import SwiftUI
import WidgetKit
import AppIntents
import WoodruffKit

@main
struct WoodruffMacWidgets: WidgetBundle {
    var body: some Widget {
        NowPlayingWidget()
        AllTVsWidget()
        HomeDevicesWidget()
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
        // Every TV the app knows is listed, even one no hub reports (an LG paired directly, a TV just added);
        // what the hubs said just now wins where they did.
        for t in snap.tvs ?? [] where tvs[t.id] == nil {
            guard let hub = snap.hubs.first(where: { $0.id == t.hubID }) ?? snap.hubs.first else { continue }
            tvs[t.id] = WidgetTV(id: t.id, name: snap.names[t.id] ?? t.name, online: t.online, playing: t.playing, hub: hub, routeID: t.routeID)
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

// MARK: - Speakers & Lights

struct HomeEntry: TimelineEntry {
    let date: Date
    let speaker: SonosRoom?
    let lights: [GoveeLight]
    let art: Data?
}

/// The Sonos room last used (asked live) and the lights, from what the app shared.
struct HomeProvider: TimelineProvider {
    func placeholder(in context: Context) -> HomeEntry { HomeEntry(date: .now, speaker: nil, lights: [], art: nil) }
    func getSnapshot(in context: Context, completion: @escaping (HomeEntry) -> Void) { Task { completion(await load()) } }
    func getTimeline(in context: Context, completion: @escaping (Timeline<HomeEntry>) -> Void) {
        Task {
            let e = await load()
            completion(Timeline(entries: [e], policy: .after(.now.addingTimeInterval(e.speaker?.isPlaying == true ? 120 : 600))))
        }
    }

    func load() async -> HomeEntry {
        let snap = SharedStore.load()
        let speakers = snap?.speakers ?? []
        var speaker = speakers.first(where: \.isPlaying) ?? speakers.first
        if let s = speaker { speaker = await Sonos.refresh(s) }
        var art: Data?
        if let u = speaker?.art { art = try? await URLSession.shared.data(from: u).0 }
        return HomeEntry(date: .now, speaker: speaker, lights: snap?.lights ?? [], art: art)
    }
}

/// Plays or pauses a Sonos room, or skips, straight from the widget.
struct WidgetSonosIntent: AppIntent {
    static let title: LocalizedStringResource = "Control a Sonos Room"
    @Parameter(title: "Room") var roomID: String
    @Parameter(title: "Action") var action: String
    init() {}
    init(roomID: String, action: String) { self.roomID = roomID; self.action = action }

    func perform() async throws -> some IntentResult {
        if let r = SharedStore.load()?.speakers?.first(where: { $0.id == roomID }) {
            let fresh = await Sonos.refresh(r)
            switch action {
            case "next": try? await Sonos.next(r)
            default: if fresh.isPlaying { try? await Sonos.pause(r) } else { try? await Sonos.play(r) }
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        WidgetCenter.shared.reloadTimelines(ofKind: "com.woodruff.family.widget.home")
        return .result()
    }
}

/// Turns a light on or off over the Wi‑Fi from the widget.
struct WidgetLightIntent: AppIntent {
    static let title: LocalizedStringResource = "Turn a Light On or Off"
    @Parameter(title: "Light") var lightID: String
    init() {}
    init(lightID: String) { self.lightID = lightID }

    func perform() async throws -> some IntentResult {
        if var snap = SharedStore.load(), var lights = snap.lights, let i = lights.firstIndex(where: { $0.id == lightID }), let ip = lights[i].ip {
            lights[i].on.toggle()
            Govee.lanTurn(ip, lights[i].on)
            snap.lights = lights
            SharedStore.save(snap)
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        WidgetCenter.shared.reloadTimelines(ofKind: "com.woodruff.family.widget.home")
        return .result()
    }
}

struct HomeDevicesWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.woodruff.family.widget.home", provider: HomeProvider()) { e in
            HomeDevicesWidgetView(entry: e)
        }
        .configurationDisplayName("Speakers & Lights")
        .description("What Sonos is playing, and your lights at a click.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct HomeDevicesWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var entry: HomeEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let s = entry.speaker {
                HStack(spacing: 10) {
                    Group {
                        if let d = entry.art, let img = NSImage(data: d) { Image(nsImage: img).resizable().scaledToFill() }
                        else { Color.white.opacity(0.1).overlay { Image(systemName: "hifispeaker.fill").foregroundStyle(.secondary) } }
                    }
                    .frame(width: 40, height: 40).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(s.name).font(.caption.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
                        Text(s.title ?? "Not Playing").font(.subheadline.weight(.semibold)).lineLimit(1)
                        if family != .systemSmall, let a = s.artist { Text(a).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }
                    Spacer(minLength: 0)
                    if family != .systemSmall {
                        Button(intent: WidgetSonosIntent(roomID: s.id, action: "playpause")) {
                            Image(systemName: s.isPlaying ? "pause.fill" : "play.fill").font(.headline)
                        }.buttonStyle(.plain)
                        Button(intent: WidgetSonosIntent(roomID: s.id, action: "next")) {
                            Image(systemName: "forward.fill").font(.headline)
                        }.buttonStyle(.plain)
                    }
                }
                if family == .systemSmall {
                    Button(intent: WidgetSonosIntent(roomID: s.id, action: "playpause")) {
                        Label(s.isPlaying ? "Pause" : "Play", systemImage: s.isPlaying ? "pause.fill" : "play.fill").font(.caption.weight(.semibold))
                    }
                }
            }
            if family != .systemSmall || entry.speaker == nil {
                let cols = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
                LazyVGrid(columns: cols, spacing: 8) {
                    ForEach(entry.lights.prefix(family == .systemLarge ? 10 : (entry.speaker == nil ? 4 : 2))) { l in
                        Button(intent: WidgetLightIntent(lightID: l.id)) {
                            HStack(spacing: 6) {
                                Circle().fill(l.on ? Color.yellow : Color.secondary.opacity(0.4)).frame(width: 8, height: 8)
                                Text(l.name).font(.caption.weight(.semibold)).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(l.on ? Color.white.opacity(0.22) : Color.white.opacity(0.07)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if entry.speaker == nil && entry.lights.isEmpty {
                Text("Open Woodruff to find your Sonos and lights.").font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}
