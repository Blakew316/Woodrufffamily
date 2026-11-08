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

/// The camera picture's box (the iPhone's is Google's WebRTC video).
final class PictureStage: UIView {
    var videoSize: CGSize = .zero
}

/// The iPhone's live player, as Apple TV can have it: no stream (no web view or WebRTC here), so the tile and the
/// big view show the camera's latest picture and say so.
@MainActor
final class LivePlayer: NSObject {
    let surface = PictureStage(frame: .zero)
    static var nativeEnabled: Bool { false }
    var camera: NestCameras.Camera
    var onStatus: ((String) -> Void)?
    var isRunning: Bool { false }
    var isLive: Bool { false }

    init(camera: NestCameras.Camera) {
        self.camera = camera
        super.init()
        surface.backgroundColor = .black
    }

    func start() { onStatus?("Latest picture") }
    func restart() { start() }
    func pause() {}
    func close() {}
    func setMuted(_ m: Bool) {}
    func frameJPEG() async -> Data? { nil }
    func received(_ name: String, _ body: String) {}
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
