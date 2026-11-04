import Foundation
import ActivityKit
import Observation
import WoodruffKit

/// Keeps the Lock Screen / Dynamic Island in step with what the remote's TV is playing: starts the Live Activity
/// when something plays, updates it when the title or play state changes (the progress bar runs by itself in
/// between), and ends it when playback stops. Settings → Notifications → Now Playing on Lock Screen turns it off.
@MainActor
final class LiveActivitySync {
    static let shared = LiveActivitySync()
    private var last: NowPlayingAttributes.ContentState?
    private var lastTV: String?
    /// Following the fleet by itself (see `watch`).
    private var watching = false
    /// The last update sent to the Live Activity, for `syncAndWait`.
    private var pending: Task<Void, Never>?

    private init() {
        // Lock Screen buttons (shared with the widgets extension) bring the Live Activity up to date through this.
        TVIntentActions.updateActivity = { fleet in await LiveActivitySync.shared.syncAndWait(fleet) }
    }

    var enabled: Bool { UserDefaults.standard.object(forKey: "liveActivity") as? Bool ?? true }

    /// `sync`, then waits until the Live Activity has the update (a Lock Screen button runs while the app is in the
    /// background, and the app may sleep again as soon as it returns).
    func syncAndWait(_ fleet: Fleet) async {
        sync(fleet)
        await pending?.value
    }

    func sync(_ fleet: Fleet) {
        watch(fleet)
        guard enabled, ActivityAuthorizationInfo().areActivitiesEnabled,
              !fleet.remoteAll, let tv = fleet.selected, let p = tv.playing else { end(); return }
        let state = NowPlayingAttributes.ContentState(tv: tv, playing: p)
        // One the system ended or the family swiped away can't be updated: start a new one instead.
        let current = Activity<NowPlayingAttributes>.activities.first { $0.activityState == .active || $0.activityState == .stale }
        if let current, current.attributes.tvID == tv.id {
            guard needsUpdate(state) else { return }
            last = state
            pending = Task { await current.update(ActivityContent(state: state, staleDate: state.staleDate)) }
        } else {
            end()
            last = state
            lastTV = tv.id
            _ = try? Activity.request(attributes: NowPlayingAttributes(tvID: tv.id),
                                      content: ActivityContent(state: state, staleDate: state.staleDate))
        }
    }

    func end() {
        last = nil
        lastTV = nil
        for a in Activity<NowPlayingAttributes>.activities {
            Task { await a.end(nil, dismissalPolicy: .immediate) }
        }
    }

    /// Follows what the remote's TV is doing by itself, not only through the app's views: those don't update
    /// while the app is in the background, yet a TV that pauses or starts something new then still has to
    /// reach the Lock Screen.
    private func watch(_ fleet: Fleet) {
        guard !watching else { return }
        watching = true
        withObservationTracking {
            _ = fleet.selected?.playing
            _ = fleet.selected?.name
            _ = fleet.remoteAll
        } onChange: {
            Task { @MainActor in
                LiveActivitySync.shared.watching = false
                LiveActivitySync.shared.sync(fleet)
            }
        }
    }

    /// Only real changes: a new title, play/pause, or a jump of more than a few seconds (a seek).
    private func needsUpdate(_ s: NowPlayingAttributes.ContentState) -> Bool {
        guard let l = last else { return true }
        if l.title != s.title || l.isPlaying != s.isPlaying || l.tvName != s.tvName || l.detail != s.detail || l.canSkip != s.canSkip { return true }
        if let a = l.startedAt, let b = s.startedAt, abs(a.timeIntervalSince(b)) > 5 { return true }
        if (l.startedAt == nil) != (s.startedAt == nil) { return true }
        if !s.isPlaying && abs(l.fraction - s.fraction) > 0.01 { return true }
        return false
    }
}
