import Foundation
import AppIntents
import WoodruffKit

// Siri, Spotlight, Shortcuts and the Action button: "Pause Master Bedroom", "Mute all TVs",
// "What's playing in the Living Room?". They run in the app, which holds the TVs' pairing keys.

/// A TV, as Siri and Shortcuts see it.
struct TVEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "TV"
    static let defaultQuery = TVQuery()
    var id: String
    var name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct TVQuery: EntityQuery {
    @MainActor func entities(for identifiers: [String]) async throws -> [TVEntity] {
        await ready().filter { identifiers.contains($0.id) }
    }
    @MainActor func suggestedEntities() async throws -> [TVEntity] { await ready() }

    @MainActor private func ready() async -> [TVEntity] {
        let fleet = Fleet.shared
        if fleet.refreshedAt == nil { await fleet.refresh() }
        return fleet.tvs.filter { !$0.isUnpaired }.map { TVEntity(id: $0.id, name: $0.name) }
    }
}

@MainActor
private func tvsForIntent(_ tv: TVEntity?) async -> [FleetTV] {
    let fleet = Fleet.shared
    // Siri can wake the app after it sat in the background for a while: ask the TVs again unless the last
    // answer is from just now, so "what's playing" and "pause the TVs" go by what the TVs are doing now.
    let fresh = fleet.refreshedAt.map { Date().timeIntervalSince($0) < 3 } ?? false
    if !fresh { await fleet.refresh() }
    if let tv { return fleet.tvs.filter { $0.id == tv.id } }
    return fleet.tvs.filter { $0.online && !$0.isUnpaired }
}

/// [op] on every TV in [list] at once (one that's off takes its whole timeout, which shouldn't hold up the
/// others, or Siri): the names it worked on, and the ones it didn't, in [list]'s order.
@MainActor
private func onEach(_ list: [FleetTV], _ op: @escaping @Sendable @MainActor (FleetTV) async throws -> Void) async -> (done: [String], failed: [String]) {
    let worked: [Bool] = await withTaskGroup(of: (Int, Bool).self) { group in
        for (i, t) in list.enumerated() {
            group.addTask { @MainActor in
                do { try await op(t); return (i, true) } catch { return (i, false) }
            }
        }
        var out = Array(repeating: false, count: list.count)
        for await (i, ok) in group { out[i] = ok }
        return out
    }
    var done: [String] = [], failed: [String] = []
    for (i, t) in list.enumerated() { if worked[i] { done.append(t.name) } else { failed.append(t.name) } }
    return (done, failed)
}

/// What Siri says after acting on some TVs: where it worked, and where it didn't (never "done" for a TV that
/// didn't get it).
private func outcome(_ verb: String, done: [String], failed: [String], none: String) -> String {
    if done.isEmpty && failed.isEmpty { return none }
    var parts: [String] = []
    if !done.isEmpty { parts.append("\(verb) \(done.joined(separator: ", ")).") }
    if !failed.isEmpty { parts.append("Couldn’t reach \(failed.joined(separator: ", ")).") }
    return parts.joined(separator: " ")
}

struct PauseTVsIntent: AppIntent {
    static let title: LocalizedStringResource = "Play or Pause a TV"
    static let description = IntentDescription("Plays or pauses a TV, or every TV that’s playing.")
    @Parameter(title: "TV") var tv: TVEntity?

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let fleet = Fleet.shared
        var list = await tvsForIntent(tv)
        if tv == nil { list = list.filter { $0.playing?.isPlaying == true } }
        let (done, failed) = await onEach(list) { t in
            guard let c = fleet.client(for: t) else { throw TVError.notPaired }
            try await c.key("playpause")
        }
        let said = outcome("Done on", done: done, failed: failed, none: "Nothing is playing.")
        return .result(dialog: "\(said)")
    }
}

struct MuteTVsIntent: AppIntent {
    static let title: LocalizedStringResource = "Mute a TV"
    static let description = IntentDescription("Mutes or unmutes a TV, or every TV that’s on.")
    @Parameter(title: "TV") var tv: TVEntity?

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let fleet = Fleet.shared
        let list = await tvsForIntent(tv)
        let (done, failed) = await onEach(list) { t in
            if let lg = fleet.lg(for: t), let v = try? await lg.volume() {
                try await lg.setMute(!v.muted)
            } else {
                guard let c = fleet.client(for: t) else { throw TVError.notPaired }
                try await c.key("mute")
            }
        }
        let said = outcome("Muted", done: done, failed: failed, none: "No TVs are on.")
        return .result(dialog: "\(said)")
    }
}

struct WhatsPlayingIntent: AppIntent {
    static let title: LocalizedStringResource = "What’s Playing"
    static let description = IntentDescription("Says what a TV, or every TV, is playing.")
    @Parameter(title: "TV") var tv: TVEntity?

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let list = await tvsForIntent(tv)
        let lines = list.compactMap { t -> String? in
            // What's playing now: a title left paused for a while is nothing playing, as everywhere else in the app.
            guard let p = t.nowPlaying else { return tv == nil ? nil : "Nothing is playing on \(t.name)." }
            return "\(t.name): \(p.title)\(p.isPlaying ? "" : " (paused)")"
        }
        return .result(dialog: "\(lines.isEmpty ? "Nothing is playing." : lines.joined(separator: ". "))")
    }
}

struct OpenWoodruffRemoteIntent: AppIntent {
    static let title: LocalizedStringResource = "Open the Remote"
    static let openAppWhenRun: Bool = true
    @Parameter(title: "TV") var tv: TVEntity?

    @MainActor func perform() async throws -> some IntentResult {
        if let tv { Fleet.shared.remoteAll = false; Fleet.shared.selectedID = tv.id }
        #if os(macOS)
        Fleet.shared.remotePanel = true
        #else
        UserDefaults.standard.set("remote", forKey: "section")
        #endif
        return .result()
    }
}

/// The phrases Siri and Spotlight offer without any setup.
struct WoodruffShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: RunSceneIntent(), phrases: [
            "\(\.$scene) with \(.applicationName)",
            "Run \(\.$scene) in \(.applicationName)",
            "Start \(\.$scene) with \(.applicationName)",
        ], shortTitle: "Run Scene", systemImageName: "sparkles")
        AppShortcut(intent: PlayOnTVIntent(), phrases: [
            "Play something on \(\.$tv) with \(.applicationName)",
            "Play on \(\.$tv) in \(.applicationName)",
        ], shortTitle: "Play on TV", systemImageName: "play.tv")
        AppShortcut(intent: TurnOffTVsIntent(), phrases: [
            "Turn off \(\.$tv) with \(.applicationName)",
            "Turn off the TVs with \(.applicationName)",
        ], shortTitle: "Turn Off TV", systemImageName: "power")
        AppShortcut(intent: PauseTVsIntent(), phrases: [
            "Pause \(\.$tv) with \(.applicationName)",
            "Play or pause \(\.$tv) in \(.applicationName)",
            "Pause the TVs with \(.applicationName)",
        ], shortTitle: "Play/Pause", systemImageName: "playpause.fill")
        AppShortcut(intent: MuteTVsIntent(), phrases: [
            "Mute \(\.$tv) with \(.applicationName)",
            "Mute the TVs with \(.applicationName)",
        ], shortTitle: "Mute", systemImageName: "speaker.slash.fill")
        AppShortcut(intent: WhatsPlayingIntent(), phrases: [
            "What’s playing on \(\.$tv) in \(.applicationName)",
            "What’s playing in \(.applicationName)",
        ], shortTitle: "What’s Playing", systemImageName: "tv")
        // One phrase set for on and off (Siri allows 10 sets per app).
        AppShortcut(intent: SetLightPowerIntent(), phrases: [
            // One parameter per phrase: Siri asks on or off.
            "Switch \(\.$light) with \(.applicationName)",
            "Turn on or off \(\.$light) in \(.applicationName)",
        ], shortTitle: "Light On or Off", systemImageName: "lightbulb.fill")
        AppShortcut(intent: SetRoomLightsIntent(), phrases: [
            "Turn off the \(\.$room) lights with \(.applicationName)",
            "Turn the \(\.$room) lights off in \(.applicationName)",
        ], shortTitle: "Room Lights Off", systemImageName: "lightbulb.2")
        AppShortcut(intent: AllLightsIntent(), phrases: [
            "Turn \(\.$power) all the lights with \(.applicationName)",
            "Turn all the lights \(\.$power) in \(.applicationName)",
        ], shortTitle: "All Lights", systemImageName: "lightbulb.slash")
        AppShortcut(intent: SonosPlayPauseIntent(), phrases: [
            "Pause \(\.$speaker) on Sonos with \(.applicationName)",
            "Play or pause Sonos with \(.applicationName)",
            "Pause the Sonos with \(.applicationName)",
        ], shortTitle: "Sonos Play/Pause", systemImageName: "hifispeaker.fill")
    }
}
