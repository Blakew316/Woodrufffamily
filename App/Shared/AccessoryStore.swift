import Foundation
import Observation
import WoodruffKit

// Every device in the house that isn't a TV, speaker or light: Apple Home accessories and Samsung SmartThings and Dreo
// appliances. Kept apart from their tiles (Accessories.swift) so the Apple TV, which draws its own, shares them.

/// Where each source's devices are kept between launches (on this device only: they're never synced).
private enum SavedDevices {
    static let home = "devicesHome"
    static let smartThings = "devicesSmartThings"
    static let dreo = "devicesDreo"

    /// What a source said last time, while it's still signed in (never in Demo mode).
    static func load(_ key: String, signedIn: Bool) -> [HomeDevice] {
        guard signedIn, !Demo.isOn else { return [] }
        return Saved.load(key, as: [HomeDevice].self) ?? []
    }
}

@Observable @MainActor
final class AccessoryStore {
    static let shared = AccessoryStore()

    // Each source's devices start as it last said (kept for the next launch), so Home shows every device at once and
    // is drawn once, rather than again as each source answers. The sources only set these when something changed.
    var fromHome: [HomeDevice] = SavedDevices.load(SavedDevices.home, signedIn: true) {
        didSet { changed(SavedDevices.home, fromHome) }
    }
    var fromSmartThings: [HomeDevice] = SavedDevices.load(SavedDevices.smartThings, signedIn: Keychain.get("st.refresh") != nil || Keychain.get("st.token") != nil) {
        didSet { changed(SavedDevices.smartThings, fromSmartThings) }
    }
    var fromDreo: [HomeDevice] = SavedDevices.load(SavedDevices.dreo, signedIn: Keychain.get("dreo.email") != nil && Keychain.get("dreo.password") != nil) {
        didSet { changed(SavedDevices.dreo, fromDreo) }
    }
    /// Carries out a change to an Apple Home accessory (set by the iPhone app).
    @ObservationIgnored var homeControl: ((HomeDevice, DeviceCommand) -> Void)?
    /// Why Apple Home has nothing to show on this iPhone (no permission, no home yet); nil when it's fine.
    var homeProblem: String?

    /// Every device as `all` gives it, and each one's place in it by id: made again only when a source or a name
    /// changes (Home reads it many times each time it's drawn).
    @ObservationIgnored private var made: [HomeDevice] = []
    @ObservationIgnored private var place: [String: Int] = [:]
    /// The family's names `made` was made with; nil until it's made.
    @ObservationIgnored private var madeWith: [String: String]?
    /// What's kept on disk for each source (written again only when that source changes).
    @ObservationIgnored private var kept: [String: [HomeDevice]] = [:]

    init() {
        kept = [SavedDevices.home: fromHome, SavedDevices.smartThings: fromSmartThings, SavedDevices.dreo: fromDreo]
        // The rooms the kept devices report, for Home's first drawing.
        zones()
    }

    /// The house's thermostat (the ecobee): one that's responding first, Apple Home's before SmartThings'.
    var thermostat: HomeDevice? {
        let list = all.filter { $0.kind == .thermostat }
        return list.first { $0.reachable && $0.source == "home" } ?? list.first { $0.reachable } ?? list.first
    }

    /// Every device, by the names the family gave them, in name order.
    var all: [HomeDevice] {
        // The sources and the names are read every time, so whatever shows devices redraws when any of them changes;
        // the list itself is only made again when one of them did.
        _ = (fromHome.count, fromSmartThings.count, fromDreo.count)
        let names = SmartHome.shared.names
        if madeWith != names { make(names) }
        return made
    }

    func device(_ id: String) -> HomeDevice? {
        let list = all
        return place[id].map { list[$0] }
    }

    func send(_ d: HomeDevice, _ c: DeviceCommand) {
        switch d.source {
        case "home":
            // Only the iPhone reaches Apple Home; it's set as soon as Apple Home starts there.
            if let control = homeControl { control(d, c) }
        case "dreo": Dreo.shared.send(d, c)
        default: SmartThings.shared.send(d, c)
        }
    }

    private func make(_ names: [String: String]) {
        // An ecobee linked to both Apple Home and SmartThings shows once (the Apple Home one).
        let homeThermostats = Set(fromHome.filter { $0.kind == .thermostat }.map { $0.name.lowercased() })
        let st = fromSmartThings.filter { !($0.kind == .thermostat && homeThermostats.contains($0.name.lowercased())) }
        let list = (fromHome + st + fromDreo).map { d -> HomeDevice in
            var d = d
            if let n = names[d.id], !n.isEmpty { d.name = n }
            return d
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        var ids: [String: Int] = [:]
        for (i, d) in list.enumerated() where ids[d.id] == nil { ids[d.id] = i }
        made = list
        place = ids
        madeWith = names
    }

    /// A source changed: the list is made again, the rooms the devices report go to SmartHome, and what the source
    /// said is kept for the next launch.
    /// When each device last answered (seconds since 1970), kept between launches: one out of reach for more than a
    /// day says when it was last seen instead of only "Not Responding".
    @ObservationIgnored private var seenAt: [String: Double] = Saved.load("deviceSeenAt", as: [String: Double].self) ?? [:]
    @ObservationIgnored private var seenSaved = Date.distantPast

    private func noteSeen(_ list: [HomeDevice]) {
        let now = Date()
        for d in list where d.reachable { seenAt[d.id] = now.timeIntervalSince1970 }
        // Written now and then (a day is what matters, not the minute).
        if now.timeIntervalSince(seenSaved) > 600 {
            seenSaved = now
            Saved.save("deviceSeenAt", seenAt)
        }
    }

    /// Out of reach for more than a day (and seen here before then).
    func longGone(_ d: HomeDevice) -> Bool {
        // Not the Samsung appliances: they say they're out of reach whenever they're idle.
        guard !d.reachable, d.bespokeLook == nil, let t = seenAt[d.id] else { return false }
        return Date().timeIntervalSince1970 - t > 86_400
    }

    /// What a device out of reach says: "Not Responding", or "Last Seen Tuesday" once it's been more than a day.
    func notResponding(_ d: HomeDevice) -> String {
        guard longGone(d), let t = seenAt[d.id] else { return "Not Responding" }
        let at = Date(timeIntervalSince1970: t)
        let week = Date().timeIntervalSince(at) < 6 * 86_400
        return "Last Seen " + (week ? at.formatted(.dateTime.weekday(.wide)) : at.formatted(.dateTime.month(.abbreviated).day()))
    }

    private func changed(_ key: String, _ list: [HomeDevice]) {
        noteSeen(list)
        make(SmartHome.shared.names)
        zones()
        guard kept[key] != list, !Demo.isOn else { return }
        kept[key] = list
        Saved.save(key, list)
    }

    /// Also when the lights or speakers change (a light found after the devices still gets the room in its name).
    func zones() {
        var z: [String: String] = [:]
        // The rooms the house already has (the TVs', the family's own, Sonos', the apps').
        let known = Set(SmartHome.shared.rooms.values) .union(Fleet.shared.tvs.map(\.name)).union(SmartHome.shared.extraRooms)
            .union((fromHome + fromSmartThings + fromDreo).compactMap(\.zone))
        for d in fromHome + fromSmartThings + fromDreo {
            if let r = d.zone, !r.isEmpty { z[d.id] = r } else if let r = Self.likelyRoom(d, known: known) { z[d.id] = r }
        }
        // Lights and speakers without a room of their own: one named in their name.
        let h = SmartHome.shared
        for (id, name, zone) in h.lights.map({ ($0.id, $0.name, $0.zone) }) + h.speakers.map({ ($0.id, $0.name, Optional($0.zone)) })
            where (zone ?? "").isEmpty && h.rooms[id] == nil {
            let n = name.lowercased()
            if let r = known.filter({ !$0.isEmpty && n.contains($0.lowercased()) }).max(by: { $0.count < $1.count }) { z[id] = r }
        }
        // Only a real change: every room on Home is worked out again from these.
        if SmartHome.shared.externalZones != z { SmartHome.shared.externalZones = z }
    }

    /// Where a device with no room in its own app most likely is, so it shows somewhere instead of nowhere: a room
    /// named in its name ("Kitchen Light"), else the kitchen for a fridge, oven or dishwasher and the laundry room
    /// for a washer or dryer. A room set for it in Woodruff always comes first (SmartHome.room(of:)).
    static func likelyRoom(_ d: HomeDevice, known: Set<String>) -> String? {
        let name = d.name.lowercased()
        if let r = known.filter({ !$0.isEmpty && name.contains($0.lowercased()) }).max(by: { $0.count < $1.count }) { return r }
        func existing(_ word: String) -> String? { known.first { $0.lowercased().contains(word) } }
        switch d.kind {
        case .fridge, .oven, .dishwasher: return existing("kitchen") ?? "Kitchen"
        case .washer, .dryer: return existing("laundry") ?? "Laundry Room"
        default: return nil
        }
    }
}
