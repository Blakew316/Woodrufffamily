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
        MoreControls().body
    }
}

struct MoreControls: WidgetBundle {
    var body: some Widget {
        DoorbellLiveActivity()
        WoodruffHomeControl()
    }
}

/// Lock Screen and Control Center: opens Woodruff to Home. Apple's plain house, drawn as iOS draws every control
/// there: white, on the dark circle. (iOS shows a control in its own colour only while it's on, and then on a white
/// circle: tried as an always-on switch with a blue house, which looked wrong. A symbol's own colours aren't kept
/// either: a house of its own in two colours came out all white, and small.)
struct WoodruffHomeControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.woodruff.family.control.home") {
            ControlWidgetButton(action: OpenHomeIntent()) {
                Label("Woodruff", systemImage: "house")
            }
        }
        .displayName("Woodruff")
        .description("Opens Woodruff to Home.")
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
            // Laid out and coloured as the system's own Now Playing card is, so the two read as one kind of thing
            // when they're on the Lock Screen together.
            LockScreenNowPlaying(state: context.state, idle: context.isStale && !context.state.isPlaying)
                .activityBackgroundTint(LockScreenNowPlaying.card)
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
                // White, as the Lock Screen's card is (the app's blue is for the app).
                Image(systemName: "tv.fill").font(.caption.weight(.semibold)).foregroundStyle(.white)
            } compactTrailing: {
                // Nothing on the right: the TV on the left says it's there. (A play mark sat here that looked like a
                // button and wasn't one; the real one is in the island held open.)
                EmptyView()
            } minimal: {
                Image(systemName: "tv.fill").font(.caption2.weight(.semibold)).foregroundStyle(.white)
            }
            .widgetURL(URL(string: "woodruff://remote"))
            .keylineTint(.white)
        }
    }
}

/// The Lock Screen's card for what the remote's TV is playing, arranged as the system's Now Playing card is: the
/// title's picture; where it's playing in small grey letters, the title in bold, a grey line under it; the bar with
/// how far in at its left and the time left at its right; the buttons in a row beneath. Its sizes are the system
/// card's. It differs where iOS makes it: a Live Activity is at most 160 points tall and its controls are buttons, so
/// there's no volume slider and no AirPlay button, and its type doesn't grow with the text size (it would be cut off).
struct LockScreenNowPlaying: View {
    var state: NowPlayingAttributes.ContentState
    /// Left paused until it went stale (5 minutes on) while the app couldn't end it: the TV, with nothing playing.
    var idle = false

    /// The system card's near-black, barely see-through.
    static let card = Color(red: 0.075, green: 0.075, blue: 0.065).opacity(0.94)
    static let grey = Color.white.opacity(0.6)

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                picture
                VStack(alignment: .leading, spacing: 0) {
                    Text(state.tvName).font(.system(size: 13, weight: .semibold)).foregroundStyle(Self.grey)
                    Text(idle ? "Nothing playing" : state.title).font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
                    if let line { Text(line).font(.system(size: 17)).foregroundStyle(Self.grey) }
                }
                .lineLimit(1)
                Spacer(minLength: 0)
            }
            if !idle {
                if let start = state.startedAt, let end = state.endsAt, end > start {
                    LockScreenTimeline(state: state, start: start, end: end)
                        .padding(.horizontal, 6)
                        .padding(.top, 12)
                }
                LockScreenTransport(state: state)
                    .padding(.top, 12)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, idle ? 14 : 10)
    }

    /// The line under the title: the episode and the app. Not when it only says the title again (an app that
    /// doesn't say what it's playing has its own name for a title).
    private var line: String? {
        guard !idle, !state.detail.isEmpty,
              state.detail.caseInsensitiveCompare(state.title) != .orderedSame else { return nil }
        return state.detail
    }

    /// The title's picture, whatever its shape (a poster stands, a still lies), else the app's emblem.
    @ViewBuilder private var picture: some View {
        if !idle, let image = WidgetImage.load(state.art, pixels: 240) {
            Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
                .frame(maxWidth: 56, maxHeight: 44)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        } else {
            Image("Emblem").resizable().frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

/// The bar with its times: how far in at the left, the time left (with a minus) at the right, a thick grey bar
/// between them. While it plays all three run by themselves (the system draws them from the start and end times).
struct LockScreenTimeline: View {
    var state: NowPlayingAttributes.ContentState
    var start: Date
    var end: Date

    var body: some View {
        let length = end.timeIntervalSince(start)
        // A timer's text takes all the room it's offered: each gets the width of its longest reading.
        let hours = length >= 3600
        let width: CGFloat = hours ? 50 : (length >= 600 ? 38 : 30)
        HStack(spacing: 9) {
            Group {
                if state.isPlaying {
                    Text(timerInterval: start...end, countsDown: false, showsHours: hours)
                } else {
                    Text(Self.clock(state.fraction * length))
                }
            }
            .multilineTextAlignment(.leading)
            .frame(width: width, alignment: .leading)
            bar
            Group {
                if state.isPlaying {
                    Text("−\(Text(timerInterval: start...end, countsDown: true, showsHours: hours))")
                } else {
                    Text("−" + Self.clock((1 - state.fraction) * length))
                }
            }
            .multilineTextAlignment(.trailing)
            .frame(width: width + 9, alignment: .trailing)
        }
        .font(.system(size: 13, weight: .semibold).monospacedDigit())
        .foregroundStyle(LockScreenNowPlaying.grey)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .frame(height: 16)
    }

    /// The system's own bar (the only one it moves by itself), made as thick as the system card's and rounded.
    private var bar: some View {
        Group {
            if state.isPlaying {
                ProgressView(timerInterval: start...end, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
            } else {
                ProgressView(value: min(1, max(0, state.fraction)))
            }
        }
        .progressViewStyle(.linear)
        .tint(LockScreenNowPlaying.grey)
        .scaleEffect(x: 1, y: 1.75, anchor: .center)
        .frame(height: 7)
        .clipShape(Capsule())
    }

    /// 0:45, 12:04, 1:02:45.
    static func clock(_ seconds: Double) -> String {
        let s = Int(max(0, seconds).rounded(.down))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Back 10 seconds, play or pause, forward 30 seconds: white, the middle one larger, spaced as the system card's.
struct LockScreenTransport: View {
    var state: NowPlayingAttributes.ContentState
    var body: some View {
        HStack(spacing: 0) {
            if state.canSkip {
                Button(intent: SkipBackTVIntent()) { glyph("gobackward.10", 23, .semibold) }
                    .accessibilityLabel("Back 10 Seconds")
            }
            Button(intent: PlayPauseTVIntent()) { glyph(state.isPlaying ? "pause.fill" : "play.fill", 32, .bold) }
                .accessibilityLabel(state.isPlaying ? "Pause" : "Play")
            if state.canSkip {
                Button(intent: SkipForwardTVIntent()) { glyph("goforward.30", 23, .semibold) }
                    .accessibilityLabel("Forward 30 Seconds")
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
    }

    private func glyph(_ name: String, _ size: CGFloat, _ weight: Font.Weight) -> some View {
        Image(systemName: name).font(.system(size: size, weight: weight))
            .frame(width: 71, height: 36)
            .contentShape(Rectangle())
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
                .background(WidgetBackdrop())   // the app icon's colours
                .tint(WidgetPalette.cyan)
                .activityBackgroundTint(WidgetPalette.navyBottom)
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
