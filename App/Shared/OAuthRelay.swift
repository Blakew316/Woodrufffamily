import Foundation
import Network
import AuthenticationServices
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Signs in to a service (Google for the cameras, Samsung SmartThings) in Apple's sign-in browser, the same
/// way the TVs do: the service sends you back to the family's small relay page, which passes the one-time
/// code over the Wi‑Fi to this device. Here a tiny listener on this device takes it, so no server is involved.
@MainActor
final class OAuthRelay: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let redirect = "https://blakew316.github.io/woodrufffiles/oauth.html"

    enum Failure: LocalizedError {
        case noWiFi, cancelled, refused(String)
        var errorDescription: String? {
            switch self {
            case .noWiFi: return "Connect to your home Wi‑Fi first."
            case .cancelled: return "Sign-in was cancelled."
            case .refused(let m): return m
            }
        }
    }

    private var listener: NWListener?
    private var session: ASWebAuthenticationSession?
    private var continuation: CheckedContinuation<String, Error>?
    private var nonce = ""

    /// Opens the sign-in page [authorize] (given the state to pass along) and returns the code it hands back.
    func signIn(authorize: (String) -> URL) async throws -> String {
        guard let ip = LocalAddress.current() else { throw Failure.noWiFi }
        let port = try await startListener()
        nonce = UUID().uuidString
        let payload = ["r": "http://\(ip):\(port)", "n": nonce]
        let state = (try? JSONSerialization.data(withJSONObject: payload))?.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") ?? ""
        defer { listener?.cancel(); listener = nil; session = nil }
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<String, Error>) in
            continuation = c
            let s = ASWebAuthenticationSession(url: authorize(state), callbackURLScheme: "woodruff") { [weak self] _, error in
                Task { @MainActor in
                    if let error, (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin { self?.finish(.failure(Failure.cancelled)) }
                    else if let error { self?.finish(.failure(error)) }
                }
            }
            s.presentationContextProvider = self
            s.prefersEphemeralWebBrowserSession = false
            session = s
            if !s.start() { finish(.failure(Failure.refused("Couldn’t open the sign-in page."))) }
        }
    }

    private func finish(_ r: Result<String, Error>) {
        guard let c = continuation else { return }
        continuation = nil
        c.resume(with: r)
    }

    private func startListener() async throws -> UInt16 {
        let l = try NWListener(using: .tcp, on: .any)
        listener = l
        l.newConnectionHandler = { [weak self] conn in
            conn.start(queue: .main)
            conn.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, _ in
                let text = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
                let line = text.split(separator: "\r\n").first.map(String.init) ?? ""
                let parts = line.split(separator: " ")
                var code: String?, error: String?, state: String?
                if parts.count >= 2, let u = URLComponents(string: "http://x" + parts[1]) {
                    code = u.queryItems?.first { $0.name == "code" }?.value
                    error = u.queryItems?.first { $0.name == "error" }?.value
                    state = u.queryItems?.first { $0.name == "state" }?.value
                }
                // Send the browser back to the app, which closes it.
                let reply = "HTTP/1.1 302 Found\r\nLocation: woodruff://signed-in\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                conn.send(content: Data(reply.utf8), completion: .contentProcessed { _ in conn.cancel() })
                Task { @MainActor in
                    guard let self else { return }
                    if let state, !self.stateMatches(state) { return }
                    if let code { self.finish(.success(code)); self.session?.cancel() }
                    else if let error { self.finish(.failure(Failure.refused("Sign-in was refused (\(error))."))); self.session?.cancel() }
                }
            }
        }
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<UInt16, Error>) in
            var done = false
            l.stateUpdateHandler = { s in
                guard !done else { return }
                switch s {
                case .ready: done = true; c.resume(returning: l.port?.rawValue ?? 0)
                case .failed(let e): done = true; c.resume(throwing: e)
                default: break
                }
            }
            l.start(queue: .main)
        }
    }

    private func stateMatches(_ s: String) -> Bool {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        guard let d = Data(base64Encoded: b), let o = try? JSONSerialization.jsonObject(with: d) as? [String: String] else { return false }
        return o["n"] == nonce
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            #if os(iOS)
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            return scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
            #else
            return NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
            #endif
        }
    }
}

/// This device's address on the home network.
enum LocalAddress {
    static func current() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var best: String?
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let i = p.pointee
            guard let addr = i.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: i.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            let private_ = ip.hasPrefix("192.168.") || ip.hasPrefix("10.") || (ip.hasPrefix("172.") && (16...31).contains(Int(ip.split(separator: ".")[1]) ?? 0))
            if private_ { if name == "en0" { return ip }; best = best ?? ip }
        }
        return best
    }
}

/// Form-encoded POST, for OAuth token exchanges.
func formPost(_ url: String, _ fields: [String: String], basic: (String, String)? = nil) async throws -> [String: Any] {
    var r = URLRequest(url: URL(string: url)!, timeoutInterval: 20)
    r.httpMethod = "POST"
    r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    if let (u, p) = basic { r.setValue("Basic " + Data("\(u):\(p)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization") }
    var c = URLComponents()
    c.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
    r.httpBody = Data((c.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
    let (d, resp) = try await URLSession.shared.data(for: r)
    let json = (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
    guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
        let msg = (json["error_description"] as? String) ?? (json["error"] as? String) ?? "HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)"
        throw OAuthRelay.Failure.refused(msg)
    }
    return json
}
