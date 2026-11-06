import Foundation
import UserNotifications
import WoodruffKit
#if os(macOS)
import AppKit
#endif

/// Local notifications: announcements sent to this device, and TVs that go off or need attention, each with
/// actions (open the TV, hide the alert, open the remote).
@MainActor
enum Notifier {
    static let handler = NotificationHandler()

    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    static func attach(to fleet: Fleet) {
        let center = UNUserNotificationCenter.current()
        center.delegate = handler
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "tv.alert", actions: [
                UNNotificationAction(identifier: "open", title: "View TV", options: [.foreground]),
                UNNotificationAction(identifier: "hide", title: "Hide Alert", options: []),
            ], intentIdentifiers: []),
            UNNotificationCategory(identifier: "tv.state", actions: [
                UNNotificationAction(identifier: "remote", title: "Open Remote", options: [.foreground]),
            ], intentIdentifiers: []),
            UNNotificationCategory(identifier: "message", actions: [
                UNNotificationAction(identifier: "open", title: "Open", options: [.foreground]),
            ], intentIdentifiers: []),
        ])
        requestPermission()
        fleet.onChange = { event in
            let fleetAlerts = UserDefaults.standard.object(forKey: "notifyFleet") as? Bool ?? true
            switch event {
            case .message(let m, let from):
                post(m.title, m.body?.isEmpty == false ? m.body! : "From \(m.from ?? from)", id: m.id, category: "message", tv: nil, relay: false)
            case .wentOffline(let tv) where fleetAlerts:
                post("Can’t Reach \(tv.name)", "It’s on the network, but Woodruff on it isn’t answering.", id: "off-\(tv.id)", category: "tv.state", tv: tv.id)
            case .needsAttention(let tv) where fleetAlerts:
                post("\(tv.name) Needs Attention", tv.health?.first ?? (tv.link == "refused" ? "Its link stopped working." : ""),
                     id: "att-\(tv.id)", category: "tv.alert", tv: tv.id)
            case .cameOnline(let tv):
                // It answers again: its "Can't Reach" alert no longer holds, so it doesn't stay standing.
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["off-\(tv.id)"])
            default: break
            }
        }
    }

    static func post(_ title: String, _ body: String, id: String, category: String, tv: String?, relay: Bool = true) {
        let c = UNMutableNotificationContent()
        c.title = title
        // A TV's words, pointing at Settings as it is now (a TV not yet updated names older pages).
        c.body = currentSettingsPaths(body)
        c.sound = .default
        c.categoryIdentifier = category
        c.threadIdentifier = tv ?? "messages"
        if let tv { c.userInfo = ["tv": tv] }
        deliver(c, id: id, relay: relay)
    }

    /// Shows an alert here and, on the Mac that sends for the family, pushes the same alert (same ID) to every
    /// iPhone, so it arrives even when Woodruff is closed there.
    static func deliver(_ c: UNMutableNotificationContent, id: String, relay: Bool = true) {
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: c, trigger: nil))
        #if os(macOS)
        if relay {
            let info = c.userInfo.reduce(into: [String: String]()) { out, kv in if let k = kv.key as? String, let v = kv.value as? String { out[k] = v } }
            PushRelay.shared.relay(id: id, title: c.title, body: c.body, category: c.categoryIdentifier.isEmpty ? nil : c.categoryIdentifier, userInfo: info, sound: c.sound != nil)
        }
        #endif
    }
}

/// What a tap on a notification (or one of its actions) does.
final class NotificationHandler: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    // The completion-handler forms, each answered on the main thread: with the async forms the system's completion ran
    // on a background thread when the method returned, and UIKit (updating the app's snapshot after a tapped alert)
    // aborted the app.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // Kept in Notification Center too: an alert that arrives while Woodruff is open was only a passing banner.
        DispatchQueue.main.async { completionHandler([.banner, .list, .sound]) }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.handle(response) }
            completionHandler()
        }
    }

    /// The picture or clip the alert itself carried (what the notification extension attached), copied out of the
    /// notification's store so the camera view can show the very same moment.
    private static func attachedMedia(_ content: UNNotificationContent) -> URL? {
        guard let a = content.attachments.first else { return nil }
        let url = a.url
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + url.pathExtension)
        return (try? FileManager.default.copyItem(at: url, to: copy)) != nil ? copy : nil
    }

    @MainActor private func handle(_ response: UNNotificationResponse) {
        let tvID = response.notification.request.content.userInfo["tv"] as? String
        let cameraID = response.notification.request.content.userInfo["camera"] as? String
        let action = response.actionIdentifier
        do {
            let fleet = Fleet.shared
            // A camera or doorbell alert: straight to that camera's live view.
            if let cameraID, action == UNNotificationDefaultActionIdentifier {
                UserDefaults.standard.set("home", forKey: "section")
                // What it saw, replayed above the live view.
                let info = response.notification.request.content.userInfo
                func text(_ k: String) -> String? { (info[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
                CameraStreams.shared.replay = CameraReplay(camera: cameraID, key: text("key") ?? response.notification.request.identifier,
                                                           event: text("event"), clip: text("clip"),
                                                           title: response.notification.request.content.title,
                                                           at: response.notification.date,
                                                           media: Self.attachedMedia(response.notification.request.content),
                                                           thumb: text("thumb"))
                CameraStreams.shared.requested = cameraID
                #if os(macOS)
                // The camera opens in Woodruff's window: bring it forward if it's tucked away in the Dock.
                if let w = MainWindow.current {
                    if w.isMiniaturized { w.deminiaturize(nil) }
                    w.makeKeyAndOrderFront(nil)
                }
                #endif
                return
            }
            switch action {
            case "hide":
                if let tvID, let tv = fleet.tv(tvID) { fleet.hideAlerts(tv) }
            case "remote":
                // Only a TV that's still here (the alert may be old, or pushed from another Mac).
                if let tvID, fleet.tv(tvID) != nil { fleet.remoteAll = false; fleet.selectedID = tvID }
                #if os(macOS)
                // The Mac has no Remote page: its remote slides out beside the window.
                fleet.remotePanel = true
                #else
                UserDefaults.standard.set("remote", forKey: "section")
                #endif
            default:
                if tvID != nil { UserDefaults.standard.set("settings", forKey: "section") }
            }
        }
    }
}
