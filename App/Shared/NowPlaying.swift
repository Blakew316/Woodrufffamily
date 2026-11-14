import SwiftUI
import ImageIO
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
            // Not ticking while nothing can see it (window hidden or covered, app in the background).
            TimelineView(.periodic(from: .now, by: fleet.isActive ? interval(d) : 3600)) { ctx in
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

#if os(macOS)
/// The Mac's floating glass bar at the bottom of a page: what the remote's TV plays now (nothing once it's off or was
/// left paused). Click for Now Playing. (On iPhone and iPad it's the tab bar's own accessory: `TabViewNowPlaying`.)
struct NowPlayingBar: View {
    @Environment(Fleet.self) private var fleet
    @State private var open = false
    private let widest: CGFloat = .infinity

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
            .frame(maxWidth: widest)
            .padding(.horizontal, 16)
            .padding(.bottom, 6)
            .sheet(isPresented: $open) { NowPlayingSheet().sheetBanner().macResizable(width: 560, height: 780) }
            // The bar going (the TV stopped) takes its sheet with it: forgotten too, or the sheet opened by itself
            // the next time something played.
            .onDisappear { open = false }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
#endif

#if os(iOS)
/// iPhone and iPad: what the remote's TV plays now as the tab bar's own accessory (iOS draws its glass and places it:
/// above the tab bar, and in line with it once the bar has tucked away on a scroll), and the Now Playing sheet a tap
/// on it opens. There while something plays, and not on Remote, which shows it itself, as far as this iOS lets an
/// accessory come and go (see `attach`). A modifier of its own, so the TVs reporting every second or two redraws
/// this and not the window's root.
struct TabViewNowPlaying: ViewModifier {
    @Environment(Fleet.self) private var fleet
    /// The Remote tab is the one showing.
    var onRemote: Bool
    /// Now Playing is open. Kept here and not in the accessory: from iOS 26.1 (until 27) the accessory's own views are
    /// made again whenever the tab changes, and what they remembered goes with them.
    @State private var open = false

    func body(content: Content) -> some View {
        attach(content, playing: fleet.selected?.nowPlaying != nil)
            .sheet(isPresented: $open) { NowPlayingSheet().sheetBanner() }
    }

    /// The accessory, there only while it has something to show:
    /// - iOS 26.2 and later: the switch iOS has for that, `tabViewBottomAccessory(isEnabled:content:)` (26.1 has it
    ///   too, but slow to follow there). It came with Xcode 26.2 (Swift 6.2.3): built with an earlier Xcode, the app
    ///   does as the next two lines say on every iOS.
    /// - iOS 26.0 leaves out an accessory with nothing in it. (Not tied to the tab there: Remote has it too.)
    /// - From iOS 26.1 an accessory with nothing in it is an empty capsule: it stays, and says nothing is playing.
    @ViewBuilder private func attach(_ content: Content, playing: Bool) -> some View {
        #if compiler(>=6.2.3)
        if #available(iOS 26.2, *) {
            content.tabViewBottomAccessory(isEnabled: playing && !onRemote) { bar }
        } else {
            content.tabViewBottomAccessory { if playing || !Self.emptyIsLeftOut { bar } }
        }
        #else
        content.tabViewBottomAccessory { if playing || !Self.emptyIsLeftOut { bar } }
        #endif
    }

    /// The accessory's content. Given the fleet by hand: the accessory is drawn apart from the tab view's pages.
    private var bar: some View {
        NowPlayingAccessory { open = true }
            .environment(fleet)
    }

    /// Whether this iOS leaves out an accessory with nothing in it (26.0 does; from 26.1 it's drawn, empty).
    private static let emptyIsLeftOut: Bool = {
        if #available(iOS 26.1, *) { return false }
        return true
    }()
}

/// What the tab bar's accessory shows: the picture, the title over the TV's name, and the transport. In line with the
/// tucked-away tab bar there's less room: the picture, the title and Play/Pause. Tap for Now Playing.
struct NowPlayingAccessory: View {
    @Environment(Fleet.self) private var fleet
    /// Where iOS has put the accessory: above the tab bar (expanded), or in line with it once it has tucked away.
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    /// Opens Now Playing.
    var open: () -> Void

    var body: some View {
        let tv = fleet.selected
        let p = tv?.nowPlaying
        let inline = placement == .inline
        let title: String = p?.title ?? "Nothing Playing"
        let side: CGFloat = inline ? 28 : 32
        HStack(spacing: 6) {
            Button(action: open) {
                HStack(spacing: 10) {
                    if let p {
                        NowPlayingArt(playing: p, maxPixel: 256)
                            .frame(width: side, height: side)
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        if let tv, !inline {
                            Text(detail(tv, p)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    // A long title stops here: where iOS makes the accessory as wide as what's in it, it isn't stretched
                    // across an iPad.
                    .frame(maxWidth: 420, alignment: .leading)
                    Spacer(minLength: 0)
                }
                // About as tall as the accessory, so a tap just above or below the words opens Now Playing too.
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Its words are held to a size that fits (below): press and hold shows them large, as a tab's own name is.
            .accessibilityShowsLargeContentViewer()
            if let tv, let p {
                Transport(tv: tv, playing: inline ? playPauseOnly(p) : p, compact: true)
            }
        }
        .padding(.leading, p == nil ? 16 : 10)
        .padding(.trailing, 8)
        // The accessory is as tall as iOS makes it: its words stop growing before they'd be cut off.
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
    }

    /// Under the title: the TV, and the app that's playing on it.
    private func detail(_ tv: FleetTV, _ p: NowPlaying?) -> String {
        guard let app = p?.app else { return tv.name }
        return tv.name + " · " + app
    }

    /// [p] with Play/Pause alone to offer: in line with the tab bar there's no room for the skips.
    private func playPauseOnly(_ p: NowPlaying) -> NowPlaying {
        var q = p
        q.can = nil
        return q
    }
}
#endif

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
                #if os(iOS)
                // The small ones (over the tabs, on a TV's tile) take a touch 44 points across; they look and sit as
                // they did.
                .contentShape(Rectangle().inset(by: compact ? -5 : 0))
                #else
                .contentShape(Rectangle())
                #endif
        }
        .buttonStyle(PressScale(scale: 0.85))
        #if os(iOS)
        .accessibilityLabel(spoken(action, symbol))
        #else
        .accessibilityLabel(action)
        #endif
    }

    #if os(iOS)
    /// What VoiceOver calls each button (it read out "playpause", "back10" and "fwd30").
    private func spoken(_ action: String, _ symbol: String) -> String {
        switch action {
        case "back10": return "Back 10 Seconds"
        case "fwd30": return "Ahead 30 Seconds"
        default: return symbol == "pause.fill" ? "Pause" : "Play"
        }
    }
    #endif
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

/// Now Playing, full screen: the picture of what's playing over a deep blur of it, the title, a thin progress bar,
/// three transport controls and three matching volume buttons. On iPhone and iPad the picture is a film's poster,
/// tall, in all the room above the controls (16:9 for anything without one), the controls are one block at the
/// bottom, and one More button moves the title to another TV or (Android) shows the TV's own screen in place of the
/// picture. On the Mac the picture is 16:9 and those are two buttons.
struct NowPlayingSheet: View {
    @Environment(Fleet.self) private var fleet
    @Environment(\.dismiss) private var dismiss
    /// A particular TV (from its page); nil follows the remote's TV.
    var tvID: String? = nil
    @State private var showScreen = false
    @State private var screen: PlatformImage?
    @State private var screenNote: String?
    /// The TV [screen] is of.
    @State private var screenOf: String?
    #if os(iOS)
    @Environment(\.verticalSizeClass) private var heightClass
    #endif

    var body: some View {
        let tv = tvID.flatMap { fleet.tv($0) } ?? fleet.selected
        // The title and the controls follow what the TV says; the pictures only what's playing now (plain black for a
        // TV that's off, or a title left paused). (On Apple TV its remote panel reads what the TV says for itself.)
        #if !os(tvOS)
        let p = tv?.playing
        #endif
        let art = tv?.nowPlaying
        NavigationStack {
            GeometryReader { geo in
                #if os(tvOS)
                // Apple TV: the picture beside the TV's remote panel, both the size a TV screen needs (the iPhone's
                // column below came out 512 points wide in the middle of it). The whole width under the bar leads to
                // the panel's keys, so Down from any of the bar's buttons reaches them.
                tvPage(tv, art).frame(width: geo.size.width, height: geo.size.height).focusSection()
                #else
                #if os(iOS)
                // iPhone on its side, or a sheet too short for it all one above another: the picture beside the controls.
                let low = heightClass == .compact || (geo.size.height < 560 && geo.size.width > geo.size.height)
                #else
                let low = false
                #endif
                if low {
                    let half: CGFloat = geo.size.width / 2
                    let w: CGFloat = max(120, min(half - 48, (geo.size.height - 32) * 16 / 9))
                    let side: CGFloat = min(half - 48, 420)
                    HStack(spacing: 0) {
                        framed(art, playing: p?.isPlaying, size: CGSize(width: w, height: w * 9 / 16))
                            .frame(width: half, height: geo.size.height)
                        VStack(spacing: 0) {
                            Spacer(minLength: 8)
                            words(p).frame(width: side, alignment: .leading)
                            if let p {
                                LiveProgress(playing: p, tint: .white)
                                    .frame(width: side)
                                    .padding(.top, 14)
                            }
                            Spacer(minLength: 14)
                            if let tv, let p {
                                Transport(tv: tv, playing: p)
                            }
                            Spacer(minLength: 16)
                            if let tv { volume(tv) }
                            Spacer(minLength: 8)
                        }
                        .frame(width: half, height: geo.size.height)
                    }
                } else {
                    let w = min(geo.size.width, 560) - 48
                    #if os(iOS)
                    // The picture takes all the room above the controls, as large as fits there: a film's poster tall,
                    // anything else wide. The title and every control are one block at the bottom, with the same
                    // gaps on every iPhone. (Five flexible gaps used to share the spare height: the picture hung well
                    // below the bar and the controls were strung down the page.)
                    let tall = hasPoster(art)
                    VStack(spacing: 0) {
                        GeometryReader { room in
                            framed(art, playing: p?.isPlaying, size: Self.pictureSize(tall: tall, in: room.size, width: w), tall: tall)
                                .frame(width: room.size.width, height: room.size.height)
                        }
                        .padding(.top, 8)
                        .padding(.bottom, 22)
                        words(p).frame(width: w, alignment: .leading)
                        if let p {
                            LiveProgress(playing: p, tint: .white)
                                .frame(width: w)
                                .padding(.top, 16)
                        }
                        if let tv, let p {
                            Transport(tv: tv, playing: p)
                                .padding(.top, 22)
                        }
                        if let tv { volume(tv).padding(.top, 24) }
                    }
                    .padding(.bottom, 14)
                    .frame(width: geo.size.width, height: geo.size.height)
                    #else
                    VStack(spacing: 0) {
                        Spacer(minLength: 12)
                        framed(art, playing: p?.isPlaying, size: CGSize(width: w, height: w * 9 / 16))
                        Spacer(minLength: 28)
                        words(p).frame(width: w, alignment: .leading)
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
                    #endif
                }
                #endif
            }
            .foregroundStyle(.white)
            .background { backdrop(art) }
            .environment(\.colorScheme, .dark)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "chevron.down") }
                        .accessibilityLabel("Close")
                }
                #if os(tvOS)
                if tvID == nil { ToolbarItem(placement: .principal) { TVPicker() } }
                #elseif os(iOS)
                // The TV's name gives way (shortens) rather than sliding under the buttons beside it.
                if tvID == nil { ToolbarItem(placement: .principal) { TVPicker(squeezes: true) }.sharedBackgroundVisibility(.hidden) }
                #else
                if tvID == nil { ToolbarItem(placement: .principal) { TVPicker() }.sharedBackgroundVisibility(.hidden) }
                #endif
                #if os(iOS)
                // iPhone and iPad: one More button with what it does in words. Two buttons took the room the TV's name
                // needs (at larger text sizes its pill slid under them and under Close), and neither said what it did.
                if canMove(tv) || showsScreen(tv) {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            // Carry on in another room: the same title, from the same spot, on another TV (this one pauses).
                            if let tv, let now = tv.nowPlaying, let key = now.key, canMove(tv) {
                                Section("Move to") {
                                    ForEach(otherTVs(than: tv)) { other in
                                        Button(other.name) { move(now, key: key, from: tv, to: other) }
                                    }
                                }
                            }
                            if showsScreen(tv) {
                                Button(showScreen ? "Show the Picture" : "Show the TV’s Screen") {
                                    withAnimation(.smooth) { showScreen.toggle() }
                                }
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                        .accessibilityLabel("More")
                    }
                }
                #else
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
                #endif
            }
            .task(id: "\(tv?.id ?? "")-\(showScreen)") { await screenLoop(tv) }
        }
        .presentationDragIndicator(.visible)
        #if os(macOS)
        // No taller than the screen has room for, as the sheet around it is (`macResizable`): a floor above the
        // sheet's own height would cut it off top and bottom.
        .frame(minWidth: 480, idealWidth: 480, maxWidth: .infinity, minHeight: macSheetHeight(720), idealHeight: macSheetHeight(720), maxHeight: .infinity)
        #endif
    }

    #if os(tvOS)
    /// Apple TV: the picture of what's playing (or the TV's own screen) on the left, when there is one, and the TV's
    /// remote panel on the right: its title, how far along it is, and the keys (`MiniRemote`), where the remote starts.
    private func tvPage(_ tv: FleetTV?, _ art: NowPlaying?) -> some View {
        HStack(spacing: 70) {
            if art != nil || showScreen {
                picture(art)
                    .frame(width: 800, height: 450)
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(.white.opacity(0.08)) }
                    .shadow(color: .black.opacity(0.5), radius: 30, y: 16)
            }
            if let tv { MiniRemote(tvID: tv.id, beside: true) }
        }
    }
    #endif

    private func otherTVs(than tv: FleetTV) -> [FleetTV] {
        fleet.tvs.filter { $0.id != tv.id && !$0.isUnpaired }
    }

    /// Whether what [tv] is playing can carry on in another room: one of the family's own titles, with another TV to
    /// move it to.
    private func canMove(_ tv: FleetTV?) -> Bool {
        guard let tv, let key = tv.nowPlaying?.key, !key.isEmpty else { return false }
        return !otherTVs(than: tv).isEmpty
    }

    /// Whether [tv]'s own screen can be shown here in place of the picture (Woodruff is on screen there; not on LG).
    private func showsScreen(_ tv: FleetTV?) -> Bool {
        tv.map { fleet.platform(of: $0) != .webOS && $0.onScreen } ?? false
    }

    /// Whether the picture is a poster (tall): the title has one, and the TV's own screen isn't being shown.
    private func hasPoster(_ p: NowPlaying?) -> Bool {
        guard !showScreen, let p else { return false }
        return fleet.artwork(for: p)?.poster != nil
    }

    /// The picture's size in the [room] it has: a poster (2:3) as tall as fits, anything else 16:9 as wide as fits,
    /// neither wider than [width].
    static func pictureSize(tall: Bool, in room: CGSize, width: CGFloat) -> CGSize {
        let most = max(0, min(width, room.width))
        if tall {
            let h = max(0, min(room.height, most * 3 / 2))
            return CGSize(width: h * 2 / 3, height: h)
        }
        let w = max(0, min(most, room.height * 16 / 9))
        return CGSize(width: w, height: w * 9 / 16)
    }

    /// Starts [now] on [other] where it is right now, pauses it here, and follows it there.
    private func move(_ now: NowPlaying, key: String, from tv: FleetTV, to other: FleetTV) {
        #if os(iOS) || os(tvOS)
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

    /// The picture in its frame of [size] ([tall]: the title's poster, not its wide picture), a little smaller while paused.
    private func framed(_ art: NowPlaying?, playing: Bool?, size: CGSize, tall: Bool = false) -> some View {
        picture(art, tall: tall)
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.08)))
            // Its shadow cast by a plain card of its shape behind it: the same shadow (the picture is opaque, on black).
            // Cast by the clipped picture itself, it was worked out off screen on every frame the sheet drew, and the
            // progress bar under it moves all the time.
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.black)
                    .shadow(color: .black.opacity(0.5), radius: 30, y: 16)
            }
            .scaleEffect(playing == false ? 0.92 : 1)
            .animation(.spring(response: 0.5, dampingFraction: 0.8), value: playing)
    }

    /// The title over what it's from.
    private func words(_ p: NowPlaying?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(p?.title ?? "Nothing Playing")
                .font(.title3.weight(.bold))
                .lineLimit(2)
            Text(subtitle(p))
                .font(.callout)
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
        }
    }

    /// The picture: the video's thumbnail, the title's backdrop, or the TV's screen (Woodruff's own menus). Plain black
    /// when nothing is playing now.
    @ViewBuilder private func picture(_ p: NowPlaying?, tall: Bool = false) -> some View {
        ZStack {
            Color.black
            if showScreen {
                if let screen { Image(platformImage: screen).resizable().aspectRatio(contentMode: .fit) }
                else { Text(screenNote ?? "Loading the TV’s screen…").font(.footnote).foregroundStyle(.white.opacity(0.6)).padding() }
            } else if let p {
                NowPlayingArt(playing: p, backdrop: !tall, maxPixel: 1800)
            }
        }
    }

    /// The film's own backdrop (else poster) when the TV has one: what `NowPlayingArt` would show for it.
    private func backdropURL(_ p: NowPlaying) -> URL? {
        let art = fleet.artwork(for: p)
        guard let path = art?.backdrop ?? art?.poster else { return nil }
        return fleet.hubClient()?.art(path)
    }

    /// A deep, dark blur of the picture, held to the screen (just the dark when nothing is playing now).
    private func backdrop(_ p: NowPlaying?) -> some View {
        GeometryReader { g in
            ZStack {
                Color(white: 0.07)
                if let p, let url = backdropURL(p) {
                    // The film's picture: blurred once, not on every frame drawn over it.
                    BlurredArtwork(url: url, radius: 80, opaque: true, maxPixel: 1800)
                        .frame(width: g.size.width, height: g.size.height)
                        .saturation(1.2)
                        .opacity(0.55)
                        .clipped()
                } else if let p {
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
        // Another TV's screen never shows as this one's while its first grab comes.
        if screenOf != tv.id { screen = nil; screenNote = nil; screenOf = tv.id }
        while !Task.isCancelled {
            var wait: UInt64 = 800_000_000
            if let c = fleet.client(for: tv) {
                do {
                    let data = try await c.screen()
                    // Decoded off the main thread (it comes about every second), ready to draw.
                    let img = await Task.detached(priority: .userInitiated) { Self.decode(data) }.value
                    guard !Task.isCancelled else { return }
                    screen = img
                    screenNote = nil
                } catch {
                    if Task.isCancelled { return }
                    screenNote = error.localizedDescription
                    wait = 3_000_000_000
                }
            }
            try? await Task.sleep(nanoseconds: wait)
        }
    }

    /// A screen grab decoded now (not when it's first drawn, on the main thread).
    nonisolated static func decode(_ data: Data) -> PlatformImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceShouldCacheImmediately: true,
                                        kCGImageSourceThumbnailMaxPixelSize: 1920]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
        #if os(macOS)
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        #else
        return UIImage(cgImage: cg)
        #endif
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
