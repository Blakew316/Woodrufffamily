import Foundation

/// What the iPhone app hands its Home Screen and Lock Screen widgets, through the app group: what's playing (and
/// its picture), the weather and the thermostat. Without the app group (signing that doesn't carry it yet) there
/// is no container, nothing is written, and the widgets say to open the app.
enum PhoneWidgetShare {
    static let groupID = "group.com.woodruff.family"
    static let nowPlayingKind = "com.woodruff.family.widget.nowplaying"
    static let homeKind = "com.woodruff.family.widget.home"
    static let tvsCamerasKind = "com.woodruff.family.widget.tvscameras"

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
        /// Every TV, in the app's order, with what each is playing.
        var tvs: [TVLine]? = nil
        /// When the app last checked all this (nil: written by an older build). Not part of "what changed".
        var savedAt: Date? = nil
        /// The TV the remote is on.
        var selectedTV: String? = nil

        static func == (a: Snapshot, b: Snapshot) -> Bool { a.sameContent(b) }

        private func sameContent(_ o: Snapshot) -> Bool {
            tvName == o.tvName && title == o.title && detail == o.detail && isPlaying == o.isPlaying && art == o.art
                && weatherTemp == o.weatherTemp && weatherSymbol == o.weatherSymbol && weatherWords == o.weatherWords
                && highLow == o.highLow && thermostatName == o.thermostatName && thermostatTemp == o.thermostatTemp
                && thermostatSet == o.thermostatSet && thermostatAction == o.thermostatAction && tvs == o.tvs
                && selectedTV == o.selectedTV
        }

        /// What the TVs were doing is too old to show as now: the app hasn't run for a while (it only writes this while
        /// it runs, so a title it saw playing last night would otherwise still show as playing).
        func tvsStale(at date: Date) -> Bool {
            guard let savedAt else { return false }
            return date.timeIntervalSince(savedAt) > PhoneWidgetShare.staleAfter
        }
    }

    /// How long what the TVs were playing is shown without the app checking again.
    static let staleAfter: TimeInterval = 3 * 3600

    /// One TV on the Now Playing widget.
    struct TVLine: Codable, Equatable, Identifiable {
        var id: String
        var name: String
        var online: Bool
        /// What's on it (nil: nothing).
        var title: String?
        var isPlaying: Bool
        /// Its title's picture in the container.
        var art: String? = nil
        /// How far through it is (0–1), and the time left ("14m", "1h 34m").
        var progress: Double? = nil
        var left: String? = nil
    }

    /// One camera on the TVs & Cameras widget: its latest still (a file in the container), when it was taken, and the
    /// last thing it saw.
    struct CameraLine: Codable, Equatable, Identifiable {
        var id: String
        var name: String
        var doorbell: Bool
        var file: String?
        var at: Date?
        var event: String?
        var eventAt: Date?
    }

    static func loadCameras() -> [CameraLine] {
        guard let url = container?.appendingPathComponent("cameras.json"), let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([CameraLine].self, from: data)) ?? []
    }

    /// Keeps a camera's latest still ([jpeg]) and/or its latest event for the widget. True when the widget should
    /// reload (an event, or a still and the last reload for stills was over a minute ago).
    @discardableResult
    static func saveCamera(id: String, name: String, doorbell: Bool, jpeg: Data? = nil, event: String? = nil) -> Bool {
        guard let dir = container else { return false }
        var all = loadCameras()
        var line = all.first { $0.id == id } ?? CameraLine(id: id, name: name, doorbell: doorbell)
        line.name = name
        line.doorbell = doorbell
        if let jpeg {
            let hash = id.utf8.reduce(UInt64(5381)) { ($0 &* 33) &+ UInt64($1) }
            let file = "cam-\(hash % 100_000_000).jpg"
            guard (try? jpeg.write(to: dir.appendingPathComponent(file), options: .atomic)) != nil else { return false }
            line.file = file
            line.at = Date()
        }
        if let event {
            line.event = event
            line.eventAt = Date()
        }
        all.removeAll { $0.id == id }
        all.append(line)
        guard let data = try? JSONEncoder().encode(all),
              (try? data.write(to: dir.appendingPathComponent("cameras.json"), options: .atomic)) != nil else { return false }
        if event != nil { lastStillReload = Date(); return true }
        if Date().timeIntervalSince(lastStillReload) > 60 { lastStillReload = Date(); return true }
        return false
    }

    nonisolated(unsafe) private static var lastStillReload = Date.distantPast

    static var container: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)
    }

    static func load() -> Snapshot? {
        guard let url = container?.appendingPathComponent("widgets.json"), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    /// Writes it (with the time, so the widgets know how fresh it is); false when nothing they show changed (or
    /// there's no app group), so the widgets needn't reload.
    @discardableResult
    static func save(_ s: Snapshot) -> Bool {
        guard let url = container?.appendingPathComponent("widgets.json") else { return false }
        var s = s
        s.savedAt = Date()
        let old = load()
        // Unchanged: only the time is brought up to date, and only now and then (no reload needed for it).
        if let old, old == s, let at = old.savedAt, Date().timeIntervalSince(at) < 600 { return false }
        guard let data = try? JSONEncoder().encode(s) else { return false }
        let wrote = (try? data.write(to: url, options: .atomic)) != nil
        // An older entry that had gone stale (or had no time) is fresh again: the widgets reload for that too.
        let wasStale = old.map { $0.savedAt == nil || $0.tvsStale(at: Date()) } ?? true
        return wrote && (old != s || wasStale)
    }

    /// What a widget says before it has anything: without the app group there is nothing opening the app would fix.
    static var emptyText: String { container == nil ? "Ready after the next update" : "Open Woodruff once" }

    static func artURL(_ name: String) -> URL? { container?.appendingPathComponent(name) }
}
