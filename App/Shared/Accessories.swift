import SwiftUI
import WoodruffKit

// Everything else in the house: Apple Home accessories (plugs, locks, thermostats, sensors, blinds, HomePod
// temperature…) and Samsung SmartThings appliances (washer, dryer, fridge…), as tiles on Home.



/// Where each source's devices are kept between launches (on this device only: they're never synced).
private enum SavedDevices {
    static let home = "devicesHome"
    static let smartThings = "devicesSmartThings"
    static let dreo = "devicesDreo"

    /// What a source said last time, while it's still signed in (never in Demo mode).
    static func load(_ key: String, signedIn: Bool) -> [HomeDevice] {
        guard signedIn, !Demo.isOn else { return [] }
        return Saved.load(key, as: [HomeDevice].self) ?? []
    }
}

@Observable @MainActor
final class AccessoryStore {
    static let shared = AccessoryStore()

    // Each source's devices start as it last said (kept for the next launch), so Home shows every device at once and
    // is drawn once, rather than again as each source answers. The sources only set these when something changed.
    var fromHome: [HomeDevice] = SavedDevices.load(SavedDevices.home, signedIn: true) {
        didSet { changed(SavedDevices.home, fromHome) }
    }
    var fromSmartThings: [HomeDevice] = SavedDevices.load(SavedDevices.smartThings, signedIn: Keychain.get("st.refresh") != nil || Keychain.get("st.token") != nil) {
        didSet { changed(SavedDevices.smartThings, fromSmartThings) }
    }
    var fromDreo: [HomeDevice] = SavedDevices.load(SavedDevices.dreo, signedIn: Keychain.get("dreo.email") != nil && Keychain.get("dreo.password") != nil) {
        didSet { changed(SavedDevices.dreo, fromDreo) }
    }
    /// Carries out a change to an Apple Home accessory (set by the iPhone app).
    @ObservationIgnored var homeControl: ((HomeDevice, DeviceCommand) -> Void)?
    /// Why Apple Home has nothing to show on this iPhone (no permission, no home yet); nil when it's fine.
    var homeProblem: String?

    /// Every device as `all` gives it, and each one's place in it by id: made again only when a source or a name
    /// changes (Home reads it many times each time it's drawn).
    @ObservationIgnored private var made: [HomeDevice] = []
    @ObservationIgnored private var place: [String: Int] = [:]
    /// The family's names `made` was made with; nil until it's made.
    @ObservationIgnored private var madeWith: [String: String]?
    /// What's kept on disk for each source (written again only when that source changes).
    @ObservationIgnored private var kept: [String: [HomeDevice]] = [:]

    init() {
        kept = [SavedDevices.home: fromHome, SavedDevices.smartThings: fromSmartThings, SavedDevices.dreo: fromDreo]
        // The rooms the kept devices report, for Home's first drawing.
        zones()
    }

    /// The house's thermostat (the ecobee): one that's responding first, Apple Home's before SmartThings'.
    var thermostat: HomeDevice? {
        let list = all.filter { $0.kind == .thermostat }
        return list.first { $0.reachable && $0.source == "home" } ?? list.first { $0.reachable } ?? list.first
    }

    /// Every device, by the names the family gave them, in name order.
    var all: [HomeDevice] {
        // The sources and the names are read every time, so whatever shows devices redraws when any of them changes;
        // the list itself is only made again when one of them did.
        _ = (fromHome.count, fromSmartThings.count, fromDreo.count)
        let names = SmartHome.shared.names
        if madeWith != names { make(names) }
        return made
    }

    func device(_ id: String) -> HomeDevice? {
        let list = all
        return place[id].map { list[$0] }
    }

    func send(_ d: HomeDevice, _ c: DeviceCommand) {
        switch d.source {
        case "home":
            // Only the iPhone reaches Apple Home; it's set as soon as Apple Home starts there.
            if let control = homeControl { control(d, c) }
        case "dreo": Dreo.shared.send(d, c)
        default: SmartThings.shared.send(d, c)
        }
    }

    private func make(_ names: [String: String]) {
        // An ecobee linked to both Apple Home and SmartThings shows once (the Apple Home one).
        let homeThermostats = Set(fromHome.filter { $0.kind == .thermostat }.map { $0.name.lowercased() })
        let st = fromSmartThings.filter { !($0.kind == .thermostat && homeThermostats.contains($0.name.lowercased())) }
        let list = (fromHome + st + fromDreo).map { d -> HomeDevice in
            var d = d
            if let n = names[d.id], !n.isEmpty { d.name = n }
            return d
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        var ids: [String: Int] = [:]
        for (i, d) in list.enumerated() where ids[d.id] == nil { ids[d.id] = i }
        made = list
        place = ids
        madeWith = names
    }

    /// A source changed: the list is made again, the rooms the devices report go to SmartHome, and what the source
    /// said is kept for the next launch.
    private func changed(_ key: String, _ list: [HomeDevice]) {
        make(SmartHome.shared.names)
        zones()
        guard kept[key] != list, !Demo.isOn else { return }
        kept[key] = list
        Saved.save(key, list)
    }

    private func zones() {
        var z: [String: String] = [:]
        for d in fromHome + fromSmartThings + fromDreo { if let r = d.zone { z[d.id] = r } }
        // Only a real change: every room on Home is worked out again from these.
        if SmartHome.shared.externalZones != z { SmartHome.shared.externalZones = z }
    }
}

/// "70°" in the family's units.

// MARK: - Home section

struct DevicesSection: View {
    var room: String? = nil
    /// Only the favourites (Home's Favorites).
    var favorites = false
    /// Off inside a room on Home (the room is the heading).
    var titled = true
    private let store = AccessoryStore.shared
    @State private var open: HomeDevice?

    private var shown: [HomeDevice] {
        let list = room.map { r in store.all.filter { roomMatches(SmartHome.shared.room(of: $0.id), r) } } ?? store.all
        return favorites ? HomeLayout.shared.favoritesOnly(store.all) : HomeLayout.shared.arrange(list, in: "devices")
    }

    var body: some View {
        if !shown.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                if titled { Text("Devices").font(.title2.bold()) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], spacing: 14) {
                    ForEach(shown) { d in DeviceTile(device: d) { open = d } }
                }
            }
            .sheet(item: $open) { d in
                NavigationStack { DeviceDetailView(deviceID: d.id, inSheet: true) }.macResizable()
            }
        }
    }
}

struct DeviceTile: View, Equatable {
    var device: HomeDevice
    var openControls: () -> Void
    @State private var confirmUnlock = false

    /// Drawn again for a change to the device, not each time the grid around it is (the action is always the same).
    nonisolated static func == (a: DeviceTile, b: DeviceTile) -> Bool { a.device == b.device }

    private var lit: Bool {
        guard device.reachable else { return false }
        switch device.kind {
        case .lock: return device.locked == false
        case .garage: return device.doorOpen == true
        case .blinds: return (device.position ?? 0) > 0
        case .washer, .dryer, .dishwasher, .oven: return device.machineState == "run"
        case .vacuum: return device.mode == "cleaning"
        case .thermostat: return device.action == "heating" || device.action == "cooling"
        default: return device.isOn == true
        }
    }

    var body: some View {
        // Compact, like the Home app: icon on the left, name and state beside it.
        HStack(spacing: 10) {
            Group {
                // A fridge is always "running": on a tile it's its still symbol (its page shows the snow falling).
                if device.source == "smartthings" && device.isRunning && device.kind != .fridge && ApplianceArt.animates(device.kind) {
                    ApplianceArt(kind: device.kind, running: true, alert: device.alert, minimumInterval: 1.0 / 20)
                        .frame(width: 30, height: 30)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(device.alert ? Palette.attention : (lit ? Color.orange : .secondary))
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(device.name).font(.footnote.weight(.semibold)).lineLimit(2)
                Text(device.reachable ? device.status : "Not Responding").font(.caption)
                    .foregroundStyle(device.alert ? Palette.attention : (lit ? Color.black.opacity(0.55) : .secondary)).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(lit ? Color.black : .primary)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 64, maxHeight: .infinity, alignment: .leading)
        .background {
            if lit { RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.white.opacity(0.94)) }
        }
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .modifier(DeviceGlass(on: lit))
        .opacity(device.reachable ? 1 : 0.6)
        .animation(.smooth(duration: 0.25), value: lit)
        .onTapGesture { if HomeLayout.shared.tapsAllowed { tap() } }
        // Press and hold arranges Home's tiles (on the Mac too); the controls are in the menu.
        .contextMenu {
            ArrangeHomeButton()
            if let quick = quickAction { Button(quick) { tap() } }
            Button("Controls…", action: openControls)
            FavoriteButton(id: device.id)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .confirmationDialog("Unlock \(device.name)?", isPresented: $confirmUnlock, titleVisibility: .visible) {
            Button("Unlock") { AccessoryStore.shared.send(device, .lock(false)) }
        }
    }

    /// What a tap does, for the menu (nil when a tap just opens the controls).
    private var quickAction: String? {
        guard device.reachable else { return nil }
        switch device.kind {
        case .outlet, .toggle, .fan: return device.isOn.map { $0 ? "Turn Off" : "Turn On" }
        case .lock: return device.locked == true ? "Unlock" : "Lock"
        case .blinds: return (device.position ?? 0) > 0 ? "Close" : "Open"
        default: return nil
        }
    }

    /// One tap does the obvious thing; anything without one opens the controls.
    private func tap() {
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
        // Not responding: nothing would happen, so show its page (which says why) instead.
        guard device.reachable else { openControls(); return }
        switch device.kind {
        case .outlet, .toggle, .fan:
            if let on = device.isOn { AccessoryStore.shared.send(device, .power(!on)) } else { openControls() }
        case .lock:
            if device.locked == true { confirmUnlock = true } else { AccessoryStore.shared.send(device, .lock(true)) }
        case .blinds:
            AccessoryStore.shared.send(device, .position((device.position ?? 0) > 0 ? 0 : 100))
        default:
            openControls()
        }
    }

    private var symbol: String { deviceSymbol(device) }
}

func deviceSymbol(_ d: HomeDevice) -> String {
    switch d.kind {
    case .outlet: return "poweroutlet.type.b.fill"
    case .toggle: return "switch.2"
    case .lock: return d.locked == false ? "lock.open.fill" : "lock.fill"
    case .thermostat: return "thermometer.medium"
    case .sensor: return d.alert ? "exclamationmark.triangle.fill" : "sensor.fill"
    case .fan: return "fan.fill"
    case .blinds: return "blinds.horizontal.closed"
    case .garage: return d.doorOpen == true ? "door.garage.open" : "door.garage.closed"
    case .washer: return "washer.fill"
    case .dryer: return "dryer.fill"
    case .fridge: return "refrigerator.fill"
    case .oven: return "oven.fill"
    case .dishwasher: return "dishwasher.fill"
    case .aircon: return "air.conditioner.horizontal.fill"
    case .vacuum: return "circle.circle.fill"
    case .appliance: return "powerplug.fill"
    }
}

private struct DeviceGlass: ViewModifier {
    var on: Bool
    func body(content: Content) -> some View {
        if on { content } else { content.glass(RoundedRectangle(cornerRadius: 20, style: .continuous)) }
    }
}

// MARK: - Detail

struct DeviceDetailView: View {
    var deviceID: String
    var inSheet = false
    @Environment(\.dismiss) private var dismiss
    private let store = AccessoryStore.shared
    @State private var position: Double = 0
    @State private var sliding = false

    var body: some View {
        // Samsung appliances have their own page; a thermostat through SmartThings (the ecobee on the Mac) gets the
        // thermostat's controls here, like the Apple Home one (the appliance page has none for it).
        if let d = store.device(deviceID), d.source == "smartthings", d.kind != .thermostat {
            ApplianceView(device: d, inSheet: inSheet)
        } else if let d = store.device(deviceID) {
            ScrollView {
                VStack(spacing: 16) {
                    VStack(spacing: 12) {
                        if d.kind == .thermostat {
                            // The ecobee itself, large, heating or cooling as it is.
                            EcobeePicture(device: d).frame(width: 200, height: 200)
                        } else {
                            Image(systemName: deviceSymbol(d))
                                .font(.system(size: 44, weight: .semibold))
                                .foregroundStyle(d.alert ? Palette.attention : .primary)
                                .frame(height: 56)
                        }
                        Text(d.reachable ? d.status : "Not Responding").font(.title3.weight(.semibold)).multilineTextAlignment(.center)
                        controls(d)
                            .disabled(!d.reachable)
                    }
                    .padding(22)
                    .frame(maxWidth: .infinity)
                    .glass(RoundedRectangle(cornerRadius: 28, style: .continuous), interactive: false)

                    if d.source == "dreo", let e = Dreo.shared.error {
                        Text(e).font(.footnote).foregroundStyle(Palette.attention).multilineTextAlignment(.center)
                    }

                    NameRoomCard(id: d.id, current: d.name, original: nil)

                    GlassCard(title: "About") {
                        LabeledContent("Connected Through", value: d.sourceName)
                        if let z = d.zone { LabeledContent("\(d.sourceName) Room", value: z) }
                    }
                }
                .padding(16)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .background { ArtBackdrop(url: nil) }
            .environment(\.colorScheme, .dark)
            .navigationTitle(d.name)
            .inlineTitle()
            .toolbar {
                if inSheet { ToolbarItem(placement: .cancellationAction) { Button(role: .close) { dismiss() } } }
            }
            .refreshable { await reread(d) }
            .onAppear { position = Double(d.position ?? 0) }
            // Moved from elsewhere (or by a tap on its tile): the slider follows, unless it's being dragged.
            .onChange(of: d.position) { _, p in if !sliding { position = Double(p ?? 0) } }
        } else {
            ContentUnavailableView("Device Not Found", systemImage: "questionmark.square.dashed")
        }
    }

    /// Pull down on a device's page: it's asked again.
    private func reread(_ d: HomeDevice) async {
        #if os(iOS)
        if d.source == "home" { HomeKitLights.shared.refresh(device: d.id) }
        #endif
        if d.source == "smartthings" { await SmartThings.shared.refresh(device: d.id) }
        if d.source == "dreo" { await Dreo.shared.refresh(full: false) }
    }

    @ViewBuilder private func controls(_ d: HomeDevice) -> some View {
        switch d.kind {
        case .fan:
            if let on = d.isOn {
                Toggle(on ? "On" : "Off", isOn: Binding(get: { on }, set: { store.send(d, .power($0)) }))
                    .toggleStyle(.switch).frame(maxWidth: 220)
            }
            FanControls(device: d)
        case .outlet, .toggle:
            if let on = d.isOn {
                Toggle(on ? "On" : "Off", isOn: Binding(get: { on }, set: { store.send(d, .power($0)) }))
                    .toggleStyle(.switch).frame(maxWidth: 220)
            }
        case .lock:
            Button(d.locked == true ? "Unlock" : "Lock") { store.send(d, .lock(d.locked != true)) }
                .buttonStyle(.glassProminent)
        case .garage:
            Button(d.doorOpen == true ? "Close" : "Open") { store.send(d, .door(open: d.doorOpen != true)) }
                .buttonStyle(.glassProminent)
        case .blinds:
            VStack(spacing: 6) {
                Slider(value: $position, in: 0...100, step: 5) { editing in
                    sliding = editing
                    if !editing { store.send(d, .position(Int(position))) }
                }
                Text("\(Int(position))% open").font(.subheadline).foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Button("Close") { position = 0; store.send(d, .position(0)) }.buttonStyle(.glass)
                    Button("Open") { position = 100; store.send(d, .position(100)) }.buttonStyle(.glass)
                }
            }
        case .thermostat:
            ThermostatControls(device: d)
        case .washer, .dryer, .dishwasher, .oven:
            if let end = d.endsAt, end > .now, d.machineState == "run" {
                Text(end, style: .timer).font(.system(size: 34, weight: .semibold)).monospacedDigit()
            }
            if d.remoteControl {
                HStack(spacing: 12) {
                    if d.machineState == "run" { Button("Pause") { store.send(d, .machine("pause")) }.buttonStyle(.glass) }
                    if d.machineState == "pause" { Button("Resume") { store.send(d, .machine("run")) }.buttonStyle(.glassProminent) }
                    if d.machineState == "run" || d.machineState == "pause" { Button("Stop", role: .destructive) { store.send(d, .machine("stop")) }.buttonStyle(.glass) }
                }
            } else if d.machineState != nil {
                Text("Turn on Remote Control on the appliance to start or pause it from here.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            if let on = d.isOn, d.kind == .oven {
                Toggle(on ? "On" : "Off", isOn: Binding(get: { on }, set: { store.send(d, .power($0)) })).frame(maxWidth: 220)
            }
        default:
            if let on = d.isOn {
                Toggle(on ? "On" : "Off", isOn: Binding(get: { on }, set: { store.send(d, .power($0)) })).frame(maxWidth: 220)
            }
        }
    }
}

// MARK: - Settings

/// Settings → Smart Home → Devices: everything from Apple Home and SmartThings, and connecting Samsung.
struct DevicesListView: View {
    private let store = AccessoryStore.shared

    var body: some View {
        Form {
            Section {
                if let problem = store.homeProblem { Text(problem).font(.footnote).foregroundStyle(Palette.attention) }
                if store.all.isEmpty { Text("No devices yet.").foregroundStyle(.secondary) }
                ForEach(store.all) { d in
                    PageLink(d.name) { DeviceDetailView(deviceID: d.id) } label: {
                        IconRow(symbol: "", color: .clear, title: d.name, subtitle: "\(d.sourceName) · \(d.reachable ? d.status : "Not Responding")",
                                value: SmartHome.shared.room(of: d.id))
                    }
                }
            } footer: {
                #if os(iOS)
                Text("Everything in Apple Home (plugs, locks, thermostats, sensors, blinds, HomePod temperature) shows here, plus Samsung appliances once SmartThings is connected. Tap one to rename it or choose its room.")
                #else
                VStack(alignment: .leading, spacing: 6) {
                    // Apple Home (the ecobee, Cync lights, locks…) through Woodruff Home Helper.
                    HomeBridgeStatusView()
                    Text("Samsung appliances show here once SmartThings is connected.")
                }
                #endif
            }
            SmartThingsSection()
            DreoSection()
        }
        .formStyle(.grouped)
        .navigationTitle("Devices")
        .inlineTitle()
        .refreshable {
            #if os(iOS)
            HomeKitLights.shared.reload()
            #endif
            // Everything listed here, the fans too.
            async let samsung: Void = SmartThings.shared.refresh(full: true)
            async let fans: Void = Dreo.shared.refresh(full: true)
            _ = await (samsung, fans)
        }
    }
}

/// A fan's speed (a slider, with quick Low / Medium / High) and oscillation, and the blades turning while it runs.
struct FanControls: View {
    var device: HomeDevice
    @State private var speed: Double = 0
    @State private var editing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // How many turns the blades make a second.
        let rate = device.isOn == true ? 0.5 + Double(device.speed ?? 50) / 25 : 0
        VStack(spacing: 14) {
            // 30 frames a second is plenty for the blades, until they turn so fast that each frame's step would look
            // like turning backwards: then 60.
            TimelineView(.animation(minimumInterval: rate > 2.5 ? 1.0 / 60 : 1.0 / 30, paused: device.isOn != true || reduceMotion)) { tl in
                Image(systemName: "fan.fill")
                    .font(.system(size: 54))
                    .rotationEffect(.degrees(reduceMotion ? 0 : tl.date.timeIntervalSinceReferenceDate * 360 * rate))
                    .foregroundStyle(device.isOn == true ? Color.cyan : .secondary)
            }
            .frame(height: 64)
            if device.speed != nil {
                VStack(spacing: 6) {
                    Slider(value: $speed, in: 0...100, step: 1) { e in
                        editing = e
                        if !e { AccessoryStore.shared.send(device, .speed(Int(speed))) }
                    }
                    Text(speed == 0 ? "Off" : "Speed \(Int(speed))%").font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                }
                HStack(spacing: 10) {
                    ForEach([("Low", 25), ("Medium", 60), ("High", 100)], id: \.0) { p in
                        Button(p.0) { speed = Double(p.1); AccessoryStore.shared.send(device, .speed(p.1)) }
                            .buttonStyle(.glass)
                    }
                }
            }
            if let sw = device.swing {
                Toggle("Oscillate", isOn: Binding(get: { sw }, set: { AccessoryStore.shared.send(device, .swing($0)) }))
                    .frame(maxWidth: 220)
            }
        }
        .onAppear { speed = Double(device.speed ?? 0) }
        .onChange(of: device.speed) { _, v in if !editing { speed = Double(v ?? 0) } }
    }
}

// MARK: - Thermostat


/// An ecobee (or any thermostat): what it is now, its mode, and the temperature(s) it's holding. Taps on
/// + and − show straight away and are sent together a moment after the last one.
struct ThermostatControls: View {
    var device: HomeDevice
    /// In the pop-over (where the page's status line isn't): say when a change didn't go through.
    var showsFailure = false
    private let store = AccessoryStore.shared
    @State private var heat: Double?
    @State private var cool: Double?
    // Heat and cool each wait on their own, so changing both in Auto sends both.
    @State private var sendHeat: Task<Void, Never>?
    @State private var sendCool: Task<Void, Never>?

    private var modes: [String] {
        let wanted = ["off", "heat", "cool", "auto"]
        let offered = device.modes.isEmpty ? wanted : wanted.filter { device.modes.contains($0) }
        return offered.isEmpty ? wanted : offered
    }

    var body: some View {
        let d = device
        VStack(spacing: 22) {
            VStack(spacing: 4) {
                Text(d.temperature.map { temperatureText($0) } ?? "--")
                    .font(.system(size: 64, weight: .semibold, design: .rounded)).monospacedDigit()
                    .contentTransition(.numericText())
                Text([actionWord(d), d.humidity.map { "\($0)% humidity" }].compactMap { $0 }.joined(separator: " · "))
                    .font(.subheadline).foregroundStyle(actionColor(d))
            }
            // A thermostat that doesn't report a mode (only its set temperatures) has no mode to pick.
            if d.thermostatMode != nil || !d.modes.isEmpty {
                Picker("Mode", selection: Binding(get: { d.thermostatMode ?? "off" }, set: { m in pick(m) })) {
                    ForEach(modes, id: \.self) { m in Text(modeName(m)).tag(m) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 360)
                .disabled(!d.reachable)
            }
            // Side by side when there's room; one above the other in the iPhone's pop-over or page and the Mac's
            // pop-over (Auto's two temperatures are wider than those).
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 28) { setpoints(d) }
                VStack(spacing: 18) { setpoints(d) }
            }
            .disabled(!d.reachable)
            if d.thermostatMode == "off" { Text("Off").font(.headline).foregroundStyle(.secondary) }
            // A change that didn't go through, in words (never a control that quietly does nothing).
            if showsFailure, d.alert, d.reachable {
                Text(d.status).font(.footnote.weight(.semibold)).foregroundStyle(Palette.attention)
            }
            if d.source == "smartthings", let e = SmartThings.shared.commandError[d.id] {
                Text(e).font(.footnote).foregroundStyle(Palette.attention).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        // Fresh numbers while the controls are open: asked once now (Apple Home then sends its changes as they
        // happen), and SmartThings, which can't send them, asked again every 10 seconds.
        .task(id: device.id) {
            let id = device.id
            let source = device.source
            #if os(iOS)
            if source == "home" { HomeKitLights.shared.refresh(device: id) }
            #endif
            guard source == "smartthings" else { return }
            while !Task.isCancelled {
                await SmartThings.shared.refresh(device: id)
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }
    }

    /// The heat and cool temperatures this mode holds, each with − and +.
    @ViewBuilder private func setpoints(_ d: HomeDevice) -> some View {
        if showsHeat(d), let h = heat ?? d.heatTo ?? d.target {
            setpoint("Heat To", h, tint: .orange) { v in change(heating: true, to: v) }
        }
        if showsCool(d), let c = cool ?? d.coolTo ?? d.target {
            setpoint("Cool To", c, tint: .cyan) { v in change(heating: false, to: v) }
        }
    }

    /// Heat To shows in Heat and Auto (and, with no mode reported, whenever it has a heat temperature).
    private func showsHeat(_ d: HomeDevice) -> Bool {
        d.thermostatMode == "heat" || d.thermostatMode == "auto" || (d.thermostatMode == nil && d.heatTo != nil)
    }

    private func showsCool(_ d: HomeDevice) -> Bool {
        d.thermostatMode == "cool" || d.thermostatMode == "auto" || (d.thermostatMode == nil && d.coolTo != nil)
    }

    /// A new mode: sent now, and shown at once (the thermostat's answer then confirms it).
    private func pick(_ m: String) {
        guard m != device.thermostatMode else { return }
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
        store.send(device, .thermostatMode(m))
    }

    /// Shows the new temperature at once; sends it a moment after the last tap (so five taps are one change).
    private func change(heating: Bool, to v: Double) {
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
        let d = device
        if heating { heat = v } else { cool = v }
        let job = Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            store.send(d, heating ? .heatTo(v) : .coolTo(v))
            // The thermostat's tile has the new value now (then whatever the thermostat says).
            if heating { heat = nil; sendHeat = nil } else { cool = nil; sendCool = nil }
        }
        if heating { sendHeat?.cancel(); sendHeat = job } else { sendCool?.cancel(); sendCool = job }
    }

    private func setpoint(_ title: String, _ value: Double, tint: Color, set: @escaping (Double) -> Void) -> some View {
        VStack(spacing: 10) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(tint)
            HStack(spacing: 14) {
                GlassCircle(symbol: "minus", size: 44) { set(thermostatStep(value, -1)) }
                    .accessibilityLabel("\(title), cooler")
                Text(temperatureText(value))
                    .font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
                    .contentTransition(.numericText())
                    .frame(minWidth: 70)
                GlassCircle(symbol: "plus", size: 44) { set(thermostatStep(value, 1)) }
                    .accessibilityLabel("\(title), warmer")
            }
        }
        .animation(.snappy, value: value)
    }

    private func modeName(_ m: String) -> String {
        ["off": "Off", "heat": "Heat", "cool": "Cool", "auto": "Auto"][m] ?? m.capitalized
    }

    private func actionWord(_ d: HomeDevice) -> String? {
        guard d.reachable else { return "Offline" }
        switch d.action {
        case "heating": return "Heating"
        case "cooling": return "Cooling"
        case "idle": return "Idle"
        default: return d.action.map { $0.capitalized }
        }
    }

    private func actionColor(_ d: HomeDevice) -> Color {
        switch d.action { case "heating": return .orange; case "cooling": return .cyan; default: return .secondary }
    }
}


/// The thermostat pill, top right: on the Mac in the toolbar of every page (with − and + for the set
/// temperature), on iPhone beside Home's title (compact). Click or tap it for every control.
/// The thermostat panel's state, kept outside the pill: the pill sits in the Mac's toolbar and Home's header,
/// which redraw every second or two while the TVs report, and a pop-over or a value held inside it was lost on
/// every redraw (the controls flashed open and vanished). The panel opens from the window itself instead.
@Observable @MainActor
final class ThermostatUI {
    static let shared = ThermostatUI()
    /// The thermostat controls are showing.
    var open = false
    /// The set temperature being changed with − and + (shown at once, sent a moment after the last click).
    var pending: Double?
    @ObservationIgnored var sendSoon: Task<Void, Never>?
}

struct ThermostatChip: View {
    /// iPhone: just the icon, the temperature and what it's doing.
    var compact = false
    private let store = AccessoryStore.shared
    private let ui = ThermostatUI.shared
    @State private var hovering = false

    /// The set temperature the − and + change (Mac, in Heat or Cool).
    private struct Nudge {
        var mode: String
        var value: Double
    }

    var body: some View {
        let t = store.thermostat
        let n = nudgeable(t)
        HStack(spacing: 0) {
            // The pill is a real button: a tap gesture inside a Mac toolbar is taken by the window (dragging it),
            // so a click on it never arrived before.
            Button {
                #if os(iOS)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                #endif
                ui.open = true
            } label: {
                summary(t)
                    .padding(.leading, 5)
                    .padding(.trailing, n == nil ? 12 : 8)
                    .padding(.vertical, compact ? 6 : 4)
                    .contentShape(Capsule())
            }
            .buttonStyle(PressScale(scale: 0.95))
            .accessibilityLabel(spoken(t))
            .accessibilityHint("Shows the thermostat’s controls")
            // − and + are buttons of their own beside it (they change the temperature; they don't open anything).
            if let t, let n {
                Divider().frame(height: 22)
                HStack(spacing: 6) {
                    stepButton("minus", "Cooler") { nudge(t, n.mode, thermostatStep(n.value, -1)) }
                    Text(temperatureText(n.value))
                        .font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(tint(t))
                        .contentTransition(.numericText())
                        .frame(minWidth: 34)
                        .animation(.snappy, value: n.value)
                    stepButton("plus", "Warmer") { nudge(t, n.mode, thermostatStep(n.value, 1)) }
                }
                .padding(.leading, 8).padding(.trailing, 10)
            }
        }
        .fixedSize()
        // Plain glass behind it (the button inside takes the taps).
        .glass(Capsule(), interactive: false)
        .opacity(t?.reachable == false ? 0.6 : 1)
        .scaleEffect(hovering ? 1.02 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: hovering)
        .onHover { hovering = $0 }
        .help(t.map { "\($0.name): \($0.status)" } ?? "Thermostat: not connected yet. Click for how to add it.")
    }

    /// The set temperature − and + work on: the Mac's full pill, a thermostat that's responding, in Heat or Cool.
    private func nudgeable(_ t: HomeDevice?) -> Nudge? {
        guard !compact, let t, t.reachable else { return nil }
        // No mode reported (only set temperatures): the one it has.
        let mode = t.thermostatMode ?? (t.heatTo == nil && t.coolTo != nil ? "cool" : "heat")
        guard mode == "heat" || mode == "cool",
              let current = ui.pending ?? (mode == "heat" ? t.heatTo : t.coolTo) ?? t.target else { return nil }
        return Nudge(mode: mode, value: current)
    }

    /// The icon, the temperature now and what it's doing.
    private func summary(_ t: HomeDevice?) -> some View {
        HStack(spacing: 9) {
            Group {
                if let t {
                    // The ecobee itself, small: black, with what it's doing (a turning snowflake, a flickering flame).
                    EcobeePicture(device: t)
                } else {
                    ZStack {
                        Circle().fill(tint(t).gradient)
                        Image(systemName: symbol(t)).font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                    }
                }
            }
            .frame(width: 28, height: 28)
            .shadow(color: tint(t).opacity(0.5), radius: 6)
            VStack(alignment: .leading, spacing: -1) {
                Text(t?.temperature.map { temperatureText($0) } ?? "--")
                    .font(.system(size: 17, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText())
                Text(t.map { subtitle($0) } ?? "Thermostat")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private func stepButton(_ symbol: String, _ name: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .bold))
                .foregroundStyle(.primary)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.primary.opacity(0.1)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(name)
        .accessibilityLabel(name)
    }

    /// Shows the new temperature at once; sends it a moment after the last click.
    private func nudge(_ t: HomeDevice, _ mode: String, _ value: Double) {
        let ui = ui
        let store = store
        ui.pending = value
        ui.sendSoon?.cancel()
        ui.sendSoon = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            store.send(t, mode == "heat" ? .heatTo(value) : .coolTo(value))
            // The thermostat's own value shows from here: the change at once, then what it says.
            ui.pending = nil
            ui.sendSoon = nil
        }
    }

    private func spoken(_ t: HomeDevice?) -> String {
        guard let t else { return "Thermostat, not connected yet" }
        let now = t.temperature.map { temperatureText($0) } ?? "no reading"
        return "\(t.name), \(now), \(subtitle(t))"
    }

    private func subtitle(_ t: HomeDevice) -> String {
        guard t.reachable else { return "Offline" }
        switch t.action {
        case "heating": return "Heating"
        case "cooling": return "Cooling"
        default:
            switch t.thermostatMode {
            case "heat": return "Heat"
            case "cool": return "Cool"
            case "auto": return t.heatTo.flatMap { h in t.coolTo.map { "Auto \(temperatureText(h))–\(temperatureText($0))" } } ?? "Auto"
            case "off": return "Off"
            default: return t.name
            }
        }
    }

    private func tint(_ t: HomeDevice?) -> Color {
        guard let t, t.reachable else { return .gray }
        switch t.action {
        case "heating": return .orange
        case "cooling": return .cyan
        default:
            switch t.thermostatMode {
            case "heat": return .orange.opacity(0.8)
            case "cool": return .blue
            case "auto": return .teal
            default: return .gray
            }
        }
    }

    private func symbol(_ t: HomeDevice?) -> String {
        guard let t else { return "thermometer.medium" }
        guard t.reachable else { return "wifi.slash" }
        switch t.action {
        case "heating": return "flame.fill"
        case "cooling": return "snowflake"
        default:
            switch t.thermostatMode {
            case "heat": return "flame"
            case "cool": return "snowflake"
            case "auto": return "arrow.up.arrow.down"
            case "off": return "power"
            default: return "thermometer.medium"
            }
        }
    }
}

/// What the thermostat pill opens: every control, or, with no thermostat yet, how to connect it.
struct ThermostatPanel: View {
    private let store = AccessoryStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline) {
                    if let t = store.thermostat {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.name).font(.title3.bold()).lineLimit(1)
                            Text(t.reachable ? t.sourceName : "Not Responding").font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Thermostat").font(.title3.bold())
                    }
                    Spacer()
                    Button("Done") { ThermostatUI.shared.open = false }
                        .keyboardShortcut(.cancelAction)
                        .buttonStyle(.glass)
                }
                if let t = store.thermostat {
                    EcobeePicture(device: t).frame(width: 180, height: 180).frame(maxWidth: .infinity)
                    ThermostatControls(device: t, showsFailure: true)
                } else {
                    ThermostatSetup()
                }
            }
            .padding(22)
        }
        #if os(macOS)
        .frame(width: 440, height: 520)
        #endif
    }
}

/// No thermostat yet: why, and what to do about it, right there (connect SmartThings on the Mac, allow Apple
/// Home on iPhone, look again).
private struct ThermostatSetup: View {
    private let st = SmartThings.shared
    @State private var looking = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("No Thermostat Yet").font(.title3.bold())
            #if os(iOS)
            if let problem = AccessoryStore.shared.homeProblem {
                Text(problem)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if HomeKitLights.enabled {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                    .buttonStyle(.glassProminent)
                }
            } else {
                Text("Add your ecobee in the Home app (Add Accessory, then scan the code on the thermostat or in the ecobee app) and it shows up here, ready to control. It can also come in through Samsung SmartThings (Settings → Smart Home → Devices).")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            lookAgain
            #else
            // On the Mac the ecobee comes from Apple Home through Woodruff Home Helper (or from SmartThings).
            HomeBridgeStatusView()
            Text("It can also come in through Samsung SmartThings: add the ecobee in the SmartThings app (Add Device → Thermostat → ecobee) and connect SmartThings in Settings → Smart Home → Devices.")
                .font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if st.connected { lookAgain }
            #endif
            if let e = st.error, st.connected {
                Text(e).font(.footnote).foregroundStyle(Palette.attention)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var lookAgain: some View {
        Button {
            looking = true
            Task {
                #if os(iOS)
                HomeKitLights.shared.reload()
                #endif
                await SmartThings.shared.refresh(full: true)
                // Apple Home answers on its own time; give it a moment before saying it's done.
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                looking = false
            }
        } label: {
            HStack(spacing: 8) {
                Text(looking ? "Looking…" : "Look Again")
                if looking { ProgressView().controlSize(.small) }
            }
        }
        .buttonStyle(.glass)
        .disabled(looking)
    }
}
