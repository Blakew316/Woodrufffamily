import Foundation
import UserNotifications
import WoodruffKit

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
            default: break
            }
        }
    }

    static func post(_ title: String, _ body: String, id: String, category: String, tv: String?, relay: Bool = true) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
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
            PushRelay.shared.relay(id: id, title: c.title, body: c.body, category: c.categoryIdentifier.isEmpty ? nil : c.categoryIdentifier, userInfo: info)
        }
        #endif
    }
}

/// What a tap on a notification (or one of its actions) does.
final class NotificationHandler: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let tvID = response.notification.request.content.userInfo["tv"] as? String
        let action = response.actionIdentifier
        await MainActor.run {
            let fleet = Fleet.shared
            switch action {
            case "hide":
                if let tvID, let tv = fleet.tv(tvID) { fleet.hideAlerts(tv) }
            case "remote":
                if let tvID { fleet.selectedID = tvID }
                UserDefaults.standard.set("remote", forKey: "section")
            default:
                if tvID != nil { UserDefaults.standard.set("settings", forKey: "section") }
            }
        }
    }
}
