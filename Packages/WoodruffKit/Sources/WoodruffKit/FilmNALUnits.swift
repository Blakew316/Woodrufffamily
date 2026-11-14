import Foundation

/// The pieces (NAL units) an HEVC picture's frames are made of, each with its length in front in `lengthSize` bytes,
/// and the parameter sets its sample description gives the decoder (the `hvcC` box).
///
/// A picture marked "hev1" may carry its parameter sets inside its frames as well, at every keyframe, as streams made
/// for the web usually do. Handed over as "hvc1" or "dvh1" (`FilmPictureFormat`), it says the decoder has them from
/// the sample description alone: the copies inside the frames are taken out, so the decoder isn't handed the same
/// settings again every second or two (`FilmPlayer`). Parameter sets that differ from the description's stay in.
public enum FilmNALUnits {
    /// HEVC's video, sequence and picture parameter sets.
    static let parameterSetTypes: Set<UInt8> = [32, 33, 34]
    /// "End of sequence" and "end of bitstream": after one, Apple's decoder starts afresh at the next keyframe and
    /// can't show the frames that lead into it (they look back past it). A film played straight through needs
    /// neither, so they're taken out with the repeated parameter sets.
    static let endTypes: Set<UInt8> = [36, 37]

    /// The kinds of the pieces in [frame], in order (each piece's NAL unit type: 19 and 20 a keyframe of its own, 21
    /// one the frames before it may look back past, 8 and 9 such frames, 62 Dolby Vision's own data); nil when the
    /// pieces can't be walked.
    public static func kinds(_ frame: Data, lengthSize: Int) -> [UInt8]? {
        guard (1...4).contains(lengthSize) else { return nil }
        var out: [UInt8] = []
        var at = frame.startIndex
        let end = frame.endIndex
        while at < end {
            guard end - at >= lengthSize else { return nil }
            var length = 0
            for i in 0..<lengthSize { length = length << 8 | Int(frame[at + i]) }
            let body = at + lengthSize
            guard length > 0, end - body >= length else { return nil }
            out.append((frame[body] >> 1) & 0x3F)
            at = body + length
        }
        return out
    }

    /// The length of each piece's length, and the parameter sets, in an `hvcC` box's contents; nil when it isn't one.
    public static func parameterSets(hvcC: Data) -> (lengthSize: Int, sets: Set<Data>)? {
        let b = [UInt8](hvcC)
        guard b.count >= 23, b[0] == 1 else { return nil }
        let lengthSize = Int(b[21] & 0x03) + 1
        var at = 23
        var sets = Set<Data>()
        for _ in 0..<Int(b[22]) {
            guard at + 3 <= b.count else { return nil }
            let type = b[at] & 0x3F
            let count = Int(b[at + 1]) << 8 | Int(b[at + 2])
            at += 3
            for _ in 0..<count {
                guard at + 2 <= b.count else { return nil }
                let length = Int(b[at]) << 8 | Int(b[at + 1])
                at += 2
                guard at + length <= b.count else { return nil }
                if parameterSetTypes.contains(type), length > 0 { sets.insert(Data(b[at..<(at + length)])) }
                at += length
            }
        }
        return (lengthSize, sets)
    }

    /// [frame] without the parameter sets in it that [sets] holds already, or nil when it has none of them (it's
    /// used as it is). Nil too when its pieces can't be walked to its end, or nothing else would be left: it's left
    /// alone then.
    public static func withoutKnownSets(_ frame: Data, lengthSize: Int, sets: Set<Data>) -> Data? {
        guard (1...4).contains(lengthSize) else { return nil }
        var kept = Data()
        var dropped = false
        var at = frame.startIndex
        let end = frame.endIndex
        while at < end {
            guard end - at >= lengthSize else { return nil }
            var length = 0
            for i in 0..<lengthSize { length = length << 8 | Int(frame[at + i]) }
            let body = at + lengthSize
            guard length > 0, end - body >= length else { return nil }
            let type = (frame[body] >> 1) & 0x3F
            if endTypes.contains(type) || (parameterSetTypes.contains(type) && sets.contains(Data(frame[body..<(body + length)]))) {
                dropped = true
            } else {
                kept.append(frame[at..<(body + length)])
            }
            at = body + length
        }
        return dropped && !kept.isEmpty ? kept : nil
    }
}
