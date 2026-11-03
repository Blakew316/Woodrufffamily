import SwiftUI
import WoodruffKit

// Everything else in the house: Apple Home accessories (plugs, locks, thermostats, sensors, blinds, HomePod
// temperature…) and Samsung SmartThings appliances (washer, dryer, fridge…), as tiles on Home.

struct HomeDevice: Identifiable, Hashable {
    enum Kind: String { case outlet, toggle, lock, thermostat, sensor, fan, blinds, garage, washer, dryer, fridge, oven, dishwasher, aircon, vacuum, appliance }

    var id: String
    var name: String
    /// "home" (Apple Home) or "smartthings".
    var source: String
    var kind: Kind
    var zone: String?
    /// On or off, for things that switch.
    var isOn: Bool?
    /// What it's doing, in a few words: "Locked", "70° · 45%", "Washing · 23 min left".
    var status: String
    var reachable = true
    /// Something to look at (a door open, a leak, smoke).
    var alert = false
    // Kind-specific.
    var locked: Bool?
    var temperature: Double?      // °C
    var target: Double?           // °C
    var position: Int?            // blinds 0…100
    var doorOpen: Bool?           // garage
    var machineState: String?     // run / pause / stop
    var endsAt: Date?
    var remoteControl = false     // the appliance allows starting / pausing from the phone
    var mode: String?             // vacuum movement, AC mode…

    /// Busy right now (for the running animations).
    var isRunning: Bool {
        switch kind {
        case .washer, .dryer, .dishwasher, .oven: return machineState == "run"
        case .vacuum: return mode == "cleaning"
        case .fridge: return reachable
        default: return isOn == true
        }
    }

    var sourceName: String { source == "home" ? "Apple Home" : "SmartThings" }
}

enum DeviceCommand {
    case power(Bool)
    case lock(Bool)
    case target(Double)
    case position(Int)
    case door(open: Bool)
    case machine(String)
}

@Observable @MainActor
final class AccessoryStore {
    static let shared = AccessoryStore()

    var fromHome: [HomeDevice] = [] { didSet { zones() } }
    var fromSmartThings: [HomeDevice] = [] { didSet { zones() } }
    /// Carries out a change to an Apple Home accessory (set by the iPhone app).
    var homeControl: ((HomeDevice, DeviceCommand) -> Void)?

    var all: [HomeDevice] {
        let names = SmartHome.shared.names
        return (fromHome + fromSmartThings).map { d in
            var d = d
            if let n = names[d.id], !n.isEmpty { d.name = n }
            return d
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func device(_ id: String) -> HomeDevice? { all.first { $0.id == id } }

    func send(_ d: HomeDevice, _ c: DeviceCommand) {
        if d.source == "home" { homeControl?(d, c) } else { SmartThings.shared.send(d, c) }
    }

    private func zones() {
        var z: [String: String] = [:]
        for d in fromHome + fromSmartThings { if let r = d.zone { z[d.id] = r } }
        SmartHome.shared.externalZones = z
    }
}

/// "70°" in the family's units.
func temperatureText(_ c: Double) -> String {
    temperatureFormatter.string(from: Measurement(value: c, unit: UnitTemperature.celsius))
}

private let temperatureFormatter: MeasurementFormatter = {
    let f = MeasurementFormatter()
    f.unitStyle = .short
    f.unitOptions = .temperatureWithoutUnit
    f.numberFormatter.maximumFractionDigits = 0
    return f
}()

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
                NavigationStack { DeviceDetailView(deviceID: d.id, inSheet: true) }
            }
        }
    }
}

struct DeviceTile: View {
    var device: HomeDevice
    var openControls: () -> Void
    @State private var confirmUnlock = false

    private var lit: Bool {
        switch device.kind {
        case .lock: return device.locked == false
        case .garage: return device.doorOpen == true
        case .blinds: return (device.position ?? 0) > 0
        case .washer, .dryer, .dishwasher, .oven: return device.machineState == "run"
        case .vacuum: return device.mode == "cleaning"
        default: return device.isOn == true
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Group {
                if device.source == "smartthings" && device.isRunning && ApplianceArt.animates(device.kind) {
                    ApplianceArt(kind: device.kind, running: true, alert: device.alert)
                        .frame(width: 34, height: 34)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(device.alert ? Palette.attention : (lit ? Color.orange : .secondary))
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .frame(height: 34, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(device.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                Text(device.reachable ? device.status : "Not Responding").font(.caption)
                    .foregroundStyle(device.alert ? Palette.attention : (lit ? Color.black.opacity(0.55) : .secondary)).lineLimit(2)
            }
        }
        .foregroundStyle(lit ? Color.black : .primary)
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
        .background {
            if lit { RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.white.opacity(0.94)) }
        }
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .modifier(DeviceGlass(on: lit))
        .opacity(device.reachable ? 1 : 0.6)
        .animation(.smooth(duration: 0.25), value: lit)
        .onTapGesture { tap() }
        .onLongPressGesture(minimumDuration: 0.35, perform: openControls)
        .contextMenu {
            Button("Controls…", action: openControls)
            FavoriteButton(id: device.id)
        }
        .confirmationDialog("Unlock \(device.name)?", isPresented: $confirmUnlock, titleVisibility: .visible) {
            Button("Unlock") { AccessoryStore.shared.send(device, .lock(false)) }
        }
    }

    /// One tap does the obvious thing; anything without one opens the controls.
    private func tap() {
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
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

    var body: some View {
        if let d = store.device(deviceID), d.source == "smartthings" {
            ApplianceView(device: d, inSheet: inSheet)
        } else if let d = store.device(deviceID) {
            ScrollView {
                VStack(spacing: 16) {
                    VStack(spacing: 12) {
                        Image(systemName: deviceSymbol(d))
                            .font(.system(size: 44, weight: .semibold))
                            .foregroundStyle(d.alert ? Palette.attention : .primary)
                            .frame(height: 56)
                        Text(d.reachable ? d.status : "Not Responding").font(.title3.weight(.semibold)).multilineTextAlignment(.center)
                        controls(d)
                    }
                    .padding(22)
                    .frame(maxWidth: .infinity)
                    .glass(RoundedRectangle(cornerRadius: 28, style: .continuous), interactive: false)

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
            .onAppear { position = Double(d.position ?? 0) }
        } else {
            ContentUnavailableView("Device Not Found", systemImage: "questionmark.square.dashed")
        }
    }

    @ViewBuilder private func controls(_ d: HomeDevice) -> some View {
        switch d.kind {
        case .outlet, .toggle, .fan:
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
                Slider(value: $position, in: 0...100, step: 5) { editing in if !editing { store.send(d, .position(Int(position))) } }
                Text("\(Int(position))% open").font(.subheadline).foregroundStyle(.secondary)
            }
        case .thermostat:
            if let t = d.target {
                HStack(spacing: 24) {
                    GlassCircle(symbol: "minus", size: 48) { store.send(d, .target(t - 0.5)) }
                    VStack(spacing: 2) {
                        Text(temperatureText(t)).font(.system(size: 40, weight: .semibold)).monospacedDigit()
                        Text("Set To").font(.caption).foregroundStyle(.secondary)
                    }
                    GlassCircle(symbol: "plus", size: 48) { store.send(d, .target(t + 0.5)) }
                }
            }
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

/// Settings → Devices: everything from Apple Home and SmartThings, and connecting Samsung.
struct DevicesListView: View {
    private let store = AccessoryStore.shared

    var body: some View {
        Form {
            Section {
                if store.all.isEmpty { Text("No devices yet.").foregroundStyle(.secondary) }
                ForEach(store.all) { d in
                    NavigationLink { DeviceDetailView(deviceID: d.id) } label: {
                        IconRow(symbol: "", color: .clear, title: d.name, subtitle: "\(d.sourceName) · \(d.reachable ? d.status : "Not Responding")",
                                value: SmartHome.shared.room(of: d.id))
                    }
                }
            } footer: {
                #if os(iOS)
                Text("Everything in Apple Home (plugs, locks, thermostats, sensors, blinds, HomePod temperature) shows here, plus Samsung appliances once SmartThings is connected. Tap one to rename it or choose its room.")
                #else
                Text("Samsung appliances show here once SmartThings is connected. Apple Home accessories show in Woodruff on iPhone.")
                #endif
            }
            SmartThingsSection()
        }
        .formStyle(.grouped)
        .navigationTitle("Devices")
        .inlineTitle()
        .refreshable { await SmartThings.shared.refresh(full: true) }
    }
}
