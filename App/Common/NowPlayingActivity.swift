import Foundation
import ActivityKit
import AppIntents
import WoodruffKit

// Shared by the app and the widgets extension: what the Lock Screen / Dynamic Island shows, and the buttons
// on it. The buttons are LiveActivityIntents, so they run in the app (which holds the TVs' pairing keys).

/// The Live Activity for what the remote's TV is playing.
struct NowPlayingAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var title: String
        var detail: String
        var tvName: String
        var isPlaying: Bool
        /// When the title started (now − position), for a progress bar that moves by itself.
        var startedAt: Date?
        /// When it will end (startedAt + duration).
        var endsAt: Date?
        /// How far through (0…1), for a paused title.
        var fraction: Double
        var canSkip: Bool
    }
    var tvID: String
}

extension NowPlayingAttributes.ContentState {
    /// What the Lock Screen shows for [p] on [tv]: when it started, worked out from where the TV is right now
    /// (its last answer plus the time since), so the bar runs by itself and lines up with the app's.
    init(tv: FleetTV, playing p: NowPlaying, now: Date = Date()) {
        let pos = p.estimatedPosition(at: now) / 1000
        let dur = (p.duration ?? 0) / 1000
        let started: Date? = dur > 0 ? now.addingTimeInterval(-pos) : nil
        self.init(title: p.title,
                  detail: [p.subtitle, p.app].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · "),
                  tvName: tv.name, isPlaying: p.isPlaying,
                  startedAt: started, endsAt: started.map { $0.addingTimeInterval(dur) },
                  fraction: dur > 0 ? min(1, max(0, pos / dur)) : 0,
                  canSkip: p.can("back10") || p.can("fwd30"))
    }

    /// When it goes stale: a playing title once it has ended; a paused one 5 minutes after the pause reached it (by then
    /// it no longer counts as playing, and the app ends it the next time it runs).
    var staleDate: Date? { isPlaying ? endsAt : Date().addingTimeInterval(300) }
}

/// The actions behind the Lock Screen, Dynamic Island and Control Center buttons, done in the app.
enum TVIntentActions {
    @MainActor static func target() async -> (Fleet, FleetTV)? {
        let fleet = Fleet.shared
        // The app may have been asleep in the background: go by what the TV is doing now.
        let fresh = fleet.refreshedAt.map { Date().timeIntervalSince($0) < 3 } ?? false
        if fleet.selected == nil || !fresh { await fleet.refresh() }
        guard let tv = fleet.selected else { return nil }
        return (fleet, tv)
    }

    @MainActor static func key(_ key: String) async {
        // Volume and mute go straight to the TV the remote is on (no refreshing every TV first), and are given up
        // on after 2 seconds: a Control Center button stays lit until this returns.
        if key != "playpause", let tv = Fleet.shared.selected {
            let fleet = Fleet.shared
            await within(2) {
                if key == "mute", let lg = fleet.lg(for: tv) {
                    if let v = try? await lg.volume() { try? await lg.setMute(!v.muted) }
                } else {
                    try? await fleet.client(for: tv)?.key(key)
                }
            }
            return
        }
        guard let found = await target() else { return }
        let fleet = found.0
        let tv = found.1
        let was = tv.playing
        if key == "mute", let lg = fleet.lg(for: tv) {
            if let v = try? await lg.volume() { try? await lg.setMute(!v.muted) }
        } else {
            try? await fleet.client(for: tv)?.key(key)
        }
        // Volume changes nothing on the Lock Screen; play/pause does, as soon as the TV has made it.
        guard key == "playpause" else { return }
        await settle(fleet, tv.id) { $0?.isPlaying != was?.isPlaying || $0?.title != was?.title }
    }

    /// Runs [work], returning after [seconds] at most (the work carries on by itself).
    @MainActor static func within(_ seconds: Double, _ work: @escaping @MainActor () async -> Void) async {
        final class Once { var done = false }
        let once = Once()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            Task { @MainActor in
                await work()
                if !once.done { once.done = true; c.resume() }
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                if !once.done { once.done = true; c.resume() }
            }
        }
    }

    @MainActor static func media(_ action: String) async {
        guard let found = await target() else { return }
        let fleet = found.0
        let tv = found.1
        let was = tv.playing
        _ = try? await fleet.client(for: tv)?.media(action)
        await settle(fleet, tv.id) { $0?.position != was?.position || $0?.title != was?.title }
    }

    /// Asks the TV again until [changed] says the change shows (or about 3 seconds pass), then brings the Live
    /// Activity up to date before returning: these buttons run while the app is in the background, where its
    /// views (which otherwise keep the Live Activity in step) don't update, and it may sleep again right after.
    @MainActor static func settle(_ fleet: Fleet, _ tvID: String, until changed: (NowPlaying?) -> Bool) async {
        let waits: [UInt64] = [400_000_000, 800_000_000, 1_600_000_000]
        for wait in waits {
            try? await Task.sleep(nanoseconds: wait)
            await fleet.refresh()
            if changed(fleet.tv(tvID)?.playing) { break }
        }
        if let update = updateActivity { await update(fleet) }
    }

    /// Brings the Live Activity up to date with the fleet and waits until it has it. Set by the app
    /// (`LiveActivitySync`); the widgets extension compiles this file too and never touches the Live Activity.
    @MainActor static var updateActivity: ((Fleet) async -> Void)?
}

struct PlayPauseTVIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Play or Pause the TV"
    static let description = IntentDescription("Plays or pauses what the remote’s TV is playing.")
    func perform() async throws -> some IntentResult {
        await TVIntentActions.key("playpause")
        return .result()
    }
}

/// Play or pause one TV (the Now Playing widget's buttons, one per TV).
struct PlayPauseTVOnIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Play or Pause a TV"
    static var isDiscoverable: Bool { false }
    @Parameter(title: "TV") var tvID: String

    init() {}
    init(tvID: String) { self.tvID = tvID }

    @MainActor func perform() async throws -> some IntentResult {
        let fleet = Fleet.shared
        if fleet.tv(tvID) == nil || !(fleet.refreshedAt.map { Date().timeIntervalSince($0) < 3 } ?? false) { await fleet.refresh() }
        guard let tv = fleet.tv(tvID) else { return .result() }
        let was = tv.playing
        try? await fleet.client(for: tv)?.key("playpause")
        // settle brings the Live Activity and the widgets up to date.
        await TVIntentActions.settle(fleet, tv.id) { $0?.isPlaying != was?.isPlaying || $0?.title != was?.title }
        return .result()
    }
}

struct SkipBackTVIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Back 10 Seconds"
    func perform() async throws -> some IntentResult {
        await TVIntentActions.media("back10")
        return .result()
    }
}

struct SkipForwardTVIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Forward 30 Seconds"
    func perform() async throws -> some IntentResult {
        await TVIntentActions.media("fwd30")
        return .result()
    }
}

struct VolumeUpTVIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Turn the TV Up"
    func perform() async throws -> some IntentResult {
        await TVIntentActions.key("volup")
        return .result()
    }
}

struct VolumeDownTVIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Turn the TV Down"
    func perform() async throws -> some IntentResult {
        await TVIntentActions.key("voldown")
        return .result()
    }
}

struct MuteTVIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Mute the TV"
    static let description = IntentDescription("Mutes or unmutes the remote’s TV.")
    func perform() async throws -> some IntentResult {
        await TVIntentActions.key("mute")
        return .result()
    }
}

/// Opens Woodruff on the remote.
struct OpenRemoteIntent: AppIntent {
    static let title: LocalizedStringResource = "Open the Woodruff Remote"
    static let openAppWhenRun: Bool = true
    @MainActor func perform() async throws -> some IntentResult {
        UserDefaults.standard.set("remote", forKey: "section")
        return .result()
    }
}

struct OpenHomeIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Woodruff"
    static let openAppWhenRun: Bool = true
    @MainActor func perform() async throws -> some IntentResult {
        UserDefaults.standard.set("home", forKey: "section")
        return .result()
    }
}

/// The same, for the Lock Screen's Woodruff button, which is a switch that's always on (iOS draws a control in its
/// own colour only while it's on): whichever way it's flipped, it opens Woodruff to Home.
struct OpenHomeSwitchIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Open Woodruff"
    static let openAppWhenRun: Bool = true
    @Parameter(title: "On") var value: Bool
    @MainActor func perform() async throws -> some IntentResult {
        UserDefaults.standard.set("home", forKey: "section")
        return .result()
    }
}

// MARK: - Speakers and lights (Control Center)

struct LightsOffControlIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Turn Off the Lights"
    @MainActor func perform() async throws -> some IntentResult {
        if let run = ControlHook.lights { await TVIntentActions.within(3) { await run(false) } } else { SmartHome.shared.allLights(false) }
        return .result()
    }
}

struct LightsOnControlIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Turn On the Lights"
    @MainActor func perform() async throws -> some IntentResult {
        if let run = ControlHook.lights { await TVIntentActions.within(3) { await run(true) } } else { SmartHome.shared.allLights(true) }
        return .result()
    }
}

struct SonosPlayPauseControlIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Play or Pause Sonos"
    @MainActor func perform() async throws -> some IntentResult {
        // Launched cold by the control: find the speakers first.
        if SmartHome.shared.speakers.isEmpty { await SmartHome.shared.findSonos() }
        guard let r0 = SmartHome.shared.lastSpeaker else { return .result() }
        let r = await Sonos.refresh(r0)
        let playing = r.isPlaying
        await SmartHome.shared.sonos(r, expect: playing ? "PAUSED_PLAYBACK" : "PLAYING") { room in
            if playing { try await Sonos.pause(room) } else { try await Sonos.play(room) }
        }
        return .result()
    }
}

struct SonosVolumeControlIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Sonos Volume"
    // Only for the controls (Shortcuts has Set Sonos Volume).
    static var isDiscoverable: Bool { false }
    @Parameter(title: "Up") var up: Bool
    init() {}
    init(up: Bool) { self.up = up }
    @MainActor func perform() async throws -> some IntentResult {
        if let run = ControlHook.sonosVolume {
            let up = up
            await TVIntentActions.within(2) { await run(up) }
            return .result()
        }
        if SmartHome.shared.speakers.isEmpty { await SmartHome.shared.findSonos() }
        guard let r0 = SmartHome.shared.lastSpeaker else { return .result() }
        let r = await Sonos.refresh(r0)
        try? await Sonos.setVolume(r, max(0, min(100, r.volume + (up ? 5 : -5))))
        await SmartHome.shared.refreshSpeakers()
        return .result()
    }
}

// MARK: - Scenes from Control Center

/// Runs a scene in the app (set by the app as it starts): a control's LiveActivityIntent runs in the app's process,
/// where the scenes, the TVs' keys and the lights are.
/// What the Control Center buttons for the lights and Sonos do, set by the app (the same work Siri's do: they find
/// the lights and speakers first when the button has just started Woodruff, and reach Apple Home's lights too).
enum ControlHook {
    @MainActor static var lights: ((Bool) async -> Void)?
    @MainActor static var sonosVolume: ((Bool) async -> Void)?
}

enum SceneHook {
    @MainActor static var run: ((String) async -> Void)?
}

struct RunSceneControlIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Run a Scene"
    // Only for the controls and widget buttons: it takes a scene's id, and Shortcuts has Run Scene by name.
    static var isDiscoverable: Bool { false }
    @Parameter(title: "Scene") var sceneID: String

    init() {}
    init(sceneID: String) { self.sceneID = sceneID }

    @MainActor func perform() async throws -> some IntentResult {
        await SceneHook.run?(sceneID)
        return .result()
    }
}
