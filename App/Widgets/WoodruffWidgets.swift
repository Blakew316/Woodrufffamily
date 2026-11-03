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
                    Image("Emblem").resizable().frame(width: 42, height: 42)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .padding(.leading, 2)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.title).font(.headline).lineLimit(1)
                        Text(s.tvName + (s.detail.isEmpty ? "" : " · " + s.detail)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ActivityRing(state: s).frame(width: 24, height: 24).padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 12) {
                        ActivityProgress(state: s).tint(.white)
                        HStack {
                            Button(intent: VolumeDownTVIntent()) { Image(systemName: "speaker.minus.fill").font(.body) }
                            Spacer()
                            if s.canSkip { Button(intent: SkipBackTVIntent()) { Image(systemName: "gobackward.10").font(.title3.weight(.semibold)) } }
                            Spacer()
                            Button(intent: PlayPauseTVIntent()) {
                                Image(systemName: s.isPlaying ? "pause.fill" : "play.fill").font(.title2.weight(.semibold))
                            }
                            Spacer()
                            if s.canSkip { Button(intent: SkipForwardTVIntent()) { Image(systemName: "goforward.30").font(.title3.weight(.semibold)) } }
                            Spacer()
                            Button(intent: VolumeUpTVIntent()) { Image(systemName: "speaker.plus.fill").font(.body) }
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 6)
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                Image(systemName: "tv.fill").font(.caption.weight(.semibold)).foregroundStyle(.tint)
            } compactTrailing: {
                // A small ring that fills as it plays: the island stays tight beside the camera.
                ActivityRing(state: s).frame(width: 18, height: 18)
            } minimal: {
                ActivityRing(state: s).frame(width: 18, height: 18)
            }
            .widgetURL(URL(string: "woodruff://remote"))
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

/// A small ring that fills while playing (the system animates it from the start and end), a pause glyph when paused.
struct ActivityRing: View {
    var state: NowPlayingAttributes.ContentState
    var body: some View {
        if state.isPlaying, let start = state.startedAt, let end = state.endsAt, end > start {
            ProgressView(timerInterval: start...end, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
                .progressViewStyle(.circular)
                .tint(.accentColor)
        } else {
            Image(systemName: state.isPlaying ? "play.fill" : "pause.fill")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.tint)
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
