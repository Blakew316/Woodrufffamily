import Foundation
import ActivityKit

/// Starts a Live Activity when a washer, dryer, dishwasher or oven starts a cycle, keeps its countdown right as
/// SmartThings reports, and shows "Done" for 15 minutes when it finishes. Settings → Notifications → Appliances on
/// Lock Screen turns it off.
@MainActor
final class ApplianceActivitySync {
    static let shared = ApplianceActivitySync()
    private var started: [String: Date] = [:]
    private var last: [String: ApplianceAttributes.ContentState] = [:]

    var enabled: Bool { UserDefaults.standard.object(forKey: "applianceActivity") as? Bool ?? true }

    func update(_ d: HomeDevice) {
        guard [.washer, .dryer, .dishwasher, .oven].contains(d.kind), let state = d.machineState else { return }
        let current = Activity<ApplianceAttributes>.activities.first {
            $0.attributes.deviceID == d.id && ($0.activityState == .active || $0.activityState == .stale)
        }
        guard enabled, ActivityAuthorizationInfo().areActivitiesEnabled else {
            if let current { Task { await current.end(nil, dismissalPolicy: .immediate) } }
            return
        }
        switch state {
        case "run", "pause":
            let start = started[d.id] ?? current?.content.state.startedAt ?? Date()
            started[d.id] = start
            let phase = state == "pause" ? "Paused"
                : String(d.status.split(separator: "·").first ?? "Running").trimmingCharacters(in: .whitespaces)
            // Whole minutes, so a countdown SmartThings nudges by seconds doesn't wake the Lock Screen.
            let ends = d.endsAt.flatMap { $0 > Date() ? Date(timeIntervalSinceReferenceDate: ($0.timeIntervalSinceReferenceDate / 60).rounded() * 60) : nil }
            let s = ApplianceAttributes.ContentState(phase: phase, startedAt: start, endsAt: ends, paused: state == "pause", done: false)
            if let current {
                guard last[d.id] != s else { return }
                last[d.id] = s
                Task { await current.update(ActivityContent(state: s, staleDate: ends?.addingTimeInterval(1800))) }
            } else if state == "run" {
                last[d.id] = s
                let a = ApplianceAttributes(deviceID: d.id, name: d.name, kind: d.kind.rawValue)
                _ = try? Activity.request(attributes: a, content: ActivityContent(state: s, staleDate: ends?.addingTimeInterval(1800)))
            }
        default:
            started[d.id] = nil
            last[d.id] = nil
            guard let current else { return }
            var s = current.content.state
            s.phase = "Done"
            s.done = true
            s.paused = false
            s.endsAt = Date()
            Task { await current.end(ActivityContent(state: s, staleDate: nil), dismissalPolicy: .after(Date().addingTimeInterval(900))) }
        }
    }

    func endAll() {
        for a in Activity<ApplianceAttributes>.activities { Task { await a.end(nil, dismissalPolicy: .immediate) } }
    }
}
