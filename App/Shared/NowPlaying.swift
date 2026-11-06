import SwiftUI
import WoodruffKit

// What a TV is playing, shown as it plays: the title's artwork, a progress bar that moves every second,
// and the transport. TVs blank video out of screen grabs, so the picture is the title's own art.

/// Milliseconds played right now: the TV's last answer plus the time since, while it plays. Each TV's answer
/// carries when it arrived (`reportedAt`); [since] is only for one that doesn't.
func livePosition(_ p: NowPlaying, at date: Date, since: Date?) -> Double {
    var q = p
    if q.reportedAt == nil { q.reportedAt = since }
    return q.estimatedPosition(at: date)
}

/// Finds the real thumbnail of a YouTube video the TV is playing, from its title and channel (YouTube doesn't
/// hand its artwork to the TV app). Answers are kept, so each video is looked up once.
@Observable @MainActor
final class VideoThumbnails {
    static let shared = VideoThumbnails()
    private(set) var found: [String: URL] = [:]
    @ObservationIgnored private var asked: Set<String> = []

    nonisolated static func key(_ p: NowPlaying) -> String { (p.title + "|" + (p.subtitle ?? "")).lowercased() }

    func url(for p: NowPlaying?) -> URL? {
        guard let p, (p.app ?? "").lowercased().contains("youtube") else { return nil }
        let k = Self.key(p)
        if let u = found[k] { return u }
        if !asked.contains(k) { asked.insert(k); Task { await look(p, k) } }
        return nil
    }

    private func look(_ p: NowPlaying, _ k: String) async {
        if let id = UserDefaults.standard.dictionary(forKey: "ytThumbs")?[k] as? String { found[k] = Self.thumb(id); return }
        var c = URLComponents(string: "https://www.youtube.com/results")!
        c.queryItems = [URLQueryItem(name: "search_query", value: [p.title, p.subtitle ?? ""].joined(separator: " "))]
        var r = URLRequest(url: c.url!, timeoutInterval: 12)
        r.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        r.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: r) else { return }
        let html = String(decoding: data, as: UTF8.self)
        guard let m = html.range(of: #""videoId":"([A-Za-z0-9_-]{11})""#, options: .regularExpression) else { return }
        let id = String(html[m].dropFirst(11).prefix(11))
        var saved = UserDefaults.standard.dictionary(forKey: "ytThumbs") ?? [:]
        saved[k] = id
        if saved.count > 200 { saved = [k: id] }
        UserDefaults.standard.set(saved, forKey: "ytThumbs")
        found[k] = Self.thumb(id)
    }

    static func thumb(_ id: String) -> URL { URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg")! }
}

/// Whether there's a real picture for [p]: library art, or a YouTube video's thumbnail.
@MainActor func hasPicture(_ fleet: Fleet, _ p: NowPlaying?) -> Bool {
    guard let p else { return false }
    return fleet.artwork(for: p) != nil || VideoThumbnails.shared.url(for: p) != nil
}

/// The picture of what's playing: the title's poster or backdrop from the library, a YouTube video's own
/// thumbnail, or a quiet tile with the app's name.
struct NowPlayingArt: View {
    @Environment(Fleet.self) private var fleet
    var playing: NowPlaying?
    var backdrop = false
    /// The most pixels the picture is decoded at on its longer side: a small thumbnail needs few (256), a tile more
    /// (1024), a backdrop the most (1800).
    var maxPixel: Int = 1024

    var body: some View {
        let art = fleet.artwork(for: playing)
        let path = backdrop ? (art?.backdrop ?? art?.poster) : (art?.poster ?? art?.backdrop)
        if let path, let url = fleet.hubClient()?.art(path) {
            Artwork(url: url, maxPixel: maxPixel)
        } else if let url = VideoThumbnails.shared.url(for: playing) {
            // hqdefault is 4:3 with black bars; filling crops them away.
            Artwork(url: url, maxPixel: maxPixel).scaleEffect(1.34)
        } else {
            ZStack {
                LinearGradient(colors: [Color(white: 0.2), Color(white: 0.09)], startPoint: .topLeading, endPoint: .bottomTrailing)
                // No picture found: at least the title, not the app's name.
                Text(playing?.title ?? playing?.app ?? "TV")
                    .font(.system(.headline, design: .rounded).weight(.semibold))
                    .foregroundStyle(.white.opacity(0.55))
                    .minimumScaleFactor(0.4)
                    .lineLimit(1)
                    .padding(6)
            }
        }
    }
}

/// A thin progress bar with elapsed and remaining time. It's drawn again only as often as it changes: every second
/// with the times showing, otherwise each time it moves a pixel (a film on a tile: every several seconds), and not
/// at all while paused.
struct LiveProgress: View {
    @Environment(Fleet.self) private var fleet
    @Environment(\.displayScale) private var displayScale
    var playing: NowPlaying
    var times = true
    var tint: Color = .primary
    /// The bar's width (how far it moves for a pixel), without the times.
    @State private var width: CGFloat = 0

    var body: some View {
        if let d = playing.duration, d > 0 {
            TimelineView(.periodic(from: .now, by: interval(d))) { ctx in
                // The TV's own clock for this title (when its answer arrived), so the bar never jumps back on a
                // slightly stale answer; the app-wide time is only for an answer that doesn't carry one.
                let pos = livePosition(playing, at: ctx.date, since: playing.reportedAt ?? fleet.refreshedAt)
                VStack(spacing: 4) {
                    GeometryReader { g in
                        Capsule().fill(tint.opacity(0.2))
                            .overlay(alignment: .leading) {
                                Capsule().fill(tint).frame(width: max(4, g.size.width * min(1, max(0, pos / d))))
                                    // Beside the times (drawn every second) it glides from one second to the next; on a
                                    // tile (drawn once a pixel) each step, and any real change from the TV, is a quick one.
                                    .animation(times && playing.isPlaying ? Animation.linear(duration: 1) : Animation.snappy, value: pos)
                            }
                    }
                    .frame(height: times ? 5 : 3)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { w in
                        if !times, abs(w - width) >= 1 { width = w }
                    }
                    if times {
                        HStack {
                            Text(formatTime(ms: pos))
                            Spacer()
                            Text("−" + formatTime(ms: max(0, d - pos)))
                        }
                        .font(.caption2.monospacedDigit().weight(.medium))
                        .foregroundStyle(tint.opacity(0.6))
                    }
                }
            }
        }
    }

    /// Seconds between drawings of a title [duration] ms long: every second beside the times; otherwise once per
    /// pixel the bar moves, between 1 and 30 seconds. Paused, it doesn't move (the TV's next answer redraws it).
    private func interval(_ duration: Double) -> TimeInterval {
        guard playing.isPlaying else { return 3600 }
        if times { return 1 }
        let pixels = Double(max(1, width * displayScale))
        return min(30, max(1, duration / 1000 / pixels))
    }
}

/// The floating glass bar above the tabs (not on Remote): what the remote's TV plays now (nothing once it's off or was
/// left paused). Tap for Now Playing.
struct NowPlayingBar: View {
    @Environment(Fleet.self) private var fleet
    @State private var open = false

    var body: some View {
        if let tv = fleet.selected, let p = tv.nowPlaying {
            HStack(spacing: 12) {
                Button { open = true } label: {
                    HStack(spacing: 10) {
                        NowPlayingArt(playing: p, maxPixel: 256)
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
            .sheet(isPresented: $open) { NowPlayingSheet().sheetBanner().macResizable(width: 560, height: 780) }
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
    /// Taps so far: a guess is only cleared by the tap that made it.
    @State private var taps = 0

    var body: some View {
        let isPlaying = flipped ?? playing.isPlaying
        HStack(spacing: compact ? 4 : 52) {
            if playing.can("back10") { button("gobackward.10", "back10", size: compact ? 17 : 30) }
            button(isPlaying ? "pause.fill" : "play.fill", "playpause", size: compact ? 19 : 46)
            if playing.can("fwd30") { button("goforward.30", "fwd30", size: compact ? 17 : 30) }
        }
        .onChange(of: playing.isPlaying) { _, _ in flipped = nil }
    }

    private func button(_ symbol: String, _ action: String, size: CGFloat) -> some View {
        Button {
            if action == "playpause" { withAnimation(.snappy) { flipped = !(flipped ?? playing.isPlaying) } }
            taps += 1
            let tap = taps
            Task {
                guard let c = fleet.client(for: tv) else { flipped = nil; return }
                do {
                    // The client tells the fleet, which asks the TV again at once and a moment later.
                    if action == "playpause" { try await c.key("playpause") } else { try await c.media(action) }
                    // The TV's answer replaces the guess as soon as it changes (onChange above). If it never does
                    // (the TV ignored the key), show what the TV really says instead of a button that lies.
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    if taps == tap && flipped != nil { withAnimation(.snappy) { flipped = nil } }
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
                        // A picture only of what's playing now (not of a title left paused long ago).
                        Group {
                            if tv.nowPlaying != nil { NowPlayingArt(playing: playing, maxPixel: 256) } else { Color.secondary.opacity(0.18) }
                        }
                        .frame(width: 52, height: 52)
                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
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
        .sheet(isPresented: $open) { NowPlayingSheet().sheetBanner().macResizable(width: 560, height: 780) }
    }
}

/// Now Playing, full screen: the picture of what's playing (16:9) over a deep blur of it, the title, a thin
/// progress bar, three transport controls and three matching volume buttons. (Android) the corner button shows
/// the TV's own screen instead of the picture.
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
        // The title and the controls follow what the TV says; the pictures only what's playing now (plain black for a
        // TV that's off, or a title left paused).
        let p = tv?.playing
        let art = tv?.nowPlaying
        NavigationStack {
            GeometryReader { geo in
                let w = min(geo.size.width, 560) - 48
                VStack(spacing: 0) {
                    Spacer(minLength: 12)
                    picture(art)
                        .frame(width: w, height: w * 9 / 16)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.08)))
                        .shadow(color: .black.opacity(0.5), radius: 30, y: 16)
                        .scaleEffect(p?.isPlaying == false ? 0.92 : 1)
                        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: p?.isPlaying)
                    Spacer(minLength: 28)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(p?.title ?? "Nothing Playing")
                            .font(.title3.weight(.bold))
                            .lineLimit(2)
                        Text(subtitle(p))
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                    }
                    .frame(width: w, alignment: .leading)
                    if let p {
                        LiveProgress(playing: p, tint: .white)
                            .frame(width: w)
                            .padding(.top, 20)
                    }
                    Spacer(minLength: 18)
                    if let tv, let p {
                        Transport(tv: tv, playing: p)
                    }
                    Spacer(minLength: 22)
                    if let tv { volume(tv) }
                    Spacer(minLength: 16)
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
            .foregroundStyle(.white)
            .background { backdrop(art) }
            .environment(\.colorScheme, .dark)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "chevron.down") }
                        .accessibilityLabel("Close")
                }
                if tvID == nil { ToolbarItem(placement: .principal) { TVPicker() }.sharedBackgroundVisibility(.hidden) }
                // Carry on in another room: the same title, from the same spot, on another TV (this one pauses).
                if let tv, let now = tv.nowPlaying, let key = now.key, !key.isEmpty, !otherTVs(than: tv).isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Section("Move to") {
                                ForEach(otherTVs(than: tv)) { other in
                                    Button(other.name) { move(now, key: key, from: tv, to: other) }
                                }
                            }
                        } label: {
                            Image(systemName: "arrow.right.circle")
                        }
                        .accessibilityLabel("Move to Another TV")
                    }
                }
                if tv.map({ fleet.platform(of: $0) != .webOS && $0.onScreen }) ?? false {
                    ToolbarItem(placement: .primaryAction) {
                        Button { withAnimation(.smooth) { showScreen.toggle() } } label: {
                            Image(systemName: showScreen ? "photo" : "rectangle.on.rectangle")
                        }
                        .accessibilityLabel(showScreen ? "Show the Picture" : "Show the TV’s Screen")
                    }
                }
            }
            .task(id: "\(tv?.id ?? "")-\(showScreen)") { await screenLoop(tv) }
        }
        .presentationDragIndicator(.visible)
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 480, maxWidth: .infinity, minHeight: 720, idealHeight: 720, maxHeight: .infinity)
        #endif
    }

    private func otherTVs(than tv: FleetTV) -> [FleetTV] {
        fleet.tvs.filter { $0.id != tv.id && !$0.isUnpaired }
    }

    /// Starts [now] on [other] where it is right now, pauses it here, and follows it there.
    private func move(_ now: NowPlaying, key: String, from tv: FleetTV, to other: FleetTV) {
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        #endif
        let action = PlayAction(key: key, title: now.title, position: now.estimatedPosition(at: Date()), label: nil,
                                duration: now.duration, resume: nil, latest: nil)
        if !other.online { fleet.wake(other) }
        guard PlayRouter.start(action, fleet: fleet, on: other) else { return }
        if now.isPlaying, let c = fleet.client(for: tv) { Task { try? await c.key("playpause") } }
        // The sheet (when it follows the remote's TV) and the remote move with it.
        if tvID == nil { fleet.selectedID = other.id } else { dismiss() }
    }

    /// The picture: the video's thumbnail, the title's backdrop, or the TV's screen (Woodruff's own menus). Plain black
    /// when nothing is playing now.
    @ViewBuilder private func picture(_ p: NowPlaying?) -> some View {
        ZStack {
            Color.black
            if showScreen {
                if let screen { Image(platformImage: screen).resizable().aspectRatio(contentMode: .fit) }
                else { Text(screenNote ?? "Loading the TV’s screen…").font(.footnote).foregroundStyle(.white.opacity(0.6)).padding() }
            } else if let p {
                NowPlayingArt(playing: p, backdrop: true, maxPixel: 1800)
            }
        }
    }

    /// A deep, dark blur of the picture, held to the screen (just the dark when nothing is playing now).
    private func backdrop(_ p: NowPlaying?) -> some View {
        GeometryReader { g in
            ZStack {
                Color(white: 0.07)
                if let p {
                    NowPlayingArt(playing: p, backdrop: true, maxPixel: 1800)
                        .frame(width: g.size.width, height: g.size.height)
                        .blur(radius: 80, opaque: true)
                        .saturation(1.2)
                        .opacity(0.55)
                        .clipped()
                }
                LinearGradient(colors: [.black.opacity(0.2), .black.opacity(0.55), .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
            }
        }
        .ignoresSafeArea()
    }

    private func subtitle(_ p: NowPlaying?) -> String {
        let parts = [p?.subtitle, p?.app].compactMap { $0?.isEmpty == false ? $0 : nil }
        return parts.isEmpty ? " " : parts.joined(separator: " · ")
    }

    /// Three matching glass buttons: down, mute, up (each repeats while held, like the remote's).
    private func volume(_ tv: FleetTV) -> some View {
        HStack(spacing: 28) {
            VolumeCircle(symbol: "speaker.minus.fill", label: "Volume Down") { n in key(tv, "voldown", n) }
            VolumeCircle(symbol: "speaker.slash.fill", label: "Mute", repeats: false) { _ in key(tv, "mute", 0) }
            VolumeCircle(symbol: "speaker.plus.fill", label: "Volume Up") { n in key(tv, "volup", n) }
        }
        .glassGroup(spacing: 28)
    }

    private func key(_ tv: FleetTV, _ k: String, _ n: Int) {
        Task {
            do {
                // As the remote sends it (an Android TV's own volume, when its remote is paired).
                try await RemoteKeys.press(k, on: tv, fleet: fleet, repeat: n)
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

/// A round glass volume button that repeats while held.
struct VolumeCircle: View {
    var symbol: String
    var label: String
    var repeats = true
    var press: (Int) -> Void

    var body: some View {
        RepeatPress(onPress: { n in if repeats || n == 0 { press(n) } }) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 58, height: 58)
                .glass(Circle())
        }
        .accessibilityLabel(label)
    }
}
