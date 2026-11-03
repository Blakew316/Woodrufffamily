import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Where one TV's Woodruff server answers, and the pairing key that opens its `/api` routes.
///
/// The TV's QR code is `http://<ip>:<port>/?k=<key>`; the same key goes on every request as the
/// `X-Tvx` header (the web page used a cookie). Image and video URLs carry it as `?k=` so that
/// `AsyncImage` and `AVPlayer` can load them directly.
public struct TVConnection: Codable, Hashable, Sendable {
    public var base: URL
    public var key: String

    public init(base: URL, key: String) {
        self.base = base
        self.key = key
    }

    /// Parses a pairing link: the QR code's URL, a pasted "Away from home" link, or `ip:port` plus a key.
    public static func parse(_ text: String, key fallbackKey: String? = nil) -> TVConnection? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.lowercased().hasPrefix("http://") && !s.lowercased().hasPrefix("https://") { s = "http://" + s }
        guard var comps = URLComponents(string: s), let host = comps.host, !host.isEmpty else { return nil }
        let key = comps.queryItems?.first(where: { $0.name == "k" })?.value ?? fallbackKey
        guard let key, !key.isEmpty else { return nil }
        if comps.port == nil { comps.port = 8090 }
        comps.path = ""
        comps.query = nil
        comps.fragment = nil
        guard let base = comps.url else { return nil }
        return TVConnection(base: base, key: key)
    }

    /// The link a phone or Shortcut would use (same as the TV's QR code).
    public var pairingLink: URL {
        var c = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        c.path = "/"
        c.queryItems = [URLQueryItem(name: "k", value: key)]
        return c.url!
    }

    /// `path` on this TV with `query`, plus the key (for URLs handed to image views and players).
    public func url(_ path: String, _ query: [String: String?] = [:], withKey: Bool = true) -> URL {
        var c = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        c.path = path
        var items = query.compactMap { k, v in v.map { URLQueryItem(name: k, value: $0) } }.sorted { $0.name < $1.name }
        if withKey { items.append(URLQueryItem(name: "k", value: key)) }
        c.queryItems = items.isEmpty ? nil : items
        return c.url!
    }
}

/// An error a TV answered with (its own words), or a network failure.
public enum TVError: LocalizedError, Equatable, Sendable {
    case http(status: Int, message: String)
    case offline(String)
    case badAnswer(String)
    case notPaired

    public var errorDescription: String? {
        switch self {
        case .http(_, let m): return m
        case .offline(let m): return m
        case .badAnswer(let m): return m
        case .notPaired: return "Pair with a TV first: scan the QR code on its Phone screen."
        }
    }

    public var status: Int? { if case .http(let s, _) = self { return s }; return nil }
    /// The TV answered but turned the key down (reset, or a new key): pair again.
    public var isRefused: Bool { status == 401 || status == 403 }

    /// The TV's error body: plain text, or JSON with `message`.
    static func from(status: Int, data: Data) -> TVError {
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let m = obj["message"] as? String {
            return .http(status: status, message: m)
        }
        if status == 401 && text.isEmpty { return .http(status: status, message: "This TV's pairing key changed. Scan its QR code again.") }
        return .http(status: status, message: text.isEmpty ? "The TV answered \(status)." : text)
    }
}

/// HTTP to one TV. Every call is async and throws `TVError`.
public struct TVTransport: Sendable {
    public let connection: TVConnection
    let session: URLSession

    public init(_ connection: TVConnection, session: URLSession = .woodruff) {
        self.connection = connection
        self.session = session
    }

    func request(_ method: String, _ path: String, query: [String: String?] = [:], body: Data? = nil,
                 contentType: String? = "application/json", timeout: TimeInterval = 10) -> URLRequest {
        // The key goes in the URL (both TV apps), as the `tvx` cookie (both) and as X-Tvx (webOS):
        // Android ignores X-Tvx, and merges other query parameters into the JSON body, which is harmless.
        var r = URLRequest(url: connection.url(path, query, withKey: true), timeoutInterval: timeout)
        r.httpMethod = method
        r.httpShouldHandleCookies = false
        r.setValue("tvx=\(connection.key)", forHTTPHeaderField: "Cookie")
        r.setValue(connection.key, forHTTPHeaderField: "X-Tvx")
        if let body {
            r.httpBody = body
            if let contentType { r.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        }
        return r
    }

    public func data(_ method: String, _ path: String, query: [String: String?] = [:], body: Data? = nil,
                     contentType: String? = "application/json", timeout: TimeInterval = 10) async throws -> (Data, HTTPURLResponse) {
        let req = request(method, path, query: query, body: body, contentType: contentType, timeout: timeout)
        let data: Data, resp: URLResponse
        do {
            (data, resp) = try await session.data(for: req)
        } catch let e as URLError {
            switch e.code {
            case .timedOut: throw TVError.offline("The TV didn't answer in time. Is it on?")
            case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet:
                throw TVError.offline("Can't reach the TV. It may be off, or on another network.")
            default: throw TVError.offline(e.localizedDescription)
            }
        }
        guard let http = resp as? HTTPURLResponse else { throw TVError.badAnswer("No answer from the TV") }
        guard (200..<300).contains(http.statusCode) || http.statusCode == 304 else { throw TVError.from(status: http.statusCode, data: data) }
        return (data, http)
    }

    public func get<T: Decodable>(_ path: String, _ query: [String: String?] = [:], as: T.Type = T.self, timeout: TimeInterval = 10) async throws -> T {
        let (d, _) = try await data("GET", path, query: query, timeout: timeout)
        return try decode(d)
    }

    public func post<T: Decodable>(_ path: String, _ body: [String: Any?] = [:], as: T.Type = T.self, timeout: TimeInterval = 10) async throws -> T {
        let clean = body.compactMapValues { $0 }
        let d = try JSONSerialization.data(withJSONObject: clean)
        let (out, _) = try await data("POST", path, body: d, timeout: timeout)
        return try decode(out.isEmpty ? Data("{}".utf8) : out)
    }

    @discardableResult
    public func post(_ path: String, _ body: [String: Any?] = [:], timeout: TimeInterval = 10) async throws -> JSONValue {
        try await post(path, body, as: JSONValue.self, timeout: timeout)
    }

    public func text(_ path: String, _ query: [String: String?] = [:]) async throws -> String {
        let (d, _) = try await data("GET", path, query: query)
        return String(decoding: d, as: UTF8.self)
    }

    func decode<T: Decodable>(_ d: Data) throws -> T {
        if T.self == Data.self { return d as! T }
        do { return try JSONDecoder.woodruff.decode(T.self, from: d) } catch {
            throw TVError.badAnswer("The TV's answer wasn't understood (\(T.self)): \(error)")
        }
    }
}

public extension URLSession {
    /// Short timeouts (TVs are on the LAN), no cookies, no cache of API answers.
    static let woodruff: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 10
        c.timeoutIntervalForResource = 600
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.waitsForConnectivity = false
        c.httpMaximumConnectionsPerHost = 6
        if Demo.isOn { c.protocolClasses = [DemoURLProtocol.self] + (c.protocolClasses ?? []) }
        return URLSession(configuration: c)
    }()
}

public extension JSONDecoder {
    static let woodruff: JSONDecoder = {
        let d = JSONDecoder()
        return d
    }()
}
