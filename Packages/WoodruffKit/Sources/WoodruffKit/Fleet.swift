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
    public var atHome: Bool {
        #if canImport(Darwin)
        let mine = LANScan.prefixes()
        let tvHosts = hubs.compactMap { $0.connection.base.host } + extras.values.compactMap(\.lastHost)
        return tvHosts.contains { host in
            let parts = host.split(separator: ".")
            return parts.count == 4 && mine.contains(parts.prefix(3).joined(separator: ".") + ".")
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
    private var lgRemotes: [String: LGRemote] = [:]

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
        if !Demo.isOn { discovery.start() }
        loop = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                guard let self else { return }
                if self.active || tick % 6 == 0 { await self.refresh() }
                if tick % 120 == 0 { await self.checkReleases() }
                if self.active || tick % 6 == 0 { await self.pollInbox() }
                if tick % 24 == 0 { await self.refreshLibrary() }
                if !Demo.isOn && (self.lanScannedAt == nil || Date().timeIntervalSince(self.lanScannedAt!) > 600) { await self.scanNetwork() }
                tick += 1
                try? await Task.sleep(nanoseconds: (self.active ? 5 : 30) * 1_000_000_000)
            }
        }
        Task { for h in hubs { _ = try? await hello(h) } }
    }

    public func setActive(_ on: Bool) {
        active = on
        if on { Task { await refresh() } }
    }

    // MARK: Pairing

    /// Pairs with the TV at [connection]: asks who it is, keeps it, says hello as this phone.
    @discardableResult
    public func pair(_ connection: TVConnection) async throws -> Hub {
        let status: TVStatus = try await TVTransport(connection).get("/api/status")
        let hub = Hub(id: status.id, name: status.name, connection: connection)
        hubs.removeAll { $0.id == hub.id }
        hubs.append(hub)
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
        tvs.removeAll { $0.hubID == hubID }
        if selectedID == hubID { selectedID = tvs.first?.id }
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

    /// Asks every hub for its TVs (each hub answers for itself and its linked TVs) and merges them.
    public func refresh() async {
        guard !hubs.isEmpty, !refreshing else { return }
        refreshing = true
        defer { refreshing = false; refreshedAt = Date() }
        let before = Dictionary(uniqueKeysWithValues: tvs.map { ($0.id, $0) })
        var merged: [String: FleetTV] = [:]
        await withTaskGroup(of: (Hub, Result<[TVListEntry], Error>).self) { g in
            for hub in hubs {
                g.addTask {
                    do {
                        let r: TVList = try await TVTransport(hub.connection).get("/api/tvs", timeout: 6)
                        return (hub, .success(r.tvs))
                    } catch { return (hub, .failure(error)) }
                }
            }
            for await (hub, result) in g {
                switch result {
                case .success(let list):
                    for e in list {
                        let realID = e.id == "this" ? hub.id : e.id
                        let tv = FleetTV(id: realID, name: e.name, online: e.online, onScreen: e.onScreen ?? false, playing: e.playing,
                                         version: e.version, seen: e.seen, link: e.link ?? "ok", health: e.health, hubID: hub.id,
                                         routeID: e.id, platform: extras[realID]?.platform)
                        // Prefer the TV's own answer (direct), then any online answer.
                        if let old = merged[realID] {
                            if old.isHub { continue }
                            if !tv.isHub && old.online && !tv.online { continue }
                        }
                        merged[realID] = tv
                    }
                    if let i = hubs.firstIndex(where: { $0.id == hub.id }), let me = list.first(where: { $0.id == "this" }), me.name != hubs[i].name {
                        hubs[i].name = me.name; saveHubs()
                    }
                case .failure:
                    // The hub is off: keep what was known of it, marked offline.
                    if merged[hub.id] == nil {
                        var tv = before[hub.id] ?? FleetTV(id: hub.id, name: hub.name, online: false, onScreen: false, playing: nil, version: nil, seen: nil, link: "ok", health: nil, hubID: hub.id, routeID: "this", platform: extras[hub.id]?.platform)
                        tv.online = false; tv.onScreen = false; tv.playing = nil; tv.hubID = hub.id; tv.routeID = "this"
                        merged[hub.id] = tv
                    }
                    // Linked TVs only this hub knew stay listed as they were, offline.
                    for old in before.values where old.hubID == hub.id && merged[old.id] == nil {
                        var t = old; t.online = false; t.playing = nil; merged[old.id] = t
                    }
                }
            }
        }
        let list = merged.values.sorted { a, b in
            if a.isHub != b.isHub { return a.isHub }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        for tv in list {
            notifyIfNeeded(tv, was: before[tv.id])
            if extras[tv.id]?.platform == nil, let p = guessPlatform(tv) { extras[tv.id, default: TVExtras()].platform = p }
        }
        var all = list.map { tv -> FleetTV in
            var t = tv
            // The webOS app calls itself "LG TV" until it's named on the TV: that's Elliot's Room.
            if extras[t.id]?.alias == nil && t.name.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare("LG TV") == .orderedSame {
                extras[t.id, default: TVExtras()].alias = "Elliot’s Room"
            }
            if let alias = extras[t.id]?.alias, !alias.isEmpty { t.name = alias }
            t.alertsHidden = t.hasAlerts && hiddenAlerts[t.id] == t.alertSignature
            return t
        }
        // TVs heard on the Wi‑Fi that no paired TV knows: listed so they can be paired.
        let pairedHosts = Set(hubs.compactMap { $0.connection.base.host })
        let heardAll = discovery.found + lanFound.filter { l in !discovery.found.contains { $0.host == l.host } }
        for f in heardAll where !pairedHosts.contains(f.host) {
            let shown = f.name.caseInsensitiveCompare("LG TV") == .orderedSame ? "Elliot’s Room" : f.name
            if all.contains(where: { $0.id == f.id || $0.name.caseInsensitiveCompare(f.name) == .orderedSame
                || $0.name.caseInsensitiveCompare(shown) == .orderedSame }) { continue }
            let heard = f.name.caseInsensitiveCompare("LG TV") == .orderedSame ? "Elliot’s Room" : f.name
            var t = FleetTV(id: f.id, name: extras[f.id]?.alias ?? heard, online: true, onScreen: false, playing: nil, version: nil, seen: nil,
                            link: "unpaired", health: nil, hubID: "", routeID: "", platform: extras[f.id]?.platform)
            t.foundAt = f.base
            all.append(t)
        }
        tvs = all
        var changedLast = false
        for tv in all { if let p = tv.playing, lastPlaying[tv.id]?.title != p.title { lastPlaying[tv.id] = p; changedLast = true } }
        if changedLast { Saved.save("lastPlaying", lastPlaying) }
        if selectedID == nil || !tvs.contains(where: { $0.id == selectedID && !$0.isUnpaired }) { selectedID = tvs.first { !$0.isUnpaired }?.id }
    }

    /// Alerts once per problem: a TV's alert is announced again only when what it says changes, and "went
    /// offline" only after two minutes without an answer (a missed check isn't an outage), once per outage.
    private func notifyIfNeeded(_ tv: FleetTV, was old: FleetTV?) {
        let hidden = hiddenAlerts[tv.id] == tv.alertSignature
        if tv.hasAlerts && !hidden && tv.online {
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
            if !atHome || !tvs.contains(where: { $0.online && !$0.isUnpaired }) {
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

    /// What each TV last played (kept after it stops, so its tile keeps its picture).
    public private(set) var lastPlaying: [String: NowPlaying] = Saved.load("lastPlaying", as: [String: NowPlaying].self) ?? [:]

    /// The hub's Watch home, kept to put pictures on what each TV is playing.
    public private(set) var library: WatchHome?

    public func refreshLibrary() async {
        guard let hub = hubs.first else { return }
        if let h = try? await TVClient(hub: hub, routeID: "this").watchHome() { library = h }
    }

    /// The poster and backdrop (TV-relative paths or TMDB links) of what [p] is: by its Drive key, else by title.
    public func artwork(for p: NowPlaying?) -> NowPlayingArtwork? {
        guard let p, let lib = library else { return nil }
        // Only Woodruff's own player plays library titles: never guess a YouTube or Netflix title from the library.
        let ours = p.key?.hasPrefix("drive:") == true || (p.app ?? "").lowercased().contains("woodruff")
        guard ours else { return nil }
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
        if let direct = hubs.first(where: { $0.id == tv.id }) { return TVClient(hub: direct, routeID: "this") }
        guard let hub = hub(tv.hubID) else { return nil }
        return TVClient(hub: hub, routeID: tv.routeID)
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
        if let r = lgRemotes[tv.id], r.host == host { return r }
        let r = LGRemote(host: host, clientKey: Keychain.get("lg.\(tv.id)"))
        lgRemotes[tv.id] = r
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
        var cursors = Saved.load("inboxCursors", as: [String: InboxCursor].self) ?? [:]
        var seenOrder = Saved.load("inboxSeen", as: [String].self) ?? []
        var seen = Set(seenOrder)
        for hub in hubs {
            var cur = cursors[hub.id] ?? InboxCursor()
            guard let box = try? await TVClient(hub: hub, routeID: "this").inbox(phone: phone.id, after: cur.after, epoch: cur.epoch) else { continue }
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
        recentMessages = Array(recentMessages.filter { ($0.at ?? weekAgo + 1) > weekAgo }.prefix(20))
        Saved.save("recentMessages", recentMessages)
        Saved.save("inboxSeen", Array(seenOrder.suffix(200)))
        Saved.save("inboxCursors", cursors)
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
        if tvs.contains(where: { $0.playing != nil }) { return "play.tv" }
        return "tv"
    }
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

struct InboxCursor: Codable {
    var after: Int?
    var epoch: String?
}
