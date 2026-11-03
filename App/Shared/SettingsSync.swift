import Foundation
import Network
import CryptoKit
import WoodruffKit

/// Keeps everything the family sets (API keys, sign-ins, app keys, names, rooms, the Home layout and favourites,
/// TV names, hidden alerts, alert choices) the same on every iPhone and Mac.
///
/// Two ways, so it always gets there:
/// 1. **Kept on the TVs.** Every device keeps an encrypted copy of all of it on each TV it's paired with
///    (one small file). On opening, coming back, every 30 seconds, and right after any change, each device
///    reads that copy, takes anything newer, and writes back anything it has that's newer. The TVs are always
///    on, so a change reaches a device that was closed, away, or asleep the next time it opens.
/// 2. **Straight across the Wi‑Fi.** Devices open at the same time also hand changes to each other directly,
///    so they show within a couple of seconds.
/// The newest change to each item wins; a sign-out on one device signs out the others.
@Observable @MainActor
final class SettingsSync {
    static let shared = SettingsSync()
    static let service = "_woodruffsync._tcp"

    /// Keychain items that travel.
    static let keychainKeys = [
        "govee.key",
        "st.client", "st.secret", "st.access", "st.refresh", "st.expires", "st.token",
        "nest.project", "nest.client", "nest.secret", "nest.access", "nest.refresh", "nest.expires", "nest.scopes", "nest.subscription",
        "github.token", "dreo.email", "dreo.password", "deco.host", "deco.password",
    ]
    /// Saved settings that travel (JSON in UserDefaults).
    static let dataKeys = ["smartNames", "smartRooms", "smartExtraRooms", "goveeManualIPs", "homeLayout", "extras", "hiddenAlerts"]
    /// Plain preferences that travel.
    static let valueKeys = ["nest.alert.person", "nest.alert.motion", "nest.alert.doorbell"]

    /// "Saved on Living Room, Master Bedroom · 12:04" for Settings.
    private(set) var status = "Not synced yet"
    private(set) var lastSynced: Date?

    @ObservationIgnored private let me: String = {
        if let s = UserDefaults.standard.string(forKey: "sync.id") { return s }
        let s = UUID().uuidString
        UserDefaults.standard.set(s, forKey: "sync.id")
        return s
    }()
    @ObservationIgnored private var stamps: [String: Double] = (UserDefaults.standard.dictionary(forKey: "sync.stamps") as? [String: Double]) ?? [:]
    @ObservationIgnored private var last: [String: String] = [:]
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var peers: [String: NWEndpoint] = [:]
    @ObservationIgnored private weak var fleet: Fleet?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var tvBusy = false
    @ObservationIgnored private var tvAgain = false
    @ObservationIgnored private var pushSoon: Task<Void, Never>?
    @ObservationIgnored private var folders: [String: String] = [:]

    func start(_ fleet: Fleet) {
        guard loop == nil, !Demo.isOn else { return }
        self.fleet = fleet
        last = snapshot()
        // Settings from before syncing began count as set now, so they reach the other devices.
        let now = Date().timeIntervalSince1970
        for (k, v) in last where stamps[k] == nil && !v.isEmpty { stamps[k] = now }
        saveStamps()
        listen()
        browse()
        loop = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard let self else { return }
                self.check()
                tick += 1
                if tick % 20 == 0 { await self.syncTVs() }   // every 30 seconds
            }
        }
        Task { await syncTVs() }
    }

    /// Back to the front: read the TVs' copy, look for the other devices, swap everything.
    func wake() {
        guard loop != nil else { return }
        if listener == nil { listen() }
        browser?.cancel(); browser = nil
        browse()
        check()
        broadcast()
        Task { await syncTVs() }
    }

    func syncNow() async { check(); await syncTVs(); broadcast() }

    // MARK: What's here

    private func canonical(_ key: String) -> String {
        let name = String(key.dropFirst(3))
        if key.hasPrefix("kc:") { return Keychain.get(name) ?? "" }
        guard let obj = UserDefaults.standard.object(forKey: name) else { return "" }
        if key.hasPrefix("ud:") {
            guard let d = obj as? Data, let o = try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed]),
                  let c = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys, .fragmentsAllowed]) else { return "" }
            return String(decoding: c, as: UTF8.self)
        }
        guard let c = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .fragmentsAllowed]) else { return "" }
        return String(decoding: c, as: UTF8.self)
    }

    private func snapshot() -> [String: String] {
        var out: [String: String] = [:]
        for k in Self.keychainKeys { out["kc:" + k] = canonical("kc:" + k) }
        for k in Self.dataKeys { out["ud:" + k] = canonical("ud:" + k) }
        for k in Self.valueKeys { out["uv:" + k] = canonical("uv:" + k) }
        return out
    }

    /// An item's age: its stamp, or never if it has no value and no stamp.
    private func stamp(_ k: String) -> Double { stamps[k] ?? ((last[k] ?? "").isEmpty ? 0 : 1) }

    /// Notices changes made here, stamps them, and sends them on.
    private func check() {
        let now = snapshot()
        var changed = false
        for (k, v) in now where last[k] != nil && last[k] != v {
            stamps[k] = Date().timeIntervalSince1970
            changed = true
        }
        last = now
        guard changed else { return }
        saveStamps()
        broadcast()
        // Onto the TVs straight away (a moment later, so a burst of edits goes as one).
        pushSoon?.cancel()
        pushSoon = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.syncTVs()
        }
    }

    private func saveStamps() { UserDefaults.standard.set(stamps, forKey: "sync.stamps") }

    // MARK: Taking newer settings in

    /// Takes whatever is newer in [items]; returns whether ours has anything newer than theirs.
    @discardableResult
    private func apply(_ items: [String: [String: Any]]) -> Bool {
        var changed = false
        var oursNewer = false
        for (k, item) in items where k.hasPrefix("kc:") || k.hasPrefix("ud:") || k.hasPrefix("uv:") {
            guard last[k] != nil else { continue }   // not something this version keeps
            let t = (item["t"] as? NSNumber)?.doubleValue ?? 0
            let v = item["v"] as? String ?? ""
            let mine = stamp(k)
            if t > mine {
                if v != (last[k] ?? "") { write(k, v); last[k] = v; changed = true }
                stamps[k] = t
            } else if mine > t && (last[k] ?? "") != v {
                oursNewer = true
            }
        }
        for (k, v) in last where items[k] == nil && !v.isEmpty { oursNewer = true }
        saveStamps()
        if changed { reload() }
        return oursNewer
    }

    private func write(_ k: String, _ v: String) {
        let key = String(k.dropFirst(3))
        if k.hasPrefix("kc:") {
            Keychain.set(v.isEmpty ? nil : v, for: key)
        } else if v.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else if k.hasPrefix("ud:") {
            UserDefaults.standard.set(Data(v.utf8), forKey: key)
        } else if let o = try? JSONSerialization.jsonObject(with: Data(v.utf8), options: [.fragmentsAllowed]) {
            UserDefaults.standard.set(o, forKey: key)
        }
    }

    /// Everything that reads these picks up the new values.
    private func reload() {
        SmartHome.shared.reloadSaved()
        HomeLayout.shared.reload()
        fleet?.reloadSynced()
        last = snapshot()   // what the reloads saved back is the same settings
        Task {
            await SmartHome.shared.refreshCloud()
            await SmartThings.shared.refresh(full: true)
            await NestCameras.shared.load()
            Dreo.shared.start()
            await Dreo.shared.refresh(full: true)
            DecoWifi.shared.start()
            await DecoWifi.shared.refresh()
        }
    }

    private func items() -> [String: Any] {
        var items: [String: Any] = [:]
        for (k, v) in last { items[k] = ["v": v, "t": stamp(k)] }
        return items
    }

    // MARK: 1. Kept on the TVs

    private func storeKey(_ hub: Hub) -> SymmetricKey {
        SymmetricKey(data: SHA256.hash(data: Data("woodruff-settings-store:\(hub.connection.key)".utf8)))
    }

    /// Reads each TV's copy, takes what's newer, and writes back what we have that's newer.
    func syncTVs() async {
        guard let fleet, !fleet.hubs.isEmpty else { return }
        if tvBusy { tvAgain = true; return }
        tvBusy = true
        defer {
            tvBusy = false
            if tvAgain { tvAgain = false; Task { await syncTVs() } }
        }
        var saved: [String] = []
        for hub in fleet.hubs {
            let c = TVClient(hub: hub, routeID: "this")
            guard let folder = await folder(c) else { continue }
            let path = folder + "/settings.wsync"
            let key = storeKey(hub)
            var remote: [String: [String: Any]] = [:]
            var found = false      // a readable copy
            var exists = false     // any file there (one that can't be read is replaced)
            if let (d, _) = try? await c.t.data("GET", "/api/download", query: ["path": path], contentType: nil, timeout: 15) {
                exists = true
                if let box = try? AES.GCM.SealedBox(combined: d), let plain = try? AES.GCM.open(box, using: key),
                   let o = try? JSONSerialization.jsonObject(with: plain) as? [String: Any], let its = o["items"] as? [String: [String: Any]] {
                    remote = its
                    found = true
                }
            }
            let oursNewer = apply(remote)
            if !found || oursNewer {
                guard let plain = try? JSONSerialization.data(withJSONObject: ["v": 1, "from": me, "items": items()]),
                      let sealed = try? AES.GCM.seal(plain, using: key).combined else { continue }
                let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("settings-\(UUID().uuidString).wsync")
                do {
                    try sealed.write(to: tmp)
                    defer { try? FileManager.default.removeItem(at: tmp) }
                    if exists { try? await c.delete(path) }
                    _ = try await c.upload(file: tmp, to: folder, name: "settings.wsync")
                } catch { continue }
            }
            saved.append(hub.name)
        }
        if saved.isEmpty {
            status = "Can’t reach a TV right now. Changes are kept here and saved when one answers."
        } else {
            lastSynced = Date()
            status = "Saved on \(saved.joined(separator: ", "))"
        }
    }

    /// Where the copy lives on a TV: a hidden folder at the top of its storage.
    private func folder(_ c: TVClient) async -> String? {
        if let f = folders[c.hub.id] { return f }
        guard let root = (try? await c.roots())?.first?.path else { return nil }
        for name in [".woodruff", "Woodruff Settings"] {
            let f = root.hasSuffix("/") ? root + name : root + "/" + name
            if (try? await c.list(f)) == nil { try? await c.mkdir(in: root, name: name) }
            if (try? await c.list(f)) != nil { folders[c.hub.id] = f; return f }
        }
        return nil
    }

    // MARK: 2. Straight across the Wi‑Fi

    private func payload() -> Data? {
        guard let plain = try? JSONSerialization.data(withJSONObject: ["from": me, "items": items()]) else { return nil }
        var boxes: [String: String] = [:]
        for (id, key) in keys() {
            if let sealed = try? AES.GCM.seal(plain, using: key).combined { boxes[id] = sealed.base64EncodedString() }
        }
        guard !boxes.isEmpty else { return nil }
        return try? JSONSerialization.data(withJSONObject: ["boxes": boxes])
    }

    /// One key per paired TV, from its pairing key.
    private func keys() -> [String: SymmetricKey] {
        var out: [String: SymmetricKey] = [:]
        for h in fleet?.hubs ?? [] where !h.connection.key.isEmpty {
            out[h.id] = SymmetricKey(data: SHA256.hash(data: Data("woodruff-settings-sync:\(h.connection.key)".utf8)))
        }
        return out
    }

    private func broadcast() {
        guard let data = payload() else { return }
        for ep in peers.values { send(data, to: ep) }
    }

    private func send(_ data: Data, to ep: NWEndpoint) {
        let c = NWConnection(to: ep, using: .tcp)
        c.stateUpdateHandler = { s in
            switch s {
            case .ready: c.send(content: data, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { c.cancel() }
            })
            case .failed, .waiting: c.cancel()
            default: break
            }
        }
        c.start(queue: .main)
    }

    private func listen() {
        guard let l = try? NWListener(using: .tcp) else { return }
        l.service = NWListener.Service(name: me, type: Self.service)
        l.newConnectionHandler = { [weak self] c in
            c.start(queue: .main)
            self?.receive(c, Data())
        }
        l.stateUpdateHandler = { [weak self] s in
            if case .failed = s { Task { @MainActor in self?.listener = nil } }
        }
        l.start(queue: .main)
        listener = l
    }

    nonisolated private func receive(_ c: NWConnection, _ buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            var buf = buffer
            if let data { buf.append(data) }
            if done || error != nil || buf.count > 4 << 20 {
                c.cancel()
                let final = buf
                Task { @MainActor in self?.handle(final) }
            } else {
                self?.receive(c, buf)
            }
        }
    }

    private func handle(_ data: Data) {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let boxes = o["boxes"] as? [String: String] else { return }
        let mine = keys()
        for (id, b64) in boxes {
            guard let key = mine[id], let raw = Data(base64Encoded: b64), let box = try? AES.GCM.SealedBox(combined: raw),
                  let plain = try? AES.GCM.open(box, using: key),
                  let p = try? JSONSerialization.jsonObject(with: plain) as? [String: Any],
                  (p["from"] as? String) != me, let items = p["items"] as? [String: [String: Any]] else { continue }
            if apply(items) { broadcast() }
            return
        }
    }

    private func browse() {
        let b = NWBrowser(for: .bonjour(type: Self.service, domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                guard let self else { return }
                var found: [String: NWEndpoint] = [:]
                for r in results {
                    if case let .service(name, _, _, _) = r.endpoint, name != self.me { found[name] = r.endpoint }
                }
                let fresh = found.keys.filter { self.peers[$0] == nil }
                self.peers = found
                if !fresh.isEmpty, let data = self.payload() { for n in fresh { if let ep = found[n] { self.send(data, to: ep) } } }
            }
        }
        b.start(queue: .main)
        browser = b
    }
}
