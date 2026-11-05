import SwiftUI
import WidgetKit
import AppIntents

// The iPhone's Home Screen and Lock Screen widgets. They show what the app last handed over (PhoneWidgetShare);
// their buttons run in the app, which holds the TVs' pairing keys.

struct ShareEntry: TimelineEntry {
    let date: Date
    let s: PhoneWidgetShare.Snapshot?
}

struct ShareProvider: TimelineProvider {
    func placeholder(in context: Context) -> ShareEntry {
        ShareEntry(date: Date(), s: PhoneWidgetShare.Snapshot(tvName: "Living Room", title: "Movie Night", detail: "Plex",
                                                              isPlaying: true, weatherTemp: "64°", weatherSymbol: "sun.max.fill",
                                                              weatherWords: "Sunny", highLow: "H 70°  L 52°",
                                                              thermostatName: "Thermostat", thermostatTemp: "70°", thermostatSet: "68°",
                                                              thermostatAction: "idle"))
    }
    func getSnapshot(in context: Context, completion: @escaping (ShareEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : ShareEntry(date: Date(), s: PhoneWidgetShare.load()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<ShareEntry>) -> Void) {
        // The app reloads the widgets when anything changes; this is only a fallback.
        completion(Timeline(entries: [ShareEntry(date: Date(), s: PhoneWidgetShare.load())],
                            policy: .after(Date().addingTimeInterval(1800))))
    }
}

// MARK: - Now Playing

struct NowPlayingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: PhoneWidgetShare.nowPlayingKind, provider: ShareProvider()) { entry in
            NowPlayingWidgetView(s: entry.s)
                .widgetURL(URL(string: "woodruff://remote"))
        }
        .configurationDisplayName("Now Playing")
        .description("What the TV is playing, with play and pause.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
        .contentMarginsDisabled()
    }
}

struct NowPlayingWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let s: PhoneWidgetShare.Snapshot?

    var body: some View {
        let playing = s?.title != nil
        switch family {
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Text(s?.tvName ?? "Woodruff").font(.caption2.weight(.semibold)).widgetAccentable()
                Text(s?.title ?? "Nothing playing").font(.headline).lineLimit(1)
                if let d = s?.detail, !d.isEmpty { Text(d).font(.caption).lineLimit(1).foregroundStyle(.secondary) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .containerBackground(for: .widget) { Color.clear }
        default:
            ZStack(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 2) {
                    Spacer(minLength: 0)
                    Text(s?.tvName ?? "Woodruff").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                    Text(s?.title ?? (s == nil ? "Open the app once" : "Nothing playing"))
                        .font(family == .systemSmall ? .headline : .title3.weight(.semibold))
                        .foregroundStyle(.white).lineLimit(2)
                    if family == .systemMedium, let d = s?.detail, !d.isEmpty {
                        Text(d).font(.caption).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                    }
                }
                .padding(14)
                .padding(.trailing, playing ? 44 : 0)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                if playing {
                    Button(intent: PlayPauseTVIntent()) {
                        Image(systemName: s?.isPlaying == true ? "pause.fill" : "play.fill")
                            .font(.system(size: 15, weight: .bold)).foregroundStyle(.black)
                            .frame(width: 36, height: 36)
                            .background(.white, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(s?.isPlaying == true ? "Pause" : "Play")
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
            }
            .containerBackground(for: .widget) { ArtBackground(name: s?.art) }
        }
    }
}

/// The title's picture with a dark fade for the text, or a quiet gradient.
struct ArtBackground: View {
    let name: String?

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.22), Color(white: 0.08)], startPoint: .topLeading, endPoint: .bottomTrailing)
            if let name, let url = PhoneWidgetShare.artURL(name), let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image).resizable().scaledToFill()
            }
            LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
        }
    }
}

// MARK: - Home (weather, thermostat, scenes)

struct HomeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: PhoneWidgetShare.homeKind, provider: ShareProvider()) { entry in
            HomeWidgetView(s: entry.s)
                .environment(\.colorScheme, .dark)   // light text on its dark blue
                .widgetURL(URL(string: "woodruff://home"))
        }
        .configurationDisplayName("Home")
        .description("The weather, the thermostat and your scenes.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryInline])
    }
}

struct HomeWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let s: PhoneWidgetShare.Snapshot?

    var body: some View {
        switch family {
        case .accessoryInline:
            Label(s?.weatherTemp ?? "--", systemImage: s?.weatherSymbol ?? "cloud")
                .containerBackground(for: .widget) { Color.clear }
        case .accessoryCircular:
            VStack(spacing: 0) {
                Image(systemName: s?.weatherSymbol ?? "cloud").font(.body)
                Text(s?.weatherTemp ?? "--").font(.headline)
            }
            .containerBackground(for: .widget) { AccessoryWidgetBackground() }
        case .systemMedium:
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    weather
                    Spacer(minLength: 0)
                    thermostat
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(spacing: 8) {
                    SceneButton(id: "movie-night", name: "Movie Night")
                    SceneButton(id: "bedtime", name: "Bedtime")
                }
                .frame(width: 128)
            }
            .containerBackground(for: .widget) { HomeBackground() }
        default:
            VStack(alignment: .leading, spacing: 8) {
                weather
                Spacer(minLength: 0)
                thermostat
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .containerBackground(for: .widget) { HomeBackground() }
        }
    }

    private var weather: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: s?.weatherSymbol ?? "cloud").symbolRenderingMode(.multicolor).font(.title3)
                Text(s?.weatherTemp ?? "--").font(.system(size: 30, weight: .semibold, design: .rounded))
            }
            Text(s?.weatherWords ?? (s == nil ? "Open the app once" : "Weather")).font(.caption.weight(.medium)).lineLimit(1)
            if let hl = s?.highLow { Text(hl).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
        }
    }

    @ViewBuilder private var thermostat: some View {
        if let t = s?.thermostatTemp {
            VStack(alignment: .leading, spacing: 1) {
                Text("Inside \(t)").font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(thermostatLine).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private var thermostatLine: String {
        switch s?.thermostatAction {
        case "heating": return "Heating to \(s?.thermostatSet ?? "")"
        case "cooling": return "Cooling to \(s?.thermostatSet ?? "")"
        case "off": return "Thermostat off"
        default: return s?.thermostatSet.map { "Set to \($0)" } ?? ""
        }
    }
}

struct SceneButton: View {
    let id: String
    let name: String

    var body: some View {
        Button(intent: RunSceneControlIntent(sceneID: id)) {
            Text(name).font(.footnote.weight(.semibold)).lineLimit(1)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

struct HomeBackground: View {
    var body: some View {
        LinearGradient(colors: [Color(red: 0.16, green: 0.24, blue: 0.40), Color(red: 0.07, green: 0.10, blue: 0.20)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}
