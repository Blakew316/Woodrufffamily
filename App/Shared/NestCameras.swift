import SwiftUI
#if canImport(WebKit)
import WebKit
#endif
#if canImport(WidgetKit)
import WidgetKit
#endif
import os
#if os(macOS)
import AppKit
#endif
import WoodruffKit
#if os(iOS) || os(tvOS)
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

    /// The camera list came from another device: shown at once if this one has none yet (Google's list follows).
    func reloadSaved() {
        guard cameras.isEmpty else { return }
        let list = Self.saved()
        if !list.isEmpty { cameras = list }
    }

    func start() {
        let signedIn = Keychain.get("nest.refresh") != nil
        if connected != signedIn { connected = signedIn }
        let alerts = (Keychain.get("nest.scopes") ?? "").contains("pubsub")
        if canAlert != alerts { canAlert = alerts }
        guard connected, !Demo.isOn else { return }
        shareSignIn()
        #if os(iOS) || os(tvOS)
        CameraEventMedia.prune()
        #endif
        // Ready before the first camera is opened: the video engine, and a fresh Google sign-in.
        #if !os(tvOS)
        if LivePlayer.nativeEnabled { NativeRTC.prewarm() }
        #endif
        Task { _ = try? await self.token() }
        if poll == nil { startPolling(now: true) } else { Task { await load() } }
    }

    /// The sign-in, where the notification extension can use it to fetch an alert's clip (iPhone and iPad only).
    private func shareSignIn() {
        #if os(iOS) || os(tvOS)
        CameraEventMedia.keepCredentials(clientID: Keychain.get("nest.client"), secret: Keychain.get("nest.secret"),
                                         refresh: Keychain.get("nest.refresh"), access: Keychain.get("nest.access"),
                                         expires: Keychain.get("nest.expires").flatMap(Double.init))
        // And where it can ask the Mac Studio for its picture of an event.
        CameraEventMedia.keepShare(token: CameraShareKey.token(), hosts: UserDefaults.standard.string(forKey: CameraShareKey.hostsKey))
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
        #if os(iOS) || os(tvOS)
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
        // A camera command answers in a second or two: one that hangs is given up on sooner, and the player tries again.
        var r = URLRequest(url: url, timeoutInterval: path.hasSuffix(":executeCommand") ? 10 : 20)
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

    /// A look at Google's camera list already under way: everyone asking meanwhile waits for it (one request, not one
    /// each from the launch, the five-minute look, a synced sign-in and a pull to refresh).
    @ObservationIgnored private var loading: Task<Void, Never>?

    func load() async {
        if let l = loading { await l.value; return }
        let t = Task { await self.loadOnce() }
        loading = t
        await t.value
        loading = nil
    }

    private func loadOnce() async {
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
            let open = CameraStreams.shared.expanded == cam || CameraStreams.shared.full == cam || CameraStreams.shared.opening == cam
            let wait = max(open ? .distantPast : nextAny, nextFor[cam] ?? .distantPast).timeIntervalSinceNow
            if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) ; continue }
            // Half a second between any two (a refusal is retried in seconds), longer for the same camera.
            nextAny = Date().addingTimeInterval(0.5)
            nextFor[cam] = Date().addingTimeInterval(8)
            do {
                let r = try await op()
                backoff[cam] = nil
                return r
            } catch is RateLimited {
                // Google's refusals pass in seconds: try again soon (3, 6, 12… up to a minute), not after 40 s, and hold
                // the other cameras back only briefly.
                let b = min(60, (backoff[cam] ?? 1.5) * 2)
                backoff[cam] = b
                let who = cameras.first(where: { $0.id == cam })?.name ?? cam
                Logger(subsystem: "com.woodruff.family", category: "camera").notice("Google refused a camera command (too many): \(who, privacy: .public) waits \(Int(b), privacy: .public) s")
                nextFor[cam] = Date().addingTimeInterval(b)
                nextAny = Date().addingTimeInterval(3)
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
    /// Each camera's last live picture, kept between launches: its tile shows it while the stream connects.
    private(set) var stills: [String: PlatformImage] = [:]
    /// When each camera last sent an alert: its tile glows for a minute after.
    private(set) var alertAt: [String: Date] = [:]
    func noteAlert(_ id: String) { alertAt[id] = Date() }

    /// When each of those was taken.
    @ObservationIgnored private(set) var stillAt: [String: Date] = [:]
    /// The camera open in the big view (its tile shows a still while it's there).
    var expanded: String?
    /// A camera to open in the big view straight away (a tapped camera or doorbell alert).
    var requested: String?
    /// Mac: the camera filling the whole app window.
    var full: String?
    /// The alert a camera was opened from: its clip or snapshot replays above the live view.
    var replay: CameraReplay?
    /// A camera being opened from a tapped alert, before its view is up: its stream goes first, and the tiles wait.
    @ObservationIgnored private(set) var opening: String?
    @ObservationIgnored private var openingEnds: Task<Void, Never>?
    /// When a tapped alert last opened a camera (the app's launch holds its other starts back a moment for it).
    @ObservationIgnored private(set) var openedFromAlertAt: Date?
    /// Streams started ahead of their view (`warm`), each let go again if nothing shows it in time.
    @ObservationIgnored private var warmEnds: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var players: [String: LivePlayer] = [:]
    @ObservationIgnored private var watching = 0
    @ObservationIgnored private var idle: Task<Void, Never>?
    @ObservationIgnored private var backgroundAt: Date?
    /// Mac: cameras whose stream runs all the time (Vehicle Alerts watches them), never let go.
    @ObservationIgnored private(set) var pinned: Set<String> = []
    /// The Mac: cameras whose picture is being taken for an alert right now.
    @ObservationIgnored private var grabbing: Set<String> = []
    /// When each camera's stream was first asked for and isn't live yet (for Settings → General → Speed).
    @ObservationIgnored private var askedAt: [String: Date] = [:]
    /// Every stream was let go (nothing on screen); a picture taken meanwhile lets its stream go too.
    @ObservationIgnored private var letGo = false
    /// iPhone: the tiles' streams paused while a camera is open over them.
    @ObservationIgnored private var heldBack: [String] = []
    /// How many tiles and big views show each camera now (only those are started again on coming back).
    @ObservationIgnored private var shownCount: [String: Int] = [:]

    /// Lets every stream go and forgets them (signed out).
    func reset() {
        idle?.cancel(); idle = nil
        #if os(macOS)
        warming?.cancel(); warming = nil
        warmed = []
        // The off-screen window lets go of their pictures.
        for id in pinned { stopKeeping(id) }
        #endif
        for p in players.values { p.close() }
        players = [:]
        status = [:]
        watching = 0
        shownCount = [:]
        heldBack = []
        askedAt = [:]
        pinned = []
        expanded = nil
    }

    /// Whether a tile or the big view shows [id] now.
    private func isShown(_ id: String) -> Bool { (shownCount[id] ?? 0) > 0 }

    private static let stillsFolder: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("CameraStills", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static func stillFile(_ id: String) -> URL {
        let safe = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "camera"
        return stillsFolder.appendingPathComponent(String(safe.suffix(120)) + ".jpg")
    }

    private init() {
        // Read in the background as the app opens, so the tiles have them by the time Home draws them.
        Task.detached(priority: .utility) {
            var found: [String: (Data, Date)] = [:]
            let files = (try? FileManager.default.contentsOfDirectory(at: Self.stillsFolder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for f in files where f.pathExtension == "jpg" {
                let id = f.deletingPathExtension().lastPathComponent.removingPercentEncoding ?? ""
                let at = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
                if !id.isEmpty, let d = try? Data(contentsOf: f) { found[id] = (d, at) }
            }
            #if os(iOS) || os(tvOS)
            // Decoded here as well. Made from their bytes on the main thread, each camera's picture was decoded
            // there the moment Home first drew its tile.
            var decoded: [String: (UIImage, Date)] = [:]
            for (id, d) in found {
                if let img = UIImage(data: d.0) { decoded[id] = (img.preparingForDisplay() ?? img, d.1) }
            }
            let ready = decoded
            await MainActor.run {
                for (id, d) in ready where CameraStreams.shared.stills[id] == nil {
                    CameraStreams.shared.stillAt[id] = d.1
                    CameraStreams.shared.stills[id] = d.0
                }
            }
            #else
            let loaded = found
            await MainActor.run {
                for (id, d) in loaded where CameraStreams.shared.stills[id] == nil {
                    if let img = PlatformImage(data: d.0) {
                        CameraStreams.shared.stillAt[id] = d.1
                        CameraStreams.shared.stills[id] = img
                    }
                }
            }
            #endif
        }
    }

    /// A camera alert was tapped: that camera's stream starts now, before its view is up (on a cold launch, before
    /// anything else the app starts), and it goes first until the view is there.
    func openFromAlert(_ id: String) {
        opening = id
        openedFromAlertAt = Date()
        openingEnds?.cancel()
        openingEnds = Task { [weak self] in
            // The view says it's up (`opened`); if it never comes, the tiles aren't held back for long.
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard let self, !Task.isCancelled, self.opening == id else { return }
            self.opening = nil
            // The tiles that waited behind it start again (when its view is up, they do as it closes instead).
            if self.expanded == nil { self.unfocus() }
        }
        #if !os(tvOS)
        if LivePlayer.nativeEnabled { NativeRTC.prewarm() }
        #endif
        warm(id)
    }

    /// The camera's view is up (it starts and focuses its own stream).
    func opened(_ id: String) {
        guard opening != nil else { return }
        opening = nil
        openingEnds?.cancel(); openingEnds = nil
    }

    /// Starts [id]'s stream ahead of its view (a tapped alert, or one arriving while the app is open), so its live
    /// picture is ready the moment it's wanted. Let go again after [seconds] if nothing has shown it by then.
    func warm(_ id: String, letGoAfter seconds: Double = 60) {
        guard NestCameras.shared.connected, !Demo.isOn else { return }
        // Another camera is open: it keeps the bandwidth (unless this one's alert was just tapped).
        if let e = expanded ?? full, e != id, opening != id { return }
        let cam = NestCameras.shared.cameras.first { $0.id == id }
            ?? NestCameras.Camera(id: id, name: "Camera", room: nil, doorbell: false, webRTC: true)
        guard cam.webRTC, cam.online else { return }
        let p = player(cam)
        if !p.isRunning {
            if status[id] != "Live", askedAt[id] == nil { askedAt[id] = Date() }
            p.start()
        }
        warmEnds[id]?.cancel()
        warmEnds[id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.warmEnds[id] = nil
            guard let p = self.players[id], p.isRunning, !self.isShown(id), !self.pinned.contains(id),
                  !self.grabbing.contains(id), self.expanded != id, self.full != id, self.opening != id else { return }
            p.pause()
            if self.status[id] != "Offline" { self.status[id] = "Paused" }
        }
    }

    /// The cameras kept ready: the doorbell and the driveway.
    static func isImportant(_ c: NestCameras.Camera) -> Bool {
        c.doorbell || c.name.localizedCaseInsensitiveContains("door") || c.name.localizedCaseInsensitiveContains("drive")
    }

    #if os(macOS)
    /// The Mac: while one of its windows can be seen, the doorbell's and driveway's streams play (off screen when no
    /// tile shows them), so opening either is instant; once none can be seen they're let go (unless Vehicle Alerts
    /// watches them). The Mac that sends the family's alerts keeps every camera live all the time, seen or not, so
    /// each alert's picture is taken from the stream at once and a camera opened anywhere is already warm. They start
    /// a few seconds apart (all at once, Google refused some and they waited), and each renews on its own clock.
    @ObservationIgnored private(set) var warmed: Set<String> = []
    @ObservationIgnored private var warming: Task<Void, Never>?
    func keepWarm(_ on: Bool) {
        let always = PushRelay.shared.isSender
        // The Mac that sends keeps each stream's last few seconds too: an alert's picture is the moment it happened.
        FrameGrabber.keepsMoments = always
        if on || always {
            // A kept stream that's been "running" for over a minute without being live (dropped, its reconnects
            // refused) is started over: an alert's picture comes from it.
            for c in NestCameras.shared.cameras where warmed.contains(c.id) && c.online {
                if let p = players[c.id], p.isRunning, !p.isLive, let s = p.lastStart, Date().timeIntervalSince(s) > 60 { p.restart() }
            }
            let due = NestCameras.shared.cameras.filter { c in
                c.webRTC && c.online && (always || Self.isImportant(c)) && !(warmed.contains(c.id) && players[c.id]?.isRunning == true)
            }
            guard !due.isEmpty, warming == nil else { return }
            // The doorbell and driveway first.
            let ordered = due.filter(Self.isImportant) + due.filter { !Self.isImportant($0) }
            warming = Task { [weak self] in
                for (i, c) in ordered.enumerated() {
                    if i > 0 { try? await Task.sleep(nanoseconds: 4_000_000_000) }
                    guard let self, !Task.isCancelled else { return }
                    self.keepPlaying(c)
                    self.warmed.insert(c.id)
                }
                self?.warming = nil
            }
        } else {
            warming?.cancel(); warming = nil
            for id in warmed where !VehicleWatch.shared.watched.contains(id) { stopKeeping(id) }
            warmed = []
        }
    }
    #endif

    /// A live picture from [id]'s stream: kept for its tile, and on disk for next time. [image]: the same picture
    /// already decoded (Apple TV's), so the tile doesn't decode it again on the main thread.
    func keepStill(_ cam: NestCameras.Camera, _ jpeg: Data, image: PlatformImage? = nil) {
        let id = cam.id
        guard let img = image ?? PlatformImage(data: jpeg) else { return }
        #if os(macOS)
        // The Mac's TVs & Cameras widget shows it too.
        if MacCameraShare.save(id: id, name: cam.name, doorbell: cam.doorbell, jpeg: jpeg) {
            WidgetCenter.shared.reloadTimelines(ofKind: MacCameraShare.kind); WidgetCenter.shared.reloadTimelines(ofKind: "com.woodruff.family.widget.tvs")
        }
        #endif
        stillAt[id] = Date()
        stills[id] = img
        let file = Self.stillFile(id)
        DispatchQueue.global(qos: .utility).async { try? jpeg.write(to: file, options: .atomic) }
    }

    /// The camera's latest live picture as kept on disk (a JPEG), nil when there's none: an alert's picture when
    /// nothing better comes.
    func latestStill(_ id: String) -> Data? {
        guard let d = try? Data(contentsOf: Self.stillFile(id)), d.count > 500 else { return nil }
        return d
    }

    func player(_ cam: NestCameras.Camera) -> LivePlayer {
        if let p = players[cam.id] { return p }
        let p = LivePlayer(camera: cam)
        p.onStatus = { [weak self] s in
            withAnimation(.smooth) { self?.status[cam.id] = s }
            // How long the first camera took to go live (Settings → General → Speed).
            if s == "Live", let t = self?.askedAt.removeValue(forKey: cam.id) { Timings.note("Camera", since: t) }
        }
        players[cam.id] = p
        return p
    }

    /// A tile or the big view came on screen.
    func show(_ cam: NestCameras.Camera) {
        if status[cam.id] != "Live", askedAt[cam.id] == nil { askedAt[cam.id] = Date() }
        watching += 1
        shownCount[cam.id, default: 0] += 1
        idle?.cancel(); idle = nil
        letGo = false
        let p = player(cam)
        p.camera = cam
        #if os(iOS) || os(tvOS)
        // A tile coming on screen behind a camera that's open (or being opened from an alert) waits, as `focus` has
        // the others wait: the open camera has the phone's bandwidth and Google's commands to itself.
        if let f = expanded ?? opening, f != cam.id, cam.online {
            if p.isRunning { p.pause() }
            if !heldBack.contains(cam.id) { heldBack.append(cam.id) }
            if status[cam.id] != "Offline" { status[cam.id] = "Paused" }
            return
        }
        #endif
        if cam.online { p.start() } else { p.pause(); status[cam.id] = "Offline" }
    }

    /// The cameras as Google last described them: an offline one stops trying (and says Offline, not a
    /// spinner); one back online starts again if it's on screen.
    func availability(_ cams: [NestCameras.Camera]) {
        #if os(macOS)
        // The list is in (or changed): the doorbell and driveway kept ready while a window can be seen.
        defer { if Fleet.shared.isActive || PushRelay.shared.isSender { keepWarm(true) } }
        #endif
        for c in cams {
            guard let p = players[c.id] else { continue }
            let was = p.camera.online
            p.camera = c
            if !c.online {
                p.pause()
                status[c.id] = "Offline"
            } else if !was {
                if isShown(c.id) || pinned.contains(c.id) { p.start() } else { status[c.id] = "Paused" }
            }
        }
    }

    /// iPhone: a camera opened over Home. The other streams pause meanwhile (their tiles are behind it), so this
    /// one has the phone's bandwidth and Google's camera commands to itself.
    func focus(_ id: String) {
        #if os(iOS) || os(tvOS)
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
        for k in back { if let p = players[k], p.camera.online, isShown(k) || pinned.contains(k) { p.start() } }
    }

    #if os(macOS)
    /// Far off screen: a camera's picture plays here while no window shows it (a web view in no window plays no video).
    @ObservationIgnored private lazy var grabWindow: NSWindow = {
        let w = OffscreenCameraWindow(contentRect: NSRect(x: -20000, y: -20000, width: 640, height: 360), styleMask: .borderless,
                         backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.ignoresMouseEvents = true
        w.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        return w
    }()

    /// The Mac: a picture of what the camera sees now, for its alert (Google has none for these cameras). Its stream,
    /// already running or started just for this, gives its first good frame, and one started for this is let go
    /// again. Nil if no frame comes within [timeout] seconds.
    /// A frame of a camera that's already live (kept ready, or on screen): at once, nil when it isn't live.
    func liveFrame(_ id: String, maxSide: Int = 480) async -> Data? {
        guard let p = players[id], p.isLive else { return nil }
        return await p.frameJPEG(maxSide: maxSide)
    }

    func grabFrame(_ cam: NestCameras.Camera, timeout: Double = 20) async -> Data? {
        let p = player(cam)
        // Kept running but not live for a while (dropped and never came back): started again for this picture,
        // rather than waited on.
        if p.isRunning, !p.isLive, let s = p.lastStart, Date().timeIntervalSince(s) > 20 { p.restart() }
        let started = !p.isRunning
        grabbing.insert(cam.id)
        var borrowed = false
        if p.surface.window == nil, let host = grabWindow.contentView {
            p.surface.frame = host.bounds
            host.addSubview(p.surface)
            grabWindow.orderBack(nil)
            borrowed = true
        }
        if started { p.start() }
        defer {
            grabbing.remove(cam.id)
            if borrowed, p.surface.superview === grabWindow.contentView { p.surface.removeFromSuperview() }
            if grabWindow.contentView?.subviews.isEmpty ?? true { grabWindow.orderOut(nil) }
            if !pinned.contains(cam.id), letGo || (started && expanded != cam.id && full != cam.id && watching == 0) { p.pause() }
        }
        let end = Date().addingTimeInterval(timeout)
        // Already playing (on screen, or Vehicle Alerts keeping it): its picture now, no settling needed.
        if !started, p.isLive, let jpeg = await p.frameJPEG() { return jpeg }
        var firstLive: Date?
        while Date() < end {
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard p.isLive else { continue }
            if firstLive == nil { firstLive = Date() }
            // A second in, past the first frames (often grey while the picture settles).
            if let f = firstLive, Date().timeIntervalSince(f) > 1, let jpeg = await p.frameJPEG() { return jpeg }
        }
        return nil
    }

    /// The last few seconds of [id]'s stream since [since], oldest first: kept on the Mac that sends the family's
    /// alerts, so an alert's picture can be the moment it happened (`StreamMoment`).
    func moments(_ id: String, since: Date) -> [FrameGrabber.Moment] {
        players[id]?.moments(since: since) ?? []
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
        if p.surface.window == nil, let host = grabWindow.contentView {
            p.surface.frame = host.bounds
            host.addSubview(p.surface)
            grabWindow.orderBack(nil)
        }
        if cam.online, !p.isRunning { p.start() }
        return p
    }

    /// No longer kept playing (its switch went off): let go unless it's on screen.
    func stopKeeping(_ id: String) {
        guard pinned.remove(id) != nil, let p = players[id] else { return }
        if p.surface.superview === grabWindow.contentView { p.surface.removeFromSuperview() }
        if grabWindow.contentView?.subviews.isEmpty ?? true { grabWindow.orderOut(nil) }
        if letGo || (expanded != id && full != id && watching == 0) { p.pause() }
    }
    #endif

    /// One went off screen ([id]: the camera it showed); if nothing is watched for two minutes, the streams are let go.
    func hide(_ id: String? = nil) {
        if let id {
            let n = (shownCount[id] ?? 0) - 1
            shownCount[id] = n > 0 ? n : nil
        }
        watching = max(0, watching - 1)
        guard watching == 0 else { return }
        #if os(tvOS)
        // Apple TV, under a film playing full screen: let go at once (the tiles start again when it closes), so the
        // film's first minutes don't share the connection with every camera's pictures.
        letGoSoon(after: NativePlayer.shared.isOpen ? 1 : 120)
        #else
        letGoSoon(after: 120)
        #endif
    }

    #if os(tvOS)
    /// Apple TV: a film is starting full screen. Streams that no page shows any more (Home left for Watch, say) are
    /// let go now rather than two minutes after they went out of sight.
    func filmStarting() {
        guard watching == 0 else { return }
        letGoSoon(after: 0)
    }
    #endif

    #if os(tvOS)
    /// How long the streams are kept once the app is in the background. Apple TV: not at all. The app is put to sleep
    /// there, where a picture stream left open only piles up old pictures (shown in a rush on the way back) and keeps
    /// the Mac Studio taking them; coming back starts the cameras on screen again at once, from their last pictures
    /// (`foreground`).
    nonisolated static let keptInBackground: Double = 0
    #else
    /// How long the streams are kept once the app is in the background (a quick switch finds them still going).
    nonisolated static let keptInBackground: Double = 60
    #endif

    /// The app went to the background (or, on the Mac, every window went out of sight; on Apple TV, the screen saver
    /// came up): keep the streams a while, in case it's a quick switch.
    func background(after seconds: Double = CameraStreams.keptInBackground) {
        backgroundAt = Date()
        guard seconds > 0 else {
            // Each ends now, its tile left as it was (no "Paused" in the app switcher's picture of it).
            idle?.cancel(); idle = nil
            for (k, p) in players where !pinned.contains(k) && !grabbing.contains(k) { p.pause() }
            return
        }
        letGoSoon(after: seconds)
    }

    func foreground() {
        #if os(iOS) || os(tvOS)
        // Replays older than ten minutes go each time the app comes back.
        CameraEventMedia.prune()
        #endif
        idle?.cancel(); idle = nil
        letGo = false
        // Away more than a minute: iOS froze the streams, so start them fresh.
        let away = backgroundAt
        let long = away.map { $0.timeIntervalSinceNow < -60 } ?? false
        backgroundAt = nil
        // A stream started since then (a tapped alert opens its camera as the app comes back) isn't frozen: starting
        // it over would throw away its connection and wait out Google's pause between two commands for one camera.
        func fresh(_ p: LivePlayer) -> Bool { p.lastStart.map { s in away.map { s > $0 } ?? false } ?? false }
        // Streams iOS froze that nothing shows now are let go, so each starts fresh when it's shown again.
        if long { for (k, p) in players where p.isRunning && !pinned.contains(k) && !grabbing.contains(k) && !isShown(k) && !fresh(p) && warmEnds[k] == nil { p.pause() } }
        guard watching > 0 else { return }
        // Only the cameras on screen (not every stream opened since launch, nor the tiles paused behind an open
        // camera); one Vehicle Alerts kept playing isn't interrupted.
        for (k, p) in players where p.camera.online && !heldBack.contains(k) && (isShown(k) || pinned.contains(k)) {
            if long && !pinned.contains(k) && !fresh(p) { p.restart() } else { p.start() }
        }
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
            // Its last live picture, dimmed, over the black of a stream still connecting (gone once it's live).
            if status != "Live", camera.online, let still = streams.stills[camera.id] {
                Color.black.overlay { Image(platformImage: still).resizable().scaledToFill().opacity(0.55) }.clipped()
                    .allowsHitTesting(false)
            }
            if status != "Live" || streams.expanded == camera.id {
                VStack(spacing: 8) {
                    if (camera.webRTC || checking) && status.hasSuffix("…") && streams.expanded != camera.id { ProgressView().tint(.white) }
                    Text(caption(status))
                        .font(.caption).foregroundStyle(.white.opacity(0.75)).multilineTextAlignment(.center).padding(.horizontal)
                    // The picture behind is the last live one: how old it is, so it's never taken for live.
                    if camera.online, streams.stills[camera.id] != nil, let at = streams.stillAt[camera.id] {
                        Text("Last picture " + at.formatted(.relative(presentation: .named)))
                            .font(.caption2).foregroundStyle(.white.opacity(0.6))
                    }
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
        // Just sent an alert: a soft cyan glow pulses round it for a minute.
        .overlay {
            if let at = streams.alertAt[camera.id], Date().timeIntervalSince(at) < 60 {
                AlertGlow(since: at).id(at)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        #if os(tvOS)
        .modifier(TVFocusTile())
        #endif
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
        // The doorbell and the driveway start as soon as Home lays them out (not only once on screen), so they're live
        // by the time you look.
        let wanted = appeared && ready && camera.webRTC && (!inBoard || visible || CameraStreams.isImportant(camera))
        guard wanted != watching else { return }
        watching = wanted
        if wanted { streams.show(camera) } else { streams.hide(camera.id) }
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
    #if os(macOS)
    /// Mac, opened from an alert: its picture of the moment, shown until the stream is live.
    @State private var alertPicture: NSImage?
    #endif
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
                // Opened from an alert: its picture at once (else the camera's last live one, dimmed) until it's live.
                if streams.status[camera.id] != "Live", let still = alertPicture ?? streams.stills[camera.id] {
                    Image(nsImage: still)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .opacity(alertPicture == nil ? 0.55 : 1)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }
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
            .task(id: streams.replay?.key) { await loadAlertPicture() }
            #else
            phoneBody(player)
            #endif
        }
        .onAppear { streams.expanded = camera.id; streams.opened(camera.id); streams.focus(camera.id); streams.show(camera) }
        .onDisappear {
            player.setMuted(true)
            if streams.replay?.camera == camera.id { streams.replay = nil }
            if streams.expanded == camera.id { streams.expanded = nil }
            streams.hide(camera.id)
            streams.unfocus()
        }
    }

    private func close() {
        #if os(iOS) || os(tvOS)
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

    #if os(macOS)
    /// The alert's picture, from what's already on this Mac (the alert's own picture, the clip or snapshot kept for it,
    /// or the small picture in it): nothing fetched, so it shows the moment the camera opens.
    private func loadAlertPicture() async {
        guard let r = streams.replay, r.camera == camera.id else { alertPicture = nil; return }
        let kept = r.media.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil } ?? CameraEventMedia.cached(r.key)
        if let kept {
            if kept.pathExtension == "mp4" {
                if let frame = await CameraEventMedia.picture(kept, maxSide: 1280) {
                    alertPicture = NSImage(cgImage: frame, size: NSSize(width: frame.width, height: frame.height))
                    return
                }
            } else if let img = NSImage(contentsOf: kept) {
                alertPicture = img
                return
            }
        }
        if let t = r.thumb, let d = Data(base64Encoded: t), let img = NSImage(data: d) { alertPicture = img }
    }
    #endif

    #if os(iOS) || os(tvOS)
    /// The alert this camera was opened from, if any.
    private var replay: CameraReplay? { streams.replay.flatMap { $0.camera == camera.id ? $0 : nil } }

    private var subtitle: String {
        if let r = replay, !showLive { return "\(r.title) · \(r.at.formatted(date: .omitted, time: .shortened))" }
        return camera.online ? (streams.status[camera.id] ?? "Starting…") : "Offline"
    }

    /// The dot by the status. Apple TV's picture can be an older one while the Mac Studio's stream for the camera
    /// starts again ("Updating…"), so there it's red only while the picture is live.
    private var dotColor: Color {
        #if os(tvOS)
        return camera.online && streams.status[camera.id] == "Live" ? .red : .gray
        #else
        return camera.online ? .red : .gray
        #endif
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
                ZStack {
                    // The live picture connects underneath meanwhile (hidden by the replay), so Live is ready at once.
                    LiveWebView(player: player).id(reattach)
                    EventReplayView(replay: r) { withAnimation(.smooth(duration: 0.25)) { showLive = true } }
                }
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
                            Circle().fill(dotColor).frame(width: 6, height: 6)
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
                // Apple TV's cameras are pictures without sound: no sound button there (it did nothing).
                #if !os(tvOS)
                GlassCircle(symbol: muted ? "speaker.slash.fill" : "speaker.wave.2.fill", size: 30) {
                    muted.toggle(); player.setMuted(muted)
                }
                .accessibilityLabel(muted ? "Turn Sound On" : "Turn Sound Off")
                #endif
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

#if os(iOS) || os(tvOS)
typealias StageView = UIView
#else
typealias StageView = NSView
#endif

#if !os(tvOS)
/// One camera's WebRTC session: the web view makes the offer, Google answers through Device Access, and
/// it's renewed every four minutes (Google ends it after five). If it drops, it reconnects by itself.
@MainActor
final class LivePlayer: NSObject, WKNavigationDelegate {
    /// The page's web view, made only when the page is needed. The native player is tried first for every stream (and
    /// plays nearly all of them), and a web view made for each camera as Home opened held the screen up: several in a
    /// row on the main thread, a second in all on an iPhone.
    private var madeWeb: WKWebView?
    /// The stage shows the native picture (a web view made later starts hidden then).
    private var showingNative = false
    private var web: WKWebView {
        if let w = madeWeb { return w }
        let config = WKWebViewConfiguration()
        #if os(iOS) || os(tvOS)
        config.allowsInlineMediaPlayback = true
        #endif
        config.mediaTypesRequiringUserActionForPlayback = []
        let w = WKWebView(frame: .zero, configuration: config)
        #if os(iOS) || os(tvOS)
        w.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        #else
        w.autoresizingMask = [.width, .height]
        #endif
        w.frame = surface.bounds
        // Over the native picture, as when it was made first.
        surface.addSubview(w)
        // A weak go-between, so the page doesn't keep the player alive forever.
        let proxy = ScriptProxy(self)
        config.userContentController.add(proxy, name: "offer")
        config.userContentController.add(proxy, name: "state")
        w.navigationDelegate = self
        #if os(iOS) || os(tvOS)
        w.isOpaque = false
        w.backgroundColor = .black
        w.scrollView.isScrollEnabled = false
        #endif
        w.isHidden = showingNative
        madeWeb = w
        return w
    }
    /// What's put on screen (a tile, the big view, the Mac's off-screen window): the native picture, or the web page.
    let surface: PictureStage
    /// The native player, tried first for each stream; the web page takes over by itself if it doesn't go live.
    private lazy var native: NativeRTC = {
        let n = NativeRTC()
        n.onState = { [weak self] s in self?.received("state", s) }
        n.onSize = { [weak self] size in self?.surface.videoSize = size }
        return n
    }()
    private var usingNative = false
    /// The native player didn't work for this camera: the web page from now on (until the app restarts).
    private var nativeOff = false
    /// Sound was asked for (the web page needs telling again when it takes over).
    private var soundOn = false
    private var nativeWatch: Task<Void, Never>?
    /// The native player can be turned off for every camera (defaults on).
    static var nativeEnabled: Bool { UserDefaults.standard.object(forKey: "camera.native") as? Bool ?? true }
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
    /// When the stream last started.
    var lastStart: Date? { startedAt }

    /// When each step of the current start happened (for the breakdown of the first camera each launch).
    private var marks: [String: Date] = [:]
    private static var reportedBreakdown = false

    private func stage(_ what: String) {
        marks[what] = Date()
        guard let t = startedAt else { return }
        Self.log.notice("\(self.camera.name, privacy: .public): \(what, privacy: .public) after \(String(format: "%.1f", Date().timeIntervalSince(t)), privacy: .public)s")
    }

    /// The first camera to go live each launch: how long each step took, into this device's diagnostics (which sync
    /// to the Macs' log), so the iPhone's own timings can be read there.
    private func reportBreakdown() {
        guard !Self.reportedBreakdown, let t0 = marks["start"] else { return }
        Self.reportedBreakdown = true
        func at(_ k: String) -> Double? { marks[k].map { $0.timeIntervalSince(t0) } }
        let offer = at("offer ready"), answered = at("Google answered"), live = Date().timeIntervalSince(t0)
        var parts: [String] = []
        if let offer { parts.append(String(format: "offer %.1f", offer)) }
        if let offer, let answered { parts.append(String(format: "Google %.1f", answered - offer)) }
        if let answered { parts.append(String(format: "connect %.1f", live - answered)) }
        parts.append(String(format: "total %.1f s", live))
        let line = "\(camera.name): " + parts.joined(separator: ", ") + (usingNative ? " (native)" : " (web)")
        Diagnostics.shared.noteTiming(line)
    }

    init(camera: NestCameras.Camera) {
        self.camera = camera
        surface = PictureStage(frame: .zero)
        super.init()
        #if os(iOS) || os(tvOS)
        surface.backgroundColor = .black
        surface.clipsToBounds = true
        #else
        surface.wantsLayer = true
        surface.layer?.backgroundColor = NSColor.black.cgColor
        surface.layer?.masksToBounds = true
        #endif
    }

    /// Starts the stream unless it's already running.
    func start() {
        guard !running else { return }
        retry?.cancel(); retry = nil
        running = true
        live = false
        startedAt = Date()
        marks = [:]
        stage("start")
        onStatus?(offline ? "Offline" : "Starting…")
        if Self.nativeEnabled && !nativeOff { startNative(); return }
        usingNative = false
        show(native: false)
        // The page stays loaded between streams: starting again is a fresh connection in it, not a new page (quicker).
        if pageLoaded { web.evaluateJavaScript("start()") } else {
            web.loadHTMLString(Self.page, baseURL: URL(string: "https://localhost/"))
            pageLoaded = true
        }
    }

    /// The player's page has been loaded (it starts its first stream as it loads).
    private var pageLoaded = false

    /// The native player's start: its offer goes to Google the same way as the page's.
    private func startNative() {
        usingNative = true
        native.sound = soundOn
        show(native: true)
        stage("native start")
        nativeWatch?.cancel()
        Task { [weak self] in
            guard let self else { return }
            do {
                let sdp = try await self.native.offer()
                guard self.running, self.usingNative else { return }
                self.received("offer", sdp)
            } catch {
                self.fallBack("no offer: \(error.localizedDescription)")
            }
        }
    }

    /// The native player gave up on this camera: the web page plays it from now on.
    private func fallBack(_ why: String) {
        guard usingNative else { return }
        Self.log.notice("\(self.camera.name, privacy: .public): native player off (\(why, privacy: .public)), using the web player")
        nativeOff = true
        usingNative = false
        nativeWatch?.cancel()
        native.sound = false   // the web page plays it from here (told again once it's live)
        native.stop()
        show(native: false)
        work?.cancel(); renew?.cancel(); watchdog?.cancel()
        session = nil
        if running { running = false; start() }
    }

    /// Which picture the stage shows.
    private func show(native on: Bool) {
        let v = native.view
        if on && v.superview !== surface {
            v.frame = surface.bounds
            #if os(iOS) || os(tvOS)
            v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            // Under the page's web view when there is one (it's made only when the page is needed).
            if let w = madeWeb { surface.insertSubview(v, belowSubview: w) } else { surface.addSubview(v) }
            #else
            if let w = madeWeb { surface.addSubview(v, positioned: .below, relativeTo: w) } else { surface.addSubview(v) }
            #endif
            surface.picture = v
        }
        v.isHidden = !on
        showingNative = on
        madeWeb?.isHidden = on
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
        work?.cancel(); renew?.cancel(); nativeWatch?.cancel(); stills?.cancel()
        session = nil
        if usingNative { native.stop() } else { madeWeb?.evaluateJavaScript("stop()") }
    }

    /// For good: no more page or messages.
    func close() {
        pause()
        native.sound = false
        native.stop()
        pageLoaded = false
        madeWeb?.configuration.userContentController.removeAllScriptMessageHandlers()
        madeWeb?.navigationDelegate = nil
    }

    func setMuted(_ m: Bool) {
        soundOn = !m
        // The native player has sound of its own (on the iPhone, speaker only: the microphone is never opened).
        if usingNative { native.sound = !m; return }
        madeWeb?.evaluateJavaScript("setMuted(\(m))")
    }

    /// Dropped: try again after a wait that grows each time it fails (5 s up to a minute), or a set wait.
    private func reconnect(after fixed: UInt64? = nil) {
        guard running else { return }
        running = false
        live = false
        work?.cancel(); renew?.cancel(); watchdog?.cancel()
        session = nil
        failures += 1
        stage("reconnecting (failure \(failures))")
        // Quick at first (a passing hiccup), slower if it keeps failing: 1, 3, 6, 12, 24 seconds, then a minute.
        let quick: [UInt64] = [1, 3, 6, 12, 24]
        let wait = fixed ?? (failures <= quick.count ? quick[failures - 1] : 60)
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
            self.pageLoaded = false
            guard self.running else { return }
            self.onStatus?("Reconnecting…")
            self.reconnect()
        }
    }

    private var stills: Task<Void, Never>?

    /// While the picture is live, a still of it a few seconds in and then every two minutes: for the camera's tile
    /// next time it connects, and on the iPhone for the TVs & Cameras widget.
    private func keepStills() {
        stills?.cancel()
        stills = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            while let self, !Task.isCancelled, self.live, self.running {
                self.saveStill()
                try? await Task.sleep(nanoseconds: 120_000_000_000)
            }
        }
    }

    var isLive: Bool { live }

    /// The video's current frame as a JPEG at most 480 pixels across, drawn into a canvas in the page (a snapshot of
    /// the web view can miss the video). Nil before the first frame.
    func frameJPEG(maxSide: Int = 480) async -> Data? {
        if usingNative { return await native.frameJPEG(maxSide: maxSide) }
        let js = """
        (() => { const v = document.querySelector('video'); if (!v || !v.videoWidth) return null;
          const k = Math.min(1, \(maxSide) / Math.max(v.videoWidth, v.videoHeight)); const c = document.createElement('canvas');
          c.width = Math.round(v.videoWidth * k); c.height = Math.round(v.videoHeight * k);
          c.getContext('2d').drawImage(v, 0, 0, c.width, c.height); return c.toDataURL('image/jpeg', 0.75); })()
        """
        guard let page = madeWeb, let url = try? await page.evaluateJavaScript(js) as? String, let comma = url.firstIndex(of: ","),
              let jpeg = Data(base64Encoded: String(url[url.index(after: comma)...])), jpeg.count > 1000 else { return nil }
        return jpeg
    }

    #if os(macOS)
    /// The picture's last few seconds (kept on the Mac that sends the family's alerts); none from the web page.
    func moments(since: Date) -> [FrameGrabber.Moment] { usingNative ? native.moments(since: since) : [] }
    #endif

    private func saveStill() {
        let cam = camera
        Task { @MainActor in
            guard let jpeg = await frameJPEG() else { return }
            CameraStreams.shared.keepStill(cam, jpeg)
            #if os(iOS) || os(tvOS)
            // The camera widgets reload now if they haven't for a minute, otherwise a moment later (so the latest
            // picture always gets there).
            if PhoneWidgetShare.saveCamera(id: cam.id, name: cam.name, doorbell: cam.doorbell, jpeg: jpeg) {
                PhoneWidgetSync.reloadCameras()
            } else {
                PhoneWidgetSync.camerasChanged()
            }
            #endif
        }
    }

    func received(_ name: String, _ body: String) {
        if name == "state" {
            // A page being let go still reports ("closed"…): only a running stream speaks.
            guard running else { return }
            // The native player failed before it was ever live: the web page takes over.
            if body == "failed", usingNative, !live { fallBack("failed"); return }
            if body != "Live" && body != "Starting…" { stage("\(usingNative ? "native" : "web"): \(body)") }
            if body == "failed" { onStatus?("Reconnecting…"); reconnect(); return }
            if body == "Live" {
                stage(usingNative ? "live (native)" : "live")
                reportBreakdown()
                live = true; failures = 0; offline = false; watchdog?.cancel(); nativeWatch?.cancel(); keepStills()
                if !usingNative && soundOn { web.evaluateJavaScript("setMuted(false)") }
            }
            // While it's known offline, the page's "Starting…" doesn't replace "Offline".
            if offline && body == "Starting…" { return }
            if body == "Reconnecting…", live {
                // Was live and dropped ("disconnected"): WebRTC may come back by itself; if not in 8 s, start over.
                live = false
                watchdog?.cancel()
                watchdog = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 8_000_000_000)
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
                if self.usingNative {
                    do { try await self.native.answer(answer) } catch { self.fallBack("answer: \(error.localizedDescription)"); return }
                    // Not live 8 seconds after Google's answer: the web page takes over for this camera. (Counted from
                    // the answer, not the start: the wait for Google, whose commands go two seconds apart, isn't the
                    // player's.)
                    self.nativeWatch?.cancel()
                    self.nativeWatch = Task { [weak self] in
                        try? await Task.sleep(nanoseconds: 8_000_000_000)
                        guard let self, !Task.isCancelled, self.running, self.usingNative, !self.live else { return }
                        self.fallBack("not live 8 s after Google answered")
                    }
                } else {
                    _ = try? await self.web.evaluateJavaScript("answer(\(js)[0])")
                }
                self.keepAlive()
                // Not live within 15 seconds of Google's answer: start over.
                self.watchdog?.cancel()
                self.watchdog = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 15_000_000_000)
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
    let pc = null;
    function connect() {
      const me = new RTCPeerConnection({ iceServers: [{ urls: 'stun:stun.l.google.com:19302' }] });
      me.addTransceiver('audio', { direction: 'recvonly' });
      me.addTransceiver('video', { direction: 'recvonly' });
      me.createDataChannel('data');
      const stream = new MediaStream();
      me.ontrack = e => { if (pc !== me) return; stream.addTrack(e.track); v.srcObject = stream; v.play().catch(() => {}); };
      me.onconnectionstatechange = () => {
        if (pc !== me) return;
        const s = me.connectionState;
        say(s === 'connected' ? 'Live' : s === 'failed' ? 'failed' : s === 'disconnected' ? 'Reconnecting…' : 'Starting…');
      };
      pc = me;
    }
    async function start() {
      stop();
      connect();
      const me = pc;
      const offer = await me.createOffer();
      await me.setLocalDescription(offer);
      if (pc === me) window.webkit.messageHandlers.offer.postMessage(offer.sdp);
    }
    function answer(sdp) { if (pc) pc.setRemoteDescription({ type: 'answer', sdp }).catch(() => say('failed')); }
    function setMuted(m) { v.muted = m; }
    function stop() { const old = pc; pc = null; try { if (old) old.close(); } catch (e) {} }
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

#endif

#if os(iOS) || os(tvOS)
struct LiveWebView: UIViewRepresentable {
    var player: LivePlayer
    /// The stream's one web view, held in a frame of its own: it can move to full screen and come back.
    func makeUIView(context: Context) -> UIView {
        let host = UIView()
        host.backgroundColor = .black
        host.clipsToBounds = true
        Self.attach(player.surface, to: host)
        return host
    }
    func updateUIView(_ host: UIView, context: Context) {
        if player.surface.superview !== host { Self.attach(player.surface, to: host) }
    }
    static func attach(_ web: UIView, to host: UIView) {
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
                // No sound on Apple TV's cameras (see the card's controls).
                #if !os(tvOS)
                GlassCircle(symbol: muted ? "speaker.slash.fill" : "speaker.wave.2.fill", size: 40) {
                    muted.toggle(); player.setMuted(muted)
                }
                .accessibilityLabel(muted ? "Turn Sound On" : "Turn Sound Off")
                #endif
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
    /// The stream's one picture, held in a frame of its own. A view is in one place at a time, and the Mac's off-screen
    /// window (the doorbell and driveway kept live) takes it whenever it's in no window, as it is while Home is still
    /// putting its tiles in: so the frame takes it back as it comes into a window, or its tile stays black over a
    /// camera that's live off screen.
    func makeNSView(context: Context) -> NSView {
        let host = Host(player: player)
        host.take()
        return host
    }
    func updateNSView(_ v: NSView, context: Context) {
        guard let host = v as? Host else { return }
        host.player = player
        host.takeIfFree()
    }
    /// Gone (a tile scrolled away, the big view closed): a camera kept live goes back to the off-screen window.
    static func dismantleNSView(_ v: NSView, coordinator: ()) {
        guard let host = v as? Host, host.player.surface.superview === host else { return }
        host.player.surface.removeFromSuperview()
        let cam = host.player.camera
        if CameraStreams.shared.pinned.contains(cam.id) { CameraStreams.shared.keepPlaying(cam) }
    }

    final class Host: NSView {
        var player: LivePlayer
        init(player: LivePlayer) {
            self.player = player
            super.init(frame: .zero)
            wantsLayer = true
            layer?.backgroundColor = NSColor.black.cgColor
            layer?.masksToBounds = true
        }
        required init?(coder: NSCoder) { fatalError() }

        /// The picture comes here, from wherever it is.
        func take() {
            let s = player.surface
            guard s.superview !== self else { return }
            s.removeFromSuperview()
            s.frame = bounds
            s.autoresizingMask = [.width, .height]
            addSubview(s)
        }

        /// Only from nowhere or the off-screen window: never from the big view or another tile on screen.
        func takeIfFree() {
            let s = player.surface
            guard window != nil, s.superview !== self, s.window == nil || s.window is OffscreenCameraWindow else { return }
            take()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            takeIfFree()
        }

        override func layout() {
            super.layout()
            if player.surface.superview === self { player.surface.frame = bounds }
        }
    }
}

/// The far-off window the Mac's cameras play in while no window shows them.
final class OffscreenCameraWindow: NSWindow {}
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
                        #if os(tvOS)
                        guard !nest.busy else { return }
                        #endif
                        Task { await nest.signIn(project: project, clientID: clientID, secret: secret) }
                    } label: {
                        HStack { Text("Connect Cameras"); if nest.busy { Spacer(); ProgressView() } }
                    }
                    #if os(tvOS)
                    // Apple TV: not switched off while it connects. A button the remote is on that's switched off loses
                    // the focus, which jumped somewhere else on the page (a press meanwhile does nothing).
                    .disabled(project.isEmpty || clientID.isEmpty || secret.isEmpty)
                    #else
                    .disabled(nest.busy || project.isEmpty || clientID.isEmpty || secret.isEmpty)
                    #endif
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
        .familyFormStyle()
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

    #if os(iOS) || os(tvOS)
    /// A cover asked for while the app is still starting (a tapped alert opening it) can be dropped by the system: if
    /// the camera's view isn't up a moment later, it's asked for again (twice at most).
    private func confirm(_ id: String?, tries: Int = 2) {
        guard let id, tries > 0 else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard let cam = shown, cam.id == id, CameraStreams.shared.expanded != id else { return }
            show(nil)
            try? await Task.sleep(nanoseconds: 60_000_000)
            guard camera?.id == id else { return }
            show(cam)
            confirm(id, tries: tries - 1)
        }
    }
    #endif

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
            .onChange(of: camera?.id, initial: true) { _, _ in show(camera); confirm(camera?.id) }
            #if os(iOS)
            // A camera asked for from elsewhere (a tapped alert) opens over everything (`CameraRequest`): one open
            // from this page closes for it, unless it's that same camera, which is then open already.
            .onChange(of: CameraStreams.shared.requested) { _, id in
                guard let id, let open = shown else { return }
                if open.id == id { CameraStreams.shared.requested = nil } else { show(nil); camera = nil }
            }
            #endif
            .fullScreenCover(item: Binding(get: { shown }, set: { v in show(v); if v == nil { camera = nil } })) { cam in
                CameraLiveView(camera: cam, onClose: { show(nil); camera = nil })
            }
        #endif
    }
}

#if os(iOS)
/// iPhone and iPad: a camera asked for from outside the page it's on (a tapped alert, the widget) opens from the
/// topmost screen, as the film player does (`NativePlayer.show`), so it comes up over a sheet or the film player too.
/// As a cover of the window's root it opened nothing while anything else was presented.
@MainActor
enum CameraRequest {
    /// The camera's view, on screen or on its way there.
    private static var cover: UIHostingController<CameraLiveView>?
    /// Times it has been put on screen for this request (put up again if one didn't take).
    private static var attempts = 0

    /// The camera asked for changed (nil: none is asked for any more).
    static func changed(_ cam: NestCameras.Camera?) {
        // Another camera's view put up from here goes first (with its full-screen picture, if that's up).
        if let old = cover, old.rootView.camera.id != cam?.id {
            cover = nil
            old.presentingViewController?.dismiss(animated: false)
        }
        guard let cam, cover == nil else { return }
        let id = cam.id
        let c = UIHostingController(rootView: CameraLiveView(camera: cam, onClose: { closed(id) }))
        // Over the whole screen, with what's under it still showing behind: the camera floats in by itself.
        c.modalPresentationStyle = .overFullScreen
        cover = c
        attempts = 0
        show(c, tries: 0)
    }

    /// Shows it once the screen it goes over is there and still (the app still opening, a sheet closing), and a camera
    /// open on the page has closed for it (`CameraPresenter`).
    private static func show(_ c: UIHostingController<CameraLiveView>, tries: Int) {
        guard cover === c, c.presentingViewController == nil else { return }
        let top = NativePlayer.top()
        let busy = top.map { $0.transitionCoordinator != nil || $0.presentedViewController != nil || $0.isBeingPresented || $0.isBeingDismissed || $0.viewIfLoaded?.window == nil } ?? true
        if (busy || CameraStreams.shared.expanded != nil) && tries < 40 {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 50_000_000)
                show(c, tries: tries + 1)
            }
            return
        }
        // Nowhere to show it: its alert, tapped again, asks again.
        guard let top else { gone(c); return }
        attempts += 1
        let attempt = attempts
        // A keyboard that's up (the remote's keyboard sheet) goes down: it would stay up over the camera.
        top.viewIfLoaded?.endEditing(true)
        c.view.backgroundColor = .clear
        top.present(c, animated: false)
        let took = c.presentingViewController != nil
        // Looked at each second while it's wanted. UIKit refuses a presentation silently (the screen under it still
        // changing, the app still opening): one that didn't take is put up again over whatever is on top then (a few
        // times at most). One that was up and went without its own ✕ (the sheet it was over closed) is no longer
        // asked for, so its alert, tapped again, opens it again.
        Task { @MainActor in
            var wasUp = took
            while cover === c, attempts == attempt {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard cover === c, attempts == attempt else { return }
                if c.presentingViewController != nil { wasUp = true; continue }
                if !wasUp && attempt < 4 { show(c, tries: 40) } else { gone(c) }
                return
            }
        }
    }

    /// Closed from its own view (its ✕, a tap beside it, a swipe down).
    private static func closed(_ id: String) {
        guard let c = cover, c.rootView.camera.id == id else { return }
        c.presentingViewController?.dismiss(animated: false)
        gone(c)
    }

    /// It has gone: no camera is asked for any more.
    private static func gone(_ c: UIHostingController<CameraLiveView>) {
        guard cover === c else { return }
        cover = nil
        if CameraStreams.shared.requested == c.rootView.camera.id { CameraStreams.shared.requested = nil }
    }
}
#endif


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

#if os(iOS) || os(tvOS)
/// The alert's moment filling the camera's picture box: its clip looping (muted) or its picture. Shows at once what's
/// already on this device (the clip or picture the notification extension kept, what the alert itself showed, else the
/// Mac's small picture from the push), then Google's clip when that comes: played straight from Google while it's
/// still downloading, and from the file once it's here. With none of them it hands over to live ([none]); a clip that
/// doesn't come leaves the picture up with Retry.
struct EventReplayView: View {
    let replay: CameraReplay
    var none: () -> Void
    @State private var file: URL?
    @State private var image: UIImage?
    /// Google's clip, playing from Google while the file downloads.
    @State private var remote: AVURLAsset?
    /// The clip's first frame is on screen (the picture under it can go).
    @State private var clipReady = false
    /// Google's clip (or snapshot) didn't come in time: the picture stays, with Retry.
    @State private var failed = false
    @State private var attempt = 0

    /// How long Google's clip is waited for before Retry shows (a picture stays up meanwhile).
    private static let wait: Double = 8

    var body: some View {
        ZStack {
            Color.black
            // The picture stays under the clip until the clip's first frame is up (no black flash between them).
            if let image, !clipReady {
                Image(uiImage: image).resizable().scaledToFit()
            }
            if let file, file.pathExtension == "mp4" {
                LoopingClip(asset: AVURLAsset(url: file)) { clipReady = true }.id(file)
            } else if let remote {
                LoopingClip(asset: remote) { clipReady = true }.id(ObjectIdentifier(remote))
            } else if image == nil {
                ProgressView().tint(.white)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if failed {
                Button("Retry") { failed = false; attempt += 1 }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.glass)
                    .padding(10)
            }
        }
        .task(id: "\(replay.key)#\(attempt)") { await load() }
    }

    private func load() async {
        failed = false
        // Nothing waits before the first picture: no sign-in, no network. A clip kept here is the best there is.
        let here = [CameraEventMedia.cached(replay.key), replay.media].compactMap { $0 }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        let kept = here.first { $0.pathExtension == "mp4" } ?? here.first
        if let kept, kept.pathExtension == "mp4" { file = kept; return }
        if image == nil, let t = replay.thumb, let d = Data(base64Encoded: t) { image = await Self.decode(d) }
        if let kept { await show(kept) }
        guard !Task.isCancelled else { return }
        // Google's clip while it downloads (it plays as it comes in), and the whole file at the same time: whichever
        // shows first. A picture kept is replaced only by the clip.
        let clipURL = replay.clip.flatMap { $0.isEmpty ? nil : URL(string: $0) }
        let streaming: Task<Void, Never>? = clipURL.map { u in Task { await stream(u) } }
        let waited = file == nil && image == nil ? 5 : Self.wait
        let got = await CameraEventMedia.fetch(camera: replay.camera, eventID: replay.event, clipURL: replay.clip,
                                               key: replay.key, timeout: waited)
        streaming?.cancel()
        guard !Task.isCancelled else { return }
        if let got, got != kept {
            // Already playing from Google: kept on this device for next time, the clip on screen isn't started over.
            if got.pathExtension == "mp4" { if remote == nil { file = got } } else { await show(got) }
            return
        }
        if remote != nil || file?.pathExtension == "mp4" { return }
        if file == nil && image == nil { none(); return }
        // Only a picture: if a clip (or Google's snapshot) was to come, it can be asked for again.
        failed = clipURL != nil || (file == nil && replay.event != nil)
    }

    /// Google's clip played from Google, as soon as it's there (it's made a few seconds after the event), with the
    /// sign-in the download uses. Asked again every second or so until the file download ends.
    private func stream(_ u: URL) async {
        let tokenJob: @Sendable () async -> String? = { await CameraEventMedia.token() }
        guard let token = await FirstOf<String>(1).run([tokenJob], deadline: Date().addingTimeInterval(3)) else { return }
        while !Task.isCancelled, remote == nil {
            let asset = AVURLAsset(url: u, options: ["AVURLAssetHTTPHeaderFieldsKey": ["Authorization": "Bearer \(token)"]])
            let check: @Sendable () async -> Bool? = { ((try? await asset.load(.isPlayable)) ?? false) ? true : nil }
            if await FirstOf<Bool>(1).run([check], deadline: Date().addingTimeInterval(3)) == true {
                guard !Task.isCancelled, file?.pathExtension != "mp4" else { return }
                remote = asset
                return
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    private func show(_ f: URL) async {
        if f.pathExtension == "mp4" { file = f; return }
        let path = f.path
        let img = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let i = UIImage(contentsOfFile: path) else { return nil }
            return i.preparingForDisplay() ?? i
        }.value
        if let img { file = f; image = img }
    }

    /// The push's small picture, decoded off the main thread.
    private static func decode(_ d: Data) async -> UIImage? {
        await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let i = UIImage(data: d) else { return nil }
            return i.preparingForDisplay() ?? i
        }.value
    }
}

/// A short clip playing on a loop, muted, filling its frame: a file on this device, or Google's clip as it streams in.
private struct LoopingClip: UIViewRepresentable {
    let asset: AVAsset
    /// Its first frame is on screen.
    var onReady: () -> Void = {}

    final class ClipView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
        var looper: AVPlayerLooper?
        var ready: NSKeyValueObservation?
    }

    func makeUIView(context: Context) -> ClipView {
        let v = ClipView()
        let player = AVQueuePlayer()
        player.isMuted = true
        // Plays as soon as there's a frame, rather than waiting to buffer more (a few seconds of clip).
        player.automaticallyWaitsToMinimizeStalling = false
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 1
        v.looper = AVPlayerLooper(player: player, templateItem: item)
        v.playerLayer.player = player
        v.playerLayer.videoGravity = .resizeAspect
        let ready = onReady
        v.ready = v.playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { layer, _ in
            guard layer.isReadyForDisplay else { return }
            DispatchQueue.main.async { ready() }
        }
        player.play()
        return v
    }

    func updateUIView(_ v: ClipView, context: Context) {}

    static func dismantleUIView(_ v: ClipView, coordinator: ()) {
        v.ready?.invalidate(); v.ready = nil
        v.playerLayer.player?.pause()
        v.looper = nil
    }
}
#endif


/// A camera tile's glow after an alert: the app icon's cyan, breathing round its edge, gone a minute after the alert.
private struct AlertGlow: View {
    let since: Date
    @State private var bright = false
    @State private var over = false
    /// Faded away and taken off the tile: its breathing repeats for as long as it's there, seen or not.
    @State private var gone = false

    var body: some View {
        if !gone {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(IconPalette.cyan.opacity(bright ? 0.95 : 0.35), lineWidth: bright ? 2.5 : 1.5)
                .shadow(color: IconPalette.cyan.opacity(bright ? 0.7 : 0.2), radius: bright ? 12 : 4)
                .opacity(over ? 0 : 1)
                .allowsHitTesting(false)
                .onAppear { withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { bright = true } }
                .task {
                    let left = max(0, 60 - Date().timeIntervalSince(since))
                    try? await Task.sleep(nanoseconds: UInt64(left * 1_000_000_000))
                    withAnimation(.easeOut(duration: 0.6)) { over = true }
                    // Gone once it has faded, rather than breathing unseen (every frame, beside Home's scrolling)
                    // until something else about the tile changes.
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    if !Task.isCancelled { gone = true }
                }
        }
    }
}
