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
            }
        }
    }
}

struct SpeakerTile: View {
    var room: SonosRoom
    var openControls: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            SpeakerArt(url: room.art, size: 38)
            VStack(alignment: .leading, spacing: 1) {
                Text(room.name).font(.footnote.weight(.semibold)).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if room.title != nil {
                Button {
                    Task { await SmartHome.shared.sonos(room) { room.isPlaying ? try await Sonos.pause($0) : try await Sonos.play($0) } }
                } label: {
                    Image(systemName: room.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 30, height: 30)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .glass(Circle())
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .glass(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onTapGesture(perform: openControls)
        .contextMenu {
            Button(room.isPlaying ? "Pause" : "Play") {
                Task { await SmartHome.shared.sonos(room) { room.isPlaying ? try await Sonos.pause($0) : try await Sonos.play($0) } }
            }
            Button("Next Track") { Task { await SmartHome.shared.sonos(room) { try await Sonos.next($0) } } }
            Button(room.muted ? "Unmute" : "Mute") { Task { await SmartHome.shared.sonos(room) { try await Sonos.setMute($0, !room.muted) } } }
            FavoriteButton(id: room.id)
        }
    }

    private var detail: String {
        if room.isTV { return room.isPlaying ? "TV" : "TV · Paused" }
        guard let t = room.title, !t.isEmpty else { return room.setupSummary ?? "Not Playing" }
        let what = [t, room.artist].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        return room.isPlaying ? what : "Paused · " + what
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
                    AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: { Color.clear }
                } else {
                    Image(systemName: "hifispeaker.fill").font(.system(size: size * 0.38)).foregroundStyle(.secondary)
                }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.18, style: .continuous))
    }
}

// MARK: - A room's small tiles, together

/// Everything small in a room (speakers, lights, devices) in one even grid, two across on iPhone, rather than
/// a short grid per kind.
struct RoomTiles: View {
    var room: String? = nil
    var favorites = false
    private let home = SmartHome.shared
    private let layout = HomeLayout.shared
    @State private var openSpeaker: SonosRoom?
    @State private var openLight: GoveeLight?
    @State private var openDevice: HomeDevice?

    private enum Item: Identifiable {
        case speaker(SonosRoom), light(GoveeLight), device(HomeDevice)
        var id: String {
            switch self {
            case .speaker(let r): return r.id
            case .light(let l): return l.id
            case .device(let d): return d.id
            }
        }
    }

    private func pick<T: Identifiable>(_ list: [T], _ kind: String, room id: (T) -> String) -> [T] where T.ID == String {
        if favorites { return layout.favoritesOnly(list) }
        guard !layout.hiddenSections.contains(kind) else { return [] }
        let inRoom = room.map { r in list.filter { roomMatches(home.room(of: id($0)), r) } } ?? list
        return layout.arrange(inRoom, in: kind)
    }

    private var items: [Item] {
        let all = pick(home.speakers, "speakers", room: \.id).map(Item.speaker)
            + pick(home.lights, "lights", room: \.id).map(Item.light)
            + pick(AccessoryStore.shared.all, "devices", room: \.id).map(Item.device)
        // Each thing once (a light found twice would otherwise upset the grid).
        var seen = Set<String>()
        return all.filter { seen.insert($0.id).inserted }
    }

    var body: some View {
        let list = items
        if !list.isEmpty {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(list) { item in
                    switch item {
                    case .speaker(let r): SpeakerTile(room: r) { openSpeaker = r }
                    case .light(let l): LightTile(light: l) { openLight = l }
                    case .device(let d): DeviceTile(device: d) { openDevice = d }
                    }
                }
            }
            .sheet(item: $openSpeaker) { r in
                NavigationStack { SpeakerDetailView(speakerID: r.id, inSheet: true) }.presentationBackground(.clear)
            }
            .sheet(item: $openLight) { l in LightSheet(lightID: l.id) }
            .sheet(item: $openDevice) { d in NavigationStack { DeviceDetailView(deviceID: d.id, inSheet: true) } }
        }
    }

    private var columns: [GridItem] {
        #if os(iOS)
        [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
        #else
        [GridItem(.adaptive(minimum: 200), spacing: 10)]
        #endif
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
                    if shown.contains(where: \.on) {
                        Button("All Off") { for l in shown where l.on { home.setOn(l, false) } }
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
            .sheet(item: $open) { l in LightSheet(lightID: l.id) }
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
        // Compact, like the Home app: the light's colour on the left, its name and state beside it.
        HStack(spacing: 10) {
            Circle()
                .fill(light.on ? light.shade : .white.opacity(0.18))
                .frame(width: 24, height: 24)
                .shadow(color: light.on ? light.shade.opacity(0.9) : .clear, radius: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(light.name).font(.footnote.weight(.semibold)).lineLimit(2)
                Text(light.on ? "\(light.brightness)%" : "Off").font(.caption)
                    .foregroundStyle(light.on ? Color.black.opacity(0.55) : .secondary)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(light.on ? Color.black : .primary)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .background {
            if light.on {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(LinearGradient(colors: [.white.opacity(0.96), light.shade.opacity(0.55).mix(with: .white, by: 0.5)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .modifier(OffGlass(on: light.on))
        .animation(.smooth(duration: 0.25), value: light.on)
        .onTapGesture {
            #if os(iOS)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            #endif
            SmartHome.shared.setOn(light, !light.on)
        }
        .onLongPressGesture(minimumDuration: 0.35, perform: openControls)
        .contextMenu {
            Button(light.on ? "Turn Off" : "Turn On") { SmartHome.shared.setOn(light, !light.on) }
            Button("Controls…", action: openControls)
            FavoriteButton(id: light.id)
        }
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

    var body: some View {
        if let light {
            ScrollView {
            VStack(spacing: 22) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(light.name).font(.title3.bold())
                        Text(light.on ? "\(Int(level))%" : "Off").font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Spacer()
                    GlassCircle(symbol: "xmark", size: 34) { dismiss() }
                }
                brightnessBar(light)
                Button(light.on ? "Turn Off" : "Turn On") { home.setOn(light, !light.on) }
                    .buttonStyle(.glass)
                VStack(alignment: .leading, spacing: 10) {
                    Text("Colour").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    swatches(Self.colors.map { c in (c.color, light.color == c, { home.setColor(light, c) }) })
                    Text("White").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 4)
                    swatches(Self.whites.map { k in (LightColor.kelvin(k), light.color == nil && light.kelvin == k, { home.setWhite(light, kelvin: k) }) })
                }
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
        GeometryReader { g in
            ZStack(alignment: .bottom) {
                Rectangle().fill(.white.opacity(0.12))
                Rectangle().fill(light.on ? light.shade : .white.opacity(0.3))
                    .frame(height: g.size.height * (light.on ? level / 100 : 0))
            }
            .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
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
                    NavigationLink { SpeakerDetailView(speakerID: r.id) } label: {
                        IconRow(symbol: "", color: .clear, title: r.name,
                                subtitle: r.title.map { [$0, r.artist].compactMap { $0 }.joined(separator: " · ") } ?? "Not Playing",
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
                    NavigationLink { LightDetailView(lightID: l.id) } label: {
                        HStack(spacing: 12) {
                            Circle().fill(l.on ? l.shade : Color.secondary.opacity(0.3)).frame(width: 12, height: 12)
                            IconRow(symbol: "", color: .clear, title: l.name, subtitle: l.on ? "On · \(l.brightness)%" : "Off", value: home.room(of: l.id))
                        }
                    }
                    .swipeActions { Button(l.on ? "Turn Off" : "Turn On") { home.setOn(l, !l.on) }.tint(l.on ? .gray : .yellow) }
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
                            .fill(l.on ? l.shade : Color.secondary.opacity(0.25))
                            .frame(width: 72, height: 72)
                            .shadow(color: l.on ? l.shade.opacity(0.9) : .clear, radius: 24)
                            .overlay { Circle().strokeBorder(.white.opacity(0.25)) }
                            .onTapGesture { home.setOn(l, !l.on) }
                        Toggle(l.on ? "On" : "Off", isOn: Binding(get: { l.on }, set: { home.setOn(l, $0) }))
                            .toggleStyle(.switch)
                        HStack(spacing: 12) {
                            Image(systemName: "sun.min").foregroundStyle(.secondary)
                            Slider(value: $level, in: 1...100) { e in dragging = e; if !e { home.setBrightness(l, Int(level)) } }
                            Image(systemName: "sun.max.fill").foregroundStyle(.secondary)
                        }
                        swatches(LightSheet.colors.map { c in (c.color, l.color == c, { home.setColor(l, c) }) })
                        swatches(LightSheet.whites.map { k in (LightColor.kelvin(k), l.color == nil && l.kelvin == k, { home.setWhite(l, kelvin: k) }) })
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                }
                NameAndRoom(id: l.id, current: l.name, original: nil)
                if l.isHome {
                    Section("Apple Home") {
                        LabeledContent("Maker", value: l.sku)
                        if let z = l.zone { LabeledContent("Apple Home Room", value: z) }
                        LabeledContent("Connection", value: "Apple Home (Matter)")
                    }
                } else {
                    Section("Govee") {
                        LabeledContent("Model", value: l.sku)
                        LabeledContent("Device ID", value: l.id).font(.footnote.monospaced())
                        LabeledContent("Connection", value: l.ip != nil ? "Wi‑Fi (\(l.ip!))" : (l.cloud ? "Govee Account" : "Not reachable"))
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
