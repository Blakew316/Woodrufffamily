import Foundation
import Network
import CryptoKit
import WoodruffKit

/// Keeps what the family types in (API keys, sign-ins, app keys, light and speaker names, rooms) the same on
/// the iPhone and the Mac. The two find each other on the home Wi‑Fi and swap changes straight away,
/// encrypted with the TVs' pairing key, which both already have and nothing else on the network does.
/// The newest change to each item wins; a sign-out on one signs out the other.
@MainActor
final class SettingsSync {
    static let shared = SettingsSync()
    static let service = "_woodruffsync._tcp"

    /// Keychain items and saved settings that travel.
    static let keychainKeys = [
        "govee.key",
        "st.client", "st.secret", "st.access", "st.refresh", "st.expires", "st.token",
        "nest.project", "nest.client", "nest.secret", "nest.access", "nest.refresh", "nest.expires", "nest.scopes", "nest.subscription",
        "github.token",
    ]
    static let defaultsKeys = ["smartNames", "smartRooms", "smartExtraRooms", "goveeManualIPs"]

    private let me: String = {
        if let s = UserDefaults.standard.string(forKey: "sync.id") { return s }
        let s = UUID().uuidString
        UserDefaults.standard.set(s, forKey: "sync.id")
        return s
    }()
    /// When each item last changed here (or arrived from the other device).
    private var stamps: [String: Double] = (UserDefaults.standard.dictionary(forKey: "sync.stamps") as? [String: Double]) ?? [:]
    private var last: [String: String] = [:]
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var peers: [String: NWEndpoint] = [:]
    private weak var fleet: Fleet?
    private var loop: Task<Void, Never>?

    func start(_ fleet: Fleet) {
        guard loop == nil, !Demo.isOn else { return }
        self.fleet = fleet
        last = snapshot()
        listen()
        browse()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                self?.check()
            }
        }
    }

    /// Back to the front: look for the other device again and swap everything.
    func wake() {
        guard loop != nil else { return }
        if listener == nil { listen() }
        browser?.cancel(); browser = nil
        browse()
        check()
        broadcast()
    }

    // MARK: What's here

    private func canonical(_ key: String) -> String {
        if key.hasPrefix("kc:") { return Keychain.get(String(key.dropFirst(3))) ?? "" }
        guard let d = UserDefaults.standard.data(forKey: String(key.dropFirst(3))),
              let o = try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed]),
              let c = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys, .fragmentsAllowed]) else { return "" }
        return String(decoding: c, as: UTF8.self)
    }

    private func snapshot() -> [String: String] {
        var out: [String: String] = [:]
        for k in Self.keychainKeys { out["kc:" + k] = canonical("kc:" + k) }
        for k in Self.defaultsKeys { out["ud:" + k] = canonical("ud:" + k) }
        return out
    }

    /// An item's age: its stamp, or (never stamped) the oldest possible if it has a value, never if it hasn't.
    private func stamp(_ k: String) -> Double { stamps[k] ?? ((last[k] ?? "").isEmpty ? 0 : 1) }

    private func check() {
        let now = snapshot()
        var changed = false
        for (k, v) in now where last[k] != nil && last[k] != v {
            stamps[k] = Date().timeIntervalSince1970
            changed = true
        }
        last = now
        if changed { saveStamps(); broadcast() }
    }

    private func saveStamps() { UserDefaults.standard.set(stamps, forKey: "sync.stamps") }

    // MARK: Taking the other device's changes

    private func apply(_ items: [String: [String: Any]]) {
        var changed = false
        var oursNewer = false
        for (k, item) in items where k.hasPrefix("kc:") || k.hasPrefix("ud:") {
            let t = (item["t"] as? NSNumber)?.doubleValue ?? 0
            let v = item["v"] as? String ?? ""
            let mine = stamp(k)
            if t > mine && v != (last[k] ?? "") {
                write(k, v)
                last[k] = v
                stamps[k] = t
                changed = true
            } else if t > mine {
                stamps[k] = t
            } else if mine > t && (last[k] ?? "") != v {
                oursNewer = true
            }
        }
        // Theirs may lack things only we have.
        for k in last.keys where items[k] == nil && !(last[k] ?? "").isEmpty { oursNewer = true }
        if changed {
            saveStamps()
            reload()
        }
        if oursNewer { broadcast() }
    }

    private func write(_ k: String, _ v: String) {
        let key = String(k.dropFirst(3))
        if k.hasPrefix("kc:") {
            Keychain.set(v.isEmpty ? nil : v, for: key)
        } else if v.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set(Data(v.utf8), forKey: key)
        }
    }

    /// Everything that reads these picks up the new values.
    private func reload() {
        SmartHome.shared.reloadSaved()
        Task {
            await SmartHome.shared.refreshCloud()
            await SmartThings.shared.refresh(full: true)
            await NestCameras.shared.load()
        }
    }

    // MARK: Sending

    private func payload() -> Data? {
        var items: [String: Any] = [:]
        for (k, v) in last { items[k] = ["v": v, "t": stamp(k)] }
        guard let plain = try? JSONSerialization.data(withJSONObject: ["from": me, "items": items]) else { return nil }
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

    // MARK: Receiving

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
            apply(items)
            return
        }
    }

    // MARK: Finding the other device

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
                // Someone new (the other app just opened): swap everything.
                if !fresh.isEmpty, let data = self.payload() { for n in fresh { if let ep = found[n] { self.send(data, to: ep) } } }
            }
        }
        b.start(queue: .main)
        browser = b
    }
}
