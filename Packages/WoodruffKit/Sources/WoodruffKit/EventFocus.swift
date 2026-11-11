import Foundation
// (On a Mac, Foundation alone has the box and point types without their arithmetic.)
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// A camera alert's small picture zooms in on who or what the alert is about, as Google Home's does. This is the
// arithmetic of where that is: which of the figures a detector found is the one that moved, and, when it found
// nobody, where the picture changed. Boxes are in shares of the picture (0 to 1), across from its left and down from
// its top; the picture's changes are on a small grid of cells, row by row from the top.
public enum EventFocus {
    /// The cells that differ between two grey copies of a camera's picture (brightness 0 to 255) by more than [by].
    public static func changed(_ a: [UInt8], since b: [UInt8], by: Int = 24) -> [Bool] {
        guard a.count == b.count else { return [] }
        var out = [Bool](repeating: false, count: a.count)
        for i in a.indices where abs(Int(a[i]) - Int(b[i])) > by { out[i] = true }
        return out
    }

    /// The cells that changed in any of [grids] (each as `changed` gives it).
    public static func any(_ grids: [[Bool]]) -> [Bool] {
        guard var out = grids.first else { return [] }
        for g in grids.dropFirst() where g.count == out.count {
            for i in g.indices where g[i] { out[i] = true }
        }
        return out
    }

    /// The share of the grid that changed.
    public static func share(_ changed: [Bool]) -> Double {
        changed.isEmpty ? 0 : Double(changed.filter { $0 }.count) / Double(changed.count)
    }

    /// The largest patch of changed cells that hang together (side by side or corner to corner), as a box; nil when
    /// nothing did, when it's a single cell (noise), or when over a third of the picture changed (that's the light).
    public static func patch(_ changed: [Bool], width: Int, height: Int) -> CGRect? {
        guard width > 0, height > 0, changed.count == width * height else { return nil }
        let total = changed.filter { $0 }.count
        guard total >= 2, Double(total) / Double(changed.count) <= 0.34 else { return nil }
        var seen = [Bool](repeating: false, count: changed.count)
        var best: (count: Int, x0: Int, y0: Int, x1: Int, y1: Int)?
        for start in changed.indices where changed[start] && !seen[start] {
            var stack = [start]
            seen[start] = true
            var count = 0, x0 = width, y0 = height, x1 = -1, y1 = -1
            while let i = stack.popLast() {
                let x = i % width, y = i / width
                count += 1
                x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
                for dy in -1...1 {
                    for dx in -1...1 where dx != 0 || dy != 0 {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, ny >= 0, nx < width, ny < height else { continue }
                        let j = ny * width + nx
                        if changed[j], !seen[j] { seen[j] = true; stack.append(j) }
                    }
                }
            }
            if count > (best?.count ?? 0) { best = (count, x0, y0, x1, y1) }
        }
        guard let b = best, b.count >= 2 else { return nil }
        let w = Double(width), h = Double(height)
        return CGRect(x: Double(b.x0) / w, y: Double(b.y0) / h, width: Double(b.x1 - b.x0 + 1) / w, height: Double(b.y1 - b.y0 + 1) / h)
    }

    /// The share of [box]'s cells that changed.
    public static func share(of changed: [Bool], in box: CGRect, width: Int, height: Int) -> Double {
        guard width > 0, height > 0, changed.count == width * height else { return 0 }
        let x0 = max(0, Int((box.minX * CGFloat(width)).rounded(.down)))
        let x1 = min(width - 1, Int((box.maxX * CGFloat(width)).rounded(.up)) - 1)
        let y0 = max(0, Int((box.minY * CGFloat(height)).rounded(.down)))
        let y1 = min(height - 1, Int((box.maxY * CGFloat(height)).rounded(.up)) - 1)
        guard x1 >= x0, y1 >= y0 else { return 0 }
        var n = 0
        for y in y0...y1 { for x in x0...x1 where changed[y * width + x] { n += 1 } }
        return Double(n) / Double((x1 - x0 + 1) * (y1 - y0 + 1))
    }

    /// Who the alert is about, of the figures [found] in its picture (each with how sure the detector is): the ones
    /// standing where the picture changed, when it's known where it changed and any of them does (somebody walking
    /// past, not a figure that's always in view or a post taken for one); otherwise the ones it's sure of. Several
    /// together are one box round them all. nil with nobody.
    public static func subject(_ found: [(box: CGRect, confidence: Double)], changed: [Bool]?, width: Int, height: Int) -> CGRect? {
        let real = found.filter { $0.box.width > 0 && $0.box.height > 0 }
        guard !real.isEmpty else { return nil }
        var chosen: [CGRect] = []
        if let changed, changed.contains(true) {
            chosen = real.filter { share(of: changed, in: $0.box, width: width, height: height) >= 0.1 }.map { $0.box }
        }
        if chosen.isEmpty {
            let surest = real.map { $0.confidence }.max() ?? 0
            // The ones about as sure as the surest (one figure half as sure as another is likely not one).
            chosen = real.filter { $0.confidence >= max(0.5, surest * 0.7) }.map { $0.box }
            if chosen.isEmpty, let top = real.max(by: { $0.confidence < $1.confidence }) { chosen = [top.box] }
        }
        guard let first = chosen.first else { return nil }
        return chosen.dropFirst().reduce(first) { $0.union($1) }
    }

    // MARK: Looking closer where the picture changed

    /// The part of a picture to look for a far-off figure in: [patch] (where the picture changed, in shares of the
    /// picture from its top left) with room round it, a square of the picture ([aspect]: the picture's width over its
    /// height) at least three tenths of its height, kept inside it. Somebody across the drive is a few dozen pixels
    /// of the whole picture, which the finders miss; in this part they're a good share of it. nil when that would be
    /// nearly the picture's whole height anyway (the whole picture is looked at then).
    public static func closer(_ patch: CGRect, aspect: Double) -> CGRect? {
        guard patch.width > 0, patch.height > 0, aspect > 0 else { return nil }
        let a = CGFloat(aspect)
        // Measured in the picture's height, so a square is a square.
        let side = max(patch.width * a * 2.4, patch.height * 2, 0.3)
        guard side < 0.8 else { return nil }
        let w = min(side / a, 1), h = side
        let x = min(max(0, patch.midX - w / 2), 1 - w), y = min(max(0, patch.midY - h / 2), 1 - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// A box found in a part of the picture ([box] in shares of [part], [part] in shares of the picture, both from
    /// the top left) as a box in the whole picture.
    public static func placed(_ box: CGRect, in part: CGRect) -> CGRect {
        CGRect(x: part.minX + box.minX * part.width, y: part.minY + box.minY * part.height,
               width: box.width * part.width, height: box.height * part.height)
    }

    // MARK: The sharpest of the frames that show it

    /// How sharp a grey picture ([width] by [height], brightness 0 to 255, row by row from the top) is inside [box]
    /// (shares of the picture, across from its left and down from its top): how much each cell differs from the
    /// four beside it, on average. Somebody walking is smeared in one frame and crisp in the next; this tells them
    /// apart. 0 for a box too small to measure.
    public static func sharpness(_ grey: [UInt8], width: Int, height: Int, in box: CGRect) -> Double {
        guard width > 2, height > 2, grey.count == width * height else { return 0 }
        let x0 = max(1, Int((box.minX * CGFloat(width)).rounded(.down)))
        let x1 = min(width - 2, Int((box.maxX * CGFloat(width)).rounded(.up)) - 1)
        let y0 = max(1, Int((box.minY * CGFloat(height)).rounded(.down)))
        let y1 = min(height - 2, Int((box.maxY * CGFloat(height)).rounded(.up)) - 1)
        guard x1 >= x0, y1 >= y0 else { return 0 }
        var total = 0
        for y in y0...y1 {
            let row = y * width
            for x in x0...x1 {
                let c = Int(grey[row + x]) * 4
                total += abs(c - Int(grey[row + x - 1]) - Int(grey[row + x + 1]) - Int(grey[row - width + x]) - Int(grey[row + width + x]))
            }
        }
        return Double(total) / Double((x1 - x0 + 1) * (y1 - y0 + 1))
    }

    /// Of the frames that show the alert's subject, which to alert with: each has how well the subject shows (the
    /// share of the picture it fills times how sure the finder is) and how sharp it is there. How well it shows
    /// counts most; of frames that show it about as well, the sharpest wins (a frame half as sharp as the sharpest
    /// counts as showing it a fifth less well). nil for none.
    public static func clearest(_ frames: [(shows: Double, sharp: Double)]) -> Int? {
        let top = frames.map { $0.sharp }.max() ?? 0
        var best: (index: Int, score: Double)?
        for (i, f) in frames.enumerated() where f.shows > 0 {
            let score = f.shows * (0.6 + 0.4 * (top > 0 ? f.sharp / top : 1))
            if let b = best, b.score >= score { continue }
            best = (i, score)
        }
        return best?.index
    }

    // MARK: The moment in a clip

    /// How a scene looks through a clip: each cell's middle value over the clip's frames (grey copies, all the same
    /// size). Whoever or whatever passes through stands out against it, wherever in the clip they are; a clip's first
    /// frame doesn't serve (they may be in it already).
    public static func scene(_ frames: [[UInt8]]) -> [UInt8] {
        guard let count = frames.first?.count, count > 0 else { return [] }
        let same = frames.filter { $0.count == count }
        var out = [UInt8](repeating: 0, count: count)
        var column = [UInt8](repeating: 0, count: same.count)
        for i in 0..<count {
            for (j, frame) in same.enumerated() { column[j] = frame[i] }
            column.sort()
            out[i] = column[column.count / 2]
        }
        return out
    }

    /// One frame of a clip, looked at.
    public struct Look: Sendable, Equatable {
        /// How far into the clip it is, in seconds.
        public var time: Double
        /// The share of the picture that differs from the scene in it (0 to 1).
        public var changed: Double
        /// How well a figure standing where the picture changed shows in it: the share of the picture it fills times
        /// how sure the finder is (0 with none).
        public var moving: Double
        /// The same for any figure, wherever it stands (someone who stood still the whole clip).
        public var figure: Double

        public init(time: Double, changed: Double, moving: Double = 0, figure: Double = 0) {
            self.time = time; self.changed = changed; self.moving = moving; self.figure = figure
        }
    }

    /// Which frame of a clip shows what its alert is about, and why (for the log); nil for no frames. For a person:
    /// the frame where a figure that moved shows best, else where any figure does. Otherwise, or with nobody found:
    /// the frame where the most of the picture differs from the scene, though not when over a third of it does
    /// (that's the light changing) nor under a hundredth (noise). With nothing to go on, the frame nearest a second
    /// in, where a clip was always looked at before.
    public static func moment(_ looks: [Look], person: Bool) -> (index: Int, why: String)? {
        guard !looks.isEmpty else { return nil }
        func best(_ score: (Look) -> Double) -> Int? {
            var at: Int?
            for (i, look) in looks.enumerated() where score(look) > 0 {
                if let a = at, score(looks[a]) >= score(look) { continue }
                at = i
            }
            return at
        }
        if person {
            if let i = best({ $0.moving }) { return (i, "person found") }
            if let i = best({ $0.figure }) { return (i, "person found, standing still") }
        }
        if let i = best({ $0.changed >= 0.01 && $0.changed <= 0.34 ? $0.changed : 0 }) {
            return (i, person ? "no person found, the most changed" : "the most changed")
        }
        var nearest = 0
        for (i, look) in looks.enumerated() where abs(look.time - 1) < abs(looks[nearest].time - 1) { nearest = i }
        return (nearest, "nothing stood out, a second in")
    }
}
