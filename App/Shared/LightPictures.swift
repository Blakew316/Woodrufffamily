import SwiftUI
import WoodruffKit

extension GoveeLight {
    /// A Govee table lamp (a frosted cylinder shade on a gold base).
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

/// A Govee table lamp: a frosted cylinder shade, rounded at the top, on a short gold base. Turned on, its light
/// starts small at the centre of the shade and spreads outward to [level] 0…1, with a glow round it that grows with it.
struct TableLampPicture: View {
    var level: Double
    var lit: Bool
    var color: Color

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            let sw = w * 0.66, sh = h * 0.66
            let baseW = sw * 0.94, baseH = h * 0.2
            let shadeTop = h * 0.04
            let shadeMid = shadeTop + sh / 2
            let baseTop = shadeTop + sh
            // How far the light has spread: a little even at 1%, the whole shade at 100%.
            let glow = lit ? 0.2 + 0.8 * max(0, min(1, level)) : 0
            let shade = UnevenRoundedRectangle(topLeadingRadius: sw * 0.34, bottomLeadingRadius: sw * 0.06,
                                               bottomTrailingRadius: sw * 0.06, topTrailingRadius: sw * 0.34,
                                               style: .continuous)
            ZStack {
                // Its shadow on the table, and the light falling round it.
                Ellipse().fill(.black.opacity(0.35)).frame(width: baseW * 1.2, height: baseH * 0.4).blur(radius: 1.5)
                    .position(x: w / 2, y: baseTop + baseH)
                // The glow round the lamp, growing with the light.
                Ellipse().fill(color.opacity(0.6)).frame(width: sw * 1.9, height: sh * 1.5)
                    .blur(radius: max(4, w * 0.16))
                    .scaleEffect(0.3 + 0.7 * glow)
                    .opacity(glow)
                    .position(x: w / 2, y: shadeMid)
                // The shade: frosted glass, then lit from its centre outward.
                shade
                    .fill(LinearGradient(colors: [Color(white: 0.86), Color(white: 0.7), Color(white: 0.8)],
                                         startPoint: .leading, endPoint: .trailing))
                    .overlay {
                        shade.fill(color.mix(with: .white, by: 0.35)).opacity(glow * 0.75)
                    }
                    .overlay {
                        Circle()
                            .fill(RadialGradient(colors: [.white, color.mix(with: .white, by: 0.25), color.opacity(0)],
                                                 center: .center, startRadius: 0, endRadius: sw * 0.75))
                            .frame(width: sw * 1.5, height: sw * 1.5)
                            .scaleEffect(max(0.01, glow))
                            .opacity(glow)
                    }
                    .clipShape(shade)
                    .overlay { shade.stroke(.white.opacity(0.35), lineWidth: 0.5) }
                    .frame(width: sw, height: sh)
                    .position(x: w / 2, y: shadeMid)
                // The base: a short gold cylinder, catching the light from above.
                RoundedRectangle(cornerRadius: baseW * 0.08, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.45, green: 0.28, blue: 0.08), Color(red: 0.96, green: 0.77, blue: 0.42),
                                                  Color(red: 0.72, green: 0.5, blue: 0.2), Color(red: 0.42, green: 0.26, blue: 0.08)],
                                         startPoint: .leading, endPoint: .trailing))
                    .overlay(alignment: .top) {
                        RoundedRectangle(cornerRadius: baseW * 0.08, style: .continuous)
                            .fill(LinearGradient(colors: [color.opacity(0.8), .clear], startPoint: .top, endPoint: .bottom))
                            .frame(height: baseH * 0.6)
                            .opacity(glow)
                    }
                    .frame(width: baseW, height: baseH)
                    .position(x: w / 2, y: baseTop + baseH / 2)
            }
            .frame(width: w, height: h)
        }
        // Turned on or off slowly; a new brightness quicker, so dragging it keeps up.
        .animation(.easeInOut(duration: 1.2), value: lit)
        .animation(.easeOut(duration: 0.35), value: level)
    }
}

/// Govee string lights: six bulbs on a dark cord that loops between them, hanging diagonally down from the top left.
/// Turned on, the bulbs light one after another down the string, each starting dim and small, its glow growing with
/// [level] 0…1.
struct StringLightsPicture: View {
    var level: Double
    var lit: Bool
    var color: Color
    var count = 6

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            let n = max(2, count)
            let bw = min(w / (CGFloat(n) * 1.15), h * 0.3)
            let bh = bw * 1.22
            let capW = bw * 0.56, capH = bw * 0.46
            let left = bw * 0.65, right = w - bw * 0.65
            let dx = (right - left) / CGFloat(n - 1)
            let top = h * 0.1
            let last = max(top, h - bh - capH - h * 0.02)
            let points = (0..<n).map { i in
                CGPoint(x: left + dx * CGFloat(i), y: top + (last - top) * CGFloat(i) / CGFloat(n - 1))
            }
            let glow = lit ? 0.15 + 0.85 * max(0, min(1, level)) : 0
            ZStack {
                // The cord: a loop up and over between each pair of bulbs.
                Path { p in
                    p.move(to: CGPoint(x: points[0].x - dx * 0.45, y: points[0].y - dx * 0.25))
                    p.addQuadCurve(to: points[0], control: CGPoint(x: points[0].x - dx * 0.1, y: points[0].y - dx * 0.3))
                    for i in 1..<n {
                        let a = points[i - 1], b = points[i]
                        p.addQuadCurve(to: b, control: CGPoint(x: (a.x + b.x) / 2, y: min(a.y, b.y) - dx * 0.55))
                    }
                }
                .stroke(Color(white: 0.28), style: StrokeStyle(lineWidth: max(1, bw * 0.13), lineCap: .round, lineJoin: .round))
                ForEach(0..<n, id: \.self) { i in
                    bulb(bw: bw, bh: bh, capW: capW, capH: capH, glow: glow)
                        // One after another down the string as it turns on; all together as it turns off.
                        .animation(.easeOut(duration: 0.9).delay(lit ? Double(i) * 0.12 : 0), value: lit)
                        .animation(.easeOut(duration: 0.35), value: level)
                        .position(x: points[i].x, y: points[i].y + (capH + bh) / 2)
                }
            }
            .frame(width: w, height: h)
        }
    }

    /// One bulb under its socket: frosted glass off; lit in the light's colour with a glow round it.
    private func bulb(bw: CGFloat, bh: CGFloat, capW: CGFloat, capH: CGFloat, glow: Double) -> some View {
        VStack(spacing: -bh * 0.06) {
            RoundedRectangle(cornerRadius: capW * 0.22, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.2), Color(white: 0.08)], startPoint: .leading, endPoint: .trailing))
                .frame(width: capW, height: capH)
                .zIndex(1)
            Ellipse()
                .fill(LinearGradient(colors: [Color(red: 0.95, green: 0.82, blue: 0.95), Color(red: 0.78, green: 0.86, blue: 1),
                                              Color(red: 0.8, green: 0.98, blue: 0.9)],
                                     startPoint: .top, endPoint: .bottom))
                .opacity(0.55)
                .overlay {
                    Ellipse()
                        .fill(RadialGradient(colors: [.white, color.mix(with: .white, by: 0.2), color],
                                             center: UnitPoint(x: 0.4, y: 0.35), startRadius: 0, endRadius: bw * 0.7))
                        .opacity(glow)
                }
                .frame(width: bw, height: bh)
                .background {
                    Circle().fill(color.opacity(0.75))
                        .frame(width: bw * 2.6, height: bw * 2.6)
                        .blur(radius: max(2, bw * 0.5))
                        .scaleEffect(0.25 + 0.75 * glow)
                        .opacity(glow)
                }
        }
    }
}
