import SwiftUI
import UIKit
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

@MainActor enum AlertsRefresh {
    static let id = "com.woodruff.family.alerts"
    static func schedule() {}
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
