#if canImport(AVFoundation)
import AVFoundation
import CoreMedia

/// DTS sound that Apple's reader leaves out of a film's tracks altogether.
///
/// A file can name DTS outright, with four letters of its own ("dtsc", "dtsh", "dtsl", "dtse"): Apple's reader lists
/// such a track as sound it can't decode, and the app's own decoder plays it (`FilmSoundDecoders`). FFmpeg and
/// HandBrake write DTS another way: as "mp4a" sound, the letters AAC has, whose settings give the kind as a number
/// (0xA9 to 0xAC). Apple's reader knows the numbers of the sound it decodes and drops a track with any other: the
/// film seems to have no such track at all.
///
/// In the film's index as the app keeps it on the device (`FilmIndexFile`), such a track's four letters are set to
/// the ones the same sound has when a file names it outright: four bytes, in the kept copy only. Nothing else of
/// the index changes, and the film itself is never written to.
public enum FilmHiddenSound {
    /// The letters a file gives DTS outright, for each number an "mp4a" track's settings can give it.
    static let letters: [UInt8: String] = [0xA9: "dtsc", 0xAA: "dtsh", 0xAB: "dtsl", 0xAC: "dtse"]

    /// One track to name: where its four letters are in the file, and what they become.
    struct Found: Equatable {
        let track: CMPersistentTrackID
        let at: Int64
        let letters: String
    }

    private typealias Box = (type: String, start: Int, end: Int)

    private static func number32(_ b: [UInt8], _ at: Int) -> UInt32 {
        UInt32(b[at]) << 24 | UInt32(b[at + 1]) << 16 | UInt32(b[at + 2]) << 8 | UInt32(b[at + 3])
    }

    private static func number64(_ b: [UInt8], _ at: Int) -> UInt64 {
        UInt64(number32(b, at)) << 32 | UInt64(number32(b, at + 4))
    }

    private static func name(_ b: [UInt8], _ at: Int) -> String {
        String(decoding: b[at..<(at + 4)], as: Unicode.ASCII.self)
    }

    /// The boxes that follow one another in [b] from [from] up to [to]: each one's four letters, and where what it
    /// holds starts and ends. It stops at a box that doesn't fit.
    private static func boxes(_ b: [UInt8], _ from: Int, _ to: Int) -> [Box] {
        var out: [Box] = []
        var at = from
        while at + 8 <= to {
            var size = UInt64(number32(b, at))
            var head = 8
            if size == 1 {
                guard at + 16 <= to else { break }
                size = number64(b, at + 8)
                head = 16
            }
            guard size >= UInt64(head), size <= UInt64(to - at) else { break }
            out.append((name(b, at + 4), at + head, at + Int(size)))
            at += Int(size)
        }
        return out
    }

    /// The hidden DTS tracks in a film's index. [index] is what the index box ("moov") holds, which starts at
    /// [start] in the file.
    static func find(inIndex index: [UInt8], at start: Int64) -> [Found] {
        let b = index
        var out: [Found] = []
        for trak in boxes(b, 0, b.count) where trak.type == "trak" {
            let inside = boxes(b, trak.start, trak.end)
            guard let header = inside.first(where: { $0.type == "tkhd" }), let media = inside.first(where: { $0.type == "mdia" }) else { continue }
            // The track's number: after the header's version and its two dates (twice as long in version 1).
            let numberAt = header.start + (header.end > header.start && b[header.start] == 1 ? 20 : 12)
            guard numberAt + 4 <= header.end else { continue }
            let track = CMPersistentTrackID(bitPattern: number32(b, numberAt))
            let within = boxes(b, media.start, media.end)
            guard let handler = within.first(where: { $0.type == "hdlr" }), handler.start + 12 <= handler.end, name(b, handler.start + 8) == "soun",
                  let information = within.first(where: { $0.type == "minf" }),
                  let table = boxes(b, information.start, information.end).first(where: { $0.type == "stbl" }) else { continue }
            let tables = boxes(b, table.start, table.end)
            guard let described = tables.first(where: { $0.type == "stsd" }), described.start + 16 <= described.end,
                  number32(b, described.start + 4) >= 1 else { continue }
            // The first description: its length, its four letters, then a sound's own fields (36 bytes in all; 52 or
            // 72 in QuickTime's later versions), then boxes, one of which holds the settings ("esds").
            let entry = described.start + 8
            let length = Int(number32(b, entry))
            guard length >= 36, entry + length <= described.end, name(b, entry + 4) == "mp4a" else { continue }
            let version = Int(b[entry + 16]) << 8 | Int(b[entry + 17])
            let fields = version == 1 ? 52 : version == 2 ? 72 : 36
            guard fields <= length else { continue }
            var inner = boxes(b, entry + fields, entry + length)
            if let wave = inner.first(where: { $0.type == "wave" }) { inner += boxes(b, wave.start, wave.end) }
            guard let settings = inner.first(where: { $0.type == "esds" }),
                  let number = b[settings.start..<settings.end].withUnsafeBytes({ FilmSoundDecoders.objectType(inSettings: $0) }),
                  let named = letters[number], whole(b, tables) else { continue }
            out.append(Found(track: track, at: start + Int64(entry + 4), letters: named))
        }
        return out
    }

    /// The track's tables are all there. A kept index holds only what Apple's reader asked for; had it asked for
    /// less than the whole of a track it leaves out, the rest would read as nothing, and the track stays hidden.
    private static func whole(_ b: [UInt8], _ tables: [Box]) -> Bool {
        func entries(_ type: String) -> Int {
            guard let t = tables.first(where: { $0.type == type }), t.start + 8 <= t.end else { return 0 }
            return Int(number32(b, t.start + 4))
        }
        guard entries("stts") > 0, entries("stsc") > 0 else { return false }
        // Each sample's size: one size for all, or a list whose first and last aren't nothing.
        guard let sizes = tables.first(where: { $0.type == "stsz" }), sizes.start + 12 <= sizes.end else { return false }
        let samples = Int(number32(b, sizes.start + 8))
        guard samples > 0 else { return false }
        if number32(b, sizes.start + 4) == 0 {
            guard samples <= (sizes.end - sizes.start - 12) / 4, number32(b, sizes.start + 12) > 0,
                  number32(b, sizes.start + 12 + (samples - 1) * 4) > 0 else { return false }
        }
        // Where each chunk of samples is in the file: the first and the last aren't nothing.
        if let places = tables.first(where: { $0.type == "stco" }), places.start + 8 <= places.end {
            let count = Int(number32(b, places.start + 4))
            return count > 0 && count <= (places.end - places.start - 8) / 4 && number32(b, places.start + 8) > 0
                && number32(b, places.start + 8 + (count - 1) * 4) > 0
        }
        if let places = tables.first(where: { $0.type == "co64" }), places.start + 8 <= places.end {
            let count = Int(number32(b, places.start + 4))
            return count > 0 && count <= (places.end - places.start - 8) / 8 && number64(b, places.start + 8) > 0
                && number64(b, places.start + 8 + (count - 1) * 8) > 0
        }
        return false
    }

    /// Names the hidden DTS tracks in the index kept at [url] (a file as long as the film that holds its index).
    /// Returns the tracks it named: none when the film has no such track, or they are named already.
    @discardableResult
    public static func name(inIndexAt url: URL) -> [CMPersistentTrackID] {
        guard let handle = try? FileHandle(forUpdating: url) else { return [] }
        defer { try? handle.close() }
        guard let total = try? handle.seekToEnd(), total > 16 else { return [] }
        // The index box among the file's own boxes: before the film's pictures and sound, or after them.
        var at: UInt64 = 0
        var index: (start: UInt64, length: UInt64)?
        for _ in 0..<64 {
            guard at + 8 <= total, (try? handle.seek(toOffset: at)) != nil,
                  let read = try? handle.read(upToCount: 16), read.count >= 8 else { break }
            let head = [UInt8](read)
            var size = UInt64(number32(head, 0))
            var header: UInt64 = 8
            if size == 1 {
                guard head.count >= 16 else { break }
                size = number64(head, 8)
                header = 16
            }
            guard size >= header, size <= total - at else { break }
            if name(head, 4) == "moov" {
                index = (at + header, size - header)
                break
            }
            at += size
        }
        guard let index, index.length > 0, index.length <= 64 << 20, (try? handle.seek(toOffset: index.start)) != nil,
              let data = try? handle.read(upToCount: Int(index.length)), data.count == Int(index.length) else { return [] }
        var named: [CMPersistentTrackID] = []
        for found in find(inIndex: [UInt8](data), at: Int64(index.start)) {
            guard (try? handle.seek(toOffset: UInt64(found.at))) != nil,
                  (try? handle.write(contentsOf: Data(found.letters.utf8))) != nil else { continue }
            named.append(found.track)
        }
        return named
    }
}
#endif
