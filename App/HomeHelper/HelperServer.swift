import Foundation
import Network
import CryptoKit
import WoodruffKit

/// The helper's private connection (127.0.0.1 only, with a secret): Woodruff on this Mac asks it what's in Apple
/// Home and sends it changes. A plain, tiny HTTP server: GET /state, POST /device, POST /light, POST /refresh.
@Observable @MainActor
final class HelperServer {
    static let shared = HelperServer()

    /// The port it listens on (nil while starting).
    private(set) var port: UInt16?
    /// When Woodruff last asked (shown in the helper's window).
    private(set) var lastAsked: Date?

    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private let token = UUID().uuidString + "-" + UUID().uuidString

    func start() {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback   // only this Mac can connect
        guard let l = try? NWListener(using: params) else { retrySoon(); return }
        l.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch state {
                case .ready:
                    if let p = l.port?.rawValue {
                        self.port = p
                        self.writeInfo(p)
                    }
                case .failed, .cancelled:
                    if self.listener === l {
                        self.listener = nil
                        self.port = nil
                        self.retrySoon()
                    }
                default:
                    break
                }
            }
        }
        l.newConnectionHandler = { [weak self] c in
            MainActor.assumeIsolated {
                guard let self else { c.cancel(); return }
                c.start(queue: .main)
                self.read(c, Data())
            }
        }
        listener = l
        l.start(queue: .main)
    }

    private func retrySoon() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            self.start()
        }
    }

    /// Where Woodruff finds this helper: the port and the secret, readable only by this Mac user.
    private func writeInfo(_ port: UInt16) {
        let info = HomeBridge.Info(port: port, token: token, pid: ProcessInfo.processInfo.processIdentifier)
        let url = HomeBridge.infoURL
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        guard let data = try? JSONEncoder().encode(info) else { return }
        try? data.write(to: url, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    // MARK: Requests

    private func read(_ c: NWConnection, _ buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, error in
            MainActor.assumeIsolated {
                guard let self else { c.cancel(); return }
                var buf = buffer
                if let data { buf.append(data) }
                if let request = Request(buf) {
                    self.respond(c, request)
                } else if done || error != nil || buf.count > 1 << 20 {
                    c.cancel()
                } else {
                    self.read(c, buf)
                }
            }
        }
    }

    private func respond(_ c: NWConnection, _ r: Request) {
        guard r.headers[HomeBridge.tokenHeader.lowercased()] == token else {
            return reply(c, 403, message: "Not allowed.")
        }
        lastAsked = Date()
        switch (r.method, r.path) {
        case ("GET", "/state"):
            let (state, body) = currentState()
            if r.query["have"] == state.hash { reply(c, 204, body: nil) } else { reply(c, 200, body: body) }
        case ("POST", "/device"):
            guard let q = try? JSONDecoder().decode(HomeBridge.DeviceRequest.self, from: r.body) else {
                return reply(c, 400, message: "That request couldn't be read.")
            }
            guard let d = AccessoryStore.shared.fromHome.first(where: { $0.id == q.id }),
                  let control = AccessoryStore.shared.homeControl else {
                return reply(c, 404, message: "That isn't in Apple Home any more.")
            }
            control(d, q.command)
            reply(c, 200, message: "OK")
        case ("POST", "/light"):
            guard let q = try? JSONDecoder().decode(HomeBridge.LightRequest.self, from: r.body) else {
                return reply(c, 400, message: "That request couldn't be read.")
            }
            guard let l = SmartHome.shared.lights.first(where: { $0.id == q.id }),
                  let control = SmartHome.shared.homeControl else {
                return reply(c, 404, message: "That light isn't in Apple Home any more.")
            }
            control(l, q.command.command)
            reply(c, 200, message: "OK")
        case ("POST", "/refresh"):
            HomeKitLights.shared.refresh()
            reply(c, 200, message: "OK")
        default:
            reply(c, 404, message: "Unknown request.")
        }
    }

    /// Everything in Apple Home now, and the same as JSON (its hash tells Woodruff whether anything changed).
    private func currentState() -> (HomeBridge.State, Data?) {
        var s = HomeBridge.State(hash: "", devices: AccessoryStore.shared.fromHome,
                                 lights: SmartHome.shared.lights.filter { $0.isHome },
                                 problem: AccessoryStore.shared.homeProblem)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let content = try? encoder.encode(s) {
            s.hash = SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined()
        }
        return (s, try? encoder.encode(s))
    }

    private func reply(_ c: NWConnection, _ code: Int, message: String) {
        let body = try? JSONSerialization.data(withJSONObject: ["message": message])
        reply(c, code, body: body)
    }

    private func reply(_ c: NWConnection, _ code: Int, body: Data?) {
        let reasons = [200: "OK", 204: "No Content", 400: "Bad Request", 403: "Forbidden", 404: "Not Found"]
        var head = "HTTP/1.1 \(code) \(reasons[code] ?? "Error")\r\nConnection: close\r\n"
        if let body {
            head += "Content-Type: application/json\r\nContent-Length: \(body.count)\r\n\r\n"
        } else {
            head += "Content-Length: 0\r\n\r\n"
        }
        var out = Data(head.utf8)
        if let body { out.append(body) }
        c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
    }
}

/// One HTTP request, once all of it has arrived (nil until then).
private struct Request {
    var method: String
    var path: String
    var query: [String: String]
    var headers: [String: String]
    var body: Data

    init?(_ data: Data) {
        let bytes = [UInt8](data)
        let separator: [UInt8] = [13, 10, 13, 10]
        guard bytes.count >= 4 else { return nil }
        var headEnd: Int?
        var i = 0
        while i + 4 <= bytes.count {
            if Array(bytes[i..<(i + 4)]) == separator { headEnd = i; break }
            i += 1
        }
        guard let end = headEnd, let head = String(bytes: bytes[0..<end], encoding: .utf8) else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let first = lines.removeFirst().split(separator: " ")
        guard first.count >= 2 else { return nil }
        method = String(first[0]).uppercased()
        let target = String(first[1])
        let comps = URLComponents(string: "http://localhost" + target)
        path = comps?.path ?? target
        var q: [String: String] = [:]
        for item in comps?.queryItems ?? [] { q[item.name] = item.value ?? "" }
        query = q
        var h: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            h[name] = value
        }
        headers = h
        let length = Int(h["content-length"] ?? "0") ?? 0
        let bodyStart = end + 4
        guard length >= 0, bytes.count - bodyStart >= length else { return nil }
        body = Data(bytes[bodyStart..<(bodyStart + length)])
    }
}
