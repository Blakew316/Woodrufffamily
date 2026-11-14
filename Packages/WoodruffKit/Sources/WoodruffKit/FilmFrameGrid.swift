import Foundation

/// Even picture times for a film made at a steady rate.
///
/// A file can give its pictures' times rounded to the millisecond (42, 41, 42 ms apart instead of 41.667, as files
/// made from Matroska ones do). A TV showing a new picture exactly every 41.667 ms then gets two of them for the same
/// refresh whenever its refreshes fall close to where the rounding moves them, and Apple's renderer drops one: a
/// stutter that comes and goes as the clocks drift (Avengers Endgame Encore dropped one picture in twelve, none of
/// them late, with twelve seconds in hand). Each picture's time is put back on the film's own steady beat, which moves
/// none of them by more than the rounding (half a millisecond): the pictures themselves are untouched.
public enum FilmFrameGrid {
    /// The rates films are made at, each with one frame's length as a fraction of a second.
    public static let rates: [(fps: Double, value: Int64, timescale: Int32)] = [
        (24000.0 / 1001, 1001, 24000), (24, 1000, 24000), (25, 960, 24000), (30000.0 / 1001, 1001, 30000),
        (30, 1000, 30000), (50, 480, 24000), (60000.0 / 1001, 1001, 60000), (60, 1000, 60000),
    ]

    /// One frame's length for a film said to run at [fps] frames a second whose shortest frame lasts [shortest]
    /// seconds: nil when [fps] isn't within half a percent of one of the rates, or the frames aren't steady (one much
    /// shorter than the rate's: a film whose rate changes is left as it is).
    public static func step(fps: Double, shortest: Double) -> (value: Int64, timescale: Int32)? {
        guard fps > 0, let nearest = rates.min(by: { abs($0.fps - fps) < abs($1.fps - fps) }),
              abs(nearest.fps - fps) / fps < 0.005 else { return nil }
        let length = Double(nearest.value) / Double(nearest.timescale)
        // Rounded to the millisecond, a frame is at most half a millisecond short of the rate's; a shorter one is
        // another rate.
        guard shortest <= 0 || shortest >= length * 0.95 else { return nil }
        return (nearest.value, nearest.timescale)
    }

    /// How many steps of [step] seconds [t] is from [base], to the nearest.
    public static func steps(_ t: Double, from base: Double, step: Double) -> Int64 {
        Int64(((t - base) / step).rounded())
    }

    /// Puts one film's picture times on its beat, frame after frame, in whatever order they come (the order they're
    /// decoded in, after a move too). The first frame's time sets the beat; a time further than [within] seconds from
    /// it (a film whose rate isn't quite the one named, or a cut in it) starts the beat again from that frame, so no
    /// time is ever moved further than that.
    ///
    /// Not safe to use from two threads at once.
    public final class Evener {
        /// One frame's length, in units of [timescale].
        public let value: Int64
        public let timescale: Int32
        let within: Double
        private var base: Int64?
        /// Frames looked at, frames moved, the furthest one was moved (seconds) and times the beat began again.
        public private(set) var frames = 0
        public private(set) var moved = 0
        public private(set) var most = 0.0
        public private(set) var restarted = 0

        public init(value: Int64, timescale: Int32, within: Double = 0.003) {
            self.value = max(1, value)
            self.timescale = max(1, timescale)
            self.within = within
        }

        /// The time [seconds] on the beat, in units of [timescale], and whether it's on it (not where the beat
        /// began again); nil for a time that can't be (not finite, or too far from zero to count in them), which is
        /// left as it is.
        public func even(_ seconds: Double) -> (at: Int64, onBeat: Bool)? {
            let scale = Double(timescale)
            let raw = (seconds * scale).rounded()
            guard raw.isFinite, abs(raw) < 1e15 else { return nil }
            let t = Int64(raw)
            frames += 1
            guard let base else {
                self.base = t
                return (t, true)
            }
            let k = (Double(t - base) / Double(value)).rounded()
            let on = base + Int64(k) * value
            let off = Double(abs(on - t)) / scale
            guard off <= within else {
                self.base = t
                restarted += 1
                return (t, false)
            }
            if on != t {
                moved += 1
                most = max(most, off)
            }
            return (on, true)
        }

        /// One frame's length in words: "1/24 s", "1001/24000 s".
        public var words: String {
            timescale % Int32(clamping: value) == 0 ? "1/\(Int64(timescale) / value) s" : "\(value)/\(timescale) s"
        }
    }
}
