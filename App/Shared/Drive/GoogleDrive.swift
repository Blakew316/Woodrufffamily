import Foundation
import CryptoKit
import WoodruffKit

/// The app's own Google Drive sign-in (read-only, plus Drive's hidden app folder for sharing progress with the TVs),
/// so Watch works anywhere, not only on the home Wi‑Fi. It uses the family's own Google sign-in keys, the ones the
/// TVs use (copied from a TV once, or typed in), and the same relay page: Google sends the one-time code there and
/// the page hands it back to the app (woodruff://oauth). PKCE means the code is no use to anything but the app that
/// asked for it. The tokens travel to the family's other devices like the other sign-ins.
@MainActor
enum GoogleDrive {
    static let redirect = "https://blakew316.github.io/woodrufffiles/oauth.html"
    static let scopes = "https://www.googleapis.com/auth/drive.readonly https://www.googleapis.com/auth/drive.appdata"
    nonisolated static let filesBase = "https://www.googleapis.com/drive/v3/files"

    // MARK: Keys and tokens

    static var clientID: String? { Keychain.get("gdrive.client").flatMap { $0.isEmpty ? nil : $0 } }
    static var clientSecret: String? { Keychain.get("gdrive.secret").flatMap { $0.isEmpty ? nil : $0 } }
    static var hasKeys: Bool { clientID != nil && clientSecret != nil }
    static var signedIn: Bool { Keychain.get("gdrive.refresh")?.isEmpty == false }

    static func setKeys(id: String, secret: String) {
        let i = id.trimmingCharacters(in: .whitespacesAndNewlines), s = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        // Tokens belong to the keys they were made with.
        if i != clientID { signOut() }
        Keychain.set(i.isEmpty ? nil : i, for: "gdrive.client")
        Keychain.set(s.isEmpty ? nil : s, for: "gdrive.secret")
    }

    static func signOut() {
        if let r = Keychain.get("gdrive.refresh"), !r.isEmpty {
            var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke?token=\(r)")!)
            req.httpMethod = "POST"
            URLSession.shared.dataTask(with: req).resume()
        }
        for k in ["gdrive.refresh", "gdrive.access", "gdrive.expires"] { Keychain.set(nil, for: k) }
    }

    struct Failure: LocalizedError {
        let message: String
        init(_ m: String) { message = m }
        var errorDescription: String? { message }
    }

    // MARK: Signing in

    /// What the sign-in needs: Google's address to open, and what to check and keep for when it comes back.
    struct Attempt {
        let url: URL
        let verifier: String
        let nonce: String
    }

    static func begin() throws -> Attempt {
        guard let id = clientID else { throw Failure("Add the Google sign-in keys first.") }
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let verifier = String((0..<64).map { _ in chars.randomElement()! })
        let nonce = String((0..<24).map { _ in chars.randomElement()! })
        let challenge = base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
        let stateJSON = try JSONSerialization.data(withJSONObject: ["r": "woodruff://oauth", "n": nonce])
        var c = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        c.queryItems = [
            .init(name: "client_id", value: id), .init(name: "redirect_uri", value: redirect),
            .init(name: "response_type", value: "code"), .init(name: "scope", value: scopes),
            .init(name: "access_type", value: "offline"), .init(name: "prompt", value: "consent"),
            .init(name: "state", value: base64url(stateJSON)),
            .init(name: "code_challenge", value: challenge), .init(name: "code_challenge_method", value: "S256"),
        ]
        return Attempt(url: c.url!, verifier: verifier, nonce: nonce)
    }

    /// Google's answer, as the relay page handed it back: the code swapped for tokens.
    static func finish(_ attempt: Attempt, callback: URL) async throws {
        let q = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func v(_ n: String) -> String? { q.first { $0.name == n }?.value }
        if let e = v("error") { throw Failure(e == "access_denied" ? "Google sign-in was cancelled." : "Google said: \(e)") }
        guard let code = v("code"), let state = v("state"),
              let data = Data(base64urlEncoded: state),
              let s = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              s["n"] as? String == attempt.nonce else { throw Failure("The sign-in came back damaged. Try again.") }
        let j = try await tokenRequest([
            "code": code, "client_id": clientID ?? "", "client_secret": clientSecret ?? "",
            "redirect_uri": redirect, "grant_type": "authorization_code", "code_verifier": attempt.verifier,
        ])
        guard let refresh = j["refresh_token"] as? String else { throw Failure("Google didn’t give a lasting sign-in. Try again.") }
        Keychain.set(refresh, for: "gdrive.refresh")
        keep(j)
    }

    private static func keep(_ j: [String: Any]) {
        if let a = j["access_token"] as? String { Keychain.set(a, for: "gdrive.access") }
        let life = (j["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        Keychain.set(String(Date().timeIntervalSince1970 + life), for: "gdrive.expires")
    }

    private static func tokenRequest(_ form: [String: String]) async throws -> [String: Any] {
        var r = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        r.httpMethod = "POST"
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        r.httpBody = form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&").data(using: .utf8)
        r.timeoutInterval = 20
        let (d, resp) = try await URLSession.shared.data(for: r)
        let j = (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 200 { return j }
        switch j["error"] as? String {
        case "invalid_grant": throw Failure("Google ended the sign-in. Sign in to Google Drive again in Settings.")
        case "invalid_client", "unauthorized_client": throw Failure("Google didn’t accept the sign-in keys.")
        default: throw Failure("Google answered \(code). Try again shortly.")
        }
    }

    /// A current access token: the kept one until a minute before it runs out, then a fresh one.
    static func token() async throws -> String {
        let expires = Double(Keychain.get("gdrive.expires") ?? "") ?? 0
        if let a = Keychain.get("gdrive.access"), !a.isEmpty, expires - Date().timeIntervalSince1970 > 60 { return a }
        guard let refresh = Keychain.get("gdrive.refresh"), !refresh.isEmpty else { throw Failure("Sign in to Google Drive in Settings.") }
        if let t = refreshing { return try await t.value }
        let t = Task { () throws -> String in
            let j = try await tokenRequest(["client_id": clientID ?? "", "client_secret": clientSecret ?? "",
                                            "refresh_token": refresh, "grant_type": "refresh_token"])
            keep(j)
            guard let a = j["access_token"] as? String else { throw Failure("Google answered without a sign-in.") }
            return a
        }
        refreshing = t
        defer { refreshing = nil }
        return try await t.value
    }
    private static var refreshing: Task<String, Error>?

    /// The kept token as rejected: the next request gets a fresh one.
    static func dropToken() { Keychain.set("0", for: "gdrive.expires") }

    // MARK: Drive

    struct File: Codable, Hashable {
        var id: String
        var name: String
        var mimeType: String
        var size: String?
        var modifiedTime: String?
        var createdTime: String?
        var thumbnailLink: String?
        var parents: [String]?
        var isFolder: Bool { mimeType == "application/vnd.google-apps.folder" }
        var isVideo: Bool {
            if mimeType.hasPrefix("video/") { return true }
            let ext = (name as NSString).pathExtension.lowercased()
            return ["mp4", "m4v", "mov", "mkv", "webm", "avi", "ts", "m2ts", "3gp", "wmv", "flv", "mpg", "mpeg"].contains(ext)
        }
        var isImage: Bool { mimeType.hasPrefix("image/") }
        var bytes: Int64 { Int64(size ?? "") ?? 0 }
        /// When it was added (created, else modified), in ms like the TV's.
        var added: Double { (GoogleDrive.time(createdTime) ?? GoogleDrive.time(modifiedTime) ?? 0) * 1000 }
    }

    nonisolated static func time(_ s: String?) -> Double? {
        guard let s else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d.timeIntervalSince1970 }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)?.timeIntervalSince1970
    }

    /// A Drive API GET, with a fresh token and one retry after a 401.
    static func get(_ url: URL) async throws -> [String: Any] {
        for attempt in 0..<2 {
            var r = URLRequest(url: url)
            r.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
            r.timeoutInterval = 30
            let (d, resp) = try await URLSession.shared.data(for: r)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 && attempt == 0 { dropToken(); continue }
            guard code == 200 else { throw Failure(code == 403 ? "Google Drive refused the request (\(code))." : "Google Drive answered \(code).") }
            return (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
        }
        throw Failure("Google Drive refused the sign-in. Sign in again in Settings.")
    }

    private static func filesURL(_ q: String, orderBy: String? = nil, fields: String, pageSize: Int, page: String?) -> URL {
        var c = URLComponents(string: filesBase)!
        var items: [URLQueryItem] = [.init(name: "q", value: q), .init(name: "pageSize", value: String(pageSize)),
                                     .init(name: "fields", value: fields),
                                     .init(name: "includeItemsFromAllDrives", value: "true"), .init(name: "supportsAllDrives", value: "true")]
        if let orderBy { items.append(.init(name: "orderBy", value: orderBy)) }
        if let page { items.append(.init(name: "pageToken", value: page)) }
        c.queryItems = items
        // "+" in a query value means a space to Google; encode it.
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return c.url!
    }

    nonisolated static let fileFields = "nextPageToken,files(id,name,mimeType,size,modifiedTime,createdTime,thumbnailLink)"

    /// Every file matching [q] (all pages, up to [limit]).
    static func files(_ q: String, orderBy: String? = "folder,name_natural", fields: String = fileFields, limit: Int = 20_000) async throws -> [File] {
        var out: [File] = []
        var page: String?
        repeat {
            let j = try await get(filesURL(q, orderBy: orderBy, fields: fields, pageSize: 1000, page: page))
            let data = try JSONSerialization.data(withJSONObject: j["files"] ?? [])
            out += (try? JSONDecoder().decode([File].self, from: data)) ?? []
            page = j["nextPageToken"] as? String
        } while page != nil && out.count < limit
        return out
    }

    static func quoted(_ s: String) -> String { "'" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'" }

    /// What's in a folder.
    static func children(_ folder: String) async throws -> [File] {
        try await files("\(quoted(folder)) in parents and trashed = false")
    }

    /// The library folder called one of [names]: at the top of My Drive first, then anywhere (the TV's order).
    static func findFolder(_ names: [String]) async throws -> String? {
        for top in [true, false] {
            for n in names {
                let q = "mimeType = 'application/vnd.google-apps.folder' and name = \(quoted(n)) and trashed = false" + (top ? " and 'root' in parents" : "")
                if let f = try await files(q, orderBy: nil, fields: "files(id)", limit: 1).first { return f.id }
            }
        }
        return nil
    }

    /// The file's bytes, from where the player or a download asks.
    nonisolated static func mediaURL(_ id: String) -> URL {
        var c = URLComponents(string: "\(filesBase)/\(id)")!
        c.queryItems = [.init(name: "alt", value: "media"), .init(name: "supportsAllDrives", value: "true")]
        return c.url!
    }

    // MARK: Helpers

    static func base64url(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

extension Data {
    init?(base64urlEncoded s: String) {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        self.init(base64Encoded: b)
    }
}
