import SwiftUI
import WoodruffKit

/// The room bar's All Devices tab: every TV, speaker, light and device, room by room, each a small tile with a little
/// animated picture of the device that comes alive when it's on (a glowing bulb, a spinning fan, a TV that lights up,
/// a speaker sending out sound). Like the Home app: a tap turns it on or off; press and hold opens its controls.
struct AllDevicesView: View {
    @Environment(Fleet.self) private var fleet
    private let home = SmartHome.shared
    private let store = AccessoryStore.shared
    @State private var openSpeaker: SonosRoom?
    @State private var openLight: GoveeLight?
    @State private var openDevice: HomeDevice?
    @State private var openTV: TitleRef?
    /// The small remote for a TV, from a tap on its tile.
    @State private var miniTV: TitleRef?
    @State private var confirmUnlock: HomeDevice?
    /// Settings → General: devices that have no room, under Other at the end (off unless asked for).
    @AppStorage("allDevices.showOther") private var showOther = false

    /// The family's rooms first, in this order and spelled like this; any other room after them, by name.
    static let order = ["Master Bedroom", "Living Room", "Haley's Sewing Room", "Elliott's Room", "Kyler's Room", "Kitchen", "Laundry Room"]

    /// The washer or dryer, unless the family put it in a room of their own in Woodruff: in the Laundry Room.
    static func inLaundry(_ d: HomeDevice) -> Bool {
        (d.kind == .washer || d.kind == .dryer) && SmartHome.shared.rooms[d.id] == nil
    }

    /// A room's name to compare by: letters only, lowercase, and Elliot/Elliott the same.
    static func key(_ room: String) -> String {
        room.lowercased().filter(\.isLetter).replacingOccurrences(of: "elliott", with: "elliot")
    }

    /// One room's section: the room as the devices have it, and its heading.
    struct RoomSection: Hashable { var rooms: [String]; var title: String }

    /// The sections, in order.
    private func sections(_ rooms: [String]) -> [RoomSection] {
        var out: [RoomSection] = []
        var used = Set<String>()
        // Every spelling of a room ("Elliot's Room" and "Elliott's Room") in one section.
        for title in Self.order {
            let same = rooms.filter { !used.contains($0) && Self.key($0) == Self.key(title) }
            if !same.isEmpty { out.append(RoomSection(rooms: same, title: title)); used.formUnion(same) }
        }
        for r in rooms.sorted() where !used.contains(r) {
            let same = rooms.filter { !used.contains($0) && Self.key($0) == Self.key(r) }
            out.append(RoomSection(rooms: same, title: r))
            used.formUnion(same)
        }
        if showOther { out.append(RoomSection(rooms: [noRoom], title: "Other")) }
        return out
    }

    #if os(macOS)
    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 14)]
    #else
    private let columns = [GridItem(.adaptive(minimum: 104, maximum: 140), spacing: 12)]
    #endif

    /// One device on the tab, whatever kind it is.
    enum Item: Identifiable {
        case tv(FleetTV)
        case speaker(SonosRoom)
        case light(GoveeLight)
        case device(HomeDevice)

        var id: String {
            switch self {
            case .tv(let t): return "tv-" + t.id
            case .speaker(let s): return "sp-" + s.id
            case .light(let l): return "li-" + l.id
            case .device(let d): return "de-" + d.id
            }
        }
    }

    var body: some View {
        let devices = store.all
        // The washer and dryer always have a Laundry Room here.
        let laundry = devices.contains { Self.inLaundry($0) } ? ["Laundry Room"] : []
        let roomOf = home.roomIndex
        let rooms = Array(Set(homeRooms(fleet, devices: devices, roomOf: roomOf) + laundry)).filter { $0 != noRoom && !$0.isEmpty }
        let byRoom = grouped(devices: devices, roomOf: roomOf)
        VStack(alignment: .leading, spacing: 26) {
            ForEach(sections(rooms), id: \.title) { section in
                let list = section.rooms.flatMap { byRoom[$0] ?? [] }
                if !list.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(section.title).font(.title3.bold())
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                            ForEach(list) { item in tile(item) }
                        }
                    }
                }
            }
        }
        .onAppear { store.zones(); ArcRoom.place() }
        .onChange(of: home.speakers.count) { _, _ in store.zones(); ArcRoom.place() }
        .onChange(of: home.lights.count) { _, _ in store.zones(); ArcRoom.place() }
        .onChange(of: store.all.count) { _, _ in ArcRoom.place() }
        .sheet(item: $openSpeaker) { r in
            NavigationStack { SpeakerDetailView(speakerID: r.id, inSheet: true) }.presentationBackground(.clear).macResizable()
        }
        .sheet(item: $openLight) { l in LightSheet(lightID: l.id).macResizable(width: 520, height: 640) }
        .sheet(item: $openDevice) { d in NavigationStack { DeviceDetailView(deviceID: d.id, inSheet: true) }.macResizable() }
        .sheet(item: $openTV) { t in NavigationStack { TVDetailView(tvID: t.id) }.macResizable() }
        .sheet(item: $miniTV) { t in
            MiniRemote(tvID: t.id)
                #if os(iOS)
                .presentationDetents([.height(300)])
                .presentationBackground(.clear)
                .presentationDragIndicator(.visible)
                #else
                .frame(width: 360, height: 300)
                #endif
        }
        .confirmationDialog("Unlock \(confirmUnlock?.name ?? "")?", isPresented: Binding(get: { confirmUnlock != nil }, set: { if !$0 { confirmUnlock = nil } }), titleVisibility: .visible) {
            Button("Unlock") { if let d = confirmUnlock { store.send(d, .lock(false)) }; confirmUnlock = nil }
        }
    }

    /// Everything in each room (``noRoom`` for things in none): TVs first, then speakers, lights and devices, each by
    /// name. Sorted into rooms in one go for each drawing.
    private func grouped(devices: [HomeDevice], roomOf: [String: String]) -> [String: [Item]] {
        let tvs = itemsByRoom(fleet.tvs.filter { !$0.isUnpaired }.sorted { $0.name < $1.name }) { home.rooms[$0.id] ?? $0.name }
        let speakers = itemsByRoom(home.speakers.sorted { $0.name < $1.name }) { roomOf[$0.id] }
        let lights = itemsByRoom(home.lights.sorted { $0.name < $1.name }) { roomOf[$0.id] }
        let things = itemsByRoom(devices.sorted { $0.name < $1.name }) { Self.inLaundry($0) ? "Laundry Room" : roomOf[$0.id] }
        var out: [String: [Item]] = [:]
        for r in Set(tvs.keys).union(speakers.keys).union(lights.keys).union(things.keys) {
            out[r] = (tvs[r] ?? []).map { Item.tv($0) } + (speakers[r] ?? []).map { Item.speaker($0) }
                + (lights[r] ?? []).map { Item.light($0) } + (things[r] ?? []).map { Item.device($0) }
        }
        return out
    }

    // MARK: One tile

    private func tile(_ item: Item) -> some View {
        let f = facts(item)
        // Centred, the same in every tile: the picture in a square of its own at the top, the name and state under it
        // at the same height whatever the picture is.
        return VStack(alignment: .center, spacing: 10) {
            DeviceGlyph(look: f.look, on: f.on, tint: f.tint)
                .frame(width: 58, height: 56, alignment: .center)
                .frame(maxWidth: .infinity)
            VStack(spacing: 2) {
                Text(f.name).font(.footnote.weight(.semibold)).lineLimit(2)
                // Two lines, so a TV's title reads in full more often.
                Text(f.state).font(.caption)
                    .foregroundStyle(f.on ? Color.black.opacity(0.55) : .secondary).lineLimit(2)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
        }
        .foregroundStyle(f.on ? Color.black : .primary)
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .top)
        .background {
            if f.on { RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.white.opacity(0.94)) }
        }
        .modifier(TileGlass(on: f.on))
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .opacity(f.reachable ? 1 : 0.55)
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: f.on)
        .onTapGesture { tap(item) }
        .onLongPressGesture(minimumDuration: 0.4) { open(item) }
        #if os(macOS)
        .contextMenu { Button("Controls…") { open(item) } }
        #endif
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Tap to turn on or off. Touch and hold for its controls.")
        // Touch and hold isn't there for VoiceOver: its controls as an action.
        .accessibilityAction(named: "Controls") { open(item) }
    }

    private struct Facts {
        var name: String
        var state: String
        var on: Bool
        var reachable: Bool
        var look: DeviceGlyph.Look
        var tint: Color
    }

    private func facts(_ item: Item) -> Facts {
        switch item {
        case .tv(let tv):
            let p = tv.nowPlaying
            // What's on it: the title while it plays.
            let state = !tv.online ? "Off" : p.map { $0.isPlaying ? $0.title : "Paused" } ?? "On"
            return Facts(name: tv.name, state: state, on: tv.online, reachable: true,
                         look: .tv(playing: p?.isPlaying == true), tint: .blue)
        case .speaker(let s):
            let state = s.isOffline ? "Offline" : s.isPlaying ? (s.title ?? "Playing") : "Paused"
            return Facts(name: s.name, state: state, on: s.isPlaying, reachable: !s.isOffline, look: .speaker(bar: Self.isSoundbar(s)), tint: .teal)
        case .light(let l):
            let state = l.isOffline ? "Offline" : l.isLit ? (l.inScene ? "Scene · \(l.brightness)%" : "\(l.brightness)%") : "Off"
            return Facts(name: l.name, state: state, on: l.isLit, reachable: !l.isOffline,
                         look: l.isFloorLamp ? .floorLamp(level: Double(l.brightness) / 100)
                            : l.isTableLamp ? .tableLamp(level: Double(l.brightness) / 100)
                            : l.isStringLights ? .stringLights(level: Double(l.brightness) / 100) : .light,
                         tint: l.shade)
        case .device(let d) where d.product?.hasPrefix("HomePod") == true:
            return Facts(name: d.name, state: d.reachable ? d.status : "Not Responding", on: false, reachable: d.reachable,
                         look: .homePod(mini: d.product == "HomePod mini"), tint: .gray)
        case .device(let d) where d.kind == .thermostat:
            return Facts(name: d.name, state: d.reachable ? d.status : "Not Responding", on: lit(d), reachable: d.reachable,
                         look: .thermostat(d), tint: d.action == "heating" ? .orange : .blue)
        case .device(let d) where d.source == "dreo":
            let on = lit(d)
            let pedestal = (d.product ?? "").uppercased().contains("HPF") || d.name.localizedCaseInsensitiveContains("pedestal")
            return Facts(name: d.name, state: d.reachable ? d.status : "Not Responding", on: on, reachable: d.reachable,
                         look: .dreoFan(pedestal: pedestal, speed: Double(d.speed ?? 50) / 100), tint: .cyan)
        case .device(let d):
            let on = lit(d)
            return Facts(name: d.name, state: d.reachable ? d.status : "Not Responding", on: on, reachable: d.reachable,
                         look: .device(d.kind, running: d.isRunning, symbol: deviceSymbol(d)), tint: d.alert ? Palette.attention : .orange)
        }
    }

    /// A Sonos soundbar (Arc, Beam, Ray, Playbar): drawn as a bar, not a speaker.
    static func isSoundbar(_ s: SonosRoom) -> Bool {
        let m = (s.model ?? "") + " " + s.name
        return ["arc", "beam", "ray", "playbar", "playbase"].contains { m.localizedCaseInsensitiveContains($0) }
    }

    private func lit(_ d: HomeDevice) -> Bool {
        guard d.reachable else { return false }
        switch d.kind {
        case .lock: return d.locked == false
        case .garage: return d.doorOpen == true
        case .blinds: return (d.position ?? 0) > 0
        case .washer, .dryer, .dishwasher, .oven: return d.machineState == "run"
        case .vacuum: return d.mode == "cleaning"
        case .thermostat: return d.action == "heating" || d.action == "cooling"
        default: return d.isOn == true
        }
    }

    // MARK: Tap and hold

    private func tap(_ item: Item) {
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
        switch item {
        case .tv(let tv):
            // A small remote for it (waking it if it's off).
            if !tv.online { fleet.wake(tv) }
            miniTV = TitleRef(id: tv.id)
        case .speaker(let s):
            guard !s.isOffline else { open(item); return }
            let playing = s.isPlaying
            Task {
                await home.sonos(s, expect: playing ? "PAUSED_PLAYBACK" : "PLAYING") { r in
                    if playing { try await Sonos.pause(r) } else { try await Sonos.play(r) }
                }
            }
        case .light(let l):
            guard !l.isOffline else { open(item); return }
            home.setOn(l, !l.on)
        case .device(let d):
            guard d.reachable else { open(item); return }
            switch d.kind {
            case .outlet, .toggle, .fan:
                if let on = d.isOn { store.send(d, .power(!on)) } else { open(item) }
            case .lock:
                if d.locked == true { confirmUnlock = d } else { store.send(d, .lock(true)) }
            case .blinds:
                store.send(d, .position((d.position ?? 0) > 0 ? 0 : 100))
            default:
                // Nothing on or off about it (a sensor, the thermostat, an appliance): its controls.
                open(item)
            }
        }
    }

    private func open(_ item: Item) {
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        #endif
        switch item {
        case .tv(let tv): openTV = TitleRef(id: tv.id)
        case .speaker(let s): openSpeaker = s
        case .light(let l): openLight = l
        case .device(let d): openDevice = d
        }
    }
}

private struct TileGlass: ViewModifier {
    var on: Bool
    func body(content: Content) -> some View {
        if on { content } else { content.glass(RoundedRectangle(cornerRadius: 22, style: .continuous)) }
    }
}

/// A small animated picture of a device: lit and moving when it's on, still and grey when it's off.
struct DeviceGlyph: View {
    enum Look: Equatable {
        case tv(playing: Bool)
        case speaker(bar: Bool)
        case homePod(mini: Bool)
        case light
        case floorLamp(level: Double)
        case tableLamp(level: Double)
        case stringLights(level: Double)
        case dreoFan(pedestal: Bool, speed: Double)
        case thermostat(HomeDevice)
        case device(HomeDevice.Kind, running: Bool, symbol: String)
    }

    var look: Look
    var on: Bool
    var tint: Color

    /// Drawn as the product itself (no circle behind it).
    private var drawn: Bool {
        switch look {
        case .tv, .floorLamp, .tableLamp, .stringLights, .dreoFan, .thermostat: return true
        case .speaker(let bar): return bar
        default: return false
        }
    }

    var body: some View {
        ZStack {
            if !drawn {
                Circle()
                    .fill(on ? AnyShapeStyle(tint.opacity(0.22)) : AnyShapeStyle(Color.white.opacity(0.12)))
                if on {
                    // A soft glow behind it while it's on.
                    Circle().fill(tint.opacity(0.35)).blur(radius: 10).scaleEffect(0.8)
                }
            }
            picture
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: on)
    }

    @ViewBuilder private var picture: some View {
        switch look {
        case .tv(let playing):
            TVPicture(on: on, playing: playing).frame(width: 56, height: 44)
        case .speaker(let bar):
            if bar {
                SoundbarPicture(on: on, tint: tint).frame(width: 58, height: 40)
            } else {
                Image(systemName: on ? "hifispeaker.fill" : "hifispeaker")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(on ? tint : .secondary)
                    .symbolEffect(.variableColor.iterative, options: .repeating, isActive: on)
                    .symbolEffect(.bounce, value: on)
            }
        case .thermostat(let d):
            EcobeePicture(device: d).frame(width: 52, height: 52)
        case .dreoFan(let pedestal, let speed):
            DreoFanPicture(pedestal: pedestal, on: on, speed: speed).frame(width: pedestal ? 40 : 52, height: 58)
        case .floorLamp(let level):
            FloorLampPicture(level: level, lit: on, color: tint).frame(width: 34, height: 56)
        case .tableLamp(let level):
            TableLampPicture(level: level, lit: on, color: tint).frame(width: 42, height: 56)
        case .stringLights(let level):
            StringLightsPicture(level: level, lit: on, color: tint).frame(width: 80, height: 54)
        case .homePod(let mini):
            Image(systemName: mini ? "homepodmini.fill" : "homepod.fill")
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(.secondary)
        case .light:
            Image(systemName: on ? "lightbulb.max.fill" : "lightbulb")
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(on ? tint : .secondary)
                .shadow(color: on ? tint.opacity(0.9) : .clear, radius: 8)
                .symbolEffect(.breathe, options: .repeating, isActive: on)
                .symbolEffect(.bounce, value: on)
        case .device(let kind, let running, let symbol):
            if running && ApplianceArt.animates(kind) && kind != .fridge && kind != .fan {
                ApplianceArt(kind: kind, running: true, minimumInterval: 1.0 / 20)
                    .frame(width: 34, height: 34)
                    .clipShape(Circle())
            } else if kind == .fan {
                Image(systemName: "fan.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(on ? tint : .secondary)
                    .symbolEffect(.rotate, options: .repeating, isActive: on)
            } else {
                Image(systemName: symbolFor(kind, on: on) ?? symbol)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(on ? tint : .secondary)
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.bounce, value: on)
            }
        }
    }

    /// The on and off pictures of the kinds that have two; the device's own symbol for the rest.
    private func symbolFor(_ kind: HomeDevice.Kind, on: Bool) -> String? {
        switch kind {
        case .lock: return on ? "lock.open.fill" : "lock.fill"
        case .blinds: return on ? "blinds.horizontal.open" : "blinds.horizontal.closed"
        case .garage: return on ? "door.garage.open" : "door.garage.closed"
        default: return nil
        }
    }
}

/// The Sonos Arc and the Cync devices (GE's lights and plugs, in Apple Home) live in the Master Bedroom: each put
/// there once (moving one later in its settings sticks).
@MainActor enum ArcRoom {
    static func place() {
        let home = SmartHome.shared
        let rooms = homeRooms(Fleet.shared)
        let master = rooms.first { AllDevicesView.key($0) == AllDevicesView.key("Master Bedroom") } ?? "Master Bedroom"
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: "arcPlacedInMasterBedroom"),
           let arc = home.speakers.first(where: { ($0.model ?? "").localizedCaseInsensitiveContains("arc") || $0.name.localizedCaseInsensitiveContains("arc") }) {
            home.setRoom(arc.id, master)
            defaults.set(true, forKey: "arcPlacedInMasterBedroom")
        }
        var placed = Set(defaults.stringArray(forKey: "cyncPlacedInMasterBedroom") ?? [])
        let before = placed.count
        // Cync's name, or its maker's as Apple Home gives it (GE Lighting, or Savant, who make Cync now).
        func isCync(_ words: String?...) -> Bool {
            words.contains { w in ["cync", "ge lighting", "savant"].contains { (w ?? "").range(of: $0, options: .caseInsensitive) != nil } }
        }
        var ids: [String] = []
        ids += home.lights.filter { $0.isCync || ($0.isHome && isCync($0.name, $0.sku)) }.map(\.id)
        ids += AccessoryStore.shared.all.filter { $0.source == "home" && isCync($0.name, $0.product) }.map(\.id)
        for id in ids where !placed.contains(id) {
            home.setRoom(id, master)
            placed.insert(id)
        }
        if placed.count != before { defaults.set(Array(placed), forKey: "cyncPlacedInMasterBedroom") }
    }
}

/// A TV, drawn like a modern one: a thin black panel on two slim feet, just below it. On, its screen glows a deep blue with a soft
/// reflection; while something plays, three bars bounce gently in the middle of it. Off, the glass is dark.
struct TVPicture: View {
    var on: Bool
    var playing: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            let panelH = h * 0.8
            TimelineView(.animation(minimumInterval: 1.0 / 24, paused: !(on && playing) || reduceMotion)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                ZStack(alignment: .top) {
                    // Its two slim feet, behind the panel, starting just below it.
                    HStack {
                        Capsule().fill(LinearGradient(colors: [Color(white: 0.55), Color(white: 0.25)], startPoint: .top, endPoint: .bottom)).frame(width: 3, height: (h - panelH) * 0.5)
                        Spacer()
                        Capsule().fill(LinearGradient(colors: [Color(white: 0.55), Color(white: 0.25)], startPoint: .top, endPoint: .bottom)).frame(width: 3, height: (h - panelH) * 0.5)
                    }
                    .frame(width: w * 0.72)
                    .offset(y: panelH)
                    // The light the screen throws behind it.
                    if on {
                        RoundedRectangle(cornerRadius: 6).fill(Color(red: 0.25, green: 0.55, blue: 1).opacity(0.45))
                            .frame(width: w * 0.9, height: panelH * 0.8).blur(radius: 9).offset(y: panelH * 0.1)
                    }
                    // The panel: a hairline black bezel round the glass.
                    RoundedRectangle(cornerRadius: w * 0.04, style: .continuous)
                        .fill(LinearGradient(colors: [Color(white: 0.2), Color(white: 0.05)], startPoint: .top, endPoint: .bottom))
                        .frame(width: w, height: panelH)
                    RoundedRectangle(cornerRadius: w * 0.025, style: .continuous)
                        .fill(on ? AnyShapeStyle(LinearGradient(colors: [Color(red: 0.12, green: 0.32, blue: 0.85), Color(red: 0.02, green: 0.1, blue: 0.35)],
                                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                                 : AnyShapeStyle(LinearGradient(colors: [Color(white: 0.13), Color(white: 0.03)], startPoint: .topLeading, endPoint: .bottomTrailing)))
                        .overlay {
                            // A diagonal reflection across the glass.
                            LinearGradient(colors: [.white.opacity(on ? 0.16 : 0.1), .clear], startPoint: .topLeading, endPoint: .center)
                                .clipShape(RoundedRectangle(cornerRadius: w * 0.025, style: .continuous))
                        }
                        .overlay {
                            if on && playing {
                                HStack(alignment: .bottom, spacing: w * 0.045) {
                                    ForEach(0..<3) { i in
                                        let phase = reduceMotion ? 0.6 : (sin(t * 4 + Double(i) * 1.4) + 1) / 2
                                        Capsule().fill(.white.opacity(0.95))
                                            .frame(width: w * 0.055, height: panelH * (0.18 + 0.32 * phase))
                                    }
                                }
                                .frame(height: panelH * 0.55, alignment: .bottom)
                                .shadow(color: .white.opacity(0.5), radius: 3)
                            }
                        }
                        .padding(w * 0.03)
                        .frame(width: w, height: panelH)
                }
                .frame(width: w, height: h, alignment: .top)
            }
        }
    }

}

/// An ecobee Smart Thermostat Enhanced, drawn like the real one: a glossy black rounded square; across the top the
/// weather, what it's doing (a snowflake cooling, a flame heating) and the menu; the humidity; the room's temperature
/// large and thin; the set temperature in its blue (or orange) pill; and the ecobee wordmark. Cooling, the snowflake
/// turns slowly in a cool glow; heating, the flame flickers in a warm one.
struct EcobeePicture: View {
    var device: HomeDevice
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var cooling: Bool { device.action == "cooling" }
    private var heating: Bool { device.action == "heating" }
    private var mode: String { device.thermostatMode ?? (device.heatTo != nil && device.coolTo == nil ? "heat" : "cool") }

    /// "72" from °C.
    private func degrees(_ c: Double?) -> String {
        guard let c else { return "--" }
        return String(temperatureText(c).filter(\.isNumber))
    }

    private var setpoint: String? {
        switch mode {
        case "off": return nil
        case "heat": return degrees(device.heatTo ?? device.target)
        case "cool": return degrees(device.coolTo ?? device.target)
        default: return [device.heatTo, device.coolTo].compactMap { $0 }.map(degrees).joined(separator: "–")
        }
    }

    var body: some View {
        GeometryReader { g in
            let s = min(g.size.width, g.size.height)
            let detailed = s >= 90
            // As small as an icon (Home's thermostat pill): the body and what it's doing, nothing else.
            let tiny = s < 40
            let heatLook = heating || (mode == "heat" && !cooling)
            let accent: Color = heatLook ? .orange : mode == "off" ? .gray : Color(red: 0.16, green: 0.5, blue: 1)
            // Moving only while it heats or cools, and never in the tiny chip (always on screen, it would run all day).
            TimelineView(.animation(minimumInterval: 1.0 / 10, paused: tiny || !(cooling || heating) || reduceMotion)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                let pulse = reduceMotion ? 0.5 : (sin(t * 2) + 1) / 2
                ZStack {
                    // The body: glossy black, its edge catching the light from the top left.
                    RoundedRectangle(cornerRadius: s * 0.27, style: .continuous)
                        .fill(LinearGradient(colors: [Color(white: 0.13), Color(white: 0.02)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    RoundedRectangle(cornerRadius: s * 0.27, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.08), .white.opacity(0.25)],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing),
                                      lineWidth: max(0.8, s * 0.022))
                    // A soft reflection across the top of the glass.
                    RoundedRectangle(cornerRadius: s * 0.22, style: .continuous)
                        .fill(LinearGradient(colors: [.white.opacity(0.07), .clear], startPoint: .top, endPoint: .center))
                        .padding(s * 0.05)
                    if cooling || heating {
                        Circle().fill(accent.opacity(0.14 + 0.14 * pulse)).blur(radius: s * 0.14).frame(width: s * 0.62)
                    }
                    if tiny {
                        modeSymbol(t: t, pulse: pulse).font(.system(size: s * 0.42, weight: .semibold))
                    } else {
                    VStack(spacing: 0) {
                        // Across the top: the weather, what it's doing, the menu.
                        HStack(alignment: .center) {
                            if detailed { Image(systemName: "cloud.sun").foregroundStyle(.white.opacity(0.75)) }
                            Spacer(minLength: 0)
                            modeSymbol(t: t, pulse: pulse)
                            Spacer(minLength: 0)
                            if detailed { Image(systemName: "line.3.horizontal").foregroundStyle(.white.opacity(0.75)) }
                        }
                        .font(.system(size: s * 0.085, weight: .regular))
                        .frame(height: s * 0.12)
                        .padding(.horizontal, s * 0.1)
                        if detailed, let h = device.humidity {
                            HStack(spacing: s * 0.02) {
                                Image(systemName: "drop")
                                Text("\(h)%")
                                Text("|").opacity(0.5)
                                Image(systemName: "wind")
                                Text("Great")
                            }
                            .font(.system(size: s * 0.05, weight: .medium))
                            .foregroundStyle(.white.opacity(0.7))
                            .padding(.top, s * 0.04)
                        }
                        // The room's temperature, large and thin.
                        Text(degrees(device.temperature))
                            .font(.system(size: s * (detailed ? 0.3 : 0.38), weight: .ultraLight))
                            .foregroundStyle(.white)
                            .monospacedDigit()
                            .minimumScaleFactor(0.5)
                            .lineLimit(1)
                            .padding(.top, s * (detailed ? 0.01 : 0.02))
                        // The set temperature, in its pill.
                        if let sp = setpoint {
                            Text(sp)
                                .font(.system(size: s * 0.075, weight: .bold))
                                .foregroundStyle(accent)
                                .padding(.horizontal, s * 0.06).padding(.vertical, s * 0.018)
                                .overlay(Capsule().strokeBorder(accent, lineWidth: max(0.8, s * 0.016)))
                        }
                        Spacer(minLength: 0)
                        if detailed {
                            Text("ecobee").font(.system(size: s * 0.055, weight: .regular)).foregroundStyle(.white.opacity(0.35))
                        }
                    }
                    .padding(.top, s * 0.11)
                    .padding(.bottom, s * 0.07)
                    }
                }
                .frame(width: s, height: s)
            }
            .frame(width: g.size.width, height: g.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    /// The snowflake (cooling, turning) or the flame (heating, flickering) or the power sign (off).
    @ViewBuilder private func modeSymbol(t: Double, pulse: Double) -> some View {
        if mode == "off" {
            Image(systemName: "power").foregroundStyle(.white.opacity(0.6))
        } else if heating || (mode == "heat" && !cooling) {
            Image(systemName: "flame.fill")
                .foregroundStyle(heating ? Color.orange : .white.opacity(0.85))
                .scaleEffect(heating && !reduceMotion ? 0.9 + 0.15 * pulse : 1, anchor: .bottom)
        } else {
            Image(systemName: "snowflake")
                .foregroundStyle(.white)
                .rotationEffect(.degrees(cooling && !reduceMotion ? t * 25 : 0))
        }
    }
}

/// A Dreo fan, drawn like the real ones. The TurboPoly Table Fan 511S: a round head (thin silver rim, black spiral
/// grille, silver ring badge) held in a silver U-shaped yoke that wraps under it and pivots at both sides, on a short
/// column with a black front, on a wide two-tone round base. The pedestal circulator: a black head on a slim pole.
/// The blades turn behind the grille while it's on, faster at higher speeds.
struct DreoFanPicture: View {
    var pedestal: Bool
    var on: Bool
    /// 0…1.
    var speed: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if pedestal { pedestalFan } else { tableFan }
    }

    private static let silver = [Color(white: 0.96), Color(white: 0.74), Color(white: 0.5)]

    /// The black grille with its spiral ribs, the blades turning behind it, and the badge.
    private func head(_ d: CGFloat, rim: [Color], badge: [Color]) -> some View {
        ZStack {
            Circle().fill(LinearGradient(colors: rim, startPoint: .topLeading, endPoint: .bottomTrailing))
            Circle().fill(Color(white: 0.04)).padding(d * 0.045)
            // The blades behind the grille, turning while it's on.
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !on || reduceMotion)) { ctx in
                let turn = on && !reduceMotion ? ctx.date.timeIntervalSinceReferenceDate * (200 + 500 * max(0.1, speed)) : 0
                ZStack {
                    FanBlades()
                        .fill(LinearGradient(colors: [Color(white: on ? 0.42 : 0.34), Color(white: on ? 0.2 : 0.14)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                    FanBlades().stroke(.white.opacity(0.12), lineWidth: max(0.3, d * 0.006))
                }
                .rotationEffect(.degrees(turn))
                .blur(radius: on && !reduceMotion ? d * 0.01 : 0)
            }
            .padding(d * 0.1)
            // The grille: spiral ribs from the badge to the rim.
            SpiralGrille().stroke(Color(white: 0.32), lineWidth: max(0.35, d * 0.012)).padding(d * 0.05)
            // A soft reflection across the grille's front.
            Circle().fill(LinearGradient(colors: [.white.opacity(0.1), .clear], startPoint: .topLeading, endPoint: .center))
                .padding(d * 0.05)
            // Light catching the rim at the top left, and a soft edge all round.
            Circle().trim(from: 0.56, to: 0.78).stroke(.white.opacity(0.55), style: StrokeStyle(lineWidth: max(0.6, d * 0.022), lineCap: .round))
                .padding(d * 0.012)
            Circle().strokeBorder(.white.opacity(0.14), lineWidth: 0.5)
            // The badge: a silver ring round a black centre.
            Circle().fill(LinearGradient(colors: badge, startPoint: .topLeading, endPoint: .bottomTrailing)).frame(width: d * 0.28)
            Circle().fill(Color(white: 0.06)).frame(width: d * 0.21)
            if on { Circle().fill(Color.cyan).frame(width: d * 0.05).shadow(color: .cyan, radius: 2) }
        }
        .frame(width: d, height: d)
    }

    private var tableFan: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            let d = w * 0.8, r = d / 2
            let cx = w / 2, cy = r + h * 0.03
            let yokeR = r * 1.1
            let baseW = w * 0.6, baseH = h * 0.09
            let baseTop = h - baseH
            let columnTop = cy + yokeR - h * 0.02
            ZStack(alignment: .topLeading) {
                // The base: a wide disc, silver on top, dark below, its shadow on the table.
                Ellipse().fill(.black.opacity(0.35)).frame(width: baseW * 1.05, height: baseH * 0.7).blur(radius: 1)
                    .position(x: cx, y: h - baseH * 0.25)
                Capsule().fill(LinearGradient(colors: [Color(white: 0.32), Color(white: 0.14)], startPoint: .top, endPoint: .bottom))
                    .frame(width: baseW, height: baseH * 0.75).position(x: cx, y: h - baseH * 0.42)
                Ellipse().fill(LinearGradient(colors: Self.silver, startPoint: .top, endPoint: .bottom))
                    .frame(width: baseW, height: baseH * 0.6).position(x: cx, y: baseTop + baseH * 0.3)
                // The column, silver with its black front panel.
                RoundedRectangle(cornerRadius: w * 0.03, style: .continuous)
                    .fill(LinearGradient(colors: Self.silver, startPoint: .leading, endPoint: .trailing))
                    .frame(width: w * 0.22, height: baseTop - columnTop + baseH * 0.3)
                    .overlay(RoundedRectangle(cornerRadius: w * 0.02, style: .continuous).fill(Color(white: 0.06)).padding(w * 0.03).padding(.bottom, baseH * 0.2))
                    .position(x: cx, y: (columnTop + baseTop + baseH * 0.3) / 2)
                // The yoke: a silver U round the bottom of the head, up to its pivots at both sides.
                Circle().trim(from: 0.0, to: 0.5)
                    .stroke(LinearGradient(colors: Self.silver, startPoint: .top, endPoint: .bottom),
                            style: StrokeStyle(lineWidth: w * 0.05, lineCap: .round))
                    .frame(width: yokeR * 2, height: yokeR * 2)
                    .position(x: cx, y: cy)
                ForEach([-1.0, 1.0], id: \.self) { side in
                    RoundedRectangle(cornerRadius: w * 0.02, style: .continuous)
                        .fill(LinearGradient(colors: Self.silver, startPoint: .top, endPoint: .bottom))
                        .frame(width: w * 0.055, height: r * 0.42)
                        .position(x: cx + CGFloat(side) * yokeR, y: cy - r * 0.05)
                }
                head(d, rim: Self.silver, badge: Self.silver).position(x: cx, y: cy)
            }
            .frame(width: w, height: h)
        }
    }

    /// The pedestal circulator: a small black head with its side bracket, a neck tapering into a tall slim pole with a
    /// silver band near the bottom, and a small dark base.
    private var pedestalFan: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            let d = min(w * 0.52, h * 0.33), r = d / 2
            let cx = w / 2, cy = r + h * 0.02
            let baseW = d * 0.78, baseH = h * 0.055
            let poleW = max(1.8, w * 0.06)
            let poleTop = cy + r * 0.85, poleBottom = h - baseH * 0.6
            ZStack(alignment: .topLeading) {
                // Its shadow, and the base: a small dark disc, lit along its top.
                Ellipse().fill(.black.opacity(0.35)).frame(width: baseW * 1.08, height: baseH * 0.8).blur(radius: 1)
                    .position(x: cx, y: h - baseH * 0.3)
                Ellipse().fill(LinearGradient(colors: [Color(white: 0.36), Color(white: 0.1)], startPoint: .top, endPoint: .bottom))
                    .frame(width: baseW, height: baseH).position(x: cx, y: h - baseH * 0.6)
                // Light along the top of the base.
                Ellipse().fill(.white.opacity(0.12)).frame(width: baseW * 0.8, height: baseH * 0.45)
                    .position(x: cx, y: h - baseH * 0.78)
                // The pole, satin black, with a silver band just above the base.
                Capsule().fill(LinearGradient(colors: [Color(white: 0.34), Color(white: 0.07), Color(white: 0.2)], startPoint: .leading, endPoint: .trailing))
                    .frame(width: poleW, height: poleBottom - poleTop)
                    .position(x: cx, y: (poleTop + poleBottom) / 2)
                // A fine highlight down its left edge.
                Capsule().fill(.white.opacity(0.18)).frame(width: max(0.5, poleW * 0.2), height: (poleBottom - poleTop) * 0.9)
                    .position(x: cx - poleW * 0.28, y: (poleTop + poleBottom) / 2)
                Rectangle().fill(LinearGradient(colors: Self.silver, startPoint: .leading, endPoint: .trailing))
                    .frame(width: poleW * 0.8, height: h * 0.06)
                    .position(x: cx, y: poleBottom - h * 0.05)
                // The neck: widening smoothly from the pole up into the bottom of the head.
                Capsule().fill(LinearGradient(colors: [Color(white: 0.28), Color(white: 0.07), Color(white: 0.16)], startPoint: .leading, endPoint: .trailing))
                    .frame(width: poleW * 2, height: r * 0.7).position(x: cx, y: cy + r * 0.9)
                head(d, rim: [Color(white: 0.34), Color(white: 0.12), Color(white: 0.05)],
                     badge: [Color(white: 0.92), Color(white: 0.6)])
                    .position(x: cx, y: cy)
            }
            .frame(width: w, height: h)
        }
    }
}

/// A fan grille's ribs: curved spokes spiralling from the middle out to the rim.
private struct SpiralGrille: Shape {
    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = min(rect.width, rect.height) / 2
        var p = Path()
        for i in 0..<24 {
            let a = Double(i) / 24 * 2 * .pi
            func pt(_ angle: Double, _ radius: CGFloat) -> CGPoint {
                CGPoint(x: c.x + cos(angle) * radius, y: c.y + sin(angle) * radius)
            }
            p.move(to: pt(a, r * 0.16))
            p.addQuadCurve(to: pt(a + 1.1, r), control: pt(a + 0.35, r * 0.72))
        }
        // A ring part way out.
        p.addEllipse(in: CGRect(x: c.x - r * 0.55, y: c.y - r * 0.55, width: r * 1.1, height: r * 1.1))
        return p
    }
}

/// Five broad blades, each sweeping round from the hub.
private struct FanBlades: Shape {
    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = min(rect.width, rect.height) / 2
        var p = Path()
        for i in 0..<5 {
            let a = Double(i) / 5 * 2 * .pi
            func pt(_ angle: Double, _ radius: CGFloat) -> CGPoint {
                CGPoint(x: c.x + cos(angle) * radius, y: c.y + sin(angle) * radius)
            }
            p.move(to: pt(a, r * 0.2))
            p.addQuadCurve(to: pt(a + 0.55, r * 0.98), control: pt(a - 0.15, r * 0.75))
            p.addQuadCurve(to: pt(a + 0.95, r * 0.6), control: pt(a + 0.95, r * 1.0))
            p.addQuadCurve(to: pt(a + 0.6, r * 0.2), control: pt(a + 0.75, r * 0.3))
            p.closeSubpath()
        }
        return p
    }
}


/// A Sonos Arc, drawn like the real thing: a long, slim, rounded bar in matte black with its perforated grille wrapping
/// the whole front, a soft sheen along the top and its small status light; while it plays, sound ripples out above it.
struct SoundbarPicture: View {
    var on: Bool
    var tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Only the sound moves: the bar and its grille are drawn once, the ripples behind them 15 times a second.
        ZStack {
            if on {
                TimelineView(.animation(minimumInterval: 1.0 / 15, paused: reduceMotion)) { ctx in
                    let t = ctx.date.timeIntervalSinceReferenceDate
                    Canvas { g, size in
                        let w = size.width, h = size.height
                        let bar = Self.bar(size)
                        // Sound rippling out above it while it plays: three soft arcs, each fading as it rises.
                        for i in 0..<3 {
                            let phase = reduceMotion ? Double(i) / 3 : (t * 0.6 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                            let rise = bar.minY - 2.5 - CGFloat(phase) * h * 0.45
                            let spread = w * (0.28 + 0.24 * CGFloat(phase))
                            var arc = Path()
                            arc.move(to: CGPoint(x: w / 2 - spread / 2, y: rise + 3))
                            arc.addQuadCurve(to: CGPoint(x: w / 2 + spread / 2, y: rise + 3), control: CGPoint(x: w / 2, y: rise - 2))
                            g.stroke(arc, with: .color(tint.opacity(0.85 * (1 - phase))), style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
                        }
                    }
                }
            }
            Canvas { g, size in
                let w = size.width
                let bar = Self.bar(size)
                let shape = Path(roundedRect: bar, cornerRadius: bar.height / 2, style: .continuous)
                // The body: matte black, lighter along the top as the real one catches the light.
                let top = on ? Color(white: 0.30) : Color(white: 0.55)
                let bottom = on ? Color(white: 0.06) : Color(white: 0.32)
                g.fill(shape, with: .linearGradient(Gradient(colors: [top, bottom]),
                                                    startPoint: CGPoint(x: 0, y: bar.minY), endPoint: CGPoint(x: 0, y: bar.maxY)))
                // The grille: fine holes in staggered rows across almost all of the front.
                g.clip(to: shape)
                let hole: CGFloat = 0.6
                let stepX: CGFloat = 1.25, stepY: CGFloat = 1.05
                var y = bar.minY + 0.9
                var row = 0
                while y < bar.maxY - 0.6 {
                    var x = bar.minX + bar.height * 0.45 + (row % 2 == 0 ? 0 : stepX / 2)
                    while x < bar.maxX - bar.height * 0.45 {
                        g.fill(Path(ellipseIn: CGRect(x: x, y: y, width: hole, height: hole)), with: .color(.black.opacity(on ? 0.55 : 0.35)))
                        x += stepX
                    }
                    y += stepY
                    row += 1
                }
                // A thin sheen along the top edge.
                var sheen = Path()
                sheen.move(to: CGPoint(x: bar.minX + bar.height / 2, y: bar.minY + 0.6))
                sheen.addLine(to: CGPoint(x: bar.maxX - bar.height / 2, y: bar.minY + 0.6))
                g.stroke(sheen, with: .color(.white.opacity(0.18)), lineWidth: 0.5)
                // Its status light, on the top in the middle: white while it plays.
                if on {
                    g.fill(Path(ellipseIn: CGRect(x: w / 2 - 0.6, y: bar.minY + 0.3, width: 1.2, height: 1.2)), with: .color(.white))
                }
            }
        }
    }

    /// Where the bar sits in a picture of [size].
    private static func bar(_ size: CGSize) -> CGRect {
        CGRect(x: 0.5, y: size.height * 0.68, width: size.width - 1, height: size.height * 0.2)
    }
}

/// A small remote for one TV, from All Devices: what it's playing, play or pause, back and ahead, mute and volume, on
/// clear Liquid Glass.
struct MiniRemote: View {
    var tvID: String
    @Environment(Fleet.self) private var fleet
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let tv = fleet.tv(tvID)
        let p = tv?.nowPlaying
        VStack(spacing: 18) {
            VStack(spacing: 3) {
                Text(tv?.name ?? "TV").font(.headline)
                Text(tv?.online == false ? "Turning on…" : p?.title ?? "Nothing playing")
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack(spacing: 14) {
                key("gobackward.10", "Back 10 Seconds") { await media("back10") }
                key(p?.isPlaying == true ? "pause.fill" : "play.fill", p?.isPlaying == true ? "Pause" : "Play", big: true) { await press("playpause") }
                key("goforward.30", "Ahead 30 Seconds") { await media("fwd30") }
            }
            HStack(spacing: 14) {
                key("speaker.minus.fill", "Volume Down") { await press("voldown") }
                key("speaker.slash.fill", "Mute") { await mute() }
                key("speaker.plus.fill", "Volume Up") { await press("volup") }
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity)
        .glass(RoundedRectangle(cornerRadius: 34, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .frame(maxHeight: .infinity, alignment: .bottom)
    }

    private func key(_ symbol: String, _ label: String, big: Bool = false, _ action: @escaping () async -> Void) -> some View {
        Button {
            #if os(iOS)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            #endif
            Task { await action() }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: big ? 26 : 20, weight: .semibold))
                .frame(width: big ? 76 : 64, height: big ? 64 : 52)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glass(Capsule(), interactive: true)
        .accessibilityLabel(label)
    }

    private func press(_ key: String) async {
        guard let c = client() else { return }
        do { try await c.key(key) } catch { fleet.show(error) }
    }

    private func media(_ action: String) async {
        guard let c = client() else { return }
        do { _ = try await c.media(action) } catch { fleet.show(error) }
    }

    /// The TV's connection, or why there isn't one (a key that did nothing used to say nothing).
    private func client() -> TVClient? {
        guard let tv = fleet.tv(tvID) else { fleet.say("TV Not Found", "That TV isn’t in Woodruff any more."); return nil }
        guard let c = fleet.client(for: tv) else {
            fleet.say("Can’t Reach \(tv.name)", tv.online ? "Try again in a moment." : "It’s off or still turning on. Try again in a moment.")
            return nil
        }
        return c
    }

    /// LG's own mute when it's linked (it knows whether it's muted); otherwise the mute key.
    private func mute() async {
        guard let tv = fleet.tv(tvID) else { return }
        if let lg = fleet.lg(for: tv), let v = try? await lg.volume() {
            do { try await lg.setMute(!v.muted) } catch { fleet.show(error) }
        } else {
            await press("mute")
        }
    }
}
