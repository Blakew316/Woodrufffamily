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

final class UINotificationFeedbackGenerator {
    enum FeedbackType { case success, warning, error }
    init() {}
    func notificationOccurred(_ type: FeedbackType) {}
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
/// camera's current picture about once a second, at home or through Tailscale.
@MainActor
final class LivePlayer: NSObject {
    let surface = PictureStage(frame: .zero)
    static var nativeEnabled: Bool { false }
    var camera: NestCameras.Camera
    var onStatus: ((String) -> Void)?
    private var feed: Task<Void, Never>?
    private var live = false
    private var lastJPEG: Data?
    var isRunning: Bool { feed != nil }
    var isLive: Bool { live }

    init(camera: NestCameras.Camera) {
        self.camera = camera
        super.init()
        surface.backgroundColor = .black
    }

    func start() {
        guard feed == nil else { return }
        onStatus?("Starting…")
        feed = Task { [weak self] in
            var misses = 0
            while !Task.isCancelled {
                guard let self else { return }
                if let jpeg = await Self.fetch(self.camera.id), let img = UIImage(data: jpeg) {
                    misses = 0
                    self.lastJPEG = jpeg
                    self.surface.image.image = img
                    self.surface.videoSize = img.size
                    if !self.live { self.live = true; self.onStatus?("Live") }
                } else {
                    misses += 1
                    if misses == 3 { self.live = false; self.onStatus?("The Mac Studio isn’t sharing this camera right now") }
                }
                try? await Task.sleep(nanoseconds: misses == 0 ? 1_000_000_000 : 4_000_000_000)
            }
        }
    }

    func restart() { close(); start() }
    func pause() { close() }
    func close() { feed?.cancel(); feed = nil; live = false }
    func setMuted(_ m: Bool) {}
    func frameJPEG(maxSide: Int = 480) async -> Data? { lastJPEG }
    func received(_ name: String, _ body: String) {}

    /// The address that answered last, tried first next time.
    private static var good: String?

    private static func fetch(_ id: String) async -> Data? {
        guard let token = CameraShareKey.token() else { return nil }
        let hosts = (UserDefaults.standard.string(forKey: CameraShareKey.hostsKey) ?? "").split(separator: ",").map(String.init)
        let order = (good.map { [$0] } ?? []) + hosts.filter { $0 != good }
        for h in order {
            var c = URLComponents()
            c.scheme = "http"; c.host = h; c.port = Int(CameraShareKey.port); c.path = "/still"
            c.queryItems = [URLQueryItem(name: "id", value: id), URLQueryItem(name: "k", value: token)]
            guard let url = c.url else { continue }
            var r = URLRequest(url: url)
            r.timeoutInterval = 3
            if let (d, resp) = try? await URLSession.shared.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200, d.count > 500 {
                good = h
                return d
            }
        }
        return nil
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
    var interruptionLevel: TVInterruptionLevel = .active
    var relevanceScore: Double = 0
}

enum TVInterruptionLevel { case passive, active, timeSensitive, critical }

final class UNNotificationSound {
    static let `default` = UNNotificationSound()
    static let defaultCritical = UNNotificationSound()
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
                    Capsule().fill(.white.opacity(0.16))
                        .overlay(Capsule().strokeBorder(IconPalette.ice.opacity(0.8), lineWidth: 1.5))
                }
            }
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
