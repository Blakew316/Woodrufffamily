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
}
