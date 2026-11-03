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
    }

    private var server = "us"
    private var token = ""
    private var fans: [String: Fan] = [:]
    private var socket: URLSessionWebSocketTask?
    private var loop: Task<Void, Never>?
    private var keepalive: Task<Void, Never>?

    func start() {
        guard connected, loop == nil, !Demo.isOn else { return }
        loop = Task { [weak self] in
            var full = true
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh(full: full)
                full = false
                try? await Task.sleep(nanoseconds: 60_000_000_000)
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
        fans = [:]
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
        if (data["region"] as? String) == "EU", server != "eu" {
            server = "eu"
            data = try await attempt()
        }
        guard let t = data["access_token"] as? String else { throw OAuthRelay.Failure.refused("Dreo didn’t accept that email and password.") }
        token = t
    }

    private func request(_ method: String, _ path: String, query: [String: String] = [:], body: [String: Any]? = nil, auth: Bool = true) async throws -> [String: Any] {
        var c = URLComponents(string: "https://app-api-\(server).dreo-tech.com\(path)")!
        c.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } + [URLQueryItem(name: "timestamp", value: String(Int(Date().timeIntervalSince1970 * 1000)))]
        var r = URLRequest(url: c.url!, timeoutInterval: 15)
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
        if code == 401 { token = ""; throw OAuthRelay.Failure.refused("Dreo sign-in expired.") }
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
            if token.isEmpty { try await login(); openSocket() }
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
                    next[sn] = f
                }
                fans = next
            }
            for sn in fans.keys {
                guard let mixed = (try? await request("GET", "/api/user-device/device/state", query: ["deviceSn": sn]))?["mixed"] as? [String: Any] else { continue }
                apply(sn, mixed.mapValues { ($0 as? [String: Any])?["state"] ?? $0 }, initial: true)
            }
            error = nil
            publish()
        } catch {
            self.error = error.localizedDescription
            if !connected { return }
        }
    }

    /// Takes a fan's state (from a full read, or a live report).
    private func apply(_ sn: String, _ s: [String: Any], initial: Bool = false) {
        guard var f = fans[sn] else { return }
        if initial {
            f.powerKey = s["fanon"] != nil ? "fanon" : "poweron"
            f.swingKey = ["shakehorizon", "hoscon", "oscmode"].first { s[$0] != nil } ?? f.swingKey
        }
        if let v = s[f.powerKey] ?? s["poweron"] ?? s["fanon"] { f.on = bool(v) }
        if let v = s["windlevel"] as? NSNumber { f.level = v.intValue }
        for k in ["shakehorizon", "hoscon", "oscmode"] { if let v = s[k] { f.swing = bool(v); if f.swingKey == nil { f.swingKey = k } } }
        fans[sn] = f
    }

    private func bool(_ v: Any) -> Bool {
        if let b = v as? Bool { return b }
        if let n = v as? NSNumber { return n.intValue != 0 }
        return false
    }

    private func publish() {
        AccessoryStore.shared.fromDreo = fans.values.map { f in
            var d = HomeDevice(id: "dreo:" + f.sn, name: f.name, source: "dreo", kind: .fan, zone: f.room, status: "")
            d.isOn = f.on
            d.speed = Int((Double(f.level) * 100 / Double(max(1, f.maxSpeed))).rounded())
            d.swing = f.swingKey == nil ? nil : f.swing
            d.status = f.on ? "Speed \(f.level) of \(f.maxSpeed)" + (f.swing ? " · Oscillating" : "") : "Off"
            return d
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: Live connection

    private func openSocket() {
        socket?.cancel(with: .goingAway, reason: nil)
        guard !token.isEmpty, let url = URL(string: "wss://wsb-\(server).dreo-tech.com/websocket?accessToken=\(token)&timestamp=\(Int(Date().timeIntervalSince1970 * 1000))") else { return }
        let ws = URLSession.shared.webSocketTask(with: url)
        socket = ws
        ws.resume()
        listen(ws)
        keepalive?.cancel()
        keepalive = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard let self, self.socket === ws else { return }
                try? await ws.send(.string("2"))
            }
        }
    }

    private func listen(_ ws: URLSessionWebSocketTask) {
        ws.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.socket === ws else { return }
                switch result {
                case .success(let m):
                    if case let .string(text) = m, let d = text.data(using: .utf8),
                       let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                       let sn = o["devicesn"] as? String, let reported = o["reported"] as? [String: Any] {
                        self.apply(sn, reported)
                        self.publish()
                    }
                    self.listen(ws)
                case .failure:
                    // Dropped: open again shortly (signing in again if the token ran out).
                    self.socket = nil
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    if self.connected {
                        if (try? await self.login()) != nil { self.openSocket() }
                    }
                }
            }
        }
    }

    // MARK: Commands

    func send(_ d: HomeDevice, _ cmd: DeviceCommand) {
        let sn = String(d.id.dropFirst(5))
        guard let f = fans[sn] else { return }
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
        Task {
            if socket == nil { if token.isEmpty { try? await login() }; openSocket(); try? await Task.sleep(nanoseconds: 800_000_000) }
            guard let ws = socket,
                  let data = try? JSONSerialization.data(withJSONObject: ["deviceSn": sn, "method": "control", "params": params, "timestamp": Int(Date().timeIntervalSince1970 * 1000)]),
                  let text = String(data: data, encoding: .utf8) else { error = "Couldn’t reach Dreo."; return }
            do { try await ws.send(.string(text)) } catch { self.error = "Couldn’t reach Dreo." }
        }
    }
}

/// The Dreo part of Settings → Devices.
struct DreoSection: View {
    private let dreo = Dreo.shared
    @State private var email = Keychain.get("dreo.email") ?? ""
    @State private var password = ""

    var body: some View {
        Section {
            if dreo.connected {
                LabeledContent("Dreo", value: "\(AccessoryStore.shared.fromDreo.count) fan\(AccessoryStore.shared.fromDreo.count == 1 ? "" : "s")")
                Button("Refresh") { Task { await dreo.refresh(full: true) } }
                Button("Disconnect", role: .destructive) { dreo.signOut() }
            } else {
                TextField("Dreo Email", text: $email)
                    .autocorrectionDisabled()
                    #if os(iOS)
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
