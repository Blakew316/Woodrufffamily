import Foundation
import ActivityKit
import Observation
import WoodruffKit

/// Keeps the Lock Screen / Dynamic Island in step with what the remote's TV is playing now (`FleetTV.nowPlaying`):
/// starts the Live Activity when something plays, updates it when the title or play state changes (the progress bar
/// runs by itself in between), and ends it when the TV stops, goes off, or is left paused. Settings → Notifications →
/// Now Playing on Lock Screen turns it off.
@MainActor
final class LiveActivitySync {
    static let shared = LiveActivitySync()
    private var last: NowPlayingAttributes.ContentState?
    /// Following the fleet by itself (see `watch`).
    private var watching = false
    /// The last update (or ending) sent to the Live Activity, for `syncAndWait`.
    private var pending: Task<Void, Never>?
    /// Nothing to show for the activity's TV just now: it ends in a moment unless something plays again by then.
    private var ending: Task<Void, Never>?

    private init() {
        // Lock Screen buttons (shared with the widgets extension) bring the Live Activity up to date through this.
        TVIntentActions.updateActivity = { fleet in await LiveActivitySync.shared.syncAndWait(fleet) }
    }

    var enabled: Bool { UserDefaults.standard.object(forKey: "liveActivity") as? Bool ?? true }

    /// `sync`, then waits until the Live Activity has the update (a Lock Screen button runs while the app is in the
    /// background, and the app may sleep again as soon as it returns). The TVs have just been asked, so nothing to show
    /// ends it at once.
    func syncAndWait(_ fleet: Fleet) async {
        sync(fleet, endAtOnce: true)
        await pending?.value
        // A button the family pressed: the widgets show what it changed at once, even with Woodruff in the background.
        await PhoneWidgetSync.write(fleet, now: true)
    }

    /// [endAtOnce]: when the remote's TV has nothing to show, end now instead of in a moment. Otherwise a TV that only
    /// seems to have stopped (the app just woke, and drops what its old answers said until the TVs answer again a
    /// moment later) never ends the Live Activity only to start a new one.
    func sync(_ fleet: Fleet, endAtOnce: Bool = false) {
        watch(fleet)
        guard enabled, ActivityAuthorizationInfo().areActivitiesEnabled, !fleet.remoteAll, let tv = fleet.selected else {
            end()
            return
        }
        // One the system ended or the family swiped away can't be updated: a new one is started instead.
        let current = Activity<NowPlayingAttributes>.activities.first { $0.activityState == .active || $0.activityState == .stale }
        guard let p = tv.nowPlaying else {
            // Nothing to show: it ends in a moment (at once when told to, or when the activity is another TV's).
            if endAtOnce || current?.attributes.tvID != tv.id { end() } else { endSoon(fleet) }
            return
        }
        ending?.cancel()
        ending = nil
        let state = NowPlayingAttributes.ContentState(tv: tv, playing: p)
        if let current, current.attributes.tvID == tv.id {
            guard needsUpdate(state) else { return }
            last = state
            pending = Task { await current.update(ActivityContent(state: state, staleDate: state.staleDate)) }
        } else {
            end()
            last = state
            _ = try? Activity.request(attributes: NowPlayingAttributes(tvID: tv.id),
                                      content: ActivityContent(state: state, staleDate: state.staleDate))
        }
    }

    func end() {
        ending?.cancel()
        ending = nil
        last = nil
        let all = Activity<NowPlayingAttributes>.activities
        guard !all.isEmpty else { return }
        // Kept as the last change, so a Lock Screen button's `syncAndWait` waits for it before the app sleeps again.
        pending = Task {
            for a in all { await a.end(nil, dismissalPolicy: .immediate) }
        }
    }

    /// Ends the Live Activity in 4 seconds, unless the remote's TV plays something again by then (see `sync`).
    private func endSoon(_ fleet: Fleet) {
        guard ending == nil else { return }
        ending = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            let live = LiveActivitySync.shared
            live.ending = nil
            live.sync(fleet, endAtOnce: true)
        }
    }

    /// Follows what the remote's TV is doing by itself, not only through the app's views: those don't update
    /// while the app is in the background, yet a TV that pauses or starts something new then still has to
    /// reach the Lock Screen.
    private func watch(_ fleet: Fleet) {
        guard !watching else { return }
        watching = true
        withObservationTracking {
            _ = fleet.selected?.nowPlaying
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
