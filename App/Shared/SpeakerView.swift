import SwiftUI
import WoodruffKit

/// One Sonos room, Apple style: what's playing over its own artwork, then the room's speakers laid out as they
/// sit (soundbar, Sub, surrounds), the sound settings the Sonos app has, grouping, and its name and room.
struct SpeakerDetailView: View {
    var speakerID: String
    var inSheet = false
    var home = SmartHome.shared
    @Environment(\.dismiss) private var dismiss
    @State private var sound = SonosSound()
    @State private var loaded = false
    @State private var volume: Double = 0
    @State private var dragging = false

    private var room: SonosRoom? { home.speaker(speakerID) }

    var body: some View {
        if let r = room {
            ScrollView {
                VStack(spacing: 16) {
                    nowPlaying(r)
                    if r.parts.count > 1 { SurroundCard(room: r, sound: $sound).disabled(r.isOffline) }
                    if loaded && !r.isOffline { SoundCard(room: r, sound: $sound) }
                    GroupCard(room: r)
                    NameRoomCard(id: r.id, current: r.name, original: r.zone)
                }
                .padding(16)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .background { ArtBackdrop(url: r.art) }
            .environment(\.colorScheme, .dark)
            .navigationTitle(r.name)
            .inlineTitle()
            .toolbar {
                if inSheet {
                    ToolbarItem(placement: .cancellationAction) { Button(role: .close) { dismiss() } }
                }
            }
            // Asked again when the speaker comes back after being offline.
            .task(id: "\(r.id)|\(r.isOffline)") {
                guard !r.isOffline else { return }
                sound = await Sonos.sound(r)
                withAnimation(.smooth) { loaded = true }
            }
            .onAppear { volume = Double(r.volume) }
            .onChange(of: r.volume) { _, v in if !dragging { volume = Double(v) } }
            .refreshable {
                await home.refreshSpeakers()
                if let now = home.speaker(r.id), !now.isOffline { sound = await Sonos.sound(now) }
            }
        } else {
            ContentUnavailableView("Speaker Not Found", systemImage: "hifispeaker")
        }
    }

    // MARK: Now playing

    private func nowPlaying(_ r: SonosRoom) -> some View {
        VStack(spacing: 18) {
            Group {
                if r.isTV {
                    RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.white.opacity(0.08))
                        .overlay { Image(systemName: "tv").font(.system(size: 54, weight: .light)).foregroundStyle(.secondary) }
                } else {
                    SpeakerArt(url: r.art, size: 220)
                }
            }
            .frame(width: 220, height: 220)
            .shadow(color: .black.opacity(0.4), radius: 26, y: 14)
            .scaleEffect(r.isPlaying ? 1 : 0.92)
            .opacity(r.isOffline ? 0.45 : 1)
            .animation(.spring(response: 0.45, dampingFraction: 0.75), value: r.isPlaying)

            VStack(spacing: 4) {
                Text(headline(r)).font(.title3.weight(.semibold)).lineLimit(1)
                Text(subtitle(r)).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                if let e = home.speakerErrors[r.id] {
                    Text(e).font(.footnote.weight(.medium)).foregroundStyle(Palette.attention).lineLimit(2)
                        .multilineTextAlignment(.center)
                        .transition(.opacity)
                }
            }
            .animation(.smooth, value: home.speakerErrors[r.id])

            // Skipping isn't a thing on the TV's sound, a radio-less empty queue, or a speaker that's offline.
            let canSkip = !r.isTV && !r.isOffline && r.canPlay
            HStack(spacing: 30) {
                GlassCircle(symbol: "backward.fill", size: 52) { act(r) { try await Sonos.previous($0) } }
                    .disabled(!canSkip).opacity(canSkip ? 1 : 0.35)
                GlassCircle(symbol: r.isPlaying ? "pause.fill" : "play.fill", size: 70) {
                    tap()
                    Task { await home.playPause(r) }
                }
                .disabled(!r.canPlay).opacity(r.canPlay ? 1 : 0.35)
                GlassCircle(symbol: "forward.fill", size: 52) { act(r) { try await Sonos.next($0) } }
                    .disabled(!canSkip).opacity(canSkip ? 1 : 0.35)
            }
            .glassGroup(spacing: 26)

            HStack(spacing: 12) {
                Button {
                    tap()
                    let mute = !r.muted
                    Task { await home.setMute(r, mute) }
                } label: {
                    Image(systemName: r.muted ? "speaker.slash.fill" : "speaker.fill").frame(width: 22)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(r.muted ? "Unmute \(r.name)" : "Mute \(r.name)")
                .foregroundStyle(r.muted ? Palette.attention : .secondary)
                Slider(value: $volume, in: 0...100) { e in dragging = e; if !e { home.setVolume(r, Int(volume)) } }
                    .tint(.white)
                    // Dragging sends as it goes; the arrow keys and VoiceOver move it without a drag, and those go too
                    // (a new level read from the speaker matches it, so it isn't sent back).
                    .onChange(of: volume) { _, v in
                        if dragging || Int(v) != (home.speaker(r.id)?.volume ?? r.volume) { home.setVolume(r, Int(v)) }
                    }
                Text("\(Int(volume))").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary).frame(width: 28, alignment: .trailing)
            }
            .disabled(r.isOffline)
            .opacity(r.isOffline ? 0.45 : 1)

            if r.hasTVInput && !r.isTV && !r.isOffline {
                Button("Switch to TV Sound") {
                    tap()
                    Task { await home.playTV(r) }
                }
                .buttonStyle(.glass)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .glass(RoundedRectangle(cornerRadius: 28, style: .continuous), interactive: false)
    }

    private func headline(_ r: SonosRoom) -> String {
        if r.isOffline { return "Offline" }
        if r.isTV { return "TV Sound" }
        if let t = r.title, !t.isEmpty { return t }
        return r.state == "STOPPED" ? "Stopped" : "Not Playing"
    }

    private func subtitle(_ r: SonosRoom) -> String {
        if r.isOffline { return "\(r.name) isn't answering. Is it plugged in and on the Wi‑Fi?" }
        let setup = r.setupSummary ?? r.name
        // Paused, stopped or loading say so; playing just shows what.
        var state: String? = nil
        if r.state != "PLAYING" && (r.isTV || !(r.title ?? "").isEmpty) { state = r.stateName }
        let others = r.groupNames.filter { $0 != r.name && $0 != r.zone }
        let group: String? = others.isEmpty ? nil : "With " + others.joined(separator: ", ")
        if r.isTV { return [state, group ?? setup].compactMap { $0 }.joined(separator: " · ") }
        let s = [r.artist, r.album].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " — ")
        return [state, s.isEmpty ? (group ?? setup) : s].compactMap { $0 }.joined(separator: " · ")
    }

    private func tap() {
        #if os(iOS) || os(tvOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }

    private func act(_ r: SonosRoom, _ op: @escaping @Sendable (SonosRoom) async throws -> Void) {
        tap()
        Task { await home.sonos(r, op) }
    }
}

// MARK: - Pieces

/// The room's art, large and blurred behind everything.
struct ArtBackdrop: View {
    var url: URL?
    var body: some View {
        ZStack {
            Color.black
            if let url {
                BlurredArtwork(url: url, radius: 60, maxPixel: 1800)
                    .opacity(0.65).scaleEffect(1.3)
            } else {
                LinearGradient(colors: [Color(red: 0.12, green: 0.14, blue: 0.2), .black], startPoint: .top, endPoint: .bottom)
            }
            LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
    }
}

/// A rounded glass card with a title.
struct GlassCard<Content: View>: View {
    var title: String
    var footer: String? = nil
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            content
            if let footer { Text(footer).font(.footnote).foregroundStyle(.secondary) }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glass(RoundedRectangle(cornerRadius: 24, style: .continuous), interactive: false)
    }
}

/// A −15…+15 style level with its value.
struct LevelRow: View {
    var title: String
    var range: ClosedRange<Double>
    var value: Int?
    var set: (Int) -> Void
    @State private var v: Double = 0
    @State private var editing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text(v > 0 ? "+\(Int(v))" : "\(Int(v))").monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: $v, in: range, step: 1) { e in editing = e; if !e { set(Int(v)) } }
                .tint(.white)
                // The arrow keys and VoiceOver move it without a drag: those are sent too.
                .onChange(of: v) { _, n in if !editing && Int(n) != (value ?? 0) { set(Int(n)) } }
        }
        .onAppear { v = Double(value ?? 0) }
        .onChange(of: value) { _, n in if !editing { v = Double(n ?? 0) } }
    }
}

// MARK: Surround

/// The speakers as they sit in the room: the soundbar at the front by the TV, the Sub, and the rear surrounds
/// either side of the sofa. Tap one for what it is; the levels sit underneath.
struct SurroundCard: View {
    var room: SonosRoom
    @Binding var sound: SonosSound
    @State private var picked: SonosPart?

    var body: some View {
        GlassCard(title: "Speakers", footer: "Sonos plays these together as one room. Surround and Sub levels apply to the pair.") {
            layout
                .frame(height: 260)
            ForEach(room.parts) { p in
                Button { picked = p } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(p.roleName).font(.subheadline.weight(.semibold))
                            Text(p.model ?? "Sonos").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(p.host ?? "").font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if p.id != room.parts.last?.id { Divider() }
            }
            if room.parts.contains(where: { $0.role == .leftRear || $0.role == .rightRear }) {
                Divider()
                Toggle("Surrounds", isOn: Binding(get: { sound.surroundOn ?? true }, set: { on in
                    sound.surroundOn = on
                    apply { try await Sonos.setEQ($0, "SurroundEnable", on ? 1 : 0) }
                }))
                if sound.surroundOn ?? true {
                    LevelRow(title: "TV Surround Level", range: -15...15, value: sound.surroundLevel) { v in
                        sound.surroundLevel = v; apply { try await Sonos.setEQ($0, "SurroundLevel", v) }
                    }
                    LevelRow(title: "Music Surround Level", range: -15...15, value: sound.musicSurroundLevel) { v in
                        sound.musicSurroundLevel = v; apply { try await Sonos.setEQ($0, "MusicSurroundLevel", v) }
                    }
                }
            }
            if room.parts.contains(where: { $0.role == .sub }) {
                Divider()
                Toggle("Sub", isOn: Binding(get: { sound.subOn ?? true }, set: { on in
                    sound.subOn = on
                    apply { try await Sonos.setEQ($0, "SubEnable", on ? 1 : 0) }
                }))
                if sound.subOn ?? true {
                    LevelRow(title: "Sub Level", range: -15...15, value: sound.subLevel) { v in
                        sound.subLevel = v; apply { try await Sonos.setEQ($0, "SubGain", v) }
                    }
                }
            }
            if sound.heightLevel != nil {
                Divider()
                LevelRow(title: "Height Level", range: -10...10, value: sound.heightLevel) { v in
                    sound.heightLevel = v; apply { try await Sonos.setEQ($0, "HeightChannelLevel", v) }
                }
            }
        }
        .animation(.smooth, value: sound)
        .sheet(item: $picked) { p in
            VStack(spacing: 14) {
                Text(p.roleName).font(.title3.bold())
                Text(p.model.map { "Sonos \($0)" } ?? "Sonos").foregroundStyle(.secondary)
                if let h = p.host { LabeledContent("Address", value: h) }
                LabeledContent("ID", value: p.id).font(.footnote.monospaced())
            }
            .padding(24)
            .presentationDetents([.height(220)])
            .macResizable(width: 380, height: 240, minWidth: 300, minHeight: 200)
        }
    }

    /// Sends a setting; if the speaker says no, shows why and reads the real settings back (so the switch
    /// doesn't stay in a position the speaker isn't in).
    private func apply(_ op: @escaping @Sendable (SonosRoom) async throws -> Void) {
        let r = room
        Task {
            do { try await op(r) } catch {
                SmartHome.shared.report(r, error)
                sound = await Sonos.sound(r)
            }
        }
    }

    private var layout: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            ZStack {
                // The room.
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [5, 5]))
                // The TV on the front wall, and where you sit.
                VStack(spacing: 3) {
                    Capsule().fill(.white.opacity(0.22)).frame(width: w * 0.46, height: 4)
                    Text("TV").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                }
                .position(x: w / 2, y: 16)
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.07))
                    .frame(width: w * 0.34, height: 40)
                    .overlay { Text("You").font(.caption.weight(.medium)).foregroundStyle(.tertiary) }
                    .position(x: w / 2, y: h * 0.74)
                ForEach(room.parts) { p in
                    piece(p)
                        .frame(width: p.role == .front ? w * 0.5 : 86)
                        .position(spot(p.role, w: w, h: h))
                        .onTapGesture { picked = p }
                }
            }
        }
    }

    private func spot(_ role: SonosPart.Role, w: CGFloat, h: CGFloat) -> CGPoint {
        switch role {
        case .front: return CGPoint(x: w / 2, y: 62)
        case .left: return CGPoint(x: w * 0.2, y: 62)
        case .right: return CGPoint(x: w * 0.8, y: 62)
        case .sub: return CGPoint(x: w * 0.84, y: h * 0.42)
        case .leftRear: return CGPoint(x: w * 0.14, y: h * 0.74)
        case .rightRear: return CGPoint(x: w * 0.86, y: h * 0.74)
        }
    }

    @ViewBuilder private func piece(_ p: SonosPart) -> some View {
        let lit = room.isPlaying && (p.role == .front || p.role == .left || p.role == .right
            || (p.role == .sub && sound.subOn != false) || ((p.role == .leftRear || p.role == .rightRear) && sound.surroundOn != false))
        VStack(spacing: 5) {
            Group {
                switch p.role {
                case .front: Capsule().frame(width: 130, height: 14)
                case .sub: RoundedRectangle(cornerRadius: 8, style: .continuous).frame(width: 34, height: 34)
                default: RoundedRectangle(cornerRadius: 9, style: .continuous).frame(width: 22, height: 34)
                }
            }
            .foregroundStyle(lit ? Color.white : Color.white.opacity(0.35))
            .shadow(color: lit ? .white.opacity(0.6) : .clear, radius: 10)
            Text(p.role == .front ? (p.model ?? room.model ?? "Soundbar") : (p.model ?? p.roleName))
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
        }
        .animation(.smooth, value: lit)
    }
}

// MARK: Sound

struct SoundCard: View {
    var room: SonosRoom
    @Binding var sound: SonosSound

    var body: some View {
        GlassCard(title: "Sound") {
            if let n = sound.nightSound {
                toggle("Night Sound", "Quieter loud parts, clearer quiet ones, for late at night.", n) { on in
                    sound.nightSound = on; apply { try await Sonos.setEQ($0, "NightMode", on ? 1 : 0) }
                }
            }
            if let s = sound.speech {
                toggle("Speech Enhancement", "Makes dialogue easier to hear.", s) { on in
                    sound.speech = on; apply { try await Sonos.setEQ($0, "DialogLevel", on ? 1 : 0) }
                }
            }
            if let l = sound.loudness {
                toggle("Loudness", "Fuller bass at low volume.", l) { on in
                    sound.loudness = on; apply { try await Sonos.setLoudness($0, on) }
                }
            }
            if sound.bass != nil {
                Divider()
                LevelRow(title: "Bass", range: -10...10, value: sound.bass) { v in sound.bass = v; apply { try await Sonos.setBass($0, v) } }
            }
            if sound.treble != nil {
                LevelRow(title: "Treble", range: -10...10, value: sound.treble) { v in sound.treble = v; apply { try await Sonos.setTreble($0, v) } }
            }
        }
    }

    /// Sends a setting; if the speaker says no, shows why and reads the real settings back (so the switch
    /// doesn't stay in a position the speaker isn't in).
    private func apply(_ op: @escaping @Sendable (SonosRoom) async throws -> Void) {
        let r = room
        Task {
            do { try await op(r) } catch {
                SmartHome.shared.report(r, error)
                sound = await Sonos.sound(r)
            }
        }
    }

    private func toggle(_ title: String, _ detail: String, _ on: Bool, _ set: @escaping (Bool) -> Void) -> some View {
        Toggle(isOn: Binding(get: { on }, set: set)) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: Group

/// Other rooms to play the same thing, as in the Sonos app's Group button.
struct GroupCard: View {
    var room: SonosRoom
    var home = SmartHome.shared

    private var others: [SonosRoom] { home.speakers.filter { $0.id != room.id } }

    var body: some View {
        if !others.isEmpty {
            GlassCard(title: "Play Together", footer: "Rooms you tick play what \(room.name) is playing.") {
                ForEach(others) { o in
                    let together = !o.isOffline && o.coordinatorHost == room.coordinatorHost
                    Button {
                        let leader = room
                        Task {
                            await home.regroup(o.id) {
                                if together { try await Sonos.leave(o) } else { try await Sonos.join(o, to: leader) }
                            }
                        }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(o.name)
                                if let e = home.speakerErrors[o.id] {
                                    Text(e).font(.caption).foregroundStyle(Palette.attention).lineLimit(1)
                                } else if o.isOffline {
                                    Text("Offline").font(.caption).foregroundStyle(.secondary)
                                } else if let s = o.isTV ? "TV" : o.title {
                                    Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Spacer()
                            Image(systemName: together ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(together ? Color.accentColor : .secondary)
                                .contentTransition(.symbolEffect(.replace))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(o.isOffline || room.isOffline)
                    .opacity(o.isOffline ? 0.5 : 1)
                }
            }
        }
    }
}

// MARK: Name and room

struct NameRoomCard: View {
    @Environment(Fleet.self) private var fleet
    var id: String
    var current: String
    var original: String?
    var home = SmartHome.shared
    @State private var name = ""
    @State private var addingRoom = false
    @State private var newRoom = ""

    var body: some View {
        GlassCard(title: "Name and Room") {
            HStack(spacing: 10) {
                TextField("Name", text: $name)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .glass(Capsule(), interactive: false)
                    .onSubmit { home.rename(id, name) }
                if name.trimmingCharacters(in: .whitespaces) != current && !name.isEmpty {
                    Button("Save") { home.rename(id, name) }.buttonStyle(.glassProminent)
                }
            }
            if let original, original != current {
                Button("Use Sonos Name “\(original)”") { name = original; home.rename(id, "") }
                    .font(.subheadline)
            }
            HStack {
                Text("Room")
                Spacer()
                Menu {
                    Button("No Room") { home.setRoom(id, nil) }
                    ForEach(allRooms(fleet), id: \.self) { r in Button(r) { home.setRoom(id, r) } }
                    Divider()
                    Button("New Room…") { addingRoom = true }
                } label: {
                    Text(home.room(of: id) ?? "No Room").padding(.horizontal, 14).padding(.vertical, 8)
                }
                .menuStyle(.button)
                .buttonStyle(.glass)
                .fixedSize()
            }
        }
        .onAppear { name = current }
        .alert("New Room", isPresented: $addingRoom) {
            TextField("Room Name", text: $newRoom)
            Button("Add") { home.setRoom(id, newRoom); newRoom = "" }
            Button("Cancel", role: .cancel) { newRoom = "" }
        }
    }
}
