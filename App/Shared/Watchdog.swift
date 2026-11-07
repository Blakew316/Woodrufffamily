import SwiftUI
import UserNotifications
import WoodruffKit

#if os(macOS)
/// The Mac keeps listening for camera alerts: every 15 minutes it checks that a listen has worked lately, and when
/// none has for ten minutes it starts listening again from scratch. If that doesn't bring it back within half an
/// hour, Settings' Needs Attention says so. It also sends the weekly health note.
@Observable @MainActor
final class AlertWatchdog {
    static let shared = AlertWatchdog()
    /// Said in Needs Attention while listening hasn't come back.
    private(set) var problem: String?
    private var loop: Task<Void, Never>?
    private var firstMiss: Date?

    func start() {
        guard loop == nil, !Demo.isOn else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15 * 60 * 1_000_000_000)
                guard let self else { return }
                self.check()
                WeeklyNote.sendIfDue()
                // The sending Mac's cameras all kept live (one that dropped, or this Mac becoming the sender).
                if PushRelay.shared.isSender { CameraStreams.shared.keepWarm(true) }
            }
        }
    }

    private func check() {
        let nest = NestCameras.shared
        guard nest.connected, nest.canAlert else { problem = nil; firstMiss = nil; return }
        let heard = NestAlerts.shared.lastHeard
        if let heard, Date().timeIntervalSince(heard) < 600 {
            if firstMiss != nil { PushRelay.log.notice("camera listener: watchdog: listening again") }
            problem = nil
            firstMiss = nil
            return
        }
        let since = firstMiss ?? Date()
        firstMiss = since
        PushRelay.log.notice("camera listener: watchdog: no listen for 10 minutes or more, starting again")
        NestAlerts.shared.restartListening()
        if Date().timeIntervalSince(since) >= 30 * 60 {
            let when = (heard ?? since).formatted(date: .omitted, time: .shortened)
            problem = "This Mac hasn’t been able to listen for camera alerts since \(when). It keeps trying by itself. "
                + "Last answer: \(NestAlerts.shared.status)"
        }
    }
}

/// Once a week (Sunday from 10 in the morning), the Mac that sends the family's alerts sends a short note to the
/// iPhones and itself: how many camera alerts came in, anything that's dropped off, and anything to fix.
enum WeeklyNote {
    private static let countsKey = "weekly.alertCounts"
    private static let sentKey = "weekly.lastNote"

    @MainActor static func countAlert(camera: String) {
        var c = UserDefaults.standard.dictionary(forKey: countsKey) as? [String: Int] ?? [:]
        let name = camera.replacingOccurrences(of: " camera", with: "", options: .caseInsensitive)
        c[name, default: 0] += 1
        UserDefaults.standard.set(c, forKey: countsKey)
    }

    @MainActor static func sendIfDue(now: Date = Date()) {
        guard PushRelay.shared.isSender else { return }
        let fleet = Fleet.shared
        let cal = Calendar.current
        guard cal.component(.weekday, from: now) == 1, cal.component(.hour, from: now) >= 10 else { return }
        let last = UserDefaults.standard.double(forKey: sentKey)
        guard now.timeIntervalSince1970 - last > 6 * 86_400 else { return }
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: sentKey)

        let counts = UserDefaults.standard.dictionary(forKey: countsKey) as? [String: Int] ?? [:]
        UserDefaults.standard.set([String: Int](), forKey: countsKey)
        var lines: [String] = []
        let total = counts.values.reduce(0, +)
        if total == 0 {
            lines.append("No camera alerts this week.")
        } else {
            let top = counts.sorted { $0.value > $1.value }.prefix(3).map { "\($0.key) \($0.value)" }.joined(separator: ", ")
            lines.append("\(total) camera alert\(total == 1 ? "" : "s") (\(top)).")
        }
        let store = AccessoryStore.shared
        let gone = store.all.filter { store.longGone($0) }.map(\.name)
        if !gone.isEmpty { lines.append("Not responding: " + gone.prefix(4).joined(separator: ", ") + (gone.count > 4 ? " and more." : ".")) }
        let offTVs = fleet.tvs.filter { !$0.isUnpaired && !$0.online }.map(\.name)
        if !offTVs.isEmpty && offTVs.count < fleet.tvs.count { lines.append("Off now: " + offTVs.joined(separator: ", ") + ".") }
        let issues = NeedsAttentionSection.issues(fleet).map(\.title)
        lines.append(issues.isEmpty ? "Nothing needs fixing." : "Needs attention: " + issues.joined(separator: ", ") + ".")

        let c = UNMutableNotificationContent()
        c.title = "Woodruff This Week"
        c.body = lines.joined(separator: " ")
        Notifier.deliver(c, id: "weekly-\(Int(now.timeIntervalSince1970))")
    }
}
#endif
