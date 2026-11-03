import Foundation
import Observation

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

    public var needsAttention: Bool { link == "refused" || health?.status == "attention" }
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
    /// The TV the remote, Send and Memories act on.
    public var selectedID: String? { didSet { UserDefaults.standard.set(selectedID, forKey: "selectedTV") } }
    public var banner: Banner?
    /// The remote sends to every TV that's on.
    public var remoteAll = false
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
        hubs = Saved.load("hubs", as: [Hub].self) ?? []
        // Pairing keys live in the Keychain, not in UserDefaults.
        for i in hubs.indices { if let k = Keychain.get("hub.\(hubs[i].id)") { hubs[i].connection.key = k } }
        extras = Saved.load("extras", as: [String: TVExtras].self) ?? [:]
        selectedID = UserDefaults.standard.string(forKey: "selectedTV")
        tvs = hubs.map { FleetTV(id: $0.id, name: $0.name, online: false, onScreen: false, playing: nil, version: nil, seen: nil, link: "ok", health: nil, hubID: $0.id, routeID: "this", platform: extras[$0.id]?.platform) }
    }

    private func saveHubs() {
        if Demo.isOn { return }
        var plain = hubs
        for i in plain.indices {
            Keychain.set(plain[i].connection.key, for: "hub.\(plain[i].id)")
            plain[i].connection.key = ""
        }
        Saved.save("hubs", plain)
    }

    // MARK: Lifecycle

    public func start() async {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                guard let self else { return }
                if self.active || tick % 6 == 0 { await self.refresh() }
                if tick % 120 == 0 { await self.checkReleases() }
                if self.active || tick % 6 == 0 { await self.pollInbox() }
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
            if let old = before[tv.id] {
                if old.online && !tv.online { onChange?(.wentOffline(tv)) }
                if !old.online && tv.online && old.seen != nil { onChange?(.cameOnline(tv)) }
                if !old.needsAttention && tv.needsAttention { onChange?(.needsAttention(tv)) }
            }
            if extras[tv.id]?.platform == nil, let p = guessPlatform(tv) { extras[tv.id, default: TVExtras()].platform = p }
        }
        tvs = list
        if selectedID == nil || !tvs.contains(where: { $0.id == selectedID }) { selectedID = tvs.first?.id }
    }

    private func guessPlatform(_ tv: FleetTV) -> TVPlatform? {
        if let r = healthReports[tv.id] { return r.platform }
        return nil
    }

    // MARK: Lookup

    public var selected: FleetTV? { tvs.first { $0.id == selectedID } ?? tvs.first }
    public func tv(_ id: String) -> FleetTV? { tvs.first { $0.id == id } }
    public func hub(_ id: String) -> Hub? { hubs.first { $0.id == id } }

    /// The client for [tv]: straight to it when it's paired here, otherwise through the hub that links it.
    public func client(for tv: FleetTV) -> TVClient? {
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
    public var attentionCount: Int { tvs.filter { $0.needsAttention || !$0.online }.count }

    /// Asks one Android TV to update now (it downloads the newest release and installs it once nobody's using it).
    public func pushUpdate(_ tv: FleetTV) async throws {
        guard let c = client(for: tv) else { throw TVError.notPaired }
        try await c.checkForUpdates()
    }

    /// Asks every reachable Android TV to update. Returns (asked, failures).
    public func pushUpdateToAll() async -> (Int, [String]) {
        var asked = 0
        var failed: [String] = []
        for tv in tvs where tv.online && platform(of: tv) != .webOS {
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
        try await TVTransport(hub.connection).post("/api/phone/hello", ["id": phone.id, "name": phone.name, "alerts": phone.alerts])
    }

    public func sayHelloEverywhere() async {
        for h in hubs { _ = try? await hello(h) }
    }

    // MARK: Inbox (announcements to this phone)

    public private(set) var recentMessages: [InboxMessage] = Saved.load("recentMessages", as: [InboxMessage].self) ?? []

    /// Asks each hub for messages kept for this phone, showing only new ones (by seq within an epoch, and by id).
    public func pollInbox() async {
        var cursors = Saved.load("inboxCursors", as: [String: InboxCursor].self) ?? [:]
        var seen = Set(Saved.load("inboxSeen", as: [String].self) ?? [])
        for hub in hubs {
            var cur = cursors[hub.id] ?? InboxCursor()
            guard let box = try? await TVClient(hub: hub, routeID: "this").inbox(phone: phone.id, after: cur.after, epoch: cur.epoch) else { continue }
            if box.epoch != cur.epoch { cur.after = 0; cur.epoch = box.epoch }
            let first = cursors[hub.id] == nil
            for m in box.messages where m.seq > (cur.after ?? 0) && !seen.contains(m.id) {
                seen.insert(m.id)
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
        Saved.save("inboxSeen", Array(seen.suffix(50)))
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

    static func load() -> PhoneIdentity {
        if let p = Saved.load("phone", as: PhoneIdentity.self) { return p }
        #if os(macOS)
        let name = Host.current().localizedName ?? "Mac"
        #else
        let name = "iPhone"
        #endif
        return PhoneIdentity(id: UUID().uuidString.lowercased(), name: name, alerts: false)
    }
    func save() { Saved.save("phone", self) }
}

struct InboxCursor: Codable {
    var after: Int?
    var epoch: String?
}
