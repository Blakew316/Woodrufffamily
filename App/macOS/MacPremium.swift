import SwiftUI
import AppKit
import MediaPlayer
import WidgetKit
import WoodruffKit

// MARK: - Ambient artwork

/// The window takes on a soft blur of what the remote's TV is playing now, like Music's full-screen player.
struct AmbientArtwork: View {
    @Environment(Fleet.self) private var fleet
    var body: some View {
        let p = fleet.selected?.nowPlaying
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
        // What's on now only: once it's stopped, off or left paused, no picture and no old title.
        let p = tv?.nowPlaying
        HStack(spacing: 14) {
            Group {
                if let p { NowPlayingArt(playing: p) } else { Color.secondary.opacity(0.18) }
            }
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
        .frame(minWidth: 320, idealWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
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
    /// The title whose poster was asked for last, and that poster once it has loaded: every update puts it back, since
    /// each one replaces all of Control Center's Now Playing.
    private var lastTitle: String?
    private var art: (title: String, artwork: MPMediaItemArtwork)?
    /// What Control Center was last given (nil: nothing yet), and where the title was then: it's given again only when
    /// that changes, or the title has got more than 2 seconds away from where Control Center's own clock has it.
    /// (Every update replaced it all before, several times a minute while anything played.)
    private var shown: Shown?
    private var shownElapsed: TimeInterval = 0
    private var shownAt = Date.distantPast
    private var shownPlaying = false

    private enum Shown: Equatable {
        case nothing
        case idle(tv: String, name: String)
        case title(tv: String, name: String, title: String, app: String?, playing: Bool, duration: Double?)
    }

    func wire() {
        guard !wired else { return }
        wired = true
        let c = MPRemoteCommandCenter.shared()
        // None of macOS's play and pause reach the TV: macOS sends them by itself (an app starting the microphone
        // on this Mac or, through AirPods and Handoff, on the iPhone), and they paused the TV with no one pressing
        // anything. The TV is played and paused from Woodruff's own controls.
        c.togglePlayPauseCommand.isEnabled = false
        c.playCommand.isEnabled = false
        c.pauseCommand.isEnabled = false
        c.skipBackwardCommand.preferredIntervals = [10]
        c.skipForwardCommand.preferredIntervals = [30]
        c.skipBackwardCommand.addTarget { _ in self.media("back10"); return .success }
        c.skipForwardCommand.addTarget { _ in self.media("fwd30"); return .success }
        c.nextTrackCommand.addTarget { _ in self.media("next"); return .success }
    }

    func update(_ fleet: Fleet) {
        wire()
        let info = MPNowPlayingInfoCenter.default()
        // Only what's playing now: a TV that's off, or has nothing playing, clears Control Center.
        guard let tv = fleet.selected, tv.online, !tv.isUnpaired, tv.playing != nil else {
            if shown != .nothing {
                info.nowPlayingInfo = nil
                info.playbackState = .stopped
                shown = .nothing
            }
            lastTitle = nil
            art = nil
            return
        }
        guard let p = tv.nowPlaying else {
            // Left paused so long it no longer counts as playing: no old title or picture, only the TV, paused, so the
            // Mac's play/pause key still reaches it (with nothing here, macOS hands that key to Music instead).
            let idle = Shown.idle(tv: tv.id, name: tv.name)
            if shown != idle {
                let d: [String: Any] = [MPMediaItemPropertyTitle: tv.name, MPNowPlayingInfoPropertyPlaybackRate: 0.0]
                info.nowPlayingInfo = d
                info.playbackState = .paused
                shown = idle
            }
            lastTitle = nil
            art = nil
            return
        }
        let now = Date()
        let elapsed = p.estimatedPosition(at: now) / 1000
        let next = Shown.title(tv: tv.id, name: tv.name, title: p.title, app: p.app, playing: p.isPlaying, duration: p.duration)
        // Where Control Center has it by now (its clock runs on by itself while it plays).
        let expected = shownElapsed + (shownPlaying ? now.timeIntervalSince(shownAt) : 0)
        if next != shown || abs(elapsed - expected) > 2 {
            var d: [String: Any] = [
                MPMediaItemPropertyTitle: p.title,
                MPMediaItemPropertyArtist: tv.name,
                MPMediaItemPropertyAlbumTitle: p.app ?? "Woodruff Family",
                MPNowPlayingInfoPropertyPlaybackRate: p.isPlaying ? 1.0 : 0.0,
                MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            ]
            if let dur = p.duration, dur > 0 { d[MPMediaItemPropertyPlaybackDuration] = dur / 1000 }
            // The poster stays: each write replaces everything.
            if let art, art.title == p.title { d[MPMediaItemPropertyArtwork] = art.artwork }
            info.nowPlayingInfo = d
            info.playbackState = p.isPlaying ? .playing : .paused
            shown = next
            shownElapsed = elapsed
            shownAt = now
            shownPlaying = p.isPlaying
        }
        if lastTitle != p.title, let path = fleet.artwork(for: p)?.poster, let url = fleet.hubClient()?.art(path, small: true) {
            lastTitle = p.title
            let title = p.title
            Task {
                // The small poster, through the app's picture cache (decoded off the main thread, kept for next time).
                guard let img = await ImageStore.shared.image(url, maxPixel: 600) else { return }
                // Still that title (not cleared, nor moved on, while the poster loaded): kept for every update after.
                guard self.lastTitle == title else { return }
                let artwork = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
                self.art = (title, artwork)
                guard var cur = MPNowPlayingInfoCenter.default().nowPlayingInfo,
                      cur[MPMediaItemPropertyTitle] as? String == title else { return }
                cur[MPMediaItemPropertyArtwork] = artwork
                // Where Control Center's own clock has the title by now: what `cur` holds is from the last full write,
                // and giving it again would set the clock back by however long the poster took to load.
                cur[MPNowPlayingInfoPropertyElapsedPlaybackTime] = self.shownElapsed + (self.shownPlaying ? Date().timeIntervalSince(self.shownAt) : 0)
                MPNowPlayingInfoCenter.default().nowPlayingInfo = cur
            }
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
    /// What the snapshot was last saved from (`snapshotKey(_:_:)`).
    private static var savedKey: Int?
    /// The save waiting to go: changes within a second of each other go as one.
    private static var pending: Task<Void, Never>?

    /// Called for every change to the TVs, the remote's TV, the speakers and the lights: saved a second after the first
    /// of a burst (as things are then), and only when something the widgets use changed.
    static func update(_ fleet: Fleet) {
        guard pending == nil else { return }
        pending = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            WidgetSync.pending = nil
            WidgetSync.write(fleet)
        }
    }

    /// Everything the snapshot holds that a widget uses, hashed: the pairings (each hub's id, name, address and key, so
    /// the pairing backup is saved whenever they change), the remote's TV, every TV's name, state and what it plays, and
    /// the speakers and lights. Where a title has got to counts only by the minute: it moves all the time, and the
    /// widgets ask the TVs for it themselves.
    private static func snapshotKey(_ fleet: Fleet, _ home: SmartHome) -> Int {
        var h = Hasher()
        for hub in fleet.hubs {
            h.combine(hub.id)
            h.combine(hub.name)
            h.combine(hub.connection.base)
            h.combine(hub.connection.key)
        }
        h.combine(fleet.selectedID)
        for t in fleet.tvs {
            h.combine(t.id)
            h.combine(t.name)
            h.combine(t.link)
            h.combine(t.online)
            h.combine(t.hubID)
            h.combine(t.routeID)
            let p = t.nowPlaying
            h.combine(p?.title)
            h.combine(p?.subtitle)
            h.combine(p?.app)
            h.combine(p?.key)
            h.combine(p?.isPlaying)
            h.combine(p?.duration)
            h.combine(p.map { (($0.position ?? 0) / 60_000).rounded(.down) })
        }
        h.combine(home.speakers)
        h.combine(home.lights)
        return h.finalize()
    }

    private static func write(_ fleet: Fleet) {
        let home = SmartHome.shared
        let saving = snapshotKey(fleet, home)
        if saving != savedKey {
            savedKey = saving
            save(fleet, home)
        }
        // Reload only when what a widget shows changes (titles, play state, on/off), not every refresh.
        let key = fleet.tvs.map { "\($0.id)|\($0.name)|\($0.link)|\($0.online)|\($0.nowPlaying?.title ?? "")|\($0.nowPlaying?.isPlaying ?? false)" }.joined(separator: ";") + "#\(fleet.selectedID ?? "")"
            + home.speakers.map { "\($0.name)|\($0.title ?? "")|\($0.isPlaying)" }.joined() + home.lights.map { "\($0.name)|\($0.on)" }.joined()
        if key != lastKey {
            lastKey = key
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    private static func save(_ fleet: Fleet, _ home: SmartHome) {
        let names = Dictionary(fleet.tvs.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        // Never write an empty list over the backup: it's what restores the pairings if the app's own are lost.
        let hubs = fleet.hubs.isEmpty ? (SharedStore.load()?.hubs ?? [])
            : fleet.hubs.map { SharedStore.HubLink(id: $0.id, name: $0.name, base: $0.connection.base, key: $0.connection.key) }
        // What each TV plays now (nothing for one that's off or left paused), so a widget drawn from this never shows
        // an old title.
        let tvs = fleet.tvs.filter { !$0.isUnpaired }.map {
            SharedStore.TVInfo(id: $0.id, name: $0.name, online: $0.online, playing: $0.nowPlaying, hubID: $0.hubID, routeID: $0.routeID)
        }
        SharedStore.save(.init(hubs: hubs, selectedID: fleet.selectedID, names: names, speakers: home.speakers, lights: home.lights, tvs: tvs))
    }
}

// MARK: - Feedback

/// A soft click for remote keys (Settings → General can turn it off) and trackpad haptics.
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
