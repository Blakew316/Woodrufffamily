import SwiftUI
import UIKit
import ImageIO
import WoodruffKit

// The cameras' alerts on Apple TV: a small Liquid Glass pill at the top right ("Person seen", "Front Driveway · now",
// with a round picture of who or what was seen), for about five seconds. The Mac Studio (the hub) hears Google's
// camera events and keeps its last few alerts for the Apple TVs (CameraShare's GET /events); the Apple TV asks it
// every few seconds, at home or through Tailscale, and never listens to Google itself for these. Selecting the pill
// opens that camera with the event's picture; Back puts it away. It never takes the remote's focus by itself, and
// over a video or an open camera it only shows (nothing there can move to it).

@MainActor
@Observable
final class TVAlerts {
    static let shared = TVAlerts()

    struct Item: Identifiable, Equatable {
        /// The event's short id.
        let id: String
        let camera: String
        let name: String
        let title: String
        /// When it happened, by this Apple TV's clock.
        let at: Date
        var thumb: UIImage?
        /// The event's picture, kept for the replay when the camera is opened.
        var picture: URL?
        var event: String?
        var clip: String?
        /// When it came on screen.
        var shownAt = Date()

        static func == (a: Item, b: Item) -> Bool { a.id == b.id && a.thumb === b.thumb }
    }

    /// The alert on screen.
    private(set) var current: Item?
    /// Something covers the app (a video playing, a camera open, a sheet): the pill shows in its own window above it,
    /// where the remote can't reach it, instead of in the app.
    private(set) var covered = false
    /// The remote is on the pill: it stays until the remote moves off or it's selected.
    @ObservationIgnored var holding = false

    @ObservationIgnored private var queue: [Item] = []
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var timer: Task<Void, Never>?
    /// The Mac's time of the newest alert seen: only newer ones are asked for.
    @ObservationIgnored private var cursor: Int64?
    @ObservationIgnored private var seen: [String: Date] = [:]
    /// The address that answered last, tried first next time.
    @ObservationIgnored private var good: String?
    @ObservationIgnored private var window: UIWindow?

    private static let shownFor: TimeInterval = 5
    /// How long one stays at least when another is waiting.
    private static let shownAtLeast: TimeInterval = 2.5
    private static let slide = Animation.spring(response: 0.5, dampingFraction: 0.86)

    // MARK: Asking the Mac Studio

    func start() {
        guard loop == nil, !Demo.isOn else { return }
        // Earlier alerts' pictures (kept only for opening the camera from the pill) don't pile up.
        Task.detached(priority: .utility) { Self.tidy() }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    /// The alerts' pictures from over an hour ago, deleted.
    nonisolated private static func tidy() {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: fm.temporaryDirectory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for f in files where f.lastPathComponent.hasPrefix("tv-alert-") {
            if let d = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
               d.timeIntervalSinceNow < -3600 {
                try? fm.removeItem(at: f)
            }
        }
    }

    /// In the background: no asking, and nothing left on screen to come back to.
    func pause() {
        loop?.cancel(); loop = nil
        timer?.cancel(); timer = nil
        queue.removeAll()
        holding = false
        current = nil
        covered = false
        window?.isHidden = true
    }

    private var hosts: [String] {
        let all = (UserDefaults.standard.string(forKey: CameraShareKey.hostsKey) ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty }
        return (good.flatMap { all.contains($0) ? [$0] : nil } ?? []) + all.filter { $0 != good }
    }

    private func url(_ host: String, _ path: String, _ items: [String: String], token: String) -> URL? {
        var c = URLComponents()
        c.scheme = "http"; c.host = host; c.port = Int(CameraShareKey.port); c.path = path
        c.queryItems = items.map { URLQueryItem(name: $0.key, value: $0.value) } + [URLQueryItem(name: "k", value: token)]
        return c.url
    }

    private func poll() async {
        guard let token = CameraShareKey.token() else { return }
        for h in hosts {
            guard let u = url(h, "/events", ["since": String(cursor ?? 0)], token: token) else { continue }
            var r = URLRequest(url: u, timeoutInterval: 2)
            r.cachePolicy = .reloadIgnoringLocalCacheData
            guard let (d, resp) = try? await URLSession.shared.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200,
                  let feed = try? JSONDecoder().decode(CameraShareFeed.self, from: d) else { continue }
            if Task.isCancelled { return }
            good = h
            take(feed, host: h, token: token)
            return
        }
    }

    private func take(_ feed: CameraShareFeed, host: String, token: String) {
        let first = cursor == nil
        // The Mac's clock went back (or the cursor is from before a change of Mac): from now on.
        if let c = cursor, feed.now + 60_000 < c { cursor = feed.now }
        let newest = feed.events.map(\.at).max() ?? 0
        cursor = max(cursor ?? 0, newest, first ? feed.now : 0)
        // Only what just happened: none from before the app opened or while it was away, beyond a few seconds.
        let fresh = feed.events.filter { feed.now - $0.at <= (first ? 20_000 : 60_000) }.sorted { $0.at < $1.at }
        seen = seen.filter { $0.value.timeIntervalSinceNow > -3600 }
        for e in fresh where seen[e.key] == nil {
            seen[e.key] = Date()
            let at = Date().addingTimeInterval(-Double(max(0, feed.now - e.at)) / 1000)
            Task { await self.prepare(e, at: at, host: host, token: token) }
        }
    }

    /// The event's picture (else the camera's picture now), its round thumbnail on who or what was seen, then shown.
    private func prepare(_ e: CameraShareEvent, at: Date, host: String, token: String) async {
        var data: Data?
        let order = [host] + hosts.filter { $0 != host }
        for (path, id) in [("/event", e.key), ("/still", e.camera)] where data == nil {
            for h in order {
                guard let u = url(h, path, ["id": id], token: token) else { continue }
                var r = URLRequest(url: u, timeoutInterval: 3)
                r.cachePolicy = .reloadIgnoringLocalCacheData
                // No answer from this address: the next one.
                guard let (d, resp) = try? await URLSession.shared.data(for: r),
                      let code = (resp as? HTTPURLResponse)?.statusCode else { continue }
                if code == 200, d.count > 500 { data = d }
                // An answer, picture or not: the Mac's other addresses would say the same (they're the same Mac), and
                // away from home its home address only times out, holding the alert up three seconds or more.
                break
            }
        }
        var file: URL?
        var thumb: UIImage?
        if let data {
            let u = FileManager.default.temporaryDirectory.appendingPathComponent("tv-alert-\(e.key).jpg")
            let focus = CameraEventMedia.focus(e.focus)
            let kind = SubjectCrop.kind(e.title)
            // Kept for the replay (the camera opened from the pill) and made round, both off the main thread.
            let made = await Task.detached(priority: .userInitiated) { () -> (file: URL?, thumb: UIImage?) in
                let kept = (try? data.write(to: u, options: .atomic)) != nil
                return (file: kept ? u : nil, thumb: Self.roundThumb(data, focus: focus, kind: kind))
            }.value
            file = made.file
            thumb = made.thumb
        }
        guard loop != nil else { return }
        enqueue(Item(id: e.key, camera: e.camera, name: e.name, title: e.title, at: at, thumb: thumb,
                      picture: file, event: e.event, clip: e.clip))
    }

    /// A square of the picture on its subject (the Mac's framing, else found here), small enough for the pill.
    nonisolated private static func roundThumb(_ data: Data, focus: CGRect?, kind: SubjectCrop.Kind) -> UIImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                       kCGImageSourceThumbnailMaxPixelSize: 1280,
                                                                       kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
        else { return nil }
        let w = CGFloat(image.width), h = CGFloat(image.height)
        guard w > 0, h > 0 else { return nil }
        let unit = focus ?? (kind == .whole ? nil : SubjectCrop.unitFocus(in: image, kind: kind))
        var square: CGRect
        if let unit {
            let f = CGRect(x: unit.minX * w, y: unit.minY * h, width: unit.width * w, height: unit.height * h)
            let side = min(max(f.width, f.height), min(w, h))
            square = CGRect(x: f.midX - side / 2, y: f.midY - side / 2, width: side, height: side)
        } else {
            let side = min(w, h)
            square = CGRect(x: (w - side) / 2, y: (h - side) / 2, width: side, height: side)
        }
        // Kept inside the picture.
        square.origin.x = min(max(0, square.minX), w - square.width)
        square.origin.y = min(max(0, square.minY), h - square.height)
        guard let cut = image.cropping(to: square.integral) else { return nil }
        let out = CGSize(width: 192, height: 192)
        let made = UIGraphicsImageRenderer(size: out).image { _ in UIImage(cgImage: cut).draw(in: CGRect(origin: .zero, size: out)) }
        return made.preparingForDisplay() ?? made
    }

    // MARK: On screen

    private func enqueue(_ a: Item) {
        if let c = current, c.camera == a.camera, !holding {
            // The same camera again: the newer one takes its place.
            withAnimation(.smooth(duration: 0.25)) { current = a }
            return
        }
        if current == nil, timer == nil { show(a); return }
        queue.append(a)
        // Briefly: the newest few, not a backlog.
        if queue.count > 2 { queue.removeFirst(queue.count - 2) }
    }

    private func show(_ a: Item) {
        var a = a
        a.shownAt = Date()
        covered = Self.appCovered(except: window)
        if covered { showWindow() }
        withAnimation(Self.slide) { current = a }
        timer?.cancel()
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let self, let c = self.current else { return }
                // A video started (or ended) under it: it moves to where it can be seen.
                let now = Self.appCovered(except: self.window)
                if now != self.covered {
                    if now { self.showWindow() }
                    withAnimation(Self.slide) { self.covered = now }
                }
                let up = Date().timeIntervalSince(c.shownAt)
                if self.holding && !self.covered && up < 60 { continue }
                if up >= (self.queue.isEmpty ? Self.shownFor : Self.shownAtLeast) { self.next(); return }
            }
        }
    }

    /// The one on screen slides away; the next waiting (if it's still recent) slides in after it.
    private func next() {
        withAnimation(Self.slide) { current = nil }
        holding = false
        timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard let self, !Task.isCancelled else { return }
            self.timer = nil
            self.queue.removeAll { $0.at.timeIntervalSinceNow < -60 }
            if !self.queue.isEmpty { self.show(self.queue.removeFirst()); return }
            if self.current == nil { self.window?.isHidden = true }
        }
    }

    /// Back on the remote while it's on the pill: away, with any waiting.
    func dismiss() {
        queue.removeAll()
        timer?.cancel(); timer = nil
        next()
    }

    /// Selected: that camera opens with the event's picture (the same view a tapped alert opens on the iPhone).
    func open() {
        guard let a = current else { return }
        let streams = CameraStreams.shared
        streams.replay = CameraReplay(camera: a.camera, key: a.id, event: a.event, clip: a.clip, title: a.title, at: a.at,
                                      media: a.picture)
        streams.requested = a.camera
        streams.openFromAlert(a.camera)
        dismiss()
    }

    // MARK: Over everything

    /// Whether the app has something presented over it (a video, an open camera, a sheet or an alert).
    private static func appCovered(except own: UIWindow?) -> Bool {
        for scene in UIApplication.shared.connectedScenes {
            guard let s = scene as? UIWindowScene else { continue }
            for w in s.windows where w !== own && !w.isHidden {
                if w.rootViewController?.presentedViewController != nil { return true }
            }
        }
        return false
    }

    /// A window of its own above the app's (and anything it presents), which never takes the remote.
    private func showWindow() {
        if window == nil {
            guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
            let w = UIWindow(windowScene: scene)
            w.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue + 50)
            w.backgroundColor = .clear
            w.isUserInteractionEnabled = false
            let host = UIHostingController(rootView: TVAlertLayer(windowed: true).preferredColorScheme(.dark))
            host.view.backgroundColor = .clear
            w.rootViewController = host
            window = w
        }
        window?.isHidden = false
    }
}

/// Where the pill goes, at the top right of the screen: in the app (where the remote can move up to it), or in its
/// own window over a video ([windowed]).
struct TVAlertLayer: View {
    var windowed = false
    private let alerts = TVAlerts.shared
    @FocusState private var focused: Bool

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.clear
            if let a = alerts.current, alerts.covered == windowed {
                Group {
                    if windowed {
                        TVAlertPill(alert: a)
                    } else {
                        // On the remote the pill gets tvOS's own highlight, in the pill's shape: it lifts and catches
                        // the light while the remote is on it (nothing drawn by hand, and no white platter).
                        Button { alerts.open() } label: {
                            TVAlertPill(alert: a)
                                .contentShape(.hoverEffect, Capsule())
                                .hoverEffect(.highlight)
                        }
                            .buttonStyle(.borderless)
                            .buttonBorderShape(.capsule)
                            .focused($focused)
                            .onExitCommand { alerts.dismiss() }
                            .focusSection()
                    }
                }
                .padding(.top, 60)
                .padding(.trailing, 70)
                .transition(AnyTransition.offset(x: 160, y: -240).combined(with: .opacity))
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(!windowed)
        .onChange(of: focused) { _, f in alerts.holding = f }
    }
}

/// The pill: the round picture, the title, and the camera with how long ago. Its words are read from across the
/// room: 29 and 23 points (nothing on Apple TV is smaller than 23), in the same shape as before, half as large again.
struct TVAlertPill: View {
    let alert: TVAlerts.Item

    var body: some View {
        HStack(spacing: 16) {
            Group {
                if let t = alert.thumb {
                    Image(uiImage: t).resizable().scaledToFill()
                } else {
                    Color.white.opacity(0.15)
                }
            }
            .frame(width: 72, height: 72)
            .clipShape(Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(alert.title)
                    .font(.system(size: 29, weight: .bold))
                    .foregroundStyle(.white)
                TimelineView(.periodic(from: .now, by: 15)) { ctx in
                    Text("\(alert.name) · \(Self.ago(alert.at, now: ctx.date))")
                        .font(.system(size: 23, weight: .medium))
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
            .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.leading, 12)
        .padding(.trailing, 27)
        .frame(width: 480, height: 96)
        .glassEffect(.regular, in: Capsule())
        .accessibilityElement(children: .combine)
    }

    static func ago(_ at: Date, now: Date) -> String {
        let s = Int(now.timeIntervalSince(at))
        if s < 60 { return "now" }
        if s < 3600 { return "\(s / 60) min ago" }
        return at.formatted(date: .omitted, time: .shortened)
    }
}

/// The Apple TV's own diagnostics lines (how each film played, freezes), sent to the Mac Studio's camera share: its
/// settings don't reach the Macs from where it is, so they're read there (appletv.log) instead.
@MainActor
enum TVDiagnosticsRelay {
    static func send(kind: String, detail: String, build: String) {
        guard let token = CameraShareKey.token() else { return }
        let hosts = (UserDefaults.standard.string(forKey: CameraShareKey.hostsKey) ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty }
        guard !hosts.isEmpty else { return }
        let name = UIDevice.current.name
        func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "" }
        let query = [("n", name), ("b", build), ("t", kind), ("d", detail), ("k", token)].map { URLQueryItem(name: $0.0, value: enc($0.1)) }
        Task.detached(priority: .utility) {
            for h in hosts {
                var c = URLComponents()
                c.scheme = "http"; c.host = h; c.port = Int(CameraShareKey.port); c.path = "/diag"
                c.percentEncodedQueryItems = query
                guard let u = c.url else { continue }
                var r = URLRequest(url: u, timeoutInterval: 4)
                r.cachePolicy = .reloadIgnoringLocalCacheData
                if let (_, resp) = try? await URLSession.shared.data(for: r), let code = (resp as? HTTPURLResponse)?.statusCode, code < 300 { return }
            }
        }
    }
}
