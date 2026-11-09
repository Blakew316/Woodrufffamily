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
        // Tokens belong to the keys they were made with (forgotten here only, never revoked).
        if let old = clientID, i != old { signOut() }
        Keychain.set(i.isEmpty ? nil : i, for: "gdrive.client")
        Keychain.set(s.isEmpty ? nil : s, for: "gdrive.secret")
    }

    /// Reading Drive's files was allowed at sign-in (unknown counts as yes).
    static var canReadFiles: Bool {
        guard let s = Keychain.get("gdrive.scopes"), !s.isEmpty else { return true }
        return s.contains("auth/drive.readonly") || s.contains("auth/drive ") || s.hasSuffix("auth/drive")
    }

    /// The Google account signed in, as Drive says.
    static var email: String? { Keychain.get("gdrive.email").flatMap { $0.isEmpty ? nil : $0 } }

    static func loadEmail() async {
        guard let j = try? await get(URL(string: "https://www.googleapis.com/drive/v3/about?fields=user(emailAddress)")!),
              let e = (j["user"] as? [String: Any])?["emailAddress"] as? String else { return }
        Keychain.set(e, for: "gdrive.email")
    }

    /// Forgets this app's Drive sign-in here. Never revoked at Google: the TVs sign in with the same keys, and a
    /// revoke would end their sign-ins too (the Nest cameras, Drive, Photos, Calendar).
    static func signOut() {
        for k in ["gdrive.refresh", "gdrive.access", "gdrive.expires", "gdrive.scopes", "gdrive.email"] { Keychain.set(nil, for: k) }
        memo.set(nil, expires: 0)
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

    /// [scopes]: Drive's (the default), or another sign-in's (Google Photos, Calendar: `GoogleGrants`).
    static func begin(scopes: String = scopes) throws -> Attempt {
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
        let j = try await exchange(attempt, callback: callback)
        guard let refresh = j["refresh_token"] as? String else { throw Failure("Google didn’t give a lasting sign-in. Try again.") }
        Keychain.set(refresh, for: "gdrive.refresh")
        keep(j)
        await loadEmail()
    }

    /// The code in Google's answer swapped for tokens (Google's reply as it came).
    static func exchange(_ attempt: Attempt, callback: URL) async throws -> [String: Any] {
        let q = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func v(_ n: String) -> String? { q.first { $0.name == n }?.value }
        if let e = v("error") { throw Failure(e == "access_denied" ? "Google sign-in was cancelled." : "Google said: \(e)") }
        guard let code = v("code"), let state = v("state"),
              let data = Data(base64urlEncoded: state),
              let s = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              s["n"] as? String == attempt.nonce else { throw Failure("The sign-in came back damaged. Try again.") }
        return try await tokenRequest([
            "code": code, "client_id": clientID ?? "", "client_secret": clientSecret ?? "",
            "redirect_uri": redirect, "grant_type": "authorization_code", "code_verifier": attempt.verifier,
        ])
    }

    private static func keep(_ j: [String: Any]) {
        // What Google let the app have (each permission is a box the person can leave unticked).
        if let s = j["scope"] as? String { Keychain.set(s, for: "gdrive.scopes") }
        let life = (j["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        let expires = Date().timeIntervalSince1970 + life
        Keychain.set(String(expires), for: "gdrive.expires")
        if let a = j["access_token"] as? String {
            Keychain.set(a, for: "gdrive.access")
            memo.set(a, expires: expires)
        }
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

    /// A current access token: the kept one until [minLife] seconds before it runs out (a minute by default), then a
    /// fresh one. Opening a title asks for ten minutes, so the film's first requests never wait for a new one.
    static func token(minLife: Double = 60) async throws -> String {
        if let a = memo.get(minLife: minLife) { return a }
        let expires = Double(Keychain.get("gdrive.expires") ?? "") ?? 0
        if let a = Keychain.get("gdrive.access"), !a.isEmpty, expires - Date().timeIntervalSince1970 > minLife {
            memo.set(a, expires: expires)
            return a
        }
        #if os(tvOS)
        // The Apple TV away from home couldn't renew its own sign-in (Google's sign-in service timed out from there and
        // Drive refused the old one): the Mac Studio's current one first, over the camera share.
        if let got = await DriveTokenRelay.fromMac(), got.expires - Date().timeIntervalSince1970 > minLife {
            Keychain.set(got.token, for: "gdrive.access")
            Keychain.set(String(got.expires), for: "gdrive.expires")
            memo.set(got.token, expires: got.expires)
            return got.token
        }
        #endif
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

    /// When the kept sign-in runs out (seconds since 1970; 0 when unknown).
    static var keptExpiry: Double { Double(Keychain.get("gdrive.expires") ?? "") ?? 0 }

    /// The kept token as rejected: the next request gets a fresh one.
    static func dropToken() {
        Keychain.set("0", for: "gdrive.expires")
        memo.set(nil, expires: 0)
    }

    /// The token in memory when it has more than a minute left, from any thread (the player's stream asks for one for
    /// every part it fetches, and shouldn't wait for the main thread or the keychain to get it).
    nonisolated static func cachedToken() -> String? { memo.get(minLife: 60) }
    /// The kept token if it lasts at least [minLife] seconds more.
    nonisolated static func cachedToken(minLife: Double) -> String? { memo.get(minLife: minLife) }

    nonisolated private static let memo = DriveTokenMemo()


    // MARK: Drive

    struct File: Codable, Hashable {
        var id: String
        var name: String
        var mimeType: String = ""
        var size: String?
        var modifiedTime: String?
        var createdTime: String?
        var parents: [String]?

        // Read whatever fields were asked for: a search that asks only for ids still gives files.
        enum CodingKeys: String, CodingKey { case id, name, mimeType, size, modifiedTime, createdTime, parents }
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
            mimeType = try c.decodeIfPresent(String.self, forKey: .mimeType) ?? ""
            size = try c.decodeIfPresent(String.self, forKey: .size)
            modifiedTime = try c.decodeIfPresent(String.self, forKey: .modifiedTime)
            createdTime = try c.decodeIfPresent(String.self, forKey: .createdTime)
            parents = try c.decodeIfPresent([String].self, forKey: .parents)
        }
        var isFolder: Bool { mimeType == "application/vnd.google-apps.folder" }
        var isVideo: Bool {
            if mimeType.hasPrefix("video/") { return true }
            let ext = (name as NSString).pathExtension.lowercased()
            return ["mp4", "m4v", "mov", "mkv", "webm", "avi", "ts", "m2ts", "3gp", "wmv", "flv", "mpg", "mpeg"].contains(ext)
        }
        var bytes: Int64 { Int64(size ?? "") ?? 0 }
        /// When it was added (created, else modified), in ms like the TV's.
        var added: Double { (GoogleDrive.time(createdTime) ?? GoogleDrive.time(modifiedTime) ?? 0) * 1000 }
    }

    nonisolated static func time(_ s: String?) -> Double? {
        guard let s else { return nil }
        if let d = fractionalTime.date(from: s) { return d.timeIntervalSince1970 }
        return wholeTime.date(from: s)?.timeIntervalSince1970
    }

    /// Made once (a formatter is slow to make, and every file read from Drive is dated with one). ISO8601DateFormatter
    /// may be used from any thread.
    nonisolated(unsafe) private static let fractionalTime: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let wholeTime: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// A Drive API GET, with a fresh token and one retry after a 401.
    static func get(_ url: URL) async throws -> [String: Any] {
        for attempt in 0..<2 {
            var r = URLRequest(url: url)
            r.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
            r.timeoutInterval = 30
            let (d, resp) = try await URLSession.shared.data(for: r)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 && attempt == 0 { dropToken(); continue }
            guard code == 200 else { throw failure(code, d) }
            return (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
        }
        throw Failure("Google Drive refused the sign-in. Sign in again in Settings.")
    }

    /// What a refused Drive request means, in words someone can act on (Drive says why in its answer).
    /// The reason in Google's refusal ("downloadQuotaExceeded", say), or "" when it gave none.
    nonisolated static func reason(_ body: Data?) -> String {
        let j = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        return ((j?["error"] as? [String: Any])?["errors"] as? [[String: Any]])?.first?["reason"] as? String ?? ""
    }

    nonisolated static func failure(_ code: Int, _ body: Data?) -> Failure {
        let j = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let reason = ((j?["error"] as? [String: Any])?["errors"] as? [[String: Any]])?.first?["reason"] as? String ?? ""
        switch (code, reason) {
        case (401, _): return Failure("Google Drive refused the sign-in. Sign in again in Settings.")
        case (_, "rateLimitExceeded"), (_, "userRateLimitExceeded"), (429, _):
            return Failure("Google Drive is busy. Try again in a minute.")
        case (_, "downloadQuotaExceeded"):
            return Failure("Google Drive won’t send this file again today (its daily limit). Try again tomorrow.")
        case (_, "insufficientPermissions"), (_, "insufficientFilePermissions"), (_, "appNotAuthorizedToFile"):
            return Failure("Google Drive didn’t allow this. Sign out in Settings → Watch, sign in again and tick every box on Google’s screen.")
        case (404, _): return Failure("That file isn’t in Google Drive any more.")
        case (500...599, _): return Failure("Google Drive is having trouble. Try again shortly.")
        default: return Failure("Google Drive answered \(code).")
        }
    }

    private static func filesURL(_ q: String, orderBy: String? = nil, fields: String, pageSize: Int, page: String?, allDrives: Bool = false) -> URL {
        var c = URLComponents(string: filesBase)!
        var items: [URLQueryItem] = [.init(name: "q", value: q), .init(name: "pageSize", value: String(pageSize)),
                                     .init(name: "fields", value: fields),
                                     .init(name: "includeItemsFromAllDrives", value: "true"), .init(name: "supportsAllDrives", value: "true")]
        if let orderBy { items.append(.init(name: "orderBy", value: orderBy)) }
        if let page { items.append(.init(name: "pageToken", value: page)) }
        if allDrives { items.append(.init(name: "corpora", value: "allDrives")) }
        c.queryItems = items
        // "+" in a query value means a space to Google; encode it.
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return c.url!
    }

    nonisolated static let fileFields = "nextPageToken,files(id,name,mimeType,size,modifiedTime,createdTime)"

    /// Every file matching [q] (all pages, up to [limit]).
    static func files(_ q: String, orderBy: String? = "folder,name_natural", fields: String = fileFields, limit: Int = 20_000, allDrives: Bool = false) async throws -> [File] {
        var out: [File] = []
        var page: String?
        repeat {
            let j = try await get(filesURL(q, orderBy: orderBy, fields: fields, pageSize: min(1000, limit), page: page, allDrives: allDrives))
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
        let folder = "mimeType = 'application/vnd.google-apps.folder' and trashed = false"
        for top in [true, false] {
            for n in names {
                let q = "\(folder) and name = \(quoted(n))" + (top ? " and 'root' in parents" : "")
                if let f = try await files(q, orderBy: nil, fields: "files(id,name,mimeType)", limit: 1).first { return f.id }
            }
        }
        // In a shared drive, or named a little differently ("movies", "My Movies").
        for n in names {
            if let f = try? await files("\(folder) and name = \(quoted(n))", orderBy: nil, fields: "files(id)", limit: 1, allDrives: true).first { return f.id }
        }
        for n in names {
            let found = (try? await files("\(folder) and name contains \(quoted(n))", orderBy: nil, fields: "files(id,name,mimeType)", limit: 20, allDrives: true)) ?? []
            if let f = found.first(where: { $0.name.lowercased() == n.lowercased() }) ?? found.first { return f.id }
        }
        return nil
    }

    /// The folders at the top of My Drive (for saying what the app can see).
    static func topFolders() async -> [String] {
        let q = "mimeType = 'application/vnd.google-apps.folder' and trashed = false and 'root' in parents"
        return ((try? await files(q, orderBy: "name_natural", fields: "files(id,name,mimeType)", limit: 12)) ?? []).map(\.name)
    }

    /// The file's bytes, from where the player or a download asks.
    nonisolated static func mediaURL(_ id: String, acknowledgeAbuse: Bool = false) -> URL {
        var c = URLComponents(string: "\(filesBase)/\(id)")!
        c.queryItems = [.init(name: "alt", value: "media"), .init(name: "supportsAllDrives", value: "true")]
        // A file Google flagged: its owner may still have it, once that's acknowledged.
        if acknowledgeAbuse { c.queryItems?.append(.init(name: "acknowledgeAbuse", value: "true")) }
        return c.url!
    }

    // MARK: Helpers

    static func base64url(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

/// Drive's current access token and when it runs out, in memory (read from any thread).
private final class DriveTokenMemo: @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?
    private var expires: Double = 0
    func get(minLife: Double) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let token, !token.isEmpty, expires - Date().timeIntervalSince1970 > minLife else { return nil }
        return token
    }
    func set(_ t: String?, expires e: Double) {
        lock.lock(); token = t; expires = e; lock.unlock()
    }
}

extension Data {
    init?(base64urlEncoded s: String) {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        self.init(base64Encoded: b)
    }
}
