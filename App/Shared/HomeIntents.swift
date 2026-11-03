import Foundation
import AppIntents
import WoodruffKit

// Siri, Spotlight and Shortcuts for the speakers and lights: "Turn off Elliot's Lamp with Woodruff",
// "Turn off the Master Bedroom lights with Woodruff", "Pause Master Bedroom on Sonos with Woodruff".

struct LightEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Light"
    static let defaultQuery = LightQuery()
    var id: String
    var name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct LightQuery: EntityStringQuery {
    @MainActor func entities(for identifiers: [String]) async throws -> [LightEntity] { all().filter { identifiers.contains($0.id) } }
    @MainActor func suggestedEntities() async throws -> [LightEntity] { all() }
    @MainActor func entities(matching string: String) async throws -> [LightEntity] {
        all().filter { $0.name.localizedCaseInsensitiveContains(string) }
    }
    @MainActor private func all() -> [LightEntity] { SmartHome.shared.lights.map { LightEntity(id: $0.id, name: $0.name) } }
}

struct SpeakerEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Sonos Room"
    static let defaultQuery = SpeakerQuery()
    var id: String
    var name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct SpeakerQuery: EntityStringQuery {
    @MainActor func entities(for identifiers: [String]) async throws -> [SpeakerEntity] { all().filter { identifiers.contains($0.id) } }
    @MainActor func suggestedEntities() async throws -> [SpeakerEntity] { all() }
    @MainActor func entities(matching string: String) async throws -> [SpeakerEntity] {
        all().filter { $0.name.localizedCaseInsensitiveContains(string) }
    }
    @MainActor private func all() -> [SpeakerEntity] { SmartHome.shared.speakers.map { SpeakerEntity(id: $0.id, name: $0.name) } }
}

/// A room, for "the Master Bedroom lights".
struct RoomEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Room"
    static let defaultQuery = RoomQuery()
    var id: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(id)") }
}

struct RoomQuery: EntityStringQuery {
    @MainActor func entities(for identifiers: [String]) async throws -> [RoomEntity] { identifiers.map { RoomEntity(id: $0) } }
    @MainActor func suggestedEntities() async throws -> [RoomEntity] { all() }
    @MainActor func entities(matching string: String) async throws -> [RoomEntity] {
        all().filter { $0.id.localizedCaseInsensitiveContains(string) }
    }
    @MainActor private func all() -> [RoomEntity] {
        let h = SmartHome.shared
        return Array(Set(h.lights.compactMap { h.room(of: $0.id) })).sorted().map { RoomEntity(id: $0) }
    }
}

enum PowerChoice: String, AppEnum {
    case on, off
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "On or Off"
    static let caseDisplayRepresentations: [PowerChoice: DisplayRepresentation] = [.on: "on", .off: "off"]
}

enum ColorChoice: String, AppEnum {
    case red, orange, yellow, green, teal, blue, indigo, purple, pink, warmWhite, white, daylight
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Colour"
    static let caseDisplayRepresentations: [ColorChoice: DisplayRepresentation] = [
        .red: "red", .orange: "orange", .yellow: "yellow", .green: "green", .teal: "teal", .blue: "blue",
        .indigo: "indigo", .purple: "purple", .pink: "pink", .warmWhite: "warm white", .white: "white", .daylight: "daylight",
    ]
    /// A colour, or a white's temperature.
    var value: (LightColor?, Int?) {
        let c = LightSheet.colors
        switch self {
        case .red: return (c[0], nil)
        case .orange: return (c[1], nil)
        case .yellow: return (c[2], nil)
        case .green: return (c[3], nil)
        case .teal: return (c[4], nil)
        case .blue: return (c[5], nil)
        case .indigo: return (c[6], nil)
        case .purple: return (c[7], nil)
        case .pink: return (c[8], nil)
        case .warmWhite: return (nil, 2700)
        case .white: return (nil, 4000)
        case .daylight: return (nil, 6500)
        }
    }
}

@MainActor private func findLight(_ e: LightEntity) -> GoveeLight? { SmartHome.shared.light(e.id) }
@MainActor private func findSpeaker(_ e: SpeakerEntity?) -> SonosRoom? {
    if let e { return SmartHome.shared.speaker(e.id) }
    return SmartHome.shared.lastSpeaker
}

struct SetLightPowerIntent: AppIntent {
    static let title: LocalizedStringResource = "Turn a Light On or Off"
    static let description = IntentDescription("Turns a Govee light on or off.")
    @Parameter(title: "Light") var light: LightEntity
    @Parameter(title: "On or Off", default: .on) var power: PowerChoice

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let l = findLight(light) else { return .result(dialog: "I can’t find that light.") }
        SmartHome.shared.setOn(l, power == .on)
        try? await Task.sleep(nanoseconds: 300_000_000)
        return .result(dialog: "Turned \(power == .on ? "on" : "off") \(l.name).")
    }
}

struct SetRoomLightsIntent: AppIntent {
    static let title: LocalizedStringResource = "Turn a Room’s Lights On or Off"
    static let description = IntentDescription("Turns every light in a room on or off.")
    @Parameter(title: "Room") var room: RoomEntity
    @Parameter(title: "On or Off", default: .off) var power: PowerChoice

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let h = SmartHome.shared
        let list = h.lights.filter { h.room(of: $0.id) == room.id }
        for l in list { h.setOn(l, power == .on) }
        try? await Task.sleep(nanoseconds: 300_000_000)
        return .result(dialog: list.isEmpty ? "There are no lights in \(room.id)." : "Turned \(power == .on ? "on" : "off") the \(room.id) lights.")
    }
}

struct AllLightsIntent: AppIntent {
    static let title: LocalizedStringResource = "Turn All Lights On or Off"
    @Parameter(title: "On or Off", default: .off) var power: PowerChoice

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        SmartHome.shared.allLights(power == .on)
        try? await Task.sleep(nanoseconds: 300_000_000)
        return .result(dialog: "Turned \(power == .on ? "on" : "off") every light.")
    }
}

struct SetLightColorIntent: AppIntent {
    static let title: LocalizedStringResource = "Set a Light’s Colour"
    @Parameter(title: "Light") var light: LightEntity
    @Parameter(title: "Colour") var color: ColorChoice

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let l = findLight(light) else { return .result(dialog: "I can’t find that light.") }
        let (c, k) = color.value
        if let c { SmartHome.shared.setColor(l, c) } else if let k { SmartHome.shared.setWhite(l, kelvin: k) }
        try? await Task.sleep(nanoseconds: 300_000_000)
        return .result(dialog: "Done.")
    }
}

struct SetLightBrightnessIntent: AppIntent {
    static let title: LocalizedStringResource = "Set a Light’s Brightness"
    @Parameter(title: "Light") var light: LightEntity
    @Parameter(title: "Brightness", inclusiveRange: (1, 100)) var brightness: Int

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let l = findLight(light) else { return .result(dialog: "I can’t find that light.") }
        SmartHome.shared.setBrightness(l, brightness)
        try? await Task.sleep(nanoseconds: 300_000_000)
        return .result(dialog: "\(l.name) is at \(brightness)%.")
    }
}

struct SonosPlayPauseIntent: AppIntent {
    static let title: LocalizedStringResource = "Play or Pause Sonos"
    static let description = IntentDescription("Plays or pauses a Sonos room (the last one used if none is named).")
    @Parameter(title: "Room") var speaker: SpeakerEntity?

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let r0 = findSpeaker(speaker) else { return .result(dialog: "I can’t find a Sonos speaker.") }
        let r = await Sonos.refresh(r0)
        let playing = r.isPlaying
        await SmartHome.shared.sonos(r) { playing ? try await Sonos.pause($0) : try await Sonos.play($0) }
        return .result(dialog: "\(r.isPlaying ? "Paused" : "Playing") \(r.name).")
    }
}

struct SonosVolumeIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Sonos Volume"
    @Parameter(title: "Room") var speaker: SpeakerEntity?
    @Parameter(title: "Volume", inclusiveRange: (0, 100)) var volume: Int

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let r = findSpeaker(speaker) else { return .result(dialog: "I can’t find a Sonos speaker.") }
        try? await Sonos.setVolume(r, volume)
        SmartHome.shared.lastSpeakerID = r.id
        return .result(dialog: "\(r.name) is at \(volume).")
    }
}

struct SonosNextIntent: AppIntent {
    static let title: LocalizedStringResource = "Skip on Sonos"
    @Parameter(title: "Room") var speaker: SpeakerEntity?

    @MainActor func perform() async throws -> some IntentResult {
        if let r = findSpeaker(speaker) { await SmartHome.shared.sonos(r) { try await Sonos.next($0) } }
        return .result()
    }
}

struct SonosWhatsPlayingIntent: AppIntent {
    static let title: LocalizedStringResource = "What’s Playing on Sonos"
    @Parameter(title: "Room") var speaker: SpeakerEntity?

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let r0 = findSpeaker(speaker) else { return .result(dialog: "I can’t find a Sonos speaker.") }
        let r = await Sonos.refresh(r0)
        guard let t = r.title, !t.isEmpty else { return .result(dialog: "Nothing is playing in \(r.name).") }
        return .result(dialog: "\(t)\(r.artist.map { " by \($0)" } ?? "") in \(r.name)\(r.isPlaying ? "" : ", paused").")
    }
}
