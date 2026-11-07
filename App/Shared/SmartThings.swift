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
                if self.connected { await self.refresh(full: self.listedAt.map { $0.timeIntervalSinceNow < -300 } ?? true) }
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
    }

    // MARK: Sign-in

    var clientID: String { Keychain.get("st.client") ?? "" }

    /// Signed in with Samsung (renews by itself for good). A pasted token, which Samsung makes last only 24 hours,
    /// is then never used, even if an old one comes back from another device.
    var usesAccount: Bool {
        Keychain.get("st.refresh") != nil && Keychain.get("st.client") != nil && Keychain.get("st.secret") != nil
    }

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
        await refresh(full: true)
    }

    func signOut() {
        for k in ["st.access", "st.refresh", "st.expires", "st.token"] { Keychain.set(nil, for: k) }
        devices = []
        raw = [:]
        capabilities = [:]
        lastMachine = [:]
        commandError = [:]
        listedAt = nil
        error = nil
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
    /// A renewal key SmartThings turned down: it isn't sent again (asking with a dead key over and over helps no one).
    /// A newer one, from another of the family's devices or a new sign-in, is tried as soon as it's here.
    @ObservationIgnored private var rejectedRefresh: String?
    static let waitingForMac = "SmartThings is waiting for a Mac at home to renew its sign-in."
    static let signInAgain = "SmartThings signed this device out. It comes back when your devices at home pass on their sign-in, or sign in again in Settings."

    /// The sign-in to use. A renewal runs one at a time (the renewal key works once, so two at once would
    /// sign the loser out); everyone else waits for it.
    private func token(force: Bool = false) async throws -> String {
        if !usesAccount, let pat = Keychain.get("st.token") { return pat }
        // An old pasted token alongside the Samsung sign-in: drop it everywhere (the removal syncs).
        if Keychain.get("st.token") != nil { Keychain.set(nil, for: "st.token") }
        if !force, let a = Keychain.get("st.access"), let e = Keychain.get("st.expires").flatMap(Double.init), e > Date().timeIntervalSince1970 { return a }
        #if os(iOS)
        // The Macs (always at home) renew the family's sign-in and pass it on; an iPhone renewing too would leave
        // them holding a key SmartThings no longer takes. So for an hour after it runs out, the iPhone waits for
        // theirs, and renews by itself only after that (no Mac about).
        if let e = Keychain.get("st.expires").flatMap(Double.init), Date().timeIntervalSince1970 >= e,
           Date().timeIntervalSince1970 < e + 3600 {
            let before = Keychain.get("st.access")
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            if let a = Keychain.get("st.access"), a != before, let e2 = Keychain.get("st.expires").flatMap(Double.init),
               e2 > Date().timeIntervalSince1970 { return a }
            throw OAuthRelay.Failure.refused(Self.waitingForMac)
        }
        #endif
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
        if r == rejectedRefresh { throw OAuthRelay.Failure.refused(Self.signInAgain) }
        do {
            let t = try await formPost(Self.tokenURL, ["grant_type": "refresh_token", "refresh_token": r, "client_id": id], basic: (id, sec))
            store(t)
        } catch {
            // Another of the family's devices renewed first (the renewal key works once) and its new key has
            // arrived by sync in the meantime: use that one rather than giving up.
            var newer = Keychain.get("st.refresh")
            if newer == r {
                // Its new key may still be on its way here: wait a moment for it.
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                newer = Keychain.get("st.refresh")
            }
            guard let newer, newer != r else {
                // Turned down (not a network hiccup): keep it from being sent again, and say so plainly.
                if case OAuthRelay.Failure.refused(let m) = error, m.localizedCaseInsensitiveContains("invalid") {
                    rejectedRefresh = r
                    throw OAuthRelay.Failure.refused(Self.signInAgain)
                }
                throw error
            }
            if let a = Keychain.get("st.access"), let e = Keychain.get("st.expires").flatMap(Double.init), e > Date().timeIntervalSince1970 {
                return a
            }
            let t = try await formPost(Self.tokenURL, ["grant_type": "refresh_token", "refresh_token": newer, "client_id": id], basic: (id, sec))
            store(t)
        }
        return Keychain.get("st.access") ?? ""
    }

    /// SmartThings said no: the HTTP code and its words (with any details it gave).
    struct APIError: LocalizedError {
        var code: Int
        var message: String
        var errorDescription: String? { message }
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
        // Sent, and its answer read, off the main actor (a round reads every appliance, several at once).
        let answer = try await Self.fetch(r)
        let code = answer.code, json = answer.json
        guard (200..<300).contains(code) else {
            // Signed in with an account (not a pasted token) and the sign-in ran out early: renew once and retry.
            if code == 401, !retried, usesAccount {
                return try await call(method, path, body, retried: true)
            }
            if code == 401 {
                throw OAuthRelay.Failure.refused(usesAccount
                    ? "Samsung signed this out. Sign In with Samsung again."
                    : "The pasted token ran out (Samsung makes them last 24 hours). Sign In with Samsung instead: it stays signed in.")
            }
            throw APIError(code: code, message: Self.errorWords(json) ?? "SmartThings answered \(code).")
        }
        return json
    }

    /// What SmartThings answered: its HTTP code and its JSON (read off the main actor, then only handed over).
    private struct Answer: @unchecked Sendable {
        var code: Int
        var json: [String: Any]
    }

    /// Sends [request] and reads the JSON that comes back, off the main actor.
    nonisolated private static func fetch(_ request: URLRequest) async throws -> Answer {
        let (d, resp) = try await URLSession.shared.data(for: request)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
        return Answer(code: code, json: json)
    }

    /// `{"error": {"message": "…", "details": [{"message": "…"}]}}` → "…: …".
    nonisolated private static func errorWords(_ json: [String: Any]) -> String? {
        guard let err = json["error"] as? [String: Any] else { return nil }
        var parts: [String] = []
        if let m = err["message"] as? String, !m.isEmpty { parts.append(m) }
        for detail in err["details"] as? [[String: Any]] ?? [] {
            if let m = detail["message"] as? String, !m.isEmpty, !parts.contains(m) { parts.append(m) }
        }
        return parts.isEmpty ? nil : parts.joined(separator: ": ")
    }

    // MARK: Devices

    @ObservationIgnored private var refreshing: Task<Void, Never>?
    @ObservationIgnored private var refreshingFull = false
    @ObservationIgnored private var refreshGen = 0
    /// After a command, the appliance's own re-read owns its tile for a few seconds (a poll that read it a moment
    /// before the command landed would otherwise put the old state back).
    @ObservationIgnored private var holdUntil: [String: Date] = [:]
    /// When each appliance's tile was last updated outside the poll (a re-read or a tap).
    @ObservationIgnored private var changedAt: [String: Date] = [:]
    /// Cycles the family stopped from here (so stopping one isn't announced as "done").
    @ObservationIgnored private var userStopped: [String: Date] = [:]

    /// Reads everything again. Only one runs at a time; anyone else waits for it (and a full one asked for
    /// while a quick one runs goes after it).
    func refresh(full: Bool) async {
        guard connected else { return }
        if let running = refreshing {
            let wasFull = refreshingFull
            await running.value
            if !full || wasFull { return }
        }
        refreshGen += 1
        let gen = refreshGen
        refreshingFull = full
        let t = Task { await self.load(full: full) }
        refreshing = t
        await t.value
        if refreshGen == gen { refreshing = nil }
    }

    private func load(full: Bool) async {
        var listFailure: String?
        if full || devices.isEmpty {
            do {
                let list = try await call("GET", "/devices")
                devices = list["items"] as? [[String: Any]] ?? []
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
            } catch {
                // Keep the list it had; with none there's nothing to read.
                listFailure = error.localizedDescription
                if devices.isEmpty {
                    self.error = listFailure
                    // Nothing read yet since the app opened: the appliances kept from last time don't show as they
                    // were then (a washer still "Running"), but as not responding until SmartThings answers.
                    let kept = AccessoryStore.shared.fromSmartThings
                    let dimmed = kept.map { $0.reachable ? Self.offline($0) : $0 }
                    if dimmed != kept { AccessoryStore.shared.fromSmartThings = dimmed }
                    return
                }
            }
        }
        let known = devices
        var out: [HomeDevice] = []
        var readAt: [String: Date] = [:]
        var failures = 0
        var lastFailure: String?
        let before = AccessoryStore.shared.fromSmartThings
        // Every appliance read together (four at a time), then taken in the list's order, as when they were read one
        // by one.
        let answers = await readings(known.compactMap { $0["deviceId"] as? String })
        // Signed out while they were read: nothing comes back.
        guard connected else { return }
        for dev in known {
            guard let id = dev["deviceId"] as? String, let r = answers[id] else { continue }
            let key = "st:" + id
            let caps = allCaps(dev)
            if capabilities[key] != caps { capabilities[key] = caps }
            readAt[key] = r.at
            let online = r.online
            guard let status = r.status else {
                // Couldn't read it this time: keep what it last said (never a false "done" or "Idle"),
                // unless SmartThings says it has gone offline, or it hasn't said anything since the app opened (what's
                // kept is from last time).
                failures += 1
                lastFailure = r.failure
                if let old = before.first(where: { $0.id == key }) {
                    out.append(online == false || raw[key] == nil ? Self.offline(old) : old)
                }
                continue
            }
            if let until = holdUntil[key], until > .now, let current = before.first(where: { $0.id == key }) {
                out.append(current)   // a command's re-read owns it right now
                continue
            }
            // Kept only when it says something new: open pages read it, and most rounds change nothing.
            let same = raw[key].map { NSDictionary(dictionary: $0).isEqual(to: status) } ?? false
            if !same { raw[key] = status }
            if let d = make(dev, status, online: online) {
                notifyIfFinished(d)
                out.append(d)
            }
        }
        // Anything a command's re-read updated while this went round keeps the newer word.
        let latest = AccessoryStore.shared.fromSmartThings
        out = out.map { d in
            let held = (holdUntil[d.id].map { $0 > .now } ?? false)
            let newer = (changedAt[d.id] ?? .distantPast) > (readAt[d.id] ?? .distantFuture)
            guard held || newer, let current = latest.first(where: { $0.id == d.id }) else { return d }
            return current
        }
        let problem = listFailure ?? (failures > 0 && failures == known.count ? lastFailure : nil)
        if error != problem { error = problem }
        // Only a real change reaches Home (most rounds change nothing).
        if AccessoryStore.shared.fromSmartThings != out { AccessoryStore.shared.fromSmartThings = out }
    }

    /// One appliance's health and status, read together.
    private struct Reading: @unchecked Sendable {
        /// When the reads began (a command's re-read after this keeps its newer word).
        var at: Date
        var online: Bool?
        var status: [String: Any]?
        /// Why the status couldn't be read.
        var failure: String?
    }

    /// Reads one appliance's health and status at the same time.
    private func reading(_ id: String) async -> Reading {
        let at = Date()
        async let reachable = health(id)
        do {
            let status = try await call("GET", "/devices/\(id)/status")
            return Reading(at: at, online: await reachable, status: status, failure: nil)
        } catch {
            return Reading(at: at, online: await reachable, status: nil, failure: error.localizedDescription)
        }
    }

    /// Every appliance's health and status, four appliances at a time (one after another, a house full of them
    /// took several seconds a round), by device id.
    private func readings(_ ids: [String]) async -> [String: Reading] {
        await withTaskGroup(of: (String, Reading).self, returning: [String: Reading].self) { group in
            var out: [String: Reading] = [:]
            var waiting = ids[...]
            for _ in 0..<4 {
                guard let id = waiting.popFirst() else { break }
                group.addTask {
                    let got = await self.reading(id)
                    return (id, got)
                }
            }
            while let (id, r) = await group.next() {
                out[id] = r
                if let next = waiting.popFirst() {
                    group.addTask {
                        let got = await self.reading(next)
                        return (next, got)
                    }
                }
            }
            return out
        }
    }

    /// Whether SmartThings can reach the appliance right now (nil when it can't say).
    private func health(_ id: String) async -> Bool? {
        guard let h = try? await call("GET", "/devices/\(id)/health"), let s = h["state"] as? String else { return nil }
        switch s.uppercased() {
        case "ONLINE": return true
        case "OFFLINE": return false
        default: return nil
        }
    }

    /// An appliance that has dropped off: nothing it last said about a cycle still holds.
    private static func offline(_ d: HomeDevice) -> HomeDevice {
        var d = d
        d.reachable = false
        d.machineState = nil
        d.endsAt = nil
        d.alert = false
        d.status = "Offline"
        return d
    }

    /// What a command should lead to, so its re-read can wait for the appliance to catch up.
    enum Expect {
        case nothing
        case power(Bool)
        case machine(String)
        case attribute(cap: String, attr: String, component: String, value: String)
    }

    /// Reads one device again (its page or the thermostat controls are open). Takes the app's id ("st:…").
    func refresh(device key: String) async {
        await reread(key.hasPrefix("st:") ? String(key.dropFirst(3)) : key)
    }

    /// Reads one appliance again (after a command), so its tile updates in a second. With an expectation it
    /// only takes the answer once the appliance agrees (or on the last try); says whether it agreed.
    @discardableResult
    func reread(_ id: String, expect: Expect = .nothing, last: Bool = true) async -> Bool {
        let key = "st:" + id
        guard let dev = devices.first(where: { ($0["deviceId"] as? String) == id }) else { return false }
        // Its health asked alongside its status (the tile waited for one, then the other).
        async let reachable = health(id)
        guard let status = try? await call("GET", "/devices/\(id)/status") else { return false }
        let online = await reachable
        guard let d = make(dev, status, online: online) else { return false }
        let agrees = matches(expect, d, status)
        guard agrees || last else { return false }
        raw[key] = status
        changedAt[key] = Date()
        notifyIfFinished(d)
        var list = AccessoryStore.shared.fromSmartThings
        if let i = list.firstIndex(where: { $0.id == key }) { list[i] = d } else { list.append(d) }
        if AccessoryStore.shared.fromSmartThings != list { AccessoryStore.shared.fromSmartThings = list }
        return agrees
    }

    private func matches(_ expect: Expect, _ d: HomeDevice, _ status: [String: Any]) -> Bool {
        if !d.reachable { return true }
        switch expect {
        case .nothing: return true
        case .power(let on): return d.isOn == on
        case .machine(let m): return d.machineState == m
        case .attribute(let cap, let attr, let component, let v):
            return value(status, cap, attr, in: component).map { "\($0)" } == v
        }
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

    /// Writes a value into the appliance's last status straight away (a tapped setting shows at once).
    private func patch(_ deviceID: String, _ component: String, _ cap: String, _ attr: String, _ newValue: Any) {
        guard var st = raw[deviceID] else { return }
        var comps = st["components"] as? [String: Any] ?? [:]
        var comp = comps[component] as? [String: Any] ?? [:]
        var capability = comp[cap] as? [String: Any] ?? [:]
        var attribute = capability[attr] as? [String: Any] ?? [:]
        attribute["value"] = newValue
        capability[attr] = attribute
        comp[cap] = capability
        comps[component] = comp
        st["components"] = comps
        raw[deviceID] = st
    }

    /// Changes the tile straight away, before the appliance answers.
    private func updateLocal(_ key: String, _ change: (inout HomeDevice) -> Void) {
        var list = AccessoryStore.shared.fromSmartThings
        guard let i = list.firstIndex(where: { $0.id == key }) else { return }
        change(&list[i])
        changedAt[key] = Date()
        if AccessoryStore.shared.fromSmartThings != list { AccessoryStore.shared.fromSmartThings = list }
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

    /// Time left from a `remainingTime` attribute ({"value": 42, "unit": "min"}).
    private func remaining(_ status: [String: Any], _ cap: String) -> TimeInterval? {
        guard let t = (((status["components"] as? [String: Any])?["main"] as? [String: Any])?[cap] as? [String: Any])?["remainingTime"] as? [String: Any],
              let v = (t["value"] as? NSNumber)?.doubleValue, v > 0 else { return nil }
        let unit = (t["unit"] as? String)?.lowercased() ?? "min"
        if unit.hasPrefix("s") { return v }
        if unit.hasPrefix("h") { return v * 3600 }
        return v * 60
    }

    /// A Samsung machine, in both of the ways SmartThings describes one: the original capability
    /// (machineState run / pause / stop, completionTime) and Samsung's own newer one
    /// (operatingState running / paused / ready, remainingTime).
    struct Machine {
        var legacy: String
        var modern: String
        var kind: HomeDevice.Kind
        var word: String
        var job: String
    }

    static let machines: [Machine] = [
        Machine(legacy: "washerOperatingState", modern: "samsungce.washerOperatingState", kind: .washer, word: "Washing", job: "washerJobState"),
        Machine(legacy: "dryerOperatingState", modern: "samsungce.dryerOperatingState", kind: .dryer, word: "Drying", job: "dryerJobState"),
        Machine(legacy: "dishwasherOperatingState", modern: "samsungce.dishwasherOperation", kind: .dishwasher, word: "Washing", job: "dishwasherJobState"),
        Machine(legacy: "ovenOperatingState", modern: "samsungce.ovenOperatingState", kind: .oven, word: "Cooking", job: "ovenJobState"),
    ]

    /// run / running → "run", pause / paused → "pause", stop / ready / anything else → "stop".
    nonisolated static func normalize(_ s: String) -> String {
        switch s.lowercased() {
        case "run", "running": return "run"
        case "pause", "paused": return "pause"
        default: return "stop"
        }
    }

    private static func date(_ iso: String) -> Date? {
        ISO8601DateFormatter.withFraction.date(from: iso) ?? ISO8601DateFormatter.plain.date(from: iso)
    }

    /// "weightSensing" → "Sensing Load", "rinse" → "Rinsing", "someNewState" → "Some New State".
    nonisolated private static func jobWords(_ job: String) -> String {
        let words = [
            "wash": "Washing", "rinse": "Rinsing", "spin": "Spinning", "drying": "Drying", "cooling": "Cooling",
            "weightSensing": "Sensing Load", "delayWash": "Delay Start", "preWash": "Pre-Wash", "airWash": "Air Wash",
            "wrinklePrevent": "Wrinkle Prevent", "preheat": "Preheating", "cooking": "Cooking", "refreshing": "Refreshing",
            "sanitizing": "Sanitizing", "freezeProtection": "Freeze Protection",
        ]
        if let w = words[job] { return w }
        var out = ""
        for ch in job.replacingOccurrences(of: "_", with: " ") {
            if ch.isUppercase, let last = out.last, last.isLowercase { out.append(" ") }
            out.append(ch)
        }
        return out.prefix(1).uppercased() + out.dropFirst()
    }

    private static func timeLeft(_ end: Date) -> String {
        let mins = max(1, Int(ceil(end.timeIntervalSinceNow / 60)))
        return mins >= 60 ? "\(mins / 60) h \(mins % 60) min left" : "\(mins) min left"
    }

    private func make(_ dev: [String: Any], _ st: [String: Any], online: Bool?) -> HomeDevice? {
        guard let id = dev["deviceId"] as? String else { return nil }
        let c = caps(dev)
        let name = (dev["label"] as? String) ?? (dev["name"] as? String) ?? "Samsung"
        let ocfType = (dev["ocf"] as? [String: Any])?["ocfDeviceType"] as? String ?? ""
        var d = HomeDevice(id: "st:" + id, name: name, source: "smartthings", kind: .appliance, zone: (dev["roomId"] as? String).flatMap { roomNames[$0] }, status: "")
        d.reachable = online ?? ((value(st, "healthCheck", "DeviceWatch-DeviceStatus") as? String).map { $0 != "offline" } ?? true)
        // Without the capability there's nothing to switch on at the appliance: let it try (SmartThings will say if not).
        if let rc = value(st, "remoteControlStatus", "remoteControlEnabled") {
            d.remoteControl = "\(rc)" == "true" || (rc as? Bool) == true
        } else {
            d.remoteControl = !c.contains("remoteControlStatus")
        }
        if let sw = value(st, "switch", "switch") as? String { d.isOn = sw == "on" }

        if let m = Self.machines.first(where: { c.contains($0.legacy) || c.contains($0.modern) }) {
            d.kind = m.kind
            let reported = (value(st, m.legacy, "machineState") ?? value(st, m.modern, "operatingState") ?? value(st, m.modern, "machineState")) as? String
            let state = reported.map { Self.normalize($0) }
            d.machineState = state
            let job = (value(st, m.legacy, m.job) ?? value(st, m.modern, m.job)) as? String
            if let iso = (value(st, m.legacy, "completionTime") ?? value(st, m.modern, "completionTime")) as? String { d.endsAt = Self.date(iso) }
            if state == "run", (d.endsAt.map { $0 <= .now } ?? true), let left = remaining(st, m.modern) ?? remaining(st, m.legacy) {
                d.endsAt = Date().addingTimeInterval(left)
            }
            let finished = job.map { ["finish", "finished"].contains($0) } ?? false
            switch state {
            case "run":
                var s = m.word
                if let job, !["none", "finish", "finished"].contains(job) { s = Self.jobWords(job) }
                if let end = d.endsAt, end > .now { s += " · " + Self.timeLeft(end) }
                d.status = s
            case "pause": d.status = "Paused"
            default: d.status = finished ? "Finished" : (d.isOn == false ? "Off" : "Idle")
            }
        } else if c.contains("refrigeration") || c.contains("custom.fridgeMode") || ocfType.contains("refrigerator") {
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
            let words = ["cleaning": "Cleaning", "homing": "Going Home", "charging": "Charging", "idle": "Docked", "pause": "Paused", "alarm": "Needs Help", "after": "Done", "powerOff": "Off"]
            d.status = (move.flatMap { words[$0] } ?? "Ready") + (battery.map { " · \($0)%" } ?? "")
            d.alert = move == "alarm"
        } else if c.contains("airConditionerMode") {
            // Before thermostats: a Samsung air conditioner also has a cooling setpoint, but it isn't the ecobee.
            d.kind = .aircon
            let mode = value(st, "airConditionerMode", "airConditionerMode") as? String
            d.mode = mode
            var bits: [String] = [d.isOn == true ? (mode.map { Self.jobWords($0) } ?? "On") : "Off"]
            if let t = celsius(st, "main") { d.temperature = t; bits.append(temperatureText(t)) }
            d.status = bits.joined(separator: " · ")
        } else if c.contains("thermostatMode") || c.contains("thermostatHeatingSetpoint") || c.contains("thermostatCoolingSetpoint")
                    || c.contains("thermostat") || ocfType.contains("thermostat") {
            // A thermostat (an ecobee added to SmartThings).
            d.kind = .thermostat
            // Each value from its own capability, else from the older all-in-one "thermostat" capability.
            d.temperature = celsius(st, "main") ?? celsius(st, "main", "thermostat", "temperature")
            d.heatTo = celsius(st, "main", "thermostatHeatingSetpoint", "heatingSetpoint") ?? celsius(st, "main", "thermostat", "heatingSetpoint")
            d.coolTo = celsius(st, "main", "thermostatCoolingSetpoint", "coolingSetpoint") ?? celsius(st, "main", "thermostat", "coolingSetpoint")
            let reported = (value(st, "thermostatMode", "thermostatMode") ?? value(st, "thermostat", "thermostatMode")) as? String
            // "emergency heat", "auxheatonly" → heat (what the controls offer).
            let mode = reported.map { m -> String in
                let l = m.lowercased()
                return l.contains("heat") ? "heat" : l.hasPrefix("auto") ? "auto" : l
            }
            d.thermostatMode = mode
            let supported = (value(st, "thermostatMode", "supportedThermostatModes") ?? value(st, "thermostat", "supportedThermostatModes")) as? [String]
            d.modes = (supported ?? []).map { $0.lowercased() }
            d.target = mode == "cool" ? d.coolTo : d.heatTo
            let operating = (value(st, "thermostatOperatingState", "thermostatOperatingState") ?? value(st, "thermostat", "thermostatOperatingState")) as? String
            d.action = operating?.lowercased()
            d.humidity = (value(st, "relativeHumidityMeasurement", "humidity") as? NSNumber)?.intValue
            d.status = thermostatStatus(d)
        } else if c.contains("airPurifierFanMode") {
            d.kind = .fan
            d.status = d.isOn == true ? ((value(st, "airPurifierFanMode", "airPurifierFanMode") as? String).map { Self.jobWords($0) } ?? "On") : "Off"
        } else if c.contains("switch") {
            d.kind = c.contains("powerMeter") || ocfType.contains("smartplug") ? .outlet : .toggle
            var s = d.isOn == true ? "On" : "Off"
            if d.isOn == true, let w = (value(st, "powerMeter", "power") as? NSNumber)?.doubleValue, w >= 1 { s += " · \(Int(w.rounded())) W" }
            d.status = s
        } else if ["contactSensor", "waterSensor", "motionSensor", "occupancySensor", "temperatureMeasurement", "relativeHumidityMeasurement", "smokeDetector"].contains(where: { c.contains($0) }) {
            d.kind = .sensor
            var bits: [String] = []
            if (value(st, "waterSensor", "water") as? String) == "wet" { bits.append("Leak"); d.alert = true }
            if (value(st, "smokeDetector", "smoke") as? String) == "detected" { bits.append("Smoke"); d.alert = true }
            if let contact = value(st, "contactSensor", "contact") as? String { bits.append(contact == "open" ? "Open" : "Closed") }
            // Said either way, as Apple Home does, so a motion sensor shows as one whether or not it sees anyone.
            if c.contains("motionSensor") { bits.append((value(st, "motionSensor", "motion") as? String) == "active" ? "Motion" : "No Motion") }
            if c.contains("occupancySensor") { bits.append((value(st, "occupancySensor", "occupancy") as? String) == "occupied" ? "Occupied" : "Empty") }
            if let t = celsius(st, "main") { d.temperature = t; bits.append(temperatureText(t)) }
            if let h = (value(st, "relativeHumidityMeasurement", "humidity") as? NSNumber)?.intValue { bits.append("\(h)%") }
            d.status = bits.isEmpty ? "Connected" : bits.joined(separator: " · ")
        } else {
            d.status = "Connected"
        }
        // Offline: what it last said (a cycle "running") no longer holds.
        return d.reachable ? d : Self.offline(d)
    }

    /// "The washer is done" when a cycle ends while the app is open.
    private func notifyIfFinished(_ d: HomeDevice) {
        #if os(iOS)
        ApplianceActivitySync.shared.update(d)
        #endif
        guard let now = d.machineState else { return }   // not known this time (or offline): nothing has finished
        let was = lastMachine[d.id]
        lastMachine[d.id] = now
        guard was == "run", now == "stop" else { return }
        // Stopped from here: not "done".
        if let s = userStopped[d.id], s.timeIntervalSinceNow > -600 { userStopped[d.id] = nil; return }
        let c = UNMutableNotificationContent()
        c.title = "\(d.name) is done"
        c.body = d.kind == .dryer ? "The dryer has finished." : d.kind == .washer ? "The wash has finished. Time to move it to the dryer." : "It has finished."
        c.sound = .default
        Notifier.deliver(c, id: "st-\(d.id)-done")
    }

    // MARK: Commands

    /// Why the last command to each appliance failed, for its page (cleared by the next one).
    private(set) var commandError: [String: String] = [:]
    /// Appliances with a command on its way.
    private(set) var pending: Set<String> = []

    /// Sends one command, then reads the appliance again. With `sets`/`to`, the new value shows at once and
    /// the re-read waits for the appliance to agree.
    func command(_ d: HomeDevice, _ cap: String, _ command: String, _ args: [Any] = [], component: String = "main", sets attr: String? = nil, to newValue: Any? = nil) {
        var c: [String: Any] = ["component": component, "capability": cap, "command": command]
        if !args.isEmpty { c["arguments"] = args }
        var expect = Expect.nothing
        if let attr, let newValue, d.reachable {
            patch(d.id, component, cap, attr, newValue)
            expect = .attribute(cap: cap, attr: attr, component: component, value: "\(newValue)")
        }
        perform(d, c, expect: expect)
    }

    /// Sets a thermostat's heat or cool temperature, in the units the thermostat uses (whole degrees in °F).
    private func setpoint(_ d: HomeDevice, heating: Bool, _ celsiusValue: Double) {
        let own = heating ? "thermostatHeatingSetpoint" : "thermostatCoolingSetpoint"
        // A thermostat with only the older all-in-one capability takes the same command through that.
        let cap = !has(d.id, own) && has(d.id, "thermostat") ? "thermostat" : own
        let attr = heating ? "heatingSetpoint" : "coolingSetpoint"
        let fahrenheit = unit(d.id, cap, attr) != "C"   // the family uses °F; only a thermostat that says °C gets °C
        let v: Any = fahrenheit ? Int((celsiusValue * 9 / 5 + 32).rounded()) : (celsiusValue * 2).rounded() / 2
        // Shown at once (the re-read after the command then confirms what the thermostat took).
        if d.reachable {
            updateLocal(d.id) { x in
                if heating { x.heatTo = celsiusValue } else { x.coolTo = celsiusValue }
                if x.thermostatMode != "auto" { x.target = celsiusValue }
                x.status = thermostatStatus(x)
            }
        }
        command(d, cap, heating ? "setHeatingSetpoint" : "setCoolingSetpoint", [v], sets: attr, to: v)
    }

    /// Switches the appliance (or one part of it) on or off.
    func power(_ d: HomeDevice, _ on: Bool, component: String = "main") {
        guard component == "main" else {
            command(d, "switch", on ? "on" : "off", component: component, sets: "switch", to: on ? "on" : "off")
            return
        }
        if d.reachable {
            patch(d.id, "main", "switch", "switch", on ? "on" : "off")
            updateLocal(d.id) { x in
                x.isOn = on
                if !on { x.status = "Off" } else if x.status == "Off" { x.status = x.machineState == nil ? "On" : "Idle" }
            }
        }
        perform(d, ["component": "main", "capability": "switch", "command": on ? "on" : "off"], expect: .power(on))
    }

    /// Starts ("run"), pauses ("pause") or stops ("stop") a washer, dryer, dishwasher or oven, with whichever
    /// capability it has.
    func machine(_ d: HomeDevice, _ action: String) {
        guard let m = Self.machines.first(where: { $0.kind == d.kind }) else { return }
        let hasLegacy = has(d.id, m.legacy)
        var c: [String: Any] = ["component": "main"]
        if d.kind == .oven {
            // Ovens take start / stop (no pause), on either capability.
            c["capability"] = hasLegacy ? m.legacy : m.modern
            c["command"] = action == "stop" ? "stop" : "start"
        } else if hasLegacy {
            c["capability"] = m.legacy
            c["command"] = "setMachineState"
            c["arguments"] = [action]
        } else {
            c["capability"] = m.modern
            switch action {
            case "pause": c["command"] = "pause"
            case "stop": c["command"] = "cancel"
            default: c["command"] = d.kind == .dishwasher && d.machineState == "pause" ? "resume" : "start"
            }
        }
        let canAct = d.reachable && d.remoteControl
        if canAct {
            updateLocal(d.id) { x in
                x.status = action == "run" ? "Starting…" : action == "pause" ? "Pausing…" : "Stopping…"
            }
        }
        perform(d, c, expect: .machine(action), stops: action == "stop")
    }

    func send(_ d: HomeDevice, _ cmd: DeviceCommand) {
        switch cmd {
        case .power(let on): power(d, on)
        case .machine(let m): machine(d, m)
        case .thermostatMode(let m):
            let cap = !has(d.id, "thermostatMode") && has(d.id, "thermostat") ? "thermostat" : "thermostatMode"
            if d.reachable {
                updateLocal(d.id) { x in
                    x.thermostatMode = m
                    x.target = m == "cool" ? x.coolTo : x.heatTo
                    x.status = thermostatStatus(x)
                }
            }
            command(d, cap, "setThermostatMode", [m], sets: "thermostatMode", to: m)
        case .heatTo(let t): setpoint(d, heating: true, t)
        case .coolTo(let t): setpoint(d, heating: false, t)
        case .target(let t): setpoint(d, heating: d.thermostatMode != "cool", t)
        case .lock, .position, .door, .speed, .swing:
            // Nothing from SmartThings offers these here; say so rather than doing nothing.
            commandError[d.id] = "\(d.name) can’t be changed that way from Woodruff yet. Use the SmartThings app."
        }
    }

    private func perform(_ d: HomeDevice, _ c: [String: Any], expect: Expect, stops: Bool = false) {
        let key = d.id
        let id = String(key.dropFirst(3))
        guard d.reachable else {
            commandError[key] = "\(d.name) is offline. Check it has power and is on Wi‑Fi, then try again."
            return
        }
        commandError[key] = nil
        pending.insert(key)
        holdUntil[key] = Date().addingTimeInterval(20)
        Task {
            do {
                let r = try await self.call("POST", "/devices/\(id)/commands", ["commands": [c]])
                if let failed = (r["results"] as? [[String: Any]])?.first(where: { ($0["status"] as? String) == "FAILED" }) {
                    throw APIError(code: 422, message: (failed["error"] as? [String: Any]).flatMap { Self.errorWords(["error": $0]) } ?? "The appliance refused it.")
                }
                if stops { self.userStopped[key] = Date() }
                // Samsung takes a few seconds to show a change (a cloud thermostat like the ecobee longer): look
                // again until it does, and only then, or at the last look, take what it says.
                let delays: [Double] = [1.5, 2.5, 4, 6]
                for (n, delay) in delays.enumerated() {
                    try? await Task.sleep(for: .seconds(delay))
                    if await self.reread(id, expect: expect, last: n == delays.count - 1) { break }
                }
            } catch {
                self.commandError[key] = self.describe(error, d, c)
                self.holdUntil[key] = nil
                await self.reread(id)   // put back what it really says
            }
            self.holdUntil[key] = nil
            self.pending.remove(key)
        }
    }

    /// A command's failure, in words that say what to do.
    private func describe(_ error: Error, _ d: HomeDevice, _ c: [String: Any]) -> String {
        guard let api = error as? APIError else { return error.localizedDescription }
        let cap = c["capability"] as? String ?? ""
        let machineKinds: [HomeDevice.Kind] = [.washer, .dryer, .dishwasher, .oven]
        let kindName: String
        switch d.kind {
        case .washer: kindName = "washer"
        case .dryer: kindName = "dryer"
        case .dishwasher: kindName = "dishwasher"
        case .oven: kindName = "oven"
        default: kindName = "appliance"
        }
        let lowered = api.message.lowercased()
        let remoteRefused = lowered.contains("remote") || (machineKinds.contains(d.kind) && cap != "switch" && !d.remoteControl)
        if [400, 409, 422].contains(api.code) && remoteRefused {
            return "\(d.name) didn't accept that because Remote Control is off. Press Remote Control (Smart Control) on the \(kindName), then try again."
        }
        switch api.code {
        case 400, 409, 422:
            return "\(d.name) didn't accept that: \(api.message)"
        case 403:
            return "SmartThings won't let this sign-in control \(d.name). Sign in again and allow control of devices (x:devices:*)."
        case 404:
            return "SmartThings can't find \(d.name) any more. Pull to refresh."
        case 429:
            return "SmartThings is busy. Try again in a minute."
        default:
            return "Couldn't change \(d.name): \(api.message)"
        }
    }
}

extension ISO8601DateFormatter {
    /// Plain (no fraction of a second), made once.
    static let plain = ISO8601DateFormatter()
    static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

/// The Samsung part of Settings → Smart Home → Devices.
struct SmartThingsSection: View {
    private let st = SmartThings.shared
    @State private var clientID = SmartThings.shared.clientID
    // Kept from the last sign-in (and synced), so signing in again is one tap.
    @State private var secret = Keychain.get("st.secret") ?? ""
    @State private var showSetup = false

    var body: some View {
        Section {
            if st.connected && st.usesAccount {
                LabeledContent("Devices", value: "\(AccessoryStore.shared.fromSmartThings.count)")
                Button("Refresh") { Task { await st.refresh(full: true) } }
                Button("Disconnect", role: .destructive) { st.signOut() }
            } else {
                if st.connected {
                    // On a 24-hour token: the Samsung sign-in below replaces it for good.
                    LabeledContent("Signed In With", value: "24-hour token")
                }
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
            }
            if let e = st.error { Text(e).foregroundStyle(Palette.attention) }
        } header: { Text("Samsung SmartThings") } footer: {
            Text("Washer, dryer, fridge, oven and dishwasher: cycle status and time left, a notification when a cycle finishes, and start, pause or stop when Remote Control is on.")
        }
    }
}
