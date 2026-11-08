import SwiftUI
import CryptoKit
import WoodruffKit

/// Dreo fans (and purifiers), through the Dreo account, the way the Dreo app does it (Dreo has no public API;
/// this follows the open-source homebridge-dreo plugin). Sign in once with the Dreo email and password; the
/// fans show with the other devices on iPhone and Mac. Commands and live changes go over Dreo's web socket.
@Observable @MainActor
final class Dreo {
    static let shared = Dreo()

    // The Dreo app's own client (from homebridge-dreo).
    private static let clientID = "d8a56a73d93b427cad801116dc4d3188"
    private static let clientSecret = "2ac9b179f7e84be58bb901d6ed8bf374"
    private static let himei = "463299817f794e52a228868167df3f34"
    private static let ua = "dreo/2.8.1 (iPhone; iOS 18.0.0; Scale/3.00)"
    private static let fanPrefixes = ["DR-HTF", "DR-HAF", "DR-HPF", "DR-HCF", "DR-HAP"]
    private static let fallbackMaxSpeed = ["DR-HPF004S": 9, "DR-HPF007S": 9, "DR-HPF008S": 9, "DR-HTF024S": 9]

    private(set) var error: String?
    private(set) var busy = false
    var connected: Bool { Keychain.get("dreo.email") != nil && Keychain.get("dreo.password") != nil }

    /// One fan as Dreo describes it, and how to talk to it.
    private struct Fan {
        var sn: String
        var name: String
        var model: String
        var room: String?
        var maxSpeed: Int
        var powerKey = "poweron"
        var swingKey: String?
        var on = false
        var level = 1
        var swing = false
        /// Dreo's cloud can reach it (state "connected"); off the Wi‑Fi or unplugged, it can't.
        var online = true
    }

    /// The keys that swing a fan, in the order they're preferred when a fan reports more than one: tower fans
    /// use "oscon" (older ones "shakehorizon"), air circulators "hoscon" or the "oscmode" bitmask.
    private static let swingKeys = ["oscon", "shakehorizon", "hoscon", "oscmode"]

    private var server = "us"
    private var token = ""
    private var fans: [String: Fan] = [:]
    private var socket: URLSessionWebSocketTask?
    private var socketFailures = 0
    private var loop: Task<Void, Never>?
    private var keepalive: Task<Void, Never>?
    /// The fans have been read since the app opened (until then Home shows the ones kept from last time).
    @ObservationIgnored private var published = false

    func start() {
        guard connected, loop == nil, !Demo.isOn else { return }
        loop = Task { [weak self] in
            // Every minute each fan's state; every ten, the list too (fans added, renamed or moved in the Dreo app).
            var n = 0
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh(full: n % 10 == 0)
                n += 1
                // Every three minutes while the app isn't in use.
                await Fleet.pause(inUse: 60, idle: 180)
            }
        }
    }

    func signIn(email: String, password: String) async {
        let e = email.trimmingCharacters(in: .whitespacesAndNewlines), p = password
        guard !e.isEmpty, !p.isEmpty else { error = "Enter your Dreo email and password."; return }
        busy = true; error = nil
        defer { busy = false }
        Keychain.set(e, for: "dreo.email")
        Keychain.set(p, for: "dreo.password")
        token = ""
        server = "us"   // a new account starts on the US servers; the login moves it to the EU's if it lives there
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        await refresh(full: true)
        if error != nil {
            Keychain.set(nil, for: "dreo.email"); Keychain.set(nil, for: "dreo.password")
        } else {
            start()
        }
    }

    func signOut() {
        loop?.cancel(); loop = nil
        keepalive?.cancel(); keepalive = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        Keychain.set(nil, for: "dreo.email"); Keychain.set(nil, for: "dreo.password")
        token = ""
        server = "us"
        socketFailures = 0
        error = nil
        published = false
        pending = []
        fans = [:]
        for t in confirms.values { t.cancel() }
        confirms = [:]
        sentAt = [:]
        AccessoryStore.shared.fromDreo = []
    }

    // MARK: Account

    private func login() async throws {
        guard let email = Keychain.get("dreo.email"), let password = Keychain.get("dreo.password") else { throw OAuthRelay.Failure.refused("Sign in to Dreo.") }
        let hash = Insecure.MD5.hash(data: Data(password.utf8)).map { String(format: "%02x", $0) }.joined()
        func attempt() async throws -> [String: Any] {
            try await request("POST", "/api/oauth/login", body: [
                "client_id": Self.clientID, "client_secret": Self.clientSecret, "email": email, "encrypt": "ciphertext",
                "grant_type": "email-password", "himei": Self.himei, "password": hash, "scope": "all",
            ], auth: false)
        }
        var data = try await attempt()
        // European accounts live on Dreo's EU servers.
        if (data["region"] as? String)?.uppercased() == "EU", server != "eu" {
            server = "eu"
            data = try await attempt()
        }
        guard let t = data["access_token"] as? String else { throw OAuthRelay.Failure.refused("Dreo didn’t accept that email and password.") }
        token = t
    }

    private func request(_ method: String, _ path: String, query: [String: String] = [:], body: [String: Any]? = nil, auth: Bool = true, retried: Bool = false) async throws -> [String: Any] {
        guard var c = URLComponents(string: "https://app-api-\(server).dreo-tech.com\(path)") else { throw OAuthRelay.Failure.refused("Dreo answered oddly.") }
        c.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } + [URLQueryItem(name: "timestamp", value: String(Int(Date().timeIntervalSince1970 * 1000)))]
        guard let url = c.url else { throw OAuthRelay.Failure.refused("Dreo answered oddly.") }
        var r = URLRequest(url: url, timeoutInterval: 15)
        r.httpMethod = method
        r.setValue(Self.ua, forHTTPHeaderField: "ua")
        r.setValue("en", forHTTPHeaderField: "lang")
        r.setValue("okhttp/4.9.1", forHTTPHeaderField: "user-agent")
        if auth { r.setValue("Bearer \(token)", forHTTPHeaderField: "authorization") }
        if let body {
            r.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "content-type")
            r.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (d, resp) = try await URLSession.shared.data(for: r)
        let json = (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 {
            token = ""
            // The sign-in ran out: sign in again with the saved email and password and ask once more, rather than
            // showing "expired" until the next minute's look.
            if auth, !retried {
                try await login()
                return try await request(method, path, query: query, body: body, auth: auth, retried: true)
            }
            throw OAuthRelay.Failure.refused(auth ? "Dreo signed Woodruff out. Sign in again in Settings → Smart Home → Devices."
                                                  : "Dreo didn’t accept that email and password.")
        }
        guard code == 200 else { throw OAuthRelay.Failure.refused((json["msg"] as? String).map { "Dreo: \($0)" } ?? "Dreo answered \(code).") }
        if let c = json["code"] as? Int, c != 0 {
            throw OAuthRelay.Failure.refused((json["msg"] as? String).map { "Dreo: \($0)" } ?? "Dreo refused (\(c)).")
        }
        return json["data"] as? [String: Any] ?? [:]
    }

    // MARK: Fans

    func refresh(full: Bool) async {
        guard connected else { return }
        do {
            if token.isEmpty { try await login() }
            if socket == nil { openSocket() }
            if full || fans.isEmpty {
                let list = (try await request("GET", "/api/app/index/family/room/devices"))["list"] as? [[String: Any]] ?? []
                var next: [String: Fan] = [:]
                for d in list {
                    guard let sn = d["sn"] as? String, let model = d["model"] as? String,
                          Self.fanPrefixes.contains(where: { model.hasPrefix($0) }) else { continue }
                    let speedConf = ((d["controlsConf"] as? [String: Any])?["control"] as? [[String: Any]])?.first { ($0["type"] as? String) == "Speed" }
                    let maxText = ((speedConf?["items"] as? [[String: Any]])?.dropFirst().first?["text"]).map { "\($0)" }
                    let max = maxText.flatMap(Int.init) ?? Self.fallbackMaxSpeed[model] ?? 4
                    var f = fans[sn] ?? Fan(sn: sn, name: d["deviceName"] as? String ?? "Dreo Fan", model: model, maxSpeed: max)
                    f.name = d["deviceName"] as? String ?? f.name
                    f.room = (d["roomName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    f.maxSpeed = max
                    // Some lists say outright whether the fan is reachable; the state read below has the final word.
                    if let v = d["online"] ?? d["connected"], !(v is NSNull) { f.online = bool(v) }
                    next[sn] = f
                }
                fans = next
            }
            for sn in Array(fans.keys) {
                let asked = Date()
                guard let mixed = (try? await request("GET", "/api/user-device/device/state", query: ["deviceSn": sn]))?["mixed"] as? [String: Any] else { continue }
                // A change sent while this was being read (or just before, Dreo's cloud still catching up) mustn't
                // be undone by it: the fan's own report, and the check a few seconds after the change, say how it is.
                if let sent = sentAt[sn], sent > asked.addingTimeInterval(-5) { continue }
                apply(sn, mixed.mapValues { ($0 as? [String: Any])?["state"] ?? $0 }, initial: true)
            }
            if token.isEmpty { try await login() }   // a 401 on a state read: sign in again for the socket and next time
            if error != nil { error = nil }
            publish()
        } catch {
            self.error = error.localizedDescription
            if !connected { return }
            // Nothing from Dreo yet since the app opened: the fans kept from last time don't show as they were then
            // ("Speed 3"), but as not responding until Dreo answers.
            if !published {
                let kept = AccessoryStore.shared.fromDreo
                let dimmed = kept.map { d -> HomeDevice in
                    var d = d
                    d.reachable = false
                    return d
                }
                if dimmed != kept { AccessoryStore.shared.fromDreo = dimmed }
            }
        }
    }

    /// Takes a fan's state (from a full read, or a live report).
    private func apply(_ sn: String, _ s: [String: Any], initial: Bool = false) {
        guard var f = fans[sn] else { return }
        if initial {
            // Ceiling fans with a light switch the fan with "fanon" ("poweron" is the whole unit there).
            f.powerKey = s["fanon"] != nil ? "fanon" : "poweron"
            f.swingKey = Self.swingKeys.first { s[$0] != nil } ?? f.swingKey
        }
        if let v = s["connected"], !(v is NSNull) { f.online = bool(v) }
        if let v = s[f.powerKey] { f.on = bool(v) }
        if let v = s["windlevel"] as? NSNumber { f.level = max(1, min(f.maxSpeed, v.intValue)) }
        if f.swingKey == nil { f.swingKey = Self.swingKeys.first { s[$0] != nil } }
        if let k = f.swingKey, let v = s[k] { f.swing = bool(v) }
        fans[sn] = f
    }

    private func bool(_ v: Any) -> Bool {
        if let b = v as? Bool { return b }
        if let n = v as? NSNumber { return n.intValue != 0 }
        if let t = v as? String { return ["true", "1", "on", "yes"].contains(t.lowercased()) }
        return false
    }

    private func publish() {
        let list = fans.values.map { f -> HomeDevice in
            var d = HomeDevice(id: "dreo:" + f.sn, name: f.name, source: "dreo", kind: .fan, zone: f.room, status: "")
            d.isOn = f.on
            d.product = f.model
            d.speed = Int((Double(f.level) * 100 / Double(max(1, f.maxSpeed))).rounded())
            d.swing = f.swingKey == nil ? nil : f.swing
            d.reachable = f.online
            d.status = !f.online ? "Offline" : f.on ? "Speed \(f.level) of \(f.maxSpeed)" + (f.swing ? " · Oscillating" : "") : "Off"
            return d
        }
        // By name (two of the same name in a steady order, so the list doesn't seem to change when it hasn't).
        .sorted { a, b in
            let order = a.name.localizedStandardCompare(b.name)
            return order == .orderedSame ? a.id < b.id : order == .orderedAscending
        }
        // Only a real change reaches Home: most of the fans' live reports and each minute's read change nothing.
        if AccessoryStore.shared.fromDreo != list { AccessoryStore.shared.fromDreo = list }
        published = true
    }

    // MARK: Live connection

    private func openSocket() {
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        guard !token.isEmpty, let url = URL(string: "wss://wsb-\(server).dreo-tech.com/websocket?accessToken=\(token)&timestamp=\(Int(Date().timeIntervalSince1970 * 1000))") else { return }
        let ws = URLSession.shared.webSocketTask(with: url)
        socket = ws
        ws.resume()
        listen(ws)
        // Dreo's server drops a quiet socket: say "2" every 15 s (as the Dreo app does). If that can't be
        // sent, the socket is dead; ending it makes the listener reconnect.
        keepalive?.cancel()
        keepalive = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard let self, self.socket === ws, !Task.isCancelled else { return }
                do { try await ws.send(.string("2")) } catch {
                    if self.socket === ws { ws.cancel(with: .abnormalClosure, reason: nil) }
                    return
                }
            }
        }
        // Anything waiting for the socket goes now (sends wait for the handshake).
        flush()
    }

    private func listen(_ ws: URLSessionWebSocketTask) {
        ws.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.socket === ws else { return }
                switch result {
                case .success(let m):
                    if self.socketFailures != 0 { self.socketFailures = 0 }
                    var text: String?
                    switch m {
                    case .string(let t): text = t
                    case .data(let d): text = String(data: d, encoding: .utf8)
                    @unknown default: text = nil
                    }
                    if let text, let d = text.data(using: .utf8),
                       let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                       let sn = o["devicesn"] as? String, let reported = o["reported"] as? [String: Any] {
                        self.apply(sn, reported)
                        self.publish()
                    }
                    self.listen(ws)
                case .failure:
                    // Dropped: open again, waiting longer each time it keeps failing (5 s up to 5 min). The
                    // saved sign-in is reused; it's only renewed every few failures in case it ran out.
                    // A command waiting to go doesn't wait for the back-off: it reopens straight away.
                    self.socket = nil
                    self.keepalive?.cancel(); self.keepalive = nil
                    self.socketFailures += 1
                    let wait = self.pending.isEmpty ? min(300, 5 * pow(2, Double(min(self.socketFailures - 1, 6)))) : 1
                    try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                    guard self.connected, self.socket == nil else { return }
                    if self.socketFailures % 3 == 0 || self.token.isEmpty { _ = try? await self.login() }
                    if !self.token.isEmpty, self.socket == nil { self.openSocket() }
                }
            }
        }
    }

    // MARK: Commands

    /// A change waiting to go to a fan (kept until the socket takes it; newer changes to the same fan merge in).
    private struct Command {
        var sn: String
        var params: [String: Any]
        var at: Date
    }
    private var pending: [Command] = []
    private var flushing = false

    func send(_ d: HomeDevice, _ cmd: DeviceCommand) {
        let sn = String(d.id.dropFirst(5))
        guard let f = fans[sn] else {
            // Shown from last time, but Dreo hasn't answered since the app opened: ask now, then carry it out
            // (a tap used to do nothing at all here).
            guard connected else { error = "Sign in to Dreo in Settings → Smart Home → Devices."; return }
            Task {
                await refresh(full: true)
                if fans[sn] != nil { send(d, cmd) } else if error == nil { error = "Dreo doesn’t list \(d.name) any more." }
            }
            return
        }
        guard f.online else { error = "\(f.name) is offline. Check it’s plugged in and on the Wi‑Fi."; return }
        var params: [String: Any] = [:]
        switch cmd {
        case .power(let on): params[f.powerKey] = on
        case .speed(let pct):
            if pct <= 0 { params[f.powerKey] = false }
            else {
                params[f.powerKey] = true
                params["windlevel"] = max(1, min(f.maxSpeed, Int((Double(pct) * Double(f.maxSpeed) / 100).rounded())))
            }
        case .swing(let on):
            guard let k = f.swingKey else { return }
            params[k] = k == "oscmode" ? (on ? 1 : 0) : on
        default: return
        }
        // Show it straight away; Dreo's report confirms it.
        apply(sn, params)
        publish()
        error = nil
        sentAt[sn] = Date()
        confirmSoon(sn)
        if let i = pending.firstIndex(where: { $0.sn == sn }) {
            pending[i].params.merge(params) { _, new in new }
            pending[i].at = Date()
        } else {
            pending.append(Command(sn: sn, params: params, at: Date()))
        }
        flush()
    }

    /// When a change last went to each fan: state reads begun before then don't undo it.
    @ObservationIgnored private var sentAt: [String: Date] = [:]
    @ObservationIgnored private var confirms: [String: Task<Void, Never>] = [:]

    /// Reads the fan's state a few seconds after the last change to it, so one Dreo didn't carry out (the fan
    /// dropped off its Wi‑Fi, the command was lost) shows as it really is in moments, not at the next minute's
    /// refresh. The fan's own live report usually confirms it sooner.
    private func confirmSoon(_ sn: String) {
        confirms[sn]?.cancel()
        confirms[sn] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.confirms[sn] = nil
            guard let mixed = (try? await self.request("GET", "/api/user-device/device/state", query: ["deviceSn": sn]))?["mixed"] as? [String: Any] else { return }
            // Changed again meanwhile: that change's own check looks later.
            guard (self.sentAt[sn] ?? .distantPast) < Date().addingTimeInterval(-5) else { return }
            self.apply(sn, mixed.mapValues { ($0 as? [String: Any])?["state"] ?? $0 })
            self.publish()
        }
    }

    /// Sends what's waiting, opening the socket (and signing in) first if it's down. A send that fails ends the
    /// socket; the listener reopens it and the command goes then, so nothing is dropped. Changes more than two
    /// minutes old are let go (a fan shouldn't come on long after it was asked).
    private func flush() {
        guard !flushing, !pending.isEmpty, connected else { return }
        flushing = true
        Task {
            defer { flushing = false }
            pending.removeAll { $0.at.timeIntervalSinceNow < -120 }
            if socket == nil {
                if token.isEmpty { do { try await login() } catch { self.error = "Couldn’t reach Dreo."; return } }
                // openSocket flushes too; it's skipped while this one runs, so carry on here.
                if socket == nil { openSocket() }
            }
            guard socket != nil else { error = "Couldn’t reach Dreo."; return }
            while let c = pending.first {
                // The socket of the moment (refresh may have replaced it meanwhile).
                guard let ws = socket else { return }
                guard let data = try? JSONSerialization.data(withJSONObject: ["devicesn": c.sn, "method": "control", "params": c.params, "timestamp": Int(Date().timeIntervalSince1970 * 1000)]),
                      let text = String(data: data, encoding: .utf8) else { pending.removeFirst(); continue }
                do {
                    try await ws.send(.string(text))
                    // A change that waited for the socket counts from now: the fan only just got it.
                    sentAt[c.sn] = Date()
                    confirmSoon(c.sn)
                    // Changed again while it was going: it stays, and the loop sends the newer one.
                    if let i = pending.firstIndex(where: { $0.sn == c.sn }), pending[i].at == c.at { pending.remove(at: i) }
                } catch {
                    // The socket is dead: end it so the listener reconnects (quickly, since something waits).
                    // (If it was already replaced, try the new one.)
                    guard socket === ws else { continue }
                    ws.cancel(with: .abnormalClosure, reason: nil)
                    return
                }
            }
        }
    }
}

/// The Dreo part of Settings → Smart Home → Devices.
struct DreoSection: View {
    private let dreo = Dreo.shared
    @State private var email = Keychain.get("dreo.email") ?? ""
    @State private var password = ""

    var body: some View {
        Section {
            if dreo.connected {
                LabeledContent("Fans", value: "\(AccessoryStore.shared.fromDreo.count)")
                Button("Refresh") { Task { await dreo.refresh(full: true) } }
                Button("Disconnect", role: .destructive) { dreo.signOut() }
            } else {
                TextField("Dreo Email", text: $email)
                    .autocorrectionDisabled()
                    #if os(iOS) || os(tvOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                    #endif
                SecureField("Dreo Password", text: $password)
                Button {
                    Task { await dreo.signIn(email: email, password: password); if dreo.connected { password = "" } }
                } label: {
                    HStack { Text("Sign In to Dreo"); if dreo.busy { Spacer(); ProgressView() } }
                }
                .disabled(dreo.busy || email.isEmpty || password.isEmpty)
            }
            if let e = dreo.error { Text(e).foregroundStyle(Palette.attention) }
        } header: { Text("Dreo") } footer: {
            Text("Tower fans, air circulators, ceiling fans and purifiers: on and off, speed and oscillation, on iPhone and Mac. Dreo has no official way in for other apps, so this signs in the way the Dreo app does; if Dreo changes it, it may stop until Woodruff is updated.")
        }
    }
}
