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

extension GoveeLight {
    /// A light bar mounted under a shelf or cabinet.
    var isUnderShelf: Bool {
        let n = name.lowercased()
        return n.contains("shelf") || n.contains("undercabinet") || n.contains("under cabinet") || n.contains("under-cabinet")
    }
}

/// A light bar under a floating cherry shelf, its light spraying down in a cone onto the counter and washing the wall. Turned on, the cone grows down
/// from the bar; the brighter it's set, the brighter the beam, the further it reaches and the wider it spreads.
struct UnderShelfPicture: View {
    var level: Double
    var lit: Bool
    var color: Color

    var body: some View {
        UnderShelfDrawing(power: lit ? 1 : 0, level: level, color: color)
            .animation(.easeInOut(duration: 1.2), value: lit)
            .animation(.easeOut(duration: 0.35), value: level)
    }
}

private struct UnderShelfDrawing: View, Animatable {
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

    /// The beam: four cones from the bar down to [reach], each a little wider and fainter, so its edges are soft.
    private func beam(_ ctx: GraphicsContext, _ x0: CGFloat, _ x1: CGFloat, _ y: CGFloat, _ reach: CGFloat, _ spread: CGFloat,
                      _ power: CGFloat, _ lv: CGFloat) {
        let cx = (x0 + x1) / 2, bw = x1 - x0
        for k in 0..<4 {
            let s = spread * (0.75 + 0.17 * CGFloat(k)), inset = bw * (0.1 - 0.04 * CGFloat(k))
            var cone = Path()
            cone.move(to: CGPoint(x: x0 + inset, y: y))
            cone.addLine(to: CGPoint(x: x1 - inset, y: y))
            cone.addLine(to: CGPoint(x: cx + s, y: reach))
            cone.addLine(to: CGPoint(x: cx - s, y: reach))
            cone.closeSubpath()
            var c = ctx
            c.opacity = power * 0.32
            c.fill(cone, with: down(y, reach, [(0, color.mix(with: .white, by: 0.5).opacity(0.8 * lv + 0.1)), (0.4, color.opacity(0.4 * lv + 0.05)),
                                               (0.85, color.opacity(0.06 * lv)), (1, color.opacity(0))]))
        }
    }

    private func draw(_ ctx: GraphicsContext, w: CGFloat, h: CGFloat) {
        let power = CGFloat(max(0, min(1, self.power)))
        let lv = CGFloat(0.08 + 0.92 * max(0, min(1, level)))
        let cx = w / 2
        // A floating shelf seen from a little above: its top face, then its front face.
        let shW = w * 0.94, shX = (w - shW) / 2, topY = h * 0.06, depth = h * 0.1, faceH = h * 0.12
        let faceY = topY + depth, under = faceY + faceH
        let brW = shW * 0.74, brX = (w - brW) / 2, brH = max(1.4, h * 0.035), brY = under - brH * 0.2
        let floorY = h * 0.95

        // The shelf's shadow on the wall.
        ctx.fill(Path(CGRect(x: shX + shW * 0.03, y: under, width: shW * 0.94, height: h * 0.08)),
                 with: down(under, under + h * 0.08, [(0, .black.opacity(0.28)), (1, .black.opacity(0))]))

        if power > 0 {
            let reach = brY + brH + (floorY - brY - brH) * (0.55 + 0.45 * lv) * (0.3 + 0.7 * power)
            var lit = ctx
            lit.opacity = power
            // The wall lit behind the beam, only below the shelf.
            var wall = lit
            wall.clip(to: Path(CGRect(x: -w, y: under, width: w * 3, height: h * 2)))
            glow(wall, at: CGPoint(x: cx, y: brY + brH), radius: w * (0.32 + 0.12 * lv), scaleY: 1.5 * (0.6 + 0.4 * power),
                 [(0, color.opacity(0.3 * lv)), (0.5, color.opacity(0.11 * lv)), (1, color.opacity(0))])
            beam(ctx, brX, brX + brW, brY + brH * 0.6, reach, w * (0.36 + 0.2 * lv), power, lv)
            // The pool of light where it lands.
            glow(lit, at: CGPoint(x: cx, y: min(floorY, reach)), radius: w * (0.35 + 0.25 * lv), scaleY: 0.16,
                 [(0, color.mix(with: .white, by: 0.4).opacity(0.75 * lv)), (0.6, color.opacity(0.25 * lv)), (1, color.opacity(0))])
        }

        // Top face: lighter, narrowing back to the wall.
        let ins = depth * 0.9
        var top = Path()
        top.move(to: CGPoint(x: shX, y: faceY))
        top.addLine(to: CGPoint(x: shX + shW, y: faceY))
        top.addLine(to: CGPoint(x: shX + shW - ins, y: topY))
        top.addLine(to: CGPoint(x: shX + ins, y: topY))
        top.closeSubpath()
        ctx.fill(top, with: down(topY, faceY, [(0, hex(0x8A3F2C)), (1, hex(0xA65A40))]))
        // Front face: cherry, darker at the ends, a bright edge where the faces meet, and its grain.
        let face = roundedRect(CGRect(x: shX, y: faceY, width: shW, height: faceH), top: 0, bottom: faceH * 0.12)
        ctx.fill(face, with: down(faceY, under, [(0, hex(0x8E3E2A)), (0.5, hex(0x743020)), (1, hex(0x562216))]))
        ctx.fill(face, with: across(shX, shX + shW, [(0, .black.opacity(0.2)), (0.12, .black.opacity(0)), (0.88, .black.opacity(0)), (1, .black.opacity(0.2))]))
        ctx.fill(Path(CGRect(x: shX, y: faceY, width: shW, height: max(0.5, faceH * 0.08))), with: .color(hex(0xFFC4AA, 0.45)))
        let grain = hex(0x280A04, 0.3)
        ctx.fill(Path(CGRect(x: shX + shW * 0.08, y: faceY + faceH * 0.45, width: shW * 0.42, height: max(0.4, faceH * 0.06))), with: .color(grain))
        ctx.fill(Path(CGRect(x: shX + shW * 0.52, y: faceY + faceH * 0.7, width: shW * 0.36, height: max(0.4, faceH * 0.06))), with: .color(grain))
        // Its lower edge catching the light.
        if power > 0 {
            var e = ctx
            e.opacity = power
            e.clip(to: face)
            e.fill(Path(CGRect(x: shX, y: under - faceH * 0.45, width: shW, height: faceH * 0.45)),
                   with: down(under - faceH * 0.45, under, [(0, color.opacity(0)), (1, color.mix(with: .white, by: 0.4).opacity(0.55 * lv))]))
        }

        // The light bar: brushed aluminium, its diffuser underneath lit in the colour.
        let bar = roundedRect(CGRect(x: brX, y: brY, width: brW, height: brH), top: brH * 0.2, bottom: brH * 0.5)
        ctx.fill(bar, with: down(brY, brY + brH, [(0, hex(0x4A4A4E)), (0.5, hex(0xB8B8BD)), (1, hex(0x7A7A80))]))
        let diffuser = roundedRect(CGRect(x: brX + brW * 0.03, y: brY + brH * 0.5, width: brW * 0.94, height: brH * 0.5), top: 0, bottom: brH * 0.25)
        ctx.fill(diffuser, with: .color(hex(0xDCDCE0)))
        if power > 0 {
            var d = ctx
            d.opacity = power
            d.fill(diffuser, with: .color(color.mix(with: .white, by: 0.6)))
            glow(d, at: CGPoint(x: cx, y: brY + brH), radius: brW * 0.6, scaleY: 0.25,
                 [(0, color.mix(with: .white, by: 0.7).opacity(0.9 * lv)), (1, color.opacity(0))])
        }
    }
}

extension GoveeLight {
    /// Govee Glide Hexa light panels (Blake's desk).
    var isHexPanels: Bool {
        ["H6058", "H6061", "H6066", "H606A"].contains(sku.uppercased())
            || name.localizedCaseInsensitiveContains("hexa") || name.localizedCaseInsensitiveContains("desk")
    }
}

/// Govee Glide Hexa panels: seven hexagons in a layered honeycomb stepping down to the right, frosted grey when off. Turned on, they light
/// one after another, each glowing from its centre, a little lighter or deeper than its neighbours as the real ones
/// blend, with a glow round them that grows with the brightness.
struct HexPanelsPicture: View {
    var level: Double
    var lit: Bool
    var color: Color

    var body: some View {
        HexPanelsDrawing(power: lit ? 1 : 0, level: level, color: color)
            .animation(.easeInOut(duration: 1.4), value: lit)
            .animation(.easeOut(duration: 0.35), value: level)
    }
}

private struct HexPanelsDrawing: View, Animatable {
    var power: Double
    var level: Double
    var color: Color

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(power, level) }
        set { power = newValue.first; level = newValue.second }
    }

    var body: some View {
        Overhang(fraction: 0.5) { size, m in
            Canvas { context, _ in
                var ctx = context
                ctx.translateBy(x: m, y: m)
                draw(ctx, w: size.width, h: size.height)
            }
        }
    }

    /// A hexagon standing on a point, its corners softened by [round] (a share of each side).
    private func hexagon(_ c: CGPoint, _ r: CGFloat, round: CGFloat = 0.16) -> Path {
        let pts = (0..<6).map { i -> CGPoint in
            let a = CGFloat.pi / 180 * (60 * CGFloat(i) - 90)
            return CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
        }
        var p = Path()
        for i in 0..<6 {
            let p0 = pts[(i + 5) % 6], p1 = pts[i], p2 = pts[(i + 1) % 6]
            let a = CGPoint(x: p1.x + (p0.x - p1.x) * round, y: p1.y + (p0.y - p1.y) * round)
            let b = CGPoint(x: p1.x + (p2.x - p1.x) * round, y: p1.y + (p2.y - p1.y) * round)
            if i == 0 { p.move(to: a) } else { p.addLine(to: a) }
            p.addQuadCurve(to: b, control: p1)
        }
        p.closeSubpath()
        return p
    }

    private func draw(_ ctx: GraphicsContext, w: CGFloat, h: CGFloat) {
        let power = CGFloat(max(0, min(1, self.power)))
        let lv = CGFloat(0.08 + 0.92 * max(0, min(1, level)))
        // Seven panels on a honeycomb (unit size), in layers stepping down to the right from the top left.
        let s3 = CGFloat(3).squareRoot()
        var cells: [CGPoint] = [.zero]
        for move in ["dr", "r", "dr", "ur", "dr", "r"] {
            let last = cells[cells.count - 1]
            cells.append(move == "r" ? CGPoint(x: last.x + s3, y: last.y)
                         : CGPoint(x: last.x + s3 / 2, y: last.y + (move == "ur" ? -1.5 : 1.5)))
        }
        let minX = cells.map(\.x).min()! - s3 / 2, maxX = cells.map(\.x).max()! + s3 / 2
        let minY = cells.map(\.y).min()! - 1, maxY = cells.map(\.y).max()! + 1
        let k = min(w / (maxX - minX), h / (maxY - minY))
        let ox = (w - (maxX - minX) * k) / 2 - minX * k, oy = (h - (maxY - minY) * k) / 2 - minY * k
        let r = k * 0.94
        let n = cells.count
        let points = cells.map { CGPoint(x: ox + $0.x * k, y: oy + $0.y * k) }
        // Each panel comes on just after the one before it.
        func each(_ i: Int) -> CGFloat { max(0, min(1, power * (1 + CGFloat(n - 1) * 0.3) - CGFloat(i) * 0.3)) }

        // The glow behind the panels.
        for (i, p) in points.enumerated() {
            let b = each(i)
            guard b > 0 else { continue }
            glow(ctx, at: p, radius: r * (1.3 + 1.1 * lv), [(0, color.opacity(0.45 * b * lv)), (0.5, color.opacity(0.15 * b * lv)), (1, color.opacity(0))])
        }
        for (i, p) in points.enumerated() {
            let b = each(i)
            let panel = hexagon(p, r)
            // Off: frosted, lighter at the top.
            ctx.fill(panel, with: down(p.y - r, p.y + r, [(0, hex(0xB4B4B9)), (1, hex(0x86868C))]))
            if b > 0 {
                // A little lighter or deeper by its place, as the real panels blend.
                let c = i % 3 == 0 ? color.mix(with: .white, by: 0.18) : i % 3 == 2 ? color.mix(with: .black, by: 0.12) : color
                var l = ctx
                l.opacity = b
                l.fill(panel, with: .radialGradient(stops([(0, c.mix(with: .white, by: 0.55 + 0.3 * lv)), (0.55, c.mix(with: .white, by: 0.15 * lv)),
                                                           (1, c.mix(with: .black, by: 0.25 * (1 - lv)))]),
                                                    center: CGPoint(x: p.x, y: p.y - r * 0.15), startRadius: 0, endRadius: r * 1.05))
            }
            // The frame, and the diffuser's thin lighter rim inside it.
            let frame = b > 0 ? color.mix(with: .black, by: 0.45).opacity(0.55 + 0.4 * (1 - b)) : hex(0x141416, 0.7)
            ctx.stroke(panel, with: .color(frame), lineWidth: max(0.5, r * 0.06))
            ctx.stroke(hexagon(p, r * 0.86), with: .color(.white.opacity(b > 0 ? 0.35 * b : 0.12)), lineWidth: max(0.4, r * 0.04))
        }
    }
}

extension HomeDevice {
    /// A motion sensor (an ecobee SmartSensor and the like): its state says whether it sees motion.
    var isMotionSensor: Bool {
        kind == .sensor && (status.contains("Motion") || status.contains("Occupied") || status.contains("Empty")
            || name.localizedCaseInsensitiveContains("ecosense") || name.localizedCaseInsensitiveContains("smartsensor"))
    }
    /// Seeing motion (or someone there) right now.
    var sensesMotion: Bool {
        isMotionSensor && ((status.contains("Motion") && !status.contains("No Motion")) || status.contains("Occupied"))
    }
}

/// An ecobee SmartSensor as ecobee shows it: a soft white square with a thin grey line just inside its edge, on a
/// short brushed-steel cone with a collar where it meets the sensor, on a deep green studio backdrop. While it senses
/// motion a soft mint glow and a faint ring spread round it.
struct SmartSensorPicture: View {
    var motion: Bool

    var body: some View {
        Canvas { ctx, size in draw(ctx, w: size.width, h: size.height) }
            .animation(.easeInOut(duration: 0.6), value: motion)
            .accessibilityHidden(true)
    }

    private func square(_ cx: CGFloat, _ cy: CGFloat, _ s: CGFloat, _ k: CGFloat) -> Path {
        roundedRect(CGRect(x: cx - s / 2, y: cy - s / 2, width: s, height: s), top: s * k, bottom: s * k)
    }

    private func draw(_ ctx: GraphicsContext, w: CGFloat, h: CGFloat) {
        let backdrop = Path(roundedRect: CGRect(x: 0, y: 0, width: w, height: h), cornerRadius: w * 0.22, style: .continuous)
        ctx.fill(backdrop, with: down(0, h, [(0, hex(0x28493F)), (1, hex(0x142B25))]))
        var c = ctx
        c.clip(to: backdrop)
        let all = Path(CGRect(x: 0, y: 0, width: w, height: h))
        let s = w * 0.48, cx = w / 2, cy = h * 0.41
        let standTop = cy + s * 0.42, floor = cy + s * 0.5 + s * 0.36

        // A studio sweep: the floor a touch lighter towards the front, a vignette round the edges, a key light above.
        c.fill(Path(CGRect(x: 0, y: floor - s * 0.15, width: w, height: h)),
               with: down(floor - s * 0.15, h, [(0, .white.opacity(0)), (0.4, .white.opacity(0.035)), (1, .black.opacity(0.12))]))
        c.fill(all, with: .radialGradient(stops([(0, .black.opacity(0)), (1, .black.opacity(0.35))]),
                                          center: CGPoint(x: cx, y: h * 0.45), startRadius: w * 0.3, endRadius: w * 0.78))
        c.fill(all, with: .radialGradient(stops([(0, .white.opacity(0.1)), (1, .white.opacity(0))]),
                                          center: CGPoint(x: cx, y: h * 0.3), startRadius: 0, endRadius: w * 0.62))
        // Motion: a soft mint glow and a faint ring spreading from the sensor.
        if motion {
            let mint = Color(red: 0.67, green: 1, blue: 0.84)
            c.fill(all, with: .radialGradient(stops([(0, mint.opacity(0.35)), (1, mint.opacity(0))]),
                                              center: CGPoint(x: cx, y: cy), startRadius: s * 0.3, endRadius: w * 0.7))
            c.stroke(square(cx, cy, s * (1 + 0.7 * 0.55), 0.28), with: .color(Color(red: 0.78, green: 1, blue: 0.9).opacity(0.22)),
                     lineWidth: max(0.5, s * 0.025))
        }
        // Its shadow on the floor.
        glow(c, at: CGPoint(x: cx, y: floor), radius: s * 0.66, scaleY: 0.16, [(0, .black.opacity(0.55)), (1, .black.opacity(0))])

        // The stand: brushed steel, a bright streak where the light catches it, fine brushing, a rim at its foot.
        let nw = s * 0.075, bw = s * 0.3
        var stand = Path()
        stand.move(to: CGPoint(x: cx - nw, y: standTop))
        stand.addLine(to: CGPoint(x: cx + nw, y: standTop))
        stand.addQuadCurve(to: CGPoint(x: cx + bw, y: floor - s * 0.03), control: CGPoint(x: cx + nw * 1.2, y: floor - s * 0.12))
        stand.addQuadCurve(to: CGPoint(x: cx - bw, y: floor - s * 0.03), control: CGPoint(x: cx, y: floor + s * 0.05))
        stand.addQuadCurve(to: CGPoint(x: cx - nw, y: standTop), control: CGPoint(x: cx - nw * 1.2, y: floor - s * 0.12))
        stand.closeSubpath()
        c.fill(stand, with: across(cx - bw, cx + bw, [(0, hex(0x2E3236)), (0.22, hex(0x7F858A)), (0.4, hex(0xD9DDE0)), (0.47, .white),
                                                     (0.55, hex(0xC4C9CD)), (0.75, hex(0x80868B)), (1, hex(0x33373B))]))
        var brushed = c
        brushed.clip(to: stand)
        for i in -6...6 {
            var line = Path()
            line.move(to: CGPoint(x: cx + CGFloat(i) * nw * 0.25, y: standTop))
            line.addLine(to: CGPoint(x: cx + CGFloat(i) * bw / 6, y: floor))
            brushed.stroke(line, with: .color(i % 2 != 0 ? .white.opacity(0.1) : .black.opacity(0.1)), lineWidth: max(0.25, s * 0.006))
        }
        brushed.fill(Path(CGRect(x: cx - bw, y: standTop, width: bw * 2, height: floor - standTop + s * 0.05)),
                     with: down(standTop, floor, [(0, .black.opacity(0.45)), (0.35, .black.opacity(0)), (0.86, .black.opacity(0)), (1, .white.opacity(0.25))]))
        // The collar where it meets the sensor.
        let collar = roundedRect(CGRect(x: cx - nw * 1.25, y: standTop - s * 0.04, width: nw * 2.5, height: s * 0.06), top: s * 0.02, bottom: s * 0.02)
        c.fill(collar, with: across(cx - nw * 1.25, cx + nw * 1.25, [(0, hex(0x2A2D30)), (0.5, hex(0x8A9095)), (1, hex(0x2A2D30))]))

        // The sensor: its depth showing as a thin grey edge below and to the right, then the soft white face.
        let depth = s * 0.035
        c.fill(square(cx + depth * 0.4, cy + depth, s, 0.24), with: down(cy, cy + s / 2 + depth, [(0, hex(0xB9BDC1)), (1, hex(0x8E9398))]))
        let body = square(cx, cy, s, 0.24)
        var shadowed = c
        shadowed.addFilter(.shadow(color: .black.opacity(0.4), radius: s * 0.07, x: 0, y: s * 0.05))
        shadowed.fill(body, with: .linearGradient(stops([(0, .white), (0.55, hex(0xF3F4F5)), (1, hex(0xDFE2E5))]),
                                                  startPoint: CGPoint(x: cx - s / 2, y: cy - s / 2), endPoint: CGPoint(x: cx + s / 2, y: cy + s / 2)))
        // A matte sheen across the face, a little shade at its foot.
        var face = c
        face.clip(to: body)
        let box = Path(CGRect(x: cx - s, y: cy - s, width: s * 2, height: s * 2))
        face.fill(box, with: .radialGradient(stops([(0, .white.opacity(0.9)), (0.6, .white.opacity(0))]),
                                             center: CGPoint(x: cx - s * 0.18, y: cy - s * 0.22), startRadius: 0, endRadius: s * 0.8))
        face.fill(box, with: down(cy - s / 2, cy + s / 2, [(0, .white.opacity(0)), (0.85, .black.opacity(0)), (1, .black.opacity(0.08))]))
        // The edge catching the light, then the fine line just inside it with a soft highlight under it (a shallow groove).
        c.stroke(square(cx, cy - s * 0.004, s * 0.995, 0.24), with: .color(.white.opacity(0.9)), lineWidth: max(0.35, s * 0.01))
        c.stroke(square(cx, cy + s * 0.006, s * 0.93, 0.22), with: .color(.white.opacity(0.8)), lineWidth: max(0.4, s * 0.012))
        c.stroke(square(cx, cy, s * 0.93, 0.22), with: .color(Color(red: 0.43, green: 0.45, blue: 0.48).opacity(0.6)), lineWidth: max(0.4, s * 0.012))
    }
}
