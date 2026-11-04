import Foundation
import SwiftUI
import Network
import CryptoKit
import UserNotifications
import WoodruffKit
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Alerts that reach the iPhones even when Woodruff is closed, through Apple's push service.
///
/// The Macs are always on and already see everything (cameras, TVs, the Wi‑Fi, the washer). When one of them
/// has an alert, it sends it as a real push to every family iPhone. Each iPhone puts its own push address in
/// the synced settings; the push key (made once in the Apple developer account) syncs to every Mac.
/// Several Macs may be on: the Mac with the lowest ID among the ones currently sending is the one that sends,
/// and every alert carries a fixed ID, so even if two send, the iPhone shows it once.
@Observable @MainActor
final class PushRelay {
    static let shared = PushRelay()
    static let tokensKey = "pushTokens"
    static let service = "_woodruffrelay._tcp"

    struct Token: Codable, Equatable, Sendable {
        var token: String   // hex
        var env: String     // "development" or "production"
        var topic: String   // the iPhone app's bundle ID
        var name: String
        var at: Double
    }

    private(set) var lastSent: Date?
    private(set) var lastError: String?
    private(set) var registered = false
    private(set) var otherRelays: [String] = []

    /// Every family iPhone's push address, by device (synced: each iPhone adds its own; see `reloadTokens`).
    private(set) var tokens: [String: Token] = Saved.load("pushTokens", as: [String: Token].self) ?? [:]
    /// Goes up whenever the push key changes here or arrives from another Mac, so what shows it looks again.
    private(set) var keyChanges = 0
    var keyID: String { _ = keyChanges; return Keychain.get("apns.keyid") ?? "" }
    /// Reads `keyChanges` first, whatever the Keychain holds: a page showing "Not Set Up" then shows the key as soon
    /// as it's saved here or arrives from another Mac.
    var hasKey: Bool { _ = keyChanges; return Keychain.get("apns.key") != nil && !(Keychain.get("apns.keyid") ?? "").isEmpty }
    /// This copy was built able to have push (its profile carries the push entitlement): its iPhone can sign up for
    /// instant alerts. Read from the app's profile once.
    static let builtWithPush: Bool = provisionedEnvironment() != nil
    /// Whether this Mac sends (each Mac's own choice; not synced).
    var sendsFromHere: Bool {
        get { UserDefaults.standard.object(forKey: "push.sendFromHere") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "push.sendFromHere"); advertise() }
    }
    var isSender: Bool {
        #if os(macOS)
        guard hasKey, sendsFromHere else { return false }
        return otherRelays.allSatisfy { DeviceID.value <= $0 }
        #else
        return false
        #endif
    }

    @ObservationIgnored private var jwt: (String, Date)?
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var wakeWatch: NSObjectProtocol?

    // MARK: iPhone: registering

    func start() {
        #if os(iOS)
        UIApplication.shared.registerForRemoteNotifications()
        #else
        advertise()
        browse()
        #endif
        #if os(macOS)
        // After the Mac sleeps, look and say so on the Wi‑Fi again (once it's back).
        if wakeWatch == nil {
            wakeWatch = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.wokeUp() }
            }
        }
        #endif
    }

    /// Reads the iPhones' push addresses again (one signed up, or one was removed, on another device).
    func reloadTokens() {
        let t = Saved.load(Self.tokensKey, as: [String: Token].self) ?? [:]
        if t != tokens { tokens = t }
    }

    /// The push key changed on another Mac (or was removed there): sign with the new one, and this Mac says on the
    /// Wi‑Fi whether it can send now.
    func keysChanged() {
        jwt = nil
        keyChanges += 1
        advertise()
    }

    /// The iPhone's push address, put where every Mac can read it.
    func didRegister(_ deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        var all = Saved.load(Self.tokensKey, as: [String: Token].self) ?? [:]
        #if DEBUG
        let env = "development"
        #else
        let env = Self.provisionedEnvironment() ?? "development"
        #endif
        #if os(iOS)
        let name = UIDevice.current.name
        #else
        let name = Host.current().localizedName ?? "Mac"
        #endif
        let topic = Bundle.main.bundleIdentifier ?? ""
        registered = true
        if let old = all[DeviceID.value], old.token == hex, old.env == env, old.topic == topic, old.name == name {
            if all != tokens { tokens = all }
            return
        }
        all[DeviceID.value] = Token(token: hex, env: env, topic: topic, name: name, at: Date().timeIntervalSince1970)
        tokens = all
        Saved.save(Self.tokensKey, all)
    }

    func didFail(_ error: Error) { lastError = error.localizedDescription }

    /// "development" for apps installed from Xcode, "production" for TestFlight/App Store, from the app's own profile.
    /// (Reads only the app's own files, so from anywhere.)
    nonisolated static func provisionedEnvironment() -> String? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let raw = try? Data(contentsOf: url), let text = String(data: raw, encoding: .isoLatin1),
              let r = text.range(of: "<key>aps-environment</key>") else { return nil }
        let after = text[r.upperBound...]
        guard let s = after.range(of: "<string>"), let e = after.range(of: "</string>", range: s.upperBound..<after.endIndex) else { return nil }
        return String(after[s.upperBound..<e.lowerBound])
    }

    // MARK: Mac: sending

    /// Sends one alert to every iPhone (only on the Mac that's the sender; elsewhere nothing happens).
    func relay(id: String, title: String, body: String, category: String? = nil, userInfo: [String: String] = [:]) {
        guard isSender, !tokens.isEmpty else { return }
        Task { await send(id: id, title: title, body: body, category: category, userInfo: userInfo) }
    }

    func sendTest() async {
        guard hasKey else { lastError = "Add the push key first."; return }
        guard !tokens.isEmpty else { lastError = "No iPhone has signed up yet. Open Woodruff on each iPhone once."; return }
        await send(id: "test-\(Int(Date().timeIntervalSince1970))", title: "Woodruff", body: "Alerts from this Mac reach your iPhone.", category: nil, userInfo: [:])
    }

    private func send(id: String, title: String, body: String, category: String?, userInfo: [String: String]) async {
        guard let auth = token() else { lastError = "The push key couldn’t be read. Add it again."; return }
        var aps: [String: Any] = ["alert": ["title": title, "body": body], "sound": "default", "thread-id": userInfo["tv"] ?? id.components(separatedBy: "-").first ?? "woodruff"]
        if let category { aps["category"] = category }
        var payload: [String: Any] = ["aps": aps]
        for (k, v) in userInfo { payload[k] = v }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        var gone: [String] = []
        var anySent = false
        var failure: String?
        for (device, t) in tokens {
            let host = t.env == "production" ? "api.push.apple.com" : "api.sandbox.push.apple.com"
            guard let url = URL(string: "https://\(host)/3/device/\(t.token)") else { continue }
            var r = URLRequest(url: url, timeoutInterval: 20)
            r.httpMethod = "POST"
            r.httpBody = data
            r.setValue("bearer \(auth)", forHTTPHeaderField: "authorization")
            r.setValue(t.topic, forHTTPHeaderField: "apns-topic")
            r.setValue("alert", forHTTPHeaderField: "apns-push-type")
            r.setValue("10", forHTTPHeaderField: "apns-priority")
            // Same ID as the alert itself: a repeat (from a second Mac, or the iPhone's own) replaces it.
            r.setValue(String(id.prefix(64)), forHTTPHeaderField: "apns-collapse-id")
            r.setValue(String(Int(Date().timeIntervalSince1970) + 3600), forHTTPHeaderField: "apns-expiration")
            do {
                let (d, resp) = try await URLSession.shared.data(for: r)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if code == 200 { anySent = true; continue }
                let reason = ((try? JSONSerialization.jsonObject(with: d)) as? [String: Any])?["reason"] as? String ?? "\(code)"
                if code == 410 || reason == "BadDeviceToken" || reason == "Unregistered" { gone.append(device) }
                if code == 403 { jwt = nil }
                failure = "\(t.name): \(Self.explain(reason))"
            } catch {
                failure = "\(t.name): \(error.localizedDescription)"
            }
        }
        if !gone.isEmpty {
            var all = Saved.load(Self.tokensKey, as: [String: Token].self) ?? [:]
            for g in gone { all[g] = nil }
            tokens = all
            Saved.save(Self.tokensKey, all)
        }
        if anySent { lastSent = Date() }
        lastError = failure
    }

    static func explain(_ reason: String) -> String {
        switch reason {
        case "InvalidProviderToken": return "Apple didn’t accept the push key. Check the Key ID matches the key."
        case "BadDeviceToken", "Unregistered": return "that iPhone’s address changed; it signs up again when Woodruff opens."
        case "TopicDisallowed", "BadTopic", "DeviceTokenNotForTopic": return "the key isn’t for this app’s team."
        case "TooManyProviderTokenUpdates": return "too many key refreshes; it settles on its own."
        default: return reason
        }
    }

    /// The signed key for Apple (ES256), made at most every 50 minutes as Apple asks.
    private func token() -> String? {
        if let j = jwt, j.1.timeIntervalSinceNow > -50 * 60 { return j.0 }
        guard let pem = Keychain.get("apns.key"), let key = try? P256.Signing.PrivateKey(pemRepresentation: pem), !keyID.isEmpty else { return nil }
        func b64(_ d: Data) -> String {
            d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        let team = Keychain.get("apns.team").flatMap { $0.isEmpty ? nil : $0 } ?? "D8D94SXAG6"
        let header = b64(Data(#"{"alg":"ES256","kid":"\#(keyID)"}"#.utf8))
        let claims = b64(Data(#"{"iss":"\#(team)","iat":\#(Int(Date().timeIntervalSince1970))}"#.utf8))
        let input = header + "." + claims
        guard let sig = try? key.signature(for: Data(input.utf8)) else { return nil }
        let t = input + "." + b64(sig.rawRepresentation)
        jwt = (t, Date())
        return t
    }

    /// Saves the push key (the .p8 file's text) and its Key ID; checks it's a usable key first.
    func saveKey(pem: String, keyID: String, team: String) -> Bool {
        let id = keyID.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let p = pem.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (try? P256.Signing.PrivateKey(pemRepresentation: p)) != nil else { lastError = "That isn’t a push key (.p8) file."; return false }
        guard id.count == 10 else { lastError = "The Key ID is the 10 letters and numbers shown next to the key."; return false }
        Keychain.set(p, for: "apns.key")
        Keychain.set(id, for: "apns.keyid")
        let tm = team.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        Keychain.set(tm.isEmpty ? nil : tm, for: "apns.team")
        jwt = nil
        keyChanges += 1
        lastError = nil
        advertise()
        return true
    }

    func removeKey() {
        Keychain.set(nil, for: "apns.key"); Keychain.set(nil, for: "apns.keyid"); Keychain.set(nil, for: "apns.team")
        jwt = nil
        keyChanges += 1
        advertise()
    }

    // MARK: Mac: which one sends

    /// Macs ready to send say so on the Wi‑Fi, so only one of them does.
    private func advertise() {
        #if os(macOS)
        let want = hasKey && sendsFromHere
        if !want { listener?.cancel(); listener = nil; return }
        guard listener == nil, let l = try? NWListener(using: .tcp) else { return }
        l.service = NWListener.Service(name: DeviceID.value, type: Self.service)
        l.newConnectionHandler = { $0.cancel() }
        l.stateUpdateHandler = { [weak self] s in
            if case .failed = s { Task { @MainActor in self?.listener = nil; try? await Task.sleep(nanoseconds: 5_000_000_000); self?.advertise() } }
        }
        l.start(queue: .main)
        listener = l
        #endif
    }

    private func browse() {
        let b = NWBrowser(for: .bonjour(type: Self.service, domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            var names: [String] = []
            for r in results { if case let .service(name, _, _, _) = r.endpoint { names.append(name) } }
            Task { @MainActor in self?.otherRelays = names.filter { $0 != DeviceID.value } }
        }
        b.stateUpdateHandler = { [weak self, weak b] s in
            guard case .failed = s else { return }
            Task { @MainActor in
                // Only the search running now (not one already replaced), and again after a pause, not in a spin.
                guard let self, let b, self.browser === b else { return }
                b.cancel()
                self.browser = nil
                self.otherRelays = []
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if self.browser == nil { self.browse() }
            }
        }
        b.start(queue: .main)
        browser = b
    }

    /// After the Mac wakes or the network changes, look again.
    func wake() {
        #if os(macOS)
        browser?.cancel(); browser = nil
        browse()
        advertise()
        #endif
    }

    #if os(macOS)
    /// The Mac woke from sleep: once the Wi‑Fi is back, look and say so again.
    private func wokeUp() {
        Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            wake()
        }
    }
    #endif
}

#if os(iOS)
/// Receives the iPhone's push address from iOS.
final class PushAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        MainActor.assumeIsolated { PushRelay.shared.didRegister(deviceToken) }
    }
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        MainActor.assumeIsolated { PushRelay.shared.didFail(error) }
    }
}
#endif

/// Settings → Notifications (→ Instant iPhone Alerts on the Mac): instant alerts on the iPhones.
struct PushSettingsSection: View {
    private let push = PushRelay.shared
    #if os(macOS)
    @State private var importing = false
    @State private var keyText = ""
    @State private var keyID = ""
    @State private var team = "D8D94SXAG6"
    @State private var testing = false
    #endif

    var body: some View {
        Section {
            #if os(iOS)
            LabeledContent("This iPhone", value: push.registered || push.tokens[DeviceID.value] != nil ? "Signed Up" : "Not Yet")
            LabeledContent("Sent From", value: push.hasKey ? "Your Macs" : "Not Set Up")
            if let e = push.lastError { Text(e).font(.caption).foregroundStyle(Palette.attention) }
            #else
            if push.hasKey {
                LabeledContent("Push Key", value: push.keyID)
                LabeledContent("iPhones", value: push.tokens.isEmpty ? "None Yet" : push.tokens.values.map(\.name).sorted().joined(separator: ", "))
                Toggle("Send from This Mac", isOn: Binding(get: { push.sendsFromHere }, set: { push.sendsFromHere = $0 }))
                LabeledContent("This Mac", value: push.isSender ? "Sending" : (push.sendsFromHere ? "Standing By (another Mac sends)" : "Off"))
                if let t = push.lastSent { LabeledContent("Last Sent", value: t.formatted(date: .omitted, time: .shortened)) }
                Button(testing ? "Sending…" : "Send Test Alert") {
                    testing = true
                    Task { await push.sendTest(); testing = false }
                }
                .disabled(testing)
                Button("Remove Push Key", role: .destructive) { push.removeKey() }
            } else {
                Button("Choose .p8 Key File…") { importing = true }
                if !keyText.isEmpty { Text("Key file loaded.").font(.caption).foregroundStyle(.secondary) }
                TextField("Key ID (10 characters)", text: $keyID)
                TextField("Team ID", text: $team)
                Button("Save Push Key") { if push.saveKey(pem: keyText, keyID: keyID, team: team) { keyText = "" } }
                    .disabled(keyText.isEmpty || keyID.isEmpty)
            }
            if let e = push.lastError { Text(e).font(.caption).foregroundStyle(Palette.attention) }
            #endif
        } header: {
            Text("Instant iPhone Alerts")
        } footer: {
            #if os(macOS)
            Text("Camera, doorbell, TV, internet and appliance alerts go from this Mac straight to every family iPhone, even when Woodruff is closed there. Make the key once at developer.apple.com → Certificates, IDs & Profiles → Keys → + → Apple Push Notifications service, then download the .p8 file. It syncs to your other Macs.")
            #else
            Text("Your Macs send camera, doorbell, TV, internet and appliance alerts here even when Woodruff is closed. Set it up once on a Mac, in Settings → Notifications → Instant iPhone Alerts.")
            #endif
        }
        #if os(macOS)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data, .text, .item]) { result in
            guard case let .success(url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            keyText = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            // "AuthKey_ABC123DEFG.p8" carries the Key ID in its name.
            let name = url.deletingPathExtension().lastPathComponent
            if keyID.isEmpty, name.hasPrefix("AuthKey_") { keyID = String(name.dropFirst("AuthKey_".count)) }
        }
        #endif
    }
}
