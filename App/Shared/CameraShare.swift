import Foundation
import Network
import WoodruffKit

/// The Apple TV's cameras: an Apple TV can't play Google's live stream itself (no WebRTC there), but the Mac Studio
/// keeps every camera live. So the Mac Studio hands each camera's current picture to the family's Apple TVs, about
/// once a second, on its home address and its Tailscale address (so an Apple TV away from home with Tailscale sees
/// them too). Only someone holding the family code can ask: each request carries a key made from it.
enum CameraShareKey {
    /// The Mac Studio's addresses, kept with the family's settings so the Apple TVs know where to ask.
    static let hostsKey = "cameraShare.hosts"
    static let port = UInt16(CameraEventMedia.sharePort)

    /// The key a request carries, made from the family code (never the code itself).
    static func token() -> String? {
        guard let code = FamilyCode.load().record?.code else { return nil }
        let k = FamilyCode.derive(FamilyCode.key(code), "woodruff-camera-share")
        return k.withUnsafeBytes { Data($0) }.prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}

/// A camera alert the Mac Studio sent, as it hands it to the Apple TVs (GET /events): the Apple TV shows its own small
/// alert for it. [at] is when the Mac sent it, in milliseconds by the Mac's clock (the Apple TV asks for those after
/// the last one it saw).
struct CameraShareEvent: Codable, Equatable {
    /// The event's short id (its picture is GET /event?id=).
    var key: String
    var camera: String
    var name: String
    var title: String
    /// person, door, motion, vehicle or event.
    var kind: String
    var at: Int64
    /// Where who or what was seen is in the picture ("x,y,w,h", unit rectangle from the top left).
    var focus: String?
    /// Google's event id and clip, for the replay when the camera is opened.
    var event: String?
    var clip: String?
}

/// GET /events: the Mac's clock now and the alerts after `since`.
struct CameraShareFeed: Codable {
    var now: Int64
    var events: [CameraShareEvent]
}

#if os(macOS)
@MainActor
final class CameraShare {
    static let shared = CameraShare()
    private var listener: NWListener?
    /// Each camera's latest picture and when it was taken (taken again at most once a second, only while asked for).
    private var latest: [String: (jpeg: Data, at: Date)] = [:]
    private var token: String?
    /// When an Apple TV last asked for each camera: its stream is kept live, and its picture fresh, for a while after.
    private var askedAt: [String: Date] = [:]
    /// The cameras whose streams this Mac keeps live for the Apple TVs (started for them).
    private var keptForTV: Set<String> = []
    /// Takes the asked-for cameras' pictures again as they go stale (while any is asked for).
    private var refresher: Task<Void, Never>?
    /// The picture streams open now (GET /mjpeg): which camera, and how many pictures a second.
    private var streamFPS: [ObjectIdentifier: (id: String, fps: Double)] = [:]
    /// A picture being taken of each camera now: every Apple TV asking meanwhile gets the same one.
    private var taking: [String: Task<Data?, Never>] = [:]
    /// The last alerts this Mac sent, newest last, for the Apple TVs' own alerts (GET /events).
    private var recent: [CameraShareEvent] = []

    /// An alert went out (its picture already kept for GET /event): the Apple TVs show it on their next ask. Only on
    /// the Mac that shares the cameras (the hub).
    func noteEvent(key: String, camera: String, name: String, title: String, focus: CGRect?, event: String?, clip: String?) {
        guard listener != nil else { return }
        let t = title.lowercased()
        let kind = t.contains("door") || t.contains("ring") ? "door" : t.contains("person") ? "person"
            : t.contains("motion") ? "motion" : t.contains("vehicle") ? "vehicle" : "event"
        // Always after the last one, so an Apple TV asking for newer ones never misses one sent the same millisecond.
        let at = max(Int64(Date().timeIntervalSince1970 * 1000), (recent.last?.at ?? 0) + 1)
        recent.append(CameraShareEvent(key: key, camera: camera, name: name, title: title, kind: kind, at: at,
                                       focus: focus.map { CameraEventMedia.focusText($0) },
                                       event: event.flatMap { $0.isEmpty ? nil : $0 }, clip: clip.flatMap { $0.isEmpty ? nil : $0 }))
        if recent.count > 20 { recent.removeFirst(recent.count - 20) }
    }

    /// On the Mac Studio (the updater's hub) only: it's the Mac that's always home with every camera live.
    func start() {
        guard listener == nil, !Demo.isOn, PushRelay.updaterRole() == "hub",
              let port = NWEndpoint.Port(rawValue: CameraShareKey.port),
              let l = try? NWListener(using: .tcp, on: port) else { return }
        l.newConnectionHandler = { [weak self] c in
            c.start(queue: .main)
            // An Apple TV that went away mid-request: never left open.
            // (A picture stream, GET /mjpeg, stays open: it ends itself.)
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
                Task { @MainActor in if !CameraShare.shared.isStreaming(c) { c.cancel() } }
            }
            Task { @MainActor in self?.read(c, Data()) }
        }
        l.start(queue: .main)
        listener = l
        publish()
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 600_000_000_000)
                publish()
            }
        }
    }

    /// The addresses the Apple TVs try: this Mac's home network address and its Tailscale one.
    private func publish() {
        token = CameraShareKey.token()
        let hosts = Self.addresses().joined(separator: ",")
        guard !hosts.isEmpty, UserDefaults.standard.string(forKey: CameraShareKey.hostsKey) != hosts else { return }
        UserDefaults.standard.set(hosts, forKey: CameraShareKey.hostsKey)
        Task { await SettingsSync.shared.syncNow() }
    }

    private static func addresses() -> [String] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var home: [String] = [], tail: [String] = []
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let sa = p.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            if ip.hasPrefix("100.") { tail.append(ip) }
            else if ip.hasPrefix("192.168.") || ip.hasPrefix("10.") || ip.hasPrefix("172.") { home.append(ip) }
        }
        return Array(Set(home)).sorted() + Array(Set(tail)).sorted()
    }

    private func read(_ c: NWConnection, _ got: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, done, error in
            Task { @MainActor in
                guard let self else { return }
                var all = got
                if let data { all.append(data) }
                if all.range(of: Data("\r\n\r\n".utf8)) != nil, CameraShare.isStream(all) {
                    self.stream(String(decoding: all, as: UTF8.self), c)
                } else if all.range(of: Data("\r\n\r\n".utf8)) != nil {
                    await self.answer(String(decoding: all, as: UTF8.self), c)
                } else if done || error != nil || all.count > 8192 {
                    c.cancel()
                } else {
                    self.read(c, all)
                }
            }
        }
    }

    /// GET /still?id=<camera>&k=<key>: the camera's current picture as a JPEG.
    /// GET /event?id=<event's short id>&k=<key>: the picture this Mac alerted with for that event (full size, for the
    /// iPhones' alerts: their push carries only a small one).
    private func answer(_ request: String, _ c: NWConnection) async {
        let line = request.components(separatedBy: "\r\n").first ?? ""
        let parts = line.split(separator: " ")
        guard parts.count >= 2, let url = URLComponents(string: "http://x" + parts[1]),
              ["/still", "/event", "/events", "/diag"].contains(url.path) else {
            return reply(c, "404 Not Found", nil)
        }
        let q = Dictionary((url.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        if token == nil { token = CameraShareKey.token() }
        guard let token, q["k"] == token else { return reply(c, "403 Forbidden", nil) }
        // GET /diag?n=<device>&b=<build>&t=<kind>&d=<detail>&k=<key>: a line of an Apple TV's own diagnostics (how a
        // film played, a freeze), kept in this Mac's appletv.log.
        if url.path == "/diag" {
            Diagnostics.shared.noteRemote(device: q["n"] ?? "Apple TV", build: q["b"] ?? "", kind: q["t"] ?? "", detail: q["d"] ?? "")
            return reply(c, "204 No Content", nil)
        }
        // GET /events?since=<ms>&k=<key>: the alerts sent after `since` (the Apple TVs' own alerts).
        if url.path == "/events" {
            let since = Int64(q["since"] ?? "") ?? 0
            let feed = CameraShareFeed(now: Int64(Date().timeIntervalSince1970 * 1000), events: recent.filter { $0.at > since })
            return reply(c, "200 OK", (try? JSONEncoder().encode(feed)) ?? Data("{}".utf8), type: "application/json")
        }
        guard let id = q["id"], !id.isEmpty else { return reply(c, "403 Forbidden", nil) }
        if url.path == "/event" {
            guard id.count <= 32, id.allSatisfy(\.isHexDigit) else { return reply(c, "403 Forbidden", nil) }
            if let jpeg = CameraEventMedia.eventImage(id) { return reply(c, "200 OK", jpeg) }
            return reply(c, "404 Not Found", nil)
        }
        watched(id)
        if let kept = latest[id], Date().timeIntervalSince(kept.at) < 0.9 { return reply(c, "200 OK", kept.jpeg) }
        if let jpeg = await frame(id) { return reply(c, "200 OK", jpeg) }
        // Not live yet (its stream is starting now): the latest picture kept, at once, with its age.
        if let kept = latest[id] { return replyFrame(c, kept.jpeg, age: Date().timeIntervalSince(kept.at)) }
        reply(c, "503 Service Unavailable", nil)
    }

    /// The camera's picture now, taken once however many ask at the same moment.
    private func frame(_ id: String) async -> Data? {
        if let t = taking[id] { return await t.value }
        let t = Task { await CameraStreams.shared.liveFrame(id, maxSide: 1280) }
        taking[id] = t
        let jpeg = await t.value
        taking[id] = nil
        if let jpeg { latest[id] = (jpeg, Date()) }
        // Not live: the last live picture this Mac kept of it (on disk), dated when it was taken, until a new one.
        if jpeg == nil, latest[id] == nil, let kept = CameraStreams.shared.latestStill(id) {
            latest[id] = (kept, CameraStreams.shared.stillAt[id] ?? .distantPast)
        }
        return jpeg
    }

    private func reply(_ c: NWConnection, _ status: String, _ jpeg: Data?, type: String = "image/jpeg") {
        var out = Data("HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(jpeg?.count ?? 0)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8)
        if let jpeg { out.append(jpeg) }
        c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
    }
}

// MARK: Keeping the Apple TVs' cameras fresh

extension CameraShare {
    /// How long a camera an Apple TV asked for stays live after its last ask.
    static let warmFor: TimeInterval = 300

    /// An Apple TV asked for [id]: its stream is kept live (started now if it isn't), and its picture taken again as
    /// it goes stale, so the next ask is answered at once from what's kept.
    func watched(_ id: String) {
        askedAt[id] = Date()
        keepLive(id)
        if refresher == nil { refresher = Task { [weak self] in await self?.refresh() } }
    }

    func isStreaming(_ c: NWConnection) -> Bool { streamFPS[ObjectIdentifier(c)] != nil }

    private func keepLive(_ id: String) {
        guard !CameraStreams.shared.pinned.contains(id),
              let cam = NestCameras.shared.cameras.first(where: { $0.id == id }), cam.webRTC, cam.online else { return }
        CameraStreams.shared.keepPlaying(cam)
        keptForTV.insert(id)
    }

    /// Ten times a second while any camera is asked for: each one's picture is taken again when it's older than its
    /// fastest stream wants (once a second for one asked for in the last few seconds, every five otherwise). One no
    /// Apple TV has asked for in five minutes is let go.
    private func refresh() async {
        var tick = 0
        while !Task.isCancelled {
            let now = Date()
            for (id, at) in askedAt {
                let fps = streamFPS.values.filter { $0.id == id }.map { $0.fps }.max()
                if fps == nil, now.timeIntervalSince(at) > Self.warmFor {
                    askedAt[id] = nil
                    letGo(id)
                    continue
                }
                let every = fps.map { 1 / $0 } ?? (now.timeIntervalSince(at) < 10 ? 1 : 5)
                let age = latest[id].map { now.timeIntervalSince($0.at) } ?? .infinity
                if age >= every * 0.9, taking[id] == nil { Task { _ = await self.frame(id) } }
            }
            // Every two seconds: a stream that stopped starts again, and its picture goes back off screen after the
            // camera was open on this Mac.
            tick += 1
            if tick % 20 == 0 { for id in keptForTV { keepLive(id) } }
            if askedAt.isEmpty { refresher = nil; return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func letGo(_ id: String) {
        guard keptForTV.remove(id) != nil else { return }
        // Kept live for something else too (Vehicle Alerts, or every camera kept ready on this Mac).
        if VehicleWatch.shared.watched.contains(id) || CameraStreams.shared.warmed.contains(id) { return }
        CameraStreams.shared.stopKeeping(id)
    }

    static func isStream(_ request: Data) -> Bool { request.starts(with: Data("GET /mjpeg?".utf8)) }

    /// GET /mjpeg?id=<camera>&k=<key>&fps=<1–10>: the camera's pictures as they're taken, pushed down one connection
    /// (multipart/x-mixed-replace JPEGs, each with its age in X-Frame-Age): at most [fps] a second, and the latest
    /// again every three seconds when nothing new comes. It ends after ten minutes (the Apple TV asks again).
    func stream(_ request: String, _ c: NWConnection) {
        let line = request.components(separatedBy: "\r\n").first ?? ""
        let parts = line.split(separator: " ")
        guard parts.count >= 2, let url = URLComponents(string: "http://x" + parts[1]) else { return reply(c, "404 Not Found", nil) }
        let q = Dictionary((url.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        if token == nil { token = CameraShareKey.token() }
        guard let token, q["k"] == token, let id = q["id"], !id.isEmpty else { return reply(c, "403 Forbidden", nil) }
        let fps = min(10, max(0.5, Double(q["fps"] ?? "") ?? 1))
        let key = ObjectIdentifier(c)
        streamFPS[key] = (id, fps)
        watched(id)
        c.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled: Task { @MainActor in CameraShare.shared.streamFPS[key] = nil }
            default: break
            }
        }
        let head = "HTTP/1.1 200 OK\r\nContent-Type: multipart/x-mixed-replace; boundary=frame\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        c.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
        // Never longer than its ten minutes, even to an Apple TV that went away without a word (a send waiting on it
        // ends with the connection).
        DispatchQueue.main.asyncAfter(deadline: .now() + 610) { c.cancel() }
        Task { await self.pump(c, key, id, fps) }
    }

    private func pump(_ c: NWConnection, _ key: ObjectIdentifier, _ id: String, _ fps: Double) async {
        let began = Date()
        var sentAt: Date?
        var lastSend = Date.distantPast
        var lastAsk = Date()
        while streamFPS[key] != nil, Date().timeIntervalSince(began) < 600 {
            let now = Date()
            if now.timeIntervalSince(lastAsk) >= 1 { lastAsk = now; watched(id) }
            if let f = latest[id], now.timeIntervalSince(lastSend) >= 0.9 / fps,
               f.at != sentAt || now.timeIntervalSince(lastSend) >= 3 {
                let age = min(999_999, max(0, now.timeIntervalSince(f.at)))
                var part = Data("--frame\r\nContent-Type: image/jpeg\r\nContent-Length: \(f.jpeg.count)\r\nX-Frame-Age: \(String(format: "%.1f", age))\r\n\r\n".utf8)
                part.append(f.jpeg)
                part.append(Data("\r\n".utf8))
                guard await send(c, part) else { break }
                sentAt = f.at
                lastSend = Date()
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        streamFPS[key] = nil
        c.cancel()
    }

    /// Sent (handed to the network, so a slow Apple TV is never sent more than it takes); false once it's gone.
    private func send(_ c: NWConnection, _ data: Data) async -> Bool {
        await withCheckedContinuation { (k: CheckedContinuation<Bool, Never>) in
            c.send(content: data, completion: .contentProcessed { e in k.resume(returning: e == nil) })
        }
    }

    /// A picture that isn't current (the camera's stream is starting), with how many seconds old it is.
    private func replyFrame(_ c: NWConnection, _ jpeg: Data, age: Double) {
        let a = String(format: "%.1f", min(999_999, max(0, age)))
        var out = Data("HTTP/1.1 200 OK\r\nContent-Type: image/jpeg\r\nContent-Length: \(jpeg.count)\r\nX-Frame-Age: \(a)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8)
        out.append(jpeg)
        c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
    }
}
#endif
