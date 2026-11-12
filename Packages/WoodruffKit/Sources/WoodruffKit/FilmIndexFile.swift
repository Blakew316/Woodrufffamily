#if canImport(AVFoundation)
import AVFoundation
import CoreMedia

/// A film's index kept in a file of its own on the device.
///
/// The app's own player needs a film's index (which sample is where, and when it plays) and reads the film itself
/// with its own readers. Apple's reader reads the index through the app's loader the first time the film is opened.
/// What the loader was asked for then is written here: a file as long as the film that holds only those parts (the
/// rest is empty, and takes no room on the device). From then on the index is read from this file:
///
/// - Walking the index never waits on the network, in the middle of a film or anywhere else.
/// - Apple's reader, done with, can't go on fetching parts of the film nobody plays.
/// - The next time the film is opened its index is here already.
public enum FilmIndexFile {
    public enum Failure: Error, Equatable {
        /// The file's size isn't known, so no file can stand in for it.
        case noSize
        /// The file doesn't walk as the film did (a part of the index is missing from it).
        case incomplete
    }

    /// What's known of one track after its index has been looked at: enough to tell whether another reading of the
    /// same film walks the same.
    public struct Mark: Equatable, Sendable {
        public let track: CMPersistentTrackID
        /// Where the track's first and last samples are in the file, and how long each is.
        public let first: Int64
        public let firstSize: Int64
        public let last: Int64
        public let lastSize: Int64
        /// When the last sample plays, in the track's own time.
        public let lastShown: Double
    }

    /// Has Apple's reader read everything of [asset] that walking its tracks needs: its tracks, what each is, and
    /// each one's first and last samples. Asked of a film that comes through the app's loader, the loader then
    /// holds every part of the file the index is in. Returns a mark for each track that can be walked.
    public static func marks(of asset: AVAsset) async throws -> [Mark] {
        let tracks = try await asset.load(.tracks)
        _ = try? await asset.load(.duration)
        var marks: [Mark] = []
        for track in tracks {
            _ = try? await track.load(.formatDescriptions)
            _ = try? await track.load(.segments)
            guard (try? await track.load(.canProvideSampleCursors)) == true,
                  let first = track.makeSampleCursorAtFirstSampleInDecodeOrder(),
                  let last = track.makeSampleCursorAtLastSampleInDecodeOrder() else { continue }
            _ = first.copyCurrentSampleFormatDescription()
            _ = first.currentSampleDependencyAttachments
            let a = first.currentSampleStorageRange, b = last.currentSampleStorageRange
            let shown = last.presentationTimeStamp.seconds
            marks.append(Mark(track: track.trackID, first: a.offset, firstSize: a.length, last: b.offset, lastSize: b.length,
                              lastShown: shown.isFinite ? shown : 0))
        }
        return marks
    }

    /// Writes [url]: a file [total] bytes long that holds only [parts] (each at its own place; the rest is empty).
    /// Written beside it first and moved into place whole, so a file half written is never read.
    public static func write(total: Int64, parts: [(offset: Int64, data: Data)], to url: URL) throws {
        guard total > 0 else { throw Failure.noSize }
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let draft = url.appendingPathExtension("part")
        try? manager.removeItem(at: draft)
        guard manager.createFile(atPath: draft.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        do {
            let handle = try FileHandle(forWritingTo: draft)
            defer { try? handle.close() }
            try handle.truncate(atOffset: UInt64(total))
            for part in parts where part.offset >= 0 && part.offset < total && !part.data.isEmpty {
                let room = Int(min(Int64(part.data.count), total - part.offset))
                try handle.seek(toOffset: UInt64(part.offset))
                try handle.write(contentsOf: part.data.prefix(room))
            }
        } catch {
            try? manager.removeItem(at: draft)
            throw error
        }
        try? manager.removeItem(at: url)
        try manager.moveItem(at: draft, to: url)
    }

    /// Opens the index kept at [url]. With [marks] (taken from the film itself as its index was read), the file
    /// must walk the same: as many tracks that can be walked, each with its first and last sample where the film
    /// has them. The tracks in [named] aren't counted: sound Apple's reader left out of the film itself, named in
    /// the kept index since (`FilmHiddenSound`).
    public static func open(_ url: URL, matching marks: [Mark]? = nil, besides named: [CMPersistentTrackID] = []) async throws -> AVURLAsset {
        let asset = AVURLAsset(url: url)
        let found = try await Self.marks(of: asset)
        guard !found.isEmpty else { throw Failure.incomplete }
        if let marks, marks != found.filter({ !named.contains($0.track) }) { throw Failure.incomplete }
        return asset
    }

    /// How long the film at [url] is in bytes (the file is as long as the film), or nil when there's no file.
    public static func length(_ url: URL) -> Int64? {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value
    }

    /// Keeps [folder] to [count] index files and [most] bytes of the device's storage: the ones opened longest ago go.
    public static func prune(_ folder: URL, count: Int = 40, most: Int64 = 600 << 20) {
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let all = try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys) else { return }
        var files: [(url: URL, used: Date, size: Int64)] = []
        for url in all {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            files.append((url, values.contentModificationDate ?? .distantPast, Int64(values.totalFileAllocatedSize ?? 0)))
        }
        files.sort { $0.used > $1.used }
        var kept = 0
        var bytes: Int64 = 0
        for file in files {
            kept += 1
            bytes += file.size
            if kept > count || (bytes > most && kept > 1) { try? manager.removeItem(at: file.url) }
        }
    }

    /// Marks the index at [url] as used now (what `prune` goes by).
    public static func used(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }
}
#endif
