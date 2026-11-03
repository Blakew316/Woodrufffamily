import SwiftUI
import WidgetKit
import ActivityKit
import AppIntents

@main
struct WoodruffWidgets: WidgetBundle {
    var body: some Widget {
        NowPlayingLiveActivity()
        RemoteControl()
        PlayPauseControl()
        MuteControl()
    }
}

// MARK: - Live Activity (Lock Screen and Dynamic Island)

struct NowPlayingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NowPlayingAttributes.self) { context in
            LockScreenNowPlaying(state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let s = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image("Emblem").resizable().frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(s.tvName).font(.caption.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.title).font(.headline).lineLimit(1)
                        if !s.detail.isEmpty { Text(s.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 10) {
                        ActivityProgress(state: s).tint(.white)
                        ActivityTransport(state: s)
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                Image(systemName: s.isPlaying ? "play.tv.fill" : "pause.fill").foregroundStyle(.tint)
            } compactTrailing: {
                if s.isPlaying, let end = s.endsAt, end > .now {
                    Text(timerInterval: Date.now...end, countsDown: true, showsHours: false)
                        .monospacedDigit().font(.caption2.weight(.semibold)).frame(maxWidth: 44)
                } else {
                    Text("Paused").font(.caption2.weight(.semibold))
                }
            } minimal: {
                Image(systemName: s.isPlaying ? "play.tv.fill" : "pause.fill").foregroundStyle(.tint)
            }
            .keylineTint(.accentColor)
        }
    }
}

struct LockScreenNowPlaying: View {
    var state: NowPlayingAttributes.ContentState
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image("Emblem").resizable().frame(width: 46, height: 46)
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.title).font(.headline).lineLimit(1)
                    Text([state.detail, state.tvName].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            ActivityProgress(state: state).tint(.white)
            ActivityTransport(state: state)
        }
        .padding(16)
        .foregroundStyle(.white)
    }
}

/// Moves by itself while playing (the system draws it from the start and end times).
struct ActivityProgress: View {
    var state: NowPlayingAttributes.ContentState
    var body: some View {
        if state.isPlaying, let start = state.startedAt, let end = state.endsAt, end > start {
            ProgressView(timerInterval: start...end, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
        } else {
            ProgressView(value: state.fraction)
        }
    }
}

struct ActivityTransport: View {
    var state: NowPlayingAttributes.ContentState
    var body: some View {
        HStack(spacing: 34) {
            if state.canSkip {
                Button(intent: SkipBackTVIntent()) { Image(systemName: "gobackward.10").font(.title3.weight(.semibold)) }
            }
            Button(intent: PlayPauseTVIntent()) {
                Image(systemName: state.isPlaying ? "pause.fill" : "play.fill").font(.title.weight(.semibold))
            }
            if state.canSkip {
                Button(intent: SkipForwardTVIntent()) { Image(systemName: "goforward.30").font(.title3.weight(.semibold)) }
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Control Center / Lock Screen controls

struct RemoteControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.woodruff.family.control.remote") {
            ControlWidgetButton(action: OpenRemoteIntent()) {
                Label("Woodruff Remote", systemImage: "appletvremote.gen4.fill")
            }
        }
        .displayName("Woodruff Remote")
        .description("Opens the remote for your TVs.")
    }
}

struct PlayPauseControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.woodruff.family.control.playpause") {
            ControlWidgetButton(action: PlayPauseTVIntent()) {
                Label("Play/Pause TV", systemImage: "playpause.fill")
            }
        }
        .displayName("Play/Pause TV")
        .description("Plays or pauses the remote’s TV.")
    }
}

struct MuteControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.woodruff.family.control.mute") {
            ControlWidgetButton(action: MuteTVIntent()) {
                Label("Mute TV", systemImage: "speaker.slash.fill")
            }
        }
        .displayName("Mute TV")
        .description("Mutes or unmutes the remote’s TV.")
    }
}
