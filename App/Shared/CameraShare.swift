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
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { c.cancel() }
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
                if all.range(of: Data("\r\n\r\n".utf8)) != nil {
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
              ["/still", "/event", "/events"].contains(url.path) else {
            return reply(c, "404 Not Found", nil)
        }
        let q = Dictionary((url.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        if token == nil { token = CameraShareKey.token() }
        guard let token, q["k"] == token else { return reply(c, "403 Forbidden", nil) }
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
        if let kept = latest[id], Date().timeIntervalSince(kept.at) < 0.9 { return reply(c, "200 OK", kept.jpeg) }
        if let jpeg = await frame(id) { return reply(c, "200 OK", jpeg) }
        if let kept = latest[id] { return reply(c, "200 OK", kept.jpeg) }
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
        return jpeg
    }

    private func reply(_ c: NWConnection, _ status: String, _ jpeg: Data?, type: String = "image/jpeg") {
        var out = Data("HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(jpeg?.count ?? 0)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8)
        if let jpeg { out.append(jpeg) }
        c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
    }
}
#endif
