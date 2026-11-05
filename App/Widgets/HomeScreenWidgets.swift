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
                                                              thermostatAction: "idle",
                                                              tvs: [.init(id: "1", name: "Living Room", online: true, title: "The Bear", isPlaying: true),
                                                                    .init(id: "2", name: "Master Bedroom", online: true, title: nil, isPlaying: false),
                                                                    .init(id: "3", name: "Den", online: true, title: "Planet Earth", isPlaying: false),
                                                                    .init(id: "4", name: "Elliott's Room", online: false, title: nil, isPlaying: false)]))
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

// MARK: - Now Playing (every TV)

struct NowPlayingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: PhoneWidgetShare.nowPlayingKind, provider: ShareProvider()) { entry in
            TVsWidgetView(s: entry.s)
                .environment(\.colorScheme, .dark)
                .widgetURL(URL(string: "woodruff://remote"))
        }
        .configurationDisplayName("TVs")
        .description("What every TV is playing, with play and pause.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular])
    }
}

struct TVsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let s: PhoneWidgetShare.Snapshot?

    private var tvs: [PhoneWidgetShare.TVLine] { s?.tvs ?? [] }

    var body: some View {
        Group {
            if tvs.isEmpty {
                Text(PhoneWidgetShare.emptyText).font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                switch family {
                case .accessoryRectangular: lockScreen
                case .systemSmall: small
                case .systemLarge: rows(limit: 6, detail: true)
                default: rows(limit: 4, detail: false)
                }
            }
        }
        .containerBackground(for: .widget) {
            if family == .accessoryRectangular { Color.clear } else { TVsBackground(art: s?.art) }
        }
    }

    /// Medium and large: one row per TV, its name, what's on, and play/pause.
    private func rows(limit: Int, detail: Bool) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(tvs.prefix(limit).enumerated()), id: \.element.id) { i, tv in
                if i > 0 { Divider().overlay(.white.opacity(0.12)) }
                HStack(spacing: 10) {
                    Text(tv.name)
                        .font(.subheadline.weight(.semibold)).lineLimit(1)
                        .frame(width: detail ? 118 : 104, alignment: .leading)
                    Text(status(tv))
                        .font(.subheadline)
                        .foregroundStyle(tv.title != nil ? .primary : .secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if tv.title != nil {
                        Button(intent: PlayPauseTVOnIntent(tvID: tv.id)) {
                            Image(systemName: tv.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 12, weight: .bold))
                                .frame(width: 30, height: 30)
                                .background(.white.opacity(0.18), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(tv.isPlaying ? "Pause \(tv.name)" : "Play \(tv.name)")
                    } else {
                        Color.clear.frame(width: 30, height: 30)
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
    }

    /// Small: every TV on a line, with how it's doing.
    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(tvs.prefix(4)) { tv in
                HStack(spacing: 6) {
                    Text(tv.name).font(.caption.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(short(tv)).font(.caption2).foregroundStyle(tv.isPlaying ? .primary : .secondary).lineLimit(1)
                }
                .frame(maxHeight: .infinity)
            }
        }
    }

    /// Lock Screen: the TV that's playing (else the first), and what's on.
    private var lockScreen: some View {
        let tv = tvs.first(where: \.isPlaying) ?? tvs.first(where: { $0.title != nil }) ?? tvs[0]
        return VStack(alignment: .leading, spacing: 1) {
            Text(tv.name).font(.caption2.weight(.semibold)).widgetAccentable()
            Text(status(tv)).font(.headline).lineLimit(1)
            let others = tvs.filter { $0.isPlaying && $0.id != tv.id }.count
            if others > 0 { Text(others == 1 ? "1 more TV playing" : "\(others) more TVs playing").font(.caption2).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func status(_ tv: PhoneWidgetShare.TVLine) -> String {
        if let t = tv.title { return t }
        return tv.online ? "Nothing playing" : "Off"
    }

    private func short(_ tv: PhoneWidgetShare.TVLine) -> String {
        if tv.isPlaying { return "Playing" }
        if tv.title != nil { return "Paused" }
        return tv.online ? "On" : "Off"
    }
}

/// Dark, with the playing title's picture softly behind when there is one.
struct TVsBackground: View {
    let art: String?

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.13, green: 0.14, blue: 0.20), Color(red: 0.05, green: 0.05, blue: 0.08)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            if let art, let url = PhoneWidgetShare.artURL(art), let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image).resizable().scaledToFill().blur(radius: 24).opacity(0.45)
                Color.black.opacity(0.35)
            }
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
            Text(s?.weatherWords ?? (s == nil ? PhoneWidgetShare.emptyText : "Weather")).font(.caption.weight(.medium)).lineLimit(1)
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
