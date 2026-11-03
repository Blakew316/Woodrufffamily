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
    }

    private(set) var cameras: [Camera] = []
    private(set) var error: String?
    private(set) var busy = false
    var connected: Bool { Keychain.get("nest.refresh") != nil }

    private var project: String? { Keychain.get("nest.project") }
    private var clientID: String? { Keychain.get("nest.client") }

    func start() {
        guard connected, !Demo.isOn else { return }
        Task { await load() }
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
                    URLQueryItem(name: "scope", value: "https://www.googleapis.com/auth/sdm.service"),
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
        } catch { self.error = error.localizedDescription }
    }

    func signOut() {
        for k in ["nest.refresh", "nest.access", "nest.expires"] { Keychain.set(nil, for: k) }
        cameras = []
    }

    private func store(_ t: [String: Any]) {
        if let a = t["access_token"] as? String { Keychain.set(a, for: "nest.access") }
        if let r = t["refresh_token"] as? String { Keychain.set(r, for: "nest.refresh") }
        let exp = (t["expires_in"] as? Double) ?? Double((t["expires_in"] as? Int) ?? 3600)
        Keychain.set(String(Date().addingTimeInterval(exp - 120).timeIntervalSince1970), for: "nest.expires")
    }

    private func token() async throws -> String {
        if let a = Keychain.get("nest.access"), let e = Keychain.get("nest.expires").flatMap(Double.init), e > Date().timeIntervalSince1970 { return a }
        guard let r = Keychain.get("nest.refresh"), let id = clientID, let sec = Keychain.get("nest.secret") else {
            throw OAuthRelay.Failure.refused("Connect the cameras again.")
        }
        store(try await formPost("https://oauth2.googleapis.com/token", ["refresh_token": r, "client_id": id, "client_secret": sec, "grant_type": "refresh_token"]))
        return Keychain.get("nest.access") ?? ""
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
            let msg = ((json["error"] as? [String: Any])?["message"] as? String) ?? "Google answered \(code)."
            throw OAuthRelay.Failure.refused(code == 403 ? "Google refused access: \(msg)" : msg)
        }
        return json
    }

    func load() async {
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
                return Camera(id: name, name: label, room: room, doorbell: doorbell, webRTC: webRTC)
            }
            .sorted { ($0.doorbell ? 0 : 1, $0.name) < ($1.doorbell ? 0 : 1, $1.name) }
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    // MARK: Live

    func startStream(_ cam: Camera, offer: String) async throws -> (answer: String, session: String) {
        let r = try await call("POST", "\(cam.id):executeCommand", [
            "command": "sdm.devices.commands.CameraLiveStream.GenerateWebRtcStream", "params": ["offerSdp": offer],
        ])
        let res = r["results"] as? [String: Any] ?? [:]
        guard let a = res["answerSdp"] as? String, let s = res["mediaSessionId"] as? String else { throw OAuthRelay.Failure.refused("The camera didn’t answer.") }
        return (a, s)
    }

    func extend(_ cam: Camera, session: String) async -> String {
        let r = try? await call("POST", "\(cam.id):executeCommand", [
            "command": "sdm.devices.commands.CameraLiveStream.ExtendWebRtcStream", "params": ["mediaSessionId": session],
        ])
        return ((r?["results"] as? [String: Any])?["mediaSessionId"] as? String) ?? session
    }

    func stop(_ cam: Camera, session: String) async {
        _ = try? await call("POST", "\(cam.id):executeCommand", [
            "command": "sdm.devices.commands.CameraLiveStream.StopWebRtcStream", "params": ["mediaSessionId": session],
        ])
    }
}

// MARK: - Home section

struct CamerasSection: View {
    var room: String? = nil
    private let nest = NestCameras.shared
    @State private var open: NestCameras.Camera?

    private var shown: [NestCameras.Camera] {
        let list = room.map { r in nest.cameras.filter { ($0.room ?? "") == r || SmartHome.shared.rooms[$0.id] == r } } ?? nest.cameras
        return HomeLayout.shared.arrange(list, in: "cameras")
    }

    var body: some View {
        if !shown.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Text("Cameras").font(.title2.bold())
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 14)], spacing: 14) {
                    ForEach(shown) { cam in
                        Button { open = cam } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                Image(systemName: cam.doorbell ? "video.doorbell.fill" : "video.fill")
                                    .font(.system(size: 20, weight: .semibold)).foregroundStyle(.secondary)
                                Spacer(minLength: 0)
                                Text(cam.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                                Text(cam.webRTC ? "Tap for Live" : "Live view not supported").font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .glass(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .disabled(!cam.webRTC)
                    }
                }
            }
            .sheet(item: $open) { cam in CameraLiveView(camera: cam) }
        }
    }
}

// MARK: - Live view

struct CameraLiveView: View {
    var camera: NestCameras.Camera
    @Environment(\.dismiss) private var dismiss
    @State private var muted = true
    @State private var status = "Connecting…"
    @State private var player = LivePlayer()

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(camera.name).font(.title3.bold())
                    Text(status).font(.subheadline).foregroundStyle(.secondary)
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
        .task {
            player.onStatus = { status = $0 }
            await player.run(camera)
        }
        .onDisappear { player.end() }
    }
}

/// The WebRTC session: the web view makes the offer, Google answers through Device Access, and the stream is
/// renewed every four minutes (Google ends it after five).
@MainActor
final class LivePlayer: NSObject, WKScriptMessageHandler {
    let web: WKWebView
    var onStatus: ((String) -> Void)?
    private var camera: NestCameras.Camera?
    private var session: String?
    private var renew: Task<Void, Never>?

    override init() {
        let config = WKWebViewConfiguration()
        #if os(iOS)
        config.allowsInlineMediaPlayback = true
        #endif
        config.mediaTypesRequiringUserActionForPlayback = []
        web = WKWebView(frame: .zero, configuration: config)
        super.init()
        config.userContentController.add(self, name: "offer")
        config.userContentController.add(self, name: "state")
        #if os(iOS)
        web.isOpaque = false
        web.backgroundColor = .black
        web.scrollView.isScrollEnabled = false
        #endif
    }

    func run(_ cam: NestCameras.Camera) async {
        camera = cam
        web.loadHTMLString(Self.page, baseURL: URL(string: "https://localhost/"))
    }

    func setMuted(_ m: Bool) { web.evaluateJavaScript("setMuted(\(m))") }

    func end() {
        renew?.cancel()
        web.evaluateJavaScript("stop()")
        if let cam = camera, let s = session { Task { await NestCameras.shared.stop(cam, session: s) } }
        session = nil
    }

    nonisolated func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        let name = message.name
        let body = message.body as? String ?? ""
        Task { @MainActor in
            if name == "state" { self.onStatus?(body); return }
            guard let cam = self.camera else { return }
            do {
                let (answer, s) = try await NestCameras.shared.startStream(cam, offer: body)
                self.session = s
                let js = (try? String(data: JSONSerialization.data(withJSONObject: [answer]), encoding: .utf8)) ?? "[\"\"]"
                try? await self.web.evaluateJavaScript("answer(\(js)[0])")
                self.renew = Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 240_000_000_000)
                        guard let self, let cam = self.camera, let s = self.session, !Task.isCancelled else { return }
                        self.session = await NestCameras.shared.extend(cam, session: s)
                    }
                }
            } catch { self.onStatus?(error.localizedDescription) }
        }
    }

    static let page = """
    <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
    <style>html,body{margin:0;height:100%;background:#000}video{width:100%;height:100%;object-fit:contain;background:#000}</style></head>
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
      say(s === 'connected' ? 'Live' : s === 'failed' ? 'Couldn’t connect. Close and try again.' : s === 'disconnected' ? 'Reconnecting…' : 'Connecting…');
    };
    async function start() {
      const offer = await pc.createOffer();
      await pc.setLocalDescription(offer);
      window.webkit.messageHandlers.offer.postMessage(offer.sdp);
    }
    function answer(sdp) { pc.setRemoteDescription({ type: 'answer', sdp }); }
    function setMuted(m) { v.muted = m; }
    function stop() { try { pc.close(); } catch (e) {} }
    start();
    </script></body></html>
    """
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
                            IconRow(symbol: "", color: .clear, title: cam.name, subtitle: cam.webRTC ? "Live" : "Live view not supported", value: cam.room)
                        }
                        .buttonStyle(.plain)
                        .disabled(!cam.webRTC)
                    }
                } footer: { Text("Tap a camera to watch it live. They also sit on Home.") }
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
