import SwiftUI
import UserNotifications
import WoodruffKit

/// "Person seen · Front door doorbell", "Someone's at the front door": the cameras' events as notifications
/// on this iPhone or Mac, like the Google Home app. They come the way the TVs get them: Google posts every
/// camera event to the family's Pub/Sub topic; this device listens on its own subscription to it (made
/// beside the TVs', so it takes nothing from them) and turns each event into a notification.
@MainActor
final class NestAlerts {
    static let shared = NestAlerts()
    static let pubsub = "https://pubsub.googleapis.com/v1/"

    var person: Bool { get { flag("nest.alert.person", true) } set { UserDefaults.standard.set(newValue, forKey: "nest.alert.person") } }
    var motion: Bool { get { flag("nest.alert.motion", false) } set { UserDefaults.standard.set(newValue, forKey: "nest.alert.motion") } }
    var doorbell: Bool { get { flag("nest.alert.doorbell", true) } set { UserDefaults.standard.set(newValue, forKey: "nest.alert.doorbell") } }
    private(set) var status = "Off"

    private var loop: Task<Void, Never>?
    private var own: String?
    private var seen: [String: Date] = [:]
    private weak var fleet: Fleet?

    private func flag(_ k: String, _ d: Bool) -> Bool { UserDefaults.standard.object(forKey: k) as? Bool ?? d }

    func start(_ fleet: Fleet) {
        self.fleet = fleet
        guard loop == nil, !Demo.isOn else { return }
        loop = Task { [weak self] in
            var wait: UInt64 = 2
            while !Task.isCancelled {
                guard let self else { return }
                let ok = await self.pullOnce(timeout: 55)
                wait = ok ? 1 : min(120, wait * 2)
                try? await Task.sleep(nanoseconds: wait * 1_000_000_000)
            }
        }
    }

    /// One listen (the background refresh on iPhone calls this too). True when it worked.
    @discardableResult
    func pullOnce(timeout: Double) async -> Bool {
        let nest = NestCameras.shared
        guard nest.connected else { status = "Connect the cameras first"; return false }
        guard nest.canAlert else { status = "Connect the cameras again to turn on alerts"; return false }
        do {
            let sub = try await subscription()
            let r = try await call("POST", "\(sub):pull", ["maxMessages": 10], timeout: timeout)
            var acks: [String] = []
            for m in r["receivedMessages"] as? [[String: Any]] ?? [] {
                if let a = m["ackId"] as? String { acks.append(a) }
                if let msg = m["message"] as? [String: Any], let b64 = msg["data"] as? String, let d = Data(base64Encoded: b64),
                   let ev = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { handle(ev, messageID: msg["messageId"] as? String) }
            }
            if !acks.isEmpty { _ = try? await call("POST", "\(sub):acknowledge", ["ackIds": acks]) }
            status = "On"
            return true
        } catch {
            status = error.localizedDescription
            // The subscription went away (unused a day): make it again next time.
            if error.localizedDescription.contains("NOT_FOUND") { own = nil }
            return false
        }
    }

    // MARK: The subscription

    /// This device's own subscription beside the family's (the TVs' one, set in Connections → Cameras).
    private func subscription() async throws -> String {
        if let own { return own }
        var shared = Keychain.get("nest.subscription") ?? ""
        if shared.isEmpty, let s = try? await fleet?.hubClient()?.settings(), let d = s.nest?.doorbell, !d.isEmpty {
            shared = d
            Keychain.set(d, for: "nest.subscription")
        }
        guard let m = shared.range(of: #"^projects/([^/]+)/subscriptions/([^/]+)$"#, options: .regularExpression), !m.isEmpty else {
            throw OAuthRelay.Failure.refused("Set up doorbell alerts on the TVs first (Settings → Connections → Cameras).")
        }
        let parts = shared.split(separator: "/")
        let project = String(parts[1]), id = String(parts[3])
        let device = DeviceID.value.lowercased().filter { $0.isLetter || $0.isNumber }.prefix(12)
        #if os(macOS)
        let suffix = "-mac-\(device)"
        #else
        let suffix = "-iphone-\(device)"
        #endif
        let name = "projects/\(project)/subscriptions/\(id.prefix(255 - suffix.count))\(suffix)"
        let topic = (try await call("GET", shared))["topic"] as? String ?? ""
        guard !topic.isEmpty else { throw OAuthRelay.Failure.refused("The family’s doorbell subscription has no topic.") }
        do {
            _ = try await call("PUT", name, [
                "topic": topic, "ackDeadlineSeconds": 30, "messageRetentionDuration": "600s",
                "expirationPolicy": ["ttl": "86400s"], "labels": ["made-by": "woodruff-family-app"],
            ])
        } catch let e as OAuthRelay.Failure where e.localizedDescription.contains("ALREADY_EXISTS") || e.localizedDescription.contains("409") {
        }
        own = name
        return name
    }

    private func call(_ method: String, _ path: String, _ body: [String: Any]? = nil, timeout: Double = 20) async throws -> [String: Any] {
        var r = URLRequest(url: URL(string: Self.pubsub + path)!, timeoutInterval: timeout + 10)
        r.httpMethod = method
        r.setValue("Bearer \(try await NestCameras.shared.accessToken())", forHTTPHeaderField: "Authorization")
        if let body {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (d, resp) = try await URLSession.shared.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
        guard (200..<300).contains(code) else {
            let e = json["error"] as? [String: Any]
            let status = e?["status"] as? String ?? "\(code)"
            if code == 409 { throw OAuthRelay.Failure.refused("ALREADY_EXISTS") }
            if code == 403 { throw OAuthRelay.Failure.refused("Google refused the alerts (\(status)). Connect the cameras again and allow everything.") }
            throw OAuthRelay.Failure.refused((e?["message"] as? String).map { "\($0) (\(status))" } ?? "Google answered \(code).")
        }
        return json
    }

    // MARK: Events → notifications

    private func handle(_ ev: [String: Any], messageID: String?) {
        guard let upd = ev["resourceUpdate"] as? [String: Any], let device = upd["name"] as? String,
              let events = upd["events"] as? [String: Any] else { return }
        // Old news (the phone was asleep) isn't worth a buzz.
        if let ts = ev["timestamp"] as? String, let t = ISO8601DateFormatter.withFraction.date(from: ts) ?? ISO8601DateFormatter().date(from: ts),
           t.timeIntervalSinceNow < -600 { return }
        let camera = NestCameras.shared.cameras.first { $0.id == device }
        let name = camera?.name ?? "Camera"
        for (type, value) in events {
            // The same event, however often Google sends it, is one key (and one notification, by its id).
            let session = (value as? [String: Any])?["eventSessionId"] as? String ?? ev["eventId"] as? String ?? messageID ?? UUID().uuidString
            let key = "\(type)|\(session)"
            guard seen[key] == nil else { continue }
            seen[key] = Date()
            switch type {
            case "sdm.devices.events.DoorbellChime.Chime" where doorbell:
                post(title: "Someone’s at the door", body: name, camera: device, key: key)
            case "sdm.devices.events.CameraPerson.Person" where person:
                post(title: "Person seen", body: name, camera: device, key: key)
            case "sdm.devices.events.CameraMotion.Motion" where motion:
                post(title: "Motion seen", body: name, camera: device, key: key)
            default: break
            }
        }
        seen = seen.filter { $0.value.timeIntervalSinceNow > -3600 }
    }

    private func post(title: String, body: String, camera: String, key: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        c.threadIdentifier = "nest-\(camera)"
        c.userInfo = ["camera": camera]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "nest-\(key)", content: c, trigger: nil))
    }
}

/// Settings → Cameras → Alerts.
struct AlertsSection: View {
    @State private var person = NestAlerts.shared.person
    @State private var motion = NestAlerts.shared.motion
    @State private var doorbell = NestAlerts.shared.doorbell
    @State private var status = NestAlerts.shared.status

    var body: some View {
        Section {
            Toggle("Doorbell Rings", isOn: $doorbell).onChange(of: doorbell) { _, v in NestAlerts.shared.doorbell = v }
            Toggle("Person Seen", isOn: $person).onChange(of: person) { _, v in NestAlerts.shared.person = v }
            Toggle("Motion", isOn: $motion).onChange(of: motion) { _, v in NestAlerts.shared.motion = v }
            if !NestCameras.shared.canAlert {
                Button("Connect Again to Turn On Alerts") { NestCameras.shared.signOut() }
            }
        } header: { Text("Alerts on This Device") } footer: {
            #if os(iOS)
            Text("Status: \(status). Alerts come straight away while Woodruff is open or was used in the last little while; when it’s been closed a long time, iOS only lets it check now and then.")
            #else
            Text("Status: \(status). The Mac listens all the time Woodruff is open (it keeps running in the menu bar).")
            #endif
        }
        .task {
            while !Task.isCancelled {
                status = NestAlerts.shared.status
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }
}

/// This device's own lasting id (the same one settings sync uses), made once.
enum DeviceID {
    static var value: String {
        if let s = UserDefaults.standard.string(forKey: "sync.id") { return s }
        let s = UUID().uuidString
        UserDefaults.standard.set(s, forKey: "sync.id")
        return s
    }
}
