import Foundation
import WidgetKit

/// What the iPhone app hands its Home Screen and Lock Screen widgets, through the app group: what's playing (and
/// its picture), the weather and the thermostat. Without the app group (signing that doesn't carry it yet) there
/// is no container, nothing is written, and the widgets say to open the app.
///
/// iOS allows each widget only so many reloads a day (about 40 to 70) while Woodruff isn't in front, and a camera
/// alert needs one to show on the widget: so a widget is reloaded only when something it shows has changed.
enum PhoneWidgetShare {
    static let groupID = "group.com.woodruff.family"
    static let nowPlayingKind = "com.woodruff.family.widget.nowplaying"
    static let homeKind = "com.woodruff.family.widget.home"
    static let tvsCamerasKind = "com.woodruff.family.widget.tvscameras"
    /// The Lock Screen's doorbell: its latest picture and event.
    static let doorbellKind = "com.woodruff.family.widget.doorbell"

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
        /// The TV the remote is on. No widget marks it any more, so it isn't part of "what changed" either.
        var selectedTV: String? = nil

        static func == (a: Snapshot, b: Snapshot) -> Bool { a.sameTVs(b) && a.sameHome(b) }

        /// What the TVs and TVs & Cameras widgets show of it is the same.
        func sameTVs(_ o: Snapshot) -> Bool { sameTVsButTimes(o) && tvs == o.tvs }

        /// The same, but perhaps for how far through each TV is and its time left: those change every minute while
        /// something plays, and only TVs & Cameras shows them.
        func sameTVsButTimes(_ o: Snapshot) -> Bool {
            func untimed(_ lines: [TVLine]?) -> [TVLine]? { lines?.map { var t = $0; t.progress = nil; t.left = nil; return t } }
            return tvName == o.tvName && title == o.title && detail == o.detail && isPlaying == o.isPlaying && art == o.art
                && untimed(tvs) == untimed(o.tvs)
        }

        /// What the Home widget shows of it (the weather and the thermostat) is the same.
        func sameHome(_ o: Snapshot) -> Bool {
            weatherTemp == o.weatherTemp && weatherSymbol == o.weatherSymbol && weatherWords == o.weatherWords
                && highLow == o.highLow && thermostatName == o.thermostatName && thermostatTemp == o.thermostatTemp
                && thermostatSet == o.thermostatSet && thermostatAction == o.thermostatAction
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

    /// The two cameras the TVs & Cameras widget shows: the doorbell, then the driveway (by name), else the first two.
    static func shownCameras(_ cameras: [CameraLine]) -> [CameraLine] {
        let door = doorbell(cameras)
        let drive = cameras.first { $0.name.localizedCaseInsensitiveContains("drive") && $0.id != door?.id }
        var out = [door, drive].compactMap { $0 }
        for c in cameras where out.count < 2 && !out.contains(where: { $0.id == c.id }) { out.append(c) }
        return out
    }

    /// The doorbell, which the Lock Screen's doorbell widget shows (else the first camera named for a door).
    static func doorbell(_ cameras: [CameraLine]) -> CameraLine? {
        cameras.first { $0.doorbell } ?? cameras.first { $0.name.localizedCaseInsensitiveContains("door") }
    }

    /// The camera widgets that show any of [cameras]: TVs & Cameras its two, the Lock Screen's the doorbell.
    static func widgets(showing cameras: Set<String>) -> Set<String> {
        guard !cameras.isEmpty else { return [] }
        let all = loadCameras()
        var kinds: Set<String> = []
        if shownCameras(all).contains(where: { cameras.contains($0.id) }) { kinds.insert(tvsCamerasKind) }
        if let door = doorbell(all), cameras.contains(door.id) { kinds.insert(doorbellKind) }
        return kinds
    }

    /// The cameras the camera widgets show, which the Mac Studio's push after an alert goes for (an alert from any
    /// other changes nothing on them, and each push uses up their reloads).
    static func camerasOnWidgets() -> [String] {
        let all = loadCameras()
        var ids = shownCameras(all).map(\.id)
        if let door = doorbell(all), !ids.contains(door.id) { ids.append(door.id) }
        return ids
    }

    /// An alert's tag or picture for [camera] was saved: only the widgets that show that camera reload for it (an
    /// alert from a camera neither shows would use up their reloads for nothing).
    static func reloadWidgets(showing camera: String) {
        for kind in widgets(showing: [camera]) { WidgetCenter.shared.reloadTimelines(ofKind: kind) }
    }

    /// Keeps a camera's latest still ([jpeg]) and/or its latest event for the widget. True when the widget should
    /// reload (an event, or a still and the last reload for stills was over a minute ago).
    @discardableResult
    static func saveCamera(id: String, name: String, doorbell: Bool, jpeg: Data? = nil, event: String? = nil) -> Bool {
        guard let dir = container else { return false }
        let list = dir.appendingPathComponent("cameras.json")
        var saved = false
        // The app and the alerts' extension can both write the list at once: one at a time, so neither loses the
        // other's picture or tag.
        NSFileCoordinator().coordinate(writingItemAt: list, options: [], error: nil) { _ in
            var all = loadCameras()
            var line = all.first { $0.id == id } ?? CameraLine(id: id, name: name, doorbell: doorbell)
            line.name = name
            line.doorbell = doorbell
            if let jpeg {
                let hash = id.utf8.reduce(UInt64(5381)) { ($0 &* 33) &+ UInt64($1) }
                let file = "cam-\(hash % 100_000_000).jpg"
                guard (try? jpeg.write(to: dir.appendingPathComponent(file), options: .atomic)) != nil else { return }
                line.file = file
                line.at = Date()
            }
            if let event {
                line.event = event
                line.eventAt = Date()
            }
            // In its place: past the doorbell and the driveway the widget shows the first cameras in the list, so a
            // save never changes which ones (an alert from a camera it doesn't show then never needs a reload).
            if let i = all.firstIndex(where: { $0.id == id }) { all[i] = line } else { all.append(line) }
            guard let data = try? JSONEncoder().encode(all), (try? data.write(to: list, options: .atomic)) != nil else { return }
            saved = true
        }
        guard saved else { return false }
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

    /// Writes it (with the time, so the widgets know how fresh it is) and gives the widgets to reload: [changed], those
    /// whose part of it changed (the TVs for the TVs and TVs & Cameras widgets, the weather and the thermostat for
    /// Home), and [timesOnly], TVs & Cameras when all that changed is how far through the TVs are and their time left,
    /// which can wait (the TVs widget doesn't show them). Neither when nothing they show changed, or there's no app
    /// group.
    static func save(_ s: Snapshot) -> (changed: Set<String>, timesOnly: Set<String>) {
        guard let url = container?.appendingPathComponent("widgets.json") else { return ([], []) }
        var s = s
        let now = Date()
        s.savedAt = now
        let old = load()
        // Unchanged: only the time is brought up to date, and only now and then. No reload for it: the widgets read it
        // again by themselves a few minutes before what they last read would be too old to show.
        if let old, old == s, let at = old.savedAt, now.timeIntervalSince(at) < 600 { return ([], []) }
        guard let data = try? JSONEncoder().encode(s), (try? data.write(to: url, options: .atomic)) != nil else { return ([], []) }
        guard let old else { return ([nowPlayingKind, homeKind, tvsCamerasKind], []) }
        var changed: Set<String> = []
        var timesOnly: Set<String> = []
        // An older entry that had gone stale (or had no time) is fresh again: the TV widgets reload for that too.
        if !old.sameTVsButTimes(s) || old.savedAt == nil || old.tvsStale(at: now) {
            changed.formUnion([nowPlayingKind, tvsCamerasKind])
        } else if old.tvs != s.tvs {
            timesOnly.insert(tvsCamerasKind)
        }
        if !old.sameHome(s) { changed.insert(homeKind) }
        return (changed, timesOnly)
    }

    // MARK: The camera widgets' push address

    /// Kept by the camera widgets' push handler (WidgetKit gives it to the widgets, not the app): the app hands it to
    /// the Macs, and the Mac Studio reloads the camera widgets with a push a moment after each alert from a camera
    /// they show. Nil when none of them is on the Home Screen or Lock Screen.
    static func saveWidgetPushToken(_ token: Data?) {
        guard let url = container?.appendingPathComponent("widget-push.txt") else { return }
        if let token, !token.isEmpty {
            try? Data(hex(token).utf8).write(to: url, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// The camera widgets' push address as kept, in hex (as the Macs send to it).
    static func widgetPushToken() -> String? {
        guard let url = container?.appendingPathComponent("widget-push.txt"), let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8), !text.isEmpty, text.allSatisfy(\.isHexDigit) else { return nil }
        return text
    }

    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    /// What a widget says before it has anything: without the app group there is nothing opening the app would fix.
    static var emptyText: String { container == nil ? "Ready after the next update" : "Open Woodruff once" }

    static func artURL(_ name: String) -> URL? { container?.appendingPathComponent(name) }
}
