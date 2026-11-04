import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Woodruff's version numbers: release v2.0.N is build N, and a TV reports "2.0.N" (or just N).
public struct WoodruffVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public var parts: [Int]

    public init?(_ text: String?) {
        guard var t = text?.trimmingCharacters(in: .whitespaces), !t.isEmpty else { return nil }
        if let r = t.range(of: #"\d+(\.\d+)*"#, options: .regularExpression) { t = String(t[r]) } else { return nil }
        let p = t.split(separator: ".").compactMap { Int($0) }
        guard !p.isEmpty else { return nil }
        parts = p
    }

    /// The build number: the last part ("2.0.312" → 312; "312" → 312).
    public var build: Int { parts.last ?? 0 }

    public static func < (a: Self, b: Self) -> Bool {
        // A bare build number compares with the last part of a dotted one.
        if a.parts.count == 1 || b.parts.count == 1 { return a.build < b.build }
        for i in 0..<max(a.parts.count, b.parts.count) {
            let x = i < a.parts.count ? a.parts[i] : 0, y = i < b.parts.count ? b.parts[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    public var description: String { parts.map(String.init).joined(separator: ".") }
}

/// A GitHub release of one of the TV apps.
public struct Release: Decodable, Hashable, Sendable {
    public struct Asset: Decodable, Hashable, Sendable {
        public var name: String
        public var url: URL                    // API URL (needs Accept: application/octet-stream)
        public var browser_download_url: URL
        public var size: Int
    }
    public var tag_name: String
    public var name: String?
    public var body: String?
    public var published_at: Date?
    public var prerelease: Bool?
    public var assets: [Asset]

    public var version: WoodruffVersion? { WoodruffVersion(tag_name) }
    public var title: String { name?.isEmpty == false ? name! : tag_name }
}

public enum TVPlatform: String, Codable, CaseIterable, Sendable {
    case android, webOS

    /// Where its releases come from: the Android app is public, the webOS port is private (needs a token).
    public var repository: String {
        switch self {
        case .android: return "Blakew316/woodrufffiles"
        case .webOS: return "Blakew316/woodrufffiles-webos"
        }
    }
    public var label: String { self == .android ? "Android TV / Google TV" : "LG webOS" }
}

/// Reads releases from GitHub.
public struct ReleaseFeed: Sendable {
    public var token: String?
    public init(token: String? = nil) { self.token = token?.isEmpty == true ? nil : token }

    func request(_ url: URL, accept: String = "application/vnd.github+json") -> URLRequest {
        var r = URLRequest(url: url, timeoutInterval: 20)
        r.setValue(accept, forHTTPHeaderField: "Accept")
        r.setValue("WoodruffFamily-Apple", forHTTPHeaderField: "User-Agent")
        if let token { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return r
    }

    /// The newest release for [platform]. Android tags are `v2.0.N`; webOS tags are `webos-N`.
    public func latest(_ platform: TVPlatform) async throws -> Release {
        let url = URL(string: "https://api.github.com/repos/\(platform.repository)/releases?per_page=15")!
        let (d, resp) = try await URLSession.shared.data(for: request(url))
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 || status == 401 {
            throw TVError.http(status: status, message: platform == .webOS
                ? "The webOS releases are in a private repository. Add a GitHub token in Settings → TVs → Software Update."
                : "GitHub refused (\(status)).")
        }
        guard status == 200 else { throw TVError.http(status: status, message: "GitHub answered \(status)") }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let all = try dec.decode([Release].self, from: d)
        let wanted = all.filter { r in
            platform == .webOS ? r.tag_name.hasPrefix("webos-") : !r.tag_name.hasPrefix("webos-")
        }
        guard let best = wanted.max(by: { ($0.version ?? WoodruffVersion("0")!) < ($1.version ?? WoodruffVersion("0")!) }) else {
            throw TVError.badAnswer("No releases found for \(platform.label)")
        }
        return best
    }

    /// Downloads [asset] to a temporary file.
    public func download(_ asset: Release.Asset) async throws -> URL {
        let req = token != nil ? request(asset.url, accept: "application/octet-stream") : request(asset.browser_download_url, accept: "application/octet-stream")
        let (file, resp) = try await URLSession.shared.download(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw TVError.badAnswer("Download failed") }
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(asset.name)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: file, to: dest)
        return dest
    }
}
