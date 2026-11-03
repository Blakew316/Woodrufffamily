import SwiftUI
import WoodruffKit

// Speakers and lights on Home, Apple Home style: a tile each, tap to act, hold (or right-click) for every control.

// MARK: - Speakers

struct SpeakersSection: View {
    var home = SmartHome.shared
    @State private var open: SonosRoom?

    var body: some View {
        if !home.speakers.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Text("Speakers").font(.title2.bold())
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 14)], spacing: 14) {
                    ForEach(home.speakers) { r in
                        SpeakerTile(room: r) { open = r }
                    }
                }
            }
            .sheet(item: $open) { r in SpeakerSheet(roomID: r.id) }
        }
    }
}

struct SpeakerTile: View {
    var room: SonosRoom
    var openControls: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            SpeakerArt(url: room.art, size: 46)
            VStack(alignment: .leading, spacing: 2) {
                Text(room.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if room.title != nil {
                Button {
                    Task { await SmartHome.shared.sonos(room) { room.isPlaying ? try await Sonos.pause($0) : try await Sonos.play($0) } }
                } label: {
                    Image(systemName: room.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 34, height: 34)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .glass(Circle())
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 74, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .glass(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onTapGesture(perform: openControls)
        .contextMenu {
            Button(room.isPlaying ? "Pause" : "Play") {
                Task { await SmartHome.shared.sonos(room) { room.isPlaying ? try await Sonos.pause($0) : try await Sonos.play($0) } }
            }
            Button("Next Track") { Task { await SmartHome.shared.sonos(room) { try await Sonos.next($0) } } }
            Button(room.muted ? "Unmute" : "Mute") { Task { await SmartHome.shared.sonos(room) { try await Sonos.setMute($0, !room.muted) } } }
        }
    }

    private var detail: String {
        guard let t = room.title, !t.isEmpty else { return "Not Playing" }
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

/// Everything for one room: what's playing, the transport, and its volume.
struct SpeakerSheet: View {
    var roomID: String
    var home = SmartHome.shared
    @Environment(\.dismiss) private var dismiss
    @State private var volume: Double = 0
    @State private var dragging = false

    private var room: SonosRoom? { home.speakers.first { $0.id == roomID } }

    var body: some View {
        if let room {
            VStack(spacing: 22) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(room.name).font(.title3.bold())
                        if room.groupNames.count > 1 {
                            Text("With " + room.groupNames.filter { $0 != room.name }.joined(separator: ", "))
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    GlassCircle(symbol: "xmark", size: 34) { dismiss() }
                }
                SpeakerArt(url: room.art, size: 240)
                    .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
                VStack(spacing: 4) {
                    Text(room.title ?? "Not Playing").font(.title3.weight(.semibold)).lineLimit(1)
                    Text([room.artist, room.album].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " — "))
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(spacing: 34) {
                    GlassCircle(symbol: "backward.fill", size: 56) { Task { await home.sonos(room) { try await Sonos.previous($0) } } }
                    GlassCircle(symbol: room.isPlaying ? "pause.fill" : "play.fill", size: 72) {
                        Task { await home.sonos(room) { room.isPlaying ? try await Sonos.pause($0) : try await Sonos.play($0) } }
                    }
                    GlassCircle(symbol: "forward.fill", size: 56) { Task { await home.sonos(room) { try await Sonos.next($0) } } }
                }
                .glassGroup(spacing: 30)
                HStack(spacing: 12) {
                    Button { Task { await home.sonos(room) { try await Sonos.setMute($0, !room.muted) } } } label: {
                        Image(systemName: room.muted ? "speaker.slash.fill" : "speaker.fill").frame(width: 24)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(room.muted ? Palette.attention : .secondary)
                    Slider(value: $volume, in: 0...100) { editing in
                        dragging = editing
                        if !editing { home.setVolume(room, Int(volume)) }
                    }
                    .onChange(of: volume) { _, v in if dragging { home.setVolume(room, Int(v)) } }
                    Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary).frame(width: 28)
                }
            }
            .padding(24)
            .frame(minWidth: 340, idealWidth: 380)
            .onAppear { volume = Double(room.volume) }
            .onChange(of: room.volume) { _, v in if !dragging { volume = Double(v) } }
            .presentationDetents([.large])
            .presentationBackground(.ultraThinMaterial)
        }
    }
}

// MARK: - Lights

struct LightsSection: View {
    var home = SmartHome.shared
    @State private var open: GoveeLight?

    var body: some View {
        if !home.lights.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Lights").font(.title2.bold())
                    Spacer()
                    if home.lights.contains(where: \.on) {
                        Button("All Off") { for l in home.lights where l.on { home.setOn(l, false) } }
                            .buttonStyle(.glass)
                    }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], spacing: 14) {
                    ForEach(home.lights) { l in
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
        VStack(alignment: .leading, spacing: 12) {
            Circle()
                .fill(light.on ? light.shade : .white.opacity(0.18))
                .frame(width: 26, height: 26)
                .shadow(color: light.on ? light.shade.opacity(0.9) : .clear, radius: 10)
            VStack(alignment: .leading, spacing: 1) {
                Text(light.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                Text(light.on ? "\(light.brightness)%" : "Off").font(.caption)
                    .foregroundStyle(light.on ? Color.black.opacity(0.55) : .secondary)
            }
        }
        .foregroundStyle(light.on ? Color.black : .primary)
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
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
                        .onSubmit { home.rename(light, name) }
                    Button("Rename") { home.rename(light, name) }.buttonStyle(.glass)
                        .disabled(name.trimmingCharacters(in: .whitespaces) == light.name)
                }
            }
            .padding(24)
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
            .gesture(DragGesture(minimumDistance: 0)
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

// MARK: - Settings

/// Settings → Speakers & Lights: what's been found, the Govee key, and how to bring Cync lights in.
struct SmartHomeSettingsView: View {
    var home = SmartHome.shared
    @State private var key = SmartHome.shared.goveeKey ?? ""

    var body: some View {
        Form {
            Section {
                IconRow(symbol: "", color: .clear, title: "Sonos", value: home.speakers.isEmpty ? "Looking…" : "\(home.speakers.count) room\(home.speakers.count == 1 ? "" : "s")")
                IconRow(symbol: "", color: .clear, title: "Govee", value: home.lights.isEmpty ? "None found" : "\(home.lights.count) light\(home.lights.count == 1 ? "" : "s")")
            } footer: {
                Text("Sonos speakers are found on your Wi‑Fi by themselves. For Govee lights, turn on LAN Control for each light in the Govee app (the light’s settings).")
            }
            Section {
                SecureField("Govee API Key", text: $key)
                Button("Save Key") { home.goveeKey = key.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .disabled(key == (home.goveeKey ?? ""))
                if let e = home.goveeError { Text(e).foregroundStyle(Palette.attention) }
            } header: { Text("Govee") } footer: {
                Text("Optional. Gives your lights their names from the Govee app and controls lights without LAN Control. Get a key in the Govee app: Profile → Settings → Apply for API Key.")
            }
            Section {} header: { Text("Cync") } footer: {
                Text("Cync lights don’t offer control over Wi‑Fi to other apps. They’re coming in a later update.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Speakers & Lights")
    }
}
