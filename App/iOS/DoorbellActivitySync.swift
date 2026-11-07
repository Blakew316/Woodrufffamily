import Foundation
import ActivityKit

/// The doorbell's Live Activity on this iPhone: its push-to-start address handed to the Macs (with the alerts'
/// address, through the synced settings), and each one the Mac's push starts ended a minute after the ring so it
/// leaves by itself.
@MainActor
final class DoorbellActivitySync {
    static let shared = DoorbellActivitySync()
    private var started = false
    /// How long it stays after the ring.
    static let shows: TimeInterval = 60

    func start() {
        guard !started else { return }
        started = true
        Task {
            for await data in Activity<DoorbellAttributes>.pushToStartTokenUpdates {
                PushRelay.shared.setStartToken(data.map { String(format: "%02x", $0) }.joined())
            }
        }
        Task {
            for await activity in Activity<DoorbellAttributes>.activityUpdates { finish(activity) }
        }
        tidy()
    }

    /// Ended at once, staying on screen until a minute after the ring.
    private func finish(_ a: Activity<DoorbellAttributes>) {
        let until = a.content.state.at.addingTimeInterval(Self.shows)
        Task { await a.end(nil, dismissalPolicy: until > Date() ? .after(until) : .immediate) }
    }

    /// Any left from before (the app wasn't woken in time): gone now.
    func tidy() {
        for a in Activity<DoorbellAttributes>.activities where a.activityState == .active || a.activityState == .stale { finish(a) }
    }
}
