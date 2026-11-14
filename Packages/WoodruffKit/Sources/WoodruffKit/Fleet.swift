import Foundation
import Observation
#if os(macOS)
import IOKit
#elseif canImport(UIKit)
import UIKit
#endif

/// A TV this app is paired with directly (its QR code): a "hub". Every hub also reports the TVs linked to it,
/// so pairing one TV is enough to see and control the whole family; pairing more makes each one reachable
/// even when another is off.
public struct Hub: Codable, Identifiable, Hashable, Sendable {
    public var id: String           // the TV's own id (from /api/status)
    public var name: String
    public var connection: TVConnection
    public var addedAt: Date

    public init(id: String, name: String, connection: TVConnection, addedAt: Date = Date()) {
        self.id = id; self.name = name; self.connection = connection; self.addedAt = addedAt
    }
}

/// What the app keeps about one TV beyond what the TV says: LG direct control, SSH for webOS updates, Wake-on-LAN.
public struct TVExtras: Codable, Hashable, Sendable {
    public var platform: TVPlatform?
    public var lgHost: String?
    public var ssh: WebOSSSH?
    public var mac: String?
    public var lastHost: String?
    /// The name the family gave this TV here (the TV itself may still call itself something else).
    public var alias: String?
    public init() {}
}

/// One TV as the dashboard shows it, merged from every hub that knows it.
public struct FleetTV: Identifiable, Hashable, Sendable, Codable {
    public var id: String
    public var name: String
    public var online: Bool
    public var onScreen: Bool
    public var playing: NowPlaying?
    public var version: String?
    public var seen: Double?
    /// "ok" or "refused" (the TV turned its hub's link key down: link again with the code it shows).
    public var link: String
    public var health: HealthSummary?
    /// The hub that reaches it, and the id that hub knows it by ("this" when it's the hub itself).
    public var hubID: String
    public var routeID: String
    public var isHub: Bool { routeID == "this" }
    public var platform: TVPlatform?
    /// The alerts the family has seen and hidden (they come back if something new goes wrong).
    public var alertsHidden = false
    /// A Woodruff TV heard on the Wi‑Fi that isn't paired or linked yet (`link == "unpaired"`): where it answers.
    public var foundAt: URL?
    /// A TV paired here that answers but turns this device's pairing key down (it was reset, or has a new key): it
    /// needs pairing again here, which isn't the same as off. Until it answers again. (Optional: copies saved before
    /// it was kept still read.)
    public var pairingRefused: Bool?
    /// What it shows is paused, and has been for 5 minutes, or was already paused when this app first saw it (an
    /// Android session left behind after leaving YouTube, Netflix or Plex): it no longer counts as playing
    /// (`FleetMerge.pause`).
    public var pausedLong = false

    /// What the TV is playing right now, the one thing every picture, title and player goes by: nothing while it's
    /// off or not paired, nothing once a pause has gone on too long (`pausedLong`), and nothing while it only shows
    /// one of its inputs (`NowPlaying.isInput`: an HDMI box isn't something playing). `playing` is what the TV last
    /// said, for its controls.
    public var nowPlaying: NowPlaying? {
        guard online, !isUnpaired, let p = playing, !p.isInput, p.isPlaying || !pausedLong else { return nil }
        return p
    }

    public var isUnpaired: Bool { link == "unpaired" }
    /// Something the family should look at (and hasn't hidden).
    public var needsAttention: Bool { !alertsHidden && hasAlerts }
    /// Something is wrong, hidden or not.
    public var hasAlerts: Bool { link == "refused" || health?.status == "attention" }
    /// What the alerts say right now: hiding is undone when this changes.
    public var alertSignature: String { "\(link)|\(health?.status ?? "")|\(health?.count ?? 0)|\(health?.first ?? "")" }
}

public struct Banner: Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var title: String
    public var message: String
    /// Something went wrong, or an answer that was asked for (`Fleet.show`, `Fleet.alert`): it's shown until it's
    /// dismissed. A result that only confirms (`Fleet.say`: "Sent") isn't one: the Mac shows those as a line in its
    /// window that goes by itself. (iPhone and Apple TV show both as alerts.)
    public var isAlert: Bool
    /// When it was said. The Mac drops one it only finds later (said with no window open to show it).
    public var at = Date()
    public init(title: String, message: String, isAlert: Bool = false) {
        self.title = title
        self.message = message
        self.isAlert = isAlert
    }
}

/// Everything the app knows about the family's TVs, and every action on them.
@Observable @MainActor
public final class Fleet {
    public static let shared = Fleet()

    public private(set) var hubs: [Hub] = [] { didSet { updateLibraryHub() } }
    public private(set) var tvs: [FleetTV] = [] { didSet { noteTVs(); keepLastSeen() } }

    /// What the TVs were doing when last heard (kept between launches): shown as the app opens, until each TV's hub
    /// answers (or is found out of reach), so Home doesn't start with every TV off. Older than six hours: not used.
    private struct LastSeen: Codable {
        var at: Double
        var tvs: [FleetTV]
    }
    @ObservationIgnored private var lastSeenSaved = Date.distantPast
    @ObservationIgnored private var lastSeenPending: Task<Void, Never>?

    /// Saved at most every ten seconds (the TVs' state changes every few).
    private func keepLastSeen() {
        guard !Demo.isOn, lastSeenPending == nil else { return }
        let wait = max(0, 10 - Date().timeIntervalSince(lastSeenSaved))
        lastSeenPending = Task { [weak self] in
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            guard let self else { return }
            self.lastSeenPending = nil
            self.lastSeenSaved = Date()
            Saved.save("lastSeenTVs", LastSeen(at: Date().timeIntervalSince1970, tvs: self.tvs.filter { !$0.isUnpaired }))
        }
    }

    /// [fresh] (every paired TV, as off) with what each was last seen doing, and the linked TVs its hubs passed on.
    private static func withLastSeen(_ fresh: [FleetTV], hubs: [Hub]) -> [FleetTV] {
        guard let saved = Saved.load("lastSeenTVs", as: LastSeen.self),
              Date().timeIntervalSince1970 - saved.at < 6 * 3600 else { return fresh }
        let hubIDs = Set(hubs.map(\.id))
        var out = fresh.map { tv in saved.tvs.first { $0.id == tv.id && $0.isHub } ?? tv }
        for t in saved.tvs where !t.isHub && hubIDs.contains(t.hubID) && !out.contains(where: { $0.id == t.id }) { out.append(t) }
        return out.sorted(by: FleetMerge.order)
    }
    /// Saved only when something in it changed (it's set again with what it already holds now and then: a TV's health
    /// report saying the same platform, say). Every save is noticed by the settings sync as a change to look at.
    public var extras: [String: TVExtras] = [:] { didSet { if extras != oldValue { Saved.save("extras", extras); noteBadge() } } }

    /// TV details the app changed by itself (`adjustExtras`), each TV's as it was just before and just after, until the
    /// settings sync takes them (`takeAutomaticExtras`).
    @ObservationIgnored private var automaticExtras: [String: (from: TVExtras, to: TVExtras)] = [:]

    /// Changes what's kept for the TV [id] the way the app does by itself, not a person (where the TV answers now, the
    /// kind it says it is, the way in that worked): only where something is kept for it already, and noted for the
    /// settings sync (`takeAutomaticExtras`).
    func adjustExtras(_ id: String, _ change: (inout TVExtras) -> Void) {
        guard var e = extras[id] else { return }
        let before = e
        change(&e)
        guard e != before else { return }
        // Straight after another change of its own, with nothing else changed between: from where that one began.
        let from = automaticExtras[id].flatMap { $0.to == before ? $0.from : nil } ?? before
        automaticExtras[id] = (from, e)
        extras[id] = e
    }

    /// The TV details the app changed by itself since the last call, each as it was before and after (`adjustExtras`).
    /// The settings sync stamps these a moment after what they changed, never as new: a TV's details travel whole, and
    /// stamped as new, a change like this on a device that hadn't had the family's latest yet put the details from
    /// before back on every device, a name given to the TV on another device and all.
    public func takeAutomaticExtras() -> [String: (from: TVExtras, to: TVExtras)] {
        defer { automaticExtras = [:] }
        return automaticExtras
    }

    /// Reads names, TV details and hidden alerts again (after another of the family's devices changed them).
    public func reloadSynced() {
        if let e = Saved.load("extras", as: [String: TVExtras].self), e != extras { extras = e }
        let h = Saved.load("hiddenAlerts", as: [String: String].self) ?? [:]
        if h != hiddenAlerts { hiddenAlerts = h }
        rebuild()   // new names and hidden alerts show at once
        Task { await refresh() }
    }
    /// The TV the remote, Send and Memories act on.
    public var selectedID: String? {
        didSet {
            UserDefaults.standard.set(selectedID, forKey: "selectedTV")
            updateLibraryHub()
        }
    }
    public var banner: Banner?
    /// The remote sends to every TV that's on.
    public var remoteAll = false
    /// Mac: the remote's sidebar is out.
    public var remotePanel = false
    /// When the latest answer arrived. Not observed: it changes with every answer, and what shows it reads it inside a
    /// `TimelineView` (each tick reads it afresh) or outside any view.
    @ObservationIgnored public private(set) var refreshedAt: Date?
    public private(set) var latest: [TVPlatform: Release] = [:]
    public private(set) var releaseErrors: [TVPlatform: String] = [:]
    public private(set) var healthReports: [String: HealthReport] = [:]
    public private(set) var healthErrors: [String: String] = [:]
    /// Events for notifications: a TV went offline, came back, needs attention.
    public var onChange: ((FleetEvent) -> Void)?
    /// A film began playing on a TV's own player, with how long it took from the player opening (`FilmStartWatch`):
    /// the TV's name and the start. For the family's log, where a slow start can then be read from.
    @ObservationIgnored public var onFilmStart: ((String, FilmStartWatch.Start) -> Void)?
    @ObservationIgnored private var filmStarts = FilmStartWatch()

    public var phone = PhoneIdentity.load() { didSet { phone.save() } }
    public var githubToken: String? {
        get { Keychain.get("github.token") }
        set { Keychain.set(newValue, for: "github.token"); Task { await checkReleases() } }
    }

    /// TV id → the alerts hidden for it (their signature).
    public private(set) var hiddenAlerts: [String: String] = Saved.load("hiddenAlerts", as: [String: String].self) ?? [:]
    private let discovery = TVDiscovery()
    /// Each TV's own address as last heard announcing on the Wi‑Fi, and its kind as this device worked it out, kept on
    /// this device only. Both used to live in `extras`, which travels between the family's devices one TV at a time:
    /// a device with nothing saved for a TV yet (a new install) saved its kind as the newest word on that TV, and the
    /// address typed for its remote, its name and its Wake-on-LAN details were dropped from every device.
    @ObservationIgnored private var heardHosts: [String: String] = Saved.load("heardHosts", as: [String: String].self) ?? [:]
    @ObservationIgnored private var learnedPlatforms: [String: TVPlatform] = Saved.load("learnedPlatforms", as: [String: TVPlatform].self) ?? [:]

    /// Where [tv] itself answers on this Wi‑Fi: where it's announcing now, else where it last did. Known for a TV
    /// another TV passes on too, whose address this device isn't told any other way.
    public func heardHost(of tv: FleetTV) -> String? {
        if let h = discovery.found.first(where: { $0.id == tv.id })?.host, !h.isEmpty { return h }
        return heardHosts[tv.id]
    }

    /// Notes what the TV [id] is (Android or LG), on this device only.
    private func learn(_ id: String, _ platform: TVPlatform) {
        guard learnedPlatforms[id] != platform else { return }
        learnedPlatforms[id] = platform
        Saved.save("learnedPlatforms", learnedPlatforms)
    }
    /// TVs found by asking every address on the home network (for those whose announcement doesn't arrive).
    public private(set) var lanFound: [DiscoveredTV] = []
    private var lanScannedAt: Date?

    /// Looks for Woodruff TVs on the home network now (also runs every 10 minutes by itself).
    public func scanNetwork() async {
        #if canImport(Darwin)
        lanScannedAt = Date()
        lanFound = await LANScan.find()
        await refresh()
        // A paired TV that has stopped answering, found by this search under its own name at another address on the
        // home network: asked there, and talked to there from now on if it answers as that TV, with its key
        // (`adoptAddress`). Otherwise only its announcement on the Wi‑Fi (`moveIfNeeded`), or another device that
        // already had its new address, moved one, and an LG's announcement doesn't reach this device: one the router
        // gave a new address stayed off everywhere (not offered to pair again either, its name being the paired TV's)
        // until it was paired again by hand.
        for hub in hubs where !isAnswering(hub.id) {
            for f in lanFound where f.name.caseInsensitiveCompare(hub.name) == .orderedSame && f.host != hub.connection.base.host {
                if let base = f.base, await adoptAddress(base, forHub: hub.id) { break }
            }
        }
        #endif
    }
    private var notifiedAlerts: [String: String] = Saved.load("notifiedAlerts", as: [String: String].self) ?? [:]
    private var offlineSince: [String: Date] = [:]
    private var offlineNotified: Set<String> = []
    /// TVs whose "can't reach" notification actually went out (so "back" only follows one of those).
    private var offlineAnnounced: Set<String> = []

    /// Whether this iPhone or Mac is on the home Wi‑Fi: the same network as a paired TV's address.
    /// Clearly away from home (TVs known, none on this network): no point searching the Wi‑Fi for things.
    public var probablyAway: Bool { !(hubs.isEmpty && extras.isEmpty) && !atHome }

    public var atHome: Bool {
        #if canImport(Darwin)
        let mine = LANScan.recentPrefixes()
        let tvHosts = hubs.compactMap { $0.connection.base.host } + extras.values.compactMap(\.lastHost)
        // Same network, allowing for ones wider than 256 addresses (a Deco's is 192.168.68.0–71.255).
        func block(_ p: [Substring]) -> String? {
            guard p.count >= 3, let third = Int(p[2]) else { return nil }
            return "\(p[0]).\(p[1]).\(third / 4)"
        }
        let myBlocks = Set(mine.compactMap { block($0.split(separator: ".")) })
        return tvHosts.contains { host in
            let parts = host.split(separator: ".")
            return parts.count == 4 && block(parts).map(myBlocks.contains) == true
        }
        #else
        return true
        #endif
    }

    /// Whether a TV that stopped answering is really unreachable, rather than just switched off: its
    /// address still answers on the network (or, for an LG, it says it's awake) but Woodruff on it doesn't.
    func cantTalkToIt(_ tv: FleetTV) async -> Bool {
        if let lg = lg(for: tv) {
            if let state = try? await lg.call("ssap://com.webos.service.tvpower/power/getPowerState"),
               let s = state["state"]?.string {
                return s == "Active"   // awake, yet not answering Woodruff
            }
        }
        var hosts: [(String, UInt16)] = []
        if let h = hub(tv.id), let host = h.connection.base.host { hosts.append((host, UInt16(h.connection.base.port ?? 8090))) }
        if let host = extras[tv.id]?.lastHost { hosts.append((host, 8090)) }
        if let f = tv.foundAt, let host = f.host { hosts.append((host, UInt16(f.port ?? 8090))) }
        if let host = extras[tv.id]?.lgHost, !host.isEmpty { hosts.append((host, 3000)) }
        // Nowhere to look: say nothing (most likely it's just off).
        for (host, port) in hosts {
            switch await NetProbe.check(host: host, port: port) {
            case .answers, .refused: return true   // the TV is on the network
            case .nothing: continue
            }
        }
        return false
    }

    private var active = true
    /// Whether the app is in use (on the Mac: its window can be seen): the house's speakers and lights, the sync and
    /// Apple Home on the Mac are asked less often while it isn't.
    public var isActive: Bool { active }

    /// A polling loop's wait: [inUse] seconds while the app is in use, up to [idle] while it isn't (on the Mac, no
    /// window seen). Back in use partway through, the wait ends within five seconds, so what's shown is fresh.
    public static func pause(inUse: Double, idle: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(inUse * 1_000_000_000))
        var waited = inUse
        while waited < idle, !Task.isCancelled, !Fleet.shared.isActive {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            waited += 5
        }
    }
    private var loop: Task<Void, Never>?
    @ObservationIgnored private var inboxLoop: Task<Void, Never>?
    @ObservationIgnored private var slowLoop: Task<Void, Never>?
    /// Not observed: `lg(for:)` is asked while pages are drawn, and makes or replaces these as it goes.
    @ObservationIgnored private var lgRemotes: [String: LGRemote] = [:]
    /// The sign-in each LG connection was made with.
    @ObservationIgnored private var lgKeys: [String: String] = [:]
    /// The `Keychain.generation` at which each TV's LG sign-in was last read (it's read again only after a write).
    @ObservationIgnored private var lgKeysRead: [String: Int] = [:]

    // Each hub is asked on its own clock and its answer shows the moment it arrives (see `askDue` and `take`).
    /// Each hub's latest answer (none yet: still waiting for its first).
    @ObservationIgnored private var answers: [String: HubAnswer] = [:]
    /// When each hub's latest answer arrived, on this device's clock: one older than `staleAfter` isn't believed
    /// about what's playing.
    @ObservationIgnored private var answeredAt: [String: Date] = [:]
    /// Each TV a hub passes on (by `FleetMerge.relayKey`): its `seen` in that hub's answers, and when the answer that
    /// first carried that value arrived. One that hasn't moved for a while is a TV the hub hasn't heard from lately.
    @ObservationIgnored private var relaySeen: [String: RelaySeen] = [:]
    /// Each TV's pause clock, by TV id (`FleetMerge.pause`).
    @ObservationIgnored private var pauseMarks: [String: PauseMark] = [:]
    /// Each TV's `seen` as its hub's latest answer gave it, by TV id (the list keeps an older one while the TV is on).
    @ObservationIgnored private var lastHeard: [String: Double] = [:]
    /// Until when what the hubs said before still counts as fresh: the app has just woken (back from the background, the
    /// Mac from sleep or a nap) and the hubs get a moment to answer, so a TV that's still playing never blinks off and on
    /// (`staleAfter`).
    @ObservationIgnored private var wokeUntil = Date.distantPast
    /// When the loop last ran (`askDue`): a long gap means the app was suspended, or the Mac asleep or napping.
    @ObservationIgnored private var lastTick = Date()
    /// When the app last woke (`woke`): a question asked before then that failed was cut off by the system while the
    /// app slept, and says nothing about its TV.
    @ObservationIgnored private var wokeAt = Date.distantPast
    /// Until when a TV that was answering before the app slept isn't called off for not answering (`woke`).
    @ObservationIgnored private var forgiveUntil = Date.distantPast
    /// Missed answers in a row, per hub (two or more: it's off, or out of reach).
    @ObservationIgnored private var failures: [String: Int] = [:]
    @ObservationIgnored private var askedAt: [String: Date] = [:]
    @ObservationIgnored private var inFlight: [String: Int] = [:]
    /// Every question gets a number; an answer older than the last one shown for its hub is dropped.
    @ObservationIgnored private var askSeq = 0
    @ObservationIgnored private var takenSeq: [String: Int] = [:]
    /// How long each hub took to answer last time (a usually slow one gets longer to answer).
    @ObservationIgnored private var latency: [String: TimeInterval] = [:]
    /// Hubs asked as often as the ones that answer, whatever they did last (just woken, say).
    @ObservationIgnored private var boostUntil: [String: Date] = [:]
    @ObservationIgnored private var pokes: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var heardBefore: Set<String> = []

    /// The Fleet the app runs: told about every command sent through a `TVClient` (see `TVClient.changed`).
    /// Nil in widgets and anywhere `start()` wasn't called.
    static var running: Fleet?

    init() {
        if Demo.isOn {
            Demo.register()
            hubs = [Demo.hub]
            extras = ["tv-kitchen": { var e = TVExtras(); e.platform = .webOS; e.lgHost = nil; return e }(),
                      "tv-living": { var e = TVExtras(); e.platform = .android; return e }(),
                      "tv-den": { var e = TVExtras(); e.platform = .android; return e }()]
            phone = PhoneIdentity(id: "demo-phone-0001", name: "Blake’s iPhone", alerts: true)
            selectedID = "tv-living"
            latest = Demo.releases
            noteTVs()
            return
        }
        hubs = Fleet.loadPairings()
        extras = Saved.load("extras", as: [String: TVExtras].self) ?? [:]
        selectedID = UserDefaults.standard.string(forKey: "selectedTV")
        tvs = Self.withLastSeen(hubs.map { FleetTV(id: $0.id, name: $0.name, online: false, onScreen: false, playing: nil, version: nil, seen: nil, link: "ok", health: nil, hubID: $0.id, routeID: "this", platform: extras[$0.id]?.platform) }, hubs: hubs)
        noteTVs()
        migrate()
        restoreLibrary()
    }

    /// Old copies cleared, once.
    private func migrate() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "migrated.v2") else { return }
        // What each TV last played was once kept to picture TVs that had stopped; nothing is pictured unless it's
        // playing now, so the old copy goes.
        d.removeObject(forKey: "lastPlaying")
        // The old split copy of the pairings, merged into "pairings". Only once every TV in it was read (a key in a
        // keychain that's still locked would otherwise be lost): until then, again at the next launch.
        let old = Saved.load("hubs", as: [Hub].self) ?? []
        guard old.allSatisfy({ h in hubs.contains { $0.id == h.id } }) else { return }
        if !old.isEmpty { saveHubs() }
        d.removeObject(forKey: "hubs")
        d.set(true, forKey: "migrated.v2")
    }

    /// Pairings are kept in three places so no update, reinstall or re-signed build ever signs the family out:
    /// the app's settings (with their keys: a re-signed Mac build can't read the Keychain items of the one
    /// before), the Keychain as one record (it outlives deleting and reinstalling the app on iPhone), and a
    /// copy the app can hand to its widgets (`pairingBackup`, also used to restore).
    private func saveHubs() {
        if Demo.isOn { return }
        let good = hubs.filter { !$0.connection.key.isEmpty }
        Saved.save("pairings", good)
        if let data = try? JSONEncoder().encode(good) { Keychain.set(String(decoding: data, as: UTF8.self), for: "pairings") }
        for h in good { Keychain.set(h.connection.key, for: "hub.\(h.id)") }
        pairingsChanged?(good)
    }

    /// Called whenever the pairings change (the Mac app copies them to its app group).
    public var pairingsChanged: (([Hub]) -> Void)?

    /// The family's paired TVs from wherever they survived, keys filled in from any copy that has them.
    static func loadPairings() -> [Hub] {
        var found: [String: Hub] = [:]
        func add(_ list: [Hub]?) {
            for h in list ?? [] {
                if var have = found[h.id] {
                    if have.connection.key.isEmpty && !h.connection.key.isEmpty { have.connection = h.connection; found[h.id] = have }
                } else { found[h.id] = h }
            }
        }
        let saved = Saved.load("pairings", as: [Hub].self) ?? []
        add(saved)
        // The Keychain's copy only when the saved one is empty or has a TV without its key. This runs before the
        // first frame, and it was the process's first Keychain call (the slow one). When the saved copy is whole,
        // the Keychain's is read in the background a moment later instead (`pairingsInKeychain`).
        if saved.isEmpty || saved.contains(where: { $0.connection.key.isEmpty }) {
            add(pairingsInKeychain())
            add(Saved.load("hubs", as: [Hub].self)) // before this version: keys were only in the Keychain
            for (id, h) in found where h.connection.key.isEmpty {
                if let k = Keychain.get("hub.\(id)") { found[id]?.connection.key = k }
            }
        } else {
            keychainPairingsUnread = true
        }
        return found.values.filter { !$0.connection.key.isEmpty }.sorted { $0.addedAt < $1.addedAt }
    }

    /// The Keychain's copy of the pairings wasn't read as the app opened (the saved copy was whole): `start` reads it
    /// in the background and adds any TV only it has.
    static var keychainPairingsUnread = false

    /// The pairings as the Keychain has them (none when it has no copy).
    nonisolated static func pairingsInKeychain() -> [Hub] {
        guard let json = Keychain.get("pairings"), let list = try? JSONDecoder().decode([Hub].self, from: Data(json.utf8)) else { return [] }
        return list
    }

    /// Restores pairings from a copy kept outside the app (the Mac's app group), when the app's own are gone.
    public func restorePairings(_ list: [Hub]) {
        let missing = list.filter { h in !h.connection.key.isEmpty && !hubs.contains { $0.id == h.id } }
        guard !missing.isEmpty else { return }
        hubs += missing
        saveHubs()
        Task { await refresh() }
    }

    // MARK: Lifecycle

    public func start() async {
        guard loop == nil else { return }
        Fleet.running = self
        // The Keychain's copy of the pairings, left unread as the app opened: read off the main thread now, and a TV
        // only it has is added (as a copy kept outside the app would be).
        if Fleet.keychainPairingsUnread {
            Fleet.keychainPairingsUnread = false
            Task.detached(priority: .utility) { [weak self] in
                let list = Fleet.pairingsInKeychain()
                guard !list.isEmpty else { return }
                await self?.restorePairings(list)
            }
        }
        if !Demo.isOn { discovery.start() }
        // What every TV is doing: each hub on its own clock (see `askDue`), never waiting on the others.
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                // Until the next hub is due: at least a quarter second, at most half a second while the app is in
                // use (a poke or a TV heard on the Wi‑Fi shows quickly) and 4 seconds while it isn't.
                let next = self.askDue()
                let cap: TimeInterval = self.active ? 0.5 : 4
                let wait = min(max(next.timeIntervalSinceNow, 0.25), cap)
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
        }
        // Announcements for this phone: every 5 seconds while the app is in use, every 30 otherwise.
        inboxLoop = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                guard let self else { return }
                if self.active || tick % 6 == 0 { await self.pollInbox() }
                tick += 1
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
        // The slow things, apart so they never hold up the TVs: the library's pictures (every 2 minutes),
        // releases (every 10) and looking for TVs across the Wi‑Fi (every 10). At launch only the library: the
        // releases follow half a minute in, and the Wi‑Fi search (hundreds of addresses) a minute in, and on the
        // iPhone only while the app is in use, so opening the app asks the TVs first and little else. (The Mac looks
        // with its windows hidden too: its menu bar, widgets and media keys follow the TVs then, and a TV that moved
        // to another address without announcing it would stay "off" there until a window is shown.)
        slowLoop = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                guard let self else { return }
                if tick % 4 == 0 { await self.refreshLibrary() }
                if tick % 20 == 1 { await self.checkReleases() }
                let scanDue = self.lanScannedAt.map({ Date().timeIntervalSince($0) > 600 }) ?? (tick >= 2)
                #if os(macOS)
                let mayScan = true
                #else
                let mayScan = self.active
                #endif
                if !Demo.isOn && mayScan && scanDue { await self.scanNetwork() }
                tick += 1
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
        Task { for h in hubs { _ = try? await hello(h) } }
    }

    public func setActive(_ on: Bool) {
        // Observed: set only when it changes (the app tells this on every scene change, often with the same value).
        let was = active
        if active != on { active = on }
        guard on else { return }
        // Back from the background: what the TVs said before may be long over. Every hub is asked at once, and each
        // answer replaces what that hub said before; one that hasn't answered within `wakeGrace` seconds no longer
        // counts for what's playing (`staleAfter`, `dropStalePlaying`). So a TV that's still playing never blinks off
        // and on, and an old title is gone within a couple of seconds.
        if was { wokeUntil = max(wokeUntil, Date().addingTimeInterval(Fleet.wakeGrace)) } else { woke() }
        Task { await refresh() }
    }

    /// How long the hubs have to answer after the app wakes before what they said before counts as old: an Android hub
    /// answers in about 0.3 s, a webOS one with a linked TV off in about 1.5.
    static let wakeGrace: TimeInterval = 2

    /// How long after the app wakes a TV that was answering before is given before not answering counts as off: the
    /// Wi‑Fi may only just be back, and the first questions go nowhere.
    static let wakeForgive: TimeInterval = 8

    /// The app has just woken (back from the background, the Mac from sleep or a nap). The questions that were out
    /// when it went to sleep were cut off by the system, and the connections kept open to the TVs may have died: both
    /// used to count as the TVs not answering, and two misses showed a TV as off, asked again only every twelve
    /// seconds. Now neither counts: the TVs are asked on connections of their own, every second and a half, and one
    /// that was answering before stays as it was until `forgiveUntil`.
    private func woke(_ now: Date = Date()) {
        wokeUntil = max(wokeUntil, now.addingTimeInterval(Fleet.wakeGrace))
        forgiveUntil = now.addingTimeInterval(Fleet.wakeForgive)
        for hub in hubs { boostUntil[hub.id] = max(boostUntil[hub.id] ?? .distantPast, forgiveUntil) }
        // Told twice as the app comes back (the loop notices the gap, the app says it's in use): once is enough.
        guard now.timeIntervalSince(wokeAt) > 3 else { return }
        wokeAt = now
        URLSession.woodruff.freshConnections()
        // What was out is no longer waited for (`askDue` asks a hub again only once it has answered).
        inFlight = [:]
        // A miss from before doesn't carry over.
        for hub in hubs where answers[hub.id]?.isAnswered == true { failures[hub.id] = nil }
    }

    /// How old a hub's answer may be before what it says is playing isn't believed any more: a little over the time
    /// a hub that has stopped answering takes to count as off while the app is in use, longer while an iPhone's isn't
    /// (the hubs are asked only every 25 seconds then). Any age just after waking (`wokeUntil`), until the hubs have
    /// had a moment.
    private var staleAfter: TimeInterval { Date() < wokeUntil ? .infinity : freshFor }
    /// `staleAfter` waking aside: also how long a hub may keep passing on the same `seen` for a TV (`staleRelays`).
    /// Always 20 on the Mac: with its windows hidden it still asks every 4 seconds (`askDue`), and its menu bar, Mini
    /// Player, Control Center and widgets keep showing what's playing, so a title that has stopped goes as quickly.
    private var freshFor: TimeInterval {
        #if os(macOS)
        return 20
        #else
        return active ? 20 : 75
        #endif
    }

    // MARK: Pairing

    /// A pairing link for a TV that's already paired here with another key or address (see `handle(url:)`).
    public struct AlreadyPaired: LocalizedError, Equatable, Sendable {
        public var name: String
        public init(name: String) { self.name = name }
        public var errorDescription: String? { "Already paired with \(name); forget it first to pair again." }
    }

    /// Pairs with the TV at [connection]: asks who it is, keeps it, says hello as this phone. With [replacing] false
    /// (a link opened from elsewhere), a TV already paired here with another key or address is left as it is, and
    /// `AlreadyPaired` is thrown.
    @discardableResult
    public func pair(_ connection: TVConnection, replacing: Bool = true) async throws -> Hub {
        let status: TVStatus = try await TVTransport(connection).get("/api/status")
        if !replacing, let have = hub(status.id), have.connection != connection {
            throw AlreadyPaired(name: tv(have.id)?.name ?? have.name)
        }
        let oldHost = self.hub(status.id)?.connection.base.host
        let hub = Hub(id: status.id, name: status.name, connection: connection)
        hubs.removeAll { $0.id == hub.id }
        hubs.append(hub)
        failures[hub.id] = nil
        saveHubs()
        adjustExtras(hub.id) { $0.lastHost = connection.base.host }
        followLG(hub.id, from: oldHost, to: connection.base.host)
        if selectedID == nil { selectedID = hub.id }
        _ = try? await hello(hub)
        await refresh()
        return hub
    }

    public func unpair(_ hubID: String) {
        hubs.removeAll { $0.id == hubID }
        Keychain.set(nil, for: "hub.\(hubID)")
        saveHubs()
        answers[hubID] = nil
        answeredAt[hubID] = nil
        relaySeen = relaySeen.filter { !$0.key.hasPrefix(hubID + "|") }
        failures[hubID] = nil
        askedAt[hubID] = nil
        latency[hubID] = nil
        boostUntil[hubID] = nil
        pokes[hubID]?.cancel()
        pokes[hubID] = nil
        // TVs another hub still reaches stay; the ones only it knew go.
        if hubs.isEmpty { tvs.removeAll { $0.hubID == hubID } } else { rebuild() }
        if selectedID == hubID || !tvs.contains(where: { $0.id == selectedID && !$0.isUnpaired }) {
            selectedID = tvs.first { !$0.isUnpaired }?.id
        }
    }

    /// A pairing link opened from elsewhere (the QR code's URL, or woodruff://pair?url=…).
    public func handle(url: URL) {
        var target = url
        if url.scheme == "woodruff", let inner = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "url" })?.value,
           let u = URL(string: inner) { target = u }
        guard let c = TVConnection.parse(target.absoluteString) else { return }
        Task {
            do {
                let h = try await pair(c, replacing: false)
                banner = Banner(title: "Paired", message: "\(h.name) is connected.")
            } catch let e as AlreadyPaired {
                banner = Banner(title: "Not Paired", message: e.localizedDescription, isAlert: true)
            } catch { show(error) }
        }
    }

    // MARK: Refresh

    /// Asks every hub for its TVs now (each hub answers for itself and its linked TVs). Each answer shows the
    /// moment it arrives, so a TV that's off never holds up the others; returns once every hub has answered or
    /// given up. Safe to call any time, also while other questions are out (the newest answer always wins).
    public func refresh() async {
        guard !hubs.isEmpty else { return }
        let list = hubs
        await withTaskGroup(of: Void.self) { g in
            for hub in list {
                g.addTask { await self.ask(hub) }
            }
        }
    }

    /// Something was just sent to [tvID] that changes what it plays or whether it's on: its hub is asked right
    /// away, and again about 1 and 3 seconds later, so the change shows as soon as the TV has made it.
    /// (Everything sent through a `TVClient` does this by itself; LG direct control and Wake-on-LAN call it.)
    public func poke(_ tvID: String) {
        pokeHubs(hubIDs(for: tvID))
    }

    /// Turns [tv] on with Wake-on-LAN (when its network address is known) and watches closely for it to come on.
    public func wake(_ tv: FleetTV) {
        #if canImport(Network)
        // To the TV's own address as well as the broadcast ones. An iPhone can only send to the TV itself (iOS keeps
        // broadcasts for apps Apple allows), and where it last answered is kept only once it has moved: for a TV that
        // never had, the iPhone's Turn On sent nothing that could reach it. Its LG direct control's address (where its
        // network address was read), else where it's paired, then.
        let at = extras[tv.id]?.lastHost ?? extras[tv.id]?.lgHost ?? hub(tv.id)?.connection.base.host
        if let mac = extras[tv.id]?.mac { WakeOnLAN.wake(mac: mac, lastHost: at) }
        #endif
        let until = Date().addingTimeInterval(90)
        for id in hubIDs(for: tv.id) { boostUntil[id] = until }
        poke(tv.id)
    }

    /// A command went out through a `TVClient` (on [hubID], for [routeID]: "this", a linked TV's id, or "all").
    static func commandSent(hub hubID: String, route routeID: String) {
        guard let fleet = running else { return }
        if routeID == "all" { fleet.pokeHubs(fleet.hubs.map(\.id)); return }
        var ids = fleet.hubIDs(for: routeID == "this" ? hubID : routeID)
        if !ids.contains(hubID) && fleet.hubs.contains(where: { $0.id == hubID }) { ids.append(hubID) }
        fleet.pokeHubs(ids)
    }

    /// The hubs that answer for [tvID]: the TV itself when it's paired here, and the hub that links it.
    private func hubIDs(for tvID: String) -> [String] {
        var ids: [String] = []
        if hubs.contains(where: { $0.id == tvID }) { ids.append(tvID) }
        if let t = tv(tvID), !t.hubID.isEmpty, !ids.contains(t.hubID), hubs.contains(where: { $0.id == t.hubID }) { ids.append(t.hubID) }
        return ids.isEmpty ? hubs.map(\.id) : ids
    }

    private func pokeHubs(_ ids: [String]) {
        // Right away (the TV has just been told), then about 1 and 3 seconds after: a TV takes a moment to
        // start a title, pause or switch apps. A newer command starts the count again.
        let waits: [UInt64] = [150_000_000, 850_000_000, 2_000_000_000]
        for id in ids {
            pokes[id]?.cancel()
            pokes[id] = Task { [weak self] in
                for wait in waits {
                    try? await Task.sleep(nanoseconds: wait)
                    if Task.isCancelled { return }
                    guard let self, let hub = self.hub(id) else { return }
                    // Asked on its own, so a newer command calling the count off never calls off a question already
                    // out: its answer is still taken (one that arrives after a newer one is dropped by its number).
                    // Otherwise taps closer together than a hub takes to answer would leave nothing answered at all.
                    await Task { await self.ask(hub) }.value
                }
            }
        }
    }

    /// Asks each hub whose turn it is. One that answers: every 1.5 seconds while the app is in use. One that's
    /// off: every 12 seconds, with a short wait of its own, so it never slows the TVs that are on. Each answer
    /// is shown by itself as it arrives (`take`). Returns when the next hub is due.
    @discardableResult
    private func askDue() -> Date {
        let now = Date()
        // The loop didn't run for a while (the app was suspended, the Mac asleep or napping): the hubs get a moment to
        // answer before what they said before counts as old (`staleAfter`).
        if now.timeIntervalSince(lastTick) > 5 { woke(now) }
        lastTick = now
        guard !hubs.isEmpty else { return .distantFuture }
        // The moment after waking is over: a TV that was answering before and hasn't answered since is off (or out of
        // reach) after all.
        if forgiveUntil != .distantPast, now >= forgiveUntil {
            forgiveUntil = .distantPast
            let gone = hubs.map(\.id).filter { (failures[$0] ?? 0) >= 2 && answers[$0]?.isAnswered == true }
            for id in gone { answers[id] = .unreachable }
            if !gone.isEmpty { rebuild() }
        }
        dropStalePlaying(now)
        let heard = heardTVs()
        #if os(macOS)
        // The Mac's menu bar, widgets and media keys show the TVs even when its window isn't in front.
        let idle: (on: TimeInterval, off: TimeInterval) = (4, 20)
        #else
        let idle: (on: TimeInterval, off: TimeInterval) = (25, 60)
        #endif
        var next = Date.distantFuture
        for listed in hubs {
            var hub = listed
            let boosted = boostUntil[hub.id].map { $0 > now } ?? false
            let answering = (failures[hub.id] ?? 0) < 2 || boosted
            var every: TimeInterval = answering ? (active ? 1.5 : idle.on) : (active ? 12 : idle.off)
            // One still being asked is due again once it has answered (looked at again by then).
            if (inFlight[listed.id] ?? 0) > 0 {
                next = min(next, (askedAt[hub.id] ?? now).addingTimeInterval(every))
                continue
            }
            if !answering, let found = heard[hub.id] {
                // Off until now but just heard on the Wi‑Fi (switched on): ask now, at its new address if it moved.
                if !heardBefore.contains(hub.id) { every = 0 }
                if let moved = moveIfNeeded(hub, to: found) { hub = moved; every = 0 }
            }
            if let at = askedAt[hub.id], now.timeIntervalSince(at) < every - 0.05 {
                next = min(next, at.addingTimeInterval(every))
                continue
            }
            let wait: TimeInterval = answering ? askTimeout(hub) : 4
            let target = hub
            Task { await self.ask(target, timeout: wait) }
            next = min(next, now.addingTimeInterval(every))
        }
        heardBefore = Set(heard.keys)
        return next
    }

    /// A hub whose latest answer has grown too old to go by (`staleAfter`) while one of its TVs still shows what that
    /// answer said was playing: shown again without it, instead of waiting for an answer that may not come (the app
    /// woke and the hub didn't answer within `wakeGrace`, or the hub went quiet without failing yet).
    private func dropStalePlaying(_ now: Date) {
        let limit = staleAfter
        let old = Set(answeredAt.filter { now.timeIntervalSince($0.value) > limit }.keys)
        guard !old.isEmpty, tvs.contains(where: { $0.playing != nil && old.contains($0.hubID) }) else { return }
        rebuild()
    }

    /// How long to wait for a hub that answers: 3 seconds on the home network (6 through an away-from-home link,
    /// more for one that's usually slow), so a TV that just went off is noticed quickly.
    private func askTimeout(_ hub: Hub) -> TimeInterval {
        let base: TimeInterval = Fleet.isHomeAddress(hub.connection.base.host) ? 3 : 6
        return min(10, max(base, (latency[hub.id] ?? 0) * 3))
    }

    /// An address on the home network (private IPv4, link-local, or .local), as opposed to an away-from-home link.
    public nonisolated static func isHomeAddress(_ host: String?) -> Bool {
        guard let host, !host.isEmpty else { return false }
        if host.hasSuffix(".local") { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        let p = parts.compactMap { Int($0) }
        guard parts.count == 4, p.count == 4, p.allSatisfy({ (0...255).contains($0) }) else { return false }
        return p[0] == 10 || (p[0] == 192 && p[1] == 168) || (p[0] == 172 && (16...31).contains(p[1])) || (p[0] == 169 && p[1] == 254)
    }

    /// Woodruff TVs heard on the Wi‑Fi, by id (Bonjour's answer wins over the address scan's).
    private func heardTVs() -> [String: DiscoveredTV] {
        var out: [String: DiscoveredTV] = [:]
        for f in lanFound { out[f.id] = f }
        for f in discovery.found { out[f.id] = f }
        return out
    }

    /// Whether the paired TV [id] answers at the address this device has for it (true until it has missed twice).
    public func isAnswering(_ id: String) -> Bool { hub(id) != nil && (failures[id] ?? 0) < 2 }

    /// The family's list has another home address for the paired TV [id] than this device talks to it at, and this
    /// device's has stopped answering: the TV moved, and wasn't heard here at its new address. It's asked at the
    /// family's address, and if it answers there as that TV, with its key, this device talks to it there from now on.
    /// Never replaces an away-from-home link, or an address that answers.
    @discardableResult
    public func adoptAddress(_ base: URL, forHub id: String) async -> Bool {
        guard let have = hub(id), have.connection.base != base, !isAnswering(id),
              Fleet.isHomeAddress(base.host), Fleet.isHomeAddress(have.connection.base.host) else { return false }
        let trial = TVConnection(base: base, key: have.connection.key)
        guard let status: TVStatus = try? await TVTransport(trial).get("/api/status", timeout: 4), status.id == id,
              let i = hubs.firstIndex(where: { $0.id == id }), !isAnswering(id) else { return false }
        let oldHost = hubs[i].connection.base.host
        hubs[i].connection.base = base
        saveHubs()
        adjustExtras(id) { $0.lastHost = base.host }
        followLG(id, from: oldHost, to: base.host)
        failures[id] = 1
        return true
    }

    /// A paired TV that stopped answering but announces itself at another address on the home network (the
    /// router gave it a new one): talk to it there. Never replaces an away-from-home link.
    private func moveIfNeeded(_ hub: Hub, to found: DiscoveredTV) -> Hub? {
        guard let base = found.base, let newHost = base.host, let oldHost = hub.connection.base.host,
              newHost != oldHost, Fleet.isHomeAddress(oldHost), Fleet.isHomeAddress(newHost),
              let i = hubs.firstIndex(where: { $0.id == hub.id }) else { return nil }
        hubs[i].connection.base = base
        saveHubs()
        adjustExtras(hub.id) { $0.lastHost = newHost }
        followLG(hub.id, from: oldHost, to: newHost)
        failures[hub.id] = 1
        return hubs[i]
    }

    /// The TV [id] answers at [newHost] on the home network now, not at [oldHost]: its LG direct control, connected at
    /// that old address (the TV's own), goes with it. It stayed there: every key on the remote, its mute and Turn Off
    /// went to an address nothing answered at, and failed, until it was connected again by hand. (Never to an
    /// away-from-home link: LG direct control is only ever on the home network.)
    private func followLG(_ id: String, from oldHost: String?, to newHost: String?) {
        guard let oldHost, let newHost, oldHost != newHost, Fleet.isHomeAddress(newHost), extras[id]?.lgHost == oldHost else { return }
        adjustExtras(id) { $0.lgHost = newHost }
    }

    /// Asks one hub for its TVs and shows the answer the moment it arrives.
    private func ask(_ hub: Hub, timeout: TimeInterval? = nil) async {
        askSeq += 1
        let seq = askSeq
        let id = hub.id
        let wait = timeout ?? askTimeout(hub)
        let started = Date()
        askedAt[id] = started
        inFlight[id, default: 0] += 1
        let result: Result<[TVListEntry], Error>
        do {
            let list: TVList = try await TVTransport(hub.connection).get("/api/tvs", timeout: wait)
            result = .success(list.tvs)
        } catch {
            result = .failure(error)
        }
        let left = (inFlight[id] ?? 1) - 1
        inFlight[id] = left > 0 ? left : nil
        // Called off (a newer command started the count again): it says nothing about the TV.
        if Task.isCancelled { return }
        // Asked before the app went to sleep and cut off while it slept: that says nothing about the TV either. Asked
        // again at the loop's next turn (unless it has been already).
        if case .failure = result, started < wokeAt {
            if askedAt[id] == started { askedAt[id] = nil }
            return
        }
        if case .success = result { latency[id] = Date().timeIntervalSince(started) }
        take(result, from: id, seq: seq)
    }

    /// One hub's answer (or its silence), shown at once.
    private func take(_ result: Result<[TVListEntry], Error>, from id: String, seq: Int) {
        guard let i = hubs.firstIndex(where: { $0.id == id }) else { return }   // unpaired meanwhile
        guard seq > (takenSeq[id] ?? 0) else { return }                       // an older question, answered late
        takenSeq[id] = seq
        let now = Date()
        refreshedAt = now
        switch result {
        case .success(let list):
            failures[id] = nil
            answers[id] = .answered(list)
            answeredAt[id] = now
            // How long a film takes to start there, from the TVs' own word about their players: a TV's about itself,
            // and a linked TV's through its hub when it has no answer of its own here.
            for e in list where e.online {
                let tv = e.id == "this" ? id : e.id
                if e.id != "this", hubs.contains(where: { $0.id == tv }) { continue }
                if let start = filmStarts.note(tv: tv, playing: e.playing, at: now) { onFilmStart?(e.name, start) }
            }
            if let me = list.first(where: { $0.id == "this" }), me.name != hubs[i].name {
                hubs[i].name = me.name
                saveHubs()
            }
        case .failure(let error):
            let missed = (failures[id] ?? 0) + 1
            failures[id] = missed
            // One missed answer from a TV that was answering isn't "off" yet: it's asked again right away.
            if missed < 2 && answers[id]?.isAnswered == true { return }
            // Just woken: the Wi‑Fi may only just be back. A TV that was answering before stays as it was and is
            // asked again (`woke`); `askDue` calls it off once the moment is over and it still hasn't answered.
            if now < forgiveUntil && answers[id]?.isAnswered == true { return }
            // It answered, turning this device's key down (reset, or a new key): it needs pairing again, not "off".
            answers[id] = (error as? TVError)?.isRefused == true ? .refused : .unreachable
        }
        rebuild()
    }

    /// Shows every TV from every hub's latest answer (the rules are `FleetMerge.merge`), with the family's
    /// names for them, the alerts they've hidden, and the TVs heard on the Wi‑Fi that aren't paired yet.
    private func rebuild() {
        guard !hubs.isEmpty else { return }
        let now = Date()
        let before = Dictionary(tvs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let limit = staleAfter
        let stale = staleRelays(after: freshFor)
        var all = FleetMerge.merge(hubs: hubs, answers: answers, before: before,
                                   platforms: extras.compactMapValues(\.platform), now: now,
                                   answeredAt: answeredAt, staleAfter: limit, staleRelays: stale)
        var marks: [String: PauseMark] = [:]
        for i in all.indices {
            let id = all[i].id
            // When its hub last heard from it, as that hub's latest answer said. A TV whose hub has stopped answering is
            // listed as it was kept (below: up to `FleetMerge.seenStep` behind), so once it's off it says when it was
            // really last heard instead.
            if answers[all[i].hubID]?.isAnswered == true {
                if let heard = all[i].seen { lastHeard[id] = heard }
            } else if !all[i].online, let heard = lastHeard[id] {
                all[i].seen = heard
            }
            // What a hub last heard from a TV moves with nearly every answer, and is only shown once the TV is off: kept
            // while it stays on (`FleetMerge.steadySeen`), so the list isn't redrawn for it every second or two.
            all[i].seen = FleetMerge.steadySeen(all[i].seen, online: all[i].online, before: before[id])
            // What the TV is, worked out here, is kept here (`learn`): never saved as that TV's details for the family.
            if extras[id]?.platform == nil {
                if let p = guessPlatform(all[i]) { learn(id, p) }
                if all[i].platform == nil, let p = learnedPlatforms[id] { all[i].platform = p }
            }
            // The webOS app calls itself "LG TV" until it's named on the TV: that's Elliot's Room.
            // (Shown under that name; not saved as the TV's details, which a device with none for it would make anew.)
            if extras[id]?.alias == nil && all[i].name.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare("LG TV") == .orderedSame {
                all[i].name = "Elliot’s Room"
            }
            if let alias = extras[id]?.alias, !alias.isEmpty { all[i].name = alias }
            all[i].alertsHidden = all[i].hasAlerts && hiddenAlerts[id] == all[i].alertSignature
            // The pause clock (`FleetMerge.pause(of:)`): kept while the TV is off or only shows nothing because what was
            // heard of it is too old, so a pause still counts from when it began once the TV is heard again.
            let hubID = all[i].hubID
            let heardAt = answeredAt[hubID]
            let tooOld = (heardAt.map { now.timeIntervalSince($0) > limit } ?? false)
                || (!all[i].isHub && stale.contains(FleetMerge.relayKey(hubID, all[i].routeID)))
            let judged = FleetMerge.pause(of: all[i], mark: pauseMarks[id], heardAt: heardAt ?? now, tooOld: tooOld, now: now)
            marks[id] = judged.mark
            all[i].pausedLong = judged.long
        }
        pauseMarks = marks
        all.sort(by: FleetMerge.order)
        // TVs heard on the Wi‑Fi that no paired TV knows: listed so they can be paired.
        let pairedHosts = Set(hubs.compactMap { $0.connection.base.host })
        let heardAll = discovery.found + lanFound.filter { l in !discovery.found.contains { $0.host == l.host } }
        // Where each TV announces itself, remembered on this device (`heardHost`).
        var heardNew = false
        for f in discovery.found where !f.host.isEmpty && heardHosts[f.id] != f.host {
            heardHosts[f.id] = f.host
            heardNew = true
        }
        if heardNew { Saved.save("heardHosts", heardHosts) }
        for f in heardAll where !pairedHosts.contains(f.host) {
            let shown = f.name.caseInsensitiveCompare("LG TV") == .orderedSame ? "Elliot’s Room" : f.name
            if all.contains(where: { $0.id == f.id || $0.name.caseInsensitiveCompare(f.name) == .orderedSame
                || $0.name.caseInsensitiveCompare(shown) == .orderedSame }) { continue }
            var t = FleetTV(id: f.id, name: extras[f.id]?.alias ?? shown, online: true, onScreen: false, playing: nil, version: nil, seen: nil,
                            link: "unpaired", health: nil, hubID: "", routeID: "", platform: extras[f.id]?.platform)
            t.foundAt = f.base
            all.append(t)
        }
        // Away from home, or every TV gone at once (the Wi‑Fi itself is down): the TVs only look gone from here.
        let paired = all.filter { !$0.isUnpaired }
        let quiet = paired.contains(where: { !$0.online }) && (!paired.contains(where: \.online) || !atHome)
        for tv in paired { notifyIfNeeded(tv, was: before[tv.id], quiet: quiet) }
        if all != tvs { tvs = all }
        // Pick another TV only when the chosen one is really gone: not while a hub that may know it hasn't
        // answered yet (a linked TV chosen last time shows up with its hub's first answer).
        let waiting = hubs.contains { answers[$0.id] == nil }
        let known = tvs.contains { $0.id == selectedID && !$0.isUnpaired }
        if selectedID == nil || (!known && !waiting) {
            if let first = tvs.first(where: { !$0.isUnpaired })?.id, first != selectedID { selectedID = first }
        }
    }

    /// The TVs a hub passes on (by `FleetMerge.relayKey`) that it still says are on but hasn't heard from for [limit]
    /// seconds (`FleetMerge.relay`): what they're playing is left out until they're heard again. Counted between that
    /// hub's own answers, on this device's clock. [limit] follows how often the hubs are asked (`freshFor`): in the
    /// background an iPhone asks only every 25 seconds, and a hub sometimes passes on the same `seen` twice (its check
    /// of a TV took longer than it waits, or it reused a round from a moment before), which a shorter limit would take
    /// for a TV it hasn't heard from.
    private func staleRelays(after limit: TimeInterval) -> Set<String> {
        var stale: Set<String> = []
        var kept: [String: RelaySeen] = [:]
        for hub in hubs {
            guard case .answered(let list)? = answers[hub.id], let at = answeredAt[hub.id] else { continue }
            for e in list where e.id != "this" && e.online {
                guard let seen = e.seen else { continue }
                let key = FleetMerge.relayKey(hub.id, e.id)
                let judged = FleetMerge.relay(seen: seen, at: at, kept: relaySeen[key], after: limit)
                kept[key] = judged.kept
                if judged.stale { stale.insert(key) }
            }
        }
        relaySeen = kept
        return stale
    }

    /// Alerts once per problem: a TV's alert is announced again only when what it says changes, and "went
    /// offline" only after two minutes without an answer (a missed check isn't an outage), once per outage.
    /// [quiet]: away from home or the Wi‑Fi is down, so TVs only look gone from here.
    private func notifyIfNeeded(_ tv: FleetTV, was old: FleetTV?, quiet: Bool) {
        // A paired TV's alerts come from its own answer only (another hub's relayed copy can lag behind it, and
        // switching between the two would announce the same problem again and again).
        let ownWord = tv.isHub || !hubs.contains(where: { $0.id == tv.id })
        let hidden = hiddenAlerts[tv.id] == tv.alertSignature
        if !ownWord {
            // Nothing to announce or clear from a relayed copy.
        } else if tv.hasAlerts && !hidden && tv.online {
            if notifiedAlerts[tv.id] != tv.alertSignature {
                notifiedAlerts[tv.id] = tv.alertSignature
                Saved.save("notifiedAlerts", notifiedAlerts)
                if old != nil { onChange?(.needsAttention(tv)) }
            }
        } else if tv.health?.status == "good" && tv.link == "ok" && notifiedAlerts[tv.id] != nil {
            // Only a clean report clears it: a TV that skips one check doesn't re-alert when it answers again.
            notifiedAlerts[tv.id] = nil
            Saved.save("notifiedAlerts", notifiedAlerts)
        }
        if tv.online {
            offlineSince[tv.id] = nil
            offlineNotified.remove(tv.id)
            if offlineAnnounced.remove(tv.id) != nil { onChange?(.cameOnline(tv)) }
        } else if !tv.isUnpaired {
            // Away from home (not on the TVs' Wi‑Fi), or every TV gone at once (the Wi‑Fi itself is down):
            // the TVs only look gone from here, so no "can't reach" and no countdown toward one.
            if quiet {
                offlineSince[tv.id] = nil
                return
            }
            let since = offlineSince[tv.id] ?? Date()
            offlineSince[tv.id] = since
            if old?.online == true || old == nil { return }
            if Date().timeIntervalSince(since) >= 120 && !offlineNotified.contains(tv.id) {
                offlineNotified.insert(tv.id)
                // Switched off is normal and says nothing. Only a TV still on the Wi‑Fi that won't talk to us
                // (or an LG awake but not answering) is worth a notification.
                Task { [weak self] in
                    guard let self, self.atHome, await self.cantTalkToIt(tv) else { return }
                    // It may have answered again while we were checking.
                    guard self.tv(tv.id)?.online == false else { self.offlineNotified.remove(tv.id); return }
                    self.offlineAnnounced.insert(tv.id)
                    self.onChange?(.wentOffline(tv))
                }
            }
        }
    }

    private func guessPlatform(_ tv: FleetTV) -> TVPlatform? {
        if let r = healthReports[tv.id] { return r.platform }
        return nil
    }

    // MARK: Names

    /// Renames [tv] in this app (blank goes back to the name the TV gives itself).
    public func rename(_ tv: FleetTV, to name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        extras[tv.id, default: TVExtras()].alias = clean.isEmpty ? "" : String(clean.prefix(40))
        if let i = tvs.firstIndex(where: { $0.id == tv.id }), !clean.isEmpty { tvs[i].name = String(clean.prefix(40)) }
        rebuild()
        Task { await refresh() }
    }

    // MARK: Hiding alerts

    /// Hides [tv]'s current alerts until something new goes wrong with it.
    public func hideAlerts(_ tv: FleetTV) {
        hiddenAlerts[tv.id] = tv.alertSignature
        Saved.save("hiddenAlerts", hiddenAlerts)
        if let i = tvs.firstIndex(where: { $0.id == tv.id }) { tvs[i].alertsHidden = tvs[i].hasAlerts }
    }

    public func hideAllAlerts() { for tv in tvs where tv.needsAttention { hideAlerts(tv) } }

    public func showAlerts(_ tv: FleetTV) {
        hiddenAlerts[tv.id] = nil
        Saved.save("hiddenAlerts", hiddenAlerts)
        if let i = tvs.firstIndex(where: { $0.id == tv.id }) { tvs[i].alertsHidden = false }
    }

    // MARK: Artwork for what's playing

    /// The hub's Watch home, kept to put pictures on what each TV is playing.
    public private(set) var library: WatchHome? {
        // What was looked up in the one before no longer holds.
        didSet {
            artIndex = nil
            libraryArt = [:]
            keepLibrary()
        }
    }

    /// The library as last read, kept on disk so Watch (and what's-playing pictures) have it the moment the app opens.
    private static var libraryFile: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("watch-home.json")
    }

    private func keepLibrary() {
        guard !Demo.isOn, !restoringLibrary, let library, let file = Self.libraryFile else { return }
        let from = libraryFrom
        DispatchQueue.global(qos: .utility).async {
            struct Kept: Encodable { let from: String?; let home: WatchHome }
            if let d = try? JSONEncoder().encode(Kept(from: from, home: library)) { try? d.write(to: file, options: .atomic) }
        }
    }

    /// Read in the background as the app opens; taken only if nothing newer came from the TVs meanwhile.
    private func restoreLibrary() {
        guard !Demo.isOn, let file = Self.libraryFile else { return }
        Task.detached(priority: .utility) {
            struct Kept: Decodable { let from: String?; let home: WatchHome }
            guard let d = try? Data(contentsOf: file), let k = try? JSONDecoder().decode(Kept.self, from: d) else { return }
            await MainActor.run {
                guard self.library == nil else { return }
                self.libraryFrom = k.from
                // Just read from the file: not written straight back to it.
                self.restoringLibrary = true
                self.library = k.home
                self.restoringLibrary = false
            }
        }
    }
    /// Set while the library read from disk is put in place, so it isn't written back to the same file.
    @ObservationIgnored private var restoringLibrary = false
    /// The library's lists arranged for looking titles up, made the first time they're needed after it changes.
    @ObservationIgnored private var artIndex: ArtIndex?
    /// What the library has for each title asked about ("key|title"), until the library changes: `artwork(for:)` runs
    /// every time anything that shows a picture of what's playing is drawn.
    @ObservationIgnored private var libraryArt: [String: ArtLookup] = [:]

    /// The hub `library` came from (another TV's library may hold other titles than the remote's).
    public private(set) var libraryFrom: String?

    public func refreshLibrary() async {
        // Any TV that answers (the first may be off): the ones answering now first, and among them the hub
        // `hubClient()` goes to, so the library kept is the one Watch shows.
        var order = hubsAnsweringFirst()
        if let id = libraryHubID, answers[id]?.isAnswered == true, let i = order.firstIndex(where: { $0.id == id }), i > 0 {
            order.insert(order.remove(at: i), at: 0)
        }
        for hub in order {
            if let h = try? await TVClient(hub: hub, routeID: "this").watchHome() {
                // Asked again every couple of minutes: taken only when something in it changed, so nothing that shows it
                // is redrawn (nor every title looked up again) for an answer that's the same.
                if h != library { library = h }
                if libraryFrom != hub.id { libraryFrom = hub.id }
                return
            }
        }
    }

    /// The paired TVs, the ones answering now first (so a TV that's off never makes the others wait).
    private func hubsAnsweringFirst() -> [Hub] {
        hubs.filter { (failures[$0.id] ?? 0) < 2 } + hubs.filter { (failures[$0.id] ?? 0) >= 2 }
    }

    /// Pictures found by searching the whole library for a title Home's short lists don't have.
    public private(set) var searchedArt: [String: NowPlayingArtwork] = [:]
    @ObservationIgnored private var artSearches: [String: Date] = [:]

    /// Searches the library on the TVs for [p]'s title and keeps its poster and backdrop.
    private func searchArt(_ p: NowPlaying, key: String) {
        if let at = artSearches[key], at.timeIntervalSinceNow > -300 { return }   // at most every 5 minutes per title
        artSearches[key] = Date()
        let query = String(p.title.split(separator: "·").first ?? Substring(p.title)).trimmingCharacters(in: .whitespaces)
        let hubs = hubsAnsweringFirst()
        Task { [weak self] in
            for hub in hubs {
                guard let r = try? await TVClient(hub: hub, routeID: "this").search(query) else { continue }
                let all = r.movies + r.shows
                let best = all.first { Self.simple($0.title) == key } ?? all.first { key.hasPrefix(Self.simple($0.title)) || Self.simple($0.title).hasPrefix(key) }
                if let t = best, t.poster != nil || t.backdrop != nil {
                    self?.searchedArt[key] = NowPlayingArtwork(poster: t.poster, backdrop: t.backdrop, titleID: t.id)
                }
                return
            }
        }
    }

    /// The poster and backdrop (TV-relative paths or TMDB links) of what [p] is: by its Drive key, else by title.
    public func artwork(for p: NowPlaying?) -> NowPlayingArtwork? {
        guard let p else { return nil }
        // Only Woodruff's own player plays library titles: never guess a YouTube or Netflix title from the library.
        let ours = p.key?.hasPrefix("drive:") == true || (p.app ?? "").lowercased().contains("woodruff")
        guard ours else { return nil }
        // Both read every time, so whatever shows the picture is redrawn when either changes; the looking up in the
        // library itself is done once per title (and again after the library changes).
        let lib = library
        let searched = searchedArt
        let lookup = libraryLookup(p, in: lib)
        if let found = lookup.artwork { return found }
        // Not in Home's short lists: search the whole library once and use what it finds.
        let key = lookup.searchKey
        guard !key.isEmpty else { return nil }
        if let found = searched[key] { return found }
        searchArt(p, key: key)
        return nil
    }

    /// What [lib] has for [p], remembered per title until the library changes, and the key to search for it by.
    private func libraryLookup(_ p: NowPlaying, in lib: WatchHome?) -> ArtLookup {
        let memo = (p.key ?? "") + "|" + p.title
        if let kept = libraryArt[memo] { return kept }
        var index = artIndex
        if index == nil, let lib {
            index = ArtIndex(lib)
            artIndex = index
        }
        let found = ArtLookup(artwork: index?.artwork(for: p), searchKey: ArtIndex.wanted(p))
        libraryArt[memo] = found
        return found
    }

    nonisolated static func simple(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }

    // MARK: Lookup

    public var selected: FleetTV? { tvs.first { $0.id == selectedID } ?? tvs.first }
    public func tv(_ id: String) -> FleetTV? { tvs.first { $0.id == id } }
    public func hub(_ id: String) -> Hub? { hubs.first { $0.id == id } }

    /// The client for [tv]: straight to it when it's paired here, otherwise through the hub that links it.
    public func client(for tv: FleetTV) -> TVClient? {
        if tv.isUnpaired { return nil }
        if let direct = hubs.first(where: { $0.id == tv.id }) {
            // Paired here but not answering this phone, while another TV still reaches it: go through that one.
            if (failures[direct.id] ?? 0) >= 2, let now = self.tv(tv.id), !now.isHub, now.online, let via = hub(now.hubID) {
                return TVClient(hub: via, routeID: now.routeID)
            }
            return TVClient(hub: direct, routeID: "this")
        }
        // The hub that reaches it now (the copy passed in may be from before it moved to another hub).
        let now = self.tv(tv.id) ?? tv
        guard let hub = hub(now.hubID) ?? hub(tv.hubID) else { return nil }
        return TVClient(hub: hub, routeID: hub.id == now.hubID ? now.routeID : tv.routeID)
    }

    /// A client for the selected TV's hub, for features that live on the hub (Memories, files, library, notes).
    /// Without a TV it goes by `libraryHubID`, kept as the TVs change rather than worked out from them here, so a page
    /// that only wants the hub (every picture from the library asks) isn't redrawn whenever any TV's state changes.
    public func hubClient(for tv: FleetTV? = nil) -> TVClient? {
        guard let t = tv else {
            if let id = libraryHubID, let h = hub(id) { return TVClient(hub: h, routeID: "this") }
            return hubs.first.map { TVClient(hub: $0, routeID: "this") }
        }
        if let direct = hubs.first(where: { $0.id == t.id }) { return TVClient(hub: direct, routeID: "this") }
        if let hub = hub(t.hubID) { return TVClient(hub: hub, routeID: "this") }
        return hubs.first.map { TVClient(hub: $0, routeID: "this") }
    }

    /// The hub `hubClient()` goes to: the remote's TV itself when it's paired here, else the hub that links it, else the
    /// first paired (the same one whether it's answering or not: Memories, files, Send and Settings act on it).
    public private(set) var libraryHubID: String?

    /// The paired and linked TVs' names, in the list's order (the Mac's TVs menu): kept apart from `tvs`, and changed
    /// only when a name does, so the menu isn't rebuilt every time a TV's state changes.
    public private(set) var pairedNames: [String] = []

    /// Called whenever the TVs change.
    private func noteTVs() {
        let names = tvs.filter { !$0.isUnpaired }.map(\.name)
        if names != pairedNames { pairedNames = names }
        noteBadge()
        updateLibraryHub()
    }

    /// Called whenever the TVs, the remote's TV or the pairings change. Changes `libraryHubID` only when it's another hub.
    private func updateLibraryHub() {
        var id: String?
        if let t = selected {
            id = hubs.first(where: { $0.id == t.id })?.id ?? hubs.first(where: { $0.id == t.hubID })?.id
        }
        if id == nil { id = hubs.first?.id }
        if id != libraryHubID { libraryHubID = id }
    }

    // MARK: Health

    /// Each value is set only when it's different, so a report that's the same as last time redraws nothing (and
    /// saves nothing).
    public func loadHealth(_ tv: FleetTV) async {
        guard let c = client(for: tv) else { return }
        do {
            let r = try await c.health()
            if healthReports[tv.id] != r { healthReports[tv.id] = r }
            if healthErrors[tv.id] != nil { healthErrors[tv.id] = nil }
            if let p = r.platform {
                learn(tv.id, p)
                // A kind saved for the TV that's wrong is put right where it is; details are never made for a TV here.
                if let saved = extras[tv.id]?.platform, saved != p { adjustExtras(tv.id) { $0.platform = p } }
            }
        } catch let u as HealthUnavailable {
            if let last = u.last, healthReports[tv.id] != last { healthReports[tv.id] = last }
            if healthErrors[tv.id] != u.message { healthErrors[tv.id] = u.message }
        } catch {
            let message = error.localizedDescription
            if healthErrors[tv.id] != message { healthErrors[tv.id] = message }
        }
    }

    public func loadAllHealth() async {
        await withTaskGroup(of: Void.self) { g in
            for tv in tvs { g.addTask { await self.loadHealth(tv) } }
        }
    }

    // MARK: Updates

    public func checkReleases() async {
        if Demo.isOn { latest = Demo.releases; noteBadge(); return }
        let token = githubToken
        // Each value is set only when it's different (this runs every 10 minutes and redraws whatever reads it).
        for p in TVPlatform.allCases {
            do {
                let r = try await ReleaseFeed(token: p == .webOS ? token : nil).latest(p)
                if latest[p] != r { latest[p] = r }
                if releaseErrors[p] != nil { releaseErrors[p] = nil }
            } catch {
                let e = error.localizedDescription
                if releaseErrors[p] != e { releaseErrors[p] = e }
            }
        }
        noteBadge()
        // The LG TVs take a new build by themselves, from a Mac that can reach them (WebOSAutoUpdate): after every
        // look at the releases, so the ten-minute look, Check Now and a token just saved all end with it.
        #if os(macOS)
        Task { await self.updateWebOSTVs() }
        #endif
    }

    public func platform(of tv: FleetTV) -> TVPlatform? { extras[tv.id]?.platform ?? tv.platform ?? learnedPlatforms[tv.id] }

    /// Whether [tv] runs an older version than the newest release for its platform.
    public func isBehind(_ tv: FleetTV) -> Bool {
        guard let p = platform(of: tv), let newest = latest[p]?.version, let mine = WoodruffVersion(tv.version) else { return false }
        return mine < newest
    }

    public var updatesWaiting: Int { tvs.filter(isBehind).count }
    public var attentionCount: Int { tvs.filter(\.needsAttention).count }
    /// Settings' badge: TVs that need attention or an update. Kept, and set only when it changes, so what shows it
    /// isn't redrawn with every change to the TVs.
    public private(set) var settingsBadge = 0

    private func noteBadge() {
        let n = attentionCount + updatesWaiting
        if n != settingsBadge { settingsBadge = n }
    }

    /// Asks one Android TV to update now (it downloads the newest release and installs it once nobody's using it).
    /// [now]: Update was pressed: the TV installs the newest build at once (unless a film is playing).
    public func pushUpdate(_ tv: FleetTV, now: Bool = false) async throws {
        guard let c = client(for: tv) else { throw TVError.notPaired }
        try await c.checkForUpdates(now: now)
    }

    /// Asks every reachable Android TV to update ([now]: at once). Returns (asked, failures).
    public func pushUpdateToAll(now: Bool = false) async -> (Int, [String]) {
        var asked = 0
        var failed: [String] = []
        for tv in tvs where tv.online && !tv.isUnpaired && platform(of: tv) != .webOS {
            do { try await pushUpdate(tv, now: now); asked += 1 } catch { failed.append("\(tv.name): \(error.localizedDescription)") }
        }
        return (asked, failed)
    }

    // MARK: LG direct control

    public func lg(for tv: FleetTV) -> LGRemote? {
        guard let host = extras[tv.id]?.lgHost, !host.isEmpty else { return nil }
        // Asked while pages are drawn: the sign-in is read again only after something was written to the Keychain.
        let generation = Keychain.generation
        if let r = lgRemotes[tv.id], r.host == host, lgKeysRead[tv.id] == generation { return r }
        let read = Keychain.read("lg.\(tv.id)")
        // Couldn't be read just now (a locked keychain): the connection there stays, not replaced by one without it.
        if !read.ok, let r = lgRemotes[tv.id], r.host == host { return r }
        lgKeysRead[tv.id] = read.ok ? generation : nil
        // The saved sign-in may have just arrived from another family device: connect afresh with it.
        let key = read.value
        if let r = lgRemotes[tv.id], r.host == host, lgKeys[tv.id] == key { return r }
        if let old = lgRemotes[tv.id] { Task { await old.disconnect() } }
        let r = LGRemote(host: host, clientKey: key, onNewKey: keepLGKey(tv.id, host: host))
        lgRemotes[tv.id] = r
        lgKeys[tv.id] = key
        return r
    }

    /// A key an LG TV gave one of its connections outside Connect (it forgot this device and asked "Allow?" again on a
    /// key press, or no key was kept here yet): kept as the TV's sign-in, so it isn't asked for again when the app next
    /// opens (and the family's other devices get it too). Not for a connection the TV's address has moved on from.
    private func keepLGKey(_ id: String, host: String) -> @Sendable (String) -> Void {
        { [weak self] key in
            Task { @MainActor in
                guard let self, self.extras[id]?.lgHost == host, self.lgRemotes[id]?.host == host else { return }
                // Noted first: the write below makes `lg(for:)` read the key again, and the same key keeps this connection.
                self.lgKeys[id] = key
                Keychain.set(key, for: "lg.\(id)")
            }
        }
    }

    /// Connects LG direct control (the TV asks "Allow?" the first time) and keeps its address and key, once the TV has
    /// taken the connection. (The address was kept first: one that never connected (mistyped, the TV off, Allow not
    /// pressed) showed as Connected on the TV's page, and every key on the remote went there and failed.)
    public func connectLG(_ tv: FleetTV, host: String) async throws {
        // The connection there before is closed, not just let go of (it kept its socket open).
        if let old = lgRemotes[tv.id] { Task { await old.disconnect() } }
        lgRemotes[tv.id] = nil
        let r = LGRemote(host: host, clientKey: Keychain.get("lg.\(tv.id)"), onNewKey: keepLGKey(tv.id, host: host))
        let key = try await r.connect()
        extras[tv.id, default: TVExtras()].lgHost = host
        extras[tv.id]?.platform = .webOS
        Keychain.set(key, for: "lg.\(tv.id)")
        if let other = lgRemotes[tv.id], other !== r { Task { await other.disconnect() } }
        lgRemotes[tv.id] = r
        lgKeys[tv.id] = key
        if let mac = await r.macAddress() { extras[tv.id]?.mac = mac }
    }

    public func forgetLG(_ tv: FleetTV) {
        extras[tv.id]?.lgHost = nil
        Keychain.set(nil, for: "lg.\(tv.id)")
        // The connection itself, taken now (the task runs after it's been let go of here).
        if let old = lgRemotes[tv.id] { Task { await old.disconnect() } }
        lgRemotes[tv.id] = nil
        lgKeysRead[tv.id] = nil
    }

    // MARK: Phone identity

    @discardableResult
    func hello(_ hub: Hub) async throws -> JSONValue {
        let r = try await TVTransport(hub.connection).post("/api/phone/hello", ["id": phone.id, "name": phone.name, "alerts": phone.alerts])
        // Earlier installs of this app registered under other ids with this device's name: forget those copies. Only
        // ones from before each device kept a lasting id ("ios-…", "mac-…"): every iPhone, iPad and Apple TV goes by
        // "iPhone", so one with a lasting id is another of the family's devices, and forgetting it took its
        // announcements with it each time this one opened.
        let t = TVTransport(hub.connection)
        for p in r["phones"]?.array ?? [] {
            guard let id = p["id"]?.string, id != phone.id, !id.hasPrefix("ios-"), !id.hasPrefix("mac-"),
                  p["name"]?.string?.caseInsensitiveCompare(phone.name) == .orderedSame else { continue }
            _ = try? await t.post("/api/phone/delete", ["id": id])
        }
        return r
    }

    public func sayHelloEverywhere() async {
        for h in hubs { _ = try? await hello(h) }
    }

    // MARK: Inbox (announcements to this phone)

    public private(set) var recentMessages: [InboxMessage] = Saved.load("recentMessages", as: [InboxMessage].self) ?? []
    /// Where each hub's messages were read up to, and the ids already shown: read once, saved as they change.
    @ObservationIgnored private var inboxCursors: [String: InboxCursor] = Saved.load("inboxCursors", as: [String: InboxCursor].self) ?? [:]
    @ObservationIgnored private var inboxSeen: [String] = Saved.load("inboxSeen", as: [String].self) ?? []

    /// Asks each hub for messages kept for this phone, showing only new ones (by seq within an epoch, and by id).
    public func pollInbox() async {
        // Every hub that's answering, all at once (one that's off would only make the others wait; it's asked
        // again once it's back, and keeps what it has for this phone until then).
        let asking = hubs.filter { (failures[$0.id] ?? 0) < 2 }
        guard !asking.isEmpty else { return }
        let startCursors = inboxCursors
        let phoneID = phone.id
        var boxes: [String: Inbox] = [:]
        await withTaskGroup(of: (String, Inbox?).self) { g in
            for hub in asking {
                let cur = startCursors[hub.id] ?? InboxCursor()
                g.addTask {
                    let box = try? await TVClient(hub: hub, routeID: "this").inbox(phone: phoneID, after: cur.after, epoch: cur.epoch, timeout: 6)
                    return (hub.id, box)
                }
            }
            for await (id, box) in g {
                if let box { boxes[id] = box }
            }
        }
        let savedCursors = inboxCursors
        var cursors = savedCursors
        let savedSeen = inboxSeen
        var seenOrder = savedSeen
        var seen = Set(seenOrder)
        let shownBefore = recentMessages
        // Worked out on a copy and put back once: each insert into the observed list redrew what shows it.
        var messages = shownBefore
        for hub in asking {
            guard let box = boxes[hub.id] else { continue }
            var cur = cursors[hub.id] ?? InboxCursor()
            if box.epoch != cur.epoch { cur.after = 0; cur.epoch = box.epoch }
            let first = cursors[hub.id] == nil
            for m in box.messages where m.seq > (cur.after ?? 0) && !seen.contains(m.id) {
                seen.insert(m.id)
                seenOrder.append(m.id)
                messages.insert(m, at: 0)
                // The first poll after pairing only catches up; it doesn't replay old messages as alerts.
                if !first { onChange?(.message(m, from: hub.name)) }
            }
            cur.after = max(cur.after ?? 0, box.seq ?? 0)
            cursors[hub.id] = cur
        }
        let weekAgo = (Date().timeIntervalSince1970 - 7 * 86400) * 1000
        // Each message once (the same one can come from two TVs, or again after the seen list was trimmed).
        var once = Set<String>()
        let kept = Array(messages.filter { ($0.at ?? weekAgo + 1) > weekAgo && once.insert("\($0.id)|\($0.title)|\($0.at ?? 0)").inserted }.prefix(20))
        if kept != recentMessages { recentMessages = kept }
        // Written only when something changed (this runs every few seconds).
        if recentMessages != shownBefore { Saved.save("recentMessages", recentMessages) }
        if seenOrder != savedSeen {
            inboxSeen = Array(seenOrder.suffix(200))
            Saved.save("inboxSeen", inboxSeen)
        }
        if cursors != savedCursors {
            inboxCursors = cursors
            Saved.save("inboxCursors", cursors)
        }
    }

    // MARK: Messages

    /// Something went wrong: the error's own words.
    public func show(_ error: Error) {
        banner = Banner(title: "Couldn't do that", message: error.localizedDescription, isAlert: true)
    }

    /// A result that only confirms ("Sent", "Paired"). The Mac shows these quietly (see `Banner.isAlert`).
    public func say(_ title: String, _ message: String) {
        banner = Banner(title: title, message: message)
    }

    /// Something that went wrong, or needs doing, in the app's own words, or an answer that was asked for: shown
    /// until it's dismissed, on the Mac too.
    public func alert(_ title: String, _ message: String) {
        banner = Banner(title: title, message: message, isAlert: true)
    }

    public var menuBarSymbol: String {
        if hubs.isEmpty { return "tv" }
        if tvs.contains(where: { $0.needsAttention }) { return "exclamationmark.triangle" }
        if tvs.contains(where: { $0.nowPlaying?.isPlaying == true }) { return "play.tv" }
        return "tv"
    }
}

/// One hub's latest answer to "which TVs, doing what?".
enum HubAnswer: Equatable, Sendable {
    case answered([TVListEntry])
    /// It didn't answer (twice in a row): it's off, or out of reach from here.
    case unreachable
    /// It answered, but turned this device's pairing key down (HTTP 401 or 403): it needs pairing again here.
    case refused

    var isAnswered: Bool {
        if case .answered = self { return true }
        return false
    }
}

/// How the TVs every hub reports become one list. Kept apart from `Fleet` so the rules can be tested, and so the
/// list comes out the same whatever order the hubs answered in.
enum FleetMerge {
    /// - A TV's own answer (a hub, about itself) beats one relayed by another hub; a relayed answer saying it's on
    ///   beats one saying it's off, and one whose word about what's playing is believed (below) beats one whose isn't;
    ///   between equals, the hub paired first wins.
    /// - A hub that doesn't answer keeps what was known of it, marked off, and so do the linked TVs only it knew
    ///   (unless another hub reports them). A hub that turned this device's key down is marked off too, and as
    ///   needing pairing again (`pairingRefused`). A hub not heard from yet keeps what was shown before.
    /// - Only a TV that's on is playing anything, or showing anything on screen. What it plays is believed only from
    ///   a fresh answer: none when its hub's answer arrived more than [staleAfter] seconds before [now] (by
    ///   [answeredAt]), nor when that hub passes it on without having heard from it lately ([staleRelays], by
    ///   `relayKey`). Either way the TV itself stays as it was (on, its version, its health).
    /// - What's playing is laid over what was shown before (`NowPlaying.smoothed`), so progress never jumps back.
    static func merge(hubs: [Hub], answers: [String: HubAnswer], before: [String: FleetTV],
                      platforms: [String: TVPlatform], now: Date,
                      answeredAt: [String: Date] = [:], staleAfter: TimeInterval = .infinity,
                      staleRelays: Set<String> = []) -> [FleetTV] {
        var merged: [String: FleetTV] = [:]
        var rank: [String: Int] = [:]
        for hub in hubs {
            guard case .answered(let list)? = answers[hub.id] else { continue }
            let fresh = answeredAt[hub.id].map { now.timeIntervalSince($0) <= staleAfter } ?? true
            for e in list {
                let realID = e.id == "this" ? hub.id : e.id
                let believed = e.online && fresh && (e.id == "this" || !staleRelays.contains(relayKey(hub.id, e.id)))
                // One of the TV's inputs on screen (an HDMI box) isn't something playing (`NowPlaying.isInput`): left
                // out here, so the bar, the remote, the widgets and the Lock Screen all show the TV as on, playing nothing.
                let playing = believed ? e.playing.flatMap { $0.isInput ? nil : $0 } : nil
                let tv = FleetTV(id: realID, name: e.name, online: e.online, onScreen: e.online && (e.onScreen ?? false),
                                 playing: playing, version: e.version, seen: e.seen, link: e.link ?? "ok",
                                 health: e.health, hubID: hub.id, routeID: e.id, platform: platforms[realID])
                // Two hubs passing on the same TV: the one that has heard from it lately, and answered lately, wins.
                let r = tv.isHub ? 4 : (tv.online ? (believed ? 3 : 2) : 1)
                if let have = rank[realID], have >= r { continue }
                merged[realID] = tv
                rank[realID] = r
            }
        }
        for hub in hubs {
            let answer = answers[hub.id]
            if answer?.isAnswered == true { continue }
            let down = answer == .unreachable || answer == .refused
            if merged[hub.id] == nil {
                var tv = before[hub.id] ?? FleetTV(id: hub.id, name: hub.name, online: false, onScreen: false, playing: nil, version: nil,
                                                   seen: nil, link: "ok", health: nil, hubID: hub.id, routeID: "this",
                                                   platform: platforms[hub.id])
                tv.hubID = hub.id
                tv.routeID = "this"
                tv.foundAt = nil
                if down { tv.online = false; tv.onScreen = false; tv.playing = nil; tv.pairingRefused = answer == .refused ? true : nil }
                merged[hub.id] = tv
            }
            for old in before.values where old.hubID == hub.id && old.id != hub.id && !old.isUnpaired && merged[old.id] == nil {
                var t = old
                if down { t.online = false; t.onScreen = false; t.playing = nil }
                merged[old.id] = t
            }
        }
        for (id, tv) in merged {
            guard let p = tv.playing else { continue }
            merged[id]?.playing = p.smoothed(after: before[id]?.playing, now: now)
        }
        return merged.values.sorted(by: order)
    }

    /// Paired TVs first, then by name (then by id, so two with the same name never swap places between answers).
    static func order(_ a: FleetTV, _ b: FleetTV) -> Bool {
        if a.isHub != b.isHub { return a.isHub }
        let byName = a.name.localizedStandardCompare(b.name)
        if byName != .orderedSame { return byName == .orderedAscending }
        return a.id < b.id
    }

    // MARK: When a TV was last heard

    /// How much later (ms) a TV that stays on has to have been heard before its `seen` moves on.
    static let seenStep: Double = 30_000

    /// A TV's `seen` as the list keeps it: [new] (from the answer just merged), except for a TV that was on before
    /// ([old]) and still is ([online]): then what was kept, until [new] is `seenStep` or more later. A hub passes on a
    /// new `seen` for each linked TV with nearly every answer, while it only shows once the TV is off ("Seen 2 minutes
    /// ago"), so following each one redrew everything that lists the TVs every second or two.
    static func steadySeen(_ new: Double?, online: Bool, before old: FleetTV?) -> Double? {
        guard online, let old, old.online, let kept = old.seen else { return new }
        guard let new, new - kept >= seenStep else { return kept }
        return new
    }

    // MARK: TVs a hub passes on

    /// One TV as one hub passes it on ("hub|TV"): the same TV can be passed on by several hubs, each hearing from it
    /// on its own.
    static func relayKey(_ hubID: String, _ tvID: String) -> String { hubID + "|" + tvID }

    /// How long a hub can keep passing on the same `seen` for a TV (by its own answers, on this device's clock)
    /// before it counts as not having heard from that TV lately, when nothing else is said (the app passes how often
    /// it asks the hubs: `Fleet.freshFor`). A hub hears from each linked TV every few seconds.
    static let relayStaleAfter: TimeInterval = 20

    /// [seen], as a hub's answer that arrived at [at] passes it on, laid over what was [kept] from its answers before:
    /// the value to keep, and whether that hub has now gone [after] seconds of answers without hearing from the TV
    /// (its `seen` hasn't moved), so what it says the TV plays is out of date.
    static func relay(seen: Double, at: Date, kept: RelaySeen?, after: TimeInterval = relayStaleAfter) -> (kept: RelaySeen, stale: Bool) {
        let r = kept.flatMap { $0.seen == seen ? $0 : nil } ?? RelaySeen(seen: seen, since: at)
        return (r, at.timeIntervalSince(r.since) >= after)
    }

    // MARK: Pauses

    /// How long a pause lasts before what's paused no longer counts as playing (its picture and title go): a minute,
    /// so a TV that's been left paused never keeps showing a movie as if it were on.
    static let pausedLongAfter: TimeInterval = 60
    /// Another title that turns up paused within this many seconds of one heard playing, and no further in than
    /// `nextTitleStart` (ms), is the next episode or video loading, not a session left behind: Android counts only
    /// "playing" as playing, so the next item reads as paused while it buffers.
    static let nextTitleWithin: TimeInterval = 60
    static let nextTitleStart: Double = 60_000

    /// The pause rule, one source of truth (`FleetTV.pausedLong`): whether [playing] has been paused so long it no
    /// longer counts as playing, and the mark to keep for the next answer ([heardAt]: when the answer saying what it
    /// plays arrived).
    /// - A pause this app sees happen (the same title was playing at the answer before) counts from when it began: where
    ///   the title stopped moving, from the last answer that heard it playing (played on for as long as its position
    ///   moved, never past now). So a pause made just before the app looks again keeps its minute after any
    ///   sleep, and one made long before counts from then. Without positions to go by, from that last playing answer.
    /// - A title first seen already paused (the app just launched, or an Android session left behind after YouTube,
    ///   Netflix or Plex closed) counts as paused long at once, also when another title was on before it, except the
    ///   next one loading (`nextTitleWithin`), whose clock starts now.
    /// - Nothing playing clears the mark; another title starts afresh.
    static func pause(_ playing: NowPlaying?, mark: PauseMark?, heardAt: Date, now: Date) -> (mark: PauseMark?, long: Bool) {
        guard let p = playing else { return (nil, false) }
        let title = (p.key ?? "") + "|" + p.title
        if p.isPlaying {
            return (PauseMark(title: title, playing: true, playedAt: heardAt, position: p.estimatedPosition(at: heardAt)), false)
        }
        guard let kept = mark, kept.title == title else {
            // Right after another title that was playing, near its start: the next one loading. Anything else: left behind.
            let lastPlayed = mark.flatMap { $0.playing ? $0.playedAt : nil }
            let loading = lastPlayed.map { heardAt.timeIntervalSince($0) <= nextTitleWithin } == true && (p.position ?? 0) <= nextTitleStart
            return (PauseMark(title: title, playing: false, pausedAt: loading ? heardAt : nil), !loading)
        }
        var m = kept
        if m.playing, let played = m.playedAt {
            var since = played
            if let was = m.position, let pos = p.position, pos > was {
                since = min(heardAt, played.addingTimeInterval((pos - was) / 1000))
            }
            m.playing = false
            m.pausedAt = since
        }
        guard let since = m.pausedAt else { return (m, true) }
        return (m, now.timeIntervalSince(since) >= pausedLongAfter)
    }

    /// The pause rule for [tv] as the list is rebuilt (`pause`), except while it's off, or shows nothing only because
    /// what was heard of it is too old ([tooOld]): then its clock is kept as it was, so a pause still counts from when
    /// it began once the TV is heard again (one missed check, a hub that went quiet, the app asleep). Only "on, nothing
    /// playing" or another title replaces it; a title left paused before the TV went off is still long over after.
    static func pause(of tv: FleetTV, mark: PauseMark?, heardAt: Date, tooOld: Bool, now: Date) -> (mark: PauseMark?, long: Bool) {
        if !tv.online || (tv.playing == nil && tooOld) { return (mark, false) }
        return pause(tv.playing, mark: mark, heardAt: heardAt, now: now)
    }
}

/// A TV as one hub passes it on: its `seen` in that hub's answers, and when the answer that first carried that value
/// arrived (on this device's clock).
struct RelaySeen: Equatable, Sendable {
    var seen: Double
    var since: Date
}

/// What a TV was last heard doing with a title, for the pause rule (`FleetMerge.pause`).
struct PauseMark: Equatable, Sendable {
    /// The title as "key|title", so another title starts afresh.
    var title: String
    /// Whether it was playing at the last answer (a paused one after that is a pause seen happening).
    var playing: Bool
    /// The last time it was heard playing; nil when it was already paused the first time it was seen.
    var playedAt: Date? = nil
    /// Where it was then (ms, at `playedAt`), to tell from where it paused how long it played on after.
    var position: Double? = nil
    /// When the pause began, as near as this app can tell; nil for a title first seen already paused.
    var pausedAt: Date? = nil
}

public struct NowPlayingArtwork: Hashable, Sendable {
    public var poster: String?
    public var backdrop: String?
    public var titleID: String?
}

/// The library's lists (Continue Watching, and Home's featured, recent, movies and shows) arranged for finding what a
/// TV is playing in them: the same answers as looking through them in order, without doing that on every redraw.
struct ArtIndex {
    private var titlesByID: [String: Title] = [:]
    private var continueByKey: [String: ContinueItem] = [:]
    private var continueNames: [(name: String, item: ContinueItem)] = []
    private var titleNames: [(name: String, title: Title)] = []

    init(_ lib: WatchHome) {
        let titles = (lib.featured ?? []) + (lib.recent ?? []) + (lib.movies?.items ?? []) + (lib.shows?.items ?? [])
        // The first of each, as looking through the lists in order finds it.
        for t in titles where titlesByID[t.id] == nil { titlesByID[t.id] = t }
        let cont = lib.continue ?? []
        for c in cont where continueByKey[c.key] == nil { continueByKey[c.key] = c }
        continueNames = cont.map { (name: Fleet.simple($0.name), item: $0) }
        titleNames = titles.map { (name: Fleet.simple($0.title), title: $0) }
    }

    /// [p]'s title as it's looked for by name: the part before any "·", only its letters and digits, lowercased.
    static func wanted(_ p: NowPlaying) -> String {
        Fleet.simple(String(p.title.split(separator: "·").first ?? Substring(p.title)))
    }

    /// By its Drive key (Continue Watching, then the lists), else by its name (the same order).
    func artwork(for p: NowPlaying) -> NowPlayingArtwork? {
        func title(_ id: String?) -> Title? { id.flatMap { titlesByID[$0] } }
        if let key = p.key, let c = continueByKey[key] {
            let t = title(c.titleId)
            return NowPlayingArtwork(poster: c.poster ?? t?.poster, backdrop: t?.backdrop, titleID: c.titleId)
        }
        if let key = p.key, key.hasPrefix("drive:"), let t = titlesByID[String(key.dropFirst("drive:".count))] {
            return NowPlayingArtwork(poster: t.poster, backdrop: t.backdrop, titleID: t.id)
        }
        let want = Self.wanted(p)
        guard !want.isEmpty else { return nil }
        if let c = continueNames.first(where: { $0.name == want || want.hasPrefix($0.name) })?.item {
            let t = title(c.titleId)
            return NowPlayingArtwork(poster: c.poster ?? t?.poster, backdrop: t?.backdrop, titleID: c.titleId)
        }
        if let t = titleNames.first(where: { $0.name == want || want.hasPrefix($0.name) })?.title {
            return NowPlayingArtwork(poster: t.poster, backdrop: t.backdrop, titleID: t.id)
        }
        return nil
    }
}

/// What the library has for one title, and the key to search the whole library for it by.
struct ArtLookup {
    var artwork: NowPlayingArtwork?
    var searchKey: String
}

public enum FleetEvent: Sendable {
    case message(InboxMessage, from: String)
    case wentOffline(FleetTV)
    case cameOnline(FleetTV)
    case needsAttention(FleetTV)
}

/// How this phone or Mac introduces itself to the TVs (Announcements pick phones by name).
public struct PhoneIdentity: Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var alerts: Bool

    @MainActor static func load() -> PhoneIdentity {
        var p = Saved.load("phone", as: PhoneIdentity.self)
            ?? PhoneIdentity(id: "", name: defaultName, alerts: false)
        // The device's own id, so a reinstall or a new build is the same phone to the TVs, not another one.
        if let stable = stableID { p.id = stable }
        else if p.id.isEmpty { p.id = UUID().uuidString.lowercased() }
        return p
    }

    static var defaultName: String {
        #if os(macOS)
        return Host.current().localizedName ?? "Mac"
        #else
        return "iPhone"
        #endif
    }

    @MainActor static var stableID: String? {
        #if os(macOS)
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        defer { IOObjectRelease(service) }
        guard service != 0, let uuid = IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String else { return nil }
        return "mac-" + uuid.lowercased()
        #elseif canImport(UIKit)
        return UIDevice.current.identifierForVendor.map { "ios-" + $0.uuidString.lowercased() }
        #else
        return nil
        #endif
    }

    func save() { Saved.save("phone", self) }
}

struct InboxCursor: Codable, Equatable, Sendable {
    var after: Int?
    var epoch: String?
}
