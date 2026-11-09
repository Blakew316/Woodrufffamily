import SwiftUI
import UIKit
import UniformTypeIdentifiers
import WoodruffKit

// The iPhone app's own screens run on Apple TV (App/Shared). These are the few iPhone-only pieces they reach for,
// as Apple TV versions: no haptics, widgets, Live Activities or Apple Home here, and no live camera video (Apple TV
// has neither a web view nor Google's WebRTC library), so a camera shows its latest picture instead.

// MARK: Haptics (an Apple TV has none)

final class UIImpactFeedbackGenerator {
    enum FeedbackStyle { case light, medium, heavy, soft, rigid }
    init(style: FeedbackStyle = .medium) {}
    func impactOccurred() {}
    func impactOccurred(intensity: CGFloat) {}
    func prepare() {}
}

final class UISelectionFeedbackGenerator {
    init() {}
    func selectionChanged() {}
    func prepare() {}
}

final class UIPasteboard {
    static let general = UIPasteboard()
    var string: String?
}

// MARK: Widgets and Live Activities (not on Apple TV)

#if !canImport(WidgetKit)
final class WidgetCenter {
    static let shared = WidgetCenter()
    func reloadAllTimelines() {}
    func reloadTimelines(ofKind kind: String) {}
}
#endif

@MainActor final class LiveActivitySync {
    static let shared = LiveActivitySync()
    static var watch: String? = nil
    func sync(_ fleet: Fleet) {}
}

@MainActor final class DoorbellActivitySync {
    static let shared = DoorbellActivitySync()
    func start() {}
    func tidy() {}
}

@MainActor final class ApplianceActivitySync {
    static let shared = ApplianceActivitySync()
    func update(_ d: HomeDevice) {}
    func endAll() {}
}

@MainActor enum PhoneWidgetSync {
    static func update(_ fleet: Fleet) {}
    static func camerasChanged() {}
    static func reloadCameras() {}
}

/// The iPhone's background refresh for its widgets (no widgets here).
@MainActor enum WidgetRefresh {
    static let id = "com.woodruff.family.widgets"
    static func schedule() {}
    static func run() async {}
}

@MainActor final class HomeKitLights {
    static let shared = HomeKitLights()
    static var enabled: Bool { false }
    func start() {}
    func refresh() {}
    func refresh(device: String) {}
    func reload() {}
}

// MARK: Cameras: the latest picture, not live video

/// The camera picture's box: the Mac Studio's latest picture of the camera, filling it.
final class PictureStage: UIView {
    var videoSize: CGSize = .zero
    let image = UIImageView()
    override init(frame: CGRect) {
        super.init(frame: frame)
        image.contentMode = .scaleAspectFill
        image.clipsToBounds = true
        image.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(image)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layoutSubviews() { super.layoutSubviews(); image.frame = bounds }
}

/// The iPhone's live player, as Apple TV can have it: the Mac Studio (which keeps every camera live) hands over each
/// camera's current picture, at home or through Tailscale. The last picture shows at once; then the Mac Studio pushes
/// each new one down a single connection (about once a second for a tile, eight a second for the open camera), or,
/// from a Mac Studio without that, it's asked for one at a time.
@MainActor
final class LivePlayer: NSObject {
    let surface = PictureStage(frame: .zero)
    static var nativeEnabled: Bool { false }
    var camera: NestCameras.Camera
    var onStatus: ((String) -> Void)?
    private var feed: Task<Void, Never>?
    private var live = false
    private var misses = 0
    private var lastJPEG: Data?
    /// When a current picture last came (the "isn't sharing" message waits for a while without one).
    private var lastFresh: Date?
    /// When a picture was last kept for the tile and on disk (for next time it opens).
    private var lastKept: Date?
    private var saidNotSharing = false
    var isRunning: Bool { feed != nil }
    var isLive: Bool { live }
    /// When the feed last started.
    private(set) var lastStart: Date?

    init(camera: NestCameras.Camera) {
        self.camera = camera
        super.init()
        surface.backgroundColor = .black
    }

    /// Pictures a second: the open camera's eight, a tile's one.
    private var wantedFPS: Double { CameraStreams.shared.expanded == camera.id ? 8 : 1 }

    func start() {
        guard feed == nil else { return }
        misses = 0
        saidNotSharing = false
        let now = Date()
        lastStart = now
        // The last picture at once (this run's, or the one kept on disk), while the current one comes.
        if surface.image.image == nil, let still = CameraStreams.shared.stills[camera.id] {
            surface.image.image = still
            surface.videoSize = still.size
        }
        if let f = lastFresh, now.timeIntervalSince(f) < 15 {
            // Back after a moment (an open camera closed over it): still current.
            live = true
            onStatus?("Live")
        } else {
            lastFresh = nil
            onStatus?(surface.image.image == nil ? "Starting…" : "Updating…")
        }
        feed = Task { [weak self] in await self?.run() }
    }

    private func run() async {
        // Only for a stream that answered nothing: asked one picture at a time instead, for a minute.
        var streamOffUntil = Date.distantPast
        while !Task.isCancelled {
            let id = camera.id
            guard let token = CameraShareKey.token() else { await missed(); continue }
            let hosts = (UserDefaults.standard.string(forKey: CameraShareKey.hostsKey) ?? "").split(separator: ",").map(String.init)
            // A picture first: from the address that answered last, else whichever answers first.
            var host: String?
            if let h = Self.good, hosts.contains(h), let f = await TVCameraFeed.still(h, id: id, token: token, timeout: 2) {
                host = h
                await present(f)
            } else if let won = await TVCameraFeed.race(hosts, id: id, token: token) {
                Self.good = won.0
                host = won.0
                await present(won.1)
            }
            if Task.isCancelled { return }
            guard let host else {
                if Self.good != nil { Self.good = nil }
                await missed()
                continue
            }
            let fps = wantedFPS
            if Date() >= streamOffUntil {
                let got = await stream(host, id: id, token: token, fps: fps)
                if got == 0 && !Task.isCancelled { streamOffUntil = Date().addingTimeInterval(60) }
                continue
            }
            try? await Task.sleep(nanoseconds: UInt64(1_000_000_000 / fps))
        }
    }

    /// The Mac Studio's pictures pushed down one connection, until it ends, the player stops or the camera is opened
    /// or closed (a new speed). How many came.
    private func stream(_ host: String, id: String, token: String, fps: Double) async -> Int {
        guard let url = TVCameraFeed.url(host, path: "/mjpeg", id: id, token: token, fps: fps) else { return 0 }
        let reader = MJPEGReader(url: url)
        var got = 0
        await withTaskCancellationHandler {
            for await f in reader.frames {
                got += 1
                await present(f)
                if Task.isCancelled || wantedFPS != fps { break }
            }
        } onCancel: {
            reader.cancel()
        }
        reader.cancel()
        return got
    }

    /// Decoded off the main thread, so the remote stays smooth; then shown (unless paused or closed meanwhile).
    private func present(_ f: ShareFrame) async {
        let jpeg = f.jpeg
        // The same picture again (a Mac Studio that has no newer one yet): nothing to decode.
        if jpeg != lastJPEG {
            let img = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                let i = UIImage(data: jpeg)
                return i?.preparingForDisplay() ?? i
            }.value
            guard !Task.isCancelled, feed != nil, let img else { return }
            lastJPEG = jpeg
            surface.image.image = img
            surface.videoSize = img.size
        }
        guard !Task.isCancelled, feed != nil else { return }
        misses = 0
        let wasNotSharing = saidNotSharing
        saidNotSharing = false
        if f.age < 15 {
            lastFresh = Date()
            if !live { live = true; onStatus?("Live") }
            // Kept for the tile (shown at once next time) and on disk, now and then.
            if lastKept.map({ Date().timeIntervalSince($0) > 60 }) ?? true {
                lastKept = Date()
                CameraStreams.shared.keepStill(camera, jpeg)
            }
        } else if (live && f.age > 30) || wasNotSharing {
            // The Mac Studio has only an older picture now (its stream for the camera is starting again).
            live = false
            onStatus?("Updating…")
        }
    }

    /// No picture came: tried again soon at first, then every few seconds.
    private func missed() async {
        misses += 1
        let since = lastFresh ?? lastStart ?? Date()
        if !saidNotSharing, Date().timeIntervalSince(since) > 8 {
            saidNotSharing = true
            live = false
            onStatus?("The Mac Studio isn’t sharing this camera right now")
        }
        let wait: UInt64 = misses <= 3 ? 300_000_000 : misses <= 6 ? 1_500_000_000 : 4_000_000_000
        try? await Task.sleep(nanoseconds: wait)
    }

    func restart() { close(); start() }
    func pause() { close() }
    func close() { feed?.cancel(); feed = nil; live = false }
    func setMuted(_ m: Bool) {}
    func frameJPEG(maxSide: Int = 480) async -> Data? { lastJPEG }
    func received(_ name: String, _ body: String) {}

    /// The address that answered last, tried first next time.
    private static var good: String?
}

/// One of the Mac Studio's pictures, and how many seconds old it was when sent.
struct ShareFrame {
    let jpeg: Data
    let age: Double
}

/// Asking the Mac Studio's camera share (CameraShare on the Mac).
enum TVCameraFeed {
    /// One session for every camera: connections kept and reused, short waits.
    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 3
        c.httpMaximumConnectionsPerHost = 16
        c.httpShouldUsePipelining = true
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.urlCache = nil
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    static func url(_ host: String, path: String, id: String, token: String, fps: Double? = nil) -> URL? {
        var c = URLComponents()
        c.scheme = "http"; c.host = host; c.port = Int(CameraShareKey.port); c.path = path
        var q = [URLQueryItem(name: "id", value: id), URLQueryItem(name: "k", value: token)]
        if let fps { q.append(URLQueryItem(name: "fps", value: String(Int(fps.rounded())))) }
        c.queryItems = q
        return c.url
    }

    /// The camera's current picture from one address (nil if it doesn't answer in time).
    static func still(_ host: String, id: String, token: String, timeout: Double) async -> ShareFrame? {
        guard let url = url(host, path: "/still", id: id, token: token) else { return nil }
        let r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        guard let (d, resp) = try? await session.data(for: r), let h = resp as? HTTPURLResponse,
              h.statusCode == 200, d.count > 500 else { return nil }
        let age = h.value(forHTTPHeaderField: "X-Frame-Age").flatMap(Double.init) ?? 0
        return ShareFrame(jpeg: d, age: age)
    }

    /// Every address asked at once; the first picture back wins (and the others are let go).
    static func race(_ hosts: [String], id: String, token: String) async -> (String, ShareFrame)? {
        guard !hosts.isEmpty else { return nil }
        return await withTaskGroup(of: (String, ShareFrame)?.self) { g in
            for h in hosts {
                g.addTask { await still(h, id: id, token: token, timeout: 2.5).map { (h, $0) } }
            }
            for await r in g {
                if let r { g.cancelAll(); return r }
            }
            return nil
        }
    }
}

/// Reads the Mac Studio's picture stream (multipart/x-mixed-replace JPEGs). It reads the parts itself, or, when
/// URLSession splits them (a response for each part), takes each part's body.
final class MJPEGReader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let frames: AsyncStream<ShareFrame>
    private let out: AsyncStream<ShareFrame>.Continuation
    private var session: URLSession!
    private var buffer = Data()
    /// Reading the parts itself: the length of the part being read (nil while reading its headers).
    private var need: Int?
    private var age: Double = 0
    /// URLSession hands over one part at a time: its expected length (-1 unknown).
    private var partMode = false
    private var partLength: Int64 = -1

    init(url: URL) {
        var c: AsyncStream<ShareFrame>.Continuation?
        frames = AsyncStream(bufferingPolicy: .bufferingNewest(2)) { c = $0 }
        out = c!
        super.init()
        let cfg = URLSessionConfiguration.ephemeral
        // Nothing for this long (the Mac sends a picture at least every few seconds): it's gone.
        cfg.timeoutIntervalForRequest = 8
        cfg.timeoutIntervalForResource = 3600
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: q)
        session.dataTask(with: URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)).resume()
    }

    func cancel() {
        out.finish()
        session.invalidateAndCancel()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let http = response as? HTTPURLResponse
        let mime = (response.mimeType ?? "").lowercased()
        if let http, http.statusCode != 200 { completionHandler(.cancel); cancel(); return }
        if mime.hasPrefix("image/") {
            // A part of its own: the one before it is done.
            if partMode, partLength < 0, buffer.count > 500 { out.yield(ShareFrame(jpeg: buffer, age: age)) }
            partMode = true
            buffer = Data()
            partLength = response.expectedContentLength
            age = http?.value(forHTTPHeaderField: "X-Frame-Age").flatMap(Double.init) ?? 0
        } else if !mime.hasPrefix("multipart/") {
            completionHandler(.cancel); cancel(); return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        buffer.append(data)
        if partMode {
            if partLength > 0, buffer.count >= Int(partLength) {
                out.yield(ShareFrame(jpeg: Data(buffer.prefix(Int(partLength))), age: age))
                buffer = Data()
                partLength = 0
            }
            return
        }
        parse()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if partMode, partLength < 0, buffer.count > 500 { out.yield(ShareFrame(jpeg: buffer, age: age)) }
        cancel()
    }

    /// Each part: "--frame", its headers (Content-Length, X-Frame-Age), a blank line, then the JPEG.
    private func parse() {
        while true {
            if need == nil {
                guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                    if buffer.count > 65_536 { cancel() }
                    return
                }
                let head = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
                buffer = buffer.subdata(in: end.upperBound..<buffer.endIndex)
                var length: Int?
                age = 0
                for line in head.components(separatedBy: "\r\n") {
                    let kv = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    guard kv.count == 2 else { continue }
                    switch kv[0].lowercased() {
                    case "content-length": length = Int(kv[1])
                    case "x-frame-age": age = Double(kv[1]) ?? 0
                    default: break
                    }
                }
                guard let length, length > 0, length < 20_000_000 else { cancel(); return }
                need = length
            }
            guard let n = need, buffer.count >= n else { return }
            let jpeg = buffer.subdata(in: buffer.startIndex..<(buffer.startIndex + n))
            buffer = buffer.subdata(in: (buffer.startIndex + n)..<buffer.endIndex)
            need = nil
            if jpeg.count > 500 { out.yield(ShareFrame(jpeg: jpeg, age: age)) }
        }
    }
}

// MARK: Sign-ins (they come to the Apple TV from the family)

struct TVWebAuth {
    func authenticate(using url: URL, callbackURLScheme: String) async throws -> URL {
        throw OAuthRelay.Failure.refused("Sign in on your iPhone or Mac. The Apple TV gets the sign-in from the family.")
    }
}

struct ASWebAuthenticationSessionError: Error {
    enum Code { case canceledLogin, presentationContextNotProvided, presentationContextInvalid }
    var code: Code
}

// MARK: Controls the Apple TV doesn't have, made for the remote

/// A level (brightness, volume, speed) on the remote: select it, then left and right move it.
struct Slider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double
    var onEditingChanged: (Bool) -> Void
    @FocusState private var focused: Bool

    init(value: Binding<Double>, in range: ClosedRange<Double>, step: Double = 0, onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
        _value = value
        self.range = range
        self.step = step > 0 ? step : (range.upperBound - range.lowerBound) / 20
        self.onEditingChanged = onEditingChanged
    }

    var body: some View {
        let span = max(range.upperBound - range.lowerBound, 0.0001)
        let f = min(1, max(0, (value - range.lowerBound) / span))
        Capsule().fill(.white.opacity(0.18))
            .overlay(alignment: .leading) {
                GeometryReader { g in Capsule().fill(focused ? Color.white : IconPalette.ice).frame(width: max(12, g.size.width * f)) }
            }
            .frame(height: focused ? 14 : 10)
            .padding(.vertical, 18)
            .focusable()
            .focused($focused)
            .onMoveCommand { d in
                switch d {
                case .left: move(-step)
                case .right: move(step)
                default: break
                }
            }
            .animation(.snappy, value: focused)
    }

    private func move(_ by: Double) {
        onEditingChanged(true)
        value = min(range.upperBound, max(range.lowerBound, value + by))
        onEditingChanged(false)
    }
}

/// − and + on the remote.
struct Stepper<Label: View>: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double
    var label: Label

    init(value: Binding<Double>, in range: ClosedRange<Double>, step: Double = 1, @ViewBuilder label: () -> Label) {
        _value = value
        self.range = range
        self.step = step
        self.label = label()
    }

    var body: some View {
        HStack(spacing: 20) {
            label
            Spacer()
            Button("−") { value = max(range.lowerBound, value - step) }
            Button("+") { value = min(range.upperBound, value + step) }
        }
    }
}

/// Dragging and pinching need a touch screen: on Apple TV these never happen (the remote does it another way).
struct DragGesture: Gesture {
    struct Value: Equatable {
        var time = Date()
        var location: CGPoint = .zero
        var startLocation: CGPoint = .zero
        var translation: CGSize = .zero
        var velocity: CGSize = .zero
        var predictedEndLocation: CGPoint = .zero
        var predictedEndTranslation: CGSize = .zero
    }
    init(minimumDistance: CGFloat = 10, coordinateSpace: CoordinateSpace = .local) {}
    var body: some Gesture<Value> { TapGesture(count: 99).map { _ in Value() } }
}

struct MagnifyGesture: Gesture {
    struct Value: Equatable {
        var time = Date()
        var magnification: CGFloat = 1
        var velocity: CGFloat = 0
        var startAnchor: UnitPoint = .center
        var startLocation: CGPoint = .zero
    }
    init(minimumScaleDelta: CGFloat = 0.01) {}
    var body: some Gesture<Value> { TapGesture(count: 99).map { _ in Value() } }
}

enum TVTextSelection { case enabled, disabled }

extension View {
    func onHover(perform action: @escaping (Bool) -> Void) -> some View { self }
    func textSelection(_ s: TVTextSelection) -> some View { self }
    func statusBarHidden(_ hidden: Bool = true) -> some View { self }
    func fileImporter(isPresented: Binding<Bool>, allowedContentTypes: [UTType], onCompletion: @escaping (Result<URL, Error>) -> Void) -> some View { self }
    func fileImporter(isPresented: Binding<Bool>, allowedContentTypes: [UTType], allowsMultipleSelection: Bool, onCompletion: @escaping (Result<[URL], Error>) -> Void) -> some View { self }
}

// MARK: Photos (added from the iPhone; the Apple TV shows them)

struct TVPickerFilter {
    static let images = TVPickerFilter()
    static let videos = TVPickerFilter()
    static func any(of: [TVPickerFilter]) -> TVPickerFilter { TVPickerFilter() }
}

struct PhotosPickerItem: Hashable {
    var supportedContentTypes: [UTType] { [] }
    func loadTransferable<T: Transferable>(type: T.Type) async throws -> T? { nil }
}

struct PhotosPicker<Label: View>: View {
    init(selection: Binding<[PhotosPickerItem]>, matching: TVPickerFilter? = nil, @ViewBuilder label: () -> Label) {}
    var body: some View { EmptyView() }
}

// MARK: Alerts (the iPhones and Macs post them; an Apple TV shows none)

/// What an alert carries, as the shared code builds it (on Apple TV it isn't posted).
final class UNMutableNotificationContent {
    var title = ""
    var subtitle = ""
    var body = ""
    var sound: UNNotificationSound?
    var userInfo: [AnyHashable: Any] = [:]
    var attachments: [UNNotificationAttachment] = []
    var categoryIdentifier = ""
    var threadIdentifier = ""
}

final class UNNotificationSound {
    static let `default` = UNNotificationSound()
}

final class UNNotificationAttachment {
    init(identifier: String, url: URL, options: [AnyHashable: Any]? = nil) throws {}
}

let UNNotificationAttachmentOptionsThumbnailTimeKey = "thumbnailTime"

@MainActor
enum Notifier {
    static let handler = NotificationHandler()
    static func requestPermission() {}
    static func attach(to fleet: Fleet) {}
    static func post(_ title: String, _ body: String, id: String, category: String, tv: String?, relay: Bool = true) {}
    static func deliver(_ c: UNMutableNotificationContent, id: String, relay: Bool = true) {}
}

final class NotificationHandler: NSObject {
    @MainActor static var presentedKeys: Set<String> = []
}

/// The iPhone's widgets' shared store (no widgets on Apple TV).
enum PhoneWidgetShare {
    static let tvsCamerasKind = "com.woodruff.family.widget.tvscameras"
    static let doorbellKind = "com.woodruff.family.widget.doorbell"
    @discardableResult
    static func saveCamera(id: String, name: String, doorbell: Bool, jpeg: Data? = nil, event: String? = nil) -> Bool { false }
}

/// Pairing by the TV's QR code needs a camera: on Apple TV a TV is paired from Settings → TVs with its link instead.
struct QRScannerView: View {
    var onCode: (String) -> Void
    var body: some View {
        Text("Scanning needs a camera. Type the TV’s link instead.").padding(60)
    }
}

// MARK: Keyboard and swipes (none on the remote)

enum TVShortcut { case cancelAction, defaultAction, `return`, escape }

struct TVModifiers: OptionSet {
    let rawValue: Int
    static let command = TVModifiers(rawValue: 1)
    static let shift = TVModifiers(rawValue: 2)
    static let option = TVModifiers(rawValue: 4)
}

extension View {
    func keyboardShortcut(_ k: TVShortcut, modifiers: TVModifiers = []) -> some View { self }
    func keyboardShortcut(_ k: Character, modifiers: TVModifiers = .command) -> some View { self }
    func swipeActions<T: View>(edge: HorizontalEdge = .trailing, allowsFullSwipe: Bool = true, @ViewBuilder content: () -> T) -> some View { self }
}

/// A few lines of writing (a note), typed with the remote or the iPhone's keyboard.
struct TextEditor: View {
    @Binding var text: String
    init(text: Binding<String>) { _text = text }
    var body: some View { TextField("", text: $text, axis: .vertical) }
}

/// A part that opens: on Apple TV it's simply shown, under its name.
struct DisclosureGroup<Content: View>: View {
    let title: String
    let content: Content
    init(_ title: String, isExpanded: Binding<Bool>, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content
        }
    }
}

extension View {
    func listRowSeparator(_ v: Visibility, edges: VerticalEdge.Set = .all) -> some View { self }
}

/// The Mac's plain buttons (the section bar, Settings' list) on the remote: no white platter, a gentle lift and glow
/// on the one the remote is on.
struct TVBarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { TVBarButtonBody(configuration: configuration) }
}

private struct TVBarButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isFocused) private var focused

    var body: some View {
        configuration.label
            .background {
                if focused {
                    Capsule().fill(.ultraThinMaterial)
                        .overlay(Capsule().fill(Color(red: 0.03, green: 0.07, blue: 0.14).opacity(0.45)))
                        .overlay(Capsule().strokeBorder(.white.opacity(0.9), lineWidth: 2))
                        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
                }
            }
            .shadow(color: .black.opacity(focused ? 0.5 : 0.25), radius: 3, y: 1)
            .scaleEffect(configuration.isPressed ? 0.96 : (focused ? 1.06 : 1))
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: focused)
    }
}

/// A Home tile (a TV, speaker, light, device or camera) the remote can land on: it lifts and gets a light edge when
/// focused, and a click is its tap.
struct TVFocusTile: ViewModifier {
    @FocusState private var focused: Bool
    func body(content: Content) -> some View {
        content
            .focusable()
            .focused($focused)
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(IconPalette.ice.opacity(focused ? 0.9 : 0), lineWidth: 3)
            }
            .scaleEffect(focused ? 1.05 : 1)
            .shadow(color: .black.opacity(focused ? 0.45 : 0), radius: 20, y: 10)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: focused)
    }
}

/// A row the remote enters at its first item: Down (or Up) from another row lands there, as the TV app's shelves do.
struct FirstFocusRow<Content: View>: View {
    var spacing: CGFloat
    var alignment: VerticalAlignment = .center
    @ViewBuilder var content: Content
    @FocusState private var focus: Int?

    var body: some View {
        LazyHStack(alignment: alignment, spacing: spacing) {
            Group(subviews: content) { subs in
                ForEach(Array(subs.enumerated()), id: \.offset) { i, sub in
                    sub.focused($focus, equals: i)
                }
            }
        }
        .focusSection()
        .defaultFocus($focus, 0, priority: .userInitiated)
    }
}
