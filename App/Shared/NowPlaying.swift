import SwiftUI
import WoodruffKit

// What a TV is playing, shown as it plays: the title's artwork, a progress bar that moves every second,
// and the transport. TVs blank video out of screen grabs, so the picture is the title's own art.

/// Seconds played right now: the TV's last answer plus the time since, while it plays.
func livePosition(_ p: NowPlaying, at date: Date, since: Date?) -> Double {
    let base = p.position ?? 0
    guard p.isPlaying, let since else { return base }
    let pos = base + date.timeIntervalSince(since) * 1000
    if let d = p.duration, d > 0 { return min(d, pos) }
    return pos
}

/// The title's poster (or backdrop), else a tile in the app's colour.
struct NowPlayingArt: View {
    @Environment(Fleet.self) private var fleet
    var playing: NowPlaying?
    var backdrop = false

    var body: some View {
        let art = fleet.artwork(for: playing)
        let path = backdrop ? (art?.backdrop ?? art?.poster) : (art?.poster ?? art?.backdrop)
        if let path, let url = fleet.hubClient()?.art(path) {
            Artwork(url: url)
        } else {
            ZStack {
                LinearGradient(colors: [appColor, appColor.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: symbol).font(.system(size: 18, weight: .bold)).foregroundStyle(.white.opacity(0.9))
            }
        }
    }

    private var app: String { playing?.app?.lowercased() ?? "" }
    private var appColor: Color {
        if app.contains("netflix") { return Color(red: 0.75, green: 0.05, blue: 0.08) }
        if app.contains("youtube") { return Color(red: 0.85, green: 0.1, blue: 0.1) }
        if app.contains("disney") { return Color(red: 0.05, green: 0.2, blue: 0.55) }
        if app.contains("prime") || app.contains("amazon") { return Color(red: 0.0, green: 0.55, blue: 0.85) }
        return .accentColor
    }
    private var symbol: String { playing == nil ? "tv" : app.contains("music") ? "music.note" : "play.fill" }
}

/// A thin progress bar with elapsed and remaining time, moving every second.
struct LiveProgress: View {
    @Environment(Fleet.self) private var fleet
    var playing: NowPlaying
    var times = true
    var tint: Color = .primary

    var body: some View {
        if let d = playing.duration, d > 0 {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let pos = livePosition(playing, at: ctx.date, since: fleet.refreshedAt)
                VStack(spacing: 4) {
                    GeometryReader { g in
                        Capsule().fill(tint.opacity(0.2))
                            .overlay(alignment: .leading) {
                                Capsule().fill(tint).frame(width: max(4, g.size.width * pos / d))
                            }
                    }
                    .frame(height: times ? 5 : 3)
                    if times {
                        HStack {
                            Text(formatTime(ms: pos))
                            Spacer()
                            Text("−" + formatTime(ms: d - pos))
                        }
                        .font(.caption2.monospacedDigit().weight(.medium))
                        .foregroundStyle(tint.opacity(0.6))
                    }
                }
            }
        }
    }
}

/// The floating glass bar above the tabs (not on Remote): what the remote's TV plays. Tap for Now Playing.
struct NowPlayingBar: View {
    @Environment(Fleet.self) private var fleet
    @State private var open = false

    var body: some View {
        if let tv = fleet.selected, let p = tv.playing {
            HStack(spacing: 12) {
                Button { open = true } label: {
                    HStack(spacing: 10) {
                        NowPlayingArt(playing: p)
                            .frame(width: 40, height: 40)
                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Text(tv.name + (p.app.map { " · \($0)" } ?? "")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Transport(tv: tv, playing: p, compact: true)
            }
            .padding(.leading, 8).padding(.trailing, 12).padding(.vertical, 8)
            .glass(Capsule())
            .padding(.horizontal, 16)
            .padding(.bottom, 6)
            .sheet(isPresented: $open) { NowPlayingSheet() }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

/// ↺10, Play/Pause, 30↻ and Next (whatever the TV allows now).
struct Transport: View {
    @Environment(Fleet.self) private var fleet
    var tv: FleetTV
    var playing: NowPlaying
    var compact = false
    @State private var flipped: Bool?

    var body: some View {
        let isPlaying = flipped ?? playing.isPlaying
        HStack(spacing: compact ? 4 : 36) {
            if playing.can("back10") { button("gobackward.10", "back10", size: compact ? 17 : 30) }
            button(isPlaying ? "pause.fill" : "play.fill", "playpause", size: compact ? 19 : 46)
            if playing.can("fwd30") { button("goforward.30", "fwd30", size: compact ? 17 : 30) }
            if !compact && playing.can("next") { button("forward.end.fill", "next", size: 26) }
        }
        .onChange(of: playing.isPlaying) { _, _ in flipped = nil }
    }

    private func button(_ symbol: String, _ action: String, size: CGFloat) -> some View {
        Button {
            if action == "playpause" { withAnimation(.snappy) { flipped = !(flipped ?? playing.isPlaying) } }
            Task {
                guard let c = fleet.client(for: tv) else { return }
                do {
                    if action == "playpause" { try await c.key("playpause") } else { try await c.media(action) }
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    await fleet.refresh()
                } catch { flipped = nil; fleet.show(error) }
            }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: compact ? 34 : size * 1.5, height: compact ? 34 : size * 1.5)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScale(scale: 0.85))
        .accessibilityLabel(action)
    }
}

/// Inside the remote: a slim bar with just the title that drops down into the full card (artwork, progress,
/// transport). The artwork opens the full player.
struct NowPlayingDropdown: View {
    @Environment(Fleet.self) private var fleet
    var tv: FleetTV
    var playing: NowPlaying
    @Binding var expanded: Bool
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) { expanded.toggle() } } label: {
                HStack(spacing: 10) {
                    Image(systemName: playing.isPlaying ? "waveform" : "pause.fill")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(Color.accentColor)
                        .symbolEffect(.variableColor.iterative, isActive: playing.isPlaying)
                        .frame(width: 18)
                    Text(playing.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.down")
                        .font(.footnote.weight(.bold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .padding(.horizontal, 16)
                .frame(height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(expanded ? "Hide what’s playing" : "Show what’s playing: \(playing.title)")

            if expanded {
                HStack(spacing: 12) {
                    Button { open = true } label: {
                        NowPlayingArt(playing: playing)
                            .frame(width: 52, height: 52)
                            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                            .overlay(alignment: .bottomTrailing) {
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                                    .font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                                    .padding(4).background(Circle().fill(.black.opacity(0.45))).padding(3)
                            }
                    }
                    .buttonStyle(PressScale())
                    .accessibilityLabel("Open the player")
                    VStack(alignment: .leading, spacing: 6) {
                        Text(playing.subtitle?.isEmpty == false ? playing.subtitle! : (playing.app ?? tv.name))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        LiveProgress(playing: playing, times: true)
                    }
                    Transport(tv: tv, playing: playing, compact: true)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .glass(RoundedRectangle(cornerRadius: expanded ? 24 : 22, style: .continuous))
        .sheet(isPresented: $open) { NowPlayingSheet() }
    }
}

/// Now Playing, full screen, like Apple Music's player: the poster large and centred over a field blurred from
/// it, the title, a scrubber that moves every second, big transport controls and the volume.
/// (Android) the corner button swaps the poster for the TV's own screen.
struct NowPlayingSheet: View {
    @Environment(Fleet.self) private var fleet
    @Environment(\.dismiss) private var dismiss
    /// A particular TV (from its page); nil follows the remote's TV.
    var tvID: String? = nil
    @State private var showScreen = false
    @State private var screen: PlatformImage?
    @State private var screenNote: String?

    var body: some View {
        let tv = tvID.flatMap { fleet.tv($0) } ?? fleet.selected
        let p = tv?.playing
        NavigationStack {
            GeometryReader { geo in
                let width = min(geo.size.width, 520) - 56
                VStack(spacing: 0) {
                    Spacer(minLength: 8)
                    hero(p, width: width, height: geo.size.height * 0.46)
                    Spacer(minLength: 20)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(p?.title ?? "Nothing Playing").font(.title3.bold()).lineLimit(1)
                        Text(subtitle(p)).font(.body).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                    }
                    .frame(width: width, alignment: .leading)
                    if let p {
                        LiveProgress(playing: p, tint: .white)
                            .frame(width: width)
                            .padding(.top, 22)
                    }
                    if let tv, let p {
                        Transport(tv: tv, playing: p)
                            .foregroundStyle(.white)
                            .padding(.top, 18)
                    }
                    Spacer(minLength: 16)
                    if let tv { volume(tv).frame(width: width) }
                    if let tv {
                        Label("Playing on \(tv.name)", systemImage: "tv")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.55))
                            .padding(.top, 16)
                    }
                    Spacer(minLength: 12)
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
            .foregroundStyle(.white)
            .background { backdrop(p) }
            .environment(\.colorScheme, .dark)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "chevron.down") }
                        .accessibilityLabel("Close")
                }
                if tvID == nil { ToolbarItem(placement: .principal) { TVPicker() }.sharedBackgroundVisibility(.hidden) }
                if tv.map({ fleet.platform(of: $0) != .webOS }) ?? false {
                    ToolbarItem(placement: .primaryAction) {
                        Button { withAnimation(.smooth) { showScreen.toggle() } } label: {
                            Image(systemName: showScreen ? "photo" : "rectangle.on.rectangle")
                        }
                        .accessibilityLabel(showScreen ? "Show Artwork" : "Show TV Screen")
                    }
                }
            }
            .task(id: "\(tv?.id ?? "")-\(showScreen)") { await screenLoop(tv) }
        }
        .presentationDragIndicator(.visible)
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 760)
        #endif
    }

    /// A deep field of the artwork's own colours, held to the screen's size.
    private func backdrop(_ p: NowPlaying?) -> some View {
        GeometryReader { g in
            NowPlayingArt(playing: p)
                .frame(width: g.size.width, height: g.size.height)
                .blur(radius: 70, opaque: true)
                .saturation(1.4)
                .clipped()
                .overlay(LinearGradient(colors: [.black.opacity(0.25), .black.opacity(0.55), .black.opacity(0.8)], startPoint: .top, endPoint: .bottom))
        }
        .ignoresSafeArea()
    }

    /// The poster (2:3) when the title has one, else its backdrop (16:9), or the TV's screen.
    @ViewBuilder private func hero(_ p: NowPlaying?, width: CGFloat, height: CGFloat) -> some View {
        let poster = fleet.artwork(for: p)?.poster != nil
        let size: CGSize = {
            if showScreen || !poster { return CGSize(width: width, height: width * 9 / 16) }
            let h = min(height, width * 1.5)
            return CGSize(width: h / 1.5, height: h)
        }()
        ZStack {
            if showScreen {
                Rectangle().fill(.black)
                if let screen { Image(platformImage: screen).resizable().aspectRatio(contentMode: .fit) }
                else { Text(screenNote ?? "Loading the TV’s screen…").font(.subheadline).foregroundStyle(.white.opacity(0.6)).multilineTextAlignment(.center).padding() }
            } else {
                NowPlayingArt(playing: p, backdrop: !poster)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: poster && !showScreen ? 14 : 18, style: .continuous))
        .shadow(color: .black.opacity(0.45), radius: 30, y: 18)
        .scaleEffect(p?.isPlaying == false ? 0.86 : 1)
        .animation(.spring(response: 0.5, dampingFraction: 0.75), value: p?.isPlaying)
    }

    private func subtitle(_ p: NowPlaying?) -> String {
        var parts: [String] = []
        if let s = p?.subtitle, !s.isEmpty { parts.append(s) }
        if let a = p?.app, !a.isEmpty { parts.append(a) }
        return parts.isEmpty ? " " : parts.joined(separator: " · ")
    }

    private func volume(_ tv: FleetTV) -> some View {
        HStack(spacing: 12) {
            Button { key(tv, "mute", 0) } label: {
                Image(systemName: "speaker.slash.fill").font(.subheadline).frame(width: 44, height: 44)
            }
            .buttonStyle(PressScale())
            .accessibilityLabel("Mute")
            HStack(spacing: 0) {
                RepeatPress(onPress: { n in key(tv, "voldown", n) }) {
                    Image(systemName: "speaker.minus.fill").font(.body).frame(maxWidth: .infinity, minHeight: 46)
                }
                .accessibilityLabel("Volume down")
                Rectangle().fill(.white.opacity(0.2)).frame(width: 0.5, height: 22)
                RepeatPress(onPress: { n in key(tv, "volup", n) }) {
                    Image(systemName: "speaker.plus.fill").font(.body).frame(maxWidth: .infinity, minHeight: 46)
                }
                .accessibilityLabel("Volume up")
            }
            .glass(Capsule())
        }
    }

    private func key(_ tv: FleetTV, _ k: String, _ n: Int) {
        Task {
            do {
                if let lg = fleet.lg(for: tv), let a = LGKeyMap.action(for: k) { try await a(lg) }
                else { try await fleet.client(for: tv)?.key(k, repeat: n) }
            } catch { if n == 0 { fleet.show(error) } }
        }
    }

    private func screenLoop(_ tv: FleetTV?) async {
        guard showScreen, let tv else { return }
        while !Task.isCancelled {
            var wait: UInt64 = 800_000_000
            if let c = fleet.client(for: tv) {
                do { screen = PlatformImage(data: try await c.screen()); screenNote = nil } catch {
                    screenNote = error.localizedDescription
                    wait = 3_000_000_000
                }
            }
            try? await Task.sleep(nanoseconds: wait)
        }
    }
}
