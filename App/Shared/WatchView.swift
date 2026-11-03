import SwiftUI
import WoodruffKit

/// Watch: the TV's Movies and TV Shows (Google Drive): Continue Watching, Recently Added, grids, search, title pages,
/// play on any TV, or watch together on every TV.
struct WatchView: View {
    @Environment(Fleet.self) private var fleet
    @State private var home: WatchHome?
    @State private var error: String?
    @State private var search = ""

    private var client: TVClient? { fleet.hubClient() }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if !search.isEmpty {
                    SearchResultsView(query: search)
                } else if let h = home {
                    content(h)
                } else if let error {
                    EmptyState(symbol: "wifi.exclamationmark", title: "Can't Load the Library", message: error)
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(40)
                }
            }
            .padding(.vertical)
        }
        .screenTitle("Watch")
        .searchable(text: $search, prompt: "Movies and TV Shows")
        .refreshable { await load() }
        .navigationDestination(for: TitleRef.self) { TitleView(id: $0.id) }
        .navigationDestination(for: LibraryRef.self) { LibraryGrid(place: $0.place) }
        .task { await loop() }
    }

    @ViewBuilder private func content(_ h: WatchHome) -> some View {
        if h.state != "ready" && (h.featured ?? []).isEmpty && (h.continue ?? []).isEmpty {
            EmptyState(symbol: "film.stack", title: stateTitle(h.state), message: stateMessage(h.state, tv: h.tv))
        }
        if let f = h.featured, let first = f.first { Billboard(title: first) }
        if let c = h.continue, !c.isEmpty {
            Shelf("Continue Watching") {
                ForEach(c) { item in ContinueTile(item: item) }
            }
        }
        if let r = h.recent, !r.isEmpty {
            Shelf("Recently Added") { ForEach(r) { PosterTile(title: $0) } }
        }
        if let m = h.movies, m.count > 0 {
            Shelf("Movies", count: m.count, all: LibraryRef(place: "movies")) { ForEach(m.items) { PosterTile(title: $0) } }
        }
        if let s = h.shows, s.count > 0 {
            Shelf("TV Shows", count: s.count, all: LibraryRef(place: "shows")) { ForEach(s.items) { PosterTile(title: $0) } }
        }
    }

    private func load() async {
        guard let c = client else { return }
        do { home = try await c.watchHome(); error = nil } catch { if home == nil { self.error = error.localizedDescription } }
    }

    private func loop() async {
        while !Task.isCancelled {
            await load()
            try? await Task.sleep(nanoseconds: home?.state == "loading" ? 3_000_000_000 : 60_000_000_000)
        }
    }

    private func stateTitle(_ s: String) -> String {
        switch s {
        case "loading": return "Loading the Library…"
        case "empty": return "Nothing Here Yet"
        case "offline", "unreachable": return "Can't Reach Google Drive"
        case "expired", "expiredEmpty": return "Google Drive's Sign-In Ended"
        case "notSignedIn": return "Not Signed In"
        case "notSetUp", "keysRejected": return "Google Drive Isn't Set Up"
        default: return "Library"
        }
    }
    private func stateMessage(_ s: String, tv: String?) -> String {
        let t = tv ?? "the TV"
        switch s {
        case "empty": return "Make folders named Movies and TV Shows in Google Drive."
        case "expired", "expiredEmpty", "notSignedIn": return "Sign \(t) in again from its page under TVs."
        case "notSetUp", "keysRejected": return "Add the Google Drive keys in Settings → Connections."
        default: return "\(t) is getting the library ready."
        }
    }
}

struct TitleRef: Hashable { var id: String }
struct LibraryRef: Hashable { var place: String }

/// A horizontal row of tiles with a heading.
struct Shelf<Content: View>: View {
    var title: String
    var count: Int?
    var all: LibraryRef?
    @ViewBuilder var content: Content
    init(_ title: String, count: Int? = nil, all: LibraryRef? = nil, @ViewBuilder content: () -> Content) {
        self.title = title; self.count = count; self.all = all; self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.title3.bold())
                Spacer()
                if let all { NavigationLink(value: all) { Text("See All" + (count.map { " (\($0))" } ?? "")) } }
            }
            .padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) { content }.padding(.horizontal)
            }
        }
    }
}

/// The featured title, big, with Play.
struct Billboard: View {
    @Environment(Fleet.self) private var fleet
    var title: Title
    var body: some View {
        NavigationLink(value: TitleRef(id: title.id)) {
            ZStack(alignment: .bottomLeading) {
                Color.clear.aspectRatio(16 / 9, contentMode: .fit)
                    .overlay { TVImage(url: fleet.hubClient()?.art(title.backdrop)) }
                    .clipped()
                LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .center, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 6) {
                    Text(title.title).font(.title.bold()).foregroundStyle(.white)
                    if let c = title.caption { Text(c).font(.subheadline).foregroundStyle(.white.opacity(0.85)) }
                    if let p = title.play { PlayButton(action: p, title: title, label: p.label ?? "Play") }
                }
                .padding()
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.horizontal)
            .frame(maxWidth: 900)
        }
        .buttonStyle(.plain)
    }
}

struct PosterTile: View {
    @Environment(Fleet.self) private var fleet
    var title: Title
    var width: CGFloat = 120
    var body: some View {
        NavigationLink(value: TitleRef(id: title.id)) {
            VStack(alignment: .leading, spacing: 4) {
                Color.clear.frame(width: width, height: width * 1.5)
                    .overlay { TVImage(url: fleet.hubClient()?.art(title.poster)) }
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(alignment: .topTrailing) {
                        if title.watched == true { Image(systemName: "checkmark.circle.fill").foregroundStyle(.white, .green).padding(5) }
                    }
                Text(title.title).font(.caption).lineLimit(1).frame(width: width, alignment: .leading)
                if let c = title.caption { Text(c).font(.caption2).foregroundStyle(.tint).lineLimit(1) }
                else if let y = title.year { Text(String(y)).font(.caption2).foregroundStyle(.secondary) }
            }
        }
        .buttonStyle(.plain)
        .contextMenu { TitleMenu(title: title) }
    }
}

struct ContinueTile: View {
    @Environment(Fleet.self) private var fleet
    var item: ContinueItem
    var body: some View {
        Button { PlayRouter.start(item.play, fleet: fleet) } label: {
            VStack(alignment: .leading, spacing: 4) {
                Color.clear.frame(width: 120, height: 180)
                    .overlay { TVImage(url: fleet.hubClient()?.art(item.poster)) }
                    .overlay(alignment: .bottom) { ProgressView(value: item.progress).tint(.white).padding(6) }
                    .overlay { Image(systemName: "play.circle.fill").font(.largeTitle).foregroundStyle(.white.opacity(0.9)).shadow(radius: 4) }
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                Text(item.name).font(.caption).lineLimit(1).frame(width: 120, alignment: .leading)
                Text([item.upNext == true ? "Next" : nil, item.code].compactMap { $0 }.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(item.play.label ?? "Play") { PlayRouter.start(item.play, fleet: fleet) }
            if let r = item.restart { Button(r.label ?? "Start Over") { PlayRouter.start(r, fleet: fleet, fromStart: true) } }
            PlayOnMenu(action: item.play)
            if let id = item.titleId { NavigationLink(item.kind == "show" ? "Episodes" : "Details", value: TitleRef(id: id)) }
            Button("Mark as Watched") { act { try await fleet.hubClient()?.markWatched([item.key], true) } }
            Button("Remove from Continue Watching", role: .destructive) { act { try await fleet.hubClient()?.removeContinue(key: item.key, title: item.playTitle) } }
        }
    }
    private func act(_ op: @escaping () async throws -> Void) { Task { do { try await op() } catch { fleet.show(error) } } }
}

/// Long-press menu on a poster.
struct TitleMenu: View {
    @Environment(Fleet.self) private var fleet
    var title: Title
    var body: some View {
        if let p = title.play {
            Button(p.label ?? "Play") { PlayRouter.start(p, fleet: fleet) }
            if (p.position ?? 0) > 0 { Button("Start Over") { PlayRouter.start(p, fleet: fleet, fromStart: true) } }
            PlayOnMenu(action: p)
        }
        if !title.isShow {
            let on = !(title.watched ?? false)
            Button(on ? "Mark as Watched" : "Mark as Unwatched") {
                Task {
                    do {
                        let d = try await fleet.hubClient()?.title(title.id)
                        if let k = d?.watchKey { try await fleet.hubClient()?.markWatched([k], on) }
                    } catch { fleet.show(error) }
                }
            }
        }
    }
}

/// "Play On…": any TV, or every TV together (Drive videos).
struct PlayOnMenu: View {
    @Environment(Fleet.self) private var fleet
    var action: PlayAction
    var fromStart = false
    var body: some View {
        if fleet.tvs.count > 1 {
            Menu("Play On…") {
                ForEach(fleet.tvs) { tv in
                    Button("\(tv.name)\(tv.online ? "" : " (off)")") { PlayRouter.start(action, fleet: fleet, on: tv, fromStart: fromStart) }
                        .disabled(!tv.online || tv.link == "refused" || (!action.isDrive && fleet.hubClient()?.hub.id != tv.id))
                }
            }
            if action.isDrive {
                Button { PlayRouter.together(action, fleet: fleet) } label: { Label("Watch Together on All TVs", systemImage: "tv.and.mediabox") }
            }
        }
    }
}

struct PlayButton: View {
    @Environment(Fleet.self) private var fleet
    var action: PlayAction
    var title: Title?
    var label: String
    var fromStart = false
    var body: some View {
        Button { PlayRouter.start(action, fleet: fleet, fromStart: fromStart) } label: {
            Label(label, systemImage: "play.fill").frame(minWidth: 120)
        }
        .buttonStyle(.borderedProminent)
    }
}

/// Where a Play goes: the remote's TV (through the hub that holds the library), as the phone page routes it.
@MainActor
enum PlayRouter {
    static func start(_ a: PlayAction, fleet: Fleet, on tv: FleetTV? = nil, fromStart: Bool = false) {
        guard let c = fleet.hubClient(), let target = tv ?? fleet.selected else { return }
        let id: String = (target.id == c.hub.id) ? "this" : target.id
        Task {
            do {
                let r = try await c.start(a, on: id, fromStart: fromStart)
                if r.started?.bool == false { fleet.say("Ready on \(target.name)", r.message ?? "Open Woodruff on \(target.name) to start it.") }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await fleet.refresh()
            } catch { fleet.show(error) }
        }
    }

    static func together(_ a: PlayAction, fleet: Fleet) {
        guard let c = fleet.hubClient() else { return }
        Task {
            do {
                let r = try await c.start(a, on: "all")
                let n = r.started?.int ?? 0, of = r.of ?? n
                fleet.say("Watching together", n == of ? "Playing on \(n) TVs." : "Playing on \(n) of \(of) TVs." + ((r.failed ?? []).isEmpty ? "" : " Not on: " + r.failed!.joined(separator: ", ")))
            } catch { fleet.show(error) }
        }
    }
}

/// A film's or show's page: overview, Play, seasons and episodes, collections.
struct TitleView: View {
    @Environment(Fleet.self) private var fleet
    var id: String
    @State private var d: TitleDetails?
    @State private var season = 0
    @State private var episodes: [Episode] = []
    @State private var loadingEpisodes = false

    private var client: TVClient? { fleet.hubClient() }

    var body: some View {
        ScrollView {
            if let d {
                VStack(alignment: .leading, spacing: 14) {
                    Color.clear.aspectRatio(16 / 9, contentMode: .fit)
                        .overlay { TVImage(url: client?.art(d.backdrop ?? d.poster)) }
                        .clipped()
                    VStack(alignment: .leading, spacing: 10) {
                        Text(d.title).font(.largeTitle.bold())
                        Text(facts(d)).font(.subheadline).foregroundStyle(.secondary)
                        HStack {
                            if let p = d.play { PlayButton(action: p, label: p.label ?? "Play") }
                            if let r = d.restart { Button(r.label ?? "Start Over") { PlayRouter.start(r, fleet: fleet, fromStart: true) }.buttonStyle(.bordered) }
                            if let p = d.play { Menu { PlayOnMenu(action: p) } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize() }
                        }
                        if let name = d.playName { Text(name).font(.headline) }
                        if let o = d.overview { Text(o).font(.body) }
                        if let cast = d.cast, !cast.isEmpty { Text("Starring " + cast.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary) }
                        if let key = d.watchKey {
                            Button(d.watched == true ? "Mark as Unwatched" : "Mark as Watched") {
                                Task { do { try await client?.markWatched([key], !(d.watched ?? false)); await load() } catch { fleet.show(error) } }
                            }
                        }
                    }
                    .padding(.horizontal)
                    if let seasons = d.seasons, !seasons.isEmpty {
                        Picker("Season", selection: $season) {
                            ForEach(Array(seasons.enumerated()), id: \.offset) { i, s in Text(s.name).tag(i) }
                        }
                        .pickerStyle(.menu)
                        .padding(.horizontal)
                        if loadingEpisodes { ProgressView().frame(maxWidth: .infinity) }
                        ForEach(episodes) { e in EpisodeRow(episode: e, showId: d.id, folder: seasons[safe: season]?.id) { Task { await loadEpisodes() } } }
                    }
                    if let films = d.films {
                        Text("In This Collection").font(.title3.bold()).padding(.horizontal)
                        ForEach(films) { e in EpisodeRow(episode: e, showId: nil, folder: d.id) { Task { await load() } } }
                    }
                }
            } else {
                ProgressView().padding(40)
            }
        }
        .navigationTitle(d?.title ?? "")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await load() }
        .onChange(of: season) { _, _ in Task { await loadEpisodes() } }
    }

    private func facts(_ d: TitleDetails) -> String {
        var f: [String] = []
        if let y = d.year { f.append(String(y)) }
        if let m = d.playMinutes ?? d.runtime {
            f.append("\(Int(m)) min")
            f.append("Ends at " + Date().addingTimeInterval(m * 60 - (d.play?.position ?? 0) / 1000).formatted(date: .omitted, time: .shortened))
        }
        if let a = d.ageRating { f.append(a) }
        if let g = d.genres, !g.isEmpty { f.append(g.prefix(2).joined(separator: ", ")) }
        if let r = d.rating { f.append(String(format: "★ %.1f", r)) }
        return f.joined(separator: " · ")
    }

    private func load() async {
        do {
            d = try await client?.title(id)
            season = d?.season ?? 0
            await loadEpisodes()
        } catch { fleet.show(error) }
    }

    private func loadEpisodes() async {
        guard let d, let s = d.seasons?[safe: season] else { return }
        loadingEpisodes = true
        defer { loadingEpisodes = false }
        do { episodes = try await client?.episodes(show: d.id, season: s.id).episodes ?? [] } catch { fleet.show(error) }
    }
}

struct EpisodeRow: View {
    @Environment(Fleet.self) private var fleet
    var episode: Episode
    var showId: String?
    var folder: String?
    var changed: () -> Void

    private var action: PlayAction { PlayAction(key: episode.key, title: episode.playTitle, position: episode.position, label: nil, duration: episode.duration, resume: true, latest: nil) }

    var body: some View {
        Button { PlayRouter.start(action, fleet: fleet) } label: {
            HStack(alignment: .top, spacing: 12) {
                Color.clear.frame(width: 140, height: 79)
                    .overlay { TVImage(url: fleet.hubClient()?.art(episode.still, small: true)) }
                    .overlay(alignment: .bottom) { if episode.progress > 0 { ProgressView(value: episode.progress).padding(4) } }
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text([episode.code, episode.name].compactMap { $0 }.joined(separator: " · ")).font(.subheadline.weight(.semibold)).lineLimit(2)
                        if episode.watched == true { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                        if episode.new == true { Text("NEW").font(.caption2.bold()).foregroundStyle(.tint) }
                    }
                    if let o = episode.overview { Text(o).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                    if let r = episode.runtime { Text("\(Int(r)) min").font(.caption2).foregroundStyle(.tertiary) }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Play from the Start") { PlayRouter.start(action, fleet: fleet, fromStart: true) }
            PlayOnMenu(action: action)
            Button(episode.watched == true ? "Mark as Unwatched" : "Mark as Watched") {
                Task { do { try await fleet.hubClient()?.markWatched([episode.key], !(episode.watched ?? false)); changed() } catch { fleet.show(error) } }
            }
        }
    }
}

/// All Movies or TV Shows, sorted and filtered, loaded page by page.
struct LibraryGrid: View {
    @Environment(Fleet.self) private var fleet
    var place: String
    @State private var items: [Title] = []
    @State private var count = 0
    @State private var genres: [String] = []
    @State private var rated = false
    @State private var sort = "az"
    @State private var unwatched = false
    @State private var genre: String?
    @State private var query = ""
    @State private var loading = false

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 12)], spacing: 16) {
                ForEach(items) { t in
                    PosterTile(title: t, width: 110).onAppear { if t.id == items.last?.id && items.count < count { Task { await load(more: true) } } }
                }
            }
            .padding()
            if loading { ProgressView() }
        }
        .navigationTitle(place == "shows" ? "TV Shows" : "Movies")
        .searchable(text: $query)
        .toolbar {
            Menu {
                Picker("Show", selection: $unwatched) { Text("All").tag(false); Text("Unwatched").tag(true) }
                Picker("Sort", selection: $sort) {
                    Text("A–Z").tag("az"); Text("Recently Added").tag("recent"); Text("Newest").tag("newest")
                    if rated { Text("Top Rated").tag("rated") }
                }
                Picker("Genre", selection: $genre) {
                    Text("All Genres").tag(String?.none)
                    ForEach(genres, id: \.self) { Text($0).tag(String?.some($0)) }
                }
            } label: { Label("Filter", systemImage: "line.3.horizontal.decrease.circle") }
        }
        .task(id: "\(sort)|\(unwatched)|\(genre ?? "")|\(query)") {
            try? await Task.sleep(nanoseconds: 200_000_000)
            await load(more: false)
        }
    }

    private func load(more: Bool) async {
        guard let c = fleet.hubClient(), !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let p = try await c.library(place: place, sort: sort, unwatched: unwatched, genre: genre, q: query, offset: more ? items.count : 0)
            items = more ? items + p.items : p.items
            count = p.count
            genres = p.genres ?? genres
            rated = p.rated ?? rated
        } catch { fleet.show(error) }
    }
}

struct SearchResultsView: View {
    @Environment(Fleet.self) private var fleet
    var query: String
    @State private var r: SearchResults?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let r {
                let sections = r.first == "shows" ? [("TV Shows", r.shows), ("Movies", r.movies)] : [("Movies", r.movies), ("TV Shows", r.shows)]
                ForEach(sections, id: \.0) { name, list in
                    if !list.isEmpty { Shelf(name) { ForEach(list) { PosterTile(title: $0) } } }
                }
                if r.movies.isEmpty && r.shows.isEmpty { EmptyState(symbol: "magnifyingglass", title: "No Results", message: "Nothing in Movies or TV Shows matches “\(query)”.") }
            } else { ProgressView().frame(maxWidth: .infinity) }
        }
        .task(id: query) {
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            r = try? await fleet.hubClient()?.search(query)
        }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
