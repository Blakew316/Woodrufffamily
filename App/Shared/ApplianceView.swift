import SwiftUI
import WoodruffKit

// Samsung appliances, each with its own controls (what SmartThings says it supports) and a little moving
// picture of it at work: the drum turning, the dryer tumbling, the dishwasher spraying, the oven glowing.

// MARK: - The moving pictures

struct ApplianceArt: View {
    var kind: HomeDevice.Kind
    var running: Bool
    var alert = false
    /// Drawn at most this often: 30 times a second on the appliance's page, 20 on a tile (smooth at those sizes,
    /// and far less work than every frame of the display).
    var minimumInterval: Double = 1.0 / 30
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static func animates(_ k: HomeDevice.Kind) -> Bool {
        [.washer, .dryer, .dishwasher, .oven, .fridge, .aircon, .vacuum, .fan].contains(k)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: minimumInterval, paused: !running || reduceMotion || !Fleet.shared.isActive)) { tl in
            let t = running && !reduceMotion ? tl.date.timeIntervalSinceReferenceDate : 0
            Canvas { ctx, size in draw(&ctx, size, t) }
        }
        .background(background)
    }

    private var background: some View {
        LinearGradient(colors: bg, startPoint: .top, endPoint: .bottom)
    }

    private var bg: [Color] {
        if alert { return [Color(red: 0.45, green: 0.08, blue: 0.08), Color(red: 0.2, green: 0.02, blue: 0.02)] }
        switch kind {
        case .oven: return running ? [Color(red: 0.35, green: 0.12, blue: 0.02), .black] : [Color(white: 0.16), .black]
        case .fridge: return [Color(red: 0.08, green: 0.16, blue: 0.24), Color(red: 0.02, green: 0.05, blue: 0.1)]
        case .aircon: return [Color(red: 0.06, green: 0.14, blue: 0.22), .black]
        default: return [Color(white: 0.16), Color(white: 0.05)]
        }
    }

    private func draw(_ ctx: inout GraphicsContext, _ size: CGSize, _ t: Double) {
        let w = size.width, h = size.height, c = CGPoint(x: w / 2, y: h / 2), r = min(w, h) * 0.36
        switch kind {
        case .washer, .dryer:
            // The door, and what's inside it turning.
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r - 4, y: c.y - r - 4, width: (r + 4) * 2, height: (r + 4) * 2)), with: .color(.white.opacity(0.35)), lineWidth: max(1.5, r * 0.08))
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)), with: .color(.white.opacity(0.06)))
            var inner = ctx
            inner.clip(to: Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)))
            if kind == .washer {
                // Water sloshing with the drum.
                let level = c.y + r * 0.15 + sin(t * 2.2) * r * 0.06
                var water = Path()
                water.move(to: CGPoint(x: c.x - r, y: level))
                for x in stride(from: -r, through: r, by: 2) {
                    water.addLine(to: CGPoint(x: c.x + x, y: level + sin(x / r * 3 + t * 6) * r * 0.08))
                }
                water.addLine(to: CGPoint(x: c.x + r, y: c.y + r)); water.addLine(to: CGPoint(x: c.x - r, y: c.y + r)); water.closeSubpath()
                inner.fill(water, with: .linearGradient(Gradient(colors: [Color(red: 0.35, green: 0.7, blue: 1).opacity(0.8), Color(red: 0.1, green: 0.35, blue: 0.8)]),
                                                        startPoint: CGPoint(x: c.x, y: level), endPoint: CGPoint(x: c.x, y: c.y + r)))
                // Bubbles rising.
                for i in 0..<6 {
                    let p = (t * 0.6 + Double(i) / 6).truncatingRemainder(dividingBy: 1)
                    let x = c.x + sin(Double(i) * 2.1 + t) * r * 0.5
                    let y = c.y + r - p * r * 1.2
                    let b = r * 0.07 * (0.6 + Double(i % 3) * 0.2)
                    inner.stroke(Path(ellipseIn: CGRect(x: x - b, y: y - b, width: b * 2, height: b * 2)), with: .color(.white.opacity(0.6 * (1 - p))), lineWidth: 1)
                }
            } else {
                // Clothes tumbling, with the warmth of the dryer.
                inner.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                           with: .radialGradient(Gradient(colors: [Color.orange.opacity(0.35), .clear]), center: c, startRadius: 0, endRadius: r))
                let colors: [Color] = [.blue, .pink, .mint, .yellow]
                for i in 0..<4 {
                    let a = t * 2.4 + Double(i) * .pi / 2
                    let fall = abs(sin(a)) * r * 0.25
                    let p = CGPoint(x: c.x + cos(a) * r * 0.55, y: c.y + sin(a) * r * 0.55 + fall)
                    var item = Path(roundedRect: CGRect(x: -r * 0.18, y: -r * 0.12, width: r * 0.36, height: r * 0.24), cornerRadius: r * 0.06)
                    item = item.applying(CGAffineTransform(rotationAngle: a * 1.5)).applying(CGAffineTransform(translationX: p.x, y: p.y))
                    inner.fill(item, with: .color(colors[i].opacity(0.85)))
                }
            }
            // Drum ribs turning.
            for i in 0..<3 {
                let a = t * (kind == .washer ? 3 : 2.4) + Double(i) * 2 * .pi / 3
                var rib = Path()
                rib.move(to: CGPoint(x: c.x + cos(a) * r * 0.8, y: c.y + sin(a) * r * 0.8))
                rib.addLine(to: CGPoint(x: c.x + cos(a) * r * 0.98, y: c.y + sin(a) * r * 0.98))
                inner.stroke(rib, with: .color(.white.opacity(0.5)), lineWidth: max(1.5, r * 0.08))
            }
        case .dishwasher:
            // Spray arms throwing water up.
            let base = h * 0.78
            ctx.fill(Path(roundedRect: CGRect(x: w * 0.2, y: base, width: w * 0.6, height: max(2, h * 0.04)), cornerRadius: 2), with: .color(.white.opacity(0.5)))
            for i in 0..<14 {
                let p = (t * 0.9 + Double(i) / 14).truncatingRemainder(dividingBy: 1)
                let spread = (Double(i % 7) - 3) / 3
                let x = c.x + spread * w * 0.3 * p + sin(t * 4 + Double(i)) * w * 0.02
                let y = base - sin(p * .pi) * h * 0.6
                let d = max(1.5, w * 0.025)
                ctx.fill(Path(ellipseIn: CGRect(x: x - d / 2, y: y - d, width: d, height: d * 1.6)), with: .color(Color(red: 0.5, green: 0.8, blue: 1).opacity(0.85 * (1 - p * 0.6))))
            }
        case .oven:
            // The window, the elements glowing, warm air rising.
            let win = CGRect(x: w * 0.15, y: h * 0.25, width: w * 0.7, height: h * 0.55)
            ctx.stroke(Path(roundedRect: win, cornerRadius: w * 0.05), with: .color(.white.opacity(0.35)), lineWidth: max(1.5, w * 0.025))
            let glow = 0.55 + 0.25 * sin(t * 2)
            ctx.fill(Path(roundedRect: win.insetBy(dx: 2, dy: 2), cornerRadius: w * 0.04),
                     with: .linearGradient(Gradient(colors: [Color.orange.opacity(running ? glow : 0.1), Color.red.opacity(running ? glow * 0.6 : 0.05)]),
                                           startPoint: CGPoint(x: c.x, y: win.minY), endPoint: CGPoint(x: c.x, y: win.maxY)))
            if running {
                for i in 0..<3 {
                    var wave = Path()
                    let x0 = win.minX + win.width * (0.25 + Double(i) * 0.25)
                    let off = (t * 0.5 + Double(i) * 0.33).truncatingRemainder(dividingBy: 1)
                    wave.move(to: CGPoint(x: x0, y: win.maxY - 4 - off * win.height * 0.3))
                    for k in 1...12 {
                        let y = win.maxY - 4 - off * win.height * 0.3 - Double(k) * win.height * 0.05
                        wave.addLine(to: CGPoint(x: x0 + sin(Double(k) * 0.9 + t * 4) * w * 0.03, y: y))
                    }
                    ctx.stroke(wave, with: .color(.white.opacity(0.35 * (1 - off))), lineWidth: max(1, w * 0.012))
                }
            }
        case .fridge:
            // Snowflakes drifting down.
            for i in 0..<10 {
                let p = (t * 0.12 + Double(i) / 10).truncatingRemainder(dividingBy: 1)
                let x = w * (0.1 + 0.8 * (Double((i * 37) % 10) / 10)) + sin(t + Double(i)) * w * 0.04
                let y = p * h
                let s = max(2, w * 0.04) * (0.6 + Double(i % 3) * 0.2)
                var flake = Path()
                for k in 0..<3 {
                    let a = Double(k) * .pi / 3 + t * 0.5
                    flake.move(to: CGPoint(x: x - cos(a) * s, y: y - sin(a) * s))
                    flake.addLine(to: CGPoint(x: x + cos(a) * s, y: y + sin(a) * s))
                }
                ctx.stroke(flake, with: .color(.white.opacity(0.7)), lineWidth: 1)
            }
        case .aircon, .fan:
            // Air flowing out.
            for i in 0..<5 {
                let y0 = h * (0.2 + Double(i) * 0.15)
                var line = Path()
                let off = (t * 0.6 + Double(i) * 0.2).truncatingRemainder(dividingBy: 1)
                let start = -w * 0.3 + off * w * 1.3
                line.move(to: CGPoint(x: start, y: y0))
                for k in 1...10 {
                    let x = start + Double(k) * w * 0.05
                    line.addLine(to: CGPoint(x: x, y: y0 + sin(Double(k) * 0.8 + t * 3) * h * 0.03))
                }
                ctx.stroke(line, with: .color(Color(red: 0.6, green: 0.85, blue: 1).opacity(0.7)), style: StrokeStyle(lineWidth: max(1.5, h * 0.025), lineCap: .round))
            }
        case .vacuum:
            // Going round the room, leaving a clean trail.
            let a = t * 0.9
            let p = CGPoint(x: c.x + cos(a) * w * 0.28, y: c.y + sin(a * 1.6) * h * 0.25)
            for k in 1...12 {
                let b = a - Double(k) * 0.08
                let q = CGPoint(x: c.x + cos(b) * w * 0.28, y: c.y + sin(b * 1.6) * h * 0.25)
                let d = r * 0.35
                ctx.fill(Path(ellipseIn: CGRect(x: q.x - d, y: q.y - d, width: d * 2, height: d * 2)), with: .color(.white.opacity(0.05 * Double(12 - k) / 12)))
            }
            let d = r * 0.4
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - d, y: p.y - d, width: d * 2, height: d * 2)), with: .color(.white.opacity(0.9)))
            ctx.stroke(Path(ellipseIn: CGRect(x: p.x - d * 0.5, y: p.y - d * 0.5, width: d, height: d)), with: .color(.black.opacity(0.4)), lineWidth: 1)
        default:
            break
        }
    }
}

// MARK: - The page

/// A Samsung appliance: the picture of it working, what it's doing, and the controls it has.
struct ApplianceView: View {
    var device: HomeDevice
    var inSheet = false
    @Environment(\.dismiss) private var dismiss
    private let st = SmartThings.shared

    private var id: String { device.id }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                hero
                if !device.reachable {
                    Text("SmartThings can't reach the \(kindName) right now. Check it has power and is on Wi‑Fi; its controls come back when it does.")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal)
                } else if isMachine && !device.remoteControl {
                    Text("Remote Control is off. Press Remote Control (Smart Control) on the \(kindName) to start it or change its settings from here.")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal)
                }
                options
                    .disabled(!device.reachable)
                NameRoomCard(id: device.id, current: device.name, original: nil)
                if let e = st.commandError[id] ?? st.error { Text(e).font(.footnote).foregroundStyle(Palette.attention).multilineTextAlignment(.center) }
            }
            .padding(16)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background { ArtBackdrop(url: nil) }
        .environment(\.colorScheme, .dark)
        .navigationTitle(device.name)
        .inlineTitle()
        .toolbar {
            if inSheet { ToolbarItem(placement: .cancellationAction) { Button(role: .close) { dismiss() } } }
        }
        .refreshable { await st.refresh(full: false) }
    }

    private var isMachine: Bool { [.washer, .dryer, .dishwasher, .oven].contains(device.kind) }

    private var kindName: String {
        switch device.kind {
        case .washer: return "washer"
        case .dryer: return "dryer"
        case .dishwasher: return "dishwasher"
        case .oven: return "oven"
        case .fridge: return "fridge"
        default: return "device"
        }
    }

    // MARK: Hero

    private var hero: some View {
        VStack(spacing: 14) {
            ApplianceArt(kind: device.kind, running: device.isRunning, alert: device.alert)
                .frame(height: 190)
                .overlay {
                    // Nothing to animate for this kind (a plug, a switch, a sensor): its symbol, not an empty picture.
                    if !ApplianceArt.animates(device.kind) {
                        Image(systemName: deviceSymbol(device))
                            .font(.system(size: 56, weight: .semibold))
                            .foregroundStyle(device.isOn == true ? Color.orange : Color.white.opacity(0.8))
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    if device.isRunning {
                        Text("Running").font(.caption.weight(.bold)).padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Capsule().fill(.green.opacity(0.85))).padding(10)
                    }
                }
            VStack(spacing: 4) {
                HStack(spacing: 8) {
                    Text(device.reachable ? device.status : "Not Responding").font(.title3.weight(.semibold)).multilineTextAlignment(.center)
                    if st.pending.contains(id) { ProgressView().controlSize(.small) }
                }
                if let end = device.endsAt, end > .now, device.machineState == "run" {
                    Text("Done at \(end.formatted(date: .omitted, time: .shortened))").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            if let end = device.endsAt, end > .now, device.machineState == "run" {
                Text(timerInterval: Date.now...end, countsDown: true)
                    .font(.system(size: 40, weight: .semibold)).monospacedDigit()
            }
            transport
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .glass(RoundedRectangle(cornerRadius: 28, style: .continuous), interactive: false)
        .animation(.smooth, value: device.isRunning)
    }

    @ViewBuilder private var transport: some View {
        switch device.kind {
        case .washer, .dryer, .dishwasher, .oven:
            let running = device.machineState == "run", paused = device.machineState == "pause"
            HStack(spacing: 12) {
                if running && device.kind != .oven {
                    Button("Pause") { st.machine(device, "pause") }.buttonStyle(.glass)
                } else if !running {
                    Button(paused ? "Resume" : "Start") { st.machine(device, "run") }
                        .buttonStyle(.glassProminent)
                }
                if running || paused {
                    Button("Stop", role: .destructive) { st.machine(device, "stop") }.buttonStyle(.glass)
                }
            }
            .disabled(!device.reachable || !device.remoteControl || st.pending.contains(id))
        case .vacuum:
            HStack(spacing: 12) {
                if device.mode == "cleaning" {
                    Button("Pause") { vacuum("pause") }.buttonStyle(.glass)
                } else {
                    Button("Clean") { vacuum("cleaning") }.buttonStyle(.glassProminent)
                }
                Button("Send Home") { vacuum("homing") }.buttonStyle(.glass)
            }
            .disabled(!device.reachable)
        default:
            if let on = device.isOn {
                Toggle(on ? "On" : "Off", isOn: Binding(get: { on }, set: { st.power(device, $0) }))
                    .toggleStyle(.switch).frame(maxWidth: 220)
                    .disabled(!device.reachable)
            }
        }
    }

    private func vacuum(_ move: String) {
        st.command(device, "robotCleanerMovement", "setRobotCleanerMovement", [move], sets: "robotCleanerMovement", to: move)
    }

    // MARK: Options

    /// A setting the appliance offers: its current value, what it can be, and how to change it.
    struct Choice {
        var title: String
        var cap: String
        var attr: String
        var supported: String
        var command: String
        var component = "main"
    }

    private var choices: [Choice] {
        switch device.kind {
        case .washer: return [
            Choice(title: "Cycle", cap: "samsungce.washerCycle", attr: "washerCycle", supported: "supportedCycles", command: "setWasherCycle"),
            Choice(title: "Water Temperature", cap: "custom.washerWaterTemperature", attr: "washerWaterTemperature", supported: "supportedWasherWaterTemperature", command: "setWasherWaterTemperature"),
            Choice(title: "Spin", cap: "custom.washerSpinLevel", attr: "washerSpinLevel", supported: "supportedWasherSpinLevel", command: "setWasherSpinLevel"),
            Choice(title: "Rinses", cap: "custom.washerRinseCycles", attr: "washerRinseCycles", supported: "supportedWasherRinseCycles", command: "setWasherRinseCycles"),
            Choice(title: "Soil Level", cap: "custom.washerSoilLevel", attr: "washerSoilLevel", supported: "supportedWasherSoilLevel", command: "setWasherSoilLevel"),
        ]
        case .dryer: return [
            Choice(title: "Cycle", cap: "samsungce.dryerCycle", attr: "dryerCycle", supported: "supportedCycles", command: "setDryerCycle"),
            Choice(title: "Dry Level", cap: "custom.dryerDryLevel", attr: "dryerDryLevel", supported: "supportedDryerDryLevel", command: "setDryerDryLevel"),
            Choice(title: "Temperature", cap: "samsungce.dryerDryingTemperature", attr: "dryingTemperature", supported: "supportedDryingTemperature", command: "setDryingTemperature"),
        ]
        case .dishwasher: return [
            Choice(title: "Course", cap: "samsungce.dishwasherWashingCourse", attr: "washingCourse", supported: "supportedCourses", command: "setWashingCourse"),
        ]
        case .oven: return [
            Choice(title: "Mode", cap: "ovenMode", attr: "ovenMode", supported: "supportedOvenModes", command: "setOvenMode"),
        ]
        case .aircon: return [
            Choice(title: "Mode", cap: "airConditionerMode", attr: "airConditionerMode", supported: "supportedAcModes", command: "setAirConditionerMode"),
            Choice(title: "Fan", cap: "airConditionerFanMode", attr: "fanMode", supported: "supportedAcFanModes", command: "setFanMode"),
        ]
        case .vacuum: return [
            Choice(title: "Cleaning Mode", cap: "robotCleanerCleaningMode", attr: "robotCleanerCleaningMode", supported: "supportedCleaningModes", command: "setRobotCleanerCleaningMode"),
            Choice(title: "Suction", cap: "robotCleanerTurboMode", attr: "robotCleanerTurboMode", supported: "supportedTurboModes", command: "setRobotCleanerTurboMode"),
        ]
        case .fan: return [
            Choice(title: "Fan", cap: "airPurifierFanMode", attr: "airPurifierFanMode", supported: "supportedAirPurifierFanModes", command: "setAirPurifierFanMode"),
        ]
        default: return []
        }
    }

    /// The values a choice can take (plain words, or Samsung's cycle objects).
    private func values(_ c: Choice) -> [String] {
        guard let v = st.read(id, c.cap, c.supported, in: c.component) else { return [] }
        if let list = v as? [String] { return list }
        if let objs = v as? [[String: Any]] {
            return objs.compactMap { ($0["cycle"] ?? $0["course"] ?? $0["mode"] ?? $0["value"]) as? String }
        }
        return []
    }

    @ViewBuilder private var options: some View {
        let available = choices.filter { st.has(id, $0.cap, in: $0.component) && !values($0).isEmpty }
        let setpoints = setpointRows
        let toggles = toggleRows
        if !available.isEmpty || !setpoints.isEmpty || !toggles.isEmpty {
            GlassCard(title: "Settings") {
                ForEach(available, id: \.cap) { c in
                    let current = st.read(id, c.cap, c.attr, in: c.component) as? String
                    HStack {
                        Text(c.title)
                        Spacer()
                        Menu {
                            ForEach(values(c), id: \.self) { v in
                                Button { st.command(device, c.cap, c.command, [v], component: c.component, sets: c.attr, to: v) } label: {
                                    if v == current { Label(pretty(v), systemImage: "checkmark") } else { Text(pretty(v)) }
                                }
                            }
                        } label: {
                            Text(current.map(pretty) ?? "Choose").padding(.horizontal, 12).padding(.vertical, 6)
                        }
                        .menuStyle(.button).buttonStyle(.glass).fixedSize()
                        .disabled(isMachine && !device.remoteControl)
                    }
                }
                ForEach(setpoints, id: \.title) { s in
                    SetpointRow(spec: s, device: device).disabled(device.kind == .oven && !device.remoteControl)
                }
                ForEach(toggles, id: \.title) { t in
                    Toggle(t.title, isOn: Binding(
                        get: { (st.read(id, t.cap, t.attr, in: t.component) as? String) == "on" },
                        set: { on in
                            // A plain switch (power, the ice maker) has its own on and off commands.
                            if t.cap == "switch" { st.power(device, on, component: t.component) }
                            else { st.command(device, t.cap, t.command, t.args(on), component: t.component, sets: t.attr, to: on ? "on" : "off") }
                        }))
                }
            }
        }
    }

    struct ToggleSpec {
        var title: String, cap: String, attr: String, command: String, component = "main"
        var args: (Bool) -> [Any] = { [$0 ? "on" : "off"] }
    }

    private var toggleRows: [ToggleSpec] {
        var out: [ToggleSpec] = []
        // A washer, dryer, dishwasher or oven that switches: its power (the tile's tap opens this page instead).
        if isMachine, device.isOn != nil, st.has(id, "switch") {
            out.append(ToggleSpec(title: "Power", cap: "switch", attr: "switch", command: "on"))
        }
        switch device.kind {
        case .fridge:
            if st.has(id, "refrigeration") {
                out.append(ToggleSpec(title: "Power Cool", cap: "refrigeration", attr: "rapidCooling", command: "setRapidCooling"))
                out.append(ToggleSpec(title: "Power Freeze", cap: "refrigeration", attr: "rapidFreezing", command: "setRapidFreezing"))
            }
            if st.has(id, "switch", in: "icemaker") {
                var t = ToggleSpec(title: "Ice Maker", cap: "switch", attr: "switch", command: "on", component: "icemaker")
                t.args = { _ in [] }
                out.append(t)
            }
        case .dryer:
            if st.has(id, "custom.dryerWrinklePrevent") {
                out.append(ToggleSpec(title: "Wrinkle Prevent", cap: "custom.dryerWrinklePrevent", attr: "dryerWrinklePrevent", command: "setDryerWrinklePrevent"))
            }
        default: break
        }
        return out
    }

    private var setpointRows: [SetpointSpec] {
        var out: [SetpointSpec] = []
        switch device.kind {
        case .fridge:
            for (comp, title, lo, hi) in [("cooler", "Fridge", 33.0, 44.0), ("freezer", "Freezer", -8.0, 5.0)] where st.has(id, "thermostatCoolingSetpoint", in: comp) {
                out.append(SetpointSpec(title: title, cap: "thermostatCoolingSetpoint", attr: "coolingSetpoint", command: "setCoolingSetpoint", component: comp, fahrenheit: lo...hi))
            }
        case .oven:
            if st.has(id, "ovenSetpoint") {
                out.append(SetpointSpec(title: "Temperature", cap: "ovenSetpoint", attr: "ovenSetpoint", command: "setOvenSetpoint", component: "main", fahrenheit: 170...550, step: 5))
            }
        case .aircon:
            if st.has(id, "thermostatCoolingSetpoint") {
                out.append(SetpointSpec(title: "Cool To", cap: "thermostatCoolingSetpoint", attr: "coolingSetpoint", command: "setCoolingSetpoint", component: "main", fahrenheit: 60...86))
            }
        default: break
        }
        return out
    }

    /// "quickWash" → "Quick Wash", "Table_00_Course_5B" → "Course 5B", "extraHigh" → "Extra High".
    private func pretty(_ s: String) -> String {
        if let r = s.range(of: "Course_") { return "Course " + s[r.upperBound...] }
        var out = ""
        for ch in s.replacingOccurrences(of: "_", with: " ") {
            if ch.isUppercase, let last = out.last, last.isLowercase { out.append(" ") }
            out.append(ch)
        }
        return out.prefix(1).uppercased() + out.dropFirst()
    }
}

struct SetpointSpec {
    var title: String, cap: String, attr: String, command: String, component: String
    var fahrenheit: ClosedRange<Double>
    var step: Double = 1
}

/// A temperature to set, − and + either side, in the appliance's own units.
struct SetpointRow: View {
    var spec: SetpointSpec
    var device: HomeDevice
    private let st = SmartThings.shared

    var body: some View {
        let value = (st.read(device.id, spec.cap, spec.attr, in: spec.component) as? NSNumber)?.doubleValue
        let unit = st.unit(device.id, spec.cap, spec.attr, in: spec.component) ?? "F"
        let range = unit == "C" ? ((spec.fahrenheit.lowerBound - 32) * 5 / 9).rounded()...((spec.fahrenheit.upperBound - 32) * 5 / 9).rounded() : spec.fahrenheit
        HStack {
            Text(spec.title)
            Spacer()
            if let v = value {
                Button { set(max(range.lowerBound, v - spec.step)) } label: { Image(systemName: "minus").frame(width: 30, height: 30) }
                    .buttonStyle(.glass).disabled(v <= range.lowerBound)
                Text("\(Int(v))°\(unit)").font(.body.monospacedDigit().weight(.semibold)).frame(minWidth: 56)
                Button { set(min(range.upperBound, v + spec.step)) } label: { Image(systemName: "plus").frame(width: 30, height: 30) }
                    .buttonStyle(.glass).disabled(v >= range.upperBound)
            } else {
                Text("—").foregroundStyle(.secondary)
            }
        }
    }

    private func set(_ v: Double) {
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
        let n = Int(v.rounded())
        st.command(device, spec.cap, spec.command, [n], component: spec.component, sets: spec.attr, to: NSNumber(value: n))
    }
}
