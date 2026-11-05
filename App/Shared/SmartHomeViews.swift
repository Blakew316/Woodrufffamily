import SwiftUI
import WoodruffKit

// Speakers and lights on Home, Apple Home style: a tile each, tap to act, hold (or right-click) for every control.

// MARK: - Speakers

struct SpeakersSection: View {
    var room: String? = nil
    /// Only the favourites (Home's Favorites).
    var favorites = false
    /// Off inside a room on Home (the room is the heading).
    var titled = true
    var home = SmartHome.shared
    @State private var open: SonosRoom?

    private var shown: [SonosRoom] {
        favorites ? HomeLayout.shared.favoritesOnly(home.speakers)
            : HomeLayout.shared.arrange(room.map { r in home.speakers.filter { roomMatches(home.room(of: $0.id), r) } } ?? home.speakers, in: "speakers")
    }

    var body: some View {
        if !shown.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                if titled { Text("Speakers").font(.title2.bold()) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 14)], spacing: 14) {
                    ForEach(shown) { r in
                        SpeakerTile(room: r) { open = r }
                    }
                }
            }
            .sheet(item: $open) { r in
                NavigationStack { SpeakerDetailView(speakerID: r.id, inSheet: true) }
                    .presentationBackground(.clear)
                    .macResizable()
            }
        }
    }
}

struct SpeakerTile: View {
    var room: SonosRoom
    var openControls: () -> Void
    var home = SmartHome.shared

    var body: some View {
        HStack(spacing: 10) {
            SpeakerArt(url: room.art, size: 38)
                .opacity(room.isOffline ? 0.45 : 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(room.name).font(.footnote.weight(.semibold)).lineLimit(1)
                if let e = home.speakerErrors[room.id] {
                    Text(e).font(.caption).foregroundStyle(Palette.attention).lineLimit(1)
                } else {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if room.canPlay {
                Button {
                    let r = room
                    Task { await SmartHome.shared.playPause(r) }
                } label: {
                    Image(systemName: room.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 30, height: 30)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .glass(Circle())
            } else if room.isOffline {
                Image(systemName: "wifi.slash").font(.caption).foregroundStyle(.secondary)
                    .accessibilityLabel("Offline")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 64, maxHeight: .infinity, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .glass(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onTapGesture { if HomeLayout.shared.tapsAllowed { openControls() } }
        .contextMenu {
            ArrangeHomeButton()
            if !room.isOffline {
                if room.canPlay {
                    Button(room.isPlaying ? "Pause" : "Play") {
                        let r = room
                        Task { await SmartHome.shared.playPause(r) }
                    }
                }
                if room.canPlay && !room.isTV {
                    Button("Next Track") { Task { await SmartHome.shared.sonos(room) { try await Sonos.next($0) } } }
                }
                Button(room.muted ? "Unmute" : "Mute") {
                    let r = room, mute = !room.muted
                    Task { await SmartHome.shared.setMute(r, mute) }
                }
                if room.hasTVInput && !room.isTV {
                    Button("Switch to TV Sound") {
                        let r = room
                        Task { await SmartHome.shared.playTV(r) }
                    }
                }
            }
            FavoriteButton(id: room.id)
        }
    }

    /// "Playing" shows just what; paused, stopped, grouped and offline say so.
    private var detail: String {
        if room.isOffline { return "Offline" }
        let others = room.groupNames.filter { $0 != room.name && $0 != room.zone }
        let group: String? = others.isEmpty ? nil : "+ " + (others.count == 1 ? others[0] : "\(others.count) rooms")
        if room.isTV {
            return [room.isPlaying ? "TV" : "TV · \(room.stateName)", group].compactMap { $0 }.joined(separator: " · ")
        }
        guard let t = room.title, !t.isEmpty else {
            return [room.state == "STOPPED" ? "Stopped" : (room.setupSummary ?? "Not Playing"), group].compactMap { $0 }.joined(separator: " · ")
        }
        let what = [t, room.artist].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        return room.isPlaying ? what : room.stateName + " · " + what
    }
}

struct SpeakerArt: View {
    var url: URL?
    var size: CGFloat
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.18, style: .continuous)
            .fill(.white.opacity(0.08))
            .overlay {
                if let url {
                    CachedImage(url: url) { Color.clear }
                } else {
                    Image(systemName: "hifispeaker.fill").font(.system(size: size * 0.38)).foregroundStyle(.secondary)
                }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.18, style: .continuous))
    }
}

// MARK: - Lights

struct LightsSection: View {
    var room: String? = nil
    /// Only the favourites (Home's Favorites).
    var favorites = false
    /// Off inside a room on Home (the room is the heading).
    var titled = true
    var home = SmartHome.shared
    @State private var open: GoveeLight?

    private var shown: [GoveeLight] {
        favorites ? HomeLayout.shared.favoritesOnly(home.lights)
            : HomeLayout.shared.arrange(room.map { r in home.lights.filter { roomMatches(home.room(of: $0.id), r) } } ?? home.lights, in: "lights")
    }

    var body: some View {
        if !shown.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    if titled { Text("Lights").font(.title2.bold()) }
                    Spacer()
                    if shown.contains(where: \.isLit) {
                        Button("All Off") { for l in shown where l.isLit { home.setOn(l, false) } }
                            .buttonStyle(.glass)
                    }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], spacing: 14) {
                    ForEach(shown) { l in
                        LightTile(light: l) { open = l }
                    }
                }
                if let e = home.goveeError {
                    Text(e).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .sheet(item: $open) { l in LightSheet(lightID: l.id).macResizable(width: 520, height: 640) }
        }
    }
}

extension LightColor {
    var color: Color { Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255) }
    static func kelvin(_ k: Int) -> Color {
        // Warm amber at 2000 K to cool blue-white at 9000 K.
        let t = max(0, min(1, Double(k - 2000) / 7000))
        return Color(red: 1, green: 0.72 + 0.26 * t, blue: 0.42 + 0.58 * t)
    }
}

extension GoveeLight {
    var shade: Color { color?.color ?? kelvin.map(LightColor.kelvin) ?? Color(red: 1, green: 0.86, blue: 0.62) }
}

/// Like a Home app accessory: lit up in the light's own colour when it's on, glass when it's off. Tap turns it
/// on or off; hold (or right-click) for brightness and colour.
struct LightTile: View {
    var light: GoveeLight
    var openControls: () -> Void

    var body: some View {
        // Unreachable (unplugged, off at the wall): never shown lit, and tapping opens its page rather than
        // sending a change that can't arrive.
        let lit = light.isLit
        // Compact, like the Home app: the light's colour on the left, its name and state beside it.
        HStack(spacing: 10) {
            Circle()
                .fill(lit ? light.shade : .white.opacity(0.18))
                .frame(width: 24, height: 24)
                .shadow(color: lit ? light.shade.opacity(0.9) : .clear, radius: 8)
                .overlay {
                    if light.isOffline { Image(systemName: "wifi.slash").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary) }
                }
            VStack(alignment: .leading, spacing: 1) {
                Text(light.name).font(.footnote.weight(.semibold)).lineLimit(2)
                Text(light.isOffline ? "Offline" : lit ? "\(light.brightness)%" : "Off").font(.caption)
                    .foregroundStyle(lit ? Color.black.opacity(0.55) : .secondary)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(lit ? Color.black : .primary)
        .opacity(light.isOffline ? 0.6 : 1)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 64, maxHeight: .infinity, alignment: .leading)
        .background {
            if lit {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(LinearGradient(colors: [.white.opacity(0.96), light.shade.opacity(0.55).mix(with: .white, by: 0.5)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .modifier(OffGlass(on: lit))
        .animation(.smooth(duration: 0.25), value: lit)
        .onTapGesture {
            guard HomeLayout.shared.tapsAllowed else { return }
            guard !light.isOffline else { openControls(); return }
            #if os(iOS)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            #endif
            SmartHome.shared.setOn(light, !light.on)
        }
        // Press and hold arranges Home's tiles (on the Mac too); the controls are in the menu (touch and hold on
        // iPhone, right-click on the Mac).
        .contextMenu {
            ArrangeHomeButton()
            if !light.isOffline {
                Button(light.on ? "Turn Off" : "Turn On") { SmartHome.shared.setOn(light, !light.on) }
            }
            Button("Controls…", action: openControls)
            FavoriteButton(id: light.id)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(light.isOffline ? "Offline" : lit ? "On, \(light.brightness)%" : "Off")
    }
}

private struct OffGlass: ViewModifier {
    var on: Bool
    func body(content: Content) -> some View {
        if on { content } else { content.glass(RoundedRectangle(cornerRadius: 20, style: .continuous)) }
    }
}

/// One light: a tall brightness bar (as in the Home app), colours, whites, and its name.
struct LightSheet: View {
    var lightID: String
    var home = SmartHome.shared
    @Environment(\.dismiss) private var dismiss
    @State private var level: Double = 100
    @State private var dragging = false
    @State private var name = ""

    private var light: GoveeLight? { home.lights.first { $0.id == lightID } }

    static let colors: [LightColor] = [
        LightColor(r: 255, g: 59, b: 48), LightColor(r: 255, g: 149, b: 0), LightColor(r: 255, g: 214, b: 10),
        LightColor(r: 52, g: 199, b: 89), LightColor(r: 0, g: 199, b: 190), LightColor(r: 10, g: 132, b: 255),
        LightColor(r: 94, g: 92, b: 230), LightColor(r: 191, g: 90, b: 242), LightColor(r: 255, g: 45, b: 85),
    ]
    static let whites = [2700, 4000, 5500, 6500]

    /// Showing this white (within a little: Apple Home rounds through mireds, Govee to its own range).
    static func isWhite(_ l: GoveeLight, _ k: Int) -> Bool {
        guard l.color == nil, let lk = l.kelvin else { return false }
        return abs(lk - (l.isHome ? k : l.clampKelvin(k))) < 80
    }

    /// Why an unreachable light might be, in a line.
    static func offlineHint(_ l: GoveeLight) -> String {
        if l.isHome {
            #if os(iOS)
            return "Not responding in Apple Home. Check it’s switched on at the wall."
            #else
            return "An Apple Home light: change it from Woodruff on iPhone."
            #endif
        }
        return "Not answering. Check it’s plugged in and on the Wi‑Fi; it comes back here by itself."
    }

    var body: some View {
        if let light {
            ScrollView {
            VStack(spacing: 22) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(light.name).font(.title3.bold())
                        Text(light.isOffline ? "Offline" : light.on || dragging ? "\(Int(level))%" : "Off")
                            .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Spacer()
                    GlassCircle(symbol: "xmark", size: 34) { dismiss() }
                }
                if light.isOffline {
                    Label(Self.offlineHint(light), systemImage: "wifi.slash")
                        .font(.footnote).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                // An unreachable light can't take a change: its controls rest until it's back.
                Group {
                    brightnessBar(light)
                        .allowsHitTesting(!light.isOffline)
                    Button(light.on ? "Turn Off" : "Turn On") { home.setOn(light, !light.on) }
                        .buttonStyle(.glass)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Colour").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                        swatches(Self.colors.map { c in (c.color, light.color == c, { home.setColor(light, c) }) })
                        Text("White").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 4)
                        swatches(Self.whites.map { k in (LightColor.kelvin(k), Self.isWhite(light, k), { home.setWhite(light, kelvin: k) }) })
                    }
                }
                .disabled(light.isOffline)
                .opacity(light.isOffline ? 0.4 : 1)
                HStack {
                    TextField("Name", text: $name)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .glass(Capsule(), interactive: false)
                        .onSubmit { home.rename(light.id, name) }
                    Button("Rename") { home.rename(light.id, name) }.buttonStyle(.glass)
                        .disabled(name.trimmingCharacters(in: .whitespaces) == light.name)
                }
            }
            .padding(24)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(minWidth: 340, idealWidth: 380)
            .onAppear { level = Double(light.brightness); name = light.name }
            .onChange(of: light.brightness) { _, v in if !dragging { level = Double(v) } }
            .presentationDetents([.large])
            .presentationBackground(.ultraThinMaterial)
        }
    }

    private func brightnessBar(_ light: GoveeLight) -> some View {
        // A light that's off shows the level under the finger too (letting go turns it on at that level).
        let shown = light.isLit || dragging
        return GeometryReader { g in
            Group {
                if light.isFloorLamp {
                    // The lamp itself: its bar lights from the base up to the level under the finger.
                    FloorLampPicture(level: level / 100, lit: shown, color: light.shade)
                } else {
                    ZStack(alignment: .bottom) {
                        Rectangle().fill(.white.opacity(0.12))
                        Rectangle().fill(shown ? light.shade : .white.opacity(0.3))
                            .frame(height: g.size.height * (shown ? level / 100 : 0))
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
                }
            }
            .contentShape(Rectangle())
            .highPriorityGesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    dragging = true
                    level = max(1, min(100, (1 - v.location.y / g.size.height) * 100)).rounded()
                }
                .onEnded { _ in
                    dragging = false
                    home.setBrightness(light, Int(level))
                })
        }
        .frame(width: 110, height: 250)
        .animation(.smooth(duration: 0.15), value: level)
    }

    private func swatches(_ items: [(Color, Bool, () -> Void)]) -> some View {
        HStack(spacing: 10) {
            ForEach(items.indices, id: \.self) { i in
                Button(action: items[i].2) {
                    Circle().fill(items[i].0)
                        .frame(width: 30, height: 30)
                        .overlay { if items[i].1 { Circle().strokeBorder(.white, lineWidth: 3) } }
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Speakers and Lights sections (like TVs)

/// Every room the house knows: the TVs' rooms, Sonos's rooms, and any chosen or added here.
@MainActor func allRooms(_ fleet: Fleet) -> [String] {
    let tvs = fleet.tvs.filter { !$0.isUnpaired }.map(\.name)
    return Array(Set(tvs).union(SmartHome.shared.knownRooms)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
}

struct SpeakersListView: View {
    var home = SmartHome.shared

    var body: some View {
        Form {
            Section {
                if home.speakers.isEmpty {
                    Text("Looking for Sonos speakers on your Wi‑Fi…").foregroundStyle(.secondary)
                }
                ForEach(home.speakers) { r in
                    PageLink(r.name) { SpeakerDetailView(speakerID: r.id) } label: {
                        IconRow(symbol: "", color: .clear, title: r.name,
                                subtitle: status(r),
                                value: home.room(of: r.id))
                    }
                }
            } footer: {
                Text("Sonos speakers are found on your Wi‑Fi by themselves, no account needed. Tap one to rename it or choose its room.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Speakers")
        .inlineTitle()
        .refreshable { await home.findSonos(); await home.refreshSpeakers() }
    }

    private func status(_ r: SonosRoom) -> String {
        if r.isOffline { return "Offline" }
        if r.isTV { return r.isPlaying ? "TV" : "TV · " + r.stateName }
        guard let t = r.title, !t.isEmpty else { return r.stateName }
        let what = [t, r.artist ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
        return r.isPlaying ? what : r.stateName + " · " + what
    }
}

struct LightsListView: View {
    var home = SmartHome.shared
    @State private var key = SmartHome.shared.goveeKey ?? ""
    @State private var adding = false
    @State private var address = ""

    var body: some View {
        Form {
            Section {
                if home.lights.isEmpty {
                    Text("No lights found yet.").foregroundStyle(.secondary)
                }
                ForEach(home.lights) { l in
                    PageLink(l.name) { LightDetailView(lightID: l.id) } label: {
                        HStack(spacing: 12) {
                            Circle().fill(l.isLit ? l.shade : Color.secondary.opacity(0.3)).frame(width: 12, height: 12)
                            IconRow(symbol: "", color: .clear, title: l.name,
                                    subtitle: l.isOffline ? "Offline" : l.on ? "On · \(l.brightness)%" : "Off", value: home.room(of: l.id))
                        }
                    }
                    .swipeActions {
                        if !l.isOffline { Button(l.on ? "Turn Off" : "Turn On") { home.setOn(l, !l.on) }.tint(l.on ? .gray : .yellow) }
                    }
                }
            } footer: {
                Text("Govee lights answer on your Wi‑Fi once LAN Control is on for each one in the Govee app (the light’s settings). Tap a light to rename it or choose its room.")
            }
            if !home.answers.isEmpty {
                Section {
                    ForEach(home.answers) { a in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(a.ip).font(.body.monospacedDigit())
                                Spacer()
                                Text("Govee \(a.sku)").foregroundStyle(.secondary)
                            }
                            Text(a.device).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                } header: { Text("Answering on Your Wi‑Fi") } footer: {
                    Text("Each lamp that answered the search, with its address and device ID. Two lamps should be two addresses here.")
                }
            }
            Section {
                Button("Search Again") { home.searchLights() }
                Button("Add a Light by Address…") { adding = true }
            } footer: {
                Text("Missing a light? Check LAN Control is on for it in the Govee app, then Search Again. Or add it by its address, shown in your router’s device list.")
            }
            if home.lights.contains(where: \.on) || home.lights.count > 1 {
                Section {
                    Button("Turn All Off") { home.allLights(false) }
                    Button("Turn All On") { home.allLights(true) }
                }
            }
            Section("Govee Account") {
                TextField("Paste your Govee API key", text: $key)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                Button(home.goveeKey?.isEmpty == false ? "Update Key" : "Save Key") { home.goveeKey = key.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || key == (home.goveeKey ?? ""))
                if let e = home.goveeError { Text(e).foregroundStyle(Palette.attention) }
                Text("Optional. Brings in your lights’ names from the Govee app and reaches lights without LAN Control. Get a key in the Govee app: Profile → Settings → Apply for API Key.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Cync and Apple Home") {
                #if os(iOS)
                Text("Cync lights with the Matter logo show up here once they’re in Apple Home. In the Cync app, open the light’s settings and choose to connect it to Apple Home (Matter) to get its setup code; then in the Home app tap +, Add Accessory, and scan or enter that code. Any light in Apple Home appears here.")
                    .font(.footnote).foregroundStyle(.secondary)
                #else
                Text("Cync and other Apple Home lights appear in Woodruff on iPhone. Apple only lets iPhone apps like this one reach Apple Home.")
                    .font(.footnote).foregroundStyle(.secondary)
                #endif
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Lights")
        .inlineTitle()
        .refreshable { home.searchLights(); await home.refreshCloud() }
        .alert("Add a Light", isPresented: $adding) {
            TextField("192.168.1.42", text: $address)
                #if os(iOS)
                .keyboardType(.decimalPad)
                #endif
            Button("Add") { home.addLight(ip: address); address = "" }
            Button("Cancel", role: .cancel) { address = "" }
        } message: {
            Text("The light’s address on your Wi‑Fi.")
        }
    }
}

/// Name and room, shared by the speaker and light pages.
struct NameAndRoom: View {
    @Environment(Fleet.self) private var fleet
    var id: String
    var current: String
    var original: String?
    var home = SmartHome.shared
    @State private var name = ""
    @State private var addingRoom = false
    @State private var newRoom = ""

    var body: some View {
        Section("Name") {
            TextField("Name", text: $name)
                .onSubmit { home.rename(id, name) }
                .onAppear { name = current }
            if name.trimmingCharacters(in: .whitespaces) != current {
                Button("Save Name") { home.rename(id, name) }
            }
            if let original, original != current {
                Button("Use “\(original)”") { name = original; home.rename(id, "") }
            }
        }
        Section {
            Picker("Room", selection: Binding(get: { home.room(of: id) ?? "" }, set: { v in
                if v == "+" { addingRoom = true } else { home.setRoom(id, v.isEmpty ? nil : v) }
            })) {
                Text("No Room").tag("")
                ForEach(allRooms(fleet), id: \.self) { Text($0).tag($0) }
                Text("New Room…").tag("+")
            }
        } footer: {
            Text("Rooms group things together on Home, like the Home app.")
        }
        .alert("New Room", isPresented: $addingRoom) {
            TextField("Room Name", text: $newRoom)
            Button("Add") { home.setRoom(id, newRoom); newRoom = "" }
            Button("Cancel", role: .cancel) { newRoom = "" }
        }
    }
}

struct LightDetailView: View {
    var lightID: String
    var home = SmartHome.shared
    @State private var level: Double = 100
    @State private var dragging = false

    var body: some View {
        if let l = home.light(lightID) {
            Form {
                Section {
                    VStack(spacing: 18) {
                        Circle()
                            .fill(l.isLit ? l.shade : Color.secondary.opacity(0.25))
                            .frame(width: 72, height: 72)
                            .shadow(color: l.isLit ? l.shade.opacity(0.9) : .clear, radius: 24)
                            .overlay { Circle().strokeBorder(.white.opacity(0.25)) }
                            .onTapGesture { if !l.isOffline { home.setOn(l, !l.on) } }
                        if l.isOffline {
                            Label(LightSheet.offlineHint(l), systemImage: "wifi.slash")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        // An unreachable light can't take a change: its controls rest until it's back.
                        Group {
                            Toggle(l.isOffline ? "Offline" : l.on ? "On" : "Off", isOn: Binding(get: { l.isLit }, set: { home.setOn(l, $0) }))
                                .toggleStyle(.switch)
                            HStack(spacing: 12) {
                                Image(systemName: "sun.min").foregroundStyle(.secondary)
                                Slider(value: $level, in: 1...100) { e in dragging = e; if !e { home.setBrightness(l, Int(level)) } }
                                    // The arrow keys and VoiceOver move it without a drag: those reach the light too.
                                    .onChange(of: level) { _, v in
                                        if !dragging && Int(v) != (home.light(lightID)?.brightness ?? l.brightness) { home.setBrightness(l, Int(v)) }
                                    }
                                Image(systemName: "sun.max.fill").foregroundStyle(.secondary)
                            }
                            swatches(LightSheet.colors.map { c in (c.color, l.color == c, { home.setColor(l, c) }) })
                            swatches(LightSheet.whites.map { k in (LightColor.kelvin(k), LightSheet.isWhite(l, k), { home.setWhite(l, kelvin: k) }) })
                        }
                        .disabled(l.isOffline)
                        if let e = home.goveeError {
                            Text(e).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                }
                NameAndRoom(id: l.id, current: l.name, original: nil)
                if l.isHome {
                    Section("Apple Home") {
                        LabeledContent("Maker", value: l.sku)
                        if let z = l.zone { LabeledContent("Apple Home Room", value: z) }
                        LabeledContent("Connection", value: l.isOffline ? "Apple Home · Not Responding" : "Apple Home (Matter)")
                    }
                } else {
                    Section("Govee") {
                        LabeledContent("Model", value: l.sku)
                        LabeledContent("Device ID", value: l.id).font(.footnote.monospaced())
                        LabeledContent("Connection", value: Self.connection(l))
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(l.name)
            .inlineTitle()
            .onAppear { level = Double(l.brightness) }
            .onChange(of: l.brightness) { _, v in if !dragging { level = Double(v) } }
        } else {
            ContentUnavailableView("Light Not Found", systemImage: "lightbulb")
        }
    }

    /// How the app reaches a Govee light, and whether it can right now.
    private static func connection(_ l: GoveeLight) -> String {
        let twin = l.id.contains("@")
        if let ip = l.ip {
            if l.isOffline { return "Wi‑Fi (\(ip)) · Not Answering" }
            return twin ? "Wi‑Fi (\(ip)) · Twin Lamp" : "Wi‑Fi (\(ip))"
        }
        if l.cloud && !twin { return l.isOffline ? "Govee Account · Offline" : "Govee Account" }
        return "Not Reachable"
    }

    private func swatches(_ items: [(Color, Bool, () -> Void)]) -> some View {
        HStack(spacing: 10) {
            ForEach(items.indices, id: \.self) { i in
                Button(action: items[i].2) {
                    Circle().fill(items[i].0).frame(width: 28, height: 28)
                        .overlay { if items[i].1 { Circle().strokeBorder(.white, lineWidth: 3) } }
                        .glass(Circle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

extension GoveeLight {
    /// A Govee floor lamp (a tall light bar on a round base): drawn as one, its light rising with the brightness.
    var isFloorLamp: Bool {
        name.localizedCaseInsensitiveContains("floor") || ["H6076", "H6072", "H607C", "H6078", "H607A"].contains(sku.uppercased())
    }
}

/// A Govee Floor Lamp 2: a small satin-black cylinder base and a slim pole standing up from it. The pole lights from
/// the base up like a progress bar, [level] 0…1 of it, in the light's colour: a bright core, a close glow and a wide
/// soft one, with light spilling onto the floor round the base. Off, it's a dark pole on its base.
struct FloorLampPicture: View {
    var level: Double
    var lit: Bool
    var color: Color

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            let baseW = max(6, w * 0.34), baseH = max(5, h * 0.11)
            let capH = baseW * 0.22
            let poleW = max(2, w * 0.065)
            let floorY = h - capH * 0.5
            let poleBottom = floorY - baseH
            let poleH = poleBottom - h * 0.01
            let fill = lit ? max(0.01, min(1, level)) : 0
            let litH = poleH * fill
            ZStack(alignment: .topLeading) {
                // Light on the floor round the base, and its shadow.
                Ellipse().fill(.black.opacity(0.45)).frame(width: baseW * 1.5, height: capH * 1.2).blur(radius: 1.5)
                    .position(x: w / 2, y: floorY)
                if lit {
                    Ellipse().fill(color.opacity(0.55)).frame(width: baseW * 2.6, height: capH * 2.4).blur(radius: max(3, w * 0.12))
                        .position(x: w / 2, y: floorY)
                }
                // The glow round the lit part of the pole: wide and soft, then close.
                if lit {
                    Capsule().fill(color.opacity(0.4)).frame(width: poleW * 9, height: litH + poleW * 4)
                        .blur(radius: max(4, w * 0.22)).position(x: w / 2, y: poleBottom - litH / 2)
                    Capsule().fill(color.opacity(0.85)).frame(width: poleW * 2.6, height: litH + poleW)
                        .blur(radius: max(1.5, poleW * 0.8)).position(x: w / 2, y: poleBottom - litH / 2)
                }
                // The pole: satin black, rounded at the top.
                Capsule()
                    .fill(LinearGradient(colors: [Color(white: 0.3), Color(white: 0.08), Color(white: 0.18)], startPoint: .leading, endPoint: .trailing))
                    .frame(width: poleW, height: poleH)
                    .position(x: w / 2, y: poleBottom - poleH / 2)
                // Its light, rising from the base: the colour with a bright core down the middle.
                if lit {
                    Capsule().fill(color).frame(width: poleW, height: max(poleW, litH))
                        .overlay(Capsule().fill(.white.opacity(0.75)).frame(width: poleW * 0.35))
                        .position(x: w / 2, y: poleBottom - max(poleW, litH) / 2)
                }
                // The base: a cylinder, its side catching the light, its top a lighter ellipse.
                RoundedRectangle(cornerRadius: baseW * 0.08, style: .continuous)
                    .fill(LinearGradient(colors: [Color(white: 0.07), Color(white: 0.32), Color(white: 0.12), Color(white: 0.05)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: baseW, height: baseH)
                    .overlay(alignment: .bottom) {
                        if lit {
                            RoundedRectangle(cornerRadius: baseW * 0.08, style: .continuous)
                                .fill(LinearGradient(colors: [.clear, color.opacity(0.9)], startPoint: .top, endPoint: .bottom))
                                .frame(height: baseH * 0.35)
                        }
                    }
                    .position(x: w / 2, y: floorY - baseH / 2)
                Ellipse()
                    .fill(LinearGradient(colors: [Color(white: 0.38), Color(white: 0.18)], startPoint: .top, endPoint: .bottom))
                    .frame(width: baseW, height: capH)
                    .position(x: w / 2, y: poleBottom)
            }
            .frame(width: w, height: h)
        }
        .animation(.smooth(duration: 0.25), value: level)
        .animation(.smooth(duration: 0.25), value: lit)
    }
}
