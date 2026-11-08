import SwiftUI
import Network
import CryptoKit
import WoodruffKit

/// Cync lights (GE's, now Savant's), through the Cync account, the way the Cync app does it. Cync has no public API;
/// this follows pycync, the open-source library behind Home Assistant's Cync integration. Sign in once with the
/// Cync email, password and the code Cync emails; the account's tokens travel to the other devices like the other
/// sign-ins. The lights show with the others (on and off, brightness, white and colour) on iPhone and Mac; the
/// Cync app keeps its own extras (effects, music, schedules).
///
/// Two parts: Cync's web API (sign-in, the homes and their lights, each light's Cync room) and Cync's command server
/// (a TLS connection carrying small binary packets: commands to a light, and each light's state as it changes).
@Observable @MainActor
final class Cync {
    static let shared = Cync()

    private static let corpID = "1007d2ad150c4000"
    private static let api = "https://api.gelighting.com"
    private static let host = "cm-sec.gelighting.com"
    private static let port: UInt16 = 23779
    /// The command server's certificate, remembered the first time: Cync's has long expired and doesn't carry the
    /// server's name, so Apple's usual check refuses it. The one seen first is trusted, and no other after it.
    nonisolated static let pinKey = "cync.serverPin"
    /// Cync's warm and cool ends; its white scale runs 1 (warm) to 100 (cool) between them.
    static let warmest = 2000, coolest = 7000
    /// Cync's device types that are lights (from pycync's list); plugs, switches and sensors aren't shown.
    private static let lightTypes: Set<Int> = [6, 8, 9, 10, 11, 13, 14, 15, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28,
        29, 30, 31, 32, 33, 34, 35, 41, 42, 43, 44, 46, 47, 71, 72, 73, 74, 75, 76, 82, 83, 97, 98, 99, 100, 101, 102,
        103, 104, 105, 107, 108, 109, 110, 123, 128, 129, 130, 131, 132, 133, 134, 135, 136, 137, 138, 139, 140, 141,
        142, 143, 144, 145, 146, 147, 148, 149, 150, 151, 152, 153, 154, 155, 156, 157, 158, 159, 160, 161, 162, 163,
        164, 165, 166, 167, 168, 169, 170, 171, 173, 174, 175, 177, 180, 181, 182]

    private(set) var error: String?
    private(set) var busy = false
    /// Signed in, waiting for the code Cync emailed.
    private(set) var needsCode = false
    var connected: Bool { Keychain.get("cync.access") != nil && Keychain.get("cync.authorize") != nil }

    /// One light as Cync describes it.
    private struct Light {
        var id: String            // "cync-<home>-<mesh>"
        var deviceID: Int         // its own id on the account (the one probed and sent through)
        var home: Int
        var mesh: Int             // its number in the home's mesh
        var name: String
        var room: String?
        var on = false
        var brightness = 100
        var kelvin: Int?
        var color: LightColor?
        var online = true
    }

    private var lights: [String: Light] = [:]
    /// Looked up on every packet, so kept as dictionaries: a device's home, a home's lights by mesh number, and each
    /// home's first light (commands go through it when no light has answered on the Wi‑Fi).
    @ObservationIgnored private var homeOfDevice: [Int: Int] = [:]
    @ObservationIgnored private var lightAt: [Int: [Int: String]] = [:]
    @ObservationIgnored private var firstDevice: [Int: Int] = [:]

    private func index() {
        var home: [Int: Int] = [:], at: [Int: [Int: String]] = [:], first: [Int: (String, Int)] = [:]
        for l in lights.values {
            home[l.deviceID] = l.home
            at[l.home, default: [:]][l.mesh % 1000] = l.id
            if let f = first[l.home], f.0 <= l.id { continue }
            first[l.home] = (l.id, l.deviceID)
        }
        homeOfDevice = home; lightAt = at; firstDevice = first.mapValues(\.1)
    }
    /// Each home's device that answered on the Wi‑Fi: commands for the home's lights go through it.
    private var hubs: [Int: Int] = [:]
    private var password = ""
    private var loop: Task<Void, Never>?
    private var connection: NWConnection?
    private var loggedIn = false
    private var buffer = Data()
    private var counter: UInt16 = 1
    private var innerCounter: UInt32 = 257
    private var pinger: Task<Void, Never>?
    private var reconnecting: Task<Void, Never>?
    private var reconnectWait: Double = 10

    func start() {
        guard connected, loop == nil, !Demo.isOn else { return }
        SmartHome.shared.cyncControl = { [weak self] l, c in self?.send(l, c) }
        loop = Task { [weak self] in
            // The list every ten minutes (lights added or renamed in the Cync app); states come over the connection.
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                try? await Task.sleep(nanoseconds: 600_000_000_000)
            }
        }
    }

    // MARK: Signing in

    func signIn(email: String, password: String) async {
        let e = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !e.isEmpty, !password.isEmpty else { error = "Enter your Cync email and password."; return }
        busy = true; error = nil
        defer { busy = false }
        self.password = password
        Keychain.set(e, for: "cync.email")
        do {
            let (code, j) = try await post("/v2/user_auth", ["corp_id": Self.corpID, "email": e, "password": password])
            if code == 200 { try save(j); clearPassword(); begin(); return }
            guard code == 400 else { throw failure(code, j) }
            // Cync wants a code: it emails one now.
            let (sent, sj) = try await post("/v2/two_factor/email/verifycode", ["corp_id": Self.corpID, "email": e, "local_lang": "en-us"])
            guard sent == 200 else { throw failure(sent, sj) }
            needsCode = true
        } catch { self.error = error.localizedDescription }
    }

    func submit(code: String) async {
        guard let e = Keychain.get("cync.email") else { needsCode = false; return }
        let c = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c.isEmpty else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            let (status, j) = try await post("/v2/user_auth/two_factor",
                                             ["corp_id": Self.corpID, "email": e, "password": password, "two_factor": c, "resource": 1])
            guard status == 200 else {
                throw status == 400 ? Failure("That code didn’t work. Check the newest email from Cync, or sign in again for a new one.") : failure(status, j)
            }
            try save(j)
            clearPassword()
            needsCode = false
            begin()
        } catch { self.error = error.localizedDescription }
    }

    func cancelCode() { needsCode = false; clearPassword() }

    func signOut() {
        loop?.cancel(); loop = nil
        reconnecting?.cancel(); reconnecting = nil; reconnectWait = 10
        disconnect()
        for k in ["cync.access", "cync.refresh", "cync.authorize", "cync.user", "cync.expires"] { Keychain.set(nil, for: k) }
        // Signing in again trusts the server's certificate afresh.
        UserDefaults.standard.removeObject(forKey: Self.pinKey)
        lights = [:]; hubs = [:]; index()
        needsCode = false
        error = nil
        SmartHome.shared.cyncControl = nil
        SmartHome.shared.setCyncLights([])
    }

    private func clearPassword() { password = "" }

    private func begin() {
        loop?.cancel(); loop = nil
        reconnecting?.cancel(); reconnecting = nil; reconnectWait = 10
        disconnect()
        start()
    }

    private func save(_ j: [String: Any]) throws {
        guard let access = j["access_token"] as? String, let authorize = j["authorize"] as? String,
              let user = (j["user_id"] as? NSNumber)?.intValue else { throw Failure("Cync answered without a sign-in.") }
        Keychain.set(access, for: "cync.access")
        Keychain.set(j["refresh_token"] as? String, for: "cync.refresh")
        Keychain.set(authorize, for: "cync.authorize")
        Keychain.set(String(user), for: "cync.user")
        let life = (j["expire_in"] as? NSNumber)?.doubleValue ?? 3600
        Keychain.set(String(Date().timeIntervalSince1970 + life), for: "cync.expires")
    }

    /// A fresh access token when the one kept is within the hour of running out.
    private func ensureToken() async throws {
        let expires = Double(Keychain.get("cync.expires") ?? "") ?? 0
        guard expires - Date().timeIntervalSince1970 < 3600 else { return }
        guard let refresh = Keychain.get("cync.refresh") else { throw Failure("Sign in to Cync again.") }
        let (code, j) = try await post("/v2/user/token/refresh", ["refresh_token": refresh])
        guard code == 200, let access = j["access_token"] as? String else {
            throw Failure("Cync signed Woodruff out. Sign in again in Settings → Smart Home → Devices.")
        }
        Keychain.set(access, for: "cync.access")
        if let r = j["refresh_token"] as? String { Keychain.set(r, for: "cync.refresh") }
        let life = (j["expire_in"] as? NSNumber)?.doubleValue ?? 3600
        Keychain.set(String(Date().timeIntervalSince1970 + life), for: "cync.expires")
    }

    // MARK: The web API

    struct Failure: LocalizedError {
        let message: String
        init(_ m: String) { message = m }
        var errorDescription: String? { message }
    }

    private func failure(_ code: Int, _ j: [String: Any]) -> Failure {
        let said = ((j["error"] as? [String: Any])?["msg"] as? String) ?? (j["msg"] as? String)
        if code == 401 || code == 403 { return Failure("Cync didn’t accept that email and password.") }
        return Failure(said.map { "Cync: \($0)" } ?? "Cync answered \(code).")
    }

    private func post(_ path: String, _ body: [String: Any]) async throws -> (Int, [String: Any]) {
        var r = URLRequest(url: URL(string: Self.api + path)!)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        r.timeoutInterval = 20
        let (d, resp) = try await URLSession.shared.data(for: r)
        let j = (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
        return ((resp as? HTTPURLResponse)?.statusCode ?? 0, j)
    }

    private func get(_ path: String) async throws -> Any {
        try await ensureToken()
        var r = URLRequest(url: URL(string: Self.api + path)!)
        r.setValue(Keychain.get("cync.access") ?? "", forHTTPHeaderField: "Access-Token")
        r.timeoutInterval = 20
        let (d, resp) = try await URLSession.shared.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let any = try? JSONSerialization.jsonObject(with: d)
        guard code == 200, let any else {
            if code == 401 || code == 403 { Keychain.set("0", for: "cync.expires") }   // refreshed next time
            throw failure(code, any as? [String: Any] ?? [:])
        }
        return any
    }

    /// The homes, their lights and Cync's rooms; then the connection for their states and commands.
    func refresh() async {
        guard connected, let user = Keychain.get("cync.user") else { return }
        do {
            guard let devices = try await get("/v2/user/\(user)/subscribe/devices") as? [[String: Any]] else {
                throw Failure("Cync sent an unexpected list.")
            }
            func int(_ v: Any?) -> Int? { (v as? NSNumber)?.intValue ?? (v as? String).flatMap(Int.init) }
            var found: [String: Light] = [:]
            for home in devices where int(home["source"]) == 5 {
                guard let homeID = int(home["id"]), let product = home["product_id"] else { continue }
                guard let props = try await get("/v2/product/\(product)/device/\(homeID)/property") as? [String: Any] else { continue }
                let bulbs = props["bulbsArray"] as? [[String: Any]] ?? []
                // Cync's rooms (groups that aren't subgroups), by the mesh numbers in them.
                var roomOf: [Int: String] = [:]
                for g in props["groupsArray"] as? [[String: Any]] ?? [] where (g["isSubgroup"] as? Bool) == false {
                    guard let name = g["displayName"] as? String else { continue }
                    for m in g["deviceIDArray"] as? [Any] ?? [] { if let m = int(m) { roomOf[m] = name } }
                }
                for b in bulbs {
                    guard let switchID = int(b["switchID"]), let raw = int(b["deviceID"]),
                          let type = int(b["deviceType"]), Self.lightTypes.contains(type),
                          devices.contains(where: { int($0["id"]) == switchID }) else { continue }
                    let mesh = homeID > 0 ? raw % homeID : raw
                    let id = "cync-\(homeID)-\(mesh)"
                    var l = lights[id] ?? Light(id: id, deviceID: switchID, home: homeID, mesh: mesh,
                                                name: (b["displayName"] as? String) ?? "Cync Light")
                    l.deviceID = switchID
                    l.name = (b["displayName"] as? String) ?? l.name
                    l.room = roomOf[mesh]
                    found[id] = l
                }
            }
            lights = found
            index()
            error = nil
            publish()
            connect()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func publish() {
        let list = lights.values.map { l -> GoveeLight in
            var g = GoveeLight(id: l.id, sku: "Cync", name: l.name, cloud: false, on: l.on, brightness: max(1, l.brightness),
                               color: l.color, kelvin: l.color == nil ? (l.kelvin ?? 2700) : nil, source: "cync", zone: l.room,
                               offline: l.online ? nil : true)
            g.kelvinMin = Self.warmest
            g.kelvinMax = Self.coolest
            return g
        }
        SmartHome.shared.setCyncLights(list)
    }

    // MARK: The command server

    private func connect() {
        guard connection == nil, !lights.isEmpty else {
            if loggedIn { queryStates() }
            return
        }
        // Cync's command server over TLS: a certificate Apple trusts is taken as usual; otherwise only the one this
        // device first saw from it (Cync's own, long expired and without the server's name).
        let tls = NWProtocolTLS.Options()
        let pinKey = Self.pinKey
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, secTrust, complete in
            let trust = sec_trust_copy_ref(secTrust).takeRetainedValue()
            if SecTrustEvaluateWithError(trust, nil) { complete(true); return }
            guard let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first else { complete(false); return }
            let print = SHA256.hash(data: SecCertificateCopyData(leaf) as Data).map { String(format: "%02x", $0) }.joined()
            let defaults = UserDefaults.standard
            if let pinned = defaults.string(forKey: pinKey) { complete(pinned == print); return }
            defaults.set(print, forKey: pinKey)
            complete(true)
        }, DispatchQueue.global(qos: .userInitiated))
        let c = NWConnection(host: NWEndpoint.Host(Self.host), port: NWEndpoint.Port(rawValue: Self.port)!,
                             using: NWParameters(tls: tls))
        connection = c
        loggedIn = false
        buffer = Data()
        c.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in self?.changed(state, c) }
        }
        c.start(queue: .main)
    }

    private func changed(_ state: NWConnection.State, _ c: NWConnection) {
        guard c === connection else { return }
        switch state {
        case .ready:
            write(loginPacket())
            receive(c)
        case .failed(let e):
            // A certificate Apple won't trust is said plainly; the lights stay listed but can't be changed.
            if case .tls = e { error = Self.tlsRefused }
            fallthrough
        case .cancelled:
            disconnect()
            reconnectSoon()
        case .waiting(let e):
            if case .tls = e { error = Self.tlsRefused }
        default: break
        }
    }

    /// The command server's certificate isn't the one trusted before.
    static let tlsRefused = "Cync’s command server showed a different certificate from the one trusted before, so the lights can’t be reached. If Cync changed it, sign out of Cync and back in to trust the new one."

    private func disconnect() {
        pinger?.cancel(); pinger = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        loggedIn = false
        // The hubs are found again by the next sign-in's probes.
        hubs = [:]
    }

    /// Tries the connection again, while signed in and the list is kept up to date: in ten seconds, then twice as
    /// long each time it fails again (up to five minutes), back to ten seconds once Cync signs it in.
    private func reconnectSoon() {
        guard connected, loop != nil, reconnecting == nil else { return }
        let wait = reconnectWait
        reconnectWait = min(wait * 2, 300)
        reconnecting = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard let self else { return }
            self.reconnecting = nil
            guard self.connected, self.loop != nil else { return }
            self.connect()
        }
    }

    private func write(_ d: Data) {
        connection?.send(content: d, completion: .contentProcessed { _ in })
    }

    private func receive(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, err in
            Task { @MainActor in
                guard let self, c === self.connection else { return }
                if let data { self.buffer.append(data); self.drain() }
                if done || err != nil { self.changed(.failed(err ?? NWError.posix(.ECONNRESET)), c) } else { self.receive(c) }
            }
        }
    }

    /// Takes each whole packet off the front of what's come in.
    private func drain() {
        while buffer.count >= 5 {
            let b = [UInt8](buffer.prefix(5))
            let length = Int(b[1]) << 24 | Int(b[2]) << 16 | Int(b[3]) << 8 | Int(b[4])
            // Cync's packets are small: a length this big means the stream is out of step (or garbage), and waiting
            // for it would hold everything after it (and the memory) forever. Start the connection again instead.
            guard length <= 1 << 20 else {
                buffer = Data()
                disconnect()
                reconnectSoon()
                return
            }
            guard buffer.count >= 5 + length else { return }
            let packet = [UInt8](buffer.prefix(5 + length))
            buffer.removeFirst(5 + length)
            handle(packet)
        }
    }

    private func handle(_ p: [UInt8]) {
        let type = Int(p[0] & 0xF0) >> 4
        let version = Int(p[0] & 0x07)
        let body = Array(p[5...])
        switch type {
        case 1:   // signed in
            loggedIn = true
            reconnectWait = 10
            if error == Self.tlsRefused { error = nil }
            pinger?.cancel()
            pinger = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 20_000_000_000)
                    self?.write(Data([0xd3, 0, 0, 0, 0]))
                }
            }
            // Which lights are on the Wi‑Fi (one per home carries the commands), then everyone's state.
            for l in lights.values { write(probePacket(l.deviceID)) }
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                self?.queryStates()
            }
        case 10:  // a light answered the probe
            guard version != 0, body.count >= 4 else { return }
            let device = be32(body, 0)
            if let home = homeOfDevice[device], hubs[home] == nil {
                hubs[home] = device
                queryStates()
            }
        case 4:   // a light changed (pushed)
            guard body.count >= 7 else { return }
            let device = be32(body, 0)
            guard body[4] == 1, body[5] == 1, body[6] == 6,
                  let home = homeOfDevice[device] else { return }
            var rest = Array(body[7...])
            var changed = false
            while rest.count > 3 {
                let length = (Int(rest[1]) << 8 | Int(rest[2])) & 0x0FFF
                guard length >= 7, rest.count >= 3 + length else { break }
                let e = Array(rest[3..<(3 + length)])
                changed = apply(home: home, mesh: Int(e[0]), on: e[1] != 0, brightness: Int(e[2]), mode: Int(e[3]),
                                rgb: (e[4], e[5], e[6]), online: nil) || changed
                rest = Array(rest[(3 + length)...])
            }
            if changed { publish() }
        case 7:   // an answer through the pipe: the states of a home's lights
            guard body.count > 8, body[7] == 0x7e, body.last == 0x7e else { return }
            let device = be32(body, 0)
            guard let home = homeOfDevice[device] ?? hubs.first(where: { $0.value == device })?.key else { return }
            var f = unescape(Array(body[8..<(body.count - 1)]))
            guard f.count > 9 else { return }
            f = Array(f[4...])   // the sequence number
            let command = f[1]
            let length = Int(f[2]) | Int(f[3]) << 8
            guard command == 0x52, f.count >= 5 + length else { return }
            let sum = f[1..<(f.count - 1)].reduce(0) { ($0 + Int($1)) % 256 }
            guard sum == Int(f[f.count - 1]) else { return }
            let data = Array(f[4..<(4 + length)])
            guard data.count >= 6 else { return }
            let count = Int(data[4]) | Int(data[5]) << 8
            var changed = false
            var at = 6
            for _ in 0..<count {
                guard data.count >= at + 24 else { break }
                let d = Array(data[at..<(at + 24)])
                changed = apply(home: home, mesh: Int(d[0]) | Int(d[1]) << 8, on: d[8] != 0, brightness: Int(d[12]),
                                mode: Int(d[16]), rgb: (d[20], d[21], d[22]), online: d[3] != 0) || changed
                at += 24
            }
            if changed { publish() }
        case 14:  // Cync closed the session
            disconnect()
            reconnectSoon()
        default: break
        }
    }

    /// A light's state as Cync reports it; true when it changed.
    private func apply(home: Int, mesh: Int, on: Bool, brightness: Int, mode: Int, rgb: (UInt8, UInt8, UInt8), online: Bool?) -> Bool {
        guard let id = lightAt[home]?[mesh], var l = lights[id] else { return false }
        let before = (l.on, l.brightness, l.kelvin, l.color, l.online)
        l.on = on
        l.brightness = max(0, min(100, brightness))
        if (1...100).contains(mode) {
            l.kelvin = Self.warmest + mode * (Self.coolest - Self.warmest) / 100
            l.color = nil
        } else if mode == 254 {
            l.color = LightColor(r: Int(rgb.0), g: Int(rgb.1), b: Int(rgb.2))
            l.kelvin = nil
        }
        if let online {
            l.online = online
            // A hub gone offline can't carry the home's commands; another is used until one answers again.
            if !online, hubs[home] == l.deviceID { hubs[home] = nil }
        }
        lights[id] = l
        return before != (l.on, l.brightness, l.kelvin, l.color, l.online)
    }

    private func queryStates() {
        guard loggedIn else { return }
        for home in firstDevice.keys {
            guard let hub = hub(home) else { continue }
            write(pipePacket(hub, inner(0x52, [0, 0, 0xff, 0xff, 0, 0], second: false)))
        }
    }

    /// The device commands for a home go through: one that answered on the Wi‑Fi, else any of its lights.
    private func hub(_ home: Int) -> Int? {
        hubs[home] ?? firstDevice[home]
    }

    // MARK: Commands

    func send(_ g: GoveeLight, _ c: LightCommand) {
        guard let l = lights[g.id] else { SmartHome.shared.cyncControlFailed(g.id, "Cync doesn’t list \(g.name) any more."); return }
        guard loggedIn, let hub = hub(l.home) else {
            SmartHome.shared.cyncControlFailed(g.id, "Cync isn’t connected right now; try again in a moment.")
            connect()
            return
        }
        let mesh = l.mesh % 1000, group = l.mesh / 1000
        let m0 = UInt8(mesh & 0xff), m1 = UInt8((mesh >> 8) & 0xff)
        let packet: [UInt8]
        switch c {
        case .power(let on):
            packet = inner(0xd0, [0, m0, UInt8(group & 0xff), 0xd0, 0x11, 0x02, on ? 1 : 0, 0, 0], second: true)
        case .brightness(let b):
            packet = inner(0xd2, [0, m0, m1, 0xd2, 0x11, 0x02, UInt8(max(0, min(100, b)))], second: true)
        case .kelvin(let k):
            let ct = max(1, min(100, (k - Self.warmest) * 100 / (Self.coolest - Self.warmest)))
            packet = inner(0xe2, [0, m0, m1, 0xe2, 0x11, 0x02, 0x05, UInt8(ct)], second: true)
        case .color(let col):
            packet = inner(0xe2, [0, m0, m1, 0xe2, 0x11, 0x02, 0x04, UInt8(max(0, min(255, col.r))),
                                  UInt8(max(0, min(255, col.g))), UInt8(max(0, min(255, col.b)))], second: true)
        }
        write(pipePacket(hub, packet))
        // Cync pushes the new state; ask too, in case the push doesn't come.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            self?.queryStates()
        }
    }

    // MARK: Packets (pycync's formats)

    private func header(_ type: UInt8, _ payload: [UInt8]) -> [UInt8] {
        let n = payload.count
        return [type << 4 | 3, UInt8(n >> 24 & 0xff), UInt8(n >> 16 & 0xff), UInt8(n >> 8 & 0xff), UInt8(n & 0xff)] + payload
    }

    private func loginPacket() -> Data {
        let user = UInt32(Keychain.get("cync.user").flatMap(Int.init) ?? 0)
        let auth = Array((Keychain.get("cync.authorize") ?? "").utf8)
        let payload: [UInt8] = [3] + be32(user) + [UInt8(auth.count >> 8 & 0xff), UInt8(auth.count & 0xff)] + auth + [0, 0, 0x1e]
        return Data(header(1, payload))
    }

    private func nextCounter() -> [UInt8] {
        let c = counter
        counter = counter == UInt16.max ? 1 : counter + 1
        return [UInt8(c >> 8), UInt8(c & 0xff)]
    }

    private func probePacket(_ device: Int) -> Data {
        Data(header(10, be32(UInt32(truncatingIfNeeded: device)) + nextCounter() + [0, 0x02]))
    }

    private func pipePacket(_ device: Int, _ inner: [UInt8]) -> Data {
        Data(header(7, be32(UInt32(truncatingIfNeeded: device)) + nextCounter() + [0] + inner))
    }

    /// An inner frame: sequence, direction (request), command, length, arguments, checksum; 0x7e at each end.
    private func inner(_ command: UInt8, _ args: [UInt8], second: Bool) -> [UInt8] {
        let seq = innerCounter
        innerCounter = innerCounter >= UInt32.max - 1 ? 257 : innerCounter + 1
        let seqBytes = [UInt8(seq & 0xff), UInt8(seq >> 8 & 0xff), UInt8(seq >> 16 & 0xff), UInt8(seq >> 24 & 0xff)]
        let a = second ? seqBytes + args : args
        let bodyBytes: [UInt8] = [command, UInt8(a.count & 0xff), UInt8(a.count >> 8 & 0xff)] + a
        let sum = UInt8(bodyBytes.reduce(0) { ($0 + Int($1)) % 256 })
        let frame = seqBytes + [0xf8] + bodyBytes + [sum]
        var escaped: [UInt8] = []
        for b in frame { if b == 0x7e { escaped += [0x7d, 0x5e] } else { escaped.append(b) } }
        return [0x7e] + escaped + [0x7e]
    }

    private func unescape(_ b: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var i = 0
        while i < b.count {
            if b[i] == 0x7d, i + 1 < b.count, b[i + 1] == 0x5e { out.append(0x7e); i += 2 } else { out.append(b[i]); i += 1 }
        }
        return out
    }

    private func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)] }
    private func be32(_ b: [UInt8], _ at: Int) -> Int { Int(b[at]) << 24 | Int(b[at + 1]) << 16 | Int(b[at + 2]) << 8 | Int(b[at + 3]) }
}

/// The Cync part of Settings → Smart Home → Devices.
struct CyncSection: View {
    private let cync = Cync.shared
    @State private var email = Keychain.get("cync.email") ?? ""
    @State private var password = ""
    @State private var code = ""

    var body: some View {
        Section {
            if cync.connected {
                LabeledContent("Lights", value: "\(SmartHome.shared.lights.filter(\.isCync).count)")
                Button("Refresh") { Task { await cync.refresh() } }
                Button("Disconnect", role: .destructive) { cync.signOut() }
            } else if cync.needsCode {
                Text("Cync emailed a code to \(email).")
                TextField("Code", text: $code)
                    #if os(iOS) || os(tvOS)
                    .keyboardType(.numberPad)
                    #endif
                Button {
                    Task { await cync.submit(code: code); if cync.connected { code = "" } }
                } label: {
                    HStack { Text("Finish Signing In"); if cync.busy { Spacer(); ProgressView() } }
                }
                .disabled(cync.busy || code.isEmpty)
                Button("Cancel") { cync.cancelCode(); code = "" }
            } else {
                TextField("Cync Email", text: $email)
                    .autocorrectionDisabled()
                    #if os(iOS) || os(tvOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                    #endif
                SecureField("Cync Password", text: $password)
                Button {
                    Task { await cync.signIn(email: email, password: password); password = "" }
                } label: {
                    HStack { Text("Sign In to Cync"); if cync.busy { Spacer(); ProgressView() } }
                }
                .disabled(cync.busy || email.isEmpty || password.isEmpty)
            }
            if let e = cync.error { Text(e).foregroundStyle(Palette.attention) }
        } header: { Text("Cync") } footer: {
            Text("Cync lights: on and off, brightness, white and colour, on iPhone and Mac. Sign in once; the other devices follow. Cync has no official way in for other apps, so this signs in the way the Cync app does; if Cync changes it, it may stop until Woodruff is updated.")
        }
    }
}
