import SwiftUI

extension HomeDevice {
    /// One of the family's Samsung Bespoke appliances, drawn as itself: the fridge, dishwasher, washer and dryer, and
    /// the oven named "Bespoke" (the landlord's oven keeps its usual picture).
    var bespokeLook: BespokeAppliance.Model? {
        guard source == "smartthings" else { return nil }
        switch kind {
        case .fridge: return .fridge
        case .dishwasher: return .dishwasher
        case .washer: return .washer
        case .dryer: return .dryer
        case .oven: return name.localizedCaseInsensitiveContains("bespoke") ? .range : nil
        default: return nil
        }
    }
}

/// Samsung Bespoke appliances, drawn like their product photos: the stainless French-door fridge, the dark steel
/// dishwasher with its top lip, the white-glass slide-in range, and the forest-green washer and dryer. Running, the
/// washer's drum and the dryer's turn, the range's window glows, and the dishwasher shows its blue light.
struct BespokeAppliance: View {
    enum Model { case fridge, dishwasher, range, washer, dryer }
    var model: Model
    var running: Bool
    var alert = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let moves = running && model != .fridge && !reduceMotion
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !moves)) { tl in
            let t = moves ? tl.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600) : 0.3
            Canvas { ctx, size in
                let d = Drawing(ctx: ctx, w: size.width, h: size.height, t: t)
                switch model {
                case .fridge: d.fridge(alert: alert)
                case .dishwasher: d.dishwasher(running: running)
                case .range: d.range(running: running)
                case .washer: d.laundry(dryer: false, running: running)
                case .dryer: d.laundry(dryer: true, running: running)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

private func gradient(_ s: [(CGFloat, Color)]) -> Gradient { Gradient(stops: s.map { Gradient.Stop(color: $0.1, location: $0.0) }) }

private func rgb(_ v: UInt32, _ a: Double = 1) -> Color {
    Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255).opacity(a)
}

private func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, top: CGFloat, bottom: CGFloat) -> Path {
    var p = Path()
    p.move(to: CGPoint(x: x + top, y: y))
    p.addLine(to: CGPoint(x: x + w - top, y: y))
    p.addQuadCurve(to: CGPoint(x: x + w, y: y + top), control: CGPoint(x: x + w, y: y))
    p.addLine(to: CGPoint(x: x + w, y: y + h - bottom))
    p.addQuadCurve(to: CGPoint(x: x + w - bottom, y: y + h), control: CGPoint(x: x + w, y: y + h))
    p.addLine(to: CGPoint(x: x + bottom, y: y + h))
    p.addQuadCurve(to: CGPoint(x: x, y: y + h - bottom), control: CGPoint(x: x, y: y + h))
    p.addLine(to: CGPoint(x: x, y: y + top))
    p.addQuadCurve(to: CGPoint(x: x + top, y: y), control: CGPoint(x: x, y: y))
    p.closeSubpath()
    return p
}

private func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> Path { Path(CGRect(x: x, y: y, width: w, height: h)) }
private func circle(_ c: CGPoint, _ r: CGFloat) -> Path { Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)) }

/// The drawing calls, one appliance each, mirroring the design drafts call for call.
private struct Drawing {
    let ctx: GraphicsContext
    let w: CGFloat, h: CGFloat
    let t: Double

    func linear(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat, _ s: [(CGFloat, Color)]) -> GraphicsContext.Shading {
        .linearGradient(gradient(s), startPoint: CGPoint(x: x0, y: y0), endPoint: CGPoint(x: x1, y: y1))
    }

    func radial(_ x: CGFloat, _ y: CGFloat, _ r0: CGFloat, _ r1: CGFloat, _ s: [(CGFloat, Color)]) -> GraphicsContext.Shading {
        .radialGradient(gradient(s), center: CGPoint(x: x, y: y), startRadius: r0, endRadius: r1)
    }

    /// A soft shadow on the floor under it.
    func shadowUnder(_ cx: CGFloat, _ y: CGFloat, _ r: CGFloat, _ color: Color = .black, _ alpha: Double = 0.45) {
        var c = ctx
        c.translateBy(x: cx, y: y)
        c.scaleBy(x: 1, y: 0.12)
        c.fill(circle(.zero, r), with: radial(0, 0, 0, r, [(0, color.opacity(alpha)), (1, color.opacity(0))]))
    }

    func feet(_ x0: CGFloat, _ x1: CGFloat, _ y: CGFloat, _ fw: CGFloat, _ fh: CGFloat) {
        let s = linear(0, y, 0, y + fh, [(0, rgb(0x2A2A2C)), (1, rgb(0x0C0C0D))])
        ctx.fill(rect(x0, y, fw, fh), with: s)
        ctx.fill(rect(x1 - fw, y, fw, fh), with: s)
    }

    /// Fine brushing lines across a surface, alternately light and dark.
    func brushed(_ path: Path, _ x: CGFloat, _ y: CGFloat, _ bw: CGFloat, _ bh: CGFloat, vertical: Bool, _ alpha: Double) {
        var c = ctx
        c.clip(to: path)
        let n = 26
        for i in 0..<n {
            let k = CGFloat(i) / CGFloat(n), jitter = CGFloat(i * 7 % 5) * 0.1
            var line = Path()
            if vertical {
                line.move(to: CGPoint(x: x + bw * k + jitter, y: y)); line.addLine(to: CGPoint(x: x + bw * k + jitter, y: y + bh))
            } else {
                line.move(to: CGPoint(x: x, y: y + bh * k + jitter)); line.addLine(to: CGPoint(x: x + bw, y: y + bh * k + jitter))
            }
            c.stroke(line, with: .color(i % 2 == 1 ? .white.opacity(alpha) : .black.opacity(alpha)), lineWidth: max(0.2, bw * 0.004))
        }
    }

    // MARK: French-door fridge, stainless steel

    func fridge(alert: Bool) {
        let bw = min(w * 0.62, h * 0.52), bh = h * 0.9, x = (w - bw) / 2, y = h * 0.02, cx = w / 2
        shadowUnder(cx, y + bh + h * 0.03, bw * 0.75)
        feet(x + bw * 0.06, x + bw * 0.94, y + bh, bw * 0.08, h * 0.03)
        let steel = linear(x, y, x + bw, y + bh * 0.3, [(0, rgb(0x8E9399)), (0.18, rgb(0xC9CDD1)), (0.42, rgb(0xE4E7EA)), (0.55, rgb(0xCFD3D7)),
                                                         (0.8, rgb(0xB4B9BE)), (1, rgb(0x878C92))])
        let top = bh * 0.66, gap = max(0.6, bw * 0.012)
        ctx.fill(box(x - 0.5, y - 0.5, bw + 1, bh + 1, top: bw * 0.03, bottom: bw * 0.02), with: .color(rgb(0x3A3D41)))
        let doors: [(CGFloat, CGFloat, CGFloat, CGFloat, Bool)] = [
            (x, y, bw / 2 - gap / 2, top, true), (x + bw / 2 + gap / 2, y, bw / 2 - gap / 2, top, true),
            (x, y + top + gap * 2.2, bw, bh - top - gap * 2.2, false),
        ]
        for (dx, dy, dw, dh, upper) in doors {
            let d = box(dx, dy, dw, dh, top: upper ? bw * 0.025 : bw * 0.01, bottom: upper ? bw * 0.008 : bw * 0.02)
            ctx.fill(d, with: steel)
            brushed(d, dx, dy, dw, dh, vertical: true, 0.035)
            var c = ctx
            c.clip(to: d)
            // A soft reflection streak, and shade towards the floor.
            c.fill(rect(dx, dy, dw, dh), with: linear(x, 0, x + bw, 0, [(0, .white.opacity(0)), (0.3, .white.opacity(0.28)), (0.36, .white.opacity(0)), (1, .white.opacity(0))]))
            c.fill(rect(dx, dy, dw, dh), with: linear(0, y, 0, y + bh, [(0, .white.opacity(0.08)), (1, .black.opacity(0.18))]))
            // Its edges: lit on the left and top, in shade on the right and bottom.
            let e = max(0.5, bw * 0.016)
            c.fill(rect(dx, dy, e, dh), with: .color(.white.opacity(0.55)))
            c.fill(rect(dx, dy, dw, e * 0.7), with: .color(.white.opacity(0.55)))
            c.fill(rect(dx + dw - e, dy, e, dh), with: .color(.black.opacity(0.22)))
            c.fill(rect(dx, dy + dh - e * 0.7, dw, e * 0.7), with: .color(.black.opacity(0.22)))
        }
        // The kick plate under the drawer, with its vent slots.
        let kp = y + bh, kh = h * 0.035
        ctx.fill(rect(x + bw * 0.04, kp - kh * 0.2, bw * 0.92, kh * 0.7), with: linear(0, kp - kh, 0, kp, [(0, rgb(0x1D1E20)), (1, rgb(0x0B0B0C))]))
        for i in 0..<16 {
            ctx.fill(rect(x + bw * (0.12 + CGFloat(i) * 0.048), kp - kh * 0.05, max(0.3, bw * 0.02), kh * 0.35), with: .color(.white.opacity(0.1)))
        }
        // The black band where the doors meet the drawer, and the hinge covers on top.
        ctx.fill(rect(x, y + top, bw, gap * 2.2), with: .color(rgb(0x1B1C1E)))
        let hinge = linear(0, y, 0, y + bh * 0.02, [(0, rgb(0x6B7076)), (1, rgb(0x3F4348))])
        ctx.fill(rect(x + bw * 0.06, y - bh * 0.008, bw * 0.12, bh * 0.012), with: hinge)
        ctx.fill(rect(x + bw * 0.82, y - bh * 0.008, bw * 0.12, bh * 0.012), with: hinge)
        // Recessed handles: a shadow line at each door's inner edge and along the drawer's top.
        let recess = GraphicsContext.Shading.color(.black.opacity(0.28))
        ctx.fill(rect(x + bw / 2 - gap / 2 - bw * 0.03, y + top * 0.06, bw * 0.012, top * 0.5), with: recess)
        ctx.fill(rect(x + bw / 2 + gap / 2 + bw * 0.018, y + top * 0.06, bw * 0.012, top * 0.5), with: recess)
        ctx.fill(rect(x + bw * 0.08, y + top + gap * 2.2 + bh * 0.012, bw * 0.84, max(0.4, bh * 0.008)), with: recess)
        if alert {
            let warn = Color(red: 1, green: 0.47, blue: 0.35)
            ctx.fill(rect(x, y, bw, top), with: radial(cx, y + top * 0.5, 0, bw * 0.6, [(0, warn.opacity(0.35)), (1, warn.opacity(0))]))
        }
    }

    // MARK: Dishwasher, dark matte steel

    func dishwasher(running: Bool) {
        let bw = min(w * 0.78, h * 0.74), bh = h * 0.88, x = (w - bw) / 2, y = h * 0.04, cx = w / 2
        shadowUnder(cx, y + bh + h * 0.02, bw * 0.7)
        if running {
            // Its light on the floor while it runs.
            var c = ctx
            c.translateBy(x: cx, y: y + bh + h * 0.02)
            c.scaleBy(x: 1, y: 0.18)
            let blue = Color(red: 0.35, green: 0.67, blue: 1)
            c.fill(circle(.zero, bw * 0.55), with: radial(0, 0, 0, bw * 0.55, [(0, blue.opacity(0.55)), (1, blue.opacity(0))]))
        }
        // One continuous panel of dark brushed steel (the top band as plain as the door), a fine seam between them.
        let strip = bh * 0.11, dy = y + strip, dh = bh * 0.8, ky = dy + dh
        let panel = box(x, y, bw, ky - y, top: bw * 0.012, bottom: bw * 0.01)
        ctx.fill(panel, with: linear(x, y, x + bw, ky, [(0, rgb(0x62656B)), (0.35, rgb(0x4A4C51)), (1, rgb(0x2D2F33))]))
        brushed(panel, x, y, bw, ky - y, vertical: false, 0.035)
        var lit = ctx
        lit.clip(to: panel)
        lit.fill(rect(x, y, bw, ky - y), with: radial(x + bw * 0.25, y + bh * 0.12, 0, bw * 0.95, [(0, .white.opacity(0.16)), (1, .white.opacity(0))]))
        lit.fill(rect(x, y, bw, ky - y), with: linear(x, 0, x + bw, 0, [(0, .black.opacity(0.18)), (0.06, .black.opacity(0)), (0.94, .black.opacity(0)), (1, .black.opacity(0.22))]))
        let seam = max(0.35, bh * 0.006)
        ctx.fill(rect(x + bw * 0.01, dy, bw * 0.98, seam), with: .color(.black.opacity(0.4)))
        ctx.fill(rect(x + bw * 0.01, dy + seam, bw * 0.98, max(0.3, bh * 0.004)), with: .color(.white.opacity(0.1)))
        ctx.stroke(panel, with: .color(.white.opacity(0.14)), lineWidth: max(0.3, bw * 0.006))
        // The toe kick with its vent slots, and the feet.
        ctx.fill(rect(x + bw * 0.01, ky, bw * 0.98, y + bh - ky), with: linear(0, ky, 0, y + bh, [(0, rgb(0x0E0E10)), (1, rgb(0x050506))]))
        ctx.fill(rect(x + bw * 0.01, ky, bw * 0.98, max(0.3, bh * 0.006)), with: .color(.white.opacity(0.08)))
        for i in 0..<14 {
            ctx.fill(rect(x + bw * (0.2 + CGFloat(i) * 0.045), ky + (y + bh - ky) * 0.35, max(0.3, bw * 0.018), (y + bh - ky) * 0.35), with: .color(.white.opacity(0.06)))
        }
        feet(x + bw * 0.02, x + bw * 0.98, y + bh, bw * 0.06, h * 0.025)
    }

    // MARK: Slide-in induction range, white glass

    func range(running: Bool) {
        let bw = min(w * 0.8, h * 0.8), bh = h * 0.86, x = (w - bw) / 2, y = h * 0.06, cx = w / 2
        shadowUnder(cx, y + bh + h * 0.02, bw * 0.7)
        // The cooktop, seen from a little above, with its two zones.
        let ct = bh * 0.1
        var top = Path()
        top.move(to: CGPoint(x: x + bw * 0.04, y: y)); top.addLine(to: CGPoint(x: x + bw * 0.96, y: y))
        top.addLine(to: CGPoint(x: x + bw, y: y + ct)); top.addLine(to: CGPoint(x: x, y: y + ct)); top.closeSubpath()
        ctx.fill(top, with: linear(0, y, 0, y + ct, [(0, rgb(0x2B2C2F)), (1, rgb(0x151618))]))
        let zone = GraphicsContext.Shading.color(.white.opacity(0.12)), line = max(0.3, bw * 0.005)
        ctx.stroke(Path(ellipseIn: CGRect(x: x + bw * 0.18, y: y + ct * 0.27, width: bw * 0.24, height: ct * 0.56)), with: zone, lineWidth: line)
        ctx.stroke(Path(ellipseIn: CGRect(x: x + bw * 0.6, y: y + ct * 0.31, width: bw * 0.2, height: ct * 0.48)), with: zone, lineWidth: line)
        ctx.fill(rect(x, y + ct - max(0.3, ct * 0.06), bw, max(0.3, ct * 0.06)), with: .color(.white.opacity(0.18)))
        if running { ctx.fill(rect(x + bw * 0.47, y + ct * 0.35, bw * 0.06, ct * 0.12), with: .color(rgb(0xFF5A3C, 0.9))) }
        // The control strip: white glass, a black band with its small red display.
        let sy = y + ct, sh = bh * 0.12
        ctx.fill(rect(x, sy, bw, sh), with: linear(0, sy, 0, sy + sh, [(0, .white), (1, rgb(0xE7E9EB))]))
        ctx.fill(rect(x, sy + sh * 0.35, bw, sh * 0.3), with: .color(rgb(0x1A1B1D)))
        for i in 0..<3 {
            ctx.fill(rect(x + bw * (0.36 + CGFloat(i) * 0.035), sy + sh * 0.43, bw * 0.018, sh * 0.14), with: .color(rgb(0xFF5A3C, running ? 1 : 0.55)))
        }
        ctx.fill(rect(x + bw * 0.5, sy + sh * 0.45, bw * 0.08, sh * 0.1), with: .color(.white.opacity(0.5)))
        // The door: black glass in a white frame, the racks through the window (glowing while it cooks).
        let dy = sy + sh, dh = bh * 0.58
        ctx.fill(rect(x, dy, bw, dh), with: linear(0, dy, 0, dy + dh, [(0, .white), (1, rgb(0xE3E5E8))]))
        let wx = x + bw * 0.04, wy = dy + dh * 0.12, ww = bw * 0.92, wh = dh * 0.76
        let window = box(wx, wy, ww, wh, top: bw * 0.01, bottom: bw * 0.01)
        ctx.fill(window, with: linear(0, wy, 0, wy + wh, [(0, rgb(0x1D1E21)), (1, rgb(0x0B0B0C))]))
        var g = ctx
        g.clip(to: window)
        let inner = box(wx + ww * 0.12, wy + wh * 0.14, ww * 0.76, wh * 0.72, top: bw * 0.01, bottom: bw * 0.01)
        if running {
            let k = 0.8 + 0.2 * sin(t * 1.7)
            g.fill(inner, with: radial(cx, wy + wh * 0.55, 0, ww * 0.55, [(0, Color(red: 1, green: 0.59, blue: 0.24).opacity(0.85 * k)),
                                                                         (0.6, Color(red: 0.86, green: 0.31, blue: 0.08).opacity(0.45 * k)),
                                                                         (1, Color(red: 0.47, green: 0.12, blue: 0).opacity(0.2))]))
            var element = Path()
            element.move(to: CGPoint(x: wx + ww * 0.18, y: wy + wh * 0.22)); element.addLine(to: CGPoint(x: wx + ww * 0.82, y: wy + wh * 0.22))
            g.stroke(element, with: .color(Color(red: 1, green: 0.47, blue: 0.16).opacity(0.9 * k)), lineWidth: max(0.4, bw * 0.01))
        }
        g.stroke(box(wx + ww * 0.03, wy + wh * 0.05, ww * 0.94, wh * 0.9, top: bw * 0.008, bottom: bw * 0.008), with: .color(.white.opacity(0.1)), lineWidth: max(0.3, bw * 0.004))
        let rackColor = GraphicsContext.Shading.color(running ? Color(red: 1, green: 0.78, blue: 0.59).opacity(0.35) : .white.opacity(0.12))
        g.stroke(inner, with: rackColor, lineWidth: line)
        for k: CGFloat in [0.42, 0.62] {
            var rack = Path()
            rack.move(to: CGPoint(x: wx + ww * 0.14, y: wy + wh * k)); rack.addLine(to: CGPoint(x: wx + ww * 0.86, y: wy + wh * k))
            g.stroke(rack, with: rackColor, lineWidth: line)
        }
        g.fill(rect(wx, wy, ww, wh), with: linear(wx, wy, wx + ww, wy + wh, [(0, .white.opacity(0.12)), (0.35, .white.opacity(0.02)), (0.36, .white.opacity(0)), (1, .white.opacity(0))]))
        // The drawer, under a black line.
        let ry = dy + dh
        ctx.fill(rect(x, ry, bw, bh * 0.025), with: .color(rgb(0x141517)))
        ctx.fill(rect(x, ry + bh * 0.025, bw, y + bh - ry - bh * 0.025), with: linear(0, ry, 0, y + bh, [(0, rgb(0xF6F7F8)), (1, rgb(0xDCDFE2))]))
        ctx.fill(rect(x, ry + bh * 0.09, bw, bh * 0.012), with: .color(rgb(0x141517)))
        // A soft sheen across the white glass, darker towards the sides.
        let sheen = linear(x, 0, x + bw, 0, [(0, .black.opacity(0.1)), (0.08, .black.opacity(0)), (0.92, .black.opacity(0)), (1, .black.opacity(0.12))])
        ctx.fill(rect(x, sy, bw, dh + sh), with: sheen)
        ctx.fill(rect(x, ry + bh * 0.025, bw, y + bh - ry - bh * 0.025), with: sheen)
        ctx.stroke(rect(x, sy, bw, y + bh - sy), with: .color(.black.opacity(0.25)), lineWidth: line)
        feet(x + bw * 0.04, x + bw * 0.96, y + bh, bw * 0.06, h * 0.02)
    }

    // MARK: Washer and dryer, forest green

    func laundry(dryer: Bool, running: Bool) {
        let bw = min(w * 0.86, h * 0.82), bh = h * 0.9, x = (w - bw) / 2, y = h * 0.03, cx = w / 2
        shadowUnder(cx, y + bh + h * 0.02, bw * 0.65)
        // Chrome feet.
        let chrome = linear(0, y + bh, 0, y + bh + h * 0.025, [(0, rgb(0xC9CDD1)), (1, rgb(0x6D7277))])
        ctx.fill(rect(x + bw * 0.08, y + bh - h * 0.005, bw * 0.06, h * 0.025), with: chrome)
        ctx.fill(rect(x + bw * 0.86, y + bh - h * 0.005, bw * 0.06, h * 0.025), with: chrome)
        // The body: brushed forest green.
        let body = box(x, y, bw, bh, top: bw * 0.02, bottom: bw * 0.015)
        ctx.fill(body, with: linear(x, y, x + bw, y + bh, [(0, rgb(0x2F4538)), (0.45, rgb(0x1E3027)), (1, rgb(0x152219))]))
        brushed(body, x, y, bw, bh, vertical: false, 0.03)
        // The control panel: darker green glass, the detergent drawer (washer), a silver dial, a display.
        let ph = bh * 0.15
        ctx.fill(box(x, y, bw, ph, top: bw * 0.02, bottom: 0), with: linear(0, y, 0, y + ph, [(0, rgb(0x283C31)), (1, rgb(0x111C16))]))
        ctx.fill(rect(x, y, bw, ph * 0.08), with: .color(.white.opacity(0.08)))
        ctx.fill(rect(x, y + ph, bw, max(0.4, bh * 0.008)), with: .color(.black.opacity(0.45)))
        if !dryer {
            ctx.fill(rect(x + bw * 0.02, y + ph * 0.12, bw * 0.28, ph * 0.76), with: .color(.black.opacity(0.35)))
            ctx.fill(rect(x + bw * 0.3, y + ph * 0.12, max(0.3, bw * 0.004), ph * 0.76), with: .color(.white.opacity(0.12)))
        }
        let dial = CGPoint(x: x + bw * (dryer ? 0.48 : 0.5), y: y + ph * 0.5), dr = ph * 0.3
        ctx.fill(circle(dial, dr), with: radial(dial.x - dr * 0.3, dial.y - dr * 0.3, 0, dr * 1.2, [(0, .white), (0.5, rgb(0xC8CCD0)), (1, rgb(0x7B8086))]))
        ctx.stroke(circle(dial, dr), with: .color(.black.opacity(0.35)), lineWidth: max(0.3, dr * 0.08))
        ctx.draw(Text("SAMSUNG").font(.system(size: max(2, ph * 0.18), weight: .medium)).foregroundStyle(Color.white.opacity(0.75)),
                 at: CGPoint(x: x + bw * 0.07, y: dial.y), anchor: .leading)
        for i in 0..<(dryer ? 2 : 3) {
            ctx.fill(rect(x + bw * (0.7 + CGFloat(i) * 0.05), dial.y - ph * 0.12, bw * 0.022, ph * 0.26), with: .color(.white.opacity(0.8)))
        }
        ctx.fill(rect(x + bw * 0.6, dial.y - ph * 0.08, bw * 0.06, ph * 0.07), with: .color(.white.opacity(0.45)))
        ctx.fill(rect(x + bw * 0.6, dial.y + ph * 0.04, bw * 0.045, ph * 0.05), with: .color(.white.opacity(0.45)))
        // The Wi‑Fi mark.
        for k: CGFloat in [0.05, 0.09] {
            var arc = Path()
            arc.addArc(center: CGPoint(x: x + bw * 0.88, y: dial.y + ph * 0.06), radius: ph * k * 1.6, startAngle: .radians(.pi * 1.25), endAngle: .radians(.pi * 1.75), clockwise: false)
            ctx.stroke(arc, with: .color(.white.opacity(0.55)), lineWidth: max(0.25, ph * 0.03))
        }
        if running { ctx.fill(circle(CGPoint(x: x + bw * 0.4, y: dial.y), max(0.5, ph * 0.05)), with: .color(Color(red: 0.47, green: 0.86, blue: 1).opacity(0.9))) }

        // The door: a chrome ring round dark tinted glass, the drum inside.
        let dc = CGPoint(x: cx, y: y + ph + (bh - ph) * 0.44), R = bw * 0.42
        ctx.fill(circle(CGPoint(x: dc.x, y: dc.y + R * 0.02), R * 1.03), with: radial(dc.x, dc.y, R * 0.9, R * 1.03, [(0, .black.opacity(0.4)), (1, .black.opacity(0))]))
        ctx.fill(circle(dc, R), with: radial(dc.x - R * 0.3, dc.y - R * 0.35, 0, R * 1.2, [(0, rgb(0x2B3047)), (0.6, rgb(0x0D0F1C)), (1, rgb(0x05060B))]))
        ctx.stroke(circle(dc, R), with: linear(dc.x - R, dc.y - R, dc.x + R, dc.y + R, [(0, rgb(0xF4F6F8)), (0.5, rgb(0x8D9297)), (1, rgb(0xE6E8EA))]),
                   lineWidth: max(0.6, R * 0.035))
        // The wide dark rim inside the chrome ring, then the glass porthole with its own soft edge.
        ctx.fill(circle(dc, R * 0.97), with: radial(dc.x - R * 0.25, dc.y - R * 0.3, R * 0.2, R * 1.1, [(0, rgb(0x1B2036)), (0.7, rgb(0x0A0C17)), (1, rgb(0x04050A))]))
        ctx.fill(circle(dc, R * 0.74), with: radial(dc.x, dc.y, R * 0.66, R * 0.74, [(0, .white.opacity(0)), (0.5, .white.opacity(0.1)), (1, .white.opacity(0))]))
        let r2 = R * 0.62, angle = running ? t * (dryer ? 2.2 : 3.2) : 0
        var drum = ctx
        drum.clip(to: circle(dc, r2))
        drum.fill(circle(dc, r2), with: radial(dc.x, dc.y, 0, r2, [(0, rgb(0x1A1D24)), (1, rgb(0x0A0B0F))]))
        drum.translateBy(x: dc.x, y: dc.y)
        drum.rotate(by: .radians(angle))
        if !dryer {
            // Three curved lifters meeting at the hub, catching the light.
            for i in 0..<3 {
                var l = drum
                l.rotate(by: .radians(Double(i) * 2 * .pi / 3))
                var lifter = Path()
                lifter.move(to: CGPoint(x: -r2 * 0.1, y: r2 * 0.12))
                lifter.addQuadCurve(to: CGPoint(x: -r2 * 0.06, y: r2), control: CGPoint(x: -r2 * 0.2, y: r2 * 0.6))
                lifter.addLine(to: CGPoint(x: r2 * 0.08, y: r2))
                lifter.addQuadCurve(to: CGPoint(x: r2 * 0.1, y: r2 * 0.12), control: CGPoint(x: r2 * 0.18, y: r2 * 0.6))
                lifter.closeSubpath()
                l.fill(lifter, with: linear(-r2 * 0.15, 0, r2 * 0.15, 0, [(0, rgb(0x50555F, 0.4)), (0.5, rgb(0xDCE1EB, 0.75)), (1, rgb(0x50555F, 0.4))]))
            }
            drum.fill(circle(.zero, r2 * 0.14), with: .color(rgb(0x050608)))
            drum.stroke(circle(.zero, r2 * 0.14), with: .color(rgb(0xDCE1EB, 0.6)), lineWidth: max(0.4, r2 * 0.05))
        } else {
            // The baffle sweeping across the drum, and the vent mesh at the top right.
            var baffle = Path()
            baffle.move(to: CGPoint(x: -r2 * 0.35, y: -r2 * 0.95))
            baffle.addQuadCurve(to: CGPoint(x: r2 * 0.15, y: r2 * 0.95), control: CGPoint(x: -r2 * 0.25, y: r2 * 0.3))
            drum.stroke(baffle, with: .color(rgb(0xC8CDD7, 0.45)), lineWidth: max(0.6, r2 * 0.14))
            var edge = Path()
            edge.move(to: CGPoint(x: -r2 * 0.28, y: -r2 * 0.95))
            edge.addQuadCurve(to: CGPoint(x: r2 * 0.24, y: r2 * 0.95), control: CGPoint(x: -r2 * 0.16, y: r2 * 0.3))
            drum.stroke(edge, with: .color(.white.opacity(0.18)), lineWidth: max(0.3, r2 * 0.03))
            let vent = Path(ellipseIn: CGRect(x: -r2 * 0.28, y: -r2 * 0.18, width: r2 * 0.56, height: r2 * 0.36))
                .applying(CGAffineTransform(rotationAngle: 0.7).concatenating(CGAffineTransform(translationX: r2 * 0.52, y: -r2 * 0.55)))
            drum.fill(vent, with: .color(rgb(0x22252C)))
            var mesh = drum
            mesh.clip(to: vent)
            for i in -4...4 {
                for j in -3...3 {
                    mesh.fill(circle(CGPoint(x: r2 * 0.52 + CGFloat(i) * r2 * 0.06, y: -r2 * 0.55 + CGFloat(j) * r2 * 0.06), max(0.2, r2 * 0.018)),
                              with: .color(rgb(0xC8CDD7, 0.35)))
                }
            }
        }
        ctx.stroke(circle(dc, r2), with: .color(.white.opacity(0.12)), lineWidth: max(0.3, R * 0.02))
        // A reflection across the glass.
        var glass = ctx
        glass.clip(to: circle(dc, R * 0.97))
        glass.fill(rect(dc.x - R, dc.y - R, R * 2, R * 2), with: linear(dc.x - R, dc.y - R, dc.x + R * 0.2, dc.y + R * 0.2,
                                                                         [(0, .white.opacity(0.22)), (0.5, .white.opacity(0.03)), (0.51, .white.opacity(0))]))
        if !dryer {
            // The service panel at the bottom left.
            let panel = box(x + bw * 0.07, y + bh * 0.84, bw * 0.2, bh * 0.12, top: bw * 0.01, bottom: bw * 0.01)
            ctx.stroke(panel, with: .color(.black.opacity(0.4)), lineWidth: max(0.3, bw * 0.006))
        }
        ctx.stroke(body, with: .color(.white.opacity(0.12)), lineWidth: max(0.3, bw * 0.006))
    }
}
