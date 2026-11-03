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
    if fleet.refreshedAt == nil { await fleet.refresh() }
    if let tv { return fleet.tvs.filter { $0.id == tv.id } }
    return fleet.tvs.filter { $0.online && !$0.isUnpaired }
}

struct PauseTVsIntent: AppIntent {
    static let title: LocalizedStringResource = "Play or Pause a TV"
    static let description = IntentDescription("Plays or pauses a TV, or every TV that’s playing.")
    @Parameter(title: "TV") var tv: TVEntity?

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let fleet = Fleet.shared
        var list = await tvsForIntent(tv)
        if tv == nil { list = list.filter { $0.playing?.isPlaying == true } }
        for t in list { try? await fleet.client(for: t)?.key("playpause") }
        let names = list.map(\.name)
        return .result(dialog: names.isEmpty ? "Nothing is playing." : "Done on \(names.joined(separator: ", ")).")
    }
}

struct MuteTVsIntent: AppIntent {
    static let title: LocalizedStringResource = "Mute a TV"
    static let description = IntentDescription("Mutes or unmutes a TV, or every TV that’s on.")
    @Parameter(title: "TV") var tv: TVEntity?

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let fleet = Fleet.shared
        let list = await tvsForIntent(tv)
        for t in list {
            if let lg = fleet.lg(for: t), let v = try? await lg.volume() { try? await lg.setMute(!v.muted) }
            else { try? await fleet.client(for: t)?.key("mute") }
        }
        return .result(dialog: list.isEmpty ? "No TVs are on." : "Muted \(list.map(\.name).joined(separator: ", ")).")
    }
}

struct WhatsPlayingIntent: AppIntent {
    static let title: LocalizedStringResource = "What’s Playing"
    static let description = IntentDescription("Says what a TV, or every TV, is playing.")
    @Parameter(title: "TV") var tv: TVEntity?

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let list = await tvsForIntent(tv)
        let lines = list.compactMap { t -> String? in
            guard let p = t.playing else { return tv == nil ? nil : "Nothing is playing on \(t.name)." }
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
        AppShortcut(intent: OpenWoodruffRemoteIntent(), phrases: [
            "Open the \(.applicationName) remote",
            "Open the \(.applicationName) remote for \(\.$tv)",
        ], shortTitle: "Remote", systemImageName: "appletvremote.gen4.fill")
    }
}
