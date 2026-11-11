import Foundation

/// How a film's samples (its picture frames, its sound packets) are gathered into runs of bytes to fetch.
///
/// The app's own player reads a film one track at a time: the picture's samples from where they are, the sound's
/// from where they are, each in the order they're decoded. That is what lets it play a film whose sound and picture
/// are stored far apart: Apple's player reads such a film by hopping between the two some hundreds of times a
/// second, and stops every twenty seconds or so.
///
/// Each sample says where its bytes are. Samples that follow one another in the file are fetched together as one
/// run. A small gap between two of them (another track's samples, in a film stored the usual way) is read through
/// rather than asked for separately.
public enum FilmRuns {
    /// Whether the sample at [offset], [size] bytes long, belongs to the run that so far covers [start] up to (not
    /// including) [end]: it must come after the run, no further than [gap] bytes on, and the run with it must stay
    /// within [most] bytes.
    public static func joins(start: Int64, end: Int64, offset: Int64, size: Int, gap: Int64, most: Int) -> Bool {
        guard offset >= end, offset - end <= gap else { return false }
        return offset + Int64(size) - start <= Int64(most)
    }

    /// How many of the samples at [offsets] with [sizes], from the first on, make one run.
    public static func count(offsets: [Int64], sizes: [Int], gap: Int64, most: Int) -> Int {
        guard let first = offsets.first, let firstSize = sizes.first else { return 0 }
        var end = first + Int64(firstSize)
        var n = 1
        while n < offsets.count, n < sizes.count,
              joins(start: first, end: end, offset: offsets[n], size: sizes[n], gap: gap, most: most) {
            end = offsets[n] + Int64(sizes[n])
            n += 1
        }
        return n
    }
}

/// When the app's own player starts and stops a film for want of data.
///
/// It holds a few seconds of the film ready to show. A film starts (or starts again after waiting) once enough is
/// ready, and waits when what's ready has run out: not at the first late sample, which would stop a film that is
/// only a moment behind.
public enum FilmBuffering {
    /// What the player should do now.
    public enum Move: Equatable, Sendable {
        /// Carry on as it is.
        case stay
        /// Stop the clock and show that it's loading.
        case wait
        /// Start the clock (again).
        case go
    }

    /// [waiting]: the clock is stopped for want of data. [picture] and [sound]: how many seconds of each are ready
    /// past where the film is (nil for a film without one), and [pictureDone], [soundDone]: whether everything to
    /// the end of each has been read. [enough]: the seconds of each a film starts with. [low]: with this little
    /// left of either, it waits (a moment before the last of it has gone to the decoder).
    public static func move(waiting: Bool, picture: Double?, sound: Double?, pictureDone: Bool, soundDone: Bool,
                            enough: Double, low: Double = 0) -> Move {
        func ready(_ ahead: Double?, _ done: Bool) -> Bool { ahead.map { $0 >= enough || done } ?? true }
        func out(_ ahead: Double?, _ done: Bool) -> Bool { ahead.map { $0 <= low && !done } ?? false }
        if waiting {
            return ready(picture, pictureDone) && ready(sound, soundDone) ? .go : .stay
        }
        return out(picture, pictureDone) || out(sound, soundDone) ? .wait : .stay
    }
}

/// The words of a film's own subtitles.
public enum FilmText {
    /// What one sample of a film's subtitle track says: its length in two bytes, then the words (whatever follows
    /// them, about how they're styled, is left). Nil for a sample that says nothing (the gap between two lines).
    public static func subtitle(_ sample: Data) -> String? {
        guard sample.count >= 2 else { return nil }
        let bytes = [UInt8](sample)
        let length = Int(bytes[0]) << 8 | Int(bytes[1])
        guard length > 0, 2 + length <= bytes.count else { return nil }
        let words = Array(bytes[2..<(2 + length)])
        var text: String?
        if words.count >= 2, (words[0] == 0xFE && words[1] == 0xFF) || (words[0] == 0xFF && words[1] == 0xFE) {
            text = String(bytes: words, encoding: .utf16)
        } else {
            text = String(bytes: words, encoding: .utf8) ?? String(bytes: words, encoding: .isoLatin1)
        }
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// A film's time as its player shows it: "1:02:03", "2:03", "0:07". Hours only when [hours] (the film is an hour
    /// or longer), so the time doesn't change width as it passes an hour.
    public static func clock(_ seconds: Double, hours: Bool) -> String {
        let whole = seconds.isFinite ? max(0, Int(seconds.rounded(.down))) : 0
        let h = whole / 3600, m = whole % 3600 / 60, s = whole % 60
        if hours || h > 0 {
            return "\(h):" + (m < 10 ? "0\(m)" : "\(m)") + ":" + (s < 10 ? "0\(s)" : "\(s)")
        }
        return "\(m):" + (s < 10 ? "0\(s)" : "\(s)")
    }
}
