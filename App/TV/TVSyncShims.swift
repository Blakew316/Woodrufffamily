import Foundation
import Observation
import WoodruffKit

// SmartThings and Dreo run here for real (the washer, dryer, fans and the rest on Home), with the family's sign-ins
// from the sync; signing in happens on the iPhone or Mac, so the sign-in relay is a stand-in.
//
// The family's settings sync (App/Shared/SettingsSync.swift, the same file the iPhone and Mac run) also restarts the
// services those apps run when a sign-in arrives or ends. The Apple TV doesn't run them, so here they're stand-ins
// that do nothing: the sign-ins still arrive and are kept with the family's keys, ready for when the Apple TV uses
// them.

@Observable @MainActor final class DecoWifi {
    static let shared = DecoWifi()
    var busy = false
    func signOut() {}
    func start() {}
    func refresh() async {}
}

@MainActor final class NestCameras {
    static let shared = NestCameras()
    func reloadSaved() {}
    func signOut() {}
    func start() {}
}

@MainActor final class Cync {
    static let shared = Cync()
    func signOut() {}
    func start() {}
}

@MainActor final class PushRelay {
    static let shared = PushRelay()
    func reloadTokens() {}
    func keysChanged() {}
}

@MainActor enum GoogleGrants {
    static func handOut(_ fleet: Fleet) async {}
}

@MainActor final class SceneStore {
    static let shared = SceneStore()
    func reload() {}
}

@MainActor final class HomeLayout {
    static let shared = HomeLayout()
    func reload() {}
}

@MainActor final class OAuthRelay {
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

    func signIn(authorize: (String) -> URL) async throws -> String {
        throw Failure.refused("Sign in on your iPhone or Mac. The Apple TV gets the sign-in from the family.")
    }
}

/// The token request the sign-ins use (OAuthRelay.swift's, the same on every device).
func formPost(_ url: String, _ fields: [String: String], basic: (String, String)? = nil) async throws -> [String: Any] {
    var r = URLRequest(url: URL(string: url)!, timeoutInterval: 20)
    r.httpMethod = "POST"
    r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    if let pair = basic { r.setValue("Basic " + Data("\(pair.0):\(pair.1)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization") }
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
