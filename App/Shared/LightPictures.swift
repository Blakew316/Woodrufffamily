import SwiftUI
import WoodruffKit

extension GoveeLight {
    /// A Govee table lamp (a frosted cylinder shade on an amber glass base).
    var isTableLamp: Bool {
        !isFloorLamp && (name.localizedCaseInsensitiveContains("table lamp")
            || ["H6020", "H6022", "H6051", "H6052"].contains(sku.uppercased()))
    }

    /// Govee string lights (bulbs hanging from a cord).
    var isStringLights: Bool {
        name.localizedCaseInsensitiveContains("string")
            || ["H7020", "H7021", "H7028", "H7041", "H7042"].contains(sku.uppercased())
    }
}

/// A Govee table lamp: a frosted cylinder shade on an amber glass base. Turned on, it brightens slowly from the centre
/// of the shade outward, the light reaching further out the brighter it's set, with a glow round the lamp.
struct TableLampPicture: View {
    var level: Double
    var lit: Bool
    var color: Color

    var body: some View {
        TableLampDrawing(power: lit ? 1 : 0, level: level, color: color)
            .animation(.easeInOut(duration: 1.4), value: lit)
            .animation(.easeOut(duration: 0.35), value: level)
    }
}

/// Govee string lights: six frosted bulbs on black sockets, the cord looping over between them, zigzagging diagonally
/// down from the top left. Turned on, the bulbs light one after another down the string, each starting dim with a
/// small glow that grows with the brightness.
struct StringLightsPicture: View {
    var level: Double
    var lit: Bool
    var color: Color
    var count = 6

    var body: some View {
        StringLightsDrawing(power: lit ? 1 : 0, level: level, color: color, count: count)
            .animation(.easeInOut(duration: 1.6), value: lit)
            .animation(.easeOut(duration: 0.35), value: level)
    }
}

// MARK: - Drawing

/// Room round the picture for its glow: drawn past its frame, so the glow fades out instead of being cut off.
private struct Overhang<Content: View>: View {
    var fraction: CGFloat
    @ViewBuilder var content: (CGSize, CGFloat) -> Content

    var body: some View {
        GeometryReader { g in
            let m = g.size.width * fraction
            content(g.size, m)
                .frame(width: g.size.width + 2 * m, height: g.size.height + 2 * m)
                .position(x: g.size.width / 2, y: g.size.height / 2)
        }
        .allowsHitTesting(false)
    }
}

private func stops(_ s: [(CGFloat, Color)]) -> Gradient {
    Gradient(stops: s.map { Gradient.Stop(color: $0.1, location: $0.0) })
}

private func hex(_ v: UInt32, _ a: Double = 1) -> Color {
    Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255).opacity(a)
}

/// A rectangle with its own corner size at the top and at the bottom.
private func roundedRect(_ r: CGRect, top rt: CGFloat, bottom rb: CGFloat) -> Path {
    var p = Path()
    let x = r.minX, y = r.minY, w = r.width, h = r.height
    p.move(to: CGPoint(x: x + rt, y: y))
    p.addLine(to: CGPoint(x: x + w - rt, y: y))
    p.addQuadCurve(to: CGPoint(x: x + w, y: y + rt), control: CGPoint(x: x + w, y: y))
    p.addLine(to: CGPoint(x: x + w, y: y + h - rb))
    p.addQuadCurve(to: CGPoint(x: x + w - rb, y: y + h), control: CGPoint(x: x + w, y: y + h))
    p.addLine(to: CGPoint(x: x + rb, y: y + h))
    p.addQuadCurve(to: CGPoint(x: x, y: y + h - rb), control: CGPoint(x: x, y: y + h))
    p.addLine(to: CGPoint(x: x, y: y + rt))
    p.addQuadCurve(to: CGPoint(x: x + rt, y: y), control: CGPoint(x: x, y: y))
    p.closeSubpath()
    return p
}

/// A soft round glow: [color] at the centre fading to nothing at [radius], squashed or stretched by [scaleY].
private func glow(_ ctx: GraphicsContext, at c: CGPoint, radius r: CGFloat, scaleY: CGFloat = 1, _ s: [(CGFloat, Color)]) {
    guard r > 0 else { return }
    var g = ctx
    g.translateBy(x: c.x, y: c.y)
    g.scaleBy(x: 1, y: scaleY)
    g.fill(Path(ellipseIn: CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r)),
           with: .radialGradient(stops(s), center: .zero, startRadius: 0, endRadius: r))
}

private func across(_ x0: CGFloat, _ x1: CGFloat, _ s: [(CGFloat, Color)]) -> GraphicsContext.Shading {
    .linearGradient(stops(s), startPoint: CGPoint(x: x0, y: 0), endPoint: CGPoint(x: x1, y: 0))
}

private func down(_ y0: CGFloat, _ y1: CGFloat, _ s: [(CGFloat, Color)]) -> GraphicsContext.Shading {
    .linearGradient(stops(s), startPoint: CGPoint(x: 0, y: y0), endPoint: CGPoint(x: 0, y: y1))
}

/// The lamp, redrawn for each step as it turns on or off ([power] 0…1) and as its brightness ([level] 0…1) moves.
private struct TableLampDrawing: View, Animatable {
    var power: Double
    var level: Double
    var color: Color

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(power, level) }
        set { power = newValue.first; level = newValue.second }
    }

    var body: some View {
        Overhang(fraction: 0.45) { size, m in
            Canvas { context, _ in
                var ctx = context
                ctx.translateBy(x: m, y: m)
                draw(ctx, w: size.width, h: size.height)
            }
        }
    }

    private func draw(_ ctx: GraphicsContext, w: CGFloat, h: CGFloat) {
        let power = CGFloat(max(0, min(1, self.power)))
        let lv = CGFloat(0.08 + 0.92 * max(0, min(1, level)))
        let sw = w * 0.64, sh = h * 0.6, sx = (w - sw) / 2, sy = h * 0.1
        let bw = sw * 0.9, bh = h * 0.17, bx = (w - bw) / 2, by = sy + sh
        let cx = w / 2

        // The light round the lamp.
        if power > 0 {
            glow(ctx, at: CGPoint(x: cx, y: sy + sh * 0.55), radius: sw * (0.75 + 0.55 * lv), scaleY: 1.25,
                 [(0, color.opacity(0.55 * power * lv)), (0.5, color.opacity(0.22 * power * lv)), (1, color.opacity(0))])
        }
        // Its shadow on the table.
        glow(ctx, at: CGPoint(x: cx, y: by + bh), radius: bw * 0.75, scaleY: 0.18, [(0, .black.opacity(0.35)), (1, .black.opacity(0))])

        // The base: amber glass, lit from above when the lamp's on.
        let base = roundedRect(CGRect(x: bx, y: by, width: bw, height: bh), top: bw * 0.04, bottom: bw * 0.1)
        ctx.fill(base, with: across(bx, bx + bw, [(0, hex(0x5A3108)), (0.18, hex(0xB8741F)), (0.38, hex(0xF3C46E)), (0.5, hex(0xFFE2A3)),
                                                 (0.66, hex(0xD08A2C)), (0.88, hex(0x8A4F12)), (1, hex(0x4A2806))]))
        ctx.fill(base, with: down(by, by + bh, [(0, hex(0xFFF0C8, 0)), (0.55, hex(0xFFDC96, 0.25)), (0.62, hex(0x502800, 0.35)), (1, hex(0x281400, 0.5))]))
        if power > 0 {
            ctx.fill(base, with: down(by, by + bh, [(0, color.mix(with: .white, by: 0.4).opacity(0.75 * power * lv)), (0.7, color.opacity(0))]))
        }

        // The shade.
        let shade = roundedRect(CGRect(x: sx, y: sy, width: sw, height: sh), top: sw * 0.2, bottom: sw * 0.03)
        var s = ctx
        s.clip(to: shade)
        let box = Path(CGRect(x: sx, y: sy, width: sw, height: sh))
        // Frosted glass, off.
        s.fill(box, with: across(sx, sx + sw, [(0, hex(0xA9A29A)), (0.22, hex(0xDDD7CF)), (0.42, hex(0xF4F0EA)), (0.6, hex(0xEBE5DD)),
                                              (0.85, hex(0xC4BDB4)), (1, hex(0x958E86))]))
        if power > 0 {
            var l = s
            l.opacity = power
            // The whole shade takes the colour, faintly at a low brightness.
            l.fill(box, with: down(sy, sy + sh, [(0, color.mix(with: .white, by: 0.5).opacity(0.35 + 0.5 * lv)), (1, color.opacity(0.45 + 0.5 * lv))]))
            // The light inside: bright at the centre, reaching further out the brighter it is, and growing as it comes on.
            let r = sh * (0.18 + 0.62 * lv) * (0.35 + 0.65 * power)
            var c = l
            c.translateBy(x: cx, y: sy + sh * 0.56)
            c.scaleBy(x: 1.15, y: 1)
            c.fill(Path(ellipseIn: CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r)),
                   with: .radialGradient(stops([(0, color.mix(with: .white, by: 0.92)), (0.3, color.mix(with: .white, by: 0.6).opacity(0.9)),
                                                (0.65, color.mix(with: .white, by: 0.2).opacity(0.45)), (1, color.opacity(0))]),
                                         center: .zero, startRadius: 0, endRadius: r))
        }
        // Round: darker at the sides, a soft highlight left of centre.
        s.fill(box, with: across(sx, sx + sw, [(0, .black.opacity(0.28)), (0.18, .black.opacity(0.06)), (0.38, .white.opacity(0.18)),
                                              (0.55, .white.opacity(0)), (0.82, .black.opacity(0.08)), (1, .black.opacity(0.32))]))
        // The top edge catching the light, the bottom edge in shadow.
        s.fill(box, with: down(sy, sy + sh, [(0, .white.opacity(0.35)), (0.06, .white.opacity(0)), (0.93, .black.opacity(0)), (1, .black.opacity(0.22))]))
    }
}

/// The string, redrawn for each step as it turns on or off ([power] 0…1) and as its brightness ([level] 0…1) moves.
private struct StringLightsDrawing: View, Animatable {
    var power: Double
    var level: Double
    var color: Color
    var count: Int

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(power, level) }
        set { power = newValue.first; level = newValue.second }
    }

    var body: some View {
        Overhang(fraction: 0.3) { size, m in
            Canvas { context, _ in
                var ctx = context
                ctx.translateBy(x: m, y: m)
                draw(ctx, w: size.width, h: size.height)
            }
        }
    }

    private func bulbPath(_ cx: CGFloat, _ top: CGFloat, _ bw: CGFloat, _ bh: CGFloat) -> Path {
        var p = Path()
        let nw = bw * 0.42
        p.move(to: CGPoint(x: cx - nw / 2, y: top))
        p.addCurve(to: CGPoint(x: cx - bw / 2, y: top + bh * 0.6),
                   control1: CGPoint(x: cx - nw / 2, y: top + bh * 0.18), control2: CGPoint(x: cx - bw / 2, y: top + bh * 0.3))
        p.addCurve(to: CGPoint(x: cx, y: top + bh),
                   control1: CGPoint(x: cx - bw / 2, y: top + bh * 0.86), control2: CGPoint(x: cx - bw * 0.27, y: top + bh))
        p.addCurve(to: CGPoint(x: cx + bw / 2, y: top + bh * 0.6),
                   control1: CGPoint(x: cx + bw * 0.27, y: top + bh), control2: CGPoint(x: cx + bw / 2, y: top + bh * 0.86))
        p.addCurve(to: CGPoint(x: cx + nw / 2, y: top),
                   control1: CGPoint(x: cx + bw / 2, y: top + bh * 0.3), control2: CGPoint(x: cx + nw / 2, y: top + bh * 0.18))
        p.closeSubpath()
        return p
    }

    private func draw(_ ctx: GraphicsContext, w: CGFloat, h: CGFloat) {
        let n = max(2, count)
        let power = CGFloat(max(0, min(1, self.power)))
        let lv = CGFloat(0.08 + 0.92 * max(0, min(1, level)))
        let bw = min(0.8 * w / (CGFloat(n - 1) + 0.96), h * 0.2), bh = bw * 1.3
        let kw = bw * 0.48, kh = bw * 0.5
        let left = bw * 0.6, right = w - bw * 0.6
        let dx = (right - left) / CGFloat(n - 1)
        let top = min(h * 0.2, dx * 0.8), last = h - bh - kh
        // A zigzag down the diagonal: every other bulb hangs lower.
        let zig = min((last - top) * 0.45, dx * 0.9)
        let points = (0..<n).map { i in
            CGPoint(x: left + dx * CGFloat(i), y: top + (last - top - zig) * CGFloat(i) / CGFloat(n - 1) + (i % 2 == 1 ? zig : 0))
        }
        // Each bulb comes on just after the one before it.
        let stagger: CGFloat = 0.35
        func each(_ i: Int) -> CGFloat { max(0, min(1, power * (1 + CGFloat(n - 1) * stagger) - CGFloat(i) * stagger)) }

        // The glow behind each bulb: small and dim at a low brightness, bigger and brighter as it goes up.
        for (i, p) in points.enumerated() {
            let b = each(i)
            guard b > 0 else { continue }
            let k = b * (0.4 + 0.6 * lv)
            glow(ctx, at: CGPoint(x: p.x, y: p.y + kh + bh * 0.6), radius: bw * (0.7 + 1.5 * lv) * (0.5 + 0.5 * b),
                 [(0, color.opacity(0.6 * k)), (0.45, color.opacity(0.22 * k)), (1, color.opacity(0))])
        }

        // The cord: in from the top left, then up and over between each pair of bulbs.
        var cord = Path()
        let p0 = points[0]
        cord.move(to: CGPoint(x: p0.x - dx * 0.6, y: p0.y - dx * 0.5))
        cord.addCurve(to: p0, control1: CGPoint(x: p0.x - dx * 0.35, y: p0.y - dx * 0.75), control2: CGPoint(x: p0.x - dx * 0.05, y: p0.y - dx * 0.55))
        for i in 1..<n {
            let a = points[i - 1], b = points[i]
            let lift = dx * 0.75
            cord.addCurve(to: b, control1: CGPoint(x: a.x + dx * 0.05, y: a.y - lift), control2: CGPoint(x: b.x - dx * 0.05, y: b.y - lift))
        }
        ctx.stroke(cord, with: .color(hex(0x141414)), style: StrokeStyle(lineWidth: max(1, bw * 0.11), lineCap: .round, lineJoin: .round))

        for (i, p) in points.enumerated() {
            let b = each(i)
            // The socket: a small black cylinder with a ridge round it.
            let socket = roundedRect(CGRect(x: p.x - kw / 2, y: p.y, width: kw, height: kh), top: kw * 0.18, bottom: kw * 0.08)
            ctx.fill(socket, with: across(p.x - kw / 2, p.x + kw / 2, [(0, hex(0x050505)), (0.3, hex(0x3A3A3A)), (0.5, hex(0x222222)), (1, hex(0x030303))]))
            ctx.fill(Path(CGRect(x: p.x - kw / 2, y: p.y + kh * 0.62, width: kw, height: max(0.5, kh * 0.07))), with: .color(.white.opacity(0.12)))

            // The bulb.
            let bt = p.y + kh - bw * 0.04
            var c = ctx
            c.clip(to: bulbPath(p.x, bt, bw, bh))
            let box = Path(CGRect(x: p.x - bw, y: bt, width: bw * 2, height: bh))
            // Frosted, with the soft colours of the real ones.
            c.fill(box, with: .linearGradient(stops([(0, hex(0xF2CDEF)), (0.35, hex(0xD6CFF6)), (0.65, hex(0xC4ECF6)), (1, hex(0xC9F4DC))]),
                                              startPoint: CGPoint(x: p.x - bw / 2, y: bt), endPoint: CGPoint(x: p.x + bw / 2, y: bt + bh)))
            if b > 0 {
                var l = c
                l.opacity = b
                let k = 0.35 + 0.65 * lv
                l.fill(box, with: .radialGradient(stops([(0, color.mix(with: .white, by: 0.85)), (0.4 * k + 0.1, color.mix(with: .white, by: 0.35)),
                                                         (1, color.mix(with: .black, by: 0.1 * (1 - k)))]),
                                                  center: CGPoint(x: p.x, y: bt + bh * 0.62), startRadius: 0, endRadius: bh * 0.75))
            }
            // Round: shade at the sides, a highlight at the top left.
            c.fill(box, with: across(p.x - bw / 2, p.x + bw / 2, [(0, .black.opacity(0.16)), (0.3, .black.opacity(0)), (0.75, .black.opacity(0)), (1, .black.opacity(0.2))]))
            c.fill(box, with: .radialGradient(stops([(0, .white.opacity(0.7)), (1, .white.opacity(0))]),
                                              center: CGPoint(x: p.x - bw * 0.16, y: bt + bh * 0.4), startRadius: 0, endRadius: bw * 0.3))
        }
    }
}
