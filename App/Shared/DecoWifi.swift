import SwiftUI
import UserNotifications
import WoodruffKit

/// The TP-Link Deco mesh Wi‑Fi: the units, everything connected to them, the internet, and restarting a unit.
/// TP-Link has no public API; this signs in to the main Deco on the home network the way its own app does
/// (as the open-source ha-tplink-deco integration does). Works on iPhone and Mac while at home.
@Observable @MainActor
final class DecoWifi {
    static let shared = DecoWifi()

    struct Node: Identifiable, Hashable {
        var id: String          // MAC
        var name: String
        var model: String?
        var ip: String?
        var online: Bool
        var main: Bool
        var internet: Bool?
        var clients: Int = 0
    }

    struct Client: Identifiable, Hashable {
        var id: String          // MAC
        var name: String
        var ip: String?
        var online: Bool
        var band: String        // Wired, 2.4 GHz, 5 GHz, 6 GHz
        var node: String?       // the Deco it's on
        var downKbps: Double
        var upKbps: Double
    }

    private(set) var nodes: [Node] = []
    private(set) var clients: [Client] = []
    private(set) var error: String?
    private(set) var busy = false
    private(set) var updated: Date?
    /// Decos asked to restart, and when: shown as "Restarting…" until each is seen offline and back.
    private(set) var restarts: [String: Date] = [:]
    @ObservationIgnored private var seenDown: Set<String> = []
    @ObservationIgnored private var restartWatch: Task<Void, Never>?

    func isRestarting(_ n: Node) -> Bool { restarts[n.id] != nil }

    var connected: Bool { Keychain.get("deco.password") != nil }
    var host: String { Keychain.get("deco.host") ?? Self.guessHost() ?? "192.168.68.1" }
    var internetUp: Bool? { nodes.first(where: \.main)?.internet }

    @ObservationIgnored private var stok: String?
    @ObservationIgnored private var cookie: String?
    @ObservationIgnored private var seq = 0
    @ObservationIgnored private var signKey: (String, String)?
    @ObservationIgnored private var aesKey = DecoCrypto.digits()
    @ObservationIgnored private var aesIV = DecoCrypto.digits()
    @ObservationIgnored private var scheme = "http"
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var wasUp: Bool?
    @ObservationIgnored private var refreshing: Task<Void, Never>?
    @ObservationIgnored private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpShouldSetCookies = false
        c.httpCookieAcceptPolicy = .never
        c.timeoutIntervalForRequest = 12
        return URLSession(configuration: c, delegate: LocalTrust.shared, delegateQueue: nil)
    }()

    /// The main Deco is the home network's router. A Deco's own network is 192.168.68.0–71.255 with the
    /// router at 192.168.68.1; otherwise it's x.y.z.1.
    static func guessHost() -> String? {
        guard let p = LANScan.prefixes().first else { return nil }
        let parts = p.split(separator: ".")
        if parts.count >= 3, parts[0] == "192", parts[1] == "168", let third = Int(parts[2]), (68...71).contains(third) { return "192.168.68.1" }
        return p + "1"
    }

    func start() {
        guard connected, loop == nil, !Demo.isOn else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
    }

    func signIn(host: String, password: String) async {
        var h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        for p in ["https://", "http://"] where h.lowercased().hasPrefix(p) { h = String(h.dropFirst(p.count)) }
        while h.hasSuffix("/") { h.removeLast() }
        guard !password.isEmpty else { error = "Enter the Deco password."; return }
        guard !h.contains(" "), URL(string: "http://\(h.isEmpty ? "192.168.68.1" : h)/")?.host != nil else { error = "That Deco address isn’t valid."; return }
        busy = true; error = nil
        defer { busy = false }
        Keychain.set(h.isEmpty ? nil : h, for: "deco.host")
        Keychain.set(password, for: "deco.password")
        stok = nil
        await refresh(evenAway: true)
        if nodes.isEmpty {
            if error == "The Deco password changed. Sign in again." { error = "The Deco didn’t accept that password." }
            Keychain.set(nil, for: "deco.password")
            if error == nil { error = "The Deco didn’t answer. Check you’re on the home Wi‑Fi." }
        } else {
            start()
        }
    }

    func signOut() {
        loop?.cancel(); loop = nil
        restartWatch?.cancel(); restartWatch = nil
        Keychain.set(nil, for: "deco.password")
        stok = nil; nodes = []; clients = []; restarts = [:]; seenDown = []
    }

    // MARK: Reading

    /// One at a time (a second sign-in mid-request would swap the keys under it); callers share the one running.
    /// Only at home: away, whatever router has the Deco's address is someone else's, and gets no password.
    func refresh(evenAway: Bool = false) async {
        guard connected, evenAway || Fleet.shared.atHome else { return }
        if let running = refreshing { await running.value; return }
        let t = Task { await self.refreshNow() }
        refreshing = t
        await t.value
        if refreshing == t { refreshing = nil }
    }

    private func refreshNow() async {
        guard connected else { return }
        do {
            var fresh = false
            if stok == nil { try await login(); fresh = true }
            var devs: [String: Any]
            do {
                devs = try await call("/admin/device", form: "device_list", ["operation": "read"])
            } catch let e where !fresh && !(e is WrongPassword) && !(e is URLError) {
                // The Deco forgot this session (it restarted, or timed it out): sign in again once.
                try await login()
                devs = try await call("/admin/device", form: "device_list", ["operation": "read"])
            }
            var ns: [Node] = []
            for d in (devs["result"] as? [String: Any])?["device_list"] as? [[String: Any]] ?? [] {
                guard let mac = d["mac"] as? String else { continue }
                let custom = (d["custom_nickname"] as? String).flatMap(Self.unbase64)
                let nick = (d["nickname"] as? String).map { $0.replacingOccurrences(of: "_", with: " ").capitalized }
                let inet = (d["inet_status"] as? String).map { $0 == "online" }
                ns.append(Node(id: mac, name: custom ?? nick ?? "Deco", model: d["device_model"] as? String, ip: d["device_ip"] as? String,
                               online: (d["group_status"] as? String) == "connected", main: (d["role"] as? String) == "master", internet: inet))
            }
            // Clients, Deco by Deco, so each knows which unit it's on.
            // (An offline Deco has none, and asking it only errors.)
            var cs: [String: Client] = [:]
            for i in ns.indices where ns[i].online {
                guard let r = try? await call("/admin/client", form: "client_list", ["operation": "read", "params": ["device_mac": ns[i].id]], keepSession: true) else { continue }
                let list = ((r["result"] as? [String: Any])?["client_list"] as? [[String: Any]] ?? [])
                    .filter { ($0["online"] as? Bool) ?? true }
                for c in list {
                    guard let mac = c["mac"] as? String else { continue }
                    let band: String
                    switch c["connection_type"] as? String {
                    case "wired": band = "Wired"
                    case "band2_4": band = "2.4 GHz"
                    case "band5": band = "5 GHz"
                    case "band6": band = "6 GHz"
                    default: band = "Wi‑Fi"
                    }
                    cs[mac] = Client(id: mac, name: (c["name"] as? String).flatMap(Self.unbase64) ?? mac, ip: c["ip"] as? String,
                                     online: (c["online"] as? Bool) ?? true, band: band, node: ns[i].id,
                                     downKbps: (c["down_speed"] as? NSNumber)?.doubleValue ?? 0, upKbps: (c["up_speed"] as? NSNumber)?.doubleValue ?? 0)
                }
                ns[i].clients = list.count
            }
            trackRestarts(&ns)
            // A Deco shown as restarting has nobody on it.
            for i in ns.indices where !ns[i].online { ns[i].clients = 0 }
            let down = Set(ns.filter { !$0.online }.map(\.id))
            cs = cs.filter { !down.contains($0.value.node ?? "") }
            nodes = ns.sorted { ($0.main ? 0 : 1, $0.name) < ($1.main ? 0 : 1, $1.name) }
            clients = cs.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            error = nil
            updated = Date()
            noticeInternet()
        } catch WrongPassword.refused {
            // The password changed on the Deco: stop trying the old one (which would lock the owner out).
            loop?.cancel(); loop = nil
            Keychain.set(nil, for: "deco.password")
            stok = nil; nodes = []; clients = []
            self.error = "The Deco password changed. Sign in again."
        } catch {
            stok = nil
            if let main = nodes.first(where: \.main), restarts[main.id] != nil {
                // The main Deco is restarting: it can't answer, and that's expected. Show every unit as down
                // (the mesh goes with it) until it's back.
                seenDown.insert(main.id)
                for i in nodes.indices { nodes[i].online = false; nodes[i].clients = 0 }
                clients = []
                self.error = nil
            } else if Fleet.shared.atHome {
                self.error = error.localizedDescription
            }
        }
    }

    /// A restarting Deco shows offline until it has been seen down and come back (or five minutes pass). The
    /// first 40 s it shows offline even if the main Deco hasn't noticed yet.
    private func trackRestarts(_ ns: inout [Node]) {
        for (mac, at) in restarts {
            let age = -at.timeIntervalSinceNow
            guard let i = ns.firstIndex(where: { $0.id == mac }) else { if age > 300 { restarts[mac] = nil; seenDown.remove(mac) }; continue }
            if !ns[i].online { seenDown.insert(mac) }
            // Back: seen down and up again, or up after two minutes (a quick restart can fall between looks).
            if (ns[i].online && (seenDown.contains(mac) ? age > 20 : age > 120)) || age > 300 {
                restarts[mac] = nil
                seenDown.remove(mac)
            } else if age < 40 || !seenDown.contains(mac) {
                ns[i].online = false
            }
        }
    }

    private enum WrongPassword: Error { case refused }

    /// "The internet is down" when the main Deco loses it (and "back" when it returns).
    private func noticeInternet() {
        // Restarting the main Deco takes the internet down on purpose: no alert, and start afresh after.
        if let m = nodes.first(where: \.main), restarts[m.id] != nil { wasUp = nil; return }
        guard let up = internetUp else { return }
        defer { wasUp = up }
        guard let was = wasUp, was != up else { return }
        let c = UNMutableNotificationContent()
        c.title = up ? "Internet Is Back" : "Internet Is Down"
        c.body = up ? "The Deco is online again." : "The Deco says the home internet connection dropped."
        c.sound = .default
        Notifier.deliver(c, id: "deco-inet")
    }

    // MARK: Restart

    func restart(_ node: Node) async {
        guard restarts[node.id] == nil else { return }
        // In the same line as the refreshes (a sign-in beside another would swap the keys under it).
        while let running = refreshing { await running.value; if refreshing == running { refreshing = nil } }
        let t = Task { await self.restartNow(node) }
        refreshing = t
        await t.value
        if refreshing == t { refreshing = nil }
    }

    private func restartNow(_ node: Node) async {
        let payload: [String: Any] = ["operation": "reboot", "params": ["mac_list": [["mac": node.id]]]]
        do {
            var fresh = false
            if stok == nil { try await login(); fresh = true }
            do {
                _ = try await call("/admin/device", form: "system", payload)
            } catch let e where !fresh && !(e is WrongPassword) && !(e is URLError) {
                try await login()
                _ = try await call("/admin/device", form: "system", payload)
            }
        } catch let e as URLError where node.main {
            // The main Deco often drops the connection as it goes down: that's the restart starting.
            _ = e
        } catch {
            self.error = error.localizedDescription
            return
        }
        error = nil
        restarts[node.id] = Date()
        seenDown = seenDown.subtracting([node.id])
        if let i = nodes.firstIndex(where: { $0.id == node.id }) { nodes[i].online = false; nodes[i].clients = 0 }
        if node.main { for i in nodes.indices { nodes[i].online = false } }
        // Look every 10 s while anything is restarting, so it shows coming back as soon as it does.
        if restartWatch == nil {
            restartWatch = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 10_000_000_000)
                    guard let self, !Task.isCancelled, !self.restarts.isEmpty else { break }
                    await self.refresh()
                }
                if !Task.isCancelled { self?.restartWatch = nil }
            }
        }
    }

    // MARK: Signing in

    private func login() async throws {
        guard let password = Keychain.get("deco.password") else { throw OAuthRelay.Failure.refused("Sign in to the Deco.") }
        aesKey = DecoCrypto.digits(); aesIV = DecoCrypto.digits()
        cookie = nil
        let keys = try await post("/cgi-bin/luci/;stok=/login", form: "keys", body: Data(#"{"operation":"read"}"#.utf8))
        guard let pw = (keys["result"] as? [String: Any])?["password"] as? [String], pw.count == 2 else {
            throw OAuthRelay.Failure.refused("This Deco uses a sign-in Woodruff doesn’t support yet.")
        }
        let auth = try await post("/cgi-bin/luci/;stok=/login", form: "auth", body: Data(#"{"operation":"read"}"#.utf8))
        guard let ar = auth["result"] as? [String: Any], let sk = ar["key"] as? [String], sk.count == 2 else {
            throw OAuthRelay.Failure.refused("The Deco didn’t give a sign-in key.")
        }
        signKey = (sk[0], sk[1])
        seq = (ar["seq"] as? NSNumber)?.intValue ?? 0
        guard let encPW = DecoCrypto.rsa(nHex: pw[0], eHex: pw[1], Data(password.utf8)) else { throw OAuthRelay.Failure.refused("Couldn’t encrypt the password.") }
        let r = try await post("/cgi-bin/luci/;stok=/login", form: "login", body: try encode(["params": ["password": encPW], "operation": "login"]))
        let data = try decrypt(r)
        let code = (data["error_code"] as? NSNumber)?.intValue ?? -1
        if code == -5002 { throw WrongPassword.refused }
        guard code == 0, let t = (data["result"] as? [String: Any])?["stok"] as? String else {
            throw OAuthRelay.Failure.refused("The Deco refused the sign-in (\(code)). If the Deco app is signed in as the owner on another device, try again in a minute.")
        }
        stok = t
    }

    /// An authenticated, encrypted request.
    /// keepSession: a refusal of this one request (a satellite that can't list its clients) isn't a lost sign-in.
    private func call(_ path: String, form: String, _ payload: [String: Any], keepSession: Bool = false) async throws -> [String: Any] {
        guard let stok else { throw OAuthRelay.Failure.refused("Not signed in.") }
        let r = try await post("/cgi-bin/luci/;stok=\(stok)\(path)", form: form, body: try encode(payload))
        let d = try decrypt(r)
        if let code = (d["error_code"] as? NSNumber)?.intValue, code != 0 {
            if !keepSession { self.stok = nil }
            throw OAuthRelay.Failure.refused("The Deco answered \(code).")
        }
        return d
    }

    private func encode(_ payload: [String: Any]) throws -> Data {
        let json = try JSONSerialization.data(withJSONObject: payload)
        guard let enc = DecoCrypto.aes(true, key: aesKey, iv: aesIV, json), let sk = signKey else {
            throw OAuthRelay.Failure.refused("Couldn’t encrypt the request.")
        }
        let (n, e) = sk
        let data = enc.base64EncodedString()
        let hash = DecoCrypto.md5Hex("admin" + (Keychain.get("deco.password") ?? ""))
        let signText = "k=\(aesKey)&i=\(aesIV)&h=\(hash)&s=\(seq + data.count)"
        guard let sign = DecoCrypto.rsa(nHex: n, eHex: e, Data(signText.utf8)) else { throw OAuthRelay.Failure.refused("Couldn’t sign the request.") }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.~")
        let quoted = data.addingPercentEncoding(withAllowedCharacters: allowed) ?? data
        return Data("sign=\(sign)&data=\(quoted)".utf8)
    }

    private func decrypt(_ r: [String: Any]) throws -> [String: Any] {
        if let d = r["data"] as? [String: Any] { return d }
        guard let s = r["data"] as? String, let raw = Data(base64Encoded: s), let plain = DecoCrypto.aes(false, key: aesKey, iv: aesIV, raw),
              let o = try? JSONSerialization.jsonObject(with: plain) as? [String: Any] else {
            stok = nil
            throw OAuthRelay.Failure.refused("The Deco’s answer couldn’t be read; signing in again.")
        }
        return o
    }

    private func post(_ path: String, form: String, body: Data) async throws -> [String: Any] {
        guard var c = URLComponents(string: "\(scheme)://\(host)\(path)") else { throw OAuthRelay.Failure.refused("That Deco address isn’t valid.") }
        c.queryItems = [URLQueryItem(name: "form", value: form)]
        guard let url = c.url else { throw OAuthRelay.Failure.refused("That Deco address isn’t valid.") }
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.httpBody = body
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let cookie { r.setValue(cookie, forHTTPHeaderField: "Cookie") }
        let (d, resp) = try await session.data(for: r)
        guard let http = resp as? HTTPURLResponse else { throw OAuthRelay.Failure.refused("No answer from the Deco.") }
        // Some Decos move everything to https; follow them there for good.
        if scheme == "http", http.url?.scheme == "https" { scheme = "https" }
        if let set = http.value(forHTTPHeaderField: "Set-Cookie"), let m = set.range(of: "sysauth=[a-f0-9]+", options: .regularExpression) {
            cookie = String(set[m])
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            stok = nil
            throw OAuthRelay.Failure.refused("The Deco refused the sign-in (\(http.statusCode)). If someone is signed in to the Deco app as the owner on a computer, try again shortly.")
        }
        guard http.statusCode == 200 else { throw OAuthRelay.Failure.refused("The Deco answered \(http.statusCode).") }
        return (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
    }

    static func unbase64(_ s: String) -> String {
        if let d = Data(base64Encoded: s), let t = String(data: d, encoding: .utf8), !t.isEmpty { return t }
        return s
    }
}

/// Trusts the Deco's own self-signed certificate on the home network (and only addresses on it).
final class LocalTrust: NSObject, URLSessionDelegate, @unchecked Sendable {
    static let shared = LocalTrust()
    /// 172.16.0.0–172.31.255.255 only (the rest of 172.* is the public internet).
    static func private172(_ host: String) -> Bool {
        let p = host.split(separator: ".")
        return p.count == 4 && p[0] == "172" && (Int(p[1]).map { (16...31).contains($0) } ?? false)
    }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let host = challenge.protectionSpace.host
        let local = host.hasPrefix("192.168.") || host.hasPrefix("10.") || Self.private172(host) || host.hasSuffix(".local") || host == "tplinkdeco.net"
        if local, challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust, let t = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: t))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

// MARK: - Home

/// Home's Wi‑Fi card: the internet, each Deco and how many are on it. Tap for everything.
struct WifiSection: View {
    private let deco = DecoWifi.shared
    @State private var open = false

    var body: some View {
        if deco.connected && !deco.nodes.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Wi‑Fi").font(.title3.bold())
                Button { open = true } label: {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Circle().fill(deco.internetUp == false ? Palette.attention : deco.internetUp == true ? Color.green : Color.secondary).frame(width: 9, height: 9)
                            Text(deco.internetUp == false ? "Internet Down" : deco.internetUp == true ? "Internet Online" : "Internet").font(.subheadline.weight(.semibold))
                            Spacer()
                            Text("\(deco.clients.count) devices").font(.subheadline).foregroundStyle(.secondary)
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 8)], spacing: 8) {
                            ForEach(deco.nodes) { n in
                                HStack(spacing: 8) {
                                    Image(systemName: "wifi.router.fill").foregroundStyle(n.online ? Color.primary : deco.isRestarting(n) ? Color.secondary : Palette.attention)
                                    VStack(alignment: .leading, spacing: 0) {
                                        Text(n.name).font(.footnote.weight(.semibold)).lineLimit(1)
                                        Text(deco.isRestarting(n) ? "Restarting…" : n.online ? "\(n.clients) connected" : "Offline").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(10)
                                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.06)))
                            }
                        }
                    }
                    .padding(14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .glass(RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
            .sheet(isPresented: $open) { NavigationStack { WifiView(inSheet: true) } }
        }
    }
}

// MARK: - The Wi‑Fi page (Settings → Wi‑Fi, and from Home)

struct WifiView: View {
    var inSheet = false
    @Environment(\.dismiss) private var dismiss
    private let deco = DecoWifi.shared
    @State private var host = Keychain.get("deco.host") ?? DecoWifi.guessHost() ?? "192.168.68.1"
    @State private var password = ""
    @State private var restarting: DecoWifi.Node?
    @State private var search = ""

    private var shownClients: [DecoWifi.Client] {
        search.isEmpty ? deco.clients : deco.clients.filter { $0.name.localizedCaseInsensitiveContains(search) || ($0.ip ?? "").contains(search) }
    }

    var body: some View {
        Form {
            if deco.connected {
                Section {
                    LabeledContent("Internet", value: deco.internetUp == false ? "Down" : deco.internetUp == true ? "Online" : "—")
                    if let u = deco.updated { LabeledContent("Updated") { Text(u, style: .relative) } }
                    if let e = deco.error { Text(e).foregroundStyle(Palette.attention) }
                }
                Section("Deco Units") {
                    ForEach(deco.nodes) { n in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(n.name + (n.main ? " (Main)" : ""))
                                Text([n.model, n.ip, deco.isRestarting(n) ? "Restarting…" : n.online ? "\(n.clients) connected" : "Offline"].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(n.online || deco.isRestarting(n) ? Color.secondary : Palette.attention)
                            }
                            Spacer()
                            if deco.isRestarting(n) {
                                ProgressView()
                            } else {
                                Button("Restart") { restarting = n }.buttonStyle(.glass).disabled(!n.online)
                            }
                        }
                    }
                }
                ForEach(deco.nodes) { n in
                    let list = shownClients.filter { $0.node == n.id }
                    if !list.isEmpty {
                        Section("On \(n.name) · \(list.count)") {
                            ForEach(list) { c in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(c.name).lineLimit(1)
                                    Text([c.band, c.ip, c.downKbps > 0 ? "↓ \(rate(c.downKbps))" : nil].compactMap { $0 }.joined(separator: " · "))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                Section {
                    Button("Refresh") { Task { await deco.refresh() } }
                    Button("Disconnect", role: .destructive) { deco.signOut() }
                }
            } else {
                Section {
                    TextField("Main Deco address", text: $host).autocorrectionDisabled()
                        #if os(iOS)
                        .keyboardType(.numbersAndPunctuation)
                        #endif
                    SecureField("Deco password", text: $password)
                    Button {
                        Task { await deco.signIn(host: host, password: password); if deco.connected { password = "" } }
                    } label: {
                        HStack { Text("Connect to Deco"); if deco.busy { Spacer(); ProgressView() } }
                    }
                    .disabled(deco.busy || password.isEmpty)
                    if let e = deco.error { Text(e).foregroundStyle(Palette.attention) }
                } header: { Text("TP-Link Deco") } footer: {
                    Text("Use the Deco’s own password (the one set when the Deco was first set up, or the owner password in the Deco app). On your home Wi‑Fi. TP-Link has no official way in for other apps, so this signs in the way the Deco app does; a Deco update may stop it until Woodruff is updated. If the Deco app is signed in as the owner on a computer at the same time, the Deco may refuse for a minute.")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Wi‑Fi")
        .inlineTitle()
        .pageSearch(text: $search, prompt: "Find a device")
        .refreshable { await deco.refresh() }
        .toolbar { if inSheet { ToolbarItem(placement: .cancellationAction) { Button(role: .close) { dismiss() } } } }
        .confirmationDialog("Restart \(restarting?.name ?? "Deco")?", isPresented: Binding(get: { restarting != nil }, set: { if !$0 { restarting = nil } }), titleVisibility: .visible) {
            Button("Restart", role: .destructive) { if let n = restarting { Task { await deco.restart(n) } } }
        } message: {
            Text("Devices on it lose Wi‑Fi for a couple of minutes while it restarts.")
        }
    }

    private func rate(_ kbps: Double) -> String {
        kbps >= 1000 ? String(format: "%.1f Mbps", kbps / 1000) : String(format: "%.0f kbps", kbps)
    }
}
