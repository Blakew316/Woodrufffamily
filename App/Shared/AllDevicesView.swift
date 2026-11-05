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
    static let order = ["Master Bedroom", "Living Room", "Haley's Sewing Room", "Elliott's Room", "Kyler's Room"]

    /// A room's name to compare by: letters only, lowercase, and Elliot/Elliott the same.
    static func key(_ room: String) -> String {
        room.lowercased().filter(\.isLetter).replacingOccurrences(of: "elliott", with: "elliot")
    }

    /// One room's section: the room as the devices have it, and its heading.
    struct RoomSection: Hashable { var room: String; var title: String }

    /// The sections, in order.
    private func sections(_ rooms: [String]) -> [RoomSection] {
        var out: [RoomSection] = []
        var used = Set<String>()
        for title in Self.order {
            for r in rooms where !used.contains(r) && Self.key(r) == Self.key(title) {
                out.append(RoomSection(room: r, title: title))
                used.insert(r)
            }
        }
        for r in rooms.sorted() where !used.contains(r) { out.append(RoomSection(room: r, title: r)) }
        if showOther { out.append(RoomSection(room: noRoom, title: "Other")) }
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
        let rooms = homeRooms(fleet, devices: devices).filter { $0 != noRoom && !$0.isEmpty }
        VStack(alignment: .leading, spacing: 26) {
            ForEach(sections(rooms), id: \.room) { section in
                let items = items(in: section.room, devices: devices)
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
                .frame(width: 46, height: 46)
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
            return Facts(name: l.name, state: state, on: l.isLit, reachable: !l.isOffline, look: .light, tint: l.shade)
        case .device(let d) where d.product?.hasPrefix("HomePod") == true:
            return Facts(name: d.name, state: d.reachable ? d.status : "Not Responding", on: false, reachable: d.reachable,
                         look: .homePod(mini: d.product == "HomePod mini"), tint: .gray)
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
        case device(HomeDevice.Kind, running: Bool, symbol: String)
    }

    var look: Look
    var on: Bool
    var tint: Color

    var body: some View {
        ZStack {
            Circle()
                .fill(on ? AnyShapeStyle(tint.opacity(0.22)) : AnyShapeStyle(Color.white.opacity(0.12)))
            if on {
                // A soft glow behind it while it's on.
                Circle().fill(tint.opacity(0.35)).blur(radius: 10).scaleEffect(0.8)
            }
            picture
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: on)
    }

    @ViewBuilder private var picture: some View {
        switch look {
        case .tv(let playing):
            Image(systemName: on ? "tv.fill" : "tv")
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(on ? tint : .secondary)
                .symbolEffect(.pulse, options: .repeating, isActive: on && playing)
                .symbolEffect(.bounce, value: on)
        case .speaker(let bar):
            if bar {
                SoundbarPicture(on: on, tint: tint).frame(width: 40, height: 30)
            } else {
                Image(systemName: on ? "hifispeaker.fill" : "hifispeaker")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(on ? tint : .secondary)
                    .symbolEffect(.variableColor.iterative, options: .repeating, isActive: on)
                    .symbolEffect(.bounce, value: on)
            }
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
                        let phase = reduceMotion ? Double(i) / 3 : (t * 0.9 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
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
