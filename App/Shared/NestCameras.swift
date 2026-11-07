import SwiftUI
import WebKit
#if os(iOS)
import WidgetKit
#endif
import os
#if os(macOS)
import AppKit
#endif
import WoodruffKit
#if os(iOS)
import AVFoundation
#endif

/// Where the cameras are kept between launches (on this device only: never synced).
private let nestCamerasKey = "nestCameras"

/// Google Home / Nest cameras and doorbells, live, through Google's Device Access (the same project and Google
/// app keys the TVs use). This device signs in for itself once; the video plays over WebRTC.
@Observable @MainActor
final class NestCameras {
    static let shared = NestCameras()
    static let sdm = "https://smartdevicemanagement.googleapis.com/v1/"

    struct Camera: Identifiable, Hashable, Codable {
        var id: String          // enterprises/{project}/devices/{id}
        var name: String
        var room: String?
        var doorbell: Bool
        var webRTC: Bool
        /// Google can reach it, by its Connectivity trait (or a Pub/Sub update of it). Cameras without the
        /// trait count as online; a stream refused as offline shows "Offline" on the player instead.
        var online = true
    }

    /// The cameras, starting as they were last found (kept for the next launch while signed in), so Home shows them
    /// at once; Google is asked again straight away.
    private(set) var cameras: [Camera] = NestCameras.saved()
    private(set) var error: String?
    private(set) var busy = false
    /// Signed in (kept in memory; the Keychain is only read when it changes).
    private(set) var connected = Keychain.get("nest.refresh") != nil
    @ObservationIgnored private var refreshing: Task<String, Error>?
    @ObservationIgnored private var poll: Task<Void, Never>?

    private var project: String? { Keychain.get("nest.project") }
    private var clientID: String? { Keychain.get("nest.client") }

    /// The cameras kept from last time, if this device is still signed in (never in Demo mode).
    nonisolated private static func saved() -> [Camera] {
        guard !Demo.isOn, Keychain.get("nest.refresh") != nil else { return [] }
        return Saved.load(nestCamerasKey, as: [Camera].self) ?? []
    }

    /// Keeps the cameras for the next launch.
    private func keep() { Saved.save(nestCamerasKey, cameras) }

    func start() {
        let signedIn = Keychain.get("nest.refresh") != nil
        if connected != signedIn { connected = signedIn }
        let alerts = (Keychain.get("nest.scopes") ?? "").contains("pubsub")
        if canAlert != alerts { canAlert = alerts }
        guard connected, !Demo.isOn else { return }
        shareSignIn()
        #if os(iOS)
        CameraEventMedia.prune()
        #endif
        if poll == nil { startPolling(now: true) } else { Task { await load() } }
    }

    /// The sign-in, where the notification extension can use it to fetch an alert's clip (iPhone and iPad only).
    private func shareSignIn() {
        #if os(iOS)
        CameraEventMedia.keepCredentials(clientID: Keychain.get("nest.client"), secret: Keychain.get("nest.secret"),
                                         refresh: Keychain.get("nest.refresh"), access: Keychain.get("nest.access"),
                                         expires: Keychain.get("nest.expires").flatMap(Double.init))
        #endif
    }

    /// Now (or after the first wait), then every five minutes: a camera going offline (or coming back)
    /// shows without a manual refresh.
    private func startPolling(now: Bool) {
        poll?.cancel()
        poll = Task { [weak self] in
            var first = now
            while !Task.isCancelled {
                // Every fifteen minutes while the app isn't in use (alerts come on their own, not from this).
                if !first { await Fleet.pause(inUse: 300, idle: 900) }
                first = false
                guard !Task.isCancelled, let self, self.connected else { break }
                await self.load()
            }
            // Stopped by itself (signed out elsewhere, sign-in revoked): a later start begins it again.
            if !Task.isCancelled { self?.poll = nil }
        }
    }

    /// Google said a camera went offline or came back (a Pub/Sub Connectivity update).
    func setOnline(_ id: String, _ online: Bool) {
        guard let i = cameras.firstIndex(where: { $0.id == id }), cameras[i].online != online else { return }
        cameras[i].online = online
        keep()
        CameraStreams.shared.availability(cameras)
    }

    /// Signs in with Google using the TVs' Device Access project and Google app (Client ID from the TV;
    /// the Secret is typed once here, as it was on the TV).
    func signIn(project: String, clientID: String, secret: String) async {
        let sec = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !project.isEmpty, !clientID.isEmpty, !sec.isEmpty else { error = "Enter the Client Secret first."; return }
        busy = true; error = nil
        defer { busy = false }
        do {
            let code = try await OAuthRelay().signIn { state in
                var c = URLComponents(string: "https://nestservices.google.com/partnerconnections/\(project)/auth")!
                c.queryItems = [
                    URLQueryItem(name: "redirect_uri", value: OAuthRelay.redirect), URLQueryItem(name: "access_type", value: "offline"),
                    URLQueryItem(name: "prompt", value: "consent"), URLQueryItem(name: "client_id", value: clientID),
                    URLQueryItem(name: "response_type", value: "code"),
                    // Pub/Sub too, for doorbell, person and motion alerts (as the TVs do).
                    URLQueryItem(name: "scope", value: "https://www.googleapis.com/auth/sdm.service https://www.googleapis.com/auth/pubsub"),
                    URLQueryItem(name: "state", value: state),
                ]
                return c.url!
            }
            let t = try await formPost("https://oauth2.googleapis.com/token", [
                "code": code, "client_id": clientID, "client_secret": sec,
                "redirect_uri": OAuthRelay.redirect, "grant_type": "authorization_code",
            ])
            Keychain.set(project, for: "nest.project")
            Keychain.set(clientID, for: "nest.client")
            Keychain.set(sec, for: "nest.secret")
            store(t)
            await load()
            startPolling(now: false)
        } catch { self.error = error.localizedDescription }
    }

    func signOut() {
        for k in ["nest.refresh", "nest.access", "nest.expires"] { Keychain.set(nil, for: k) }
        #if os(iOS)
        CameraEventMedia.forgetCredentials()
        #endif
        connected = false
        error = nil
        poll?.cancel(); poll = nil
        cameras = []
        UserDefaults.standard.removeObject(forKey: nestCamerasKey)
        CameraStreams.shared.reset()
    }

    /// Whether this sign-in included Pub/Sub (alerts). Older ones didn't; connecting again adds it.
    private(set) var canAlert = (Keychain.get("nest.scopes") ?? "").contains("pubsub")

    private func store(_ t: [String: Any]) {
        if let sc = t["scope"] as? String { Keychain.set(sc, for: "nest.scopes"); canAlert = sc.contains("pubsub") }
        if t["refresh_token"] is String { connected = true }
        if let a = t["access_token"] as? String { Keychain.set(a, for: "nest.access") }
        if let r = t["refresh_token"] as? String { Keychain.set(r, for: "nest.refresh") }
        let exp = (t["expires_in"] as? Double) ?? Double((t["expires_in"] as? Int) ?? 3600)
        Keychain.set(String(Date().addingTimeInterval(exp - 120).timeIntervalSince1970), for: "nest.expires")
        shareSignIn()
    }

    func accessToken() async throws -> String { try await token() }

    private func token() async throws -> String {
        if let a = Keychain.get("nest.access"), let e = Keychain.get("nest.expires").flatMap(Double.init), e > Date().timeIntervalSince1970 { return a }
        // One refresh at a time; everyone else waits for it.
        if let r = refreshing { return try await r.value }
        let task = Task<String, Error> { @MainActor in
            defer { self.refreshing = nil }
            guard let r = Keychain.get("nest.refresh"), let id = self.clientID, let sec = Keychain.get("nest.secret") else {
                throw OAuthRelay.Failure.refused("Connect the cameras again.")
            }
            do {
                self.store(try await formPost("https://oauth2.googleapis.com/token", ["refresh_token": r, "client_id": id, "client_secret": sec, "grant_type": "refresh_token"]))
            } catch {
                // Google won't renew it (password changed, access removed): sign in again, don't keep trying.
                if "\(error.localizedDescription)".contains("invalid_grant") || error.localizedDescription.contains("expired or revoked") {
                    Keychain.set(nil, for: "nest.refresh")
                    self.connected = false
                    throw OAuthRelay.Failure.refused("Connect the cameras again.")
                }
                throw error
            }
            return Keychain.get("nest.access") ?? ""
        }
        refreshing = task
        return try await task.value
    }

    private func call(_ method: String, _ path: String, _ body: [String: Any]? = nil, retried: Bool = false) async throws -> [String: Any] {
        guard let url = URL(string: Self.sdm + path) else { throw OAuthRelay.Failure.refused("Google answered oddly.") }
        var r = URLRequest(url: url, timeoutInterval: 20)
        r.httpMethod = method
        r.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        if let body {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (d, resp) = try await URLSession.shared.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
        guard (200..<300).contains(code) else {
            if code == 401 {
                // The sign-in ran out early (Google ended it, or another device's renewal replaced it): renew it once
                // and ask again, rather than showing an error until the next look.
                Keychain.set(nil, for: "nest.access")
                if !retried { return try await call(method, path, body, retried: true) }
            }
            if code == 429 { throw RateLimited() }
            // Google's own hiccups ("Internal error encountered", unavailable): try again, quietly.
            if code >= 500 { throw Busy() }
            let msg = ((json["error"] as? [String: Any])?["message"] as? String) ?? "Google answered \(code)."
            // A stream asked of a camera that's off or off the Wi‑Fi.
            let lower = msg.lowercased()
            if path.hasSuffix(":executeCommand"), lower.contains("offline") || lower.contains("not online") || lower.contains("unavailable") || lower.contains("not reachable") || lower.contains("unreachable") {
                throw Offline()
            }
            throw OAuthRelay.Failure.refused(code == 403 ? "Google refused access: \(msg)" : msg)
        }
        return json
    }

    func load() async {
        // Sign-ins can arrive from another device (settings sync): look again.
        let signedIn = Keychain.get("nest.refresh") != nil
        if connected != signedIn { connected = signedIn }
        let alerts = (Keychain.get("nest.scopes") ?? "").contains("pubsub")
        if canAlert != alerts { canAlert = alerts }
        guard let project, connected else { return }
        do {
            let devices = (try await call("GET", "enterprises/\(project)/devices"))["devices"] as? [[String: Any]] ?? []
            let found: [Camera] = devices.compactMap { d in
                guard let name = d["name"] as? String, let traits = d["traits"] as? [String: Any],
                      let live = traits["sdm.devices.traits.CameraLiveStream"] as? [String: Any] else { return nil }
                let type = d["type"] as? String ?? ""
                let room = ((d["parentRelations"] as? [[String: Any]])?.first?["displayName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                let custom = ((traits["sdm.devices.traits.Info"] as? [String: Any])?["customName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                let doorbell = type.hasSuffix("DOORBELL")
                let label = custom ?? room.map { "\($0) \(doorbell ? "Doorbell" : "Camera")" } ?? (doorbell ? "Doorbell" : "Camera")
                let webRTC = (live["supportedProtocols"] as? [String] ?? []).contains("WEB_RTC")
                var cam = Camera(id: name, name: label, room: room, doorbell: doorbell, webRTC: webRTC)
                if let status = (traits["sdm.devices.traits.Connectivity"] as? [String: Any])?["status"] as? String {
                    cam.online = status.uppercased() != "OFFLINE"
                }
                return cam
            }
            .sorted { ($0.doorbell ? 0 : 1, $0.name) < ($1.doorbell ? 0 : 1, $1.name) }
            // Signed out while Google answered: nothing comes back.
            guard connected else { return }
            // Only a real change reaches Home (and is kept for the next launch); most looks find the same cameras.
            if found != cameras {
                cameras = found
                keep()
            }
            CameraStreams.shared.availability(cameras)
            if error != nil { error = nil }
        } catch { self.error = error.localizedDescription }
    }

    // MARK: Live

    struct RateLimited: Error {}
    struct Busy: Error {}
    struct Offline: Error {}

    /// Google allows only so many camera commands a minute. Commands wait their turn: a few seconds apart
    /// overall, longer for the same camera, and a refusal just means waiting longer and trying again,
    /// never an error on screen.
    private var nextAny = Date.distantPast
    private var nextFor: [String: Date] = [:]
    private var backoff: [String: Double] = [:]

    private func paced<T>(_ cam: String, _ op: () async throws -> T) async throws -> T {
        var busy = 0
        while true {
            try Task.checkCancellation()
            // The camera that's open goes first: it doesn't wait behind the tiles' starts and renewals (only its own
            // turn, and Google's wait after a refusal).
            let open = CameraStreams.shared.expanded == cam || CameraStreams.shared.full == cam
            let wait = max(open ? .distantPast : nextAny, nextFor[cam] ?? .distantPast).timeIntervalSinceNow
            if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) ; continue }
            nextAny = Date().addingTimeInterval(2)
            nextFor[cam] = Date().addingTimeInterval(8)
            do {
                let r = try await op()
                backoff[cam] = nil
                return r
            } catch is RateLimited {
                let b = min(300, (backoff[cam] ?? 20) * 2)
                backoff[cam] = b
                nextFor[cam] = Date().addingTimeInterval(b)
                nextAny = Date().addingTimeInterval(15)
            } catch is Busy {
                // A couple of quick retries; after that the player starts over with a fresh offer.
                busy += 1
                if busy >= 3 { throw Busy() }
                nextFor[cam] = Date().addingTimeInterval(Double(busy) * 4)
            }
        }
    }

    func startStream(_ cam: Camera, offer: String) async throws -> (answer: String, session: String) {
        let r = try await paced(cam.id) {
            try await call("POST", "\(cam.id):executeCommand", [
                "command": "sdm.devices.commands.CameraLiveStream.GenerateWebRtcStream", "params": ["offerSdp": offer],
            ])
        }
        let res = r["results"] as? [String: Any] ?? [:]
        guard let a = res["answerSdp"] as? String, let s = res["mediaSessionId"] as? String else { throw OAuthRelay.Failure.refused("The camera didn’t answer.") }
        return (a, s)
    }

    func extend(_ cam: Camera, session: String) async -> String? {
        let r = try? await paced(cam.id) {
            try await call("POST", "\(cam.id):executeCommand", [
                "command": "sdm.devices.commands.CameraLiveStream.ExtendWebRtcStream", "params": ["mediaSessionId": session],
            ])
        }
        guard let r else { return nil }
        return ((r["results"] as? [String: Any])?["mediaSessionId"] as? String) ?? session
    }
}

// MARK: - Home section

struct CamerasSection: View {
    /// Two across on iPhone; on the Mac, as many as fit at a comfortable size.
    #if os(macOS)
    static let compactWidth: CGFloat = 340
    #else
    static let compactWidth: CGFloat = 160
    #endif
    var room: String? = nil
    /// Only the favourites (Home's Favorites).
    var favorites = false
    /// Two across on iPhone (inside a room), rather than one big one each.
    var compact = false
    /// Off inside a room on Home (the room is the heading).
    var titled = true
    /// Cameras shown elsewhere on the same screen (Favorites): one live picture can only be in one place.
    var excluding: Set<String> = []
    private let nest = NestCameras.shared
    @State private var open: NestCameras.Camera?

    private var shown: [NestCameras.Camera] {
        let list = room.map { r in nest.cameras.filter { roomMatches(SmartHome.shared.rooms[$0.id] ?? $0.room, r) } } ?? nest.cameras
        return favorites ? HomeLayout.shared.favoritesOnly(nest.cameras) : HomeLayout.shared.arrange(list.filter { !excluding.contains($0.id) }, in: "cameras")
    }

    var body: some View {
        if !shown.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                if titled { Text("Cameras").font(.title2.bold()) }
                LazyVGrid(columns: compact ? [GridItem(.adaptive(minimum: Self.compactWidth), spacing: 10)] : [GridItem(.adaptive(minimum: 320), spacing: 14)], spacing: compact ? 10 : 14) {
                    ForEach(shown) { cam in
                        LiveCameraTile(camera: cam, compact: compact) { open = cam }
                    }
                }
            }
            .cameraPresenter($open)
        }
    }
}

/// One live stream per camera, kept for the whole time the app is open: the Home tile and the big view
/// show the same stream, scrolling doesn't restart it, and it's only let go a while after nobody is
/// looking (the app in the background, or Home out of view for a couple of minutes). That keeps the
/// camera commands to one start and a renewal every four minutes per camera.
@Observable @MainActor
final class CameraStreams {
    static let shared = CameraStreams()

    private(set) var status: [String: String] = [:]
    /// The camera open in the big view (its tile shows a still while it's there).
    var expanded: String?
    /// A camera to open in the big view straight away (a tapped camera or doorbell alert).
    var requested: String?
    /// Mac: the camera filling the whole app window.
    var full: String?
    /// The alert a camera was opened from: its clip or snapshot replays above the live view.
    var replay: CameraReplay?
    @ObservationIgnored private var players: [String: LivePlayer] = [:]
    @ObservationIgnored private var watching = 0
    @ObservationIgnored private var idle: Task<Void, Never>?
    @ObservationIgnored private var backgroundAt: Date?
    /// Mac: cameras whose stream runs all the time (Vehicle Alerts watches them), never let go.
    @ObservationIgnored private(set) var pinned: Set<String> = []
    /// The Mac: cameras whose picture is being taken for an alert right now.
    @ObservationIgnored private var grabbing: Set<String> = []
    /// Every stream was let go (nothing on screen); a picture taken meanwhile lets its stream go too.
    @ObservationIgnored private var letGo = false
    /// iPhone: the tiles' streams paused while a camera is open over them.
    @ObservationIgnored private var heldBack: [String] = []

    /// Lets every stream go and forgets them (signed out).
    func reset() {
        for p in players.values { p.close() }
        players = [:]
        status = [:]
        watching = 0
        expanded = nil
    }

    func player(_ cam: NestCameras.Camera) -> LivePlayer {
        if let p = players[cam.id] { return p }
        let p = LivePlayer(camera: cam)
        p.onStatus = { [weak self] s in withAnimation(.smooth) { self?.status[cam.id] = s } }
        players[cam.id] = p
        return p
    }

    /// A tile or the big view came on screen.
    func show(_ cam: NestCameras.Camera) {
        watching += 1
        idle?.cancel(); idle = nil
        letGo = false
        let p = player(cam)
        p.camera = cam
        if cam.online { p.start() } else { p.pause(); status[cam.id] = "Offline" }
    }

    /// The cameras as Google last described them: an offline one stops trying (and says Offline, not a
    /// spinner); one back online starts again if it's on screen.
    func availability(_ cams: [NestCameras.Camera]) {
        for c in cams {
            guard let p = players[c.id] else { continue }
            let was = p.camera.online
            p.camera = c
            if !c.online {
                p.pause()
                status[c.id] = "Offline"
            } else if !was {
                if watching > 0 { p.start() } else { status[c.id] = "Paused" }
            }
        }
    }

    /// iPhone: a camera opened over Home. The other streams pause meanwhile (their tiles are behind it), so this
    /// one has the phone's bandwidth and Google's camera commands to itself.
    func focus(_ id: String) {
        #if os(iOS)
        for (k, p) in players where k != id && p.isRunning {
            p.pause()
            heldBack.append(k)
            if status[k] != "Offline" { status[k] = "Paused" }
        }
        #endif
    }

    /// It closed: the tiles' streams start again (if Home is still showing them).
    func unfocus() {
        let back = heldBack
        heldBack = []
        guard watching > 0 else { return }
        for k in back { if let p = players[k], p.camera.online { p.start() } }
    }

    #if os(macOS)
    /// Far off screen: a camera's picture plays here while no window shows it (a web view in no window plays no video).
    @ObservationIgnored private lazy var grabWindow: NSWindow = {
        let w = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 640, height: 360), styleMask: .borderless,
                         backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.ignoresMouseEvents = true
        w.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        return w
    }()

    /// The Mac: a picture of what the camera sees now, for its alert (Google has none for these cameras). Its stream,
    /// already running or started just for this, gives its first good frame, and one started for this is let go
    /// again. Nil if no frame comes within [timeout] seconds.
    func grabFrame(_ cam: NestCameras.Camera, timeout: Double = 20) async -> Data? {
        let p = player(cam)
        let started = !p.isRunning
        grabbing.insert(cam.id)
        var borrowed = false
        if p.web.window == nil, let host = grabWindow.contentView {
            p.web.frame = host.bounds
            host.addSubview(p.web)
            grabWindow.orderBack(nil)
            borrowed = true
        }
        if started { p.start() }
        defer {
            grabbing.remove(cam.id)
            if borrowed, p.web.superview === grabWindow.contentView { p.web.removeFromSuperview() }
            if grabWindow.contentView?.subviews.isEmpty ?? true { grabWindow.orderOut(nil) }
            if !pinned.contains(cam.id), letGo || (started && expanded != cam.id && full != cam.id && watching == 0) { p.pause() }
        }
        let end = Date().addingTimeInterval(timeout)
        var firstLive: Date?
        while Date() < end {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard p.isLive else { continue }
            if firstLive == nil { firstLive = Date() }
            // A second in, past the first frames (often grey while the picture settles).
            if let f = firstLive, Date().timeIntervalSince(f) > 1, let jpeg = await p.frameJPEG() { return jpeg }
        }
        return nil
    }
    #endif

    #if os(macOS)
    /// Mac: keeps a camera's stream playing all the time, in the far-off window when no window shows it (Vehicle
    /// Alerts). Called again every second or so: it puts the picture back there after the camera was open on screen,
    /// and starts the stream again if it stopped.
    @discardableResult
    func keepPlaying(_ cam: NestCameras.Camera) -> LivePlayer {
        pinned.insert(cam.id)
        let p = player(cam)
        if p.web.window == nil, let host = grabWindow.contentView {
            p.web.frame = host.bounds
            host.addSubview(p.web)
            grabWindow.orderBack(nil)
        }
        if cam.online, !p.isRunning { p.start() }
        return p
    }

    /// No longer kept playing (its switch went off): let go unless it's on screen.
    func stopKeeping(_ id: String) {
        guard pinned.remove(id) != nil, let p = players[id] else { return }
        if p.web.superview === grabWindow.contentView { p.web.removeFromSuperview() }
        if grabWindow.contentView?.subviews.isEmpty ?? true { grabWindow.orderOut(nil) }
        if letGo || (expanded != id && full != id && watching == 0) { p.pause() }
    }
    #endif

    /// One went off screen; if nothing is watched for two minutes, the streams are let go.
    func hide() {
        watching = max(0, watching - 1)
        guard watching == 0 else { return }
        letGoSoon(after: 120)
    }

    /// The app went to the background (or, on the Mac, every window went out of sight): keep the streams a while, in
    /// case it's a quick switch.
    func background(after seconds: Double = 60) { backgroundAt = Date(); letGoSoon(after: seconds) }

    func foreground() {
        #if os(iOS)
        // Replays older than ten minutes go each time the app comes back.
        CameraEventMedia.prune()
        #endif
        idle?.cancel(); idle = nil
        letGo = false
        // Away more than a minute: iOS froze the streams, so start them fresh.
        let long = backgroundAt.map { $0.timeIntervalSinceNow < -60 } ?? false
        backgroundAt = nil
        guard watching > 0 else { return }
        // One Vehicle Alerts kept playing isn't interrupted.
        for (k, p) in players where p.camera.online { if long && !pinned.contains(k) { p.restart() } else { p.start() } }
    }

    private func letGoSoon(after seconds: Double) {
        idle?.cancel()
        idle = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.letGo = true
            // A stream Vehicle Alerts watches, or a picture being taken for an alert, keeps going.
            let keep = self.pinned.union(self.grabbing)
            for (k, p) in self.players where !keep.contains(k) { p.pause() }
            for k in self.status.keys where self.status[k] != "Offline" && !keep.contains(k) { self.status[k] = "Paused" }
        }
    }
}

/// A camera tile's shape: its own (16:9, or 4:3 two across), or whatever size Home's grid gives it.
private struct CameraTileShape: ViewModifier {
    var fill: Bool
    var compact: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if fill {
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            content.aspectRatio(compact ? 4 / 3 : 16 / 9, contentMode: .fit)
        }
    }
}

/// A camera on Home: its live picture right in the tile (muted), its name over it. Tap for the big view.
struct LiveCameraTile: View, Equatable {
    static func nameFont(_ compact: Bool) -> Font {
        #if os(macOS)
        compact ? .headline : .title3.weight(.semibold)
        #else
        compact ? .footnote.weight(.semibold) : .subheadline.weight(.semibold)
        #endif
    }
    var camera: NestCameras.Camera
    /// Two across: taller (4:3) so the picture isn't small, and a smaller LIVE mark so the name fits.
    var compact = false
    /// Fills whatever size it's given (a tile on Home's grid, sized there) instead of keeping its own shape.
    var fill = false
    var open: () -> Void
    private let streams = CameraStreams.shared
    /// On one of Home's tabs: every tile there is laid out at once, on screen or not.
    @Environment(\.inHomeBoard) private var inBoard
    /// An offline camera was tapped: Google is being asked about it again.
    @State private var checking = false
    /// The tile has been drawn once: its live picture's web view is made only now (making one held up the frame).
    @State private var ready = false
    /// Between appearing and disappearing.
    @State private var appeared = false
    /// At least a fifth of it is on screen (Home's scrolling says).
    @State private var visible = false
    /// This tile has asked for the camera's stream (each ask is matched by one let-go).
    @State private var watching = false

    /// Drawn again for a change to the camera or the tile's shape, not each time the grid around it is.
    nonisolated static func == (a: LiveCameraTile, b: LiveCameraTile) -> Bool {
        a.camera == b.camera && a.compact == b.compact && a.fill == b.fill
    }

    var body: some View {
        let status = camera.online ? (streams.status[camera.id] ?? "Starting…") : (checking ? "Checking…" : "Offline")
        ZStack(alignment: .bottomLeading) {
            Color.black
            if camera.webRTC && ready && streams.expanded != camera.id {
                LiveWebView(player: streams.player(camera)).allowsHitTesting(false)
            }
            if status != "Live" || streams.expanded == camera.id {
                VStack(spacing: 8) {
                    if (camera.webRTC || checking) && status.hasSuffix("…") && streams.expanded != camera.id { ProgressView().tint(.white) }
                    Text(caption(status))
                        .font(.caption).foregroundStyle(.white.opacity(0.75)).multilineTextAlignment(.center).padding(.horizontal)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .center, endPoint: .bottom)
                .allowsHitTesting(false)
            HStack(alignment: .bottom) {
                Text(camera.name).font(Self.nameFont(compact))
                    .foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.85)
                Spacer()
            }
            .padding(compact ? 10 : 12)
        }
        .modifier(CameraTileShape(fill: fill, compact: compact))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.08)))
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onTapGesture {
            guard HomeLayout.shared.tapsAllowed else { return }
            if camera.webRTC && camera.online { streams.expanded = camera.id; open() }
            else if !camera.online { checkAgain() }
        }
        .contextMenu {
            ArrangeHomeButton()
            if camera.webRTC && camera.online { Button("Open") { streams.expanded = camera.id; open() } }
            if !camera.online { Button("Check Again") { checkAgain() } }
            FavoriteButton(id: camera.id)
        }
        // After the first frame: the web view, and the stream.
        .task {
            await Task.yield()
            guard !Task.isCancelled else { return }
            ready = true
            appeared = true
            follow()
        }
        // On Home's tabs a camera streams once it's on screen (and is let go the usual two minutes after nothing is
        // watched), rather than as soon as it's laid out somewhere off the bottom of the page.
        .onScrollVisibilityChange(threshold: 0.2) { on in
            visible = on
            follow()
        }
        .onDisappear {
            appeared = false
            follow()
        }
    }

    /// Asks for the stream while the tile shows (on Home's tabs: while it's on screen), and lets it go after.
    private func follow() {
        let wanted = appeared && ready && camera.webRTC && (!inBoard || visible)
        guard wanted != watching else { return }
        watching = wanted
        if wanted { streams.show(camera) } else { streams.hide() }
    }

    /// What the tile says over its picture when it isn't simply live.
    private func caption(_ status: String) -> String {
        if !camera.online { return checking ? "Checking…" : "Offline · Tap to Check Again" }
        if !camera.webRTC { return "Live view not supported" }
        if streams.expanded == camera.id { return "Open in the big view" }
        return status
    }

    /// Offline: ask Google about the cameras now (otherwise it's every five minutes). One that's back starts
    /// playing by itself.
    private func checkAgain() {
        guard !checking else { return }
        checking = true
        Task {
            await NestCameras.shared.load()
            checking = false
        }
    }
}

// MARK: - Live view

/// The big view: the same stream as the tile (no new one), with sound.
struct CameraLiveView: View {
    var camera: NestCameras.Camera
    /// iPhone: closes it (the presenter takes it away without the cover's slide); nil: dismissed as a cover.
    var onClose: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var muted = true
    /// iPhone and iPad: the live view filling the whole screen.
    @State private var fullScreen = false
    /// Bumped when full screen closes, so the live view takes the picture back.
    @State private var reattach = 0
    /// Opened from an alert: the live picture instead of the event's replay.
    @State private var showLive = false
    /// iPhone: the card has floated in (it fades and settles as it opens).
    @State private var appeared = false
    /// iPhone: how far the card has been pulled down (past a point, it closes).
    @State private var drag: CGFloat = 0
    private let streams = CameraStreams.shared

    var body: some View {
        let player = streams.player(camera)
        Group {
            #if os(macOS)
            // Just the picture, filling everything right of the sidebar (centred, edge to edge), with the name and
            // buttons floating over its top, below the window's title bar so a click on them is never a window drag.
            ZStack(alignment: .top) {
                Color.black
                    .ignoresSafeArea()
                LiveWebView(player: player)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .allowsHitTesting(false)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea()
                // A shade from the very top (under the title bar too) behind the name and buttons.
                VStack(spacing: 0) {
                    LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: 140)
                    Spacer(minLength: 0)
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(camera.name).font(.title3.bold()).foregroundStyle(.white)
                        Text(camera.online ? (streams.status[camera.id] ?? "Starting…") : "Offline").font(.subheadline).foregroundStyle(.white.opacity(0.7))
                    }
                    Spacer()
                    GlassCircle(symbol: muted ? "speaker.slash.fill" : "speaker.wave.2.fill", size: 36) {
                        muted.toggle(); player.setMuted(muted)
                    }
                    .accessibilityLabel(muted ? "Turn Sound On" : "Turn Sound Off")
                    GlassCircle(symbol: "xmark", size: 36) { close() }
                        .accessibilityLabel("Close")
                }
                .padding(14)
            }
            .onExitCommand { close() }
            // Esc closes it wherever the focus is (onExitCommand only hears it while something in it has focus).
            .background { Button("Close") { close() }.keyboardShortcut(.cancelAction).opacity(0).frame(width: 0, height: 0).accessibilityHidden(true) }
            #else
            phoneBody(player)
            #endif
        }
        .onAppear { streams.expanded = camera.id; streams.focus(camera.id); streams.show(camera) }
        .onDisappear {
            player.setMuted(true)
            if streams.replay?.camera == camera.id { streams.replay = nil }
            if streams.expanded == camera.id { streams.expanded = nil }
            streams.hide()
            streams.unfocus()
        }
    }

    private func close() {
        #if os(iOS)
        // The card settles away before the cover closes.
        withAnimation(.easeOut(duration: 0.18)) { appeared = false }
        Task {
            try? await Task.sleep(nanoseconds: 170_000_000)
            if let onClose { onClose() } else { dismiss() }
        }
        #else
        if streams.full == camera.id { withAnimation(.smooth(duration: 0.25)) { streams.full = nil } } else { dismiss() }
        #endif
    }

    #if os(iOS)
    /// The alert this camera was opened from, if any.
    private var replay: CameraReplay? { streams.replay.flatMap { $0.camera == camera.id ? $0 : nil } }

    private var subtitle: String {
        if let r = replay, !showLive { return "\(r.title) · \(r.at.formatted(date: .omitted, time: .shortened))" }
        return camera.online ? (streams.status[camera.id] ?? "Starting…") : "Offline"
    }

    /// iPhone and iPad: the camera floats in the middle of the screen as one rounded picture over the dimmed, blurred
    /// app, with its name over the top of the picture and small controls in its corners. Tap outside it or swipe it
    /// down to close.
    private func phoneBody(_ player: LivePlayer) -> some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
                .overlay(Color.black.opacity(0.45))
                .ignoresSafeArea()
                .opacity(appeared ? 1 : 0)
                .onTapGesture { close() }
            card(player)
                .padding(.horizontal, 14)
                .offset(y: max(0, drag))
                .scaleEffect(appeared ? 1 : 0.92)
                .opacity(appeared ? 1 : 0)
                .gesture(DragGesture()
                    .onChanged { drag = $0.translation.height }
                    .onEnded { v in
                        if v.translation.height > 110 || v.predictedEndTranslation.height > 260 { close() }
                        else { withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { drag = 0 } }
                    })
        }
        .presentationBackground(.clear)
        .onAppear { withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) { appeared = true } }
        .fullScreenCover(isPresented: $fullScreen, onDismiss: { reattach += 1 }) {
            CameraFullScreen(camera: camera, player: player, muted: $muted)
        }
    }

    private func card(_ player: LivePlayer) -> some View {
        ZStack {
            // One picture: opened from an alert, the event first (its clip or picture); with nothing to replay, live.
            if let r = replay, !showLive {
                EventReplayView(replay: r) { withAnimation(.smooth(duration: 0.25)) { showLive = true } }
            } else if fullScreen {
                Color.black
            } else {
                LiveWebView(player: player).id(reattach)
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        // The name over the top of the picture, on a soft shade so it reads on any scene.
        .overlay(alignment: .top) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(camera.name).font(.headline).lineLimit(1)
                    HStack(spacing: 5) {
                        if showLive || replay == nil {
                            Circle().fill(camera.online ? Color.red : Color.gray).frame(width: 6, height: 6)
                        }
                        Text(subtitle).font(.caption.weight(.medium)).lineLimit(1)
                    }
                    .foregroundStyle(.white.opacity(0.85))
                }
                Spacer(minLength: 0)
                GlassCircle(symbol: "xmark", size: 30) { close() }
                    .accessibilityLabel("Close")
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 22)
            .background(LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom))
            .shadow(color: .black.opacity(0.3), radius: 2)
        }
        // The controls, small in the bottom corner.
        .overlay(alignment: .bottomTrailing) {
            HStack(spacing: 8) {
                if replay != nil {
                    GlassCircle(symbol: showLive ? "gobackward" : "dot.radiowaves.left.and.right", size: 30) {
                        withAnimation(.smooth(duration: 0.25)) { showLive.toggle() }
                    }
                    .accessibilityLabel(showLive ? "Replay" : "Live")
                }
                GlassCircle(symbol: muted ? "speaker.slash.fill" : "speaker.wave.2.fill", size: 30) {
                    muted.toggle(); player.setMuted(muted)
                }
                .accessibilityLabel(muted ? "Turn Sound On" : "Turn Sound Off")
                if showLive || replay == nil {
                    GlassCircle(symbol: "arrow.up.left.and.arrow.down.right", size: 30) { fullScreen = true }
                        .accessibilityLabel("Full Screen")
                }
            }
            .padding(10)
        }
        .environment(\.colorScheme, .dark)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.45), radius: 30, y: 14)
    }
    #endif
}

/// One camera's WebRTC session: the web view makes the offer, Google answers through Device Access, and
/// it's renewed every four minutes (Google ends it after five). If it drops, it reconnects by itself.
@MainActor
final class LivePlayer: NSObject, WKNavigationDelegate {
    let web: WKWebView
    /// Kept current by CameraStreams (name, and whether Google can reach it).
    var camera: NestCameras.Camera
    var onStatus: ((String) -> Void)?
    private var session: String?
    private var running = false
    private var live = false
    private var work: Task<Void, Never>?
    private var renew: Task<Void, Never>?
    private var retry: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var failures = 0
    /// Google's last answer was that the camera is offline (it's tried again every minute, quietly).
    private var offline = false
    /// When this start began, for the stage times in the log (Console: subsystem com.woodruff.family, category camera).
    private var startedAt: Date?
    private static let log = Logger(subsystem: "com.woodruff.family", category: "camera")
    var isRunning: Bool { running }

    private func stage(_ what: String) {
        guard let t = startedAt else { return }
        Self.log.notice("\(self.camera.name, privacy: .public): \(what, privacy: .public) after \(String(format: "%.1f", Date().timeIntervalSince(t)), privacy: .public)s")
    }

    init(camera: NestCameras.Camera) {
        self.camera = camera
        let config = WKWebViewConfiguration()
        #if os(iOS)
        config.allowsInlineMediaPlayback = true
        #endif
        config.mediaTypesRequiringUserActionForPlayback = []
        web = WKWebView(frame: .zero, configuration: config)
        super.init()
        // A weak go-between, so the page doesn't keep the player alive forever.
        let proxy = ScriptProxy(self)
        config.userContentController.add(proxy, name: "offer")
        config.userContentController.add(proxy, name: "state")
        web.navigationDelegate = self
        #if os(iOS)
        web.isOpaque = false
        web.backgroundColor = .black
        web.scrollView.isScrollEnabled = false
        #endif
    }

    /// Starts the stream unless it's already running.
    func start() {
        guard !running else { return }
        retry?.cancel(); retry = nil
        running = true
        live = false
        startedAt = Date()
        stage("start")
        onStatus?(offline ? "Offline" : "Starting…")
        web.loadHTMLString(Self.page, baseURL: URL(string: "https://localhost/"))
    }

    /// Starts over with a fresh stream.
    func restart() { pause(); start() }

    /// Lets the stream go without a command to Google (it ends by itself within five minutes).
    func pause() {
        retry?.cancel(); retry = nil
        watchdog?.cancel(); watchdog = nil
        guard running else { return }
        running = false
        live = false
        work?.cancel(); renew?.cancel()
        session = nil
        web.evaluateJavaScript("stop()")
    }

    /// For good: no more page or messages.
    func close() {
        pause()
        web.configuration.userContentController.removeAllScriptMessageHandlers()
        web.navigationDelegate = nil
    }

    func setMuted(_ m: Bool) { web.evaluateJavaScript("setMuted(\(m))") }

    /// Dropped: try again after a wait that grows each time it fails (5 s up to a minute), or a set wait.
    private func reconnect(after fixed: UInt64? = nil) {
        guard running else { return }
        running = false
        live = false
        work?.cancel(); renew?.cancel(); watchdog?.cancel()
        session = nil
        failures += 1
        let wait = fixed ?? UInt64(min(60, 5 * (1 << min(failures - 1, 4))))
        retry?.cancel()
        retry = Task { [weak self] in
            try? await Task.sleep(nanoseconds: wait * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.start()
        }
    }

    // The web page's process was ended by the system: start again.
    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Task { @MainActor in
            guard self.running else { return }
            self.onStatus?("Reconnecting…")
            self.reconnect()
        }
    }

    #if os(iOS)
    private var stills: Task<Void, Never>?
    #endif

    /// iPhone: while the picture is live, a still of it for the TVs & Cameras widget, a few seconds in and then every
    /// two minutes.
    private func keepStills() {
        #if os(iOS)
        stills?.cancel()
        stills = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            while let self, !Task.isCancelled, self.live, self.running {
                self.saveStill()
                try? await Task.sleep(nanoseconds: 120_000_000_000)
            }
        }
        #endif
    }

    var isLive: Bool { live }

    /// The video's current frame as a JPEG at most 480 pixels across, drawn into a canvas in the page (a snapshot of
    /// the web view can miss the video). Nil before the first frame.
    func frameJPEG() async -> Data? {
        let js = """
        (() => { const v = document.querySelector('video'); if (!v || !v.videoWidth) return null;
          const k = Math.min(1, 480 / Math.max(v.videoWidth, v.videoHeight)); const c = document.createElement('canvas');
          c.width = Math.round(v.videoWidth * k); c.height = Math.round(v.videoHeight * k);
          c.getContext('2d').drawImage(v, 0, 0, c.width, c.height); return c.toDataURL('image/jpeg', 0.75); })()
        """
        guard let url = try? await web.evaluateJavaScript(js) as? String, let comma = url.firstIndex(of: ","),
              let jpeg = Data(base64Encoded: String(url[url.index(after: comma)...])), jpeg.count > 1000 else { return nil }
        return jpeg
    }

    #if os(iOS)
    private func saveStill() {
        let cam = camera
        Task { @MainActor in
            guard let jpeg = await frameJPEG() else { return }
            if PhoneWidgetShare.saveCamera(id: cam.id, name: cam.name, doorbell: cam.doorbell, jpeg: jpeg) {
                WidgetCenter.shared.reloadTimelines(ofKind: PhoneWidgetShare.tvsCamerasKind)
            }
        }
    }
    #endif

    func received(_ name: String, _ body: String) {
        if name == "state" {
            // A page being let go still reports ("closed"…): only a running stream speaks.
            guard running else { return }
            if body == "failed" { onStatus?("Reconnecting…"); reconnect(); return }
            if body == "Live" { stage("live"); live = true; failures = 0; offline = false; watchdog?.cancel(); keepStills() }
            // While it's known offline, the page's "Starting…" doesn't replace "Offline".
            if offline && body == "Starting…" { return }
            if body == "Reconnecting…", live {
                // Was live and dropped ("disconnected"): WebRTC may come back by itself; if not in 20 s, start over.
                live = false
                watchdog?.cancel()
                watchdog = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 20_000_000_000)
                    guard let self, !Task.isCancelled, self.running, !self.live else { return }
                    self.reconnect()
                }
            }
            onStatus?(body)
            return
        }
        guard running else { return }
        work?.cancel()
        work = Task { [weak self] in
            guard let self else { return }
            do {
                if !self.offline { self.onStatus?("Starting…") }
                self.stage("offer ready")
                let (answer, s) = try await NestCameras.shared.startStream(self.camera, offer: body)
                self.stage("Google answered")
                guard self.running, !Task.isCancelled else { return }
                self.offline = false
                self.onStatus?("Starting…")
                self.session = s
                let js = (try? String(data: JSONSerialization.data(withJSONObject: [answer]), encoding: .utf8)) ?? "[\"\"]"
                _ = try? await self.web.evaluateJavaScript("answer(\(js)[0])")
                self.keepAlive()
                // Not live within 30 seconds of Google's answer: start over.
                self.watchdog?.cancel()
                self.watchdog = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 30_000_000_000)
                    guard let self, !Task.isCancelled, self.running, !self.live else { return }
                    self.onStatus?("Reconnecting…")
                    self.reconnect()
                }
            } catch is CancellationError {
            } catch is NestCameras.Offline {
                // Off or off the Wi‑Fi: say so (no spinner) and look again in a minute.
                self.offline = true
                self.onStatus?("Offline")
                self.reconnect(after: 60)
            } catch {
                // Only a sign-in problem is worth words; anything else (Google busy, no internet) just retries.
                let m = error.localizedDescription
                self.onStatus?(m.contains("Connect") || m.contains("refused access") ? m : "Reconnecting…")
                if m.contains("Connect") { self.pause(); return }   // signed out: wait for a new sign-in
                self.reconnect()
            }
        }
    }

    private func keepAlive() {
        renew?.cancel()
        renew = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 210_000_000_000)   // 3½ minutes, inside Google's five
                guard let self, self.running, let s = self.session, !Task.isCancelled else { return }
                if let next = await NestCameras.shared.extend(self.camera, session: s) { self.session = next }
                else { self.reconnect(); return }
            }
        }
    }

    static let page = """
    <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
    <style>html,body{margin:0;height:100%;background:#000}video{width:100%;height:100%;object-fit:cover;background:#000}</style></head>
    <body><video id="v" autoplay playsinline muted></video><script>
    const v = document.getElementById('v');
    const say = s => window.webkit.messageHandlers.state.postMessage(s);
    const pc = new RTCPeerConnection({ iceServers: [{ urls: 'stun:stun.l.google.com:19302' }] });
    pc.addTransceiver('audio', { direction: 'recvonly' });
    pc.addTransceiver('video', { direction: 'recvonly' });
    pc.createDataChannel('data');
    const stream = new MediaStream();
    pc.ontrack = e => { stream.addTrack(e.track); v.srcObject = stream; v.play().catch(() => {}); };
    pc.onconnectionstatechange = () => {
      const s = pc.connectionState;
      say(s === 'connected' ? 'Live' : s === 'failed' ? 'failed' : s === 'disconnected' ? 'Reconnecting…' : 'Starting…');
    };
    async function start() {
      const offer = await pc.createOffer();
      await pc.setLocalDescription(offer);
      window.webkit.messageHandlers.offer.postMessage(offer.sdp);
    }
    function answer(sdp) { pc.setRemoteDescription({ type: 'answer', sdp }).catch(() => say('failed')); }
    function setMuted(m) { v.muted = m; }
    function stop() { try { pc.close(); } catch (e) {} }
    start();
    </script></body></html>
    """
}

/// Passes the page's messages to the player without the page keeping the player alive.
final class ScriptProxy: NSObject, WKScriptMessageHandler {
    weak var player: LivePlayer?
    init(_ p: LivePlayer) { player = p }
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        let name = message.name, body = message.body as? String ?? ""
        Task { @MainActor [weak self] in self?.player?.received(name, body) }
    }
}

#if os(iOS)
struct LiveWebView: UIViewRepresentable {
    var player: LivePlayer
    /// The stream's one web view, held in a frame of its own: it can move to full screen and come back.
    func makeUIView(context: Context) -> UIView {
        let host = UIView()
        host.backgroundColor = .black
        host.clipsToBounds = true
        Self.attach(player.web, to: host)
        return host
    }
    func updateUIView(_ host: UIView, context: Context) {
        if player.web.superview !== host { Self.attach(player.web, to: host) }
    }
    static func attach(_ web: WKWebView, to host: UIView) {
        web.removeFromSuperview()
        web.frame = host.bounds
        web.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.addSubview(web)
    }
}

/// A camera's live view filling the screen (turn the phone sideways for the widest picture). The arrows in the corner
/// come back out.
struct CameraFullScreen: View {
    let camera: NestCameras.Camera
    let player: LivePlayer
    @Binding var muted: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            LiveWebView(player: player)
                .aspectRatio(16 / 9, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
        }
        .overlay(alignment: .topLeading) {
            Text(camera.name).font(.headline).foregroundStyle(.white)
                .shadow(color: .black.opacity(0.6), radius: 6)
                .padding(20)
        }
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 10) {
                GlassCircle(symbol: muted ? "speaker.slash.fill" : "speaker.wave.2.fill", size: 40) {
                    muted.toggle(); player.setMuted(muted)
                }
                .accessibilityLabel(muted ? "Turn Sound On" : "Turn Sound Off")
                GlassCircle(symbol: "arrow.down.right.and.arrow.up.left", size: 40) { dismiss() }
                    .accessibilityLabel("Exit Full Screen")
            }
            .environment(\.colorScheme, .dark)
            .padding(16)
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
    }
}
#else
struct LiveWebView: NSViewRepresentable {
    var player: LivePlayer
    func makeNSView(context: Context) -> WKWebView { player.web }
    func updateNSView(_ v: WKWebView, context: Context) {}
}
#endif

// MARK: - Settings

/// Settings → Smart Home → Cameras: connect this device to the Nest cameras and list them.
struct CamerasPhoneView: View {
    @Environment(Fleet.self) private var fleet
    /// The TVs' settings as Settings already has them (the Device Access project and Google app this device signs in
    /// with), so opening the page asks the TVs nothing. Without them it reads its own, once.
    var hub: HubSettings? = nil
    private let nest = NestCameras.shared
    @State private var own = HubSettings()
    @State private var secret = ""
    @State private var open: NestCameras.Camera?

    private var settings: HubSettings { hub ?? own }
    private var project: String { settings.s?.nest?.project ?? "" }
    private var clientID: String { settings.s?.google?.clientId ?? "" }

    var body: some View {
        Form {
            if nest.connected {
                Section {
                    if nest.cameras.isEmpty { Text("No cameras found yet.").foregroundStyle(.secondary) }
                    ForEach(nest.cameras) { cam in
                        Button { open = cam } label: {
                            IconRow(symbol: "", color: .clear, title: cam.name, subtitle: !cam.online ? "Offline" : cam.webRTC ? (cam.doorbell ? "Doorbell · Live" : "Live") : "Live view not supported", value: cam.room)
                        }
                        .buttonStyle(.plain)
                        .disabled(!cam.webRTC || !cam.online)
                    }
                } footer: { Text("Tap a camera to watch it live. Their alerts are in Notifications → Camera Alerts.") }
                if !NestCameras.shared.canAlert {
                    Section { Button("Connect Again to Turn On Alerts") { NestCameras.shared.signOut() } }
                }
                Section {
                    Button("Refresh") { Task { await nest.load() } }
                    Button("Disconnect", role: .destructive) { nest.signOut() }
                }
            } else {
                Section {
                    LabeledContent("Device Access Project", value: project.isEmpty ? "Not set on the TV" : String(project.prefix(13)) + "…")
                    LabeledContent("Google Client ID", value: clientID.isEmpty ? "Not set on the TV" : String(clientID.prefix(13)) + "…")
                    SecureField("Google Client Secret", text: $secret)
                    Button {
                        Task { await nest.signIn(project: project, clientID: clientID, secret: secret) }
                    } label: {
                        HStack { Text("Connect Cameras"); if nest.busy { Spacer(); ProgressView() } }
                    }
                    .disabled(nest.busy || project.isEmpty || clientID.isEmpty || secret.isEmpty)
                } footer: {
                    Text("Uses the same Google project as your TVs (Settings → Accounts → Nest Cameras). Paste the Client Secret from Google Cloud → Credentials (the one you gave the TVs), then sign in with Google and allow the cameras. Do this on the same Wi‑Fi as your TVs.")
                }
            }
            if let e = nest.error { Section { Text(e).foregroundStyle(Palette.attention) } }
            if let hub, hub.s != nil {
                // The TVs' own camera keys and alerts (the same page as Accounts → Nest Cameras), right from here. Only
                // once their settings are read, as on Accounts: that page's fields would be blank before.
                Section {
                    PageLink("Nest Cameras") { CamerasView(hub: hub) } label: {
                        IconRow(symbol: "", color: .clear, title: "Camera Keys on the TVs", value: hub.s?.nest?.statusText)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Cameras")
        .inlineTitle()
        // Settings hadn't read the TVs' settings yet (or this page was opened from somewhere else): read them once.
        .task { await settings.loadIfNeeded(fleet) }
        .cameraPresenter($open)
    }
}

extension View {
    /// Opens a camera: on iPhone in a sheet; on the Mac filling the whole app window.
    func cameraPresenter(_ camera: Binding<NestCameras.Camera?>) -> some View { modifier(CameraPresenter(camera: camera)) }
}

struct CameraPresenter: ViewModifier {
    @Binding var camera: NestCameras.Camera?
    /// iPhone: the camera shown, set without the cover's slide (the card floats in by itself).
    @State private var shown: NestCameras.Camera?

    private func show(_ cam: NestCameras.Camera?) {
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { shown = cam }
    }

    func body(content: Content) -> some View {
        #if os(macOS)
        content.onChange(of: camera?.id, initial: true) { _, id in
            guard let id else { return }
            withAnimation(.smooth(duration: 0.3)) { CameraStreams.shared.full = id }
            camera = nil
        }
        #else
        // Over the whole screen, without the cover's slide: the camera floats in by itself.
        content
            .onChange(of: camera?.id, initial: true) { _, _ in show(camera) }
            .fullScreenCover(item: Binding(get: { shown }, set: { v in show(v); if v == nil { camera = nil } })) { cam in
                CameraLiveView(camera: cam, onClose: { show(nil); camera = nil })
            }
        #endif
    }
}


/// An alert's moment, replayed above the camera's live view when the alert is tapped.
struct CameraReplay: Equatable {
    var camera: String
    var key: String
    var event: String?
    var clip: String?
    var title: String
    var at: Date
    /// What the alert itself showed (its attachment), when it had one.
    var media: URL? = nil
    /// The Mac's small picture of the moment, from the push.
    var thumb: String? = nil
}

#if os(iOS)
/// The alert's moment filling the camera's picture box: its clip looping (muted) or its picture. Tries what the alert
/// itself showed, then Google, then the Mac's small picture; with none of them it hands over to live ([none]).
struct EventReplayView: View {
    let replay: CameraReplay
    var none: () -> Void
    @State private var file: URL?

    var body: some View {
        ZStack {
            Color.black
            if let file {
                if file.pathExtension == "mp4" {
                    LoopingClip(url: file)
                } else if let image = UIImage(contentsOfFile: file.path) {
                    Image(uiImage: image).resizable().scaledToFit()
                }
            } else {
                ProgressView().tint(.white)
            }
        }
        .task(id: replay.key) {
            if let m = replay.media, FileManager.default.fileExists(atPath: m.path) {
                file = m
                // The alert's own picture shows at once; Google's clip replaces it when it comes.
                if m.pathExtension == "mp4" { return }
            }
            if let f = await CameraEventMedia.fetch(camera: replay.camera, eventID: replay.event, clipURL: replay.clip, key: replay.key, timeout: 6) {
                file = f
                return
            }
            if file == nil, let t = replay.thumb, let f = CameraEventMedia.thumbnailFile(t) { file = f }
            if file == nil { none() }
        }
    }
}

/// A short clip playing on a loop, muted, filling its frame.
private struct LoopingClip: UIViewRepresentable {
    let url: URL

    final class ClipView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
        var looper: AVPlayerLooper?
    }

    func makeUIView(context: Context) -> ClipView {
        let v = ClipView()
        let player = AVQueuePlayer()
        player.isMuted = true
        v.looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        v.playerLayer.player = player
        v.playerLayer.videoGravity = .resizeAspect
        player.play()
        return v
    }

    func updateUIView(_ v: ClipView, context: Context) {}

    static func dismantleUIView(_ v: ClipView, coordinator: ()) {
        v.playerLayer.player?.pause()
        v.looper = nil
    }
}
#endif
