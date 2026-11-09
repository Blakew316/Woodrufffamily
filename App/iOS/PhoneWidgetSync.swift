import Foundation
import UIKit
import WidgetKit
import BackgroundTasks
import ImageIO
import UniformTypeIdentifiers
import WoodruffKit

/// Keeps the iPhone's Home Screen widgets in step with the app: what the remote's TV is playing, the weather and the
/// thermostat. Changes are gathered for a couple of seconds (a burst that keeps going still writes within about six),
/// and the widgets reload only when what they show has changed. Going into the background writes at once (a write
/// still waiting would otherwise wait until the app is next opened), and coming back after a while brings the
/// cameras' pictures up to date straight away.
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

    /// The camera widgets reload now.
    static func reloadCameras() {
        cameraReload?.cancel()
        cameraReload = nil
        lastCameraReload = Date()
        WidgetCenter.shared.reloadTimelines(ofKind: PhoneWidgetShare.tvsCamerasKind)
        WidgetCenter.shared.reloadTimelines(ofKind: PhoneWidgetShare.doorbellKind)
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
        let away = awayAt.map { Date().timeIntervalSince($0) } ?? 0
        awayAt = nil
        guard away > 60 else { return }
        Task { @MainActor in
            if await CameraStillPull.run() > 0 { reloadCameras() }
        }
    }

    /// Writes it now (a widget's or the Lock Screen's button has just changed what's playing).
    static func write(_ fleet: Fleet) async {
        guard PhoneWidgetShare.container != nil else { return }
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
        if PhoneWidgetShare.save(s) { WidgetCenter.shared.reloadAllTimelines() }
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

    /// How many cameras got a new picture.
    @discardableResult
    static func run() async -> Int {
        guard !running, !Demo.isOn, NestCameras.shared.connected, let token = CameraShareKey.token() else { return 0 }
        let hosts = (UserDefaults.standard.string(forKey: CameraShareKey.hostsKey) ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty }
        let cams = NestCameras.shared.cameras.filter { $0.online }
        guard !hosts.isEmpty, let first = cams.first else { return 0 }
        running = true
        defer { running = false }
        // The first camera finds the address that answers (home, or Tailscale away from home); the rest go at once.
        let order = (good.map { [$0] } ?? []) + hosts.filter { $0 != good }
        var got: [String: Data] = [:]
        var host: String?
        for h in order {
            if let d = await fetch(h, first.id, token) { host = h; got[first.id] = d; break }
        }
        guard let host else { return 0 }
        good = host
        let rest = cams.dropFirst().map(\.id)
        await withTaskGroup(of: (String, Data?).self) { g in
            for id in rest { g.addTask { (id, await CameraStillPull.fetch(host, id, token)) } }
            for await pair in g { if let d = pair.1 { got[pair.0] = d } }
        }
        var count = 0
        for cam in cams {
            guard let jpeg = got[cam.id] else { continue }
            CameraStreams.shared.keepStill(cam, jpeg)
            PhoneWidgetShare.saveCamera(id: cam.id, name: cam.name, doorbell: cam.doorbell, jpeg: jpeg)
            count += 1
        }
        return count
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

/// Closed a while: iOS wakes the app now and then (about every quarter hour at most, as it sees fit) to bring the
/// widgets up to date: what the TVs are doing and the cameras' latest pictures.
@MainActor
enum WidgetRefresh {
    static let id = "com.woodruff.family.widgets"

    static func schedule() {
        let r = BGAppRefreshTaskRequest(identifier: id)
        r.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(r)
    }

    static func run() async {
        guard !Demo.isOn, PhoneWidgetShare.container != nil else { return }
        let fleet = Fleet.shared
        if await CameraStillPull.run() > 0 { PhoneWidgetSync.reloadCameras() }
        // Only with the TVs at hand (a launch into the background with the phone locked may not have them yet):
        // never an empty list over what the widgets show.
        guard !fleet.hubs.isEmpty, !fleet.tvs.isEmpty else { return }
        await fleet.refresh()
        await PhoneWidgetSync.write(fleet)
    }
}
