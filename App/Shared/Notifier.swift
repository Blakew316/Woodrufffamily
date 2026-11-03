import Foundation
import UserNotifications
import WoodruffKit

/// Local notifications: announcements sent to this device, and TVs that go off or need attention.
@MainActor
enum Notifier {
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    static func attach(to fleet: Fleet) {
        requestPermission()
        fleet.onChange = { event in
            let fleetAlerts = UserDefaults.standard.object(forKey: "notifyFleet") as? Bool ?? true
            switch event {
            case .message(let m, let from):
                post(m.title, m.body?.isEmpty == false ? m.body! : "From \(m.from ?? from)", id: m.id)
            case .wentOffline(let tv) where fleetAlerts:
                post("\(tv.name) went offline", "It's off, asleep or off the network.", id: "off-\(tv.id)")
            case .needsAttention(let tv) where fleetAlerts:
                post("\(tv.name) needs attention", tv.health?.first ?? (tv.link == "refused" ? "Its link stopped working." : ""), id: "att-\(tv.id)")
            default: break
            }
        }
    }

    static func post(_ title: String, _ body: String, id: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: c, trigger: nil))
    }
}
