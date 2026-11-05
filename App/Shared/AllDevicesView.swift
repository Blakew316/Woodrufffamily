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
    @State private var openCamera: NestCameras.Camera?
    @State private var confirmUnlock: HomeDevice?
    /// Settings → General: devices that have no room, under Other at the end (off unless asked for).
    @AppStorage("allDevices.showOther") private var showOther = false

    /// The family's rooms first, in this order and spelled like this; any other room after them, by name.
    static let order = ["Master Bedroom", "Living Room", "Haley's Sewing Room", "Elliott's Room", "Kyler's Room"]

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
        case camera(NestCameras.Camera)
        case tv(FleetTV)
        case speaker(SonosRoom)
        case light(GoveeLight)
        case device(HomeDevice)

        var id: String {
            switch self {
            case .camera(let c): return "cam-" + c.id
            case .tv(let t): return "tv-" + t.id
            case .speaker(let s): return "sp-" + s.id
            case .light(let l): return "li-" + l.id
            case .device(let d): return "de-" + d.id
            }
        }
    }

    var body: some View {
        let devices = store.all
        let cameraRooms = NestCameras.shared.cameras.compactMap { home.rooms[$0.id] ?? $0.room }
        let rooms = Array(Set(homeRooms(fleet, devices: devices) + cameraRooms)).filter { $0 != noRoom && !$0.isEmpty }
        VStack(alignment: .leading, spacing: 26) {
            ForEach(sections(rooms), id: \.title) { section in
                let items = section.rooms.flatMap { items(in: $0, devices: devices) }
                if !items.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(section.title).font(.title3.bold())
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                            ForEach(items) { item in tile(item) }
                        }
                    }
                }
            }
        }
        .onAppear { ArcRoom.place() }
        .onChange(of: home.speakers.count) { _, _ in ArcRoom.place() }
        .cameraPresenter($openCamera)
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

    /// Everything in [room]: TVs first, then speakers, lights and devices, each by name.
    private func items(in room: String, devices: [HomeDevice]) -> [Item] {
        var out: [Item] = []
        out += NestCameras.shared.cameras.filter { roomMatches(home.rooms[$0.id] ?? $0.room, room) }
            .sorted { $0.name < $1.name }.map { .camera($0) }
        out += fleet.tvs.filter { !$0.isUnpaired && roomMatches(home.rooms[$0.id] ?? $0.name, room) }
            .sorted { $0.name < $1.name }.map { .tv($0) }
        out += home.speakers.filter { roomMatches(home.room(of: $0.id), room) }.sorted { $0.name < $1.name }.map { .speaker($0) }
        out += home.lights.filter { roomMatches(home.room(of: $0.id), room) }.sorted { $0.name < $1.name }.map { .light($0) }
        out += devices.filter { roomMatches(home.room(of: $0.id), room) }.sorted { $0.name < $1.name }.map { .device($0) }
        return out
    }

    // MARK: One tile

    private func tile(_ item: Item) -> some View {
        let f = facts(item)
        return VStack(alignment: .leading, spacing: 0) {
            DeviceGlyph(look: f.look, on: f.on, tint: f.tint)
                .frame(width: 58, height: 56, alignment: .leading)
            Spacer(minLength: 8)
            Text(f.name).font(.footnote.weight(.semibold)).lineLimit(2).multilineTextAlignment(.leading)
            // Two lines, so a TV's title reads in full more often.
            Text(f.state).font(.caption)
                .foregroundStyle(f.on ? Color.black.opacity(0.55) : .secondary).lineLimit(2)
        }
        .foregroundStyle(f.on ? Color.black : .primary)
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
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
        case .camera(let c):
            return Facts(name: c.name, state: c.online ? (c.doorbell ? "Doorbell" : "Live") : "Offline", on: c.online, reachable: c.online,
                         look: .camera(doorbell: c.doorbell), tint: .green)
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
            let state = l.isOffline ? "Offline" : l.isLit ? "\(l.brightness)%" : "Off"
            return Facts(name: l.name, state: state, on: l.isLit, reachable: !l.isOffline,
                         look: l.isFloorLamp ? .floorLamp(level: Double(l.brightness) / 100) : .light, tint: l.shade)
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
        case .camera(let c):
            openCamera = c
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
        case .camera(let c): openCamera = c
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
        case camera(doorbell: Bool)
        case speaker(bar: Bool)
        case homePod(mini: Bool)
        case light
        case floorLamp(level: Double)
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
        case .tv, .camera, .floorLamp, .dreoFan, .thermostat: return true
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
        case .camera(let doorbell):
            CameraPicture(doorbell: doorbell, on: on).frame(width: 44, height: 52)
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
            DreoFanPicture(pedestal: pedestal, on: on, speed: speed).frame(width: 46, height: 56)
        case .floorLamp(let level):
            FloorLampPicture(level: level, lit: on, color: tint).frame(width: 34, height: 56)
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

/// The Sonos Arc lives in the Master Bedroom: put there once (moving it later in its settings sticks).
@MainActor enum ArcRoom {
    static func place() {
        guard !UserDefaults.standard.bool(forKey: "arcPlacedInMasterBedroom") else { return }
        let home = SmartHome.shared
        guard let arc = home.speakers.first(where: { ($0.model ?? "").localizedCaseInsensitiveContains("arc") || $0.name.localizedCaseInsensitiveContains("arc") }) else { return }
        let rooms = homeRooms(Fleet.shared)
        let master = rooms.first { AllDevicesView.key($0) == AllDevicesView.key("Master Bedroom") } ?? "Master Bedroom"
        home.setRoom(arc.id, master)
        UserDefaults.standard.set(true, forKey: "arcPlacedInMasterBedroom")
    }
}

/// A TV, drawn like a modern one: a thin black panel on two slim feet. On, its screen glows a deep blue with a soft
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
                    // Its two slim feet.
                    HStack {
                        foot
                        Spacer()
                        foot
                    }
                    .frame(width: w * 0.72)
                    .offset(y: panelH - 1)
                }
                .frame(width: w, height: h, alignment: .top)
            }
        }
    }

    private var foot: some View {
        Capsule().fill(LinearGradient(colors: [Color(white: 0.55), Color(white: 0.25)], startPoint: .top, endPoint: .bottom))
            .frame(width: 3, height: 7)
            .rotationEffect(.degrees(0))
    }
}

/// A Nest camera: the round lens head on its stand (an indoor or outdoor cam), or the tall Nest Doorbell with its
/// lens at the top and its ring button below. Its status light glows green while it's streaming.
struct CameraPicture: View {
    var doorbell: Bool
    var on: Bool

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            if doorbell {
                let bw = w * 0.5
                ZStack {
                    RoundedRectangle(cornerRadius: bw / 2, style: .continuous)
                        .fill(LinearGradient(colors: [Color(white: 0.96), Color(white: 0.78)], startPoint: .leading, endPoint: .trailing))
                        .overlay(RoundedRectangle(cornerRadius: bw / 2, style: .continuous).strokeBorder(.black.opacity(0.15), lineWidth: 0.5))
                    VStack(spacing: h * 0.07) {
                        lens(size: bw * 0.62)
                        Spacer()
                        // The button, ringed in light.
                        Circle().fill(Color(white: 0.2)).frame(width: bw * 0.5)
                            .overlay(Circle().strokeBorder(on ? Color(red: 0.4, green: 0.85, blue: 1) : Color(white: 0.6), lineWidth: 1.5))
                            .shadow(color: on ? .cyan.opacity(0.7) : .clear, radius: 3)
                    }
                    .padding(.vertical, bw * 0.18)
                }
                .frame(width: bw, height: h * 0.96)
                .frame(width: w, height: h)
            } else {
                let r = w * 0.36
                ZStack(alignment: .top) {
                    // The stand.
                    Capsule().fill(Color(white: 0.85)).frame(width: w * 0.12, height: h * 0.32).offset(y: r * 1.7)
                    Ellipse().fill(LinearGradient(colors: [Color(white: 0.92), Color(white: 0.7)], startPoint: .top, endPoint: .bottom))
                        .frame(width: w * 0.6, height: h * 0.1).offset(y: h * 0.86)
                    // The head: white, round, the black face with its lens.
                    Circle().fill(LinearGradient(colors: [Color(white: 0.98), Color(white: 0.78)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: r * 2)
                        .overlay(Circle().fill(Color(white: 0.08)).padding(r * 0.18))
                        .overlay(lens(size: r * 0.85))
                        .offset(y: h * 0.04)
                }
                .frame(width: w, height: h, alignment: .top)
            }
        }
    }

    private func lens(size: CGFloat) -> some View {
        ZStack {
            Circle().fill(RadialGradient(colors: [Color(red: 0.2, green: 0.25, blue: 0.4), .black], center: .center, startRadius: 0, endRadius: size / 2))
            Circle().fill(.white.opacity(0.55)).frame(width: size * 0.22).offset(x: -size * 0.15, y: -size * 0.15)
            // Its status light.
            Circle().fill(on ? Color.green : Color(white: 0.3)).frame(width: size * 0.16).offset(y: size * 0.62)
                .shadow(color: on ? .green : .clear, radius: 2)
        }
        .frame(width: size, height: size)
    }
}

/// An ecobee Smart Thermostat, drawn like the real one: a black rounded square with a glossy edge, the room's
/// temperature large in the middle, the set temperature in a pill under it, and what it's doing at the top. Cooling,
/// the snowflake turns slowly in a cool blue glow; heating, a flame flickers in a warm one.
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
            let accent: Color = heating || mode == "heat" ? .orange : mode == "off" ? .gray : Color(red: 0.2, green: 0.55, blue: 1)
            TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !(cooling || heating) || reduceMotion)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                let pulse = reduceMotion ? 0.5 : (sin(t * 2) + 1) / 2
                ZStack {
                    // The body: black, its edge catching the light.
                    RoundedRectangle(cornerRadius: s * 0.3, style: .continuous)
                        .fill(LinearGradient(colors: [Color(white: 0.16), .black], startPoint: .top, endPoint: .bottom))
                    RoundedRectangle(cornerRadius: s * 0.3, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0.06)], startPoint: .top, endPoint: .bottom),
                                      lineWidth: max(0.6, s * 0.02))
                    // While it's heating or cooling, its glow.
                    if cooling || heating {
                        Circle().fill(accent.opacity(0.18 + 0.17 * pulse)).blur(radius: s * 0.15).frame(width: s * 0.7)
                    }
                    VStack(spacing: s * 0.03) {
                        // What it's doing, at the top.
                        Group {
                            if heating || (mode == "heat" && !cooling) {
                                Image(systemName: "flame.fill")
                                    .foregroundStyle(heating ? .orange : .white.opacity(0.7))
                                    .scaleEffect(heating && !reduceMotion ? 0.9 + 0.15 * pulse : 1, anchor: .bottom)
                            } else if mode == "off" {
                                Image(systemName: "power").foregroundStyle(.white.opacity(0.6))
                            } else {
                                Image(systemName: "snowflake")
                                    .foregroundStyle(.white.opacity(cooling ? 1 : 0.7))
                                    .rotationEffect(.degrees(cooling && !reduceMotion ? t * 25 : 0))
                            }
                        }
                        .font(.system(size: s * 0.13, weight: .semibold))
                        .frame(height: s * 0.15)
                        // The room's temperature.
                        Text(degrees(device.temperature))
                            .font(.system(size: s * 0.34, weight: .light, design: .default))
                            .foregroundStyle(.white)
                            .monospacedDigit()
                            .minimumScaleFactor(0.5)
                            .lineLimit(1)
                        // The set temperature, in its pill.
                        if let sp = setpoint {
                            Text(sp)
                                .font(.system(size: s * 0.1, weight: .bold))
                                .foregroundStyle(accent)
                                .padding(.horizontal, s * 0.07).padding(.vertical, s * 0.02)
                                .overlay(Capsule().strokeBorder(accent, lineWidth: max(0.6, s * 0.018)))
                        }
                    }
                    .padding(s * 0.08)
                    // The wordmark, faint, at the bottom.
                    if s > 120 {
                        Text("ecobee").font(.system(size: s * 0.06, weight: .medium)).foregroundStyle(.white.opacity(0.35))
                            .frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, s * 0.05)
                    }
                }
                .frame(width: s, height: s)
            }
            .frame(width: g.size.width, height: g.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// A Dreo air circulator, drawn like the real one: a round head with its spiral grille and centre badge, on a curved
/// arm over a round base (the table circulator, silver), or on a slim pole (the pedestal one, black). The blades turn
/// while it's on, faster at higher speeds.
struct DreoFanPicture: View {
    var pedestal: Bool
    var on: Bool
    /// 0…1.
    var speed: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !on || reduceMotion)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            Canvas { g, size in
                let w = size.width, h = size.height
                let body = pedestal ? Color(white: 0.16) : Color(white: 0.72)
                let bodyDark = pedestal ? Color(white: 0.08) : Color(white: 0.45)
                // The head: a circle, its rim in the body's colour, the grille dark inside.
                let r = pedestal ? w * 0.34 : w * 0.38
                let cx = w / 2, cy = pedestal ? r + 1 : h * 0.4
                // Below the head: the pedestal's pole and base, or the table one's arm and base.
                let baseW = pedestal ? w * 0.6 : w * 0.72
                let baseH = h * (pedestal ? 0.08 : 0.1)
                let baseRect = CGRect(x: cx - baseW / 2, y: h - baseH, width: baseW, height: baseH)
                if pedestal {
                    let pole = CGRect(x: cx - w * 0.035, y: cy + r * 0.8, width: w * 0.07, height: baseRect.minY - (cy + r * 0.8) + 1)
                    g.fill(Path(roundedRect: pole, cornerRadius: w * 0.035), with: .color(body))
                    g.stroke(Path(roundedRect: pole, cornerRadius: w * 0.035), with: .color(.white.opacity(0.18)), lineWidth: 0.5)
                } else {
                    // The curved arm, round the back of the head down to the base.
                    var arm = Path()
                    arm.move(to: CGPoint(x: cx + r * 0.85, y: cy - r * 0.15))
                    arm.addQuadCurve(to: CGPoint(x: cx, y: cy + r * 1.25), control: CGPoint(x: cx + r * 1.15, y: cy + r * 1.05))
                    g.stroke(arm, with: .color(body), style: StrokeStyle(lineWidth: w * 0.07, lineCap: .round))
                    let neck = CGRect(x: cx - w * 0.05, y: cy + r * 1.2, width: w * 0.1, height: baseRect.minY - (cy + r * 1.2) + 1)
                    g.fill(Path(roundedRect: neck, cornerRadius: w * 0.04), with: .color(body))
                }
                // Its shadow on the floor, then the base: a disc, its top catching the light.
                g.fill(Path(ellipseIn: baseRect.insetBy(dx: -w * 0.04, dy: 0).offsetBy(dx: 0, dy: baseH * 0.3)), with: .color(.black.opacity(0.35)))
                g.fill(Path(ellipseIn: baseRect), with: .linearGradient(Gradient(colors: [bodyDark, body, bodyDark]),
                                                                         startPoint: CGPoint(x: baseRect.minX, y: 0), endPoint: CGPoint(x: baseRect.maxX, y: 0)))
                g.fill(Path(ellipseIn: baseRect.insetBy(dx: baseW * 0.06, dy: baseH * 0.12).offsetBy(dx: 0, dy: -baseH * 0.12)),
                       with: .color(.white.opacity(pedestal ? 0.08 : 0.25)))
                g.stroke(Path(ellipseIn: baseRect), with: .color(.white.opacity(0.2)), lineWidth: 0.5)
                let head = CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)
                // The rim: brushed metal (or satin black), lit from the top left.
                g.fill(Path(ellipseIn: head), with: .linearGradient(Gradient(colors: [pedestal ? Color(white: 0.3) : Color(white: 0.92), body, bodyDark]),
                                                                     startPoint: CGPoint(x: head.minX, y: head.minY), endPoint: CGPoint(x: head.maxX, y: head.maxY)))
                g.stroke(Path(ellipseIn: head), with: .color(.white.opacity(0.3)), lineWidth: 0.6)
                let grille = head.insetBy(dx: r * 0.12, dy: r * 0.12)
                g.fill(Path(ellipseIn: grille), with: .radialGradient(Gradient(colors: [Color(white: 0.14), Color(white: 0.03)]),
                                                                       center: CGPoint(x: cx, y: cy), startRadius: 0, endRadius: grille.width / 2))
                // The grille's rings, faint.
                for k in 1...3 {
                    let ring = grille.insetBy(dx: grille.width * 0.12 * CGFloat(k), dy: grille.width * 0.12 * CGFloat(k))
                    g.stroke(Path(ellipseIn: ring), with: .color(.white.opacity(0.07)), lineWidth: 0.4)
                }
                // The spiral grille: curved spokes, turning while it's on.
                let turn = reduceMotion || !on ? 0 : t * (2 + 6 * max(0.15, speed))
                let gr = grille.width / 2
                var spokes = Path()
                for i in 0..<20 {
                    let a = Double(i) / 20 * 2 * .pi + turn
                    let inner = CGPoint(x: cx + cos(a) * gr * 0.28, y: cy + sin(a) * gr * 0.28)
                    let outer = CGPoint(x: cx + cos(a + 0.9) * gr * 0.95, y: cy + sin(a + 0.9) * gr * 0.95)
                    let bend = CGPoint(x: cx + cos(a + 0.25) * gr * 0.75, y: cy + sin(a + 0.25) * gr * 0.75)
                    spokes.move(to: inner)
                    spokes.addQuadCurve(to: outer, control: bend)
                }
                g.stroke(spokes, with: .color(.white.opacity(on ? 0.3 : 0.32)), lineWidth: max(0.4, w * 0.012))
                // Spinning, the blades blur into a soft disc.
                if on {
                    g.fill(Path(ellipseIn: grille.insetBy(dx: grille.width * 0.12, dy: grille.width * 0.12)),
                           with: .color(.white.opacity(0.06 + 0.06 * min(1, speed))))
                }
                // A sheen across the top of the grille.
                var sheen = Path()
                sheen.addArc(center: CGPoint(x: cx, y: cy), radius: grille.width * 0.46, startAngle: .degrees(200), endAngle: .degrees(290), clockwise: false)
                g.stroke(sheen, with: .color(.white.opacity(0.18)), lineWidth: max(0.6, w * 0.02))
                // The badge in the middle.
                let hub = gr * 0.3
                g.fill(Path(ellipseIn: CGRect(x: cx - hub, y: cy - hub, width: hub * 2, height: hub * 2)),
                       with: .color(pedestal ? Color(white: 0.7) : Color(white: 0.12)))
                g.stroke(Path(ellipseIn: CGRect(x: cx - hub, y: cy - hub, width: hub * 2, height: hub * 2)),
                         with: .color(.white.opacity(0.5)), lineWidth: 0.5)
                // While it's on, a soft blue light at the hub.
                if on {
                    g.fill(Path(ellipseIn: CGRect(x: cx - hub * 0.35, y: cy - hub * 0.35, width: hub * 0.7, height: hub * 0.7)), with: .color(.cyan))
                }
            }
        }
    }
}

/// A Sonos Arc, drawn like the real thing: a long, slim, rounded bar in matte black with its perforated grille wrapping
/// the whole front, a soft sheen along the top and its small status light; while it plays, sound ripples out above it.
struct SoundbarPicture: View {
    var on: Bool
    var tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !on || reduceMotion)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            Canvas { g, size in
                let w = size.width, h = size.height
                let bar = CGRect(x: 0.5, y: h * 0.68, width: w - 1, height: h * 0.2)
                let shape = Path(roundedRect: bar, cornerRadius: bar.height / 2, style: .continuous)

                // Sound rippling out above it while it plays: three soft arcs, each fading as it rises.
                if on {
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
        guard let tv = fleet.tv(tvID), let c = fleet.client(for: tv) else { return }
        do { try await c.key(key) } catch { fleet.show(error) }
    }

    private func media(_ action: String) async {
        guard let tv = fleet.tv(tvID), let c = fleet.client(for: tv) else { return }
        do { _ = try await c.media(action) } catch { fleet.show(error) }
    }

    /// LG's own mute when it's linked (it knows whether it's muted); otherwise the mute key.
    private func mute() async {
        guard let tv = fleet.tv(tvID) else { return }
        if let lg = fleet.lg(for: tv), let v = try? await lg.volume() {
            try? await lg.setMute(!v.muted)
        } else {
            await press("mute")
        }
    }
}
