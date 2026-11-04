import SwiftUI
import WebKit
import WoodruffKit

/// Google Home / Nest cameras and doorbells, live, through Google's Device Access (the same project and Google
/// app keys the TVs use). This device signs in for itself once; the video plays over WebRTC.
@Observable @MainActor
final class NestCameras {
    static let shared = NestCameras()
    static let sdm = "https://smartdevicemanagement.googleapis.com/v1/"

    struct Camera: Identifiable, Hashable {
        var id: String          // enterprises/{project}/devices/{id}
        var name: String
        var room: String?
        var doorbell: Bool
        var webRTC: Bool
        /// Google can reach it, by its Connectivity trait (or a Pub/Sub update of it). Cameras without the
        /// trait count as online; a stream refused as offline shows "Offline" on the player instead.
        var online = true
    }

    private(set) var cameras: [Camera] = []
    private(set) var error: String?
    private(set) var busy = false
    /// Signed in (kept in memory; the Keychain is only read when it changes).
    private(set) var connected = Keychain.get("nest.refresh") != nil
    @ObservationIgnored private var refreshing: Task<String, Error>?
    @ObservationIgnored private var poll: Task<Void, Never>?

    private var project: String? { Keychain.get("nest.project") }
    private var clientID: String? { Keychain.get("nest.client") }

    func start() {
        connected = Keychain.get("nest.refresh") != nil
        canAlert = (Keychain.get("nest.scopes") ?? "").contains("pubsub")
        guard connected, !Demo.isOn else { return }
        if poll == nil { startPolling(now: true) } else { Task { await load() } }
    }

    /// Now (or after the first wait), then every five minutes: a camera going offline (or coming back)
    /// shows without a manual refresh.
    private func startPolling(now: Bool) {
        poll?.cancel()
        poll = Task { [weak self] in
            var first = now
            while !Task.isCancelled {
                if !first { try? await Task.sleep(nanoseconds: 300_000_000_000) }
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
        connected = false
        poll?.cancel(); poll = nil
        cameras = []
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

    private func call(_ method: String, _ path: String, _ body: [String: Any]? = nil) async throws -> [String: Any] {
        var r = URLRequest(url: URL(string: Self.sdm + path)!, timeoutInterval: 20)
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
            if code == 401 { Keychain.set(nil, for: "nest.access") }
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
        connected = Keychain.get("nest.refresh") != nil
        canAlert = (Keychain.get("nest.scopes") ?? "").contains("pubsub")
        guard let project, connected else { return }
        do {
            let devices = (try await call("GET", "enterprises/\(project)/devices"))["devices"] as? [[String: Any]] ?? []
            cameras = devices.compactMap { d in
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
            CameraStreams.shared.availability(cameras)
            error = nil
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
            let wait = max(nextAny, nextFor[cam] ?? .distantPast).timeIntervalSinceNow
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
    static let compactWidth: CGFloat = 260
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
            .sheet(item: $open) { cam in CameraLiveView(camera: cam) }
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
    @ObservationIgnored private var players: [String: LivePlayer] = [:]
    @ObservationIgnored private var watching = 0
    @ObservationIgnored private var idle: Task<Void, Never>?
    @ObservationIgnored private var backgroundAt: Date?

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

    /// One went off screen; if nothing is watched for two minutes, the streams are let go.
    func hide() {
        watching = max(0, watching - 1)
        guard watching == 0 else { return }
        letGoSoon(after: 120)
    }

    /// The app went to the background: keep the streams a minute, in case it's a quick switch.
    func background() { backgroundAt = Date(); letGoSoon(after: 60) }

    func foreground() {
        idle?.cancel(); idle = nil
        // Away more than a minute: iOS froze the streams, so start them fresh.
        let long = backgroundAt.map { $0.timeIntervalSinceNow < -60 } ?? false
        backgroundAt = nil
        guard watching > 0 else { return }
        for p in players.values where p.camera.online { if long { p.restart() } else { p.start() } }
    }

    private func letGoSoon(after seconds: Double) {
        idle?.cancel()
        idle = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            for p in self.players.values { p.pause() }
            for k in self.status.keys where self.status[k] != "Offline" { self.status[k] = "Paused" }
        }
    }
}

/// A camera on Home: its live picture right in the tile (muted), its name over it. Tap for the big view.
struct LiveCameraTile: View {
    var camera: NestCameras.Camera
    /// Two across: taller (4:3) so the picture isn't small, and a smaller LIVE mark so the name fits.
    var compact = false
    var open: () -> Void
    private let streams = CameraStreams.shared

    var body: some View {
        let status = camera.online ? (streams.status[camera.id] ?? "Starting…") : "Offline"
        ZStack(alignment: .bottomLeading) {
            Color.black
            if camera.webRTC && streams.expanded != camera.id {
                LiveWebView(player: streams.player(camera)).allowsHitTesting(false)
            }
            if status != "Live" || streams.expanded == camera.id {
                VStack(spacing: 8) {
                    if camera.webRTC && status.hasSuffix("…") && streams.expanded != camera.id { ProgressView().tint(.white) }
                    Text(!camera.online ? "Offline" : !camera.webRTC ? "Live view not supported" : streams.expanded == camera.id ? "Open in the big view" : status)
                        .font(.caption).foregroundStyle(.white.opacity(0.75)).multilineTextAlignment(.center).padding(.horizontal)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .center, endPoint: .bottom)
                .allowsHitTesting(false)
            HStack(alignment: .bottom) {
                Text(camera.name).font(compact ? .footnote.weight(.semibold) : .subheadline.weight(.semibold))
                    .foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.85)
                Spacer()
                if status == "Live" {
                    if compact {
                        Circle().fill(.red).frame(width: 8, height: 8).shadow(color: .red.opacity(0.8), radius: 3)
                    } else {
                        HStack(spacing: 5) {
                            Circle().fill(.red).frame(width: 7, height: 7)
                            Text("LIVE").font(.caption2.weight(.heavy)).foregroundStyle(.white)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(.black.opacity(0.45)))
                    }
                }
            }
            .padding(compact ? 10 : 12)
        }
        .aspectRatio(compact ? 4 / 3 : 16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.08)))
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onTapGesture { if camera.webRTC && camera.online { streams.expanded = camera.id; open() } }
        .contextMenu {
            if camera.webRTC && camera.online { Button("Open") { streams.expanded = camera.id; open() } }
            FavoriteButton(id: camera.id)
        }
        .onAppear { if camera.webRTC { streams.show(camera) } }
        .onDisappear { if camera.webRTC { streams.hide() } }
    }
}

// MARK: - Live view

/// The big view: the same stream as the tile (no new one), with sound.
struct CameraLiveView: View {
    var camera: NestCameras.Camera
    @Environment(\.dismiss) private var dismiss
    @State private var muted = true
    private let streams = CameraStreams.shared

    var body: some View {
        let player = streams.player(camera)
        VStack(spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(camera.name).font(.title3.bold())
                    Text(camera.online ? (streams.status[camera.id] ?? "Starting…") : "Offline").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                GlassCircle(symbol: muted ? "speaker.slash.fill" : "speaker.wave.2.fill", size: 40) {
                    muted.toggle(); player.setMuted(muted)
                }
                GlassCircle(symbol: "xmark", size: 40) { dismiss() }
            }
            LiveWebView(player: player)
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.black))
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(minWidth: 420, minHeight: 340)
        .presentationDetents([.medium, .large])
        .onAppear { streams.expanded = camera.id; streams.show(camera) }
        .onDisappear {
            player.setMuted(true)
            if streams.expanded == camera.id { streams.expanded = nil }
            streams.hide()
        }
    }
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

    func received(_ name: String, _ body: String) {
        if name == "state" {
            // A page being let go still reports ("closed"…): only a running stream speaks.
            guard running else { return }
            if body == "failed" { onStatus?("Reconnecting…"); reconnect(); return }
            if body == "Live" { live = true; failures = 0; offline = false; watchdog?.cancel() }
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
                let (answer, s) = try await NestCameras.shared.startStream(self.camera, offer: body)
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
    func makeUIView(context: Context) -> WKWebView { player.web }
    func updateUIView(_ v: WKWebView, context: Context) {}
}
#else
struct LiveWebView: NSViewRepresentable {
    var player: LivePlayer
    func makeNSView(context: Context) -> WKWebView { player.web }
    func updateNSView(_ v: WKWebView, context: Context) {}
}
#endif

// MARK: - Settings

/// Settings → Cameras: connect this device to the Nest cameras and list them.
struct CamerasPhoneView: View {
    @Environment(Fleet.self) private var fleet
    private let nest = NestCameras.shared
    @State private var project = ""
    @State private var clientID = ""
    @State private var secret = ""
    @State private var open: NestCameras.Camera?

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
                } footer: { Text("Tap a camera to watch it live. They also sit on Home.") }
                AlertsSection()
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
                    Text("Uses the same Google project as your TVs (Settings → Connections → Cameras). Paste the Client Secret from Google Cloud → Credentials (the one you gave the TVs), then sign in with Google and allow the cameras. Do this on the same Wi‑Fi as your TVs.")
                }
            }
            if let e = nest.error { Section { Text(e).foregroundStyle(Palette.attention) } }
        }
        .formStyle(.grouped)
        .navigationTitle("Cameras")
        .inlineTitle()
        .task {
            if let s = try? await fleet.hubClient()?.settings() {
                project = s.nest?.project ?? ""
                clientID = s.google?.clientId ?? ""
            }
        }
        .sheet(item: $open) { cam in CameraLiveView(camera: cam) }
    }
}
