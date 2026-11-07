import Foundation
import WoodruffKit

/// The family's Google Photos and Calendar sign-ins, kept by the app (in the Keychain, synced to every phone and Mac
/// with the family's other keys) and handed to every TV, which uses them for Memories and Today's events. Signing in
/// once on any device covers every TV; a TV that was off, reset or paired later gets them the next time a device sees
/// it. Same Google keys and sign-in page as the Drive sign-in (`GoogleDrive`), so a TV can renew them itself.
enum GoogleGrant: String, CaseIterable {
    case photos, calendar

    var title: String { self == .photos ? "Google Photos" : "Google Calendar" }
    var scope: String {
        switch self {
        case .photos: return "https://www.googleapis.com/auth/photospicker.mediaitems.readonly"
        case .calendar: return "https://www.googleapis.com/auth/calendar.readonly"
        }
    }
    private var prefix: String { self == .photos ? "gphotos" : "gcal" }
    var refreshKey: String { prefix + ".refresh" }
    var scopesKey: String { prefix + ".scopes" }
    /// When it was signed in (ms since 1970): a TV keeps it only if it's newer than one made on the TV itself.
    var atKey: String { prefix + ".at" }

    /// The Keychain items that travel with the family's keys (SettingsSync).
    static var syncedKeys: [String] { allCases.flatMap { [$0.refreshKey, $0.scopesKey, $0.atKey] } }

    var refresh: String? { Keychain.get(refreshKey).flatMap { $0.isEmpty ? nil : $0 } }
    var signedIn: Bool { refresh != nil }
}

@MainActor
enum GoogleGrants {
    /// Signs [grant] in here (Google's page, as for Drive), keeps it, and hands it to every TV.
    static func signIn(_ grant: GoogleGrant, fleet: Fleet,
                       authenticate: (URL) async throws -> URL) async throws {
        let attempt = try GoogleDrive.begin(scopes: grant.scope)
        let callback = try await authenticate(attempt.url)
        let j = try await GoogleDrive.exchange(attempt, callback: callback)
        guard let refresh = j["refresh_token"] as? String, !refresh.isEmpty else {
            throw GoogleDrive.Failure("Google didn’t give a lasting sign-in. Try again.")
        }
        Keychain.set(refresh, for: grant.refreshKey)
        Keychain.set((j["scope"] as? String) ?? grant.scope, for: grant.scopesKey)
        Keychain.set(String(Int64(Date().timeIntervalSince1970 * 1000)), for: grant.atKey)
        await handOut(fleet, only: grant)
    }

    /// Forgets [grant] on this device (and, through the sync, on the others). The TVs keep theirs.
    static func signOut(_ grant: GoogleGrant) {
        for k in [grant.refreshKey, grant.scopesKey, grant.atKey] { Keychain.set(nil, for: k) }
    }

    /// Gives every TV this device can reach the sign-ins kept here (a TV keeps one only if it's new to it).
    /// [only]: just that one.
    static func handOut(_ fleet: Fleet, only: GoogleGrant? = nil) async {
        let grants = (only.map { [$0] } ?? GoogleGrant.allCases).filter(\.signedIn)
        guard !grants.isEmpty, !Demo.isOn else { return }
        for tv in fleet.tvs where !tv.isUnpaired {
            guard let c = fleet.client(for: tv) else { continue }
            for g in grants {
                guard let refresh = g.refresh else { continue }
                let at = Int64(Keychain.get(g.atKey) ?? "") ?? 0
                // A TV on an older version (or an LG TV) doesn't know this yet: nothing to do there.
                if let kept = try? await c.giveGrant(g.rawValue, refresh: refresh, scope: Keychain.get(g.scopesKey) ?? g.scope, at: at), kept {
                    PushRelay.log.notice("\(g.title, privacy: .public) sign-in handed to \(tv.name, privacy: .public)")
                }
            }
        }
    }

    private static var loop: Task<Void, Never>?

    /// Hands the sign-ins out a little after launch and every three hours (a TV turned on, reset or paired since).
    static func start(_ fleet: Fleet) {
        guard loop == nil else { return }
        loop = Task {
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            while !Task.isCancelled {
                await handOut(fleet)
                try? await Task.sleep(nanoseconds: 3 * 3600 * 1_000_000_000)
            }
        }
    }
}
