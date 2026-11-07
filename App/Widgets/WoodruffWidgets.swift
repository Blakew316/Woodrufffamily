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
        LightsOffControl()
        LightsOnControl()
        SonosPlayPauseControl()
        SonosVolumeUpControl()
        SonosVolumeDownControl()
        SceneControls().body
    }
}

// MARK: - Scenes

/// Movie Night and Bedtime in Control Center (their own bundle: one bundle holds ten at most).
struct SceneControls: WidgetBundle {
    var body: some Widget {
        MovieNightControl()
        BedtimeControl()
        ApplianceLiveActivity()
        TVVolumeUpControl()
        TVVolumeDownControl()
        NowPlayingWidget()
        HomeWidget()
        TVsCamerasWidget()
        DoorbellLockWidget()
        DoorbellLiveActivity()
    }
}

struct MovieNightControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.woodruff.family.control.movienight") {
            ControlWidgetButton(action: RunSceneControlIntent(sceneID: "movie-night")) {
                Label("Movie Night", systemImage: "popcorn.fill")
            }
        }
        .displayName("Movie Night")
        .description("Runs your Movie Night scene.")
    }
}

struct BedtimeControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.woodruff.family.control.bedtime") {
            ControlWidgetButton(action: RunSceneControlIntent(sceneID: "bedtime")) {
                Label("Bedtime", systemImage: "moon.zzz.fill")
            }
        }
        .displayName("Bedtime")
        .description("Runs your Bedtime scene.")
    }
}

// MARK: - Live Activity (Lock Screen and Dynamic Island)

struct NowPlayingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NowPlayingAttributes.self) { context in
            LockScreenNowPlaying(state: context.state, idle: context.isStale && !context.state.isPlaying)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
                // Tapping it (anywhere but its buttons) opens the remote, as the Dynamic Island does.
                .widgetURL(URL(string: "woodruff://remote"))
        } dynamicIsland: { context in
            let s = context.state
            // Left paused until it went stale (5 minutes on) while the app was asleep and couldn't end it: the TV, with
            // nothing playing (no old title, bar or buttons) until the app next runs and ends it.
            let idle = context.isStale && !s.isPlaying
            let headline: String = idle ? s.tvName : s.title
            let subline: String = idle ? "Nothing playing" : s.tvName + (s.detail.isEmpty ? "" : " · " + s.detail)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image("Emblem").resizable().frame(width: 42, height: 42)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .padding(.leading, 2)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(headline).font(.headline).lineLimit(1)
                        Text(subline).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if !idle { ActivityRing(state: s).frame(width: 24, height: 24).padding(.trailing, 4) }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if !idle {
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
    /// Left paused until it went stale (5 minutes on) while the app couldn't end it: the TV, with nothing playing.
    var idle = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image("Emblem").resizable().frame(width: 46, height: 46)
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(headline).font(.headline).lineLimit(1)
                    Text(subline).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            if !idle {
                ActivityProgress(state: state).tint(.white)
                ActivityTransport(state: state)
            }
        }
        .padding(16)
        .foregroundStyle(.white)
    }

    private var headline: String { idle ? state.tvName : state.title }
    private var subline: String {
        idle ? "Nothing playing" : [state.detail, state.tvName].filter { !$0.isEmpty }.joined(separator: " · ")
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

struct TVVolumeUpControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.woodruff.family.control.tvvolup") {
            ControlWidgetButton(action: VolumeUpTVIntent()) {
                Label("TV Volume Up", systemImage: "speaker.plus.fill")
            }
        }
        .displayName("TV Volume Up")
        .description("Turns the remote’s TV up.")
    }
}

struct TVVolumeDownControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.woodruff.family.control.tvvoldown") {
            ControlWidgetButton(action: VolumeDownTVIntent()) {
                Label("TV Volume Down", systemImage: "speaker.minus.fill")
            }
        }
        .displayName("TV Volume Down")
        .description("Turns the remote’s TV down.")
    }
}

// MARK: - Speakers and lights

struct LightsOffControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.woodruff.family.control.lightsoff") {
            ControlWidgetButton(action: LightsOffControlIntent()) {
                Label("Lights Off", systemImage: "lightbulb.slash")
            }
        }
        .displayName("Lights Off")
        .description("Turns off every light (Govee and Apple Home).")
    }
}

struct LightsOnControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.woodruff.family.control.lightson") {
            ControlWidgetButton(action: LightsOnControlIntent()) {
                Label("Lights On", systemImage: "lightbulb.fill")
            }
        }
        .displayName("Lights On")
        .description("Turns on every light (Govee and Apple Home).")
    }
}

struct SonosPlayPauseControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.woodruff.family.control.sonos") {
            ControlWidgetButton(action: SonosPlayPauseControlIntent()) {
                Label("Sonos", systemImage: "hifispeaker.fill")
            }
        }
        .displayName("Sonos Play/Pause")
        .description("Plays or pauses the Sonos room you used last.")
    }
}

struct SonosVolumeUpControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.woodruff.family.control.sonosup") {
            ControlWidgetButton(action: SonosVolumeControlIntent(up: true)) {
                Label("Sonos Up", systemImage: "speaker.plus.fill")
            }
        }
        .displayName("Sonos Volume Up")
        .description("Turns the playing Sonos room up.")
    }
}

struct SonosVolumeDownControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.woodruff.family.control.sonosdown") {
            ControlWidgetButton(action: SonosVolumeControlIntent(up: false)) {
                Label("Sonos Down", systemImage: "speaker.minus.fill")
            }
        }
        .displayName("Sonos Volume Down")
        .description("Turns the playing Sonos room down.")
    }
}

// MARK: - Appliances

/// A washer, dryer, dishwasher or oven's cycle: a countdown on the Lock Screen and in the Dynamic Island.
struct ApplianceLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ApplianceAttributes.self) { context in
            ApplianceLockScreen(attributes: context.attributes, state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(URL(string: "woodruff://home"))
        } dynamicIsland: { context in
            let a = context.attributes
            let s = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: a.symbol).font(.title2).foregroundStyle(s.done ? .green : .accentColor)
                        .frame(width: 42, height: 42)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(a.name).font(.headline).lineLimit(1)
                        Text(s.phase).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ApplianceTimeLeft(state: s).font(.title3.weight(.semibold)).padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ApplianceProgress(state: s).padding(.horizontal, 4)
                }
            } compactLeading: {
                Image(systemName: a.symbol).font(.caption.weight(.semibold)).foregroundStyle(s.done ? .green : .accentColor)
            } compactTrailing: {
                ApplianceTimeLeft(state: s).font(.caption.weight(.semibold)).frame(maxWidth: 52)
            } minimal: {
                Image(systemName: a.symbol).font(.caption.weight(.semibold)).foregroundStyle(s.done ? .green : .accentColor)
            }
            .widgetURL(URL(string: "woodruff://home"))
            .keylineTint(.accentColor)
        }
    }
}

struct ApplianceLockScreen: View {
    let attributes: ApplianceAttributes
    let state: ApplianceAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: attributes.symbol).font(.title2)
                    .foregroundStyle(state.done ? .green : .white)
                    .frame(width: 40, height: 40)
                    .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(attributes.name).font(.headline).lineLimit(1)
                    Text(state.phase).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                ApplianceTimeLeft(state: state).font(.title2.weight(.semibold))
            }
            ApplianceProgress(state: state)
        }
        .foregroundStyle(.white)
        .padding(16)
    }
}

/// Minutes left, counting down by itself; "Done" when finished.
struct ApplianceTimeLeft: View {
    let state: ApplianceAttributes.ContentState

    var body: some View {
        if state.done {
            Text("Done").foregroundStyle(.green)
        } else if let end = state.endsAt, end > state.startedAt, !state.paused {
            // From the cycle's start, not "now": the view is drawn again later, when now can be past the end (a
            // range whose start is after its end would crash the widget). Past the end it reads 0:00.
            Text(timerInterval: state.startedAt...end, countsDown: true, showsHours: true)
                .monospacedDigit().multilineTextAlignment(.trailing)
        } else if state.paused {
            Text("Paused").foregroundStyle(.secondary)
        } else {
            EmptyView()
        }
    }
}

/// A bar from when the cycle started to when it ends, moving by itself.
struct ApplianceProgress: View {
    let state: ApplianceAttributes.ContentState

    var body: some View {
        Group {
            if state.done {
                ProgressView(value: 1)
            } else if let end = state.endsAt, end > state.startedAt, !state.paused {
                ProgressView(timerInterval: state.startedAt...end, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
            } else {
                ProgressView(value: 0)
            }
        }
        .tint(state.done ? .green : .white)
    }
}
