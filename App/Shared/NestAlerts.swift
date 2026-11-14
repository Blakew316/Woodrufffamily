import SwiftUI
import UserNotifications
import Network
import WoodruffKit
#if canImport(WidgetKit)
import WidgetKit
#endif
#if os(macOS)
import AppKit
#endif

/// "Person seen · Front door doorbell", "Someone's at the front door": the cameras' events as notifications
/// on this iPhone or Mac, like the Google Home app. They come the way the TVs get them: Google posts every
/// camera event to the family's Pub/Sub topic; this device listens on its own subscription to it (made
/// beside the TVs', so it takes nothing from them) and turns each event into a notification.
@MainActor
final class NestAlerts {
    static let shared = NestAlerts()
    static let pubsub = "https://pubsub.googleapis.com/v1/"
    /// The longest an alert waits for its picture: it goes with the best there is by then, and a better one that comes
    /// later is put in its place quietly.
    private static let pictureWait: Double = 2
    /// iPhone: how long its own alert for an event waits for the Mac's push of it (which has the Mac's picture).
    private static let pushWait: Double = 8

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
    /// The network coming back (and the Mac waking) is a listen at once (`listenNow`).
    private var network: NWPathMonitor?
    /// Whether the network was there at its last report (nil before the first).
    private var networkUp: Bool?
    #if os(macOS)
    private var wakeWatch: NSObjectProtocol?
    #endif
    private var own: String?
    /// When a listen last worked (the Mac's watchdog checks this).
    private(set) var lastHeard: Date?
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
    #if os(macOS)
    /// Each event session's picture being got now (a clip that comes in a later message joins it).
    private var racing: [String: EventPicture] = [:]
    #elseif os(iOS)
    /// A visit's clip that came in a later message (a doorbell's ring comes first and its clip a few seconds after):
    /// this iPhone's own alert for it, shown only when the Mac's push doesn't come, gets its picture from it.
    private var laterClips: [String: String] = [:]
    #endif
    private weak var fleet: Fleet?
    /// When the event being posted happened (Google's timestamp), for Settings' Last Camera Event.
    private var eventHappened: Date?

    private func flag(_ k: String, _ d: Bool) -> Bool { UserDefaults.standard.object(forKey: k) as? Bool ?? d }

    /// The Mac's watchdog: listening again from scratch (a new subscription look-up, a new loop).
    func restartListening() {
        loop?.cancel(); loop = nil
        own = nil
        if let fleet { start(fleet) }
    }

    func start(_ fleet: Fleet) {
        self.fleet = fleet
        #if os(macOS)
        AlertWatchdog.shared.start()
        #endif
        guard loop == nil, !Demo.isOn else { return }
        watchNetwork()
        loop = Task { [weak self] in
            var wait: Double = 1
            while !Task.isCancelled {
                guard let self else { return }
                let ok = await self.pullOnce(timeout: 55)
                // After an error, again within a few seconds: 2, 4, 8, then 15 at most, each a little shorter by chance so
                // the family's devices don't all ask at once. (It doubled to two minutes: a Mac could be that late with
                // an alert after the network dropped.)
                wait = ok ? 1 : min(15, max(2, wait * 2))
                let pause = ok ? wait : wait * Double.random(in: 0.7...1)
                try? await Task.sleep(nanoseconds: UInt64(pause * 1_000_000_000))
            }
        }
    }

    /// The network came back, or the Mac woke: listened again at once (the subscription kept), not after the wait the
    /// last error left, nor down a connection that died meanwhile.
    func listenNow() {
        guard loop != nil, let fleet else { return }
        loop?.cancel(); loop = nil
        start(fleet)
    }

    private func watchNetwork() {
        guard network == nil else { return }
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] path in
            let up = path.status == .satisfied
            Task { @MainActor in self?.networkChanged(up) }
        }
        m.start(queue: .main)
        network = m
        #if os(macOS)
        wakeWatch = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.listenNow() }
        }
        #endif
    }

    private func networkChanged(_ up: Bool) {
        let was = networkUp
        networkUp = up
        if up, was == false { listenNow() }
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
                var alerts: [Task<Void, Never>] = []
                if let msg = m["message"] as? [String: Any], let b64 = msg["data"] as? String, let d = Data(base64Encoded: b64),
                   let ev = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { alerts = handle(ev, messageID: msg["messageId"] as? String) }
                guard let a = m["ackId"] as? String else { continue }
                // A message with an alert to show is acknowledged once that alert has gone out: until then Google keeps
                // it, and sends it again if this device stops first (the app quit for an update, or ended by iOS).
                // Acknowledged as it came, an alert the app never got to show was lost.
                if alerts.isEmpty { acks.append(a) } else { acknowledge(a, on: sub, after: alerts) }
            }
            if !acks.isEmpty { _ = try? await call("POST", "\(sub):acknowledge", ["ackIds": acks]) }
            status = "On"
            lastHeard = Date()
            return true
        } catch let e as URLError where e.code == .timedOut || e.code == .networkConnectionLost {
            // A long listen that ended without news (or a phone's connection changing): normal, and listened again.
            beat(received: 0)
            status = "On"
            lastHeard = Date()
            return true
        } catch {
            // Called off to listen again at once (`listenNow`): nothing went wrong.
            if Task.isCancelled { return false }
            status = error.localizedDescription
            // The subscription went away (unused a day): make it again next time.
            if error.localizedDescription.contains("NOT_FOUND") { own = nil }
            return false
        }
    }

    /// Acknowledges the message [ack] once each of [alerts] has gone out.
    private func acknowledge(_ ack: String, on sub: String, after alerts: [Task<Void, Never>]) {
        Task {
            for a in alerts { await a.value }
            _ = try? await call("POST", "\(sub):acknowledge", ["ackIds": [ack]])
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
        let made: [String: Any] = [
            "topic": topic, "ackDeadlineSeconds": 30, "messageRetentionDuration": "600s",
            "expirationPolicy": ["ttl": "86400s"], "labels": ["made-by": "woodruff-family-app"],
        ]
        do {
            _ = try await call("PUT", name, made)
        } catch let e as OAuthRelay.Failure where e.localizedDescription.contains("ALREADY_EXISTS") || e.localizedDescription.contains("409") {
            // Made before: still on the family's topic? One left on a topic since made again (Google then names it
            // "_deleted-topic_") hears nothing ever again, though every listen works: it's made again, on this one.
            if let kept = (try? await call("GET", name))?["topic"] as? String, kept != topic {
                PushRelay.log.notice("camera listener: this device's subscription was on another topic, made again")
                _ = try? await call("DELETE", name)
                _ = try await call("PUT", name, made)
            }
        }
        own = name
        return name
    }

    private func call(_ method: String, _ path: String, _ body: [String: Any]? = nil, timeout: Double = 20, retried: Bool = false) async throws -> [String: Any] {
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
            // The sign-in ran out early (Google ended it, or another device's renewal replaced it): renew it once and
            // ask again, rather than failing every listen until the kept one's time is up.
            if code == 401, !retried {
                Keychain.set(nil, for: "nest.access")
                return try await call(method, path, body, timeout: timeout, retried: true)
            }
            let e = json["error"] as? [String: Any]
            let status = e?["status"] as? String ?? "\(code)"
            if code == 409 { throw OAuthRelay.Failure.refused("ALREADY_EXISTS") }
            if code == 403 { throw OAuthRelay.Failure.refused("Google refused the alerts (\(status)). Connect the cameras again and allow everything.") }
            throw OAuthRelay.Failure.refused((e?["message"] as? String).map { "\($0) (\(status))" } ?? "Google answered \(code).")
        }
        return json
    }

    // MARK: Events → notifications

    /// The alerts it started, each done once it has gone out (or was found already shown).
    private func handle(_ ev: [String: Any], messageID: String?) -> [Task<Void, Never>] {
        guard let upd = ev["resourceUpdate"] as? [String: Any], let device = upd["name"] as? String else { return [] }
        // A trait change, not an event: a camera going offline or coming back shows on its tile.
        if let status = ((upd["traits"] as? [String: Any])?["sdm.devices.traits.Connectivity"] as? [String: Any])?["status"] as? String {
            NestCameras.shared.setOnline(device, status.uppercased() != "OFFLINE")
        }
        guard let events = upd["events"] as? [String: Any] else { return [] }
        var alerts: [Task<Void, Never>] = []
        // When it happened, by Google's clock: how late it reached this device is logged and shown in Settings.
        let happened = (ev["timestamp"] as? String).flatMap { ISO8601DateFormatter.withFraction.date(from: $0) ?? ISO8601DateFormatter.plain.date(from: $0) }
        if let happened {
            let late = Int(-happened.timeIntervalSinceNow)
            PushRelay.log.notice("camera event reached this device \(late, privacy: .public) s after it happened")
            // Older than a quarter of an hour (the phone was asleep a long time): old news, not shown.
            if late > 900 {
                PushRelay.log.notice("camera event dropped: \(late, privacy: .public) s old")
                return []
            }
        }
        eventHappened = happened
        #if os(iOS) || os(tvOS)
        // Caught up later (the iPhone was closed or asleep when the Mac's push should have come): shown, quietly.
        let catchingUp = happened.map { -$0.timeIntervalSinceNow > 60 } ?? false
        #else
        let catchingUp = false
        #endif
        let camera = NestCameras.shared.cameras.first { $0.id == device }
        let name = camera?.name ?? "Camera"
        // The event's short clip, when the camera sends one (newer Nest cameras and doorbells).
        let clip = (events["sdm.devices.events.CameraClipPreview.ClipPreview"] as? [String: Any])?["previewUrl"] as? String
        let kinds = events.keys.map { $0.components(separatedBy: ".").last ?? $0 }.sorted().joined(separator: ", ")
        PushRelay.log.notice("camera event from \(name, privacy: .public): \(kinds, privacy: .public)\(clip != nil ? " (with clip)" : "", privacy: .public)")
        // The ring first, then a person, then motion: one visit is one alert, and the most telling one.
        func rank(_ t: String) -> Int { t.hasSuffix(".Chime") ? 0 : t.hasSuffix(".Person") ? 1 : t.hasSuffix(".Motion") ? 2 : 3 }
        for (type, value) in events.sorted(by: { rank($0.key) < rank($1.key) }) {
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
                // The clip of an alert already shown: not a second alert (one per event, its picture in it).
                if let url = (value as? [String: Any])?["previewUrl"] as? String, !url.isEmpty,
                   let p = posted[session], !p.hasClip {
                    posted[session]?.hasClip = true
                    #if os(macOS)
                    // Its picture is still being got: the clip's first frames can be it.
                    if let race = racing[session] {
                        race.offerClip(url)
                        PushRelay.log.notice("clip for \(p.body, privacy: .public) came while its picture was being got (used for it)")
                        break
                    }
                    #elseif os(iOS)
                    laterClips[session] = url
                    #endif
                    PushRelay.log.notice("clip for \(p.body, privacy: .public) came after its alert (no second alert)")
                }
            default: break
            }
            if title == nil, ["Chime", "Person", "Motion"].contains(where: { type.hasSuffix(".\($0)") }) {
                PushRelay.log.notice("camera event not alerted: \(type.components(separatedBy: ".").last ?? type, privacy: .public) is off on this device")
            }
            // Another event of a visit already alerted for (a person after the ring, motion after a person): not a
            // second alert. A ring after a person or motion alert still goes (it means someone's at the door), and so
            // does a person after a motion alert (with Motion on, the visit's person was never said).
            if title != nil, let p = posted[session] {
                let tells = type.hasSuffix(".Chime") ? !p.title.localizedCaseInsensitiveContains("door")
                    : type.hasSuffix(".Person") && p.title.localizedCaseInsensitiveContains("motion")
                if !tells {
                    PushRelay.log.notice("camera event not alerted: \(type.components(separatedBy: ".").last ?? type, privacy: .public) is part of a visit already alerted for")
                    continue
                }
            }
            if let title {
                posted[session] = Posted(title: title, body: name, camera: device, key: key, event: eventID, hasClip: clip != nil, at: Date())
                if let alert = post(title: title, body: name, camera: device, key: key, event: eventID, clip: clip, quiet: catchingUp,
                                    session: session, eventSession: (value as? [String: Any])?["eventSessionId"] as? String) {
                    alerts.append(alert)
                }
            }
        }
        seen = seen.filter { $0.value.timeIntervalSinceNow > -3600 }
        posted = posted.filter { $0.value.at.timeIntervalSinceNow > -3600 }
        #if os(iOS)
        laterClips = laterClips.filter { posted[$0.key] != nil }
        #endif
        return alerts
    }

    /// [quiet]: an update of an alert already shown (its clip came later), so no second sound.
    #if os(macOS)
    /// A vehicle the Mac saw itself on a camera's stream (Google sends no vehicle events): the same alert as Google's
    /// events, with that frame as its picture, close on the vehicle where the detector found it ([box], in shares of
    /// the frame from its top left). (Its close-up was framed on whatever stood out or changed in the picture, which
    /// could be a person walking past, or the house.)
    func postVehicle(camera: NestCameras.Camera, jpeg: Data, box: CGRect? = nil) {
        let now = Date()
        eventHappened = now
        // The frame the vehicle was found in is smaller than the camera sends (looking through full-size frames all
        // day would cost too much), and the alert's picture, its close-up and the event's photo on the camera's page
        // were all cut from it: half the detail of every other alert's. The stream's own full-size picture of the
        // same moment is the alert's picture instead, when this Mac keeps the last few seconds.
        var picture = jpeg
        let given = CameraEventMedia.pixelSize(jpeg)?.width ?? 0
        if let full = CameraStreams.shared.moments(camera.id, since: now.addingTimeInterval(-1.5)).max(by: { $0.at < $1.at }),
           full.width > given {
            picture = full.jpeg
        }
        post(title: "Vehicle seen", body: camera.name, camera: camera.id,
             key: "vehicle|\(camera.id)|\(Int(now.timeIntervalSince1970))", event: nil, clip: nil, picture: picture, subject: box)
    }
    #endif

    /// [picture]: the Mac's own frame of the moment (a vehicle it saw), used instead of fetching one; [subject]: where
    /// what it saw is in that frame (shares of it, from its top left).
    /// [session]: the event session (a clip that comes later for it joins the picture still being got); [eventSession]:
    /// Google's own session id, when it gave one (the Google TVs and the LG are told it with the alert's picture).
    /// Returns the alert's work, done once it has gone out (its message is acknowledged then).
    @discardableResult
    private func post(title: String, body: String, camera: String, key: String, event: String?, clip: String?, quiet: Bool = false,
                      picture: Data? = nil, subject: CGRect? = nil, session: String? = nil, eventSession: String? = nil) -> Task<Void, Never>? {
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
        let id = "nest-" + short
        if !quiet { CameraStreams.shared.noteAlert(camera) }
        #if os(macOS)
        if !quiet { WeeklyNote.countAlert(camera: body) }
        #endif
        #if os(iOS)
        // The TVs & Cameras widget: the camera's red tag at once, its picture of the moment when it comes.
        let doorbell = NestCameras.shared.cameras.first { $0.id == camera }?.doorbell ?? false
        let tag = title.localizedCaseInsensitiveContains("person") ? "Person"
            : title.localizedCaseInsensitiveContains("motion") ? "Motion" : title.localizedCaseInsensitiveContains("ring") || title.localizedCaseInsensitiveContains("door") ? "Ring" : "Event"
        if PhoneWidgetShare.saveCamera(id: camera, name: body, doorbell: doorbell, event: tag) {
            PhoneWidgetShare.reloadWidgets(showing: camera)
        }
        // Where the extension (and this) can ask the Mac Studio for its picture of the event.
        CameraEventMedia.keepShare(token: CameraShareKey.token(), hosts: UserDefaults.standard.string(forKey: CameraShareKey.hostsKey))
        // Google's picture of the event, asked for at once: it makes a snapshot only within 30 seconds of the event.
        // Kept for the replay, and for this device's own alert below.
        let google = Task { await CameraEventMedia.fetch(camera: camera, eventID: event, clipURL: clip, key: short, until: Date().addingTimeInterval(25)) }
        let happened = eventHappened
        // One alert per event, with its picture. The Mac's push normally brings it (picture included), so the iPhone
        // shows its own only when that hasn't come: after a short wait for it (the Mac's alert goes within a few
        // seconds of the event, and this waited fifteen), or at once when catching up.
        return Task {
            if !quiet { try? await Task.sleep(nanoseconds: UInt64(Self.pushWait * 1_000_000_000)) }
            let shown = await Self.alreadyShown(id: id, key: short)
            // The visit's clip, when it came in a later message meanwhile (a ring's comes a few seconds after it, and
            // without it a doorbell that makes no snapshots had no picture): fetched now, and replayed when it's opened.
            let later = (clip ?? "").isEmpty ? session.flatMap { self.laterClips[$0] } : nil
            if let later { c.userInfo["clip"] = later }
            // Google's clip or snapshot, or the Mac Studio's picture of the event, whichever comes first: for this
            // iPhone's own alert, two seconds at most (one that comes after is put in quietly, below).
            let fetching = Task {
                await CameraEventMedia.firstPicture(camera: camera, eventID: event, clipURL: later ?? clip, key: short,
                                                    deadline: Date().addingTimeInterval(shown ? 10 : 8), google: later == nil ? google : nil)
            }
            let got = shown ? await fetching.value : await Self.value(of: fetching, within: Self.pictureWait)
            var file = got?.file
            var how = got == nil ? "none" : got!.fromMac ? "the Mac’s picture" : file?.pathExtension == "mp4" ? "Google’s clip" : "Google’s snapshot"
            // Neither: the camera's latest picture (better than none), kept from its stream here, else the one the
            // widgets show (an earlier alert's: a camera never opened on this iPhone has no other).
            if file == nil, !shown, let jpeg = CameraStreams.shared.latestStill(camera) ?? Self.widgetStill(camera) {
                file = CameraEventMedia.jpegFile(jpeg, name: "kept-\(short)")
                if file != nil { how = "the camera’s latest picture" }
            }
            // The widget's still, and (for an alert shown here) where who or what was seen is, from one decode.
            var look: (still: Data?, focus: CGRect?) = (nil, nil)
            if let file {
                if shown { look.still = await CameraEventMedia.still(file) }
                else { look = await CameraEventMedia.stillAndFocus(file, title: title) }
            }
            if let jpeg = look.still {
                PhoneWidgetShare.saveCamera(id: camera, name: body, doorbell: doorbell, jpeg: jpeg)
                PhoneWidgetShare.reloadWidgets(showing: camera)
            }
            if shown {
                PushRelay.log.notice("alert for \(body, privacy: .public) already shown from the Mac (not shown twice)")
                return
            }
            // Its picture close on who or what was seen, cut from the full picture (as Google Home's is); with
            // nothing to close in on, the picture or the clip as it is. Whether it's that close-up.
            @MainActor func attach(_ file: URL, _ look: (still: Data?, focus: CGRect?)) async -> Bool {
                var all: [UNNotificationAttachment] = []
                var pictured = file
                if let focus = look.focus, let close = await CameraEventMedia.closeUp(file, focus: focus) { pictured = close }
                if let a = CameraEventMedia.attachment(pictured) { all.append(a) }
                // A clip also carries a still of it, as the alerts from the Mac do: Apple Watch shows a picture,
                // never a video.
                if pictured.pathExtension == "mp4", let jpeg = look.still, let f = CameraEventMedia.jpegFile(jpeg, name: "still-\(short)"),
                   let s = CameraEventMedia.attachment(f, identifier: "still") {
                    all.append(s)
                }
                c.attachments = all
                return pictured != file
            }
            var cut = false
            if let file { cut = await attach(file, look) }
            // The Mac's push may have come during the fetch: not shown twice.
            if await Self.alreadyShown(id: id, key: short) {
                PushRelay.log.notice("alert for \(body, privacy: .public) came from the Mac meanwhile (not shown twice)")
                return
            }
            PushRelay.log.notice("alert for \(body, privacy: .public) shown here, picture: \(c.attachments.isEmpty ? "none" : how, privacy: .public)")
            // The Mac's push for it, if it comes after all, takes its place quietly.
            CameraEventMedia.noteShownHere(short)
            Notifier.deliver(c, id: id)
            // Its one line in the family's log, once its picture is settled.
            let shownAt = Date()
            var line = CameraEventMedia.alertLine(camera: body, title: title, happened: happened, shown: shownAt,
                                                  picture: c.attachments.isEmpty ? "none" : how, cut: cut)
            defer { Diagnostics.shared.noteAlert(line, at: shownAt) }
            // Its picture came only after it went: put in its place, quietly. (Not when the Mac's push has come
            // meanwhile: that alert has the Mac's own picture.)
            guard got == nil, let late = await fetching.value else { return }
            let lateLook = await CameraEventMedia.stillAndFocus(late.file, title: title)
            if let jpeg = lateLook.still {
                PhoneWidgetShare.saveCamera(id: camera, name: body, doorbell: doorbell, jpeg: jpeg)
                PhoneWidgetShare.reloadWidgets(showing: camera)
            }
            guard !CameraEventMedia.pushArrived(short) else { return }
            let lateCut = await attach(late.file, lateLook)
            c.sound = nil
            c.interruptionLevel = .passive
            let lateHow = late.fromMac ? "the Mac’s picture" : late.file.pathExtension == "mp4" ? "Google’s clip" : "Google’s snapshot"
            PushRelay.log.notice("alert for \(body, privacy: .public) given its picture after it was shown: \(lateHow, privacy: .public)")
            Notifier.deliver(c, id: id)
            let after = happened.map { String(format: " %.1f s after it happened", Date().timeIntervalSince($0)) } ?? ""
            line += "; its picture\(after): \(lateHow), \(lateCut ? "close on its subject" : "whole")"
        }
        #elseif os(macOS)
        // One alert per event, with its picture: the best there is within two seconds (Google's picture of the event
        // on a camera Google has given one for, `EventPicture.googleGives`; else the moment it happened, from the
        // camera's live stream; else a frame of the stream now; else its latest picture). Then it goes, here and to
        // every iPhone, the picture inside the push and kept full size here for the iPhones to fetch. A better picture
        // that comes after it (the moment, once it's picked; Google's; the stream started for it) takes its place
        // quietly, under the same id: here, on the iPhones and on the Apple TVs. (The alert waited for the best picture
        // before it went: up to seven seconds, and twenty when there was none at all.)
        let received = Date(), happened = eventHappened
        // When it happened, for each iPhone's line in the family's log (how long after it the alert was shown there).
        if let happened { c.userInfo["h"] = String(format: "%.1f", happened.timeIntervalSince1970) }
        // The Mac's TVs & Cameras widget: the camera's red tag at once, its picture of the moment when there is one.
        let macCam = NestCameras.shared.cameras.first { $0.id == camera }
        let macTag = title.localizedCaseInsensitiveContains("person") ? "Person"
            : title.localizedCaseInsensitiveContains("motion") ? "Motion" : title.localizedCaseInsensitiveContains("ring") || title.localizedCaseInsensitiveContains("door") ? "Ring" : "Event"
        if !quiet, MacCameraShare.save(id: camera, name: macCam?.name ?? body, doorbell: macCam?.doorbell ?? false, event: macTag) {
            WidgetCenter.shared.reloadTimelines(ofKind: MacCameraShare.kind); WidgetCenter.shared.reloadTimelines(ofKind: "com.woodruff.family.widget.tvs")
        }
        // Apple's object detector, where this Mac has it, ready before the picture is picked: it finds the person
        // in the stream's frames when Vision's own finder doesn't.
        if VehicleWatch.watchesHere { VehicleDetector.shared.prepare() }
        let race = EventPicture(camera: camera, event: event, clip: clip, key: short, happened: happened, title: title)
        if let session { racing[session] = race }
        race.start(given: picture)
        let googleWait: Double = EventPicture.googleGives(camera) ? Self.pictureWait : 0
        return Task { [weak self] in
            /// The alert with [got] as its picture, shown here and sent on: what its picture is, and whether it's cut
            /// close on who or what was seen. [again]: the same alert with a better picture than it went out with,
            /// quietly (no sound, no second banner, no second Live Activity); nil when that picture couldn't be read,
            /// and nothing changed. [toTVs]: its picture goes to the Google TVs and the LG too (once per alert: the
            /// first time it has one). On the main actor, as all it touches is (a function made inside the task isn't,
            /// by itself).
            @MainActor func show(_ got: (file: URL, source: EventPicture.Source)?, again: Bool, toTVs: Bool) async -> (picture: String, cut: Bool)? {
                if again {
                    c.sound = nil
                    c.interruptionLevel = .passive
                    c.userInfo["ring"] = nil
                }
                var thumb: String?
                var still: Data?
                // Where who or what was seen is in the picture (Vision): the small picture in the push is cropped to it,
                // and the alerts' small picture shows it (motion: the whole picture).
                var focus: CGRect?
                var shown: URL?
                var made: (file: URL, focus: CGRect?, image: CGImage, still: Data?, clipTime: Double?)?
                // Where who or what was seen is, so the small picture zooms in there as Google Home's does. A frame
                // picked from the stream says itself: where the person is in it, or where it differs from the scene.
                // Any other picture: where the camera's picture changed around the event (the stream's last few seconds,
                // on the Mac that keeps them), and Apple's object detector where this Mac has it.
                let picked = got?.source == .moment ? race.momentPick : nil
                let moved = picked?.moved ?? StreamMoment.moved(camera: camera, happened: happened ?? received)
                if let got {
                    made = await CameraEventMedia.keepEventPicture(got.file, key: short, title: title, moved: moved,
                                                                   subject: picked?.subject ?? (got.source == .given ? subject : nil))
                }
                // What came couldn't be read (a clip cut short): the camera's latest picture instead. (An update keeps
                // the picture it has.)
                if again, made == nil { return nil }
                // What the picture is, for the alert's line in the family's log.
                var what = got.map { race.text($0.source) } ?? "none"
                if made == nil, let jpeg = CameraStreams.shared.latestStill(camera), let u = CameraEventMedia.jpegFile(jpeg, name: "frame-kept-\(short)") {
                    made = await CameraEventMedia.keepEventPicture(u, key: short, title: title, moved: moved)
                    if made != nil { PushRelay.log.notice("picture for \(body, privacy: .public): \(got == nil ? "none came" : "it couldn’t be read", privacy: .public), the camera’s latest picture instead") }
                    what = EventPicture.Source.kept.text
                }
                if made == nil { what = "none" }
                if let made {
                    focus = made.focus; still = made.still; shown = made.file
                    // A clip that came meanwhile goes in the push too.
                    if let later = race.clip, !later.isEmpty { c.userInfo["clip"] = later }
                    if let focus { c.userInfo["f"] = CameraEventMedia.focusText(focus) } else { c.userInfo["f"] = nil }
                    // The picture is a frame of Google's clip: how far in, so an iPhone that attaches the clip itself
                    // (away from home, where this Mac's picture can't be fetched) shows that frame, framed the same.
                    if let t = made.clipTime { c.userInfo["t"] = String(format: "%.2f", t) } else { c.userInfo["t"] = nil }
                    let info = c.userInfo.reduce(into: [String: String]()) { out, kv in if let k = kv.key as? String, let v = kv.value as? String { out[k] = v } }
                    let budget = PushRelay.thumbnailBudget(id: id, title: c.title, body: c.body, userInfo: info, sound: c.sound != nil, passive: again)
                    // Many small encodes to find the biggest that fits: off the main thread.
                    let image = made.image, framing = focus
                    thumb = await Task.detached(priority: .userInitiated) { CameraEventMedia.pushThumbnail(image, focus: framing, budget: budget) }.value
                }
                if let still, MacCameraShare.save(id: camera, name: macCam?.name ?? body, doorbell: macCam?.doorbell ?? false, jpeg: still) {
                    WidgetCenter.shared.reloadTimelines(ofKind: MacCameraShare.kind); WidgetCenter.shared.reloadTimelines(ofKind: "com.woodruff.family.widget.tvs")
                }
                // The latest event, for Send Test Camera Alert.
                Saved.save(LastCameraEvent.savedKey, LastCameraEvent(title: title, body: body, camera: camera, key: short, happened: happened,
                                                                     event: event ?? "", clip: race.clip ?? clip ?? "", at: received, thumb: thumb))
                if let thumb { c.userInfo["thumb"] = thumb }
                // The picture close on who or what was seen, cut from the full one: this Mac's own alert shows it, and
                // the iPhones fetch it for theirs (the camera share's GET /close).
                var close: URL?
                if let shown {
                    if let focus { close = await CameraEventMedia.closeUp(shown, focus: focus) }
                    if let a = CameraEventMedia.attachment(close ?? shown) { c.attachments = [a] }
                }
                // In the log: what the picture is, how large, and how large the close-up cut from it (a small one is a
                // fog on the alert, and the log is where that shows).
                let waited = String(format: "%.1f", Date().timeIntervalSince(received))
                let whole = made.map { ", \($0.image.width)x\($0.image.height)" } ?? ""
                let cut = close.flatMap { CameraEventMedia.pixelSize($0) }.map { ", its close-up \($0.width)x\($0.height)" }
                    ?? (focus != nil ? ", on its subject" : "")
                PushRelay.log.notice("picture for \(body, privacy: .public) \(again ? "updated " : "", privacy: .public)after \(waited, privacy: .public) s: \(got.map { race.text($0.source) } ?? "none (no picture from Google, the live stream or before)", privacy: .public)\(whole, privacy: .public)\(cut, privacy: .public)\(thumb.map { ", \($0.count) characters in the push" } ?? ", none in the push", privacy: .public)")
                // The Apple TVs' own alert for it (the hub only; its picture is kept above for them to fetch), and the
                // alert itself, here and on the iPhones.
                if !quiet {
                    CameraShare.shared.noteEvent(key: short, camera: camera, name: body, title: title, focus: focus,
                                                 event: event, clip: race.clip ?? clip, happened: happened)
                }
                Notifier.deliver(c, id: id)
                // The Google TVs' and the LG's card for it: its close-up, else the whole picture (the hub only).
                if toTVs, !quiet, let forTVs = close ?? shown {
                    let kind = CameraEventMedia.alertKind(title)
                    TVCameraPicture.send(camera: camera, name: body, kind: kind == "event" ? "motion" : kind, event: event,
                                         session: eventSession, at: happened ?? received, cropped: close != nil, file: forTVs)
                }
                let result = (picture: what, cut: close != nil)
                guard !quiet else { return result }
                // The camera's page lists its last events: this one's picture is kept for it, and its clip (now, if
                // Google's has come; else when it does, a few seconds after the event or in a later message).
                let when = happened ?? received
                let here = CameraEventMedia.cached(short).flatMap { $0.pathExtension == "mp4" ? $0 : nil }
                await CameraHistory.keep(key: short, camera: camera, title: title, at: when, picture: shown, clip: here)
                guard !again, here == nil else { return result }
                // Its own short film, made here from the pictures of the stream this Mac keeps (Google sends no
                // clip for most of the family's cameras): something to play when the event is opened. The
                // pictures from before it are taken now (only the last twelve seconds are kept), the rest once
                // the seconds after it have come. Google's clip, if one comes, takes its place.
                let start = when.addingTimeInterval(-EventClip.before), end = when.addingTimeInterval(EventClip.after)
                let early = CameraStreams.shared.moments(camera, since: start).filter { $0.at <= end }
                Task {
                    let wait = end.timeIntervalSinceNow + 0.6
                    if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
                    let from = early.last?.at ?? start
                    let late = CameraStreams.shared.moments(camera, since: from).filter { $0.at > from && $0.at <= end }
                    let frames = early + late
                    guard frames.count >= EventClip.fewest, !CameraHistory.hasClip(short) else { return }
                    let file = FileManager.default.temporaryDirectory.appendingPathComponent("eventclip-\(short).mp4")
                    guard let made = await EventClip.write(frames, to: file) else {
                        PushRelay.log.notice("clip for \(body, privacy: .public): none could be made from \(frames.count, privacy: .public) pictures")
                        return
                    }
                    if !CameraHistory.hasClip(short) {
                        await CameraHistory.keep(key: short, camera: camera, title: title, at: when, picture: nil, clip: made)
                        let size = ((try? made.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) / 1024
                        let length = String(format: "%.1f", (frames.last?.at ?? when).timeIntervalSince(frames.first?.at ?? when))
                        PushRelay.log.notice("clip for \(body, privacy: .public): made here from \(frames.count, privacy: .public) pictures, \(length, privacy: .public) s, \(size, privacy: .public) KB")
                    }
                    try? FileManager.default.removeItem(at: made)
                }
                Task {
                    var url = race.clip ?? clip
                    var waited = 0
                    while (url ?? "").isEmpty, waited < 30 {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        waited += 2
                        url = race.clip
                    }
                    guard let url, !url.isEmpty, let token = try? await NestCameras.shared.accessToken() else { return }
                    let file = await CameraEventMedia.fetch(camera: camera, eventID: nil, clipURL: url, key: short,
                                                            until: Date().addingTimeInterval(60), using: token)
                    if let file, file.pathExtension == "mp4" {
                        await CameraHistory.keep(key: short, camera: camera, title: title, at: when, picture: nil, clip: file)
                    }
                }
                return result
            }
            let got = await race.result(googleWait: googleWait, cap: Self.pictureWait, staleCap: Self.pictureWait, last: Self.pictureWait)
            let first = await show(got, again: false, toTVs: true)
            let shownAt = Date()
            // A better picture than the one it went out with, when one comes in the event's first twenty seconds: the
            // alert is updated with it. (Not waited for here: its message is acknowledged once the alert is out.) Then
            // the alert's one line in the family's log, with both.
            Task {
                var line = CameraEventMedia.alertLine(camera: body, title: title, happened: happened, shown: shownAt,
                                                      picture: first?.picture ?? "none", cut: first?.cut ?? false)
                if let better = await race.better(than: got?.source, until: received.addingTimeInterval(20)),
                   let then = await show(better, again: true, toTVs: first?.picture == "none") {
                    let after = happened.map { String(format: " %.1f s after it happened", Date().timeIntervalSince($0)) } ?? ""
                    line += "; a better one\(after): \(then.picture), \(then.cut ? "close on its subject" : "whole")"
                }
                Diagnostics.shared.noteAlert(line, at: shownAt)
                if let session, self?.racing[session] === race { self?.racing[session] = nil }
            }
        }
        #else
        return nil
        #endif
    }

    #if os(iOS)
    /// Whether this event's alert is already on the iPhone (the Mac's push), by its id or its event key.
    static func alreadyShown(id: String, key: String) async -> Bool {
        if NotificationHandler.presentedKeys.contains(key) { return true }
        // The Mac's push for it arrived (its extension noted it): while that's still getting its picture it isn't
        // delivered yet, and once opened or cleared it isn't delivered any more.
        if CameraEventMedia.pushArrived(key) { return true }
        let delivered = await UNUserNotificationCenter.current().deliveredNotifications()
        return delivered.contains { $0.request.identifier == id || ($0.request.content.userInfo["key"] as? String) == key }
    }

    /// [task]'s value if it comes within [seconds], else nil (the task goes on, for whatever waits on it later).
    private static func value<T>(of task: Task<T?, Never>, within seconds: Double) async -> T? {
        await FirstOf<T>(1).run([{ await task.value }], deadline: Date().addingTimeInterval(seconds))
    }

    /// The camera's picture the iPhone's widgets show, if they have one.
    private static func widgetStill(_ camera: String) -> Data? {
        guard let name = PhoneWidgetShare.loadCameras().first(where: { $0.id == camera })?.file,
              let url = PhoneWidgetShare.artURL(name) else { return nil }
        return try? Data(contentsOf: url)
    }
    #endif

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

#if os(macOS)
/// The Mac: the picture for one event's alert, got every way at once the moment the event comes. Google's own picture
/// of the event (its snapshot, asked for at once as it's made only within 30 seconds, or its clip's first frames) is
/// the one Google Home shows, so on a camera Google gives one for it's waited for a few seconds; meanwhile the moment
/// it happened is picked from the last few seconds of the camera's live stream (every camera is kept live on the Mac
/// that sends, `StreamMoment`), a frame of the stream now is ready in case that can't be had, and the camera's latest
/// picture is the last resort.
@MainActor
private final class EventPicture {
    enum Source: Int {
        case given = 0, google, moment, live, grabbed, kept
        var text: String {
            switch self {
            case .given: return "the Mac’s own frame"
            case .google: return "Google’s picture of the event"
            case .moment: return "the moment it happened, from the stream"
            case .live: return "the live stream, at once"
            case .grabbed: return "the live stream, started for it"
            case .kept: return "the camera’s latest picture"
            }
        }
    }

    let camera: String
    let event: String?
    let key: String
    /// When the event happened (Google's time) and its alert's title: which of the stream's last few seconds shows it.
    let happened: Date?
    let title: String
    private(set) var clip: String?
    private(set) var best: (file: URL, source: Source)?
    /// Google's fetches still going.
    private var googleBusy = 0
    private var askedImage = false
    /// The moment it happened is still being looked for in the stream's last few seconds.
    private var findingMoment = false
    /// Why that frame was picked ("person found"), for the log.
    private var momentWhy: String?
    /// The frame picked from the stream, with where its subject is in it.
    private(set) var momentPick: StreamMoment.Pick?

    init(camera: String, event: String?, clip: String?, key: String, happened: Date? = nil, title: String = "") {
        self.camera = camera; self.event = event; self.clip = clip.flatMap { $0.isEmpty ? nil : $0 }; self.key = key
        self.happened = happened; self.title = title
    }

    func start(given: Data?) {
        if let given, let u = write(given, "given") { take(u, .given); return }
        google(clip: clip)
        moment()
        Task { [weak self] in
            guard let self else { return }
            if let jpeg = await CameraStreams.shared.liveFrame(self.camera, maxSide: CameraEventMedia.fullSide), let u = self.write(jpeg, "live") {
                self.take(u, .live)
                return
            }
            // Not live: its stream started for this one picture.
            guard let cam = NestCameras.shared.cameras.first(where: { $0.id == self.camera }), cam.webRTC, cam.online else { return }
            if let jpeg = await CameraStreams.shared.grabFrame(cam, timeout: 15, maxSide: CameraEventMedia.fullSide), let u = self.write(jpeg, "grab") {
                self.take(u, .grabbed)
            }
        }
    }

    /// The moment it happened, from the last few seconds of the camera's stream this Mac keeps: better than a frame of
    /// the stream now, not as good as Google's own picture of the event.
    private func moment() {
        guard let happened else { return }
        findingMoment = true
        let camera = camera, key = key, title = title
        Task { [weak self] in
            let got = await StreamMoment.pick(camera: camera, key: key, happened: happened, title: title)
            guard let self else { return }
            self.findingMoment = false
            if let got {
                self.momentWhy = got.why
                self.momentPick = got
                self.take(got.file, .moment)
            }
        }
    }

    /// What [s] was, for the log ("the moment it happened, from the stream (person found)").
    func text(_ s: Source) -> String {
        guard s == .moment, let why = momentWhy else { return s.text }
        return "\(s.text) (\(why))"
    }

    /// The event's clip came in a later message.
    func offerClip(_ url: String) {
        guard clip == nil else { return }
        clip = url
        google(clip: url)
    }

    private func google(clip: String?) {
        let image = askedImage ? nil : event.flatMap { $0.isEmpty ? nil : $0 }
        guard image != nil || clip != nil else { return }
        if image != nil { askedImage = true }
        googleBusy += 1
        let camera = camera, key = key
        Task { [weak self] in
            let token = try? await NestCameras.shared.accessToken()
            var file: URL?
            if let token {
                file = await CameraEventMedia.fetch(camera: camera, eventID: image, clipURL: clip, key: key,
                                                    until: Date().addingTimeInterval(20), using: token)
            }
            // (Noted even when it comes after the alert has gone, and this is no longer here to take it.)
            if file != nil { EventPicture.noteGoogleGave(camera) }
            guard let self else { return }
            self.googleBusy -= 1
            if let file { self.take(file, .google) }
        }
    }

    // MARK: Whether Google gives this camera's pictures

    private static let gaveKey = "nest.googleGave"
    /// A camera Google hasn't given a picture for in this long isn't waited on for one.
    private static let gaveFor: TimeInterval = 30 * 86400

    /// Whether Google has given an event's picture for [camera] (its snapshot or its clip) in the last month: only
    /// then is an alert held back for Google's. The newer Nest cameras give other apps neither, and every alert of
    /// theirs was held up to four and a half seconds for a picture that never came, though the frame from the
    /// stream was picked within a second.
    static func googleGives(_ camera: String) -> Bool {
        guard let at = (UserDefaults.standard.dictionary(forKey: gaveKey) as? [String: Double])?[camera] else { return false }
        return Date().timeIntervalSince1970 - at < gaveFor
    }

    /// Google gave a picture of one of [camera]'s events: its alerts wait for Google's from now on.
    private static func noteGoogleGave(_ camera: String) {
        var all = UserDefaults.standard.dictionary(forKey: gaveKey) as? [String: Double] ?? [:]
        if !googleGives(camera) {
            let name = NestCameras.shared.cameras.first { $0.id == camera }?.name ?? "a camera"
            PushRelay.log.notice("Google gave a picture for \(name, privacy: .public): its alerts wait for Google’s from now on")
        }
        all[camera] = Date().timeIntervalSince1970
        UserDefaults.standard.set(all, forKey: gaveKey)
    }

    private func take(_ u: URL, _ s: Source) {
        if best == nil || s.rawValue < best!.source.rawValue { best = (u, s) }
    }

    private func write(_ d: Data, _ tag: String) -> URL? {
        CameraEventMedia.jpegFile(d, name: "frame-\(tag)-\(key)")
    }

    /// How recent the camera's latest picture must be to stand for the moment (its stream dropped only just now).
    static let freshStill: TimeInterval = 30

    /// The picture to alert with: Google's as soon as it's there; else, once [googleWait] seconds are up (or Google
    /// has nothing; none at all on a camera Google gives no pictures for), the moment it happened from the stream
    /// (waited for until [cap] at most), else the stream's frame;
    /// with nothing at all by [cap], the camera's latest picture if it's from the last half minute, and by [staleCap]
    /// whatever its age (an older one shows an earlier moment, while the stream started for this, or Google's clip a few
    /// seconds behind the event, can still bring this one); nil only when there's still nothing after [last] seconds.
    func result(googleWait: Double, cap: Double, staleCap: Double, last: Double) async -> (file: URL, source: Source)? {
        let t0 = Date()
        while true {
            let waited = Date().timeIntervalSince(t0)
            if let b = best {
                // The moment it happened is still being picked: a frame of the stream now waits for it.
                let picking = findingMoment && b.source.rawValue > Source.moment.rawValue && waited < cap
                if b.source.rawValue <= Source.google.rawValue || ((googleBusy == 0 || waited >= googleWait) && !picking) { return b }
            } else if waited >= cap {
                let age = CameraStreams.shared.stillAt[camera].map { Date().timeIntervalSince($0) } ?? .infinity
                if age < Self.freshStill || waited >= staleCap, let jpeg = CameraStreams.shared.latestStill(camera),
                   let u = write(jpeg, "kept") {
                    return (u, .kept)
                }
            }
            if waited >= last { return best }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// A better picture than [sent] (the one the alert went out with; nil: none), as soon as one has come; nil when
    /// none has by [deadline], or none can (Google's own picture, or the Mac's own frame, is the best there is).
    func better(than sent: Source?, until deadline: Date) async -> (file: URL, source: Source)? {
        let bar = sent?.rawValue ?? Int.max
        guard bar > Source.google.rawValue else { return nil }
        while Date() < deadline {
            if let b = best, b.source.rawValue < bar { return b }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return nil
    }
}
#endif

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
            #if os(iOS) || os(tvOS)
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
