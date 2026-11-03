import SwiftUI
import UserNotifications
import WoodruffKit

/// Samsung SmartThings: the washer, dryer, fridge, oven, dishwasher (and any other SmartThings device), over
/// Samsung's official API. Signed in once with the family's own SmartThings app keys; works on iPhone and Mac.
@Observable @MainActor
final class SmartThings {
    static let shared = SmartThings()
    static let api = "https://api.smartthings.com/v1"
    static let tokenURL = "https://auth-global.api.smartthings.com/oauth/token"
    /// Asked for in turn: the app's keys may have been made with fewer of these, and SmartThings refuses
    /// a sign-in that asks for any it doesn't have.
    static let scopeSets = ["r:devices:* x:devices:* r:locations:*", "r:devices:* x:devices:*", "r:devices:$ x:devices:$", "r:devices:*"]

    private(set) var error: String?
    private(set) var busy = false
    var connected: Bool { Keychain.get("st.refresh") != nil || Keychain.get("st.token") != nil }

    private var devices: [[String: Any]] = []
    /// Each appliance's last full status and its capabilities, for its controls.
    private(set) var raw: [String: [String: Any]] = [:]
    private(set) var capabilities: [String: Set<String>] = [:]
    private var roomNames: [String: String] = [:]
    private var loop: Task<Void, Never>?
    private var lastMachine: [String: String] = [:]
    private var listedAt: Date?

    func start() {
        guard loop == nil, !Demo.isOn else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.connected { await self.refresh(full: self.listedAt.map { $0.timeIntervalSinceNow < -600 } ?? true) }
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
    }

    // MARK: Sign-in

    var clientID: String { Keychain.get("st.client") ?? "" }

    /// Signs in through Samsung with the family's SmartThings app (its Client ID and Secret).
    func signIn(clientID: String, secret: String) async {
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines), sec = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !sec.isEmpty else { error = "Enter the Client ID and Secret first."; return }
        busy = true; error = nil
        defer { busy = false }
        do {
            var code: String?
            var lastError: Error?
            for scopes in Self.scopeSets {
                do {
                    code = try await OAuthRelay().signIn { state in
                        var c = URLComponents(string: "https://api.smartthings.com/oauth/authorize")!
                        c.queryItems = [
                            URLQueryItem(name: "client_id", value: id), URLQueryItem(name: "response_type", value: "code"),
                            URLQueryItem(name: "redirect_uri", value: OAuthRelay.redirect), URLQueryItem(name: "scope", value: scopes),
                            URLQueryItem(name: "state", value: state),
                        ]
                        return c.url!
                    }
                    break
                } catch {
                    lastError = error
                    // Only a scope the app wasn't made with is worth another try with fewer.
                    guard error.localizedDescription.contains("scope") else { throw error }
                    try? await Task.sleep(nanoseconds: 800_000_000)  // let the last sign-in sheet close first
                }
            }
            guard let code else {
                throw OAuthRelay.Failure.refused("SmartThings refused the permissions (\(lastError?.localizedDescription ?? "invalid scope")). Make sure the SmartThings app was created with r:devices:* and x:devices:*.")
            }
            let t = try await formPost(Self.tokenURL, ["grant_type": "authorization_code", "code": code, "client_id": id, "redirect_uri": OAuthRelay.redirect], basic: (id, sec))
            Keychain.set(id, for: "st.client")
            Keychain.set(sec, for: "st.secret")
            store(t)
            await refresh(full: true)
        } catch { self.error = error.localizedDescription }
    }

    /// A Personal Access Token from account.smartthings.com/tokens (new ones last 24 hours; good for a try).
    func useToken(_ token: String) async {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        Keychain.set(t, for: "st.token")
        Keychain.set(nil, for: "st.access"); Keychain.set(nil, for: "st.refresh")
        await refresh(full: true)
    }

    func signOut() {
        for k in ["st.access", "st.refresh", "st.expires", "st.token"] { Keychain.set(nil, for: k) }
        devices = []
        AccessoryStore.shared.fromSmartThings = []
    }

    private func store(_ t: [String: Any]) {
        if let a = t["access_token"] as? String { Keychain.set(a, for: "st.access") }
        if let r = t["refresh_token"] as? String { Keychain.set(r, for: "st.refresh") }
        let exp = (t["expires_in"] as? Double) ?? Double((t["expires_in"] as? Int) ?? 3600)
        Keychain.set(String(Date().addingTimeInterval(exp - 120).timeIntervalSince1970), for: "st.expires")
        Keychain.set(nil, for: "st.token")
    }

    @ObservationIgnored private var renewing: Task<String, Error>?

    /// The sign-in to use. A renewal runs one at a time (the renewal key works once, so two at once would
    /// sign the loser out); everyone else waits for it.
    private func token(force: Bool = false) async throws -> String {
        if let pat = Keychain.get("st.token") { return pat }
        if !force, let a = Keychain.get("st.access"), let e = Keychain.get("st.expires").flatMap(Double.init), e > Date().timeIntervalSince1970 { return a }
        if let running = renewing { return try await running.value }
        let t = Task { try await self.renew() }
        renewing = t
        defer { renewing = nil }
        return try await t.value
    }

    private func renew() async throws -> String {
        guard let r = Keychain.get("st.refresh"), let id = Keychain.get("st.client"), let sec = Keychain.get("st.secret") else {
            throw OAuthRelay.Failure.refused("Sign in to SmartThings again.")
        }
        let t = try await formPost(Self.tokenURL, ["grant_type": "refresh_token", "refresh_token": r, "client_id": id], basic: (id, sec))
        store(t)
        return Keychain.get("st.access") ?? ""
    }

    private func call(_ method: String, _ path: String, _ body: Any? = nil, retried: Bool = false) async throws -> [String: Any] {
        guard let url = URL(string: Self.api + path) else { throw OAuthRelay.Failure.refused("SmartThings answered oddly.") }
        var r = URLRequest(url: url, timeoutInterval: 20)
        r.httpMethod = method
        r.setValue("Bearer \(try await token(force: retried))", forHTTPHeaderField: "Authorization")
        if let body {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (d, resp) = try await URLSession.shared.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
        guard (200..<300).contains(code) else {
            // Signed in with an account (not a pasted token) and the sign-in ran out early: renew once and retry.
            if code == 401, !retried, Keychain.get("st.token") == nil, Keychain.get("st.refresh") != nil {
                return try await call(method, path, body, retried: true)
            }
            if code == 401 { throw OAuthRelay.Failure.refused(Keychain.get("st.token") != nil ? "The SmartThings token expired. Paste a new one or sign in." : "Sign in to SmartThings again.") }
            let msg = ((json["error"] as? [String: Any])?["message"] as? String) ?? "SmartThings answered \(code)."
            throw OAuthRelay.Failure.refused(msg)
        }
        return json
    }

    // MARK: Devices

    func refresh(full: Bool) async {
        guard connected else { return }
        do {
            if full || devices.isEmpty {
                devices = (try await call("GET", "/devices"))["items"] as? [[String: Any]] ?? []
                var rooms: [String: String] = [:]
                // Rooms need r:locations:*; without it devices just have no room.
                for loc in (try? await call("GET", "/locations"))?["items"] as? [[String: Any]] ?? [] {
                    guard let lid = loc["locationId"] as? String else { continue }
                    for room in (try? await call("GET", "/locations/\(lid)/rooms"))?["items"] as? [[String: Any]] ?? [] {
                        if let rid = room["roomId"] as? String, let n = room["name"] as? String { rooms[rid] = n }
                    }
                }
                roomNames = rooms
                listedAt = Date()
            }
            var out: [HomeDevice] = []
            let before = AccessoryStore.shared.fromSmartThings
            for dev in devices {
                guard let id = dev["deviceId"] as? String else { continue }
                capabilities["st:" + id] = allCaps(dev)
                guard let status = try? await call("GET", "/devices/\(id)/status") else {
                    // Couldn't read it this time: keep what it last said (never a false "done" or "Idle").
                    if let old = before.first(where: { $0.id == "st:" + id }) { out.append(old) }
                    continue
                }
                raw["st:" + id] = status
                if let d = make(dev, status) { out.append(d) }
            }
            error = nil
            AccessoryStore.shared.fromSmartThings = out
        } catch { self.error = error.localizedDescription }
    }

    /// Reads one appliance again (after a command), so its tile updates in a second.
    func reread(_ id: String) async {
        guard let dev = devices.first(where: { ($0["deviceId"] as? String) == id }),
              let status = try? await call("GET", "/devices/\(id)/status") else { return }
        raw["st:" + id] = status
        guard let d = make(dev, status) else { return }
        var list = AccessoryStore.shared.fromSmartThings
        if let i = list.firstIndex(where: { $0.id == d.id }) { list[i] = d } else { list.append(d) }
        AccessoryStore.shared.fromSmartThings = list
    }

    private func allCaps(_ dev: [String: Any]) -> Set<String> {
        var out = Set<String>()
        for comp in dev["components"] as? [[String: Any]] ?? [] {
            let cid = comp["id"] as? String ?? "main"
            for c in comp["capabilities"] as? [[String: Any]] ?? [] {
                if let id = c["id"] as? String { out.insert(cid == "main" ? id : "\(cid)/\(id)") }
            }
        }
        return out
    }

    /// A value from an appliance's last status.
    func read(_ deviceID: String, _ cap: String, _ attr: String, in component: String = "main") -> Any? {
        guard let st = raw[deviceID] else { return nil }
        return value(st, cap, attr, in: component)
    }

    /// The unit that came with a value ("F", "C", "W").
    func unit(_ deviceID: String, _ cap: String, _ attr: String, in component: String = "main") -> String? {
        ((((raw[deviceID]?["components"] as? [String: Any])?[component] as? [String: Any])?[cap] as? [String: Any])?[attr] as? [String: Any])?["unit"] as? String
    }

    func has(_ deviceID: String, _ cap: String, in component: String = "main") -> Bool {
        capabilities[deviceID]?.contains(component == "main" ? cap : "\(component)/\(cap)") == true
    }

    /// Sends one command, then reads the appliance again.
    func command(_ d: HomeDevice, _ cap: String, _ command: String, _ args: [Any] = [], component: String = "main") {
        let id = String(d.id.dropFirst(3))
        var c: [String: Any] = ["component": component, "capability": cap, "command": command]
        if !args.isEmpty { c["arguments"] = args }
        Task {
            do {
                _ = try await call("POST", "/devices/\(id)/commands", ["commands": [c]])
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await reread(id)
            } catch { self.error = error.localizedDescription }
        }
    }

    private func caps(_ dev: [String: Any]) -> Set<String> {
        let comps = dev["components"] as? [[String: Any]] ?? []
        let main = comps.first { ($0["id"] as? String) == "main" } ?? comps.first ?? [:]
        return Set((main["capabilities"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String })
    }

    private func value(_ status: [String: Any], _ cap: String, _ attr: String, in component: String = "main") -> Any? {
        (((status["components"] as? [String: Any])?[component] as? [String: Any])?[cap] as? [String: Any])
            .flatMap { ($0[attr] as? [String: Any])?["value"] }
            .flatMap { $0 is NSNull ? nil : $0 }
    }

    private func celsius(_ status: [String: Any], _ component: String, _ cap: String = "temperatureMeasurement", _ attr: String = "temperature") -> Double? {
        guard let t = (((status["components"] as? [String: Any])?[component] as? [String: Any])?[cap] as? [String: Any])?[attr] as? [String: Any],
              let v = (t["value"] as? NSNumber)?.doubleValue else { return nil }
        return (t["unit"] as? String) == "F" ? (v - 32) * 5 / 9 : v
    }

    private func make(_ dev: [String: Any], _ st: [String: Any]) -> HomeDevice? {
        guard let id = dev["deviceId"] as? String else { return nil }
        let c = caps(dev)
        let name = (dev["label"] as? String) ?? (dev["name"] as? String) ?? "Samsung"
        var d = HomeDevice(id: "st:" + id, name: name, source: "smartthings", kind: .appliance, zone: (dev["roomId"] as? String).flatMap { roomNames[$0] }, status: "")
        d.reachable = (value(st, "healthCheck", "DeviceWatch-DeviceStatus") as? String).map { $0 != "offline" } ?? true
        d.remoteControl = (value(st, "remoteControlStatus", "remoteControlEnabled") as? String) == "true"
        if let sw = value(st, "switch", "switch") as? String { d.isOn = sw == "on" }

        let machines: [(String, HomeDevice.Kind, String)] = [
            ("washerOperatingState", .washer, "Washing"), ("dryerOperatingState", .dryer, "Drying"),
            ("dishwasherOperatingState", .dishwasher, "Washing"), ("ovenOperatingState", .oven, "Cooking"),
        ]
        if let m = machines.first(where: { c.contains($0.0) }) {
            d.kind = m.1
            let state = value(st, m.0, "machineState") as? String
            d.machineState = state
            if let iso = value(st, m.0, "completionTime") as? String { d.endsAt = ISO8601DateFormatter.withFraction.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) }
            switch state {
            case "run":
                var s = m.2
                if let job = (value(st, m.0, "washerJobState") ?? value(st, m.0, "dryerJobState") ?? value(st, m.0, "dishwasherJobState")) as? String,
                   !["none", "finish", "finished"].contains(job) { s = job.capitalized }
                if let end = d.endsAt, end > .now { s += " · \(Int(ceil(end.timeIntervalSinceNow / 60))) min left" }
                d.status = s
            case "pause": d.status = "Paused"
            default: d.status = d.isOn == false ? "Off" : "Idle"
            }
            notifyIfFinished(d, name: name)
        } else if c.contains("refrigeration") || c.contains("custom.fridgeMode") || dev["ocf"].flatMap({ ($0 as? [String: Any])?["ocfDeviceType"] as? String })?.contains("refrigerator") == true {
            d.kind = .fridge
            var bits: [String] = []
            if let f = celsius(st, "cooler") ?? celsius(st, "main") { bits.append("Fridge \(temperatureText(f))") }
            if let z = celsius(st, "freezer") { bits.append("Freezer \(temperatureText(z))") }
            if (value(st, "contactSensor", "contact") as? String) == "open" { bits.insert("Door Open", at: 0); d.alert = true }
            d.status = bits.isEmpty ? "On" : bits.joined(separator: " · ")
        } else if c.contains("robotCleanerMovement") {
            d.kind = .vacuum
            let move = value(st, "robotCleanerMovement", "robotCleanerMovement") as? String
            d.mode = move
            let battery = (value(st, "battery", "battery") as? NSNumber)?.intValue
            let words = ["cleaning": "Cleaning", "homing": "Going Home", "charging": "Charging", "idle": "Docked", "pause": "Paused", "alarm": "Needs Help", "after": "Done"]
            d.status = (move.flatMap { words[$0] } ?? "Ready") + (battery.map { " · \($0)%" } ?? "")
            d.alert = move == "alarm"
        } else if c.contains("airConditionerMode") {
            d.kind = .aircon
            let mode = value(st, "airConditionerMode", "airConditionerMode") as? String
            d.mode = mode
            var bits: [String] = [d.isOn == true ? (mode?.capitalized ?? "On") : "Off"]
            if let t = celsius(st, "main") { d.temperature = t; bits.append(temperatureText(t)) }
            d.status = bits.joined(separator: " · ")
        } else if c.contains("airPurifierFanMode") {
            d.kind = .fan
            d.status = d.isOn == true ? ((value(st, "airPurifierFanMode", "airPurifierFanMode") as? String)?.capitalized ?? "On") : "Off"
        } else if c.contains("switch") {
            d.kind = .toggle
            d.status = d.isOn == true ? "On" : "Off"
        } else if let t = celsius(st, "main") {
            d.kind = .sensor
            d.temperature = t
            d.status = temperatureText(t)
        } else {
            d.status = d.reachable ? "Connected" : "Offline"
        }
        return d
    }

    /// "The washer is done" when a cycle ends while the app is open.
    private func notifyIfFinished(_ d: HomeDevice, name: String) {
        guard let now = d.machineState else { return }   // not known this time: nothing has finished
        let was = lastMachine[d.id]
        lastMachine[d.id] = now
        guard was == "run", now == "stop" else { return }
        let c = UNMutableNotificationContent()
        c.title = "\(name) is done"
        c.body = d.kind == .dryer ? "The dryer has finished." : d.kind == .washer ? "The wash has finished. Time to move it to the dryer." : "It has finished."
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "st-\(d.id)-\(Date().timeIntervalSince1970)", content: c, trigger: nil))
    }

    // MARK: Commands

    func send(_ d: HomeDevice, _ cmd: DeviceCommand) {
        let id = String(d.id.dropFirst(3))
        var command: [String: Any]
        switch cmd {
        case .power(let on): command = ["component": "main", "capability": "switch", "command": on ? "on" : "off"]
        case .machine(let m):
            let cap: String
            switch d.kind {
            case .dryer: cap = "dryerOperatingState"
            case .dishwasher: cap = "dishwasherOperatingState"
            case .oven: cap = "ovenOperatingState"
            default: cap = "washerOperatingState"
            }
            command = ["component": "main", "capability": cap, "command": "setMachineState", "arguments": [m]]
        default: return
        }
        Task {
            do {
                _ = try await call("POST", "/devices/\(id)/commands", ["commands": [command]])
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await reread(id)
            } catch { self.error = error.localizedDescription }
        }
    }
}

extension ISO8601DateFormatter {
    static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

/// The Samsung part of Settings → Devices.
struct SmartThingsSection: View {
    private let st = SmartThings.shared
    @State private var clientID = SmartThings.shared.clientID
    @State private var secret = ""
    @State private var token = ""
    @State private var showSetup = false

    var body: some View {
        Section {
            if st.connected {
                LabeledContent("Samsung SmartThings", value: "\(AccessoryStore.shared.fromSmartThings.count) devices")
                Button("Refresh") { Task { await st.refresh(full: true) } }
                Button("Disconnect", role: .destructive) { st.signOut() }
            } else {
                TextField("Client ID", text: $clientID).autocorrectionDisabled().font(.body.monospaced())
                SecureField("Client Secret", text: $secret)
                Button {
                    Task { await st.signIn(clientID: clientID, secret: secret) }
                } label: {
                    HStack { Text("Sign In with Samsung"); if st.busy { Spacer(); ProgressView() } }
                }
                .disabled(st.busy || clientID.isEmpty || secret.isEmpty)
                DisclosureGroup("How to Get These", isExpanded: $showSetup) {
                    Text("""
                    Once, on your Mac in Terminal:
                    1. brew install smartthingscommunity/smartthings/smartthings
                    2. smartthings apps:create
                    3. Choose “OAuth-In App”, any name, and the scopes r:devices:*, x:devices:* and r:locations:*.
                    4. For the redirect URI enter:
                    \(OAuthRelay.redirect)
                    5. Paste the Client ID and Client Secret it shows here, then Sign In with Samsung.
                    """)
                    .font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                }
                HStack {
                    SecureField("Or paste a personal access token", text: $token)
                    Button("Use") { Task { await st.useToken(token); token = "" } }.disabled(token.isEmpty)
                }
            }
            if let e = st.error { Text(e).foregroundStyle(Palette.attention) }
        } header: { Text("Samsung SmartThings") } footer: {
            Text("Washer, dryer, fridge, oven and dishwasher: cycle status and time left, a notification when a cycle finishes, and start, pause or stop when Remote Control is on. A token from account.smartthings.com/tokens works too, but Samsung makes those last only 24 hours.")
        }
    }
}
