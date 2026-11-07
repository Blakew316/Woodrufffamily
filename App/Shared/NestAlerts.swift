import SwiftUI
import UserNotifications
import WoodruffKit
import WidgetKit

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
    private(set) var status = "Off" {
        // Each change in the log, so a Mac that stopped listening says why (Console: com.woodruff.family, alerts).
        didSet { if status != oldValue { PushRelay.log.notice("camera listener: \(self.status, privacy: .public)") } }
    }
    /// For the log's line every ten minutes: listens and messages since the last one.
    private var listens = 0, messages = 0, lastBeat = Date()

    private var loop: Task<Void, Never>?
    private var own: String?
    private var seen: [String: Date] = [:]
    /// The alert that went out for each event session: the newer cameras send the event's clip a few seconds later,
    /// in a second message for the same session, and it's added to that alert then.
    private var posted: [String: Posted] = [:]
    private struct Posted {
        var title: String
        var body: String
        var camera: String
        var key: String
        var event: String?
        var hasClip: Bool
        var at: Date
    }
    private weak var fleet: Fleet?
    /// When the event being posted happened (Google's timestamp), for Settings' Last Camera Event.
    private var eventHappened: Date?

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
            beat(received: (r["receivedMessages"] as? [Any])?.count ?? 0)
            var acks: [String] = []
            for m in r["receivedMessages"] as? [[String: Any]] ?? [] {
                if let a = m["ackId"] as? String { acks.append(a) }
                if let msg = m["message"] as? [String: Any], let b64 = msg["data"] as? String, let d = Data(base64Encoded: b64),
                   let ev = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { handle(ev, messageID: msg["messageId"] as? String) }
            }
            if !acks.isEmpty { _ = try? await call("POST", "\(sub):acknowledge", ["ackIds": acks]) }
            status = "On"
            return true
        } catch let e as URLError where e.code == .timedOut || e.code == .networkConnectionLost {
            // A long listen that ended without news (or a phone's connection changing): normal, and listened again.
            beat(received: 0)
            status = "On"
            return true
        } catch {
            status = error.localizedDescription
            // The subscription went away (unused a day): make it again next time.
            if error.localizedDescription.contains("NOT_FOUND") { own = nil }
            return false
        }
    }

    /// Counts a listen; every ten minutes the log says how many there were and how many messages came.
    private func beat(received: Int) {
        listens += 1
        messages += received
        guard Date().timeIntervalSince(lastBeat) > 600 else { return }
        PushRelay.log.notice("camera listener: \(self.listens) listens, \(self.messages) messages in the last \(Int(Date().timeIntervalSince(self.lastBeat) / 60)) minutes")
        listens = 0; messages = 0; lastBeat = Date()
    }

    // MARK: The subscription

    /// This device's own subscription beside the family's (the TVs' one, set in Accounts → Nest Cameras).
    private func subscription() async throws -> String {
        if let own { return own }
        var shared = Keychain.get("nest.subscription") ?? ""
        if shared.isEmpty, let s = try? await fleet?.hubClient()?.settings(), let d = s.nest?.doorbell, !d.isEmpty {
            shared = d
            Keychain.set(d, for: "nest.subscription")
        }
        guard let m = shared.range(of: #"^projects/([^/]+)/subscriptions/([^/]+)$"#, options: .regularExpression), !m.isEmpty else {
            throw OAuthRelay.Failure.refused("Set up doorbell alerts on the TVs first (Settings → Accounts → Nest Cameras).")
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
        guard let upd = ev["resourceUpdate"] as? [String: Any], let device = upd["name"] as? String else { return }
        // A trait change, not an event: a camera going offline or coming back shows on its tile.
        if let status = ((upd["traits"] as? [String: Any])?["sdm.devices.traits.Connectivity"] as? [String: Any])?["status"] as? String {
            NestCameras.shared.setOnline(device, status.uppercased() != "OFFLINE")
        }
        guard let events = upd["events"] as? [String: Any] else { return }
        // When it happened, by Google's clock: how late it reached this device is logged and shown in Settings.
        let happened = (ev["timestamp"] as? String).flatMap { ISO8601DateFormatter.withFraction.date(from: $0) ?? ISO8601DateFormatter.plain.date(from: $0) }
        if let happened {
            let late = Int(-happened.timeIntervalSinceNow)
            PushRelay.log.notice("camera event reached this device \(late, privacy: .public) s after it happened")
            // Old news (the phone was asleep) isn't worth a buzz.
            if late > 600 {
                PushRelay.log.notice("camera event dropped: \(late, privacy: .public) s old")
                return
            }
        }
        eventHappened = happened
        let camera = NestCameras.shared.cameras.first { $0.id == device }
        let name = camera?.name ?? "Camera"
        // The event's short clip, when the camera sends one (newer Nest cameras and doorbells).
        let clip = (events["sdm.devices.events.CameraClipPreview.ClipPreview"] as? [String: Any])?["previewUrl"] as? String
        let kinds = events.keys.map { $0.components(separatedBy: ".").last ?? $0 }.sorted().joined(separator: ", ")
        PushRelay.log.notice("camera event from \(name, privacy: .public): \(kinds, privacy: .public)\(clip != nil ? " (with clip)" : "", privacy: .public)")
        for (type, value) in events {
            // The same event, however often Google sends it, is one key (and one notification, by its id).
            let session = (value as? [String: Any])?["eventSessionId"] as? String ?? ev["eventId"] as? String ?? messageID ?? UUID().uuidString
            // Its snapshot, for the cameras without clips (Google makes it only within 30 seconds of the event).
            let eventID = (value as? [String: Any])?["eventId"] as? String
            let key = "\(type)|\(session)"
            guard seen[key] == nil else { continue }
            seen[key] = Date()
            var title: String?
            switch type {
            case "sdm.devices.events.DoorbellChime.Chime" where doorbell: title = "Someone’s at the door"
            case "sdm.devices.events.CameraPerson.Person" where person: title = "Person seen"
            case "sdm.devices.events.CameraMotion.Motion" where motion: title = "Motion seen"
            case "sdm.devices.events.CameraClipPreview.ClipPreview":
                // The clip of an alert already shown: the same alert again, quietly, now with it.
                if let url = (value as? [String: Any])?["previewUrl"] as? String, !url.isEmpty,
                   let p = posted[session], !p.hasClip {
                    posted[session]?.hasClip = true
                    post(title: p.title, body: p.body, camera: p.camera, key: p.key, event: p.event, clip: url, quiet: true)
                }
            default: break
            }
            if title == nil, ["Chime", "Person", "Motion"].contains(where: { type.hasSuffix(".\($0)") }) {
                PushRelay.log.notice("camera event not alerted: \(type.components(separatedBy: ".").last ?? type, privacy: .public) is off on this device")
            }
            if let title {
                posted[session] = Posted(title: title, body: name, camera: device, key: key, event: eventID, hasClip: clip != nil, at: Date())
                post(title: title, body: name, camera: device, key: key, event: eventID, clip: clip)
            }
        }
        seen = seen.filter { $0.value.timeIntervalSinceNow > -3600 }
        posted = posted.filter { $0.value.at.timeIntervalSinceNow > -3600 }
    }

    /// [quiet]: an update of an alert already shown (its clip came later), so no second sound.
    #if os(macOS)
    /// A vehicle the Mac saw itself on a camera's stream (Google sends no vehicle events): the same alert as Google's
    /// events, with that frame as its picture.
    func postVehicle(camera: NestCameras.Camera, jpeg: Data) {
        eventHappened = Date()
        post(title: "Vehicle seen", body: camera.name, camera: camera.id,
             key: "vehicle|\(camera.id)|\(Int(Date().timeIntervalSince1970))", event: nil, clip: nil, picture: jpeg)
    }
    #endif

    /// [picture]: the Mac's own frame of the moment (a vehicle it saw), used instead of fetching one.
    private func post(title: String, body: String, camera: String, key: String, event: String?, clip: String?, quiet: Bool = false,
                      picture: Data? = nil) {
        let short = Self.shortID(key)
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = quiet ? nil : .default
        c.threadIdentifier = "nest-\(camera)"
        // What the iPhones need to fetch the moment (the Mac's push carries these to them).
        c.userInfo = ["camera": camera, "key": short, "event": event ?? "", "clip": clip ?? ""]
        // The doorbell itself rang: the iPhones show it as a Live Activity too (started by the Mac's push).
        if title.localizedCaseInsensitiveContains("at the door") { c.userInfo["ring"] = "1" }
        // The alert goes at once; its picture follows as a quiet update of the same alert (same id), so fetching it
        // never holds the alert up.
        Notifier.deliver(c, id: "nest-" + short)
        #if os(iOS)
        // The TVs & Cameras widget: the camera's red tag at once, its picture of the moment when it comes.
        let doorbell = NestCameras.shared.cameras.first { $0.id == camera }?.doorbell ?? false
        let tag = title.localizedCaseInsensitiveContains("person") ? "Person"
            : title.localizedCaseInsensitiveContains("motion") ? "Motion" : title.localizedCaseInsensitiveContains("ring") || title.localizedCaseInsensitiveContains("door") ? "Ring" : "Event"
        if PhoneWidgetShare.saveCamera(id: camera, name: body, doorbell: doorbell, event: tag) {
            WidgetCenter.shared.reloadTimelines(ofKind: PhoneWidgetShare.tvsCamerasKind); WidgetCenter.shared.reloadTimelines(ofKind: PhoneWidgetShare.doorbellKind)
        }
        // Here: the clip or snapshot added to the alert when Google has it.
        Task {
            guard let file = await CameraEventMedia.fetch(camera: camera, eventID: event, clipURL: clip, key: short, timeout: 10) else { return }
            if let jpeg = await CameraEventMedia.still(file) {
                PhoneWidgetShare.saveCamera(id: camera, name: body, doorbell: doorbell, jpeg: jpeg)
                WidgetCenter.shared.reloadTimelines(ofKind: PhoneWidgetShare.tvsCamerasKind); WidgetCenter.shared.reloadTimelines(ofKind: PhoneWidgetShare.doorbellKind)
            }
            guard let a = CameraEventMedia.attachment(file),
                  let update = c.mutableCopy() as? UNMutableNotificationContent else { return }
            update.attachments = [a]
            update.sound = nil
            Notifier.deliver(update, id: "nest-" + short)
        }
        #else
        // The Mac fetches the moment itself and sends a small picture of it as a quiet update, so every iPhone shows
        // one, signed in to the cameras or not.
        let received = Date(), happened = eventHappened
        // The Mac's TVs & Cameras widget: the camera's red tag at once, its picture of the moment when there is one.
        let macCam = NestCameras.shared.cameras.first { $0.id == camera }
        let macTag = title.localizedCaseInsensitiveContains("person") ? "Person"
            : title.localizedCaseInsensitiveContains("motion") ? "Motion" : title.localizedCaseInsensitiveContains("ring") || title.localizedCaseInsensitiveContains("door") ? "Ring" : "Event"
        if !quiet, MacCameraShare.save(id: camera, name: macCam?.name ?? body, doorbell: macCam?.doorbell ?? false, event: macTag) {
            WidgetCenter.shared.reloadTimelines(ofKind: MacCameraShare.kind); WidgetCenter.shared.reloadTimelines(ofKind: "com.woodruff.family.widget.tvs")
        }
        Task {
            var thumb: String?
            var still: Data?
            if let picture {
                still = picture
                let file = FileManager.default.temporaryDirectory.appendingPathComponent("frame-\(short).jpg")
                if (try? picture.write(to: file, options: .atomic)) != nil { thumb = await CameraEventMedia.thumbnail(file) }
                try? FileManager.default.removeItem(at: file)
            } else if let token = try? await NestCameras.shared.accessToken(),
               let file = await CameraEventMedia.fetch(camera: camera, eventID: event, clipURL: clip, key: short, timeout: 10, using: token) {
                thumb = await CameraEventMedia.thumbnail(file)
                still = await CameraEventMedia.still(file)
            }
            // Google has no picture for these cameras (no snapshot, and often no clip): one frame from the live stream.
            var how = picture != nil ? "the Mac's own frame" : "Google's clip or snapshot"
            if thumb == nil, !quiet, picture == nil, let cam = NestCameras.shared.cameras.first(where: { $0.id == camera }), cam.webRTC, cam.online {
                let t0 = Date()
                if let jpeg = await CameraStreams.shared.grabFrame(cam) {
                    still = jpeg
                    let file = FileManager.default.temporaryDirectory.appendingPathComponent("grab-\(short).jpg")
                    if (try? jpeg.write(to: file, options: .atomic)) != nil { thumb = await CameraEventMedia.thumbnail(file) }
                    try? FileManager.default.removeItem(at: file)
                }
                how = String(format: "the live stream, %.1f s", Date().timeIntervalSince(t0))
            }
            if let still, MacCameraShare.save(id: camera, name: macCam?.name ?? body, doorbell: macCam?.doorbell ?? false, jpeg: still) {
                WidgetCenter.shared.reloadTimelines(ofKind: MacCameraShare.kind); WidgetCenter.shared.reloadTimelines(ofKind: "com.woodruff.family.widget.tvs")
            }
            // The latest event, for Send Test Camera Alert.
            Saved.save(LastCameraEvent.savedKey, LastCameraEvent(title: title, body: body, camera: camera, key: short, happened: happened,
                                                                 event: event ?? "", clip: clip ?? "", at: received, thumb: thumb))
            PushRelay.log.notice("picture for \(body, privacy: .public)\(quiet ? " (clip came later)" : "", privacy: .public): \(thumb.map { "\($0.count) characters, from \(how)" } ?? "none (no clip or snapshot from Google, and no frame from the live stream)", privacy: .public)")
            guard let thumb, let update = c.mutableCopy() as? UNMutableNotificationContent else { return }
            update.userInfo["thumb"] = thumb
            update.userInfo["ring"] = nil   // the Live Activity started with the alert itself
            update.sound = nil
            Notifier.deliver(update, id: "nest-" + short)
        }
        #endif
    }

    /// The latest camera event this device alerted for (Send Test Camera Alert sends it again).
    static var lastEvent: LastCameraEvent? { Saved.load(LastCameraEvent.savedKey, as: LastCameraEvent.self) }

    /// A short name for an event, the same on every device. Google's event ids are long, and the Mac's push to the
    /// iPhones carries at most 64 characters of it (Apple's limit), so the iPhone's own alert for the same event had
    /// a different id and showed a second time; with the same short id the two are one notification.
    static func shortID(_ key: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in key.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(h, radix: 16)
    }
}

/// A camera alert as it went out: what Send Test Camera Alert sends again, picture and clip included.
struct LastCameraEvent: Codable, Equatable {
    static let savedKey = "nest.lastEvent"
    var title: String
    var body: String
    var camera: String
    var key: String
    /// When it happened by Google's clock (nil: an older record).
    var happened: Date? = nil
    var event: String
    var clip: String
    var at: Date
    /// The small picture the Mac sent with it.
    var thumb: String? = nil
}

/// The cameras' alerts on this device: Settings → Notifications → Camera Alerts.
struct AlertsSection: View {
    var title = "Alerts on This Device"
    /// Offers to connect the cameras again when they can't alert yet (it signs them out first, so only where the
    /// cameras are connected); elsewhere it says where that's done.
    var showsReconnect = true
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
                if showsReconnect {
                    Button("Connect Again to Turn On Alerts") { NestCameras.shared.signOut() }
                } else {
                    Text("Connect the cameras again in Smart Home → Cameras to turn these on.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        } header: { Text(title) } footer: {
            #if os(iOS)
            // One block of text: a footer shows only its first view, which hid the line about the last alert.
            VStack(alignment: .leading, spacing: 6) {
                if let last = CameraEventMedia.lastPush {
                    Text("Last alert from the Mac: \(last.at.formatted(date: .abbreviated, time: .shortened)). \(last.what).")
                        .foregroundStyle(.primary)
                } else {
                    Text("No alert from the Mac has reached this iPhone yet (or its picture step couldn’t report back).")
                        .foregroundStyle(.primary)
                }
                Text("Status: \(status). Alerts come straight away while Woodruff is open or was used in the last little while; when it’s been closed a long time, iOS only lets it check now and then.")
            }
            #else
            Text("Status: \(status). The Mac listens all the time Woodruff is open (it keeps running in the menu bar).")
            #endif
        }
        .task {
            while !Task.isCancelled {
                // Only when it's changed: the switches above aren't redrawn every 2 seconds for nothing.
                let now = NestAlerts.shared.status
                if now != status { status = now }
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
