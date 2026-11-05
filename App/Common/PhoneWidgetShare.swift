import Foundation

/// What the iPhone app hands its Home Screen and Lock Screen widgets, through the app group: what's playing (and
/// its picture), the weather and the thermostat. Without the app group (signing that doesn't carry it yet) there
/// is no container, nothing is written, and the widgets say to open the app.
enum PhoneWidgetShare {
    static let groupID = "group.com.woodruff.family"
    static let nowPlayingKind = "com.woodruff.family.widget.nowplaying"
    static let homeKind = "com.woodruff.family.widget.home"

    struct Snapshot: Codable, Equatable {
        var tvName: String?
        var title: String?
        var detail: String?
        var isPlaying = false
        /// The picture's name in the container (changes with the title, so a widget never shows an old one).
        var art: String?
        var weatherTemp: String?
        var weatherSymbol: String?
        var weatherWords: String?
        var highLow: String?
        var thermostatName: String?
        var thermostatTemp: String?
        var thermostatSet: String?
        /// heating / cooling / idle / off.
        var thermostatAction: String?
    }

    static var container: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)
    }

    static func load() -> Snapshot? {
        guard let url = container?.appendingPathComponent("widgets.json"), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    /// Writes it; false when nothing changed (or there's no app group).
    @discardableResult
    static func save(_ s: Snapshot) -> Bool {
        guard let url = container?.appendingPathComponent("widgets.json") else { return false }
        if load() == s { return false }
        guard let data = try? JSONEncoder().encode(s) else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    /// What a widget says before it has anything: without the app group there is nothing opening the app would fix.
    static var emptyText: String { container == nil ? "Ready after the next update" : "Open Woodruff once" }

    static func artURL(_ name: String) -> URL? { container?.appendingPathComponent(name) }
}
