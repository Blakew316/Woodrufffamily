import SwiftUI
import WidgetKit
import AppIntents
import WoodruffKit

@main
struct WoodruffMacWidgets: WidgetBundle {
    var body: some Widget {
        NowPlayingWidget()
        AllTVsWidget()
    }
}

// MARK: - Data

/// One TV as a widget shows it.
struct WidgetTV: Hashable, Identifiable {
    var id: String
    var name: String
    var online: Bool
    var playing: NowPlaying?
    var hub: SharedStore.HubLink
    var routeID: String
}

struct TVsEntry: TimelineEntry {
    let date: Date
    let tvs: [WidgetTV]
    let selected: WidgetTV?
    let art: Data?
    let paired: Bool
}

/// Asks the paired TVs directly (the app shares their keys), so the widgets work while the app is closed.
struct TVsProvider: TimelineProvider {
    func placeholder(in context: Context) -> TVsEntry { TVsEntry(date: .now, tvs: [], selected: nil, art: nil, paired: true) }

    func getSnapshot(in context: Context, completion: @escaping (TVsEntry) -> Void) {
        Task { completion(await load()) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TVsEntry>) -> Void) {
        Task {
            let e = await load()
            completion(Timeline(entries: [e], policy: .after(.now.addingTimeInterval(e.selected?.playing != nil ? 120 : 600))))
        }
    }

    func load() async -> TVsEntry {
        guard let snap = SharedStore.load(), !snap.hubs.isEmpty else { return TVsEntry(date: .now, tvs: [], selected: nil, art: nil, paired: false) }
        var tvs: [String: WidgetTV] = [:]
        for hub in snap.hubs {
            let t = TVTransport(TVConnection(base: hub.base, key: hub.key))
            guard let list: TVList = try? await t.get("/api/tvs", timeout: 6) else { continue }
            for e in list.tvs {
                let id = e.id == "this" ? hub.id : e.id
                if let old = tvs[id], old.routeID == "this" { continue }
                tvs[id] = WidgetTV(id: id, name: snap.names[id] ?? e.name, online: e.online, playing: e.playing, hub: hub, routeID: e.id)
            }
        }
        let list = tvs.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let selected = list.first { $0.id == snap.selectedID } ?? list.first { $0.playing != nil } ?? list.first
        var art: Data?
        if let s = selected, let p = s.playing { art = await poster(for: p, hub: s.hub) }
        return TVsEntry(date: .now, tvs: list, selected: selected, art: art, paired: true)
    }

    /// The title's poster from the hub's library (by its Drive key, else its name).
    private func poster(for p: NowPlaying, hub: SharedStore.HubLink) async -> Data? {
        let c = TVClient(hub: Hub(id: hub.id, name: hub.name, connection: TVConnection(base: hub.base, key: hub.key)), routeID: "this")
        guard let home = try? await c.watchHome() else { return nil }
        let simple: (String) -> String = { $0.lowercased().filter { $0.isLetter || $0.isNumber } }
        let titles = (home.featured ?? []) + (home.recent ?? []) + (home.movies?.items ?? []) + (home.shows?.items ?? [])
        var path: String?
        if let key = p.key, let c = (home.continue ?? []).first(where: { $0.key == key }) { path = c.poster }
        if path == nil, let key = p.key { path = titles.first { "drive:" + $0.id == key }?.poster }
        if path == nil {
            let want = simple(String(p.title.split(separator: "·").first ?? Substring(p.title)))
            path = (home.continue ?? []).first { want.hasPrefix(simple($0.name)) }?.poster ?? titles.first { want.hasPrefix(simple($0.title)) }?.poster
        }
        guard let path, let url = c.art(path) else { return nil }
        return try? await URLSession.woodruff.data(from: url).0
    }
}

// MARK: - Buttons

/// Presses a key on a TV straight from the widget.
struct WidgetKeyIntent: AppIntent {
    static let title: LocalizedStringResource = "Press a TV Key"
    @Parameter(title: "Hub") var hub: String
    @Parameter(title: "Pairing") var pairing: String
    @Parameter(title: "TV") var route: String
    @Parameter(title: "Key") var key: String

    init() {}
    init(tv: WidgetTV, key: String) {
        self.hub = tv.hub.base.absoluteString
        self.pairing = tv.hub.key
        self.route = tv.routeID
        self.key = key
    }

    func perform() async throws -> some IntentResult {
        if let base = URL(string: hub) {
            let c = TVClient(hub: Hub(id: "", name: "", connection: TVConnection(base: base, key: pairing)), routeID: route)
            try? await c.key(key)
            try? await Task.sleep(nanoseconds: 800_000_000)
        }
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}

// MARK: - Now Playing

struct NowPlayingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.woodruff.family.widget.nowplaying", provider: TVsProvider()) { e in
            NowPlayingWidgetView(entry: e)
        }
        .configurationDisplayName("Now Playing")
        .description("What the remote’s TV is playing, with play and pause.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct NowPlayingWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var entry: TVsEntry

    var body: some View {
        let tv = entry.selected
        let p = tv?.playing
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(tv?.name ?? "Woodruff").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.75))
                Spacer()
                if let tv, p != nil {
                    Button(intent: WidgetKeyIntent(tv: tv, key: "playpause")) {
                        Image(systemName: p?.isPlaying == true ? "pause.fill" : "play.fill").font(.headline)
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer(minLength: 0)
            Text(p?.title ?? (entry.paired ? "Nothing Playing" : "Open Woodruff to pair")).font(family == .systemSmall ? .headline : .title3.bold()).lineLimit(2)
            if let a = p?.app { Text(a).font(.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(1) }
            if let p, let d = p.duration, d > 0 {
                ProgressView(value: min(1, (p.position ?? 0) / d)).tint(.white).padding(.top, 4)
            }
        }
        .foregroundStyle(.white)
        .containerBackground(for: .widget) {
            ZStack {
                Color.black
                if let data = entry.art, let img = NSImage(data: data) {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fill).blur(radius: family == .systemSmall ? 0 : 0)
                        .opacity(0.9)
                } else {
                    LinearGradient(colors: [Color(red: 0.16, green: 0.34, blue: 0.5), .black], startPoint: .topLeading, endPoint: .bottomTrailing)
                }
                LinearGradient(colors: [.black.opacity(0.1), .black.opacity(0.8)], startPoint: .top, endPoint: .bottom)
            }
        }
        .widgetURL(URL(string: "woodruff://remote"))
    }
}

// MARK: - Every TV

struct AllTVsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.woodruff.family.widget.tvs", provider: TVsProvider()) { e in
            AllTVsWidgetView(entry: e)
        }
        .configurationDisplayName("TVs")
        .description("Every TV, what it’s playing, and play and pause.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct AllTVsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var entry: TVsEntry

    var body: some View {
        VStack(alignment: .leading, spacing: family == .systemLarge ? 12 : 8) {
            Text("TVs").font(.headline)
            if entry.tvs.isEmpty {
                Text(entry.paired ? "No TVs answered." : "Open Woodruff to pair your TVs.").font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(entry.tvs.prefix(family == .systemLarge ? 8 : 4)) { tv in
                HStack(spacing: 10) {
                    Circle().fill(tv.online ? (tv.playing?.isPlaying == true ? Color.accentColor : .green) : .gray).frame(width: 7, height: 7)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(tv.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(tv.playing?.title ?? (tv.online ? "Nothing playing" : "Off")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    if tv.playing != nil {
                        Button(intent: WidgetKeyIntent(tv: tv, key: "playpause")) {
                            Image(systemName: tv.playing?.isPlaying == true ? "pause.fill" : "play.fill")
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}
