import Foundation
import AppIntents
import Observation
import WoodruffKit

// Siri, Spotlight and Shortcuts for the speakers and lights: "Turn off Elliot's Lamp with Woodruff",
// "Turn off the Master Bedroom lights with Woodruff", "Pause Master Bedroom on Sonos with Woodruff".
// Siri may start Woodruff just for one of these, with nothing running yet: each starts what it needs, and says
// what really happened (never "done" for a light that didn't change).

/// A name as Siri hears it and as it's written here, made comparable: case, accents, spaces and curly or straight
/// apostrophes don't matter ("elliots lamp" finds “Elliot’s Lamp”).
private func spokenKey(_ s: String) -> String {
    s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        .filter { $0.isLetter || $0.isNumber }
}

/// Whether [name] is what [query] asks for: the whole name, or part of it.
private func matches(_ name: String, _ query: String) -> Bool {
    let n = spokenKey(name), q = spokenKey(query)
    guard !q.isEmpty else { return true }
    guard !n.isEmpty else { return false }
    return n.contains(q) || q.contains(n)
}

struct LightEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Light"
    static let defaultQuery = LightQuery()
    var id: String
    var name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct LightQuery: EntityStringQuery {
    @MainActor func entities(for identifiers: [String]) async throws -> [LightEntity] { all().filter { identifiers.contains($0.id) } }
    @MainActor func suggestedEntities() async throws -> [LightEntity] {
        SiriVocabulary.start()
        return all()
    }
    @MainActor func entities(matching string: String) async throws -> [LightEntity] {
        all().filter { matches($0.name, string) }
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
    @MainActor func suggestedEntities() async throws -> [SpeakerEntity] {
        SiriVocabulary.start()
        return all()
    }
    @MainActor func entities(matching string: String) async throws -> [SpeakerEntity] {
        all().filter { matches($0.name, string) }
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
    @MainActor func suggestedEntities() async throws -> [RoomEntity] {
        SiriVocabulary.start()
        return all()
    }
    @MainActor func entities(matching string: String) async throws -> [RoomEntity] {
        all().filter { matches($0.id, string) }
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
    /// What Siri says it is.
    var words: String { self == .warmWhite ? "warm white" : rawValue }
}

// MARK: - Carrying out a change, honestly

/// Starts the lights and speakers (and Apple Home on iPhone), in case Siri started Woodruff just for this: a change
/// can then go out and the lights' answers come back. True when Apple Home was only started now (it needs a moment
/// to find its lights).
@MainActor private func startHome() -> Bool {
    SmartHome.shared.start()
    SiriVocabulary.start()
    #if os(iOS)
    if SmartHome.shared.homeControl == nil {
        HomeKitLights.shared.start()
        return SmartHome.shared.homeControl != nil
    }
    #endif
    return false
}

/// The light Siri named: by its id, else by its name (one found again under another id keeps its name).
@MainActor private func findLight(_ e: LightEntity) -> GoveeLight? {
    let h = SmartHome.shared
    return h.light(e.id) ?? h.lights.first { spokenKey($0.name) == spokenKey(e.name) }
}

/// Apple Home reads its homes a moment after it starts: gives it that, then waits (up to [seconds]) until each of
/// [ids] is listed again.
@MainActor private func settleHome(_ ids: [String], seconds: Double) async {
    let h = SmartHome.shared
    try? await Task.sleep(nanoseconds: 1_200_000_000)
    var waited = 0.0
    while waited < seconds && ids.contains(where: { h.light($0) == nil }) {
        try? await Task.sleep(nanoseconds: 250_000_000)
        waited += 0.25
    }
}

/// How a change went: the lights it reached, and what went wrong with the others.
private struct LightOutcome {
    var done: [String] = []
    var problems: [String] = []
}

/// Does [apply] to each of [ids] and finds out how it really went. [turnsOn]: the power each light should end up
/// with (a light that didn't do it is one that failed).
@MainActor private func change(_ ids: [String], turnsOn: Bool?, coldHome: Bool, _ apply: @MainActor (GoveeLight) -> Void) async -> LightOutcome {
    let h = SmartHome.shared
    let viaHome = ids.contains { h.light($0)?.isHome == true }
    if coldHome && viaHome { await settleHome(ids, seconds: 3) }
    var out = await attempt(ids, turnsOn: turnsOn, apply)
    // Apple Home was only just started and may not have had its lights yet: once more, when it has.
    if !out.problems.isEmpty && coldHome && viaHome {
        await settleHome(ids, seconds: 4)
        out = await attempt(ids, turnsOn: turnsOn, apply)
        if !out.problems.isEmpty {
            out.problems.append("Apple Home may not answer while Woodruff is closed: open Woodruff and try again.")
        }
    }
    return out
}

@MainActor private func attempt(_ ids: [String], turnsOn: Bool?, _ apply: @MainActor (GoveeLight) -> Void) async -> LightOutcome {
    let h = SmartHome.shared
    var out = LightOutcome()
    let targets = ids.compactMap { h.light($0) }
    let missing = ids.count - targets.count
    if missing > 0 {
        out.problems.append(ids.count == 1 ? "I can’t find that light right now." : "\(missing) of the lights can’t be found right now.")
    }
    guard !targets.isEmpty else { return out }
    let wasOffline = Set(targets.filter(\.isOffline).map(\.id))
    let before = h.goveeError
    for l in targets { apply(l) }
    // Apple Home and Govee's cloud say no within a second or two (the light then goes back to how it was);
    // a lamp on the Wi‑Fi answers its next ask.
    var said: String?
    for _ in 0..<8 {
        try? await Task.sleep(nanoseconds: 250_000_000)
        if let e = h.goveeError, e != before { said = e; break }
    }
    for l in targets {
        guard let now = h.light(l.id) else { out.problems.append("\(l.name) can’t be found right now."); continue }
        if wasOffline.contains(l.id) && now.isOffline { out.problems.append("\(now.name) isn’t answering."); continue }
        if let want = turnsOn, now.on != want { out.problems.append("\(now.name) didn’t turn \(want ? "on" : "off")."); continue }
        out.done.append(now.name)
    }
    if let said {
        // What Apple Home or Govee said: for one light, that's the whole story.
        if targets.count == 1 { out.done = []; out.problems = [said] }
        else if !out.problems.contains(said) { out.problems.append(said) }
    }
    return out
}

/// "Turned off the Living Room lights." or "Turned off 3 of 4: … Lamp isn’t answering."
private func words(_ o: LightOutcome, on: Bool, what: String, total: Int) -> String {
    let verb = on ? "Turned on" : "Turned off"
    if o.problems.isEmpty { return "\(verb) \(what)." }
    if o.done.isEmpty { return o.problems.joined(separator: " ") }
    return "\(verb) \(o.done.count) of \(total): \(o.done.joined(separator: ", ")). " + o.problems.joined(separator: " ")
}

/// Turns one light on or off and says how it went.
@MainActor private func turn(_ e: LightEntity, on: Bool) async -> String {
    let cold = startHome()
    guard let l = findLight(e) else { return "I can’t find \(e.name)." }
    let o = await change([l.id], turnsOn: on, coldHome: cold) { SmartHome.shared.setOn($0, on) }
    return o.problems.isEmpty ? "Turned \(on ? "on" : "off") \(l.name)." : o.problems.joined(separator: " ")
}

/// Every light in [list] on or off, and what happened.
@MainActor private func turnAll(_ list: [GoveeLight], on: Bool, what: String, cold: Bool) async -> String {
    let o = await change(list.map(\.id), turnsOn: on, coldHome: cold) { SmartHome.shared.setOn($0, on) }
    return words(o, on: on, what: what, total: list.count)
}

// MARK: - Lights

struct SetLightPowerIntent: AppIntent {
    static let title: LocalizedStringResource = "Turn a Light On or Off"
    static let description = IntentDescription("Turns a light on or off.")
    @Parameter(title: "Light") var light: LightEntity
    // No default: from Siri ("Switch the lamp…") it asks.
    @Parameter(title: "On or Off", requestValueDialog: "On or off?") var power: PowerChoice

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let said = await turn(light, on: power == .on)
        return .result(dialog: "\(said)")
    }
}

struct LightOnIntent: AppIntent {
    static let title: LocalizedStringResource = "Turn On a Light"
    @Parameter(title: "Light") var light: LightEntity
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let said = await turn(light, on: true)
        return .result(dialog: "\(said)")
    }
}

struct LightOffIntent: AppIntent {
    static let title: LocalizedStringResource = "Turn Off a Light"
    @Parameter(title: "Light") var light: LightEntity
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let said = await turn(light, on: false)
        return .result(dialog: "\(said)")
    }
}

struct SetRoomLightsIntent: AppIntent {
    static let title: LocalizedStringResource = "Turn a Room’s Lights On or Off"
    static let description = IntentDescription("Turns every light in a room on or off.")
    @Parameter(title: "Room") var room: RoomEntity
    @Parameter(title: "On or Off", default: .off) var power: PowerChoice

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let said = await turnRoom(room, on: power == .on)
        return .result(dialog: "\(said)")
    }
}

/// The room's lights on, by name ("Turn on the Master Bedroom lights"): a Siri phrase holds only one name, so
/// on and off each have their own.
struct RoomLightsOnIntent: AppIntent {
    static let title: LocalizedStringResource = "Turn On a Room’s Lights"
    @Parameter(title: "Room") var room: RoomEntity

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let said = await turnRoom(room, on: true)
        return .result(dialog: "\(said)")
    }
}

struct RoomLightsOffIntent: AppIntent {
    static let title: LocalizedStringResource = "Turn Off a Room’s Lights"
    @Parameter(title: "Room") var room: RoomEntity

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let said = await turnRoom(room, on: false)
        return .result(dialog: "\(said)")
    }
}

/// Every light in [room] on or off, and what happened.
@MainActor private func turnRoom(_ room: RoomEntity, on: Bool) async -> String {
    let cold = startHome()
    let h = SmartHome.shared
    let want = spokenKey(room.id)
    let list = h.lights.filter { l in h.room(of: l.id).map { spokenKey($0) == want } ?? false }
    guard !list.isEmpty else { return "There are no lights in \(room.id)." }
    return await turnAll(list, on: on, what: "the \(room.id) lights", cold: cold)
}

struct AllLightsIntent: AppIntent {
    static let title: LocalizedStringResource = "Turn All Lights On or Off"
    @Parameter(title: "On or Off", default: .off) var power: PowerChoice

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let cold = startHome()
        let list = SmartHome.shared.lights
        guard !list.isEmpty else { return .result(dialog: "There are no lights to turn \(power == .on ? "on" : "off").") }
        let said = await turnAll(list, on: power == .on, what: "every light", cold: cold)
        return .result(dialog: "\(said)")
    }
}

struct SetLightColorIntent: AppIntent {
    static let title: LocalizedStringResource = "Set a Light’s Colour"
    @Parameter(title: "Light") var light: LightEntity
    @Parameter(title: "Colour") var color: ColorChoice

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let cold = startHome()
        guard let l = findLight(light) else { return .result(dialog: "I can’t find \(light.name).") }
        let (c, k) = color.value
        let o = await change([l.id], turnsOn: true, coldHome: cold) { x in
            if let c { SmartHome.shared.setColor(x, c) } else if let k { SmartHome.shared.setWhite(x, kelvin: k) }
        }
        let said = o.problems.isEmpty ? "\(l.name) is \(color.words) now." : o.problems.joined(separator: " ")
        return .result(dialog: "\(said)")
    }
}

struct SetLightBrightnessIntent: AppIntent {
    static let title: LocalizedStringResource = "Set a Light’s Brightness"
    @Parameter(title: "Light") var light: LightEntity
    @Parameter(title: "Brightness", inclusiveRange: (1, 100)) var brightness: Int

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let cold = startHome()
        guard let l = findLight(light) else { return .result(dialog: "I can’t find \(light.name).") }
        let level = max(1, min(100, brightness))
        let o = await change([l.id], turnsOn: true, coldHome: cold) { SmartHome.shared.setBrightness($0, level) }
        let said = o.problems.isEmpty ? "\(l.name) is at \(level)%." : o.problems.joined(separator: " ")
        return .result(dialog: "\(said)")
    }
}

// MARK: - Sonos

/// The Sonos room Siri named (by id, else by name), or the one used last when none is named. When none are known
/// yet (the first time, or Siri started Woodruff just for this), the network is asked first.
@MainActor private func findSpeaker(_ e: SpeakerEntity?) async -> SonosRoom? {
    let h = SmartHome.shared
    SiriVocabulary.start()
    if h.speakers.isEmpty { await h.findSonos() }
    guard let e else { return h.lastSpeaker }
    return h.speaker(e.id) ?? h.speakers.first { spokenKey($0.name) == spokenKey(e.name) }
}

struct SonosPlayPauseIntent: AppIntent {
    static let title: LocalizedStringResource = "Play or Pause Sonos"
    static let description = IntentDescription("Plays or pauses a Sonos room (the last one used if none is named).")
    @Parameter(title: "Room") var speaker: SpeakerEntity?

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let r0 = await findSpeaker(speaker) else { return .result(dialog: "I can’t find a Sonos speaker.") }
        let p = await Sonos.poll(r0, leader: true)
        guard p.answered || p.transportAnswered else { return .result(dialog: "\(r0.name) isn’t answering.") }
        var r = p.room
        r.unreachableSince = nil   // it just answered
        let playing = r.isPlaying
        if !playing && !r.canPlay { return .result(dialog: "There’s nothing to play in \(r.name).") }
        await SmartHome.shared.sonos(r, expect: playing ? "PAUSED_PLAYBACK" : "PLAYING") { room in
            if playing { try await Sonos.pause(room) } else { try await Sonos.play(room) }
        }
        if let e = SmartHome.shared.speakerErrors[r.id] { return .result(dialog: "\(e)") }
        return .result(dialog: "\(playing ? "Paused" : "Playing") \(r.name).")
    }
}

struct SonosVolumeIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Sonos Volume"
    @Parameter(title: "Room") var speaker: SpeakerEntity?
    @Parameter(title: "Volume", inclusiveRange: (0, 100)) var volume: Int

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let r = await findSpeaker(speaker) else { return .result(dialog: "I can’t find a Sonos speaker.") }
        let v = max(0, min(100, volume))
        await SmartHome.shared.sonos(r) { try await Sonos.setVolume($0, v) }
        if let e = SmartHome.shared.speakerErrors[r.id] { return .result(dialog: "\(e)") }
        return .result(dialog: "\(r.name) is at \(v).")
    }
}

struct SonosNextIntent: AppIntent {
    static let title: LocalizedStringResource = "Skip on Sonos"
    @Parameter(title: "Room") var speaker: SpeakerEntity?

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let r = await findSpeaker(speaker) else { return .result(dialog: "I can’t find a Sonos speaker.") }
        if r.isTV { return .result(dialog: "\(r.name) is playing the TV’s sound; there’s nothing to skip.") }
        await SmartHome.shared.sonos(r) { try await Sonos.next($0) }
        if let e = SmartHome.shared.speakerErrors[r.id] { return .result(dialog: "\(e)") }
        return .result(dialog: "Skipped in \(r.name).")
    }
}

struct SonosWhatsPlayingIntent: AppIntent {
    static let title: LocalizedStringResource = "What’s Playing on Sonos"
    @Parameter(title: "Room") var speaker: SpeakerEntity?

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let r0 = await findSpeaker(speaker) else { return .result(dialog: "I can’t find a Sonos speaker.") }
        let p = await Sonos.poll(r0, leader: true)
        guard p.answered || p.transportAnswered else { return .result(dialog: "\(r0.name) isn’t answering.") }
        var r = p.room
        r.unreachableSince = nil   // it just answered
        if r.isTV { return .result(dialog: "\(r.name) is playing the TV’s sound\(r.isPlaying ? "" : ", paused").") }
        guard let t = r.title, !t.isEmpty, r.state != "STOPPED" else { return .result(dialog: "Nothing is playing in \(r.name).") }
        return .result(dialog: "\(t)\(r.artist.map { " by \($0)" } ?? "") in \(r.name)\(r.isPlaying ? "" : ", paused").")
    }
}

// MARK: - Siri's names

/// Keeps the names Siri listens for (lights, rooms, Sonos rooms, TVs) up to date. App Shortcuts phrases with a
/// name in them ("Turn off Elliot’s Lamp with Woodruff") only know the names they were last given, so without
/// this a light, room or TV added or renamed here was never found by voice.
@MainActor
enum SiriVocabulary {
    private static var started = false
    private static var lastKey = ""
    private static var pending: Task<Void, Never>?

    /// Starts following the names (once; later calls do nothing).
    static func start() {
        guard !started else { return }
        started = true
        follow()
    }

    private static func follow() {
        let key = withObservationTracking {
            names()
        } onChange: {
            Task { @MainActor in SiriVocabulary.follow() }
        }
        guard key != lastKey else { return }
        lastKey = key
        pending?.cancel()
        pending = Task { @MainActor in
            // Names arrive in bursts (a search finding one lamp after another): tell Siri once they settle.
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            WoodruffShortcuts.updateAppShortcutParameters()
        }
    }

    private static func names() -> String {
        let h = SmartHome.shared
        let lights = h.lights.map { "\($0.id)=\($0.name)@\(h.room(of: $0.id) ?? "")" }
        let speakers = h.speakers.map { "\($0.id)=\($0.name)" }
        let tvs = Fleet.shared.tvs.filter { !$0.isUnpaired }.map { "\($0.id)=\($0.name)" }
        return (lights + ["#"] + speakers + ["#"] + tvs).joined(separator: ";")
    }
}

// MARK: - Control Center

/// The Control Center buttons' work (see `ControlHook`).
enum ControlActions {
    /// Every light on or off, once they're found (a button may have just started Woodruff).
    @MainActor static func lights(_ on: Bool) async {
        let cold = startHome()
        var waited = 0
        while SmartHome.shared.lights.isEmpty && waited < 12 {
            try? await Task.sleep(nanoseconds: 250_000_000)
            waited += 1
        }
        let list = SmartHome.shared.lights
        guard !list.isEmpty else { return }
        _ = await turnAll(list, on: on, what: "every light", cold: cold)
    }

    /// The Sonos room that's playing (else the last one used) up or down 5.
    @MainActor static func sonosVolume(up: Bool) async {
        let h = SmartHome.shared
        h.start()
        if h.speakers.isEmpty { await h.findSonos() }
        await h.refreshSpeakers()
        guard let r0 = h.speakers.first(where: \.isPlaying) ?? h.lastSpeaker else { return }
        let r = await Sonos.refresh(r0)
        let v = max(0, min(100, r.volume + (up ? 5 : -5)))
        await h.sonos(r) { try await Sonos.setVolume($0, v) }
    }
}
