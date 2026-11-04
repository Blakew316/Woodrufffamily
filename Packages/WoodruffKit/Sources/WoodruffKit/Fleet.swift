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
public struct FleetTV: Identifiable, Hashable, Sendable {
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
    /// What it shows is paused, and has been for 5 minutes, or was already paused when this app first saw it (an
    /// Android session left behind after leaving YouTube, Netflix or Plex): it no longer counts as playing
    /// (`FleetMerge.pause`).
    public var pausedLong = false

    /// What the TV is playing right now, the one thing every picture, title and player goes by: nothing while it's
    /// off or not paired, and nothing once a pause has gone on too long (`pausedLong`). `playing` is what the TV
    /// last said, for its controls.
    public var nowPlaying: NowPlaying? {
        guard online, !isUnpaired, let p = playing, p.isPlaying || !pausedLong else { return nil }
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
    public init(title: String, message: String) { self.title = title; self.message = message }
}

/// Everything the app knows about the family's TVs, and every action on them.
@Observable @MainActor
public final class Fleet {
    public static let shared = Fleet()

    public private(set) var hubs: [Hub] = []
    public private(set) var tvs: [FleetTV] = []
    public var extras: [String: TVExtras] = [:] { didSet { Saved.save("extras", extras) } }

    /// Reads names, TV details and hidden alerts again (after another of the family's devices changed them).
    public func reloadSynced() {
        if let e = Saved.load("extras", as: [String: TVExtras].self), e != extras { extras = e }
        let h = Saved.load("hiddenAlerts", as: [String: String].self) ?? [:]
        if h != hiddenAlerts { hiddenAlerts = h }
        rebuild()   // new names and hidden alerts show at once
        Task { await refresh() }
    }
    /// The TV the remote, Send and Memories act on.
    public var selectedID: String? { didSet { UserDefaults.standard.set(selectedID, forKey: "selectedTV") } }
    public var banner: Banner?
    /// The remote sends to every TV that's on.
    public var remoteAll = false
    /// Mac: the remote's sidebar is out.
    public var remotePanel = false
    public private(set) var refreshedAt: Date?
    public private(set) var refreshing = false
    public private(set) var latest: [TVPlatform: Release] = [:]
    public private(set) var releaseErrors: [TVPlatform: String] = [:]
    public private(set) var healthReports: [String: HealthReport] = [:]
    public private(set) var healthErrors: [String: String] = [:]
    /// Events for notifications: a TV went offline, came back, needs attention.
    public var onChange: ((FleetEvent) -> Void)?

    public var phone = PhoneIdentity.load() { didSet { phone.save() } }
    public var githubToken: String? {
        get { Keychain.get("github.token") }
        set { Keychain.set(newValue, for: "github.token"); Task { await checkReleases() } }
    }

    /// TV id → the alerts hidden for it (their signature).
    public private(set) var hiddenAlerts: [String: String] = Saved.load("hiddenAlerts", as: [String: String].self) ?? [:]
    private let discovery = TVDiscovery()
    /// TVs found by asking every address on the home network (for those whose announcement doesn't arrive).
    public private(set) var lanFound: [DiscoveredTV] = []
    private var lanScannedAt: Date?

    /// Looks for Woodruff TVs on the home network now (also runs every 10 minutes by itself).
    public func scanNetwork() async {
        #if canImport(Darwin)
        lanScannedAt = Date()
        lanFound = await LANScan.find()
        await refresh()
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
        let mine = LANScan.prefixes()
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
    private var loop: Task<Void, Never>?
    @ObservationIgnored private var inboxLoop: Task<Void, Never>?
    @ObservationIgnored private var slowLoop: Task<Void, Never>?
    private var lgRemotes: [String: LGRemote] = [:]
    /// The sign-in each LG connection was made with.
    @ObservationIgnored private var lgKeys: [String: String] = [:]

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
    @ObservationIgnored private var refreshCount = 0

    /// The Fleet the app runs: told about every command sent through a `TVClient` (see `TVClient.changed`).
    /// Nil in widgets and anywhere `start()` wasn't called.
    static var running: Fleet?

    init() {
        // What each TV last played was once kept to picture TVs that had stopped; nothing is pictured unless it's
        // playing now, so the old copy goes.
        UserDefaults.standard.removeObject(forKey: "lastPlaying")
        if Demo.isOn {
            Demo.register()
            hubs = [Demo.hub]
            extras = ["tv-kitchen": { var e = TVExtras(); e.platform = .webOS; e.lgHost = nil; return e }(),
                      "tv-living": { var e = TVExtras(); e.platform = .android; return e }(),
                      "tv-den": { var e = TVExtras(); e.platform = .android; return e }()]
            phone = PhoneIdentity(id: "demo-phone-0001", name: "Blake’s iPhone", alerts: true)
            selectedID = "tv-living"
            latest = Demo.releases
            return
        }
        hubs = Fleet.loadPairings()
        extras = Saved.load("extras", as: [String: TVExtras].self) ?? [:]
        selectedID = UserDefaults.standard.string(forKey: "selectedTV")
        tvs = hubs.map { FleetTV(id: $0.id, name: $0.name, online: false, onScreen: false, playing: nil, version: nil, seen: nil, link: "ok", health: nil, hubID: $0.id, routeID: "this", platform: extras[$0.id]?.platform) }
    }

    /// Pairings are kept in three places so no update, reinstall or re-signed build ever signs the family out:
    /// the app's settings (with their keys: a re-signed Mac build can't read the Keychain items of the one
    /// before), the Keychain as one record (it outlives deleting and reinstalling the app on iPhone), and a
    /// copy the app can hand to its widgets (`pairingBackup`, also used to restore).
    private func saveHubs() {
        if Demo.isOn { return }
        let good = hubs.filter { !$0.connection.key.isEmpty }
        Saved.save("pairings", good)
        UserDefaults.standard.removeObject(forKey: "hubs") // the old split copy, now merged into "pairings"
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
        add(Saved.load("pairings", as: [Hub].self))
        if let json = Keychain.get("pairings"), let list = try? JSONDecoder().decode([Hub].self, from: Data(json.utf8)) { add(list) }
        add(Saved.load("hubs", as: [Hub].self)) // before this version: keys were only in the Keychain
        for (id, h) in found where h.connection.key.isEmpty {
            if let k = Keychain.get("hub.\(id)") { found[id]?.connection.key = k }
        }
        return found.values.filter { !$0.connection.key.isEmpty }.sorted { $0.addedAt < $1.addedAt }
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
        if !Demo.isOn { discovery.start() }
        // What every TV is doing: each hub on its own clock (see `askDue`), never waiting on the others.
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.askDue()
                try? await Task.sleep(nanoseconds: 500_000_000)
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
        // releases (every 10) and looking for TVs across the Wi‑Fi (every 10).
        slowLoop = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                guard let self else { return }
                if tick % 4 == 0 { await self.refreshLibrary() }
                if tick % 20 == 0 { await self.checkReleases() }
                let scanDue = self.lanScannedAt.map({ Date().timeIntervalSince($0) > 600 }) ?? true
                if !Demo.isOn && scanDue { await self.scanNetwork() }
                tick += 1
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
        Task { for h in hubs { _ = try? await hello(h) } }
    }

    public func setActive(_ on: Bool) {
        active = on
        guard on else { return }
        // Back from the background: what the TVs said before it may be long over, so it goes at once (answers older
        // than `staleAfter` say nothing is playing), and each TV shows what it's doing as soon as its hub answers.
        rebuild()
        Task { await refresh() }
    }

    /// How old a hub's answer may be before what it says is playing isn't believed any more: a little over the time
    /// a hub that has stopped answering takes to count as off while the app is in use, longer while it isn't (the
    /// hubs are asked less often then).
    private var staleAfter: TimeInterval { active ? 20 : 75 }

    // MARK: Pairing

    /// Pairs with the TV at [connection]: asks who it is, keeps it, says hello as this phone.
    @discardableResult
    public func pair(_ connection: TVConnection) async throws -> Hub {
        let status: TVStatus = try await TVTransport(connection).get("/api/status")
        let hub = Hub(id: status.id, name: status.name, connection: connection)
        hubs.removeAll { $0.id == hub.id }
        hubs.append(hub)
        failures[hub.id] = nil
        saveHubs()
        if extras[hub.id] == nil { extras[hub.id] = TVExtras() }
        extras[hub.id]?.lastHost = connection.base.host
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
            do { let h = try await pair(c); banner = Banner(title: "Paired", message: "\(h.name) is connected.") } catch { show(error) }
        }
    }

    // MARK: Refresh

    /// Asks every hub for its TVs now (each hub answers for itself and its linked TVs). Each answer shows the
    /// moment it arrives, so a TV that's off never holds up the others; returns once every hub has answered or
    /// given up. Safe to call any time, also while other questions are out (the newest answer always wins).
    public func refresh() async {
        guard !hubs.isEmpty else { return }
        refreshCount += 1
        refreshing = true
        defer {
            refreshCount -= 1
            if refreshCount <= 0 { refreshCount = 0; refreshing = false }
        }
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
        if let mac = extras[tv.id]?.mac { WakeOnLAN.wake(mac: mac, lastHost: extras[tv.id]?.lastHost) }
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
                    await self.ask(hub)
                }
            }
        }
    }

    /// Asks each hub whose turn it is. One that answers: every 1.5 seconds while the app is in use. One that's
    /// off: every 12 seconds, with a short wait of its own, so it never slows the TVs that are on. Each answer
    /// is shown by itself as it arrives (`take`).
    private func askDue() {
        guard !hubs.isEmpty else { return }
        let now = Date()
        dropStalePlaying(now)
        let heard = heardTVs()
        #if os(macOS)
        // The Mac's menu bar, widgets and media keys show the TVs even when its window isn't in front.
        let idle: (on: TimeInterval, off: TimeInterval) = (4, 20)
        #else
        let idle: (on: TimeInterval, off: TimeInterval) = (25, 60)
        #endif
        for listed in hubs where (inFlight[listed.id] ?? 0) == 0 {
            var hub = listed
            let boosted = boostUntil[hub.id].map { $0 > now } ?? false
            let answering = (failures[hub.id] ?? 0) < 2 || boosted
            var every: TimeInterval = answering ? (active ? 1.5 : idle.on) : (active ? 12 : idle.off)
            if !answering, let found = heard[hub.id] {
                // Off until now but just heard on the Wi‑Fi (switched on): ask now, at its new address if it moved.
                if !heardBefore.contains(hub.id) { every = 0 }
                if let moved = moveIfNeeded(hub, to: found) { hub = moved; every = 0 }
            }
            if let at = askedAt[hub.id], now.timeIntervalSince(at) < every - 0.05 { continue }
            let wait: TimeInterval = answering ? askTimeout(hub) : 4
            let target = hub
            Task { await self.ask(target, timeout: wait) }
        }
        heardBefore = Set(heard.keys)
    }

    /// A hub whose latest answer has grown too old to go by (`staleAfter`) while one of its TVs still shows what that
    /// answer said was playing: shown again without it, instead of waiting for an answer that may not come (the app
    /// just woke in the background, or the hub went quiet without failing yet).
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
    nonisolated static func isHomeAddress(_ host: String?) -> Bool {
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

    /// A paired TV that stopped answering but announces itself at another address on the home network (the
    /// router gave it a new one): talk to it there. Never replaces an away-from-home link.
    private func moveIfNeeded(_ hub: Hub, to found: DiscoveredTV) -> Hub? {
        guard let base = found.base, let newHost = base.host, let oldHost = hub.connection.base.host,
              newHost != oldHost, Fleet.isHomeAddress(oldHost), Fleet.isHomeAddress(newHost),
              let i = hubs.firstIndex(where: { $0.id == hub.id }) else { return nil }
        hubs[i].connection.base = base
        saveHubs()
        extras[hub.id, default: TVExtras()].lastHost = newHost
        failures[hub.id] = 1
        return hubs[i]
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
            if let me = list.first(where: { $0.id == "this" }), me.name != hubs[i].name {
                hubs[i].name = me.name
                saveHubs()
            }
        case .failure:
            let missed = (failures[id] ?? 0) + 1
            failures[id] = missed
            // One missed answer from a TV that was answering isn't "off" yet: it's asked again right away.
            if missed < 2 && answers[id]?.isAnswered == true { return }
            answers[id] = .unreachable
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
        let stale = staleRelays()
        var all = FleetMerge.merge(hubs: hubs, answers: answers, before: before,
                                   platforms: extras.compactMapValues(\.platform), now: now,
                                   answeredAt: answeredAt, staleAfter: limit, staleRelays: stale)
        var marks: [String: PauseMark] = [:]
        for i in all.indices {
            let id = all[i].id
            if extras[id]?.platform == nil, let p = guessPlatform(all[i]) {
                extras[id, default: TVExtras()].platform = p
                all[i].platform = p
            }
            // The webOS app calls itself "LG TV" until it's named on the TV: that's Elliot's Room.
            if extras[id]?.alias == nil && all[i].name.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare("LG TV") == .orderedSame {
                extras[id, default: TVExtras()].alias = "Elliot’s Room"
            }
            if let alias = extras[id]?.alias, !alias.isEmpty { all[i].name = alias }
            all[i].alertsHidden = all[i].hasAlerts && hiddenAlerts[id] == all[i].alertSignature
            // The pause clock. A TV that only shows nothing because what was heard of it is too old keeps its clock,
            // so a pause from before the app went to the background still counts from when it began.
            let hubID = all[i].hubID
            let heardAt = answeredAt[hubID]
            let tooOld = (heardAt.map { now.timeIntervalSince($0) > limit } ?? false)
                || (!all[i].isHub && stale.contains(FleetMerge.relayKey(hubID, all[i].routeID)))
            if all[i].online && all[i].playing == nil && tooOld {
                marks[id] = pauseMarks[id]
            } else {
                let judged = FleetMerge.pause(all[i].online ? all[i].playing : nil, mark: pauseMarks[id], heardAt: heardAt ?? now, now: now)
                marks[id] = judged.mark
                all[i].pausedLong = judged.long
            }
        }
        pauseMarks = marks
        all.sort(by: FleetMerge.order)
        // TVs heard on the Wi‑Fi that no paired TV knows: listed so they can be paired.
        let pairedHosts = Set(hubs.compactMap { $0.connection.base.host })
        let heardAll = discovery.found + lanFound.filter { l in !discovery.found.contains { $0.host == l.host } }
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

    /// The TVs a hub passes on (by `FleetMerge.relayKey`) that it still says are on but hasn't heard from for a while
    /// (`FleetMerge.relay`): what they're playing is left out until they're heard again. Counted between that hub's
    /// own answers, so a hub that's asked less often (the app in the background) never makes its TVs look stale.
    private func staleRelays() -> Set<String> {
        var stale: Set<String> = []
        var kept: [String: RelaySeen] = [:]
        for hub in hubs {
            guard case .answered(let list)? = answers[hub.id], let at = answeredAt[hub.id] else { continue }
            for e in list where e.id != "this" && e.online {
                guard let seen = e.seen else { continue }
                let key = FleetMerge.relayKey(hub.id, e.id)
                let judged = FleetMerge.relay(seen: seen, at: at, kept: relaySeen[key])
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
    public private(set) var library: WatchHome?

    public func refreshLibrary() async {
        // Any TV that answers (the first may be off): the ones answering now first.
        for hub in hubsAnsweringFirst() {
            if let h = try? await TVClient(hub: hub, routeID: "this").watchHome() { library = h; return }
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
        if let found = libraryArtwork(p) { return found }
        // Not in Home's short lists: search the whole library once and use what it finds.
        let key = Self.simple(String(p.title.split(separator: "·").first ?? Substring(p.title)))
        guard !key.isEmpty else { return nil }
        if let found = searchedArt[key] { return found }
        searchArt(p, key: key)
        return nil
    }

    private func libraryArtwork(_ p: NowPlaying) -> NowPlayingArtwork? {
        guard let lib = library else { return nil }
        let titles = (lib.featured ?? []) + (lib.recent ?? []) + (lib.movies?.items ?? []) + (lib.shows?.items ?? [])
        func title(_ id: String?) -> Title? { id.flatMap { id in titles.first { $0.id == id } } }
        let cont = lib.continue ?? []
        if let key = p.key, let c = cont.first(where: { $0.key == key }) {
            let t = title(c.titleId)
            return NowPlayingArtwork(poster: c.poster ?? t?.poster, backdrop: t?.backdrop, titleID: c.titleId)
        }
        if let key = p.key, key.hasPrefix("drive:"), let t = titles.first(where: { "drive:" + $0.id == key }) {
            return NowPlayingArtwork(poster: t.poster, backdrop: t.backdrop, titleID: t.id)
        }
        let want = Self.simple(String(p.title.split(separator: "·").first ?? Substring(p.title)))
        guard !want.isEmpty else { return nil }
        if let c = cont.first(where: { Self.simple($0.name) == want || want.hasPrefix(Self.simple($0.name)) }) {
            let t = title(c.titleId)
            return NowPlayingArtwork(poster: c.poster ?? t?.poster, backdrop: t?.backdrop, titleID: c.titleId)
        }
        if let t = titles.first(where: { Self.simple($0.title) == want || want.hasPrefix(Self.simple($0.title)) }) {
            return NowPlayingArtwork(poster: t.poster, backdrop: t.backdrop, titleID: t.id)
        }
        return nil
    }

    static func simple(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }

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
    public func hubClient(for tv: FleetTV? = nil) -> TVClient? {
        let t = tv ?? selected
        if let t, let direct = hubs.first(where: { $0.id == t.id }) { return TVClient(hub: direct, routeID: "this") }
        if let t, let hub = hub(t.hubID) { return TVClient(hub: hub, routeID: "this") }
        return hubs.first.map { TVClient(hub: $0, routeID: "this") }
    }

    public var selectedClient: TVClient? { selected.flatMap(client(for:)) }

    // MARK: Health

    public func loadHealth(_ tv: FleetTV) async {
        guard let c = client(for: tv) else { return }
        do {
            let r = try await c.health()
            healthReports[tv.id] = r
            healthErrors[tv.id] = nil
            if let p = r.platform { extras[tv.id, default: TVExtras()].platform = p }
        } catch let u as HealthUnavailable {
            if let last = u.last { healthReports[tv.id] = last }
            healthErrors[tv.id] = u.message
        } catch {
            healthErrors[tv.id] = error.localizedDescription
        }
    }

    public func loadAllHealth() async {
        await withTaskGroup(of: Void.self) { g in
            for tv in tvs { g.addTask { await self.loadHealth(tv) } }
        }
    }

    // MARK: Updates

    public func checkReleases() async {
        if Demo.isOn { latest = Demo.releases; return }
        let token = githubToken
        for p in TVPlatform.allCases {
            do {
                latest[p] = try await ReleaseFeed(token: p == .webOS ? token : nil).latest(p)
                releaseErrors[p] = nil
            } catch {
                releaseErrors[p] = error.localizedDescription
            }
        }
    }

    public func platform(of tv: FleetTV) -> TVPlatform? { extras[tv.id]?.platform ?? tv.platform }

    /// Whether [tv] runs an older version than the newest release for its platform.
    public func isBehind(_ tv: FleetTV) -> Bool {
        guard let p = platform(of: tv), let newest = latest[p]?.version, let mine = WoodruffVersion(tv.version) else { return false }
        return mine < newest
    }

    public var updatesWaiting: Int { tvs.filter(isBehind).count }
    public var attentionCount: Int { tvs.filter(\.needsAttention).count }

    /// Asks one Android TV to update now (it downloads the newest release and installs it once nobody's using it).
    public func pushUpdate(_ tv: FleetTV) async throws {
        guard let c = client(for: tv) else { throw TVError.notPaired }
        try await c.checkForUpdates()
    }

    /// Asks every reachable Android TV to update. Returns (asked, failures).
    public func pushUpdateToAll() async -> (Int, [String]) {
        var asked = 0
        var failed: [String] = []
        for tv in tvs where tv.online && !tv.isUnpaired && platform(of: tv) != .webOS {
            do { try await pushUpdate(tv); asked += 1 } catch { failed.append("\(tv.name): \(error.localizedDescription)") }
        }
        return (asked, failed)
    }

    // MARK: LG direct control

    public func lg(for tv: FleetTV) -> LGRemote? {
        guard let host = extras[tv.id]?.lgHost, !host.isEmpty else { return nil }
        // The saved sign-in may have just arrived from another family device: connect afresh with it.
        let key = Keychain.get("lg.\(tv.id)")
        if let r = lgRemotes[tv.id], r.host == host, lgKeys[tv.id] == key { return r }
        if let old = lgRemotes[tv.id] { Task { await old.disconnect() } }
        let r = LGRemote(host: host, clientKey: key)
        lgRemotes[tv.id] = r
        lgKeys[tv.id] = key
        return r
    }

    /// Connects LG direct control (the TV asks "Allow?" the first time) and keeps its key.
    public func connectLG(_ tv: FleetTV, host: String) async throws {
        extras[tv.id, default: TVExtras()].lgHost = host
        extras[tv.id]?.platform = .webOS
        lgRemotes[tv.id] = nil
        guard let r = lg(for: tv) else { return }
        let key = try await r.connect()
        Keychain.set(key, for: "lg.\(tv.id)")
        lgKeys[tv.id] = key
        if let mac = await r.macAddress() { extras[tv.id]?.mac = mac }
    }

    public func forgetLG(_ tv: FleetTV) {
        extras[tv.id]?.lgHost = nil
        Keychain.set(nil, for: "lg.\(tv.id)")
        Task { await lgRemotes[tv.id]?.disconnect() }
        lgRemotes[tv.id] = nil
    }

    // MARK: Phone identity

    @discardableResult
    func hello(_ hub: Hub) async throws -> JSONValue {
        let r = try await TVTransport(hub.connection).post("/api/phone/hello", ["id": phone.id, "name": phone.name, "alerts": phone.alerts])
        // Earlier installs of this app registered under other ids with this device's name: forget those copies.
        let t = TVTransport(hub.connection)
        for p in r["phones"]?.array ?? [] {
            guard let id = p["id"]?.string, id != phone.id,
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

    /// Asks each hub for messages kept for this phone, showing only new ones (by seq within an epoch, and by id).
    public func pollInbox() async {
        // Every hub that's answering, all at once (one that's off would only make the others wait; it's asked
        // again once it's back, and keeps what it has for this phone until then).
        let asking = hubs.filter { (failures[$0.id] ?? 0) < 2 }
        guard !asking.isEmpty else { return }
        let startCursors = Saved.load("inboxCursors", as: [String: InboxCursor].self) ?? [:]
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
        let savedCursors = Saved.load("inboxCursors", as: [String: InboxCursor].self) ?? [:]
        var cursors = savedCursors
        let savedSeen = Saved.load("inboxSeen", as: [String].self) ?? []
        var seenOrder = savedSeen
        var seen = Set(seenOrder)
        let shownBefore = recentMessages
        for hub in asking {
            guard let box = boxes[hub.id] else { continue }
            var cur = cursors[hub.id] ?? InboxCursor()
            if box.epoch != cur.epoch { cur.after = 0; cur.epoch = box.epoch }
            let first = cursors[hub.id] == nil
            for m in box.messages where m.seq > (cur.after ?? 0) && !seen.contains(m.id) {
                seen.insert(m.id)
                seenOrder.append(m.id)
                recentMessages.insert(m, at: 0)
                // The first poll after pairing only catches up; it doesn't replay old messages as alerts.
                if !first { onChange?(.message(m, from: hub.name)) }
            }
            cur.after = max(cur.after ?? 0, box.seq ?? 0)
            cursors[hub.id] = cur
        }
        let weekAgo = (Date().timeIntervalSince1970 - 7 * 86400) * 1000
        let kept = Array(recentMessages.filter { ($0.at ?? weekAgo + 1) > weekAgo }.prefix(20))
        if kept != recentMessages { recentMessages = kept }
        // Written only when something changed (this runs every few seconds).
        if recentMessages != shownBefore { Saved.save("recentMessages", recentMessages) }
        if seenOrder != savedSeen { Saved.save("inboxSeen", Array(seenOrder.suffix(200))) }
        if cursors != savedCursors { Saved.save("inboxCursors", cursors) }
    }

    // MARK: Messages

    public func show(_ error: Error) {
        banner = Banner(title: "Couldn't do that", message: error.localizedDescription)
    }

    public func say(_ title: String, _ message: String) {
        banner = Banner(title: title, message: message)
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

    var isAnswered: Bool {
        if case .answered = self { return true }
        return false
    }
}

/// How the TVs every hub reports become one list. Kept apart from `Fleet` so the rules can be tested, and so the
/// list comes out the same whatever order the hubs answered in.
enum FleetMerge {
    /// - A TV's own answer (a hub, about itself) beats one relayed by another hub; a relayed answer saying it's on
    ///   beats one saying it's off; between equals, the hub paired first wins.
    /// - A hub that doesn't answer keeps what was known of it, marked off, and so do the linked TVs only it knew
    ///   (unless another hub reports them). A hub not heard from yet keeps what was shown before.
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
                let tv = FleetTV(id: realID, name: e.name, online: e.online, onScreen: e.online && (e.onScreen ?? false),
                                 playing: believed ? e.playing : nil, version: e.version, seen: e.seen, link: e.link ?? "ok",
                                 health: e.health, hubID: hub.id, routeID: e.id, platform: platforms[realID])
                let r = tv.isHub ? 3 : (tv.online ? 2 : 1)
                if let have = rank[realID], have >= r { continue }
                merged[realID] = tv
                rank[realID] = r
            }
        }
        for hub in hubs {
            let answer = answers[hub.id]
            if answer?.isAnswered == true { continue }
            let down = answer == .unreachable
            if merged[hub.id] == nil {
                var tv = before[hub.id] ?? FleetTV(id: hub.id, name: hub.name, online: false, onScreen: false, playing: nil, version: nil,
                                                   seen: nil, link: "ok", health: nil, hubID: hub.id, routeID: "this",
                                                   platform: platforms[hub.id])
                tv.hubID = hub.id
                tv.routeID = "this"
                tv.foundAt = nil
                if down { tv.online = false; tv.onScreen = false; tv.playing = nil }
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

    // MARK: TVs a hub passes on

    /// One TV as one hub passes it on ("hub|TV"): the same TV can be passed on by several hubs, each hearing from it
    /// on its own.
    static func relayKey(_ hubID: String, _ tvID: String) -> String { hubID + "|" + tvID }

    /// How long a hub can keep passing on the same `seen` for a TV (by its own answers, on this device's clock)
    /// before it counts as not having heard from that TV lately. A hub hears from each linked TV every few seconds.
    static let relayStaleAfter: TimeInterval = 20

    /// [seen], as a hub's answer that arrived at [at] passes it on, laid over what was [kept] from its answers before:
    /// the value to keep, and whether that hub has now gone `relayStaleAfter` seconds of answers without hearing from
    /// the TV (its `seen` hasn't moved), so what it says the TV plays is out of date.
    static func relay(seen: Double, at: Date, kept: RelaySeen?) -> (kept: RelaySeen, stale: Bool) {
        let r = kept.flatMap { $0.seen == seen ? $0 : nil } ?? RelaySeen(seen: seen, since: at)
        return (r, at.timeIntervalSince(r.since) >= relayStaleAfter)
    }

    // MARK: Pauses

    /// How long a pause lasts before what's paused no longer counts as playing.
    static let pausedLongAfter: TimeInterval = 300

    /// The pause rule, one source of truth (`FleetTV.pausedLong`): whether [playing] has been paused so long it no
    /// longer counts as playing, and the mark to keep for the next answer. A pause counts from the last time the title
    /// was heard playing ([heardAt]: when the answer saying what it plays arrived), so a pause this app sees happen
    /// starts the clock then, and one that began while the app was asleep counts from before it slept. A title first
    /// seen already paused (the app just launched, or an Android session left behind after YouTube, Netflix or Plex
    /// closed) counts as paused long at once. Nothing playing (or the TV off) clears the mark; another title starts
    /// afresh.
    static func pause(_ playing: NowPlaying?, mark: PauseMark?, heardAt: Date, now: Date) -> (mark: PauseMark?, long: Bool) {
        guard let p = playing else { return (nil, false) }
        let title = (p.key ?? "") + "|" + p.title
        if p.isPlaying { return (PauseMark(title: title, playedAt: heardAt), false) }
        guard let kept = mark, kept.title == title else { return (PauseMark(title: title, playedAt: nil), true) }
        guard let at = kept.playedAt else { return (kept, true) }
        return (kept, now.timeIntervalSince(at) >= pausedLongAfter)
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
    /// The last time it was heard playing; nil when it was already paused the first time it was seen.
    var playedAt: Date?
}

public struct NowPlayingArtwork: Hashable, Sendable {
    public var poster: String?
    public var backdrop: String?
    public var titleID: String?
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
