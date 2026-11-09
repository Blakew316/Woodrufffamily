import Foundation
import WoodruffKit

/// What the Mac app shares with its desktop widgets, through the app group: the paired TVs (so a widget can
/// ask them itself, and press their buttons, without the app running) and which TV the remote is on.
///
/// Known limitation: each TV's pairing key (`HubLink.key`) sits here in the app group's settings, unencrypted, because
/// the widgets can't read the app's Keychain (sharing Keychain items between the app and its widgets needs
/// `keychain-access-groups`, which this project doesn't use). Anything that can read this Mac's app-group settings can
/// read the keys. They no longer open the family's synced settings on their own (those need the family code too).
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
        /// Sonos rooms and Govee lights, for the Speakers & Lights widget.
        var speakers: [SonosRoom]? = nil
        var lights: [GoveeLight]? = nil
        /// Every TV the app knows (so the widgets list the same TVs, not only what each hub reports).
        var tvs: [TVInfo]? = nil
    }

    /// One TV as the app last saw it.
    struct TVInfo: Codable, Hashable {
        var id: String
        var name: String
        var online: Bool
        var playing: NowPlaying?
        var hubID: String
        var routeID: String
    }

    static let groupID: String? = {
        guard let g = Bundle.main.object(forInfoDictionaryKey: "WoodruffAppGroup") as? String, !g.isEmpty, !g.hasPrefix("$(") else { return nil }
        return g
    }()

    /// Made once (it was made afresh on every save and load, several times a minute while anything played).
    static let defaults: UserDefaults? = groupID.flatMap { UserDefaults(suiteName: $0) }

    /// Keys in a fixed order, so the same snapshot always makes the same bytes and an unchanged one isn't written again.
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    static func save(_ s: Snapshot) {
        guard let d = defaults, let data = try? encoder.encode(s) else { return }
        if d.data(forKey: "snapshot") != data { d.set(data, forKey: "snapshot") }
    }

    static func load() -> Snapshot? {
        guard let data = defaults?.data(forKey: "snapshot") else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }
}

/// The Mac's TVs & Cameras widget: each camera's latest picture (from its live stream or an alert) and its latest
/// event, written by the app into the app group, read by the widget.
enum MacCameraShare {
    static let kind = "com.woodruff.family.widget.mactvscameras"

    struct Line: Codable, Identifiable, Equatable {
        var id: String
        var name: String
        var doorbell: Bool
        var file: String?
        var at: Date?
        var event: String?
        var eventAt: Date?
    }

    static var container: URL? {
        SharedStore.groupID.flatMap { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) }
    }

    static func load() -> [Line] {
        guard let d = SharedStore.defaults?.data(forKey: "cameras") else { return [] }
        return (try? JSONDecoder().decode([Line].self, from: d)) ?? []
    }

    static func picture(_ line: Line) -> Data? {
        guard let f = line.file, let url = container?.appendingPathComponent(f) else { return nil }
        return try? Data(contentsOf: url)
    }

    /// Keeps [jpeg] as [id]'s latest picture and/or [event] as its latest event. True when something changed.
    @discardableResult
    static func save(id: String, name: String, doorbell: Bool, jpeg: Data? = nil, event: String? = nil) -> Bool {
        guard let defaults = SharedStore.defaults else { return false }
        var all = load()
        var line = all.first { $0.id == id } ?? Line(id: id, name: name, doorbell: doorbell)
        line.name = name
        line.doorbell = doorbell
        if let jpeg, let dir = container {
            let safe = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "camera"
            let name = "cam-" + String(safe.suffix(80)) + ".jpg"
            guard (try? jpeg.write(to: dir.appendingPathComponent(name), options: .atomic)) != nil else { return false }
            line.file = name
            line.at = Date()
        }
        if let event {
            line.event = event
            line.eventAt = Date()
        }
        all.removeAll { $0.id == id }
        all.append(line)
        guard let data = try? JSONEncoder().encode(all) else { return false }
        defaults.set(data, forKey: "cameras")
        return true
    }
}
