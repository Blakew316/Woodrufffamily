import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// A camera alert's picture made clear when it comes out washed out or dark. The doorbell sees the street through a
/// shaded porch, and its view of a car out there came out milky (its darkest parts a light grey, 89 of 255: a fog over
/// the alert); a room at night comes from the camera's night vision dim and flat. Google Home's own alert pictures are
/// toned so they're clear, and the family's were sent as they came.
///
/// One tone curve for the picture, from how bright its parts are: its darkest and lightest parts (leaving out the
/// odd speck) are spread over nearly the whole range, by at most a little over twice (more brings up only grain), and
/// a picture still dark after that has its middle tones lifted. The same curve goes on red, green and blue, so the
/// colours stay as they were. A picture already clear is left exactly as it is.
enum PictureTone {
    /// Where the darkest and lightest parts go.
    static let black = 4, white = 250
    /// A picture whose darkest parts are at most this and lightest at least `clearWhite` has its range already.
    static let clearBlack = 32, clearWhite = 200
    /// The most the range is spread.
    static let mostGain = 2.3
    /// The middle tones are lifted when the picture's middle is still darker than this, towards `lifted`, by at most
    /// `mostLift` (black stays black: a gamma lifted it into a grey).
    static let dark = 70, lifted = 116
    static let mostLift = 0.8

    /// The curve every red, green and blue value goes through, for a picture whose brightness values (0 to 255) are
    /// counted in [histogram] (256 counts); nil when the picture is clear as it is (the curve would hardly move it).
    static func curve(_ histogram: [Int]) -> [UInt8]? {
        guard histogram.count == 256 else { return nil }
        let total = histogram.reduce(0, +)
        guard total >= 64 else { return nil }
        /// The brightness below which [share] of the picture is.
        func value(_ share: Double) -> Int {
            let target = Double(total) * share
            var sum = 0
            for (v, n) in histogram.enumerated() {
                sum += n
                if Double(sum) >= target { return v }
            }
            return 255
        }
        let lo = value(0.005), hi = value(0.995), mid = value(0.5)
        // Its range spread over nearly all there is, unless it has that already.
        var gain = 1.0, offset = 0.0, from = 0.0
        if lo > clearBlack || hi < clearWhite {
            let spread = Double(max(hi - lo, 1))
            let room = Double(white - black)
            gain = min(room / spread, mostGain)
            // With the spread held back, the range lands where the picture's own middle says: a dark one stays dark at
            // the bottom (night stays night), a bright one stays bright at the top.
            let slack = max(0, room - spread * gain)
            offset = Double(black) + slack * min(max(Double(mid) / 255, 0), 1)
            from = Double(lo)
        }
        func linear(_ v: Double) -> Double { min(max((v - from) * gain + offset, 0), 255) }
        // Still dark in the middle (a room at night): the middle tones lifted, the ends where they are.
        var lift = 0.0
        let m = linear(Double(mid)) / 255
        if m * 255 < Double(dark), m > 0.004 {
            lift = min(mostLift, max(0, (Double(lifted) / 255 - m) / (m * (1 - m))))
        }
        var table = [UInt8](repeating: 0, count: 256)
        var moved = 0.0
        for v in 0...255 {
            let x = linear(Double(v)) / 255
            let o = min(max((255 * (x + lift * x * (1 - x))).rounded(), 0), 255)
            table[v] = UInt8(o)
            // How far the parts that are in the picture move (not the values it doesn't have).
            if v >= lo, v <= hi { moved = max(moved, abs(o - Double(v))) }
        }
        return moved < 8 ? nil : table
    }

    /// How much of the band's own curve each of [height] rows takes, the band being rows [top] up to [bottom]: all of
    /// it inside, none of it far outside, and between the two over [ramp] rows on either side (no edge to see where
    /// the one tone meets the other).
    static func bandWeights(height: Int, top: Int, bottom: Int, ramp: Int) -> [Double] {
        guard height > 0 else { return [] }
        let r = Double(max(1, ramp))
        return (0..<height).map { y -> Double in
            if y >= top && y < bottom { return 1 }
            let d = y < top ? top - y : y - (bottom - 1)
            return max(0, 1 - Double(d) / r)
        }
    }

    #if canImport(CoreGraphics)
    /// [image] made clear (`curve`), or nil when it's clear as it is (or couldn't be read). [band]: the rows that will
    /// be seen (shares of the picture's height, from its top), when it's shown cut to a wide tile: the widgets show
    /// the middle of a square doorbell picture, the street through the porch, and that band is made clear by its own
    /// curve; the rest by the whole picture's (the doorbell's lock screen widget shows nearly all of it).
    static func clarified(_ image: CGImage, band: (top: Double, bottom: Double)? = nil) -> CGImage? {
        let w = image.width, h = image.height
        guard w > 0, h > 0, w * h <= 16_000_000,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let data = ctx.data else { return nil }
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let rowBytes = ctx.bytesPerRow
        let px = data.bindMemory(to: UInt8.self, capacity: rowBytes * h)
        /// How bright the rows [from] up to [to] are, counted on about 200,000 of their pixels, evenly spread.
        func histogram(_ from: Int, _ to: Int) -> [Int] {
            let step = max(1, Int((Double(w * max(1, to - from)) / 200_000).squareRoot()))
            var counts = [Int](repeating: 0, count: 256)
            var y = from
            while y < to {
                let row = px + y * rowBytes
                var x = 0
                while x < w {
                    let p = row + x * 4
                    counts[(Int(p[0]) * 77 + Int(p[1]) * 150 + Int(p[2]) * 29) >> 8] += 1
                    x += step
                }
                y += step
            }
            return counts
        }
        let whole = curve(histogram(0, h))
        var rows: (top: Int, bottom: Int)?
        var inBand: [UInt8]?
        if let band {
            let top = min(max(0, Int((band.top * Double(h)).rounded(.down))), h - 1)
            let bottom = min(h, max(top + 1, Int((band.bottom * Double(h)).rounded(.up))))
            if top > 0 || bottom < h {
                rows = (top, bottom)
                inBand = curve(histogram(top, bottom))
            }
        }
        guard whole != nil || inBand != nil else { return nil }
        let outside = whole ?? (0...255).map { UInt8($0) }
        let inside = inBand ?? outside
        let weights = rows.map { bandWeights(height: h, top: $0.top, bottom: $0.bottom, ramp: max(1, h / 8)) }
        var blended = [UInt8](repeating: 0, count: 256)
        for y in 0..<h {
            let k = weights?[y] ?? 0
            let table: [UInt8]
            if k >= 1 { table = inside } else if k <= 0 { table = outside } else {
                for v in 0...255 { blended[v] = UInt8((Double(inside[v]) * k + Double(outside[v]) * (1 - k)).rounded()) }
                table = blended
            }
            table.withUnsafeBufferPointer { t in
                let row = px + y * rowBytes
                for x in 0..<w {
                    let p = row + x * 4
                    p[0] = t[Int(p[0])]
                    p[1] = t[Int(p[1])]
                    p[2] = t[Int(p[2])]
                }
            }
        }
        return ctx.makeImage()
    }

    /// The rows of a [width] by [height] picture a wide tile (twice as wide as it is high) shows, filled and cut to
    /// it: its middle band; nil for a picture already about that wide (all of it shows).
    static func wideBand(width: Int, height: Int) -> (top: Double, bottom: Double)? {
        guard width > 0, height > 0 else { return nil }
        let shown = min(1, Double(width) / 2 / Double(height))
        guard shown < 0.95 else { return nil }
        return ((1 - shown) / 2, (1 + shown) / 2)
    }
    #endif
}
