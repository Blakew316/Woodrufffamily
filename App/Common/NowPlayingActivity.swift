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

/// The actions behind the Lock Screen, Dynamic Island and Control Center buttons, done in the app.
enum TVIntentActions {
    @MainActor static func target() async -> (Fleet, FleetTV)? {
        let fleet = Fleet.shared
        if fleet.selected == nil || fleet.refreshedAt == nil { await fleet.refresh() }
        guard let tv = fleet.selected else { return nil }
        return (fleet, tv)
    }

    @MainActor static func key(_ key: String) async {
        guard let (fleet, tv) = await target() else { return }
        if let lg = fleet.lg(for: tv) {
            switch key {
            case "mute": if let v = try? await lg.volume() { try? await lg.setMute(!v.muted) }
            default: try? await fleet.client(for: tv)?.key(key)
            }
        } else {
            try? await fleet.client(for: tv)?.key(key)
        }
        try? await Task.sleep(nanoseconds: 600_000_000)
        await fleet.refresh()
    }

    @MainActor static func media(_ action: String) async {
        guard let (fleet, tv) = await target() else { return }
        _ = try? await fleet.client(for: tv)?.media(action)
        try? await Task.sleep(nanoseconds: 600_000_000)
        await fleet.refresh()
    }
}

struct PlayPauseTVIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Play or Pause the TV"
    static let description = IntentDescription("Plays or pauses what the remote’s TV is playing.")
    func perform() async throws -> some IntentResult {
        await TVIntentActions.key("playpause")
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

// MARK: - Speakers and lights (Control Center)

struct LightsOffControlIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Turn Off the Lights"
    @MainActor func perform() async throws -> some IntentResult {
        SmartHome.shared.allLights(false)
        try? await Task.sleep(nanoseconds: 400_000_000)
        return .result()
    }
}

struct LightsOnControlIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Turn On the Lights"
    @MainActor func perform() async throws -> some IntentResult {
        SmartHome.shared.allLights(true)
        try? await Task.sleep(nanoseconds: 400_000_000)
        return .result()
    }
}

struct SonosPlayPauseControlIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Play or Pause Sonos"
    @MainActor func perform() async throws -> some IntentResult {
        guard let r0 = SmartHome.shared.lastSpeaker else { return .result() }
        let r = await Sonos.refresh(r0)
        let playing = r.isPlaying
        await SmartHome.shared.sonos(r) { playing ? try await Sonos.pause($0) : try await Sonos.play($0) }
        return .result()
    }
}

struct SonosVolumeControlIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Sonos Volume"
    @Parameter(title: "Up") var up: Bool
    init() {}
    init(up: Bool) { self.up = up }
    @MainActor func perform() async throws -> some IntentResult {
        guard let r0 = SmartHome.shared.lastSpeaker else { return .result() }
        let r = await Sonos.refresh(r0)
        try? await Sonos.setVolume(r, r.volume + (up ? 5 : -5))
        return .result()
    }
}
