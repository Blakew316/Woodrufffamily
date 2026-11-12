import Foundation

/// How long a film takes to start on a TV, worked out from what the TV says of its own player each time it's asked.
/// (The TV app times its starts only in Android's own log, which nothing here can read: a start that took half a
/// minute left no trace anywhere the family's devices could look.)
///
/// Three moments, as the answers show them: the player opened (the TV names a film it didn't a moment ago), the
/// player knew the film's length (its header and index were read from Google), and its place began to move (the
/// picture playing). A start that waits before the length is known waits on the sign-in, the connection or Google;
/// one that waits after it waits on the player itself (filling up, the decoders, the TV's picture mode).
public struct FilmStartWatch: Sendable {
    public struct Start: Equatable, Sendable {
        public var title: String
        /// Seconds from the player opening to the film playing.
        public var seconds: Double
        /// Seconds until the film's length was known (nil: the TV never said it).
        public var lengthKnown: Double?
        /// How far apart the TV was asked when the player opened: the times are right to within about this.
        public var within: Double
    }

    private struct Open: Sendable {
        var key: String
        var title: String
        var at: Date
        var within: Double
        var lengthAt: Date?
        var lastPosition: Double
        var lastAt: Date
        var done: Bool
    }

    /// A TV asked longer ago than this wasn't being watched closely enough to say when its player opened.
    static let longestGap: TimeInterval = 15
    /// A film left at its start this long (paused there) isn't timed.
    static let givenUpAfter: TimeInterval = 600

    private var askedAt: [String: Date] = [:]
    private var open: [String: Open] = [:]

    public init() {}

    /// The TV [id] just said what it's playing ([playing]: nil for nothing), at [now]. The start, once, when a film
    /// whose player opened while this was watching is seen playing.
    public mutating func note(tv id: String, playing: NowPlaying?, at now: Date) -> Start? {
        let last = askedAt[id]
        askedAt[id] = now
        // Only the TV's own player says which film it is (its key): other apps' titles aren't timed.
        guard let p = playing, let key = p.key, !key.isEmpty else {
            open[id] = nil
            return nil
        }
        guard var o = open[id], o.key == key else {
            // A film just opened. Timed only when the TV was asked a moment ago and wasn't on it yet: otherwise the
            // film was come upon part-way through.
            let gap = last.map { now.timeIntervalSince($0) }
            let watched = gap.map { $0 <= Self.longestGap } ?? false
            open[id] = Open(key: key, title: p.title, at: now, within: gap ?? 0, lengthAt: (p.duration ?? 0) > 0 ? now : nil,
                            lastPosition: p.position ?? 0, lastAt: now, done: !watched)
            return nil
        }
        guard !o.done else { return nil }
        if o.lengthAt == nil, (p.duration ?? 0) > 0 { o.lengthAt = now }
        let position = p.position ?? 0
        let moved = position - o.lastPosition
        let passed = now.timeIntervalSince(o.lastAt) * 1000
        // Playing: its place moved on about as far as the clock did since it was last asked. (A jump to where the film
        // was left off is far more than that, and isn't the film playing.)
        if p.isPlaying, passed > 0, moved >= 300, moved <= passed * 1.5 + 500 {
            o.done = true
            open[id] = o
            let began = max(o.lastAt, now.addingTimeInterval(-moved / 1000))
            return Start(title: o.title, seconds: max(0, began.timeIntervalSince(o.at)),
                         lengthKnown: o.lengthAt.map { max(0, $0.timeIntervalSince(o.at)) }, within: o.within)
        }
        o.lastPosition = position
        o.lastAt = now
        if now.timeIntervalSince(o.at) > Self.givenUpAfter { o.done = true }
        open[id] = o
        return nil
    }
}
