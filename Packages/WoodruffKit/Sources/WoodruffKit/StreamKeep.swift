import Foundation

/// Which fetched parts of a film a player's stream keeps in memory and which it lets go, when it holds more than it
/// may.
///
/// A player doesn't read a film from one place. Its picture and its sound are read each at their own place (far
/// apart when they sit apart in the file, or when one is buffered further ahead than the other), and a request it
/// drops is asked again from nearly the same place a moment later. Letting go of whatever was read longest ago, as
/// was done before, threw away what one place had fetched ahead (not read yet, so "old") to make room for another's,
/// and Google was asked for it again: freezes while it came, and Google's daily allowance spent more than once.
///
/// So what goes first is what no place will come to soon.
public enum StreamKeep {
    /// A part of the film that's held: where it starts, how long it is, when it was last read (seconds since 1970), and
    /// whether it can't go just now (still arriving, or being read this moment).
    public struct Part: Equatable, Sendable {
        public var offset: Int64
        public var length: Int64
        public var used: Double
        public var busy: Bool

        public init(offset: Int64, length: Int64, used: Double, busy: Bool = false) {
            self.offset = offset
            self.length = length
            self.used = used
            self.busy = busy
        }

        /// One past its last byte.
        var end: Int64 { offset + length }
    }

    /// The parts to let go (their indexes in [parts], in the order they go) so that what's held fits [budget].
    /// [places]: where the film is being read just now and was a moment ago. [back]: how far behind a place still
    /// counts as where it is (a dropped request is asked again from a little before where it had got to).
    ///
    /// 1. Parts behind every place (the film has gone past them): the one read longest ago first.
    /// 2. Parts ahead of a place: the one furthest ahead of the place that comes to it first.
    /// 3. Parts a place is in, only when nothing else is left: the one read longest ago first.
    ///
    /// With no place known, simply the ones read longest ago. A busy part never goes, so what's left can still be
    /// more than the budget.
    public static func letGo(_ parts: [Part], places: [Int64], budget: Int64, back: Int64 = 0) -> [Int] {
        var held: Int64 = 0
        for p in parts { held += p.length }
        guard held > budget else { return [] }

        struct Ranked {
            var index: Int
            var group: Int
            var key: Double
        }
        var ranked: [Ranked] = []
        for (i, p) in parts.enumerated() where !p.busy && p.length > 0 {
            if places.isEmpty {
                ranked.append(Ranked(index: i, group: 0, key: p.used))
            } else if places.contains(where: { p.offset <= $0 && $0 - back < p.end }) {
                ranked.append(Ranked(index: i, group: 2, key: p.used))
            } else if let reader = places.filter({ $0 < p.offset }).max() {
                // The further ahead of its reader, the sooner it goes.
                ranked.append(Ranked(index: i, group: 1, key: -Double(p.offset - reader)))
            } else {
                ranked.append(Ranked(index: i, group: 0, key: p.used))
            }
        }
        ranked.sort { a, b in
            if a.group != b.group { return a.group < b.group }
            if a.key != b.key { return a.key < b.key }
            return a.index < b.index
        }
        var going: [Int] = []
        for r in ranked {
            guard held > budget else { break }
            held -= parts[r.index].length
            going.append(r.index)
        }
        return going
    }

    /// How many places a film is being read from at once, and how far apart the furthest two are: positions closer
    /// together than [near] count as one place.
    public static func places(_ positions: [Int64], near: Int64) -> (count: Int, spread: Int64) {
        let sorted = positions.sorted()
        guard let first = sorted.first, let last = sorted.last else { return (0, 0) }
        var count = 1
        var previous = first
        for p in sorted.dropFirst() {
            if p - previous > near { count += 1 }
            previous = p
        }
        return (count, count > 1 ? last - first : 0)
    }
}

/// The parts of a file asked for so far, to tell how much of a new request had been asked for before.
public struct ByteRanges: Equatable, Sendable {
    /// A run of bytes: from [lo] up to, not including, [hi].
    public struct Span: Equatable, Sendable {
        public var lo: Int64
        public var hi: Int64
    }

    /// In order, none touching another.
    public private(set) var spans: [Span] = []

    public init() {}

    /// Every byte asked for, counted once.
    public var total: Int64 {
        var sum: Int64 = 0
        for s in spans { sum += s.hi - s.lo }
        return sum
    }

    /// Adds the bytes from [lo] up to, not including, [hi]; returns how many of them were already there.
    @discardableResult
    public mutating func add(_ lo: Int64, _ hi: Int64) -> Int64 {
        guard hi > lo else { return 0 }
        var again: Int64 = 0
        var newLo = lo, newHi = hi
        var kept: [Span] = []
        kept.reserveCapacity(spans.count + 1)
        var placed = false
        for s in spans {
            if s.hi < newLo {
                kept.append(s)
            } else if s.lo > newHi {
                if !placed {
                    kept.append(Span(lo: newLo, hi: newHi))
                    placed = true
                }
                kept.append(s)
            } else {
                // Overlapping or touching: one run from here on.
                again += max(0, min(s.hi, hi) - max(s.lo, lo))
                newLo = min(newLo, s.lo)
                newHi = max(newHi, s.hi)
            }
        }
        if !placed { kept.append(Span(lo: newLo, hi: newHi)) }
        spans = kept
        return again
    }
}
