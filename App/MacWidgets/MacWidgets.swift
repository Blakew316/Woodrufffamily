import SwiftUI
import WidgetKit
import AppIntents
import ImageIO
import WoodruffKit

@main
struct WoodruffMacWidgets: WidgetBundle {
    var body: some Widget {
        NowPlayingWidget()
        AllTVsWidget()
        HomeDevicesWidget()
        MacTVsCamerasWidget()
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
    /// A button here that didn't work a moment ago, said in the widget (it has no other way to say so).
    let problem: String?
}

/// What a widget button that didn't work says, for a minute and a half (by widget: "tvs" or "home").
enum WidgetProblem {
    /// How long a note shows, in seconds.
    static let lasts: TimeInterval = 90
    private static func key(_ kind: String) -> String { "widget.problem.\(kind)" }

    static func set(_ text: String?, for kind: String) {
        guard let d = SharedStore.defaults else { return }
        if let text { d.set(["text": text, "at": Date().timeIntervalSince1970], forKey: key(kind)) }
        else { d.removeObject(forKey: key(kind)) }
    }

    static func current(_ kind: String) -> String? {
        guard let d = SharedStore.defaults?.dictionary(forKey: key(kind)),
              let text = d["text"] as? String, let at = d["at"] as? Double else { return nil }
        return Date().timeIntervalSince1970 - at < lasts ? text : nil
    }
}

/// [work]'s answer when it comes within [seconds]; nil when it doesn't, or has none (a widget has only a few seconds
/// to draw, and a TV that's off would otherwise use them all).
private func within<T: Sendable>(_ seconds: Double, _ work: @escaping @Sendable () async -> T?) async -> T? {
    await withTaskGroup(of: T?.self, returning: T?.self) { g in
        g.addTask { await work() }
        g.addTask {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return nil
        }
        let first = await g.next() ?? nil
        g.cancelAll()
        return first
    }
}

/// Asks the paired TVs directly (the app shares their keys), so the widgets work while the app is closed.
struct TVsProvider: TimelineProvider {
    func placeholder(in context: Context) -> TVsEntry { TVsEntry(date: .now, tvs: [], selected: nil, art: nil, paired: true, problem: nil) }

    func getSnapshot(in context: Context, completion: @escaping (TVsEntry) -> Void) {
        // The widget gallery: what the app last saw, at once (no waiting on the TVs).
        if context.isPreview { completion(TVsProvider.saved()); return }
        Task { completion(await TVsLoads.shared.entry()) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TVsEntry>) -> Void) {
        Task {
            let e = await TVsLoads.shared.entry()
            // While something plays, again in five minutes (the bars move by themselves, and the app reloads these the
            // moment a TV changes while it runs); otherwise every ten. Sooner when a note about a button that
            // didn't work is showing, so it goes once it's old.
            let playing = e.tvs.contains { $0.playing?.isPlaying == true }
            let next: TimeInterval = e.problem != nil ? WidgetProblem.lasts + 5 : (playing ? 300 : 600)
            completion(Timeline(entries: [e], policy: .after(.now.addingTimeInterval(next))))
        }
    }

    /// The TV widgets reload together, so they look once between them (every hub, and the poster), not once each.
    static func reloadAll() {
        WidgetCenter.shared.reloadTimelines(ofKind: "com.woodruff.family.widget.nowplaying")
        WidgetCenter.shared.reloadTimelines(ofKind: "com.woodruff.family.widget.tvs")
        WidgetCenter.shared.reloadTimelines(ofKind: MacCameraShare.kind)
    }

    /// The TVs as the app last saw them (no network).
    static func saved() -> TVsEntry {
        guard let snap = SharedStore.load(), !snap.hubs.isEmpty else {
            return TVsEntry(date: .now, tvs: [], selected: nil, art: nil, paired: false, problem: nil)
        }
        let list = (snap.tvs ?? []).compactMap { t -> WidgetTV? in
            guard let hub = snap.hubs.first(where: { $0.id == t.hubID }) ?? snap.hubs.first else { return nil }
            return WidgetTV(id: t.id, name: snap.names[t.id] ?? t.name, online: t.online, playing: t.playing, hub: hub, routeID: t.routeID)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let selected = list.first { $0.id == snap.selectedID } ?? list.first { $0.playing != nil } ?? list.first
        return TVsEntry(date: .now, tvs: list, selected: selected, art: nil, paired: true, problem: nil)
    }

    func load() async -> TVsEntry {
        guard let snap = SharedStore.load(), !snap.hubs.isEmpty else {
            return TVsEntry(date: .now, tvs: [], selected: nil, art: nil, paired: false, problem: nil)
        }
        // Every hub at once, with a short wait: one that's off never holds up the others.
        var answers: [String: [TVListEntry]] = [:]
        await withTaskGroup(of: (String, [TVListEntry]?).self) { g in
            for hub in snap.hubs {
                g.addTask {
                    let t = TVTransport(TVConnection(base: hub.base, key: hub.key))
                    let list = try? await t.get("/api/tvs", as: TVList.self, timeout: 4)
                    return (hub.id, list?.tvs)
                }
            }
            for await answer in g {
                if let list = answer.1 { answers[answer.0] = list }
            }
        }
        var tvs: [String: WidgetTV] = [:]
        var rank: [String: Int] = [:]
        // What the app last had each TV playing now (`FleetTV.nowPlaying`, which leaves out a title left paused for a
        // while or already paused when it first saw it): a paused title shows here only when the app had it too, so a
        // session left behind (after leaving YouTube, say) never shows as something to resume.
        var shown: [String: NowPlaying] = [:]
        for t in snap.tvs ?? [] { if let p = t.playing { shown[t.id] = p } }
        // In the order the TVs were paired, so the same answers always give the same list.
        for hub in snap.hubs {
            guard let list = answers[hub.id] else { continue }
            for e in list {
                let id = e.id == "this" ? hub.id : e.id
                // A TV's own answer beats one passed on by another TV; one saying it's on beats one saying it's off.
                let r = e.id == "this" ? 3 : (e.online ? 2 : 1)
                if let have = rank[id], have >= r { continue }
                rank[id] = r
                // Only a TV that's on plays anything (a hub can still hold what an off TV last played).
                var playing = e.online ? e.playing : nil
                if let p = playing, !p.isPlaying, shown[id]?.title != p.title { playing = nil }
                tvs[id] = WidgetTV(id: id, name: snap.names[id] ?? e.name, online: e.online, playing: playing, hub: hub, routeID: e.id)
            }
        }
        // Every TV the app knows is listed, also one no TV reported just now. One whose TV didn't answer is off from
        // here, as the app shows it. None of these plays anything: what the app saw it playing may be long over.
        let silent = Set(snap.hubs.map(\.id).filter { answers[$0] == nil })
        for t in snap.tvs ?? [] where tvs[t.id] == nil {
            guard let hub = snap.hubs.first(where: { $0.id == t.hubID }) ?? snap.hubs.first else { continue }
            let gone = silent.contains(t.hubID) || silent.contains(t.id)
            tvs[t.id] = WidgetTV(id: t.id, name: snap.names[t.id] ?? t.name, online: gone ? false : t.online,
                                 playing: nil, hub: hub, routeID: t.routeID)
        }
        for hub in snap.hubs where tvs[hub.id] == nil {
            tvs[hub.id] = WidgetTV(id: hub.id, name: snap.names[hub.id] ?? hub.name, online: false, playing: nil, hub: hub, routeID: "this")
        }
        let list = tvs.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let selected = list.first { $0.id == snap.selectedID } ?? list.first { $0.playing != nil } ?? list.first
        var art: Data?
        // A poster only for what's actually playing (not something paused, or left behind).
        if let s = selected, let p = s.playing, p.isPlaying {
            let hub = s.hub
            art = await within(5) { await TVsProvider.poster(for: p, hub: hub) }
        }
        return TVsEntry(date: .now, tvs: list, selected: selected, art: art, paired: true, problem: WidgetProblem.current("tvs"))
    }

    /// The title's poster from the hub's library (by its Drive key, else its name), made small enough for a widget.
    static func poster(for p: NowPlaying, hub: SharedStore.HubLink) async -> Data? {
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
        guard let path, let url = c.art(path, small: true) else { return nil }
        guard let data = try? await URLSession.woodruff.data(from: url).0 else { return nil }
        return shrink(data, to: 600) ?? data
    }

    /// A picture made small enough for a widget (they have little memory, and a full-size poster is 2,000 × 3,000).
    static func shrink(_ data: Data, to pixels: Int) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: pixels]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return Data(referencing: out)
    }

    /// [data] decoded no larger than [pixels] across: a camera's frame can be full size, and a widget has little memory.
    static func image(_ data: Data, pixels: Int) -> NSImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceShouldCacheImmediately: true,
                                     kCGImageSourceThumbnailMaxPixelSize: pixels]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return NSImage(cgImage: img, size: NSSize(width: img.width, height: img.height))
    }
}

/// One look at the TVs for every TV widget asking at about the same time: the three are reloaded together, and each
/// would otherwise ask every hub and fetch the poster (the hub's whole Watch home) itself.
actor TVsLoads {
    static let shared = TVsLoads()
    private var running: Task<TVsEntry, Never>?

    func entry() async -> TVsEntry {
        if let running { return await running.value }
        let task = Task { await TVsProvider().load() }
        running = task
        let e = await task.value
        if running == task { running = nil }
        return e
    }

    /// A button was just pressed: the next widget to ask looks again rather than joining a look from before.
    func forget() { running = nil }
}

// MARK: - Buttons

/// Presses a key on a TV straight from the widget. It names the hub by its id and finds its pairing key in what the
/// app shared when pressed, so the key isn't kept in the widget's buttons.
struct WidgetKeyIntent: AppIntent {
    static let title: LocalizedStringResource = "Press a TV Key"
    // Only for the widgets' buttons (Shortcuts has Play or Pause a TV).
    static var isDiscoverable: Bool { false }
    @Parameter(title: "Hub") var hub: String
    @Parameter(title: "TV") var route: String
    @Parameter(title: "Key") var key: String
    @Parameter(title: "Name") var name: String?

    init() {}
    init(tv: WidgetTV, key: String) {
        self.hub = tv.hub.id
        self.route = tv.routeID
        self.key = key
        self.name = tv.name
    }

    func perform() async throws -> some IntentResult {
        guard let link = SharedStore.load()?.hubs.first(where: { $0.id == hub }) else {
            WidgetProblem.set("Open Woodruff once so the widget finds \(name ?? "that TV") again.", for: "tvs")
            await TVsLoads.shared.forget()
            TVsProvider.reloadAll()
            return .result()
        }
        let c = TVClient(hub: Hub(id: link.id, name: link.name, connection: TVConnection(base: link.base, key: link.key)), routeID: route)
        do {
            try await c.key(key)
            WidgetProblem.set(nil, for: "tvs")
        } catch {
            // Said in the widget: a button that looks like it worked but didn't is worse than none.
            WidgetProblem.set("\(name ?? "The TV"): \(error.localizedDescription)", for: "tvs")
        }
        // A moment for the TV to make the change, so the widget shows it when it draws again.
        try? await Task.sleep(nanoseconds: 800_000_000)
        await TVsLoads.shared.forget()
        TVsProvider.reloadAll()
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

/// How far through: a bar that moves by itself while it plays (the system draws it from when the title started and
/// when it ends), still when paused.
struct WidgetProgress: View {
    var playing: NowPlaying
    var at: Date
    var tint: Color = .white

    var body: some View {
        if let d = playing.duration, d > 0 {
            let pos = min(d, max(0, playing.position ?? 0))
            if playing.isPlaying {
                let start = at.addingTimeInterval(-pos / 1000)
                ProgressView(timerInterval: start...start.addingTimeInterval(d / 1000), countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
                    .tint(tint)
            } else {
                ProgressView(value: pos / d).tint(tint)
            }
        }
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
                Text(tv?.name ?? "Woodruff").font(.caption.weight(.bold)).foregroundStyle(WidgetPalette.sky)
                Spacer()
                if let tv, let p {
                    Button(intent: WidgetKeyIntent(tv: tv, key: "playpause")) {
                        Image(systemName: p.isPlaying ? "pause.fill" : "play.fill").font(.headline)
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer(minLength: 0)
            Text(p?.title ?? idleWords(tv)).font(family == .systemSmall ? .headline : .title3.bold()).lineLimit(2)
            if let a = p?.app { Text(a).font(.caption).foregroundStyle(WidgetPalette.sky).lineLimit(1) }
            if let p { WidgetProgress(playing: p, at: entry.date, tint: WidgetPalette.cyan).padding(.top, 4) }
            if let problem = entry.problem {
                Text(problem).font(.caption2).foregroundStyle(.yellow).lineLimit(2)
            }
        }
        .foregroundStyle(WidgetPalette.frost)
        .containerBackground(for: .widget) {
            ZStack {
                // The family's navy, with what's playing softly behind it.
                WidgetBackdrop()
                if let data = entry.art, let img = TVsProvider.image(data, pixels: 600) {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                        .opacity(0.45)
                }
                LinearGradient(colors: [WidgetPalette.navyBottom.opacity(0.15), WidgetPalette.navyBottom.opacity(0.85)], startPoint: .top, endPoint: .bottom)
            }
        }
        .widgetURL(URL(string: "woodruff://remote"))
    }

    private func idleWords(_ tv: WidgetTV?) -> String {
        guard entry.paired else { return "Open Woodruff to pair" }
        guard let tv else { return "No TVs answered" }
        return tv.online ? "Nothing Playing" : "Off"
    }
}

// MARK: - Every TV

struct AllTVsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.woodruff.family.widget.tvs", provider: TVsProvider()) { e in
            AllTVsWidgetView(entry: e)
        }
        .configurationDisplayName("TVs")
        .description("Medium: what the TVs are playing with the doorbell and driveway beside them. Large: every TV.")
        .supportedFamilies([.systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

struct AllTVsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var entry: TVsEntry

    /// As many as fit: two columns of three in the medium size, eight rows in the large one.
    private var room: Int { family == .systemLarge ? 8 : 6 }

    var body: some View {
        // Medium: the iPhone's TVs & Cameras layout (what's playing on the left, the cameras on the right).
        if family == .systemMedium {
            MacTVsCamerasView(entry: entry, cameras: MacCameraShare.load())
                .environment(\.colorScheme, .dark)
                .containerBackground(for: .widget) {
                    WidgetBackdrop()
                }
        } else {
            list
        }
    }

    private var list: some View {
        let shown = Array(entry.tvs.prefix(room))
        let more = entry.tvs.count - shown.count
        return VStack(alignment: .leading, spacing: family == .systemLarge ? 10 : 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("TVs").font(.headline)
                Spacer()
                if more > 0 { Text("+\(more) more").font(.caption).foregroundStyle(.secondary) }
            }
            if entry.tvs.isEmpty {
                Text(entry.paired ? "No TVs answered." : "Open Woodruff to pair your TVs.").font(.subheadline).foregroundStyle(.secondary)
            }
            if family == .systemLarge {
                ForEach(shown) { tv in row(tv, compact: false) }
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10, alignment: .leading), GridItem(.flexible(), spacing: 10, alignment: .leading)],
                          alignment: .leading, spacing: 6) {
                    ForEach(shown) { tv in row(tv, compact: true) }
                }
            }
            Spacer(minLength: 0)
            if let problem = entry.problem {
                Text(problem).font(.caption2).foregroundStyle(.orange).lineLimit(1)
            }
        }
        .padding(16)   // the widget's own margins are off (the medium size fills to its edges)
        .environment(\.colorScheme, .dark)
        .foregroundStyle(WidgetPalette.frost)
        .tint(WidgetPalette.cyan)
        .containerBackground(for: .widget) {
            WidgetBackdrop()
        }
    }

    private func row(_ tv: WidgetTV, compact: Bool) -> some View {
        HStack(spacing: compact ? 6 : 10) {
            Circle().fill(dot(tv)).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(tv.name).font(compact ? Font.caption.weight(.semibold) : Font.subheadline.weight(.semibold)).lineLimit(1)
                Text(status(tv)).font(compact ? Font.caption2 : Font.caption).foregroundStyle(.secondary).lineLimit(1)
                if !compact, let p = tv.playing {
                    WidgetProgress(playing: p, at: entry.date, tint: WidgetPalette.cyan).padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
            if let p = tv.playing {
                Button(intent: WidgetKeyIntent(tv: tv, key: "playpause")) {
                    Image(systemName: p.isPlaying ? "pause.fill" : "play.fill").font(compact ? Font.caption : Font.body)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func dot(_ tv: WidgetTV) -> Color {
        guard tv.online else { return .gray }
        return tv.playing?.isPlaying == true ? Color.accentColor : .green
    }

    private func status(_ tv: WidgetTV) -> String {
        if let p = tv.playing { return (p.isPlaying ? "" : "Paused · ") + p.title }
        return tv.online ? "Nothing playing" : "Off"
    }
}

// MARK: - Speakers & Lights

struct HomeEntry: TimelineEntry {
    let date: Date
    let speaker: SonosRoom?
    let lights: [GoveeLight]
    let art: Data?
    let problem: String?
}

/// The Sonos room last used (asked live) and the lights, from what the app shared.
struct HomeProvider: TimelineProvider {
    func placeholder(in context: Context) -> HomeEntry { HomeEntry(date: .now, speaker: nil, lights: [], art: nil, problem: nil) }
    func getSnapshot(in context: Context, completion: @escaping (HomeEntry) -> Void) {
        if context.isPreview {
            let snap = SharedStore.load()
            let speakers = snap?.speakers ?? []
            completion(HomeEntry(date: .now, speaker: speakers.first(where: \.isPlaying) ?? speakers.first, lights: snap?.lights ?? [], art: nil, problem: nil))
            return
        }
        Task { completion(await load()) }
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<HomeEntry>) -> Void) {
        Task {
            let e = await load()
            let next: TimeInterval = e.problem != nil ? WidgetProblem.lasts + 5 : (e.speaker?.isPlaying == true ? 300 : 600)
            completion(Timeline(entries: [e], policy: .after(.now.addingTimeInterval(next))))
        }
    }

    func load() async -> HomeEntry {
        let snap = SharedStore.load()
        let speakers = snap?.speakers ?? []
        var speaker = speakers.first(where: \.isPlaying) ?? speakers.first
        // Asked live, briefly (a speaker that's off would otherwise use up the widget's time).
        if let s = speaker, let fresh = await within(6, { () async -> SonosRoom? in await Sonos.refresh(s) }) { speaker = fresh }
        var art: Data?
        if let u = speaker?.art {
            art = await within(4) { () async -> Data? in
                guard let d = try? await URLSession.shared.data(from: u).0 else { return nil }
                return TVsProvider.shrink(d, to: 300) ?? d
            }
        }
        return HomeEntry(date: .now, speaker: speaker, lights: snap?.lights ?? [], art: art, problem: WidgetProblem.current("home"))
    }
}

/// Plays or pauses a Sonos room, or skips, straight from the widget.
struct WidgetSonosIntent: AppIntent {
    static let title: LocalizedStringResource = "Control a Sonos Room"
    static var isDiscoverable: Bool { false }
    @Parameter(title: "Room") var roomID: String
    @Parameter(title: "Action") var action: String
    init() {}
    init(roomID: String, action: String) { self.roomID = roomID; self.action = action }

    func perform() async throws -> some IntentResult {
        if let r = SharedStore.load()?.speakers?.first(where: { $0.id == roomID }) {
            // As the room is now (its group's leader may have changed since the app last looked).
            let fresh = await Sonos.refresh(r)
            do {
                switch action {
                case "next": try await Sonos.next(fresh)
                default: if fresh.isPlaying { try await Sonos.pause(fresh) } else { try await Sonos.play(fresh) }
                }
                WidgetProblem.set(nil, for: "home")
            } catch {
                WidgetProblem.set("\(r.name) didn’t do that: \(error.localizedDescription)", for: "home")
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        } else {
            WidgetProblem.set("Open Woodruff once so the widget finds that room again.", for: "home")
        }
        WidgetCenter.shared.reloadTimelines(ofKind: "com.woodruff.family.widget.home")
        return .result()
    }
}

/// Turns a light on or off over the Wi‑Fi from the widget.
struct WidgetLightIntent: AppIntent {
    static let title: LocalizedStringResource = "Turn a Light On or Off"
    static var isDiscoverable: Bool { false }
    @Parameter(title: "Light") var lightID: String
    init() {}
    init(lightID: String) { self.lightID = lightID }

    func perform() async throws -> some IntentResult {
        if var snap = SharedStore.load(), var lights = snap.lights, let i = lights.firstIndex(where: { $0.id == lightID }) {
            if let ip = lights[i].ip {
                lights[i].on.toggle()
                Govee.lanTurn(ip, lights[i].on)
                snap.lights = lights
                SharedStore.save(snap)
                WidgetProblem.set(nil, for: "home")
                try? await Task.sleep(nanoseconds: 300_000_000)
            } else {
                // Only lamps on this Wi‑Fi can be switched from here; the app reaches the others.
                WidgetProblem.set("\(lights[i].name) can only be switched in Woodruff.", for: "home")
            }
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
                        if let d = entry.art, let img = TVsProvider.image(d, pixels: 120) { Image(nsImage: img).resizable().scaledToFill() }
                        else { Color.primary.opacity(0.08).overlay { Image(systemName: "hifispeaker.fill").foregroundStyle(.secondary) } }
                    }
                    .frame(width: 40, height: 40).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(s.name).font(.caption.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
                        Text(s.isOffline ? "Not Answering" : (s.title ?? "Not Playing")).font(.subheadline.weight(.semibold)).lineLimit(1)
                        if family != .systemSmall, let a = s.artist { Text(a).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }
                    Spacer(minLength: 0)
                    if family != .systemSmall && !s.isOffline {
                        Button(intent: WidgetSonosIntent(roomID: s.id, action: "playpause")) {
                            Image(systemName: s.isPlaying ? "pause.fill" : "play.fill").font(.headline)
                        }.buttonStyle(.plain)
                        if !s.isTV {
                            Button(intent: WidgetSonosIntent(roomID: s.id, action: "next")) {
                                Image(systemName: "forward.fill").font(.headline)
                            }.buttonStyle(.plain)
                        }
                    }
                }
                if family == .systemSmall && !s.isOffline {
                    Button(intent: WidgetSonosIntent(roomID: s.id, action: "playpause")) {
                        Label(s.isPlaying ? "Pause" : "Play", systemImage: s.isPlaying ? "pause.fill" : "play.fill").font(.caption.weight(.semibold))
                    }
                }
            }
            if family != .systemSmall || entry.speaker == nil {
                let cols = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
                LazyVGrid(columns: cols, spacing: 8) {
                    ForEach(entry.lights.prefix(family == .systemLarge ? 10 : (entry.speaker == nil ? 4 : 2))) { l in
                        // A lamp on this Wi‑Fi switches from here; any other (or one not answering) opens the app.
                        if l.ip != nil && !l.isOffline {
                            Button(intent: WidgetLightIntent(lightID: l.id)) { lightLabel(l) }
                                .buttonStyle(.plain)
                        } else {
                            lightLabel(l).opacity(0.55)
                        }
                    }
                }
            }
            if entry.speaker == nil && entry.lights.isEmpty {
                Text("Open Woodruff to find your Sonos and lights.").font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let problem = entry.problem {
                Text(problem).font(.caption2).foregroundStyle(.orange).lineLimit(2)
            }
        }
        .environment(\.colorScheme, .dark)
        .foregroundStyle(WidgetPalette.frost)
        .tint(WidgetPalette.cyan)
        .containerBackground(for: .widget) {
            WidgetBackdrop()
        }
    }

    private func lightLabel(_ l: GoveeLight) -> some View {
        HStack(spacing: 6) {
            Circle().fill(l.isLit ? Color.yellow : Color.secondary.opacity(0.4)).frame(width: 8, height: 8)
            Text(l.name).font(.caption.weight(.semibold)).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(l.isLit ? Color.yellow.opacity(0.22) : Color.primary.opacity(0.07)))
    }
}


// MARK: - TVs & Cameras

/// The Mac's TVs & Cameras widget (medium), as on the iPhone: Master Bedroom, Living Room and Kyler's Room down the
/// left with what each is playing, the Doorbell and Front Driveway's latest pictures on the right.
struct MacTVsCamerasWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: MacCameraShare.kind, provider: TVsProvider()) { e in
            MacTVsCamerasView(entry: e, cameras: MacCameraShare.load())
                .environment(\.colorScheme, .dark)
                .containerBackground(for: .widget) {
                    WidgetBackdrop()
                }
        }
        .configurationDisplayName("TVs & Cameras")
        .description("What the TVs are playing, with the doorbell and driveway beside them.")
        .supportedFamilies([.systemMedium])
        .contentMarginsDisabled()
    }
}

struct MacTVsCamerasView: View {
    var entry: TVsEntry
    var cameras: [MacCameraShare.Line]

    private var tvs: [WidgetTV] {
        func key(_ n: String) -> String { n.lowercased().replacingOccurrences(of: "\u{2019}", with: "'") }
        var out: [WidgetTV] = []
        for name in ["master bedroom", "living room", "kyler's room"] {
            if let t = entry.tvs.first(where: { key($0.name) == name }) { out.append(t) }
        }
        for t in entry.tvs where out.count < 3 && !out.contains(where: { $0.id == t.id }) { out.append(t) }
        return out
    }

    private var cams: [MacCameraShare.Line] {
        let door = cameras.first { $0.doorbell } ?? cameras.first { $0.name.localizedCaseInsensitiveContains("door") }
        let drive = cameras.first { $0.name.localizedCaseInsensitiveContains("drive") && $0.id != door?.id }
        var out = [door, drive].compactMap { $0 }
        for c in cameras where out.count < 2 && !out.contains(where: { $0.id == c.id }) { out.append(c) }
        return out
    }

    var body: some View {
        HStack(spacing: 9) {
            VStack(spacing: 4) {
                if tvs.isEmpty {
                    Text(entry.paired ? "No TVs answered." : "Open Woodruff to pair your TVs.")
                        .font(.caption).foregroundStyle(WidgetPalette.sky)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ForEach(tvs) { tv in row(tv) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            VStack(spacing: 6) {
                ForEach(0..<2, id: \.self) { i in
                    if i < cams.count { camera(cams[i]) } else {
                        RoundedRectangle(cornerRadius: 11, style: .continuous).fill(WidgetPalette.cyan.opacity(0.1))
                            .overlay(Text("Camera").font(.caption2).foregroundStyle(WidgetPalette.sky.opacity(0.6)))
                    }
                }
            }
            .frame(width: 140)
            .frame(maxHeight: .infinity)
        }
        .padding(11)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ tv: WidgetTV) -> some View {
        let selected = tv.id == entry.selected?.id
        let playing = tv.online ? tv.playing : nil
        return HStack(spacing: 8) {
            Group {
                if selected, playing != nil, let data = entry.art, let img = TVsProvider.image(data, pixels: 120) {
                    Image(nsImage: img).resizable().scaledToFill()
                } else {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(WidgetPalette.cyan.opacity(0.14))
                        .overlay(Image(systemName: "tv").font(.system(size: 14, weight: .semibold)).foregroundStyle(WidgetPalette.cyan))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(WidgetPalette.cyan.opacity(0.45), lineWidth: 0.75))
                }
            }
            .frame(width: 34, height: 34)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(tv.name).font(.system(size: 10, weight: .bold)).foregroundStyle(WidgetPalette.ice).lineLimit(1)
                Text(playing?.title ?? (tv.online ? "On" : "Off"))
                    .font(.system(size: 12.5, weight: selected ? .bold : .semibold, design: .rounded))
                    .foregroundStyle(WidgetPalette.frost)
                    .lineLimit(1)
                if let p = playing {
                    WidgetProgress(playing: p, at: entry.date, tint: WidgetPalette.cyan).padding(.top, 3)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4).padding(.leading, 4).padding(.trailing, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(WidgetPalette.cyan.opacity(0.13))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(WidgetPalette.cyan.opacity(0.9), lineWidth: 1))
                    .shadow(color: WidgetPalette.cyan.opacity(0.35), radius: 6)
            }
        }
    }

    private func camera(_ c: MacCameraShare.Line) -> some View {
        let fresh = c.eventAt.map { entry.date.timeIntervalSince($0) < 600 } ?? false
        return WidgetPalette.cyan.opacity(0.1)
            .overlay {
                if let data = MacCameraShare.picture(c), let image = TVsProvider.image(data, pixels: 420) {
                    Image(nsImage: image).resizable().scaledToFill()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .overlay(LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .center, endPoint: .bottom))
            .overlay(alignment: .bottom) {
                HStack(spacing: 4) {
                    Text(c.doorbell ? "Doorbell" : c.name.replacingOccurrences(of: " camera", with: "", options: .caseInsensitive)).lineLimit(1)
                    Spacer(minLength: 2)
                    if let at = c.at {
                        Text(at, style: .time).foregroundStyle(.white.opacity(0.78)).lineLimit(1).fixedSize().layoutPriority(1)
                    }
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.6), radius: 2)
                .padding(.horizontal, 6).padding(.bottom, 5)
            }
            .overlay(alignment: .topLeading) {
                if fresh, let e = c.event {
                    Text(e).font(.system(size: 9.5, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.red.opacity(0.92), in: Capsule())
                        .padding(6)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}


/// The widgets' colours, taken from the app icon: its steel-blue to deep-navy background with a soft cyan glow,
/// its glowing cyan for outlines and accents, its ice blue for labels and its white for what matters most.
enum WidgetPalette {
    static let navyTop = Color(red: 0.220, green: 0.325, blue: 0.443)      // steel
    static let navyMid = Color(red: 0.114, green: 0.200, blue: 0.314)
    static let navyBottom = Color(red: 0.031, green: 0.067, blue: 0.122)   // deep navy
    static let cyan = Color(red: 0.227, green: 0.678, blue: 0.875)         // the icon's glow
    /// Labels.
    static let sky = Color(red: 0.659, green: 0.831, blue: 0.961)          // ice
    static let ice = sky
    /// What's on, the main words.
    static let frost = Color(red: 0.976, green: 0.992, blue: 0.992)        // white core
}

/// Behind every widget: the icon's fade from steel blue to deep navy, with its cyan glow in the middle.
struct WidgetBackdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [WidgetPalette.navyTop, WidgetPalette.navyMid, WidgetPalette.navyBottom], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [WidgetPalette.cyan.opacity(0.16), .clear], center: .center, startRadius: 0, endRadius: 220)
        }
    }
}
