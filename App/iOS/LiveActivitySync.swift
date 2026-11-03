import Foundation
import ActivityKit
import WoodruffKit

/// Keeps the Lock Screen / Dynamic Island in step with what the remote's TV is playing: starts the Live Activity
/// when something plays, updates it when the title or play state changes (the progress bar runs by itself in
/// between), and ends it when playback stops. Settings → Notifications → Now Playing on Lock Screen turns it off.
@MainActor
final class LiveActivitySync {
    static let shared = LiveActivitySync()
    private var last: NowPlayingAttributes.ContentState?
    private var lastTV: String?

    var enabled: Bool { UserDefaults.standard.object(forKey: "liveActivity") as? Bool ?? true }

    func sync(_ fleet: Fleet) {
        guard enabled, ActivityAuthorizationInfo().areActivitiesEnabled,
              !fleet.remoteAll, let tv = fleet.selected, let p = tv.playing else { end(); return }
        let state = makeState(tv, p, at: fleet.refreshedAt ?? Date())
        let current = Activity<NowPlayingAttributes>.activities.first
        if let current, current.attributes.tvID == tv.id {
            guard needsUpdate(state) else { return }
            last = state
            Task { await current.update(ActivityContent(state: state, staleDate: state.endsAt)) }
        } else {
            end()
            last = state
            lastTV = tv.id
            _ = try? Activity.request(attributes: NowPlayingAttributes(tvID: tv.id),
                                      content: ActivityContent(state: state, staleDate: state.endsAt))
        }
    }

    func end() {
        last = nil
        lastTV = nil
        for a in Activity<NowPlayingAttributes>.activities {
            Task { await a.end(nil, dismissalPolicy: .immediate) }
        }
    }

    private func makeState(_ tv: FleetTV, _ p: NowPlaying, at: Date) -> NowPlayingAttributes.ContentState {
        let pos = (p.position ?? 0) / 1000
        let dur = (p.duration ?? 0) / 1000
        let started = dur > 0 ? at.addingTimeInterval(-pos) : nil
        return .init(title: p.title,
                     detail: [p.subtitle, p.app].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · "),
                     tvName: tv.name, isPlaying: p.isPlaying,
                     startedAt: started, endsAt: started.map { $0.addingTimeInterval(dur) },
                     fraction: dur > 0 ? min(1, pos / dur) : 0,
                     canSkip: p.can("back10") || p.can("fwd30"))
    }

    /// Only real changes: a new title, play/pause, or a jump of more than a few seconds (a seek).
    private func needsUpdate(_ s: NowPlayingAttributes.ContentState) -> Bool {
        guard let l = last else { return true }
        if l.title != s.title || l.isPlaying != s.isPlaying || l.tvName != s.tvName || l.detail != s.detail { return true }
        if let a = l.startedAt, let b = s.startedAt, abs(a.timeIntervalSince(b)) > 5 { return true }
        if !s.isPlaying && abs(l.fraction - s.fraction) > 0.01 { return true }
        return false
    }
}
