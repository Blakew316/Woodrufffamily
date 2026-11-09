import Foundation
import UIKit
import WidgetKit
import BackgroundTasks
import ImageIO
import UniformTypeIdentifiers
import WoodruffKit

/// Keeps the iPhone's Home Screen widgets in step with the app: what the remote's TV is playing, the weather and the
/// thermostat. Changes are gathered for a couple of seconds (a burst that keeps going still writes within about six),
/// and only the widgets whose part changed reload. Going into the background writes at once (a write still waiting
/// would otherwise wait until the app is next opened), and coming back after a while brings the cameras' pictures up
/// to date straight away.
@MainActor
enum PhoneWidgetSync {
    private static var pending: Task<Void, Never>?
    /// When the write waiting to go was first asked for.
    private static var firstAsked: Date?
    /// The fleet last handed over (written from it when the app goes into the background).
    private static var fleet: Fleet?
    private static var observers: [NSObjectProtocol] = []
    /// When the app went into the background.
    private static var awayAt: Date?
    private static var hold: UIBackgroundTaskIdentifier = .invalid

    static func update(_ fleet: Fleet) {
        guard PhoneWidgetShare.container != nil else { return }
        self.fleet = fleet
        watch()
        let now = Date()
        // Changes that keep coming don't hold the widgets back for ever: the write already waiting goes.
        if pending != nil, let f = firstAsked, now.timeIntervalSince(f) > 4 { return }
        if firstAsked == nil { firstAsked = now }
        pending?.cancel()
        pending = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            PhoneWidgetSync.pending = nil
            PhoneWidgetSync.firstAsked = nil
            await write(fleet)
        }
    }

    // MARK: Cameras

    private static var cameraReload: Task<Void, Never>?
    private static var lastCameraReload = Date.distantPast

    /// A camera's picture or event in the app group changed: the camera widgets reload a couple of seconds later, at
    /// most every half minute (the latest picture always gets there).
    static func camerasChanged() {
        guard PhoneWidgetShare.container != nil else { return }
        watch()
        guard cameraReload == nil else { return }
        let wait = max(2, 30 - Date().timeIntervalSince(lastCameraReload))
        cameraReload = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard !Task.isCancelled else { return }
            PhoneWidgetSync.cameraReload = nil
            reloadCameras()
        }
    }

    /// The camera widgets reload now (in the background, for newer pictures only when their time has come).
    static func reloadCameras() {
        cameraReload?.cancel()
        cameraReload = nil
        lastCameraReload = Date()
        reload([PhoneWidgetShare.tvsCamerasKind: .pictures, PhoneWidgetShare.doorbellKind: .pictures])
    }

    /// What a widget reloads for, which decides how soon a camera widget's reload goes while Woodruff is in the
    /// background. There each reload counts against the widget's daily allowance from iOS (in front they're free), and
    /// the camera widgets need theirs for the camera alerts, which reload them the moment they come (the alert's
    /// add-on, then the Mac Studio's push).
    enum Why: Int {
        /// Only newer pictures from the cameras: a camera widget at most every two hours (it reads the newest by
        /// itself every few hours, and each alert brings its own).
        case pictures
        /// Only how far through the TVs are and their time left (every minute while something plays): at most every
        /// half hour.
        case times
        /// What the family would notice (a new title, play or pause, a TV going off, the remote's TV), or a button
        /// they pressed: at once.
        case change

        /// The least time from a camera widget's last reload in the background to one for this.
        var gap: TimeInterval {
            switch self {
            case .pictures: return 2 * 3600
            case .times: return 30 * 60
            case .change: return 0
            }
        }
    }

    /// Reloads these widgets, each for what changed in it. In the background a camera widget reloads at once only for
    /// a change the family would notice; for newer pictures or TV times alone it waits until that one's gap since its
    /// last reload there is up. One put off then goes when its time comes: from a timer while the app is still
    /// running, else at the next background refresh (asked for by then), or as soon as Woodruff is in front.
    static func reload(_ kinds: [String: Why]) {
        let d = UserDefaults.standard
        let owed = d.dictionary(forKey: owedKey) as? [String: Double] ?? [:]
        let away = UIApplication.shared.applicationState == .background
        let now = Date().timeIntervalSince1970
        var stillOwed: [String: Double] = [:]
        for kind in Set(kinds.keys).union(owed.keys) {
            if away, kind == PhoneWidgetShare.tvsCamerasKind || kind == PhoneWidgetShare.doorbellKind {
                let key = "widgets.reloadedAway." + kind
                if kinds[kind] != .change {
                    // Due once its gap after the last reload out here is up, or when one put off before is due.
                    let last = min(d.double(forKey: key), now)
                    let due = min(owed[kind] ?? .infinity, kinds[kind].map { last + $0.gap } ?? .infinity)
                    if now < due { stillOwed[kind] = due; continue }
                }
                d.set(now, forKey: key)
            }
            WidgetCenter.shared.reloadTimelines(ofKind: kind)
        }
        if stillOwed != owed { d.set(stillOwed, forKey: owedKey) }
        if let first = stillOwed.values.min() { remind(at: first) }
    }

    /// The camera widgets whose reload was put off, with when each is due.
    private static let owedKey = "widgets.owedReloads"

    /// When the first camera widget reload put off in the background is due, if one is.
    static var owedDue: Date? {
        (UserDefaults.standard.dictionary(forKey: owedKey) as? [String: Double])?.values.min().map { Date(timeIntervalSince1970: $0) }
    }

    /// The timer for a reload put off, and when it fires.
    private static var reminder: Task<Void, Never>?
    private static var reminderAt: Double?

    /// A camera widget's reload is put off until [due]: a timer for then while the app still runs (iOS suspends it
    /// with the app), and the background refresh asked for by then.
    private static func remind(at due: Double) {
        guard reminderAt != due else { return }
        reminderAt = due
        reminder?.cancel()
        reminder = Task { @MainActor in
            let wait = min(max(1, due - Date().timeIntervalSince1970), 3 * 3600)
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard !Task.isCancelled else { return }
            PhoneWidgetSync.reminder = nil
            PhoneWidgetSync.reminderAt = nil
            reload([:])
        }
        WidgetRefresh.schedule()
    }

    // MARK: Background and back

    private static func watch() {
        guard observers.isEmpty else { return }
        let c = NotificationCenter.default
        observers.append(c.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { PhoneWidgetSync.leaving() }
        })
        observers.append(c.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { PhoneWidgetSync.returning() }
        })
        // In front: a camera widget reload put off in the background goes now (free in front).
        observers.append(c.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { PhoneWidgetSync.reload([:]) }
        })
        // The camera widgets' push address to the Macs (it can change while Woodruff is closed).
        WidgetPushToken.check()
        reload([:])
    }

    /// Into the background: what's waiting is written now, with a little time asked for to finish.
    private static func leaving() {
        awayAt = Date()
        if cameraReload != nil { reloadCameras() }
        pending?.cancel()
        pending = nil
        firstAsked = nil
        guard let fleet = PhoneWidgetSync.fleet, PhoneWidgetShare.container != nil else { return }
        // Written even with nothing waiting: it's only saved, and the widgets reloaded, when something they show changed.
        endHold()
        hold = UIApplication.shared.beginBackgroundTask(withName: "Woodruff widgets") {
            MainActor.assumeIsolated { PhoneWidgetSync.endHold() }
        }
        Task { @MainActor in
            await write(fleet)
            PhoneWidgetSync.endHold()
        }
    }

    private static func endHold() {
        guard hold != .invalid else { return }
        UIApplication.shared.endBackgroundTask(hold)
        hold = .invalid
    }

    /// Back after more than a minute away: the cameras' latest pictures, from the Mac Studio, straight away (the
    /// tiles show them while their streams reconnect, and the widgets get them too).
    private static func returning() {
        WidgetPushToken.check()
        let away = awayAt.map { Date().timeIntervalSince($0) } ?? 0
        awayAt = nil
        guard away > 60 else { return }
        Task { @MainActor in
            let fresh = await CameraStillPull.run()
            if !fresh.isEmpty { reloadCameras() }
        }
    }

    /// The write going now, if any: writes go one after another (one clearing out old pictures could otherwise delete
    /// one another has just saved but not yet handed over).
    private static var writing: Task<[String: Why], Never>?

    /// Writes it now and reloads the widgets whose part changed. [now]: a button the family pressed (a widget's or the
    /// Lock Screen's) has just changed what's playing, so they show it at once, with Woodruff in the background too.
    static func write(_ fleet: Fleet, now: Bool = false) async {
        let kinds = await written(fleet)
        reload(now ? kinds.mapValues { _ in Why.change } : kinds)
    }

    /// Writes it now and gives the widgets whose part changed, with what for, for the caller to reload.
    static func written(_ fleet: Fleet) async -> [String: Why] {
        guard PhoneWidgetShare.container != nil else { return [:] }
        let previous = writing
        let task = Task { @MainActor () -> [String: Why] in
            _ = await previous?.value
            return await writeNow(fleet)
        }
        writing = task
        let kinds = await task.value
        if writing == task { writing = nil }
        return kinds
    }

    private static func writeNow(_ fleet: Fleet) async -> [String: Why] {
        var s = PhoneWidgetShare.Snapshot()
        if let tv = fleet.selected {
            s.tvName = tv.name
            if let p = tv.nowPlaying {
                s.title = p.title
                s.detail = [p.subtitle, p.app].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
                s.isPlaying = p.isPlaying
                s.art = await art(fleet, p)
            }
        }
        s.selectedTV = fleet.selected?.id
        var lines: [PhoneWidgetShare.TVLine] = []
        var keep: Set<String> = []
        if let a = s.art { keep.insert(a) }
        for tv in fleet.tvs where !tv.isUnpaired {
            var line = PhoneWidgetShare.TVLine(id: tv.id, name: tv.name, online: tv.online, title: tv.nowPlaying?.title, isPlaying: tv.nowPlaying?.isPlaying ?? false)
            if let p = tv.nowPlaying {
                if let pr = p.progress { line.progress = (pr * 50).rounded() / 50 }
                line.left = timeLeft(position: p.position, duration: p.duration).map { $0.replacingOccurrences(of: " left", with: "") }
                line.art = await art(fleet, p)
                if let a = line.art { keep.insert(a) }
            }
            lines.append(line)
        }
        s.tvs = lines
        // Only the pictures something shows now are kept.
        if let dir = PhoneWidgetShare.container {
            for old in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where old.hasPrefix("art-") && !keep.contains(old) {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(old))
            }
        }
        if let w = HomeWeather.shared.now {
            s.weatherTemp = w.tempText
            s.weatherSymbol = w.sky.symbol
            s.weatherWords = w.sky.words
            if let h = w.high, let l = w.low { s.highLow = "H \(Int(h.rounded()))°  L \(Int(l.rounded()))°" }
        }
        if let t = AccessoryStore.shared.thermostat {
            s.thermostatName = t.name
            s.thermostatTemp = t.temperature.map(temperatureText)
            let set = t.thermostatMode == "cool" ? (t.coolTo ?? t.target) : (t.heatTo ?? t.target)
            s.thermostatSet = t.thermostatMode == "off" ? "Off" : set.map(temperatureText)
            s.thermostatAction = t.thermostatMode == "off" ? "off" : t.action
        }
        // Only the widgets whose part changed (the doorbell's shows only its camera, reloaded with the cameras).
        let saved = PhoneWidgetShare.save(s)
        var kinds: [String: Why] = [:]
        for kind in saved.timesOnly { kinds[kind] = .times }
        for kind in saved.changed { kinds[kind] = .change }
        return kinds
    }

    /// Saves a small copy of the title's picture in the app group (once per title) and gives its name.
    private static func art(_ fleet: Fleet, _ p: NowPlaying) async -> String? {
        let a = fleet.artwork(for: p)
        guard let path = a?.poster ?? a?.backdrop, let url = fleet.hubClient()?.art(path) else { return nil }
        // A name that stays the same from launch to launch for the same picture.
        let hash = url.absoluteString.utf8.reduce(UInt64(5381)) { ($0 &* 33) &+ UInt64($1) }
        let name = "art-" + String(hash % 100_000_000) + ".jpg"
        if let file = PhoneWidgetShare.artURL(name), FileManager.default.fileExists(atPath: file.path) { return name }
        guard let image = await ImageStore.shared.image(url, maxPixel: 300),
              let data = image.jpegData(compressionQuality: 0.8),
              let file = PhoneWidgetShare.artURL(name) else { return nil }
        guard (try? data.write(to: file, options: .atomic)) != nil else { return nil }
        return name
    }
}

/// The cameras' latest pictures, from the Mac Studio (which keeps every camera live and hands their pictures to the
/// family's Apple TVs, `CameraShare`): the iPhone's own pictures come only from a stream it's playing, so with the
/// app in the background they stop. Asked on coming back after a while, and by the background refresh.
@MainActor
enum CameraStillPull {
    /// The address that answered last, tried first next time.
    private static var good: String?
    private static var running = false

    /// The cameras that got a new picture.
    @discardableResult
    static func run() async -> Set<String> {
        guard !running, !Demo.isOn, NestCameras.shared.connected, let token = CameraShareKey.token() else { return [] }
        let hosts = (UserDefaults.standard.string(forKey: CameraShareKey.hostsKey) ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty }
        // The notification extension asks the Mac Studio for each alert's picture with these too.
        CameraEventMedia.keepShare(token: token, hosts: hosts.joined(separator: ","))
        let cams = NestCameras.shared.cameras.filter { $0.online }
        guard !hosts.isEmpty, let first = cams.first else { return [] }
        running = true
        defer { running = false }
        // The first camera finds the address that answers (home, or Tailscale away from home); the rest go at once.
        let order = (good.map { [$0] } ?? []) + hosts.filter { $0 != good }
        var got: [String: Data] = [:]
        var host: String?
        for h in order {
            if let d = await fetch(h, first.id, token) { host = h; got[first.id] = d; break }
        }
        guard let host else { return [] }
        good = host
        let rest = cams.dropFirst().map(\.id)
        await withTaskGroup(of: (String, Data?).self) { g in
            for id in rest { g.addTask { (id, await CameraStillPull.fetch(host, id, token)) } }
            for await pair in g { if let d = pair.1 { got[pair.0] = d } }
        }
        var fresh: Set<String> = []
        for cam in cams {
            guard let jpeg = got[cam.id] else { continue }
            CameraStreams.shared.keepStill(cam, jpeg)
            PhoneWidgetShare.saveCamera(id: cam.id, name: cam.name, doorbell: cam.doorbell, jpeg: jpeg)
            fresh.insert(cam.id)
        }
        return fresh
    }

    /// [id]'s picture now from the Mac Studio at [host], made at most 480 pixels across (as the iPhone's own are).
    nonisolated private static func fetch(_ host: String, _ id: String, _ token: String) async -> Data? {
        var c = URLComponents()
        c.scheme = "http"; c.host = host; c.port = Int(CameraShareKey.port); c.path = "/still"
        c.queryItems = [URLQueryItem(name: "id", value: id), URLQueryItem(name: "k", value: token)]
        guard let url = c.url else { return nil }
        var r = URLRequest(url: url)
        r.timeoutInterval = 3
        guard let (d, resp) = try? await URLSession.shared.data(for: r),
              (resp as? HTTPURLResponse)?.statusCode == 200, d.count > 500 else { return nil }
        return shrink(d, maxSide: 480)
    }

    nonisolated private static func shrink(_ data: Data, maxSide: Int) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: maxSide]
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}

/// Closed a while: iOS wakes the app now and then (about every quarter hour at most, as it sees fit, or sooner for a
/// camera widget's reload put off until then) to bring the widgets up to date: what the TVs are doing and the cameras'
/// latest pictures.
@MainActor
enum WidgetRefresh {
    static let id = "com.woodruff.family.widgets"

    static func schedule() {
        let r = BGAppRefreshTaskRequest(identifier: id)
        // In a quarter of an hour at the earliest, or sooner when a camera widget's reload put off is due by then.
        let next = Date(timeIntervalSinceNow: 15 * 60)
        r.earliestBeginDate = PhoneWidgetSync.owedDue.map { min(next, max($0, Date())) } ?? next
        try? BGTaskScheduler.shared.submit(r)
    }

    static func run() async {
        guard !Demo.isOn, PhoneWidgetShare.container != nil else { return }
        WidgetPushToken.check()
        let fleet = Fleet.shared
        // The cameras' pictures and the TVs first, then one reload of each widget whose part changed (two in a row
        // would use up two of its reloads). For newer pictures, only the widgets that show those cameras.
        var kinds: [String: PhoneWidgetSync.Why] = [:]
        let fresh = await CameraStillPull.run()
        for kind in PhoneWidgetShare.widgets(showing: fresh) { kinds[kind] = .pictures }
        // Only with the TVs at hand (a launch into the background with the phone locked may not have them yet):
        // never an empty list over what the widgets show.
        if !fleet.hubs.isEmpty, !fleet.tvs.isEmpty {
            await fleet.refresh()
            let tvs = await PhoneWidgetSync.written(fleet)
            kinds.merge(tvs) { $0.rawValue >= $1.rawValue ? $0 : $1 }
        }
        PhoneWidgetSync.reload(kinds)
    }
}

/// The camera widgets' push address (WidgetKit's), handed to the Macs with this iPhone's alert address (the synced
/// settings carry both), with the cameras those widgets show: a moment after an alert from one of them the Mac Studio
/// sends a push to it, and iOS reloads the camera widgets then, with the event and its picture already saved for them
/// by the alert's add-on, even with Woodruff closed. Looked at on launch, on coming back and at each background
/// refresh (the widgets keep the newest address in the app group meanwhile).
@MainActor
enum WidgetPushToken {
    static func check() {
        guard !Demo.isOn, PhoneWidgetShare.container != nil else { return }
        Task { @MainActor in
            // WidgetKit's own copy first: none until it has made one, or with no camera widget set up.
            let current = await WidgetCenter.shared.currentPushInfo?.token
            PushRelay.shared.setWidgetToken(current.map(PhoneWidgetShare.hex) ?? PhoneWidgetShare.widgetPushToken(),
                                            cameras: PhoneWidgetShare.camerasOnWidgets())
        }
    }
}
