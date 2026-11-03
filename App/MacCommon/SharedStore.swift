import Foundation
import WoodruffKit

/// What the Mac app shares with its desktop widgets, through the app group: the paired TVs (so a widget can
/// ask them itself, and press their buttons, without the app running) and which TV the remote is on.
enum SharedStore {
    struct HubLink: Codable, Hashable {
        var id: String
        var name: String
        var base: URL
        var key: String
    }

    struct Snapshot: Codable {
        var hubs: [HubLink]
        var selectedID: String?
        /// TV id → the name the family gave it here (Elliot's Room…).
        var names: [String: String]
    }

    static var groupID: String? {
        guard let g = Bundle.main.object(forInfoDictionaryKey: "WoodruffAppGroup") as? String, !g.isEmpty, !g.hasPrefix("$(") else { return nil }
        return g
    }

    static var defaults: UserDefaults? { groupID.flatMap { UserDefaults(suiteName: $0) } }

    static func save(_ s: Snapshot) {
        guard let d = defaults, let data = try? JSONEncoder().encode(s) else { return }
        if d.data(forKey: "snapshot") != data { d.set(data, forKey: "snapshot") }
    }

    static func load() -> Snapshot? {
        guard let data = defaults?.data(forKey: "snapshot") else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }
}
