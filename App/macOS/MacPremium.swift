import SwiftUI
import AppKit
import MediaPlayer
import WidgetKit
import WoodruffKit

// MARK: - Ambient artwork

/// The window takes on a soft blur of what the remote's TV is playing, like Music's full-screen player.
struct AmbientArtwork: View {
    @Environment(Fleet.self) private var fleet
    var body: some View {
        let p = fleet.selected?.playing
        ZStack {
            if p != nil, fleet.artwork(for: p) != nil {
                GeometryReader { g in
                    NowPlayingArt(playing: p, backdrop: true)
                        .frame(width: g.size.width, height: g.size.height)
                        .blur(radius: 90, opaque: true)
                        .saturation(1.3)
                        .clipped()
                }
                .opacity(0.28)
                .transition(.opacity)
                .id(p?.title)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .animation(.easeInOut(duration: 1.2), value: p?.title)
    }
}

// MARK: - Hover tilt

/// Tilts a tile a little toward the pointer, with a moving highlight, like Apple TV's focus.
struct HoverTilt: ViewModifier {
    var cornerRadius: CGFloat = 24
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var point: CGPoint?
    @State private var size: CGSize = .zero

    func body(content: Content) -> some View {
        let dx = reduceMotion ? 0 : point.map { ($0.x / max(size.width, 1)) - 0.5 } ?? 0
        let dy = reduceMotion ? 0 : point.map { ($0.y / max(size.height, 1)) - 0.5 } ?? 0
        content
            .overlay {
                if let point {
                    RadialGradient(colors: [.white.opacity(0.16), .clear], center: UnitPoint(x: point.x / max(size.width, 1), y: point.y / max(size.height, 1)),
                                   startRadius: 0, endRadius: max(size.width, size.height) * 0.7)
                        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                        .allowsHitTesting(false)
                        .blendMode(.plusLighter)
                }
            }
            .rotation3DEffect(.degrees(Double(-dy) * 6), axis: (x: 1, y: 0, z: 0), perspective: 0.6)
            .rotation3DEffect(.degrees(Double(dx) * 6), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
            .animation(.spring(response: 0.35, dampingFraction: 0.75), value: point)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): point = p
                case .ended: point = nil
                }
            }
    }
}

extension View {
    func hoverTilt(cornerRadius: CGFloat = 24) -> some View { modifier(HoverTilt(cornerRadius: cornerRadius)) }
}

// MARK: - Mini player

/// A small always-on-top player (⌘⇧M), like Music's mini player.
struct MiniPlayerView: View {
    @Environment(Fleet.self) private var fleet

    var body: some View {
        let tv = fleet.selected
        let p = tv?.playing
        HStack(spacing: 14) {
            NowPlayingArt(playing: p ?? tv.flatMap { fleet.lastPlaying[$0.id] })
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(p?.title ?? "Nothing Playing").font(.headline).lineLimit(1)
                    Menu {
                        ForEach(fleet.tvs.filter { !$0.isUnpaired }) { t in
                            Button(t.name) { fleet.remoteAll = false; fleet.selectedID = t.id }
                        }
                    } label: {
                        Text(tv?.name ?? "No TV").font(.caption).foregroundStyle(.secondary)
                    }
                    .menuStyle(.button).buttonStyle(.plain).fixedSize()
                }
                if let tv, let p {
                    HStack(spacing: 10) {
                        LiveProgress(playing: p, times: false)
                        Transport(tv: tv, playing: p, compact: true)
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 380)
        .background(.regularMaterial)
    }
}

// MARK: - Media keys and the Mac's Now Playing

/// Makes the remote's TV the Mac's "now playing": its title shows in Control Center's Now Playing, and the
/// keyboard's play/pause and skip keys (and headphone buttons) control the TV.
@MainActor
final class NowPlayingBridge {
    static let shared = NowPlayingBridge()
    private var wired = false
    private var lastTitle: String?

    func wire() {
        guard !wired else { return }
        wired = true
        let c = MPRemoteCommandCenter.shared()
        c.togglePlayPauseCommand.addTarget { _ in self.key("playpause"); return .success }
        c.playCommand.addTarget { _ in self.key("playpause"); return .success }
        c.pauseCommand.addTarget { _ in self.key("playpause"); return .success }
        c.skipBackwardCommand.preferredIntervals = [10]
        c.skipForwardCommand.preferredIntervals = [30]
        c.skipBackwardCommand.addTarget { _ in self.media("back10"); return .success }
        c.skipForwardCommand.addTarget { _ in self.media("fwd30"); return .success }
        c.nextTrackCommand.addTarget { _ in self.media("next"); return .success }
    }

    func update(_ fleet: Fleet) {
        wire()
        let info = MPNowPlayingInfoCenter.default()
        guard let tv = fleet.selected, let p = tv.playing else {
            info.nowPlayingInfo = nil
            info.playbackState = .stopped
            lastTitle = nil
            return
        }
        var d: [String: Any] = [
            MPMediaItemPropertyTitle: p.title,
            MPMediaItemPropertyArtist: tv.name,
            MPMediaItemPropertyAlbumTitle: p.app ?? "Woodruff Family",
            MPNowPlayingInfoPropertyPlaybackRate: p.isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: (p.position ?? 0) / 1000,
        ]
        if let dur = p.duration, dur > 0 { d[MPMediaItemPropertyPlaybackDuration] = dur / 1000 }
        info.nowPlayingInfo = d
        info.playbackState = p.isPlaying ? .playing : .paused
        if lastTitle != p.title, let path = fleet.artwork(for: p)?.poster, let url = fleet.hubClient()?.art(path) {
            lastTitle = p.title
            Task {
                guard let data = try? await URLSession.woodruff.data(from: url).0, let img = NSImage(data: data) else { return }
                var cur = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? d
                cur[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
                MPNowPlayingInfoCenter.default().nowPlayingInfo = cur
            }
        }
    }

    private func key(_ k: String) {
        Task { @MainActor in
            let f = Fleet.shared
            if let tv = f.selected { try? await f.client(for: tv)?.key(k) }
            try? await Task.sleep(nanoseconds: 600_000_000)
            await f.refresh()
        }
    }

    private func media(_ a: String) {
        Task { @MainActor in
            let f = Fleet.shared
            if let tv = f.selected { _ = try? await f.client(for: tv)?.media(a) }
            try? await Task.sleep(nanoseconds: 600_000_000)
            await f.refresh()
        }
    }
}

// MARK: - Desktop widgets

/// Shares the paired TVs with the desktop widgets and refreshes them when something changes.
@MainActor
enum WidgetSync {
    private static var lastKey = ""

    static func update(_ fleet: Fleet) {
        let names = Dictionary(fleet.tvs.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        // Never write an empty list over the backup: it's what restores the pairings if the app's own are lost.
        let hubs = fleet.hubs.isEmpty ? (SharedStore.load()?.hubs ?? [])
            : fleet.hubs.map { SharedStore.HubLink(id: $0.id, name: $0.name, base: $0.connection.base, key: $0.connection.key) }
        let home = SmartHome.shared
        SharedStore.save(.init(hubs: hubs, selectedID: fleet.selectedID, names: names, speakers: home.speakers, lights: home.lights))
        // Reload only when what a widget shows changes (titles, play state, on/off), not every refresh.
        let key = fleet.tvs.map { "\($0.id)|\($0.online)|\($0.playing?.title ?? "")|\($0.playing?.isPlaying ?? false)" }.joined(separator: ";") + "#\(fleet.selectedID ?? "")"
            + home.speakers.map { "\($0.name)|\($0.title ?? "")|\($0.isPlaying)" }.joined() + home.lights.map { "\($0.name)|\($0.on)" }.joined()
        if key != lastKey {
            lastKey = key
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
}

// MARK: - Feedback

/// A soft click for remote keys (Settings → Notifications can turn it off) and trackpad haptics.
@MainActor
enum MacFeedback {
    static var soundOn: Bool { UserDefaults.standard.object(forKey: "remoteClick") as? Bool ?? true }
    private static let click: NSSound? = {
        let s = NSSound(named: NSSound.Name("Tink"))
        s?.volume = 0.18
        return s
    }()

    static func key() {
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        if soundOn, let click { click.stop(); click.play() }
    }

    static func snap() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
}

// MARK: - Welcome

/// The first time the Mac app opens with TVs: three short pages, like Apple's own welcome screens.
struct MacWelcome: View {
    @Environment(\.dismiss) private var dismiss
    @State private var page = 0

    private let pages: [(String, String, String)] = [
        ("tv.and.mediabox", "Every TV, at Home", "Home shows each TV with what it’s playing. Click one for its screen, health and updates."),
        ("appletvremote.gen4", "The Remote, When You Want It", "Click the remote in the toolbar, or press ⌥⌘R. The keyboard drives it too: arrows, Return, Esc, Space."),
        ("rectangle.on.rectangle", "Always Within Reach", "The menu bar and the mini player (⌘⇧M) keep what’s playing in view. Add Woodruff widgets to your desktop, and the media keys play and pause the TV."),
    ]

    var body: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 10)
            Image(systemName: pages[page].0)
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(Color.accentColor)
                .contentTransition(.symbolEffect(.replace))
                .frame(height: 70)
            Text(pages[page].1).font(.title.bold()).multilineTextAlignment(.center)
            Text(pages[page].2).font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
            Spacer(minLength: 10)
            HStack(spacing: 6) {
                ForEach(pages.indices, id: \.self) { i in
                    Circle().fill(i == page ? Color.primary : Color.secondary.opacity(0.35)).frame(width: 6, height: 6)
                }
            }
            Button(page == pages.count - 1 ? "Get Started" : "Continue") {
                if page == pages.count - 1 { UserDefaults.standard.set(true, forKey: "macWelcomeShown"); dismiss() }
                else { withAnimation(.smooth) { page += 1 } }
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
        .padding(36)
        .frame(width: 520, height: 420)
    }
}

// MARK: - Pairing backup

/// The Mac keeps a copy of the pairings in its app group (shared with the widgets): if the app's own copy is
/// ever gone (a new bundle id, a reset), the TVs come back from there instead of having to be paired again.
@MainActor
enum MacPairingBackup {
    static func attach(_ fleet: Fleet) {
        fleet.pairingsChanged = { hubs in
            var snap = SharedStore.load() ?? SharedStore.Snapshot(hubs: [], selectedID: nil, names: [:])
            snap.hubs = hubs.map { .init(id: $0.id, name: $0.name, base: $0.connection.base, key: $0.connection.key) }
            SharedStore.save(snap)
        }
        if let snap = SharedStore.load() {
            fleet.restorePairings(snap.hubs.map { Hub(id: $0.id, name: $0.name, connection: TVConnection(base: $0.base, key: $0.key)) })
        }
    }
}
