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
        HStack(spacing: compact ? 4 : 30) {
            if playing.can("back10") { button("gobackward.10", "back10", size: compact ? 17 : 28) }
            button(isPlaying ? "pause.fill" : "play.fill", "playpause", size: compact ? 19 : 44)
            if playing.can("fwd30") { button("goforward.30", "fwd30", size: compact ? 17 : 28) }
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
                .frame(width: compact ? 34 : size * 1.6, height: compact ? 34 : size * 1.6)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScale(scale: 0.85))
        .accessibilityLabel(action)
    }
}

/// Inside the remote: what's on, compact, so the remote's buttons stay free. Tap for Now Playing.
struct NowPlayingCard: View {
    @Environment(Fleet.self) private var fleet
    var tv: FleetTV
    var playing: NowPlaying
    @State private var open = false

    var body: some View {
        HStack(spacing: 12) {
            Button { open = true } label: {
                HStack(spacing: 12) {
                    NowPlayingArt(playing: playing)
                        .frame(width: 46, height: 46)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(playing.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(playing.subtitle?.isEmpty == false ? playing.subtitle! : (playing.app ?? tv.name))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        LiveProgress(playing: playing, times: false)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Transport(tv: tv, playing: playing, compact: true)
        }
        .padding(10)
        .glass(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .sheet(isPresented: $open) { NowPlayingSheet() }
    }
}

/// Now Playing, full screen: the title's art over a blurred backdrop, live progress, transport and volume,
/// and (Android) the TV's own screen.
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
            ZStack {
                background(p)
                VStack(spacing: 22) {
                    Spacer(minLength: 8)
                    hero(tv, p)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(p?.title ?? "Nothing Playing").font(.title2.bold()).lineLimit(2)
                        Text(subtitle(tv, p)).font(.body).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if let p { LiveProgress(playing: p) }
                    if let tv, let p { Transport(tv: tv, playing: p) }
                    if let tv { volume(tv) }
                    Spacer(minLength: 8)
                }
                .padding(.horizontal, 28)
                .frame(maxWidth: 560)
            }
            .environment(\.colorScheme, .dark)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(role: .close) { dismiss() } }
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
            .task(id: "\(fleet.selectedID ?? "")-\(showScreen)") { await screenLoop() }
        }
        .presentationDragIndicator(.visible)
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 720)
        #endif
    }

    @ViewBuilder private func background(_ p: NowPlaying?) -> some View {
        ZStack {
            Color.black
            NowPlayingArt(playing: p, backdrop: true)
                .blur(radius: 60)
                .scaleEffect(1.4)
                .opacity(0.75)
            LinearGradient(colors: [.black.opacity(0.15), .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
    }

    @ViewBuilder private func hero(_ tv: FleetTV?, _ p: NowPlaying?) -> some View {
        Group {
            if showScreen {
                ZStack {
                    Rectangle().fill(.black)
                    if let screen { Image(platformImage: screen).resizable().aspectRatio(contentMode: .fit) }
                    else { Text(screenNote ?? "Loading the TV’s screen…").font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center).padding() }
                }
                .aspectRatio(16 / 9, contentMode: .fit)
            } else {
                NowPlayingArt(playing: p, backdrop: true)
                    .aspectRatio(16 / 9, contentMode: .fill)
                    .overlay(alignment: .bottomLeading) {
                        if fleet.artwork(for: p)?.poster != nil {
                            NowPlayingArt(playing: p)
                                .frame(width: 74, height: 111)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .shadow(color: .black.opacity(0.5), radius: 12, y: 6)
                                .padding(14)
                        }
                    }
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.5), radius: 24, y: 12)
        .scaleEffect(p?.isPlaying == false ? 0.94 : 1)
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: p?.isPlaying)
    }

    private func subtitle(_ tv: FleetTV?, _ p: NowPlaying?) -> String {
        var parts: [String] = []
        if let s = p?.subtitle, !s.isEmpty { parts.append(s) }
        if let a = p?.app, !a.isEmpty { parts.append(a) }
        if let n = tv?.name { parts.append(n) }
        return parts.joined(separator: " · ")
    }

    private func volume(_ tv: FleetTV) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "speaker.fill").foregroundStyle(.secondary)
            HStack(spacing: 0) {
                RepeatPress(onPress: { n in key(tv, "voldown", n) }) {
                    Image(systemName: "minus").font(.headline).frame(maxWidth: .infinity, minHeight: 44)
                }
                Rectangle().fill(.separator).frame(width: 0.5, height: 22)
                RepeatPress(onPress: { n in key(tv, "volup", n) }) {
                    Image(systemName: "plus").font(.headline).frame(maxWidth: .infinity, minHeight: 44)
                }
            }
            .glass(Capsule())
            Button { key(tv, "mute", 0) } label: {
                Image(systemName: "speaker.slash.fill").font(.headline).frame(width: 44, height: 44).glass(Circle())
            }
            .buttonStyle(PressScale())
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

    private func screenLoop() async {
        guard showScreen else { return }
        while !Task.isCancelled {
            var wait: UInt64 = 800_000_000
            if let tv = tvID.flatMap({ fleet.tv($0) }) ?? fleet.selected, let c = fleet.client(for: tv) {
                do { screen = PlatformImage(data: try await c.screen()); screenNote = nil } catch {
                    screenNote = error.localizedDescription
                    wait = 3_000_000_000
                }
            }
            try? await Task.sleep(nanoseconds: wait)
        }
    }
}
