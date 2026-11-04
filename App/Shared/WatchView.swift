import SwiftUI
import WoodruffKit

/// Watch: Movies and TV Shows from the TV's Google Drive, laid out like the Apple TV app: a featured billboard,
/// Continue Watching, Recently Added, Movies and TV Shows. Plays on the remote's TV, any TV, or all of them.
struct WatchView: View {
    @Environment(Fleet.self) private var fleet
    @Namespace private var zoom
    @State private var home: WatchHome?
    @State private var error: String?
    @State private var page = 0
    @State private var openTitle: String?
    /// The hub whose library is shown (the remote's TV picks it).
    @State private var loadedHub: String?
    /// Taken off Continue Watching here, hidden until the TV's next answer (which no longer has them).
    @State private var removed: Set<String> = []

    private var client: TVClient? { fleet.hubClient() }

    /// What every TV is playing, and whether it plays: when it changes, Continue Watching has changed too.
    private var playingKey: String {
        fleet.tvs.map { "\($0.id)|\($0.playing?.key ?? $0.playing?.title ?? "")|\($0.playing?.isPlaying == true)" }.joined(separator: ";")
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                if let h = home {
                    content(h)
                } else if let error {
                    VStack(spacing: 14) {
                        EmptyState(symbol: "wifi.exclamationmark", title: "Can’t Load the Library", message: error)
                        ActionButton(action: { await load() }) { Text("Try Again") }
                            .buttonStyle(.glass)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 80)
                } else {
                    WatchPlaceholder()
                }
            }
            .padding(.bottom, 30)
        }
        .scrollIndicators(.hidden)
        #if os(iOS)
        // The billboard runs under the top bar, edge to edge, like the Apple TV app.
        .ignoresSafeArea(edges: .top)
        #endif
        #if os(iOS)
        .toolbar {
            ToolbarItem(placement: .principal) { TVPicker() }.sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .primaryAction) {
                NavigationLink { SearchPage() } label: { Image(systemName: "magnifyingglass") }
            }
        }
        #else
        // The window's own bar has the search; the TV that plays is picked at the top of the page.
        .macPageBar { TVPicker() }
        #endif
        .inlineTitle()
        #if os(macOS)
        .navigationTitle("Watch")
        #endif
        .navigationDestination(for: LibraryRef.self) { LibraryGrid(place: $0.place) }
        .sheet(item: Binding(get: { openTitle.map { TitleRef(id: $0) } }, set: { openTitle = $0?.id })) { ref in
            TitleSheet(id: ref.id).zoomDestination(ref.id, zoom).macResizable(width: 760, height: 820, minWidth: 520, minHeight: 500)
        }
        .environment(\.openTitle, OpenTitleAction { openTitle = $0 })
        .environment(\.zoomNamespace, zoom)
        // Marked watched or taken off Continue Watching anywhere in Watch: gone at once, then asked again.
        .environment(\.watchChanged, WatchChanged { key in
            if let key { withAnimation(.smooth) { _ = removed.insert(key) } }
            Task { await load() }
        })
        .refreshable { await load() }
        // Again from the start when the remote moves to a TV with another library.
        .task(id: client?.hub.id) { await loop() }
        // Something started, paused or stopped on a TV: Continue Watching follows (the TV saves where it got to).
        .task(id: playingKey) {
            guard home != nil else { return }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            await load()
        }
        .onAppear { if UserDefaults.standard.string(forKey: "route") == "title" { openTitle = "t_backyard_science" } }
    }

    @ViewBuilder private func content(_ h: WatchHome) -> some View {
        if h.state != "ready" && (h.featured ?? []).isEmpty && (h.continue ?? []).isEmpty {
            EmptyState(symbol: "film.stack", title: stateTitle(h.state), message: stateMessage(h.state, tv: h.tv)).padding(.top, 60)
        }
        if let featured = h.featured, !featured.isEmpty {
            Billboard(titles: featured, page: $page)
        }
        if let c = h.continue?.filter({ !removed.contains($0.key) }), !c.isEmpty {
            ShelfRow("Continue Watching") { ForEach(c) { ContinueTile(item: $0) } }
        }
        if let r = h.recent, !r.isEmpty {
            ShelfRow("Recently Added") { ForEach(r) { PosterTile(title: $0) } }
        }
        if let m = h.movies, m.count > 0 {
            ShelfRow("Movies", all: LibraryRef(place: "movies")) { ForEach(m.items) { PosterTile(title: $0) } }
        }
        if let s = h.shows, s.count > 0 {
            ShelfRow("TV Shows", all: LibraryRef(place: "shows")) { ForEach(s.items) { PosterTile(title: $0) } }
        }
    }

    private func load() async {
        guard let c = client else { error = TVError.notPaired.localizedDescription; return }
        let hubID = c.hub.id
        do {
            let h = try await c.watchHome()
            // The remote moved to a TV with another library meanwhile: this answer is for the old one.
            guard client?.hub.id == hubID else { return }
            withAnimation(.smooth) {
                home = h
                removed = []
            }
            loadedHub = hubID
            error = nil
        } catch {
            if Task.isCancelled { return }
            // A library already shown stays (a blink in the Wi‑Fi isn't worth an empty page); another TV's doesn't.
            if home == nil || loadedHub != hubID {
                home = nil
                self.error = error.localizedDescription
            }
        }
    }

    private func loop() async {
        while !Task.isCancelled {
            await load()
            try? await Task.sleep(nanoseconds: home?.state == "loading" ? 3_000_000_000 : 60_000_000_000)
        }
    }

    private func stateTitle(_ s: String) -> String {
        switch s {
        case "loading": return "Getting the Library Ready"
        case "empty": return "Nothing Here Yet"
        case "offline", "unreachable": return "Can’t Reach Google Drive"
        case "expired", "expiredEmpty": return "Google Drive’s Sign-In Ended"
        case "notSignedIn": return "Not Signed In"
        default: return "Set Up Google Drive"
        }
    }
    private func stateMessage(_ s: String, tv: String?) -> String {
        let t = tv ?? "the TV"
        switch s {
        case "empty": return "Make folders named Movies and TV Shows in Google Drive."
        case "expired", "expiredEmpty", "notSignedIn": return "Sign \(t) in again from Settings → TVs → \(t)."
        case "loading": return "\(t) is reading Movies and TV Shows."
        default: return "Add the Google Drive keys in Settings → Connections."
        }
    }
}

struct TitleRef: Hashable, Identifiable { var id: String }
struct LibraryRef: Hashable { var place: String }

/// Opens a title's sheet from anywhere in Watch.
struct OpenTitleAction { var open: (String) -> Void; func callAsFunction(_ id: String) { open(id) } }
private struct OpenTitleKey: EnvironmentKey { static let defaultValue = OpenTitleAction { _ in } }

/// Tells Watch the library changed here (marked watched, taken off Continue Watching), so it shows at once
/// instead of on its next round. [removed] is a Continue Watching key to hide straight away.
struct WatchChanged { var changed: (String?) -> Void; func callAsFunction(removed: String? = nil) { changed(removed) } }
private struct WatchChangedKey: EnvironmentKey { static let defaultValue = WatchChanged { _ in } }

extension EnvironmentValues {
    var openTitle: OpenTitleAction {
        get { self[OpenTitleKey.self] }
        set { self[OpenTitleKey.self] = newValue }
    }
    var watchChanged: WatchChanged {
        get { self[WatchChangedKey.self] }
        set { self[WatchChangedKey.self] = newValue }
    }
}

/// The featured titles, one card at a time, swiping.
struct Billboard: View {
    @Environment(Fleet.self) private var fleet
    @Environment(\.openTitle) private var openTitle
    var titles: [Title]
    @Binding var page: Int

    var body: some View {
        pages
            .frame(maxWidth: .infinity)
            .overlay(alignment: .bottomTrailing) { dots }
            // A shorter list after a refresh: never a page that isn't there.
            .onChange(of: titles.count) { _, n in if page >= n { page = 0 } }
    }

    #if os(iOS)
    private var pages: some View {
        TabView(selection: $page) {
            ForEach(Array(titles.enumerated()), id: \.offset) { i, t in card(t).tag(i) }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .aspectRatio(0.82, contentMode: .fit)
    }
    #else
    /// The Mac has no swiping pages (a plain TabView there is a strip of blank tabs): one card at a time that moves
    /// on by itself; the dots pick one.
    private var pages: some View {
        ZStack {
            if let t = titles[safe: page] ?? titles.first {
                card(t).id(t.id).transition(.opacity)
            }
        }
        .aspectRatio(2.2, contentMode: .fit)
        .clipped()
        .task(id: page) {
            try? await Task.sleep(nanoseconds: 9_000_000_000)
            guard !Task.isCancelled, titles.count > 1 else { return }
            withAnimation(.smooth(duration: 0.6)) { page = (page + 1) % titles.count }
        }
    }
    #endif

    private var dots: some View {
        HStack(spacing: 5) {
            ForEach(titles.indices, id: \.self) { i in
                #if os(macOS)
                Button { withAnimation(.smooth(duration: 0.4)) { page = i } } label: {
                    Circle().fill(.white.opacity(i == page ? 0.95 : 0.4)).frame(width: 7, height: 7)
                        .padding(3).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(titles[i].title)
                #else
                Circle().fill(.white.opacity(i == page ? 0.95 : 0.4)).frame(width: 6, height: 6)
                #endif
            }
        }
        .padding(.trailing, 24).padding(.bottom, 34)
        .animation(.snappy, value: page)
    }

    private func card(_ t: Title) -> some View {
        ZStack(alignment: .bottomLeading) {
            Color.clear.overlay { Artwork(url: fleet.hubClient()?.art(t.backdrop ?? t.poster)) }.clipped()
            // Fades into the page, so the billboard has no edge.
            LinearGradient(stops: [.init(color: .black.opacity(0.35), location: 0), .init(color: .clear, location: 0.25),
                                   .init(color: .clear, location: 0.42), .init(color: .black.opacity(0.82), location: 0.9),
                                   .init(color: Palette.groupedBackground, location: 1)],
                           startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 6) {
                Text(t.title).font(.largeTitle.bold()).foregroundStyle(.white).lineLimit(2).shadow(color: .black.opacity(0.4), radius: 8)
                Text(meta(t)).font(.footnote.weight(.medium)).foregroundStyle(.white.opacity(0.75))
                HStack(spacing: 10) {
                    if let p = t.play {
                        CapsuleButton(title: p.label ?? "Play", symbol: "play.fill") { PlayRouter.start(p, fleet: fleet) }
                    }
                    CapsuleButton(title: "Details", symbol: nil, prominent: false) { openTitle(t.id) }
                }
                .padding(.top, 6)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .contentShape(Rectangle())
        .onTapGesture { openTitle(t.id) }
        .contextMenu { TitleMenu(title: t) }
    }

    private func meta(_ t: Title) -> String {
        var m: [String] = []
        if let y = t.year { m.append(String(y)) }
        if let g = t.genres, !g.isEmpty { m.append(g.prefix(2).joined(separator: ", ")) }
        if let r = t.rating { m.append(String(format: "★ %.1f", r)) }
        return m.joined(separator: " · ")
    }
}

/// A heading and a row of tiles that scrolls sideways.
struct ShelfRow<Content: View>: View {
    var title: String
    var all: LibraryRef?
    @ViewBuilder var content: Content
    init(_ title: String, all: LibraryRef? = nil, @ViewBuilder content: () -> Content) {
        self.title = title; self.all = all; self.content = content()
    }
    /// The shelf's name, with a chevron when it opens everything in it.
    private var heading: some View {
        HStack(spacing: 4) {
            Text(title).font(.title2.bold())
            Image(systemName: "chevron.right").font(.headline.weight(.bold)).foregroundStyle(.secondary)
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Group {
                if let all {
                    #if os(macOS)
                    // On the Mac's own page stack, so Woodruff's Back button returns from it.
                    PageLink(title) { LibraryGrid(place: all.place) } label: { heading }
                        .buttonStyle(.plain)
                    #else
                    NavigationLink(value: all) { heading }
                        .buttonStyle(.plain)
                    #endif
                } else {
                    Text(title).font(.title2.bold())
                }
            }
            .padding(.horizontal, 20)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 10) { content }
                    .scrollTargetLayout()
                    .padding(.horizontal, 20)
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.viewAligned)
        }
    }
}

struct PosterTile: View {
    @Environment(Fleet.self) private var fleet
    @Environment(\.openTitle) private var openTitle
    @Environment(\.zoomNamespace) private var zoom
    var title: Title
    var width: CGFloat = 112

    var body: some View {
        Button { openTitle(title.id) } label: {
            VStack(alignment: .leading, spacing: 6) {
                Color.clear.frame(width: width, height: width * 1.5)
                    .overlay { Artwork(url: fleet.hubClient()?.art(title.poster)) }
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .zoomSource(title.id, zoom)
                    .overlay(alignment: .topTrailing) {
                        if title.watched == true {
                            Image(systemName: "checkmark.circle.fill").symbolRenderingMode(.palette).foregroundStyle(.white, .black.opacity(0.5)).padding(6)
                        }
                    }
                    .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title.title).font(.footnote.weight(.semibold)).lineLimit(1)
                    Text(title.caption ?? title.year.map(String.init) ?? " ")
                        .font(.caption).foregroundStyle(title.caption != nil ? Color.accentColor : .secondary).lineLimit(1)
                }
                .frame(width: width, alignment: .leading)
            }
        }
        .buttonStyle(PressScale(scale: 0.96))
        #if os(macOS)
        .hoverTilt(cornerRadius: 12)
        #endif
        .contextMenu { TitleMenu(title: title) }
    }
}

struct ContinueTile: View {
    @Environment(Fleet.self) private var fleet
    @Environment(\.openTitle) private var openTitle
    @Environment(\.watchChanged) private var watchChanged
    var item: ContinueItem

    var body: some View {
        Button { PlayRouter.start(item.play, fleet: fleet) } label: {
            VStack(alignment: .leading, spacing: 6) {
                Color.clear.frame(width: 112, height: 168)
                    .overlay { Artwork(url: fleet.hubClient()?.art(item.poster)) }
                    .overlay(alignment: .bottom) {
                        VStack(spacing: 8) {
                            Image(systemName: "play.fill").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                                .frame(width: 32, height: 32).glass(Circle(), interactive: false).environment(\.colorScheme, .dark)
                            if item.progress > 0 {
                                Capsule().fill(.white.opacity(0.3)).frame(height: 4)
                                    .overlay(alignment: .leading) { Capsule().fill(.white).frame(width: 96 * item.progress) }
                                    .frame(width: 96)
                            }
                        }
                        .padding(.bottom, 10)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name).font(.footnote.weight(.semibold)).lineLimit(1)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(width: 112, alignment: .leading)
            }
        }
        .buttonStyle(PressScale(scale: 0.96))
        .contextMenu {
            Button { PlayRouter.start(item.play, fleet: fleet) } label: { Label(item.play.label ?? "Play", systemImage: "play.fill") }
            if let r = item.restart { Button { PlayRouter.start(r, fleet: fleet, fromStart: true) } label: { Label(r.label ?? "Start Over", systemImage: "arrow.counterclockwise") } }
            PlayOnMenu(action: item.play)
            if let id = item.titleId { Button { openTitle(id) } label: { Label(item.kind == "show" ? "Episodes" : "Details", systemImage: "info.circle") } }
            Button {
                act {
                    guard let c = fleet.hubClient() else { throw TVError.notPaired }
                    try await c.markWatched([item.key], true)
                    watchChanged(removed: item.key)
                }
            } label: { Label("Mark as Watched", systemImage: "checkmark.circle") }
            Button(role: .destructive) {
                act {
                    guard let c = fleet.hubClient() else { throw TVError.notPaired }
                    try await c.removeContinue(key: item.key, title: item.playTitle)
                    watchChanged(removed: item.key)
                }
            } label: { Label("Remove from Continue Watching", systemImage: "xmark.circle") }
        }
    }

    private var subtitle: String {
        if item.upNext == true { return "Next · " + (item.code ?? "") }
        let left = timeLeft(position: item.position, duration: item.duration) ?? ""
        return [item.code, left].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
    }

    private func act(_ op: @escaping () async throws -> Void) { Task { do { try await op() } catch { fleet.show(error) } } }
}

/// The long-press menu on a poster.
struct TitleMenu: View {
    @Environment(Fleet.self) private var fleet
    @Environment(\.watchChanged) private var watchChanged
    var title: Title
    var body: some View {
        if let p = title.play {
            Button { PlayRouter.start(p, fleet: fleet) } label: { Label(p.label ?? "Play", systemImage: "play.fill") }
            if (p.position ?? 0) > 0 { Button { PlayRouter.start(p, fleet: fleet, fromStart: true) } label: { Label("Start Over", systemImage: "arrow.counterclockwise") } }
            PlayOnMenu(action: p)
        }
        if !title.isShow {
            let on = !(title.watched ?? false)
            Button {
                Task {
                    do {
                        guard let c = fleet.hubClient() else { throw TVError.notPaired }
                        guard let k = try await c.title(title.id).watchKey else {
                            throw TVError.badAnswer("\(title.title) can’t be marked as watched from here.")
                        }
                        try await c.markWatched([k], on)
                        watchChanged()
                    } catch { fleet.show(error) }
                }
            } label: { Label(on ? "Mark as Watched" : "Mark as Unwatched", systemImage: on ? "checkmark.circle" : "circle") }
        }
    }
}

/// "Play On…" any TV, or every TV together (Drive videos). [then] runs once a play has gone out (a sheet closes).
struct PlayOnMenu: View {
    @Environment(Fleet.self) private var fleet
    var action: PlayAction
    var fromStart = false
    var then: () -> Void = {}
    var body: some View {
        // Paired and linked TVs only (one heard on the Wi‑Fi but not paired can't be asked to play).
        let tvs = fleet.tvs.filter { !$0.isUnpaired }
        if tvs.count > 1 {
            Menu {
                ForEach(tvs) { tv in
                    Button { if PlayRouter.start(action, fleet: fleet, on: tv, fromStart: fromStart) { then() } } label: {
                        Text(tv.name); Text(statusWord(tv))
                    }
                    .disabled(!tv.online || tv.link == "refused" || (!action.isDrive && fleet.hubClient()?.hub.id != tv.id))
                }
                if action.isDrive {
                    Divider()
                    Button { if PlayRouter.together(action, fleet: fleet) { then() } } label: { Label("Watch Together on All TVs", systemImage: "tv.and.mediabox") }
                }
            } label: { Label("Play On…", systemImage: "tv") }
        }
    }
}

/// Where a Play goes: the remote's TV (through the hub that holds the library), as the phone page routes it.
@MainActor
enum PlayRouter {
    /// Starts [a] on [tv] (the remote's TV when nil). False when there's nowhere to play it (and says so).
    @discardableResult
    static func start(_ a: PlayAction, fleet: Fleet, on tv: FleetTV? = nil, fromStart: Bool = false) -> Bool {
        guard let c = fleet.hubClient(), let target = tv ?? fleet.selected, !target.isUnpaired else {
            fleet.show(TVError.notPaired)
            return false
        }
        let id = target.id == c.hub.id ? "this" : target.id
        let name = target.name
        Task {
            do {
                // The client tells the fleet, which asks the TV again at once and a moment later.
                let r = try await c.start(a, on: id, fromStart: fromStart)
                if r.started?.bool == false { fleet.say("Ready on \(name)", r.message ?? "Open Woodruff on \(name) to start it.") }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await fleet.refresh()
            } catch { fleet.show(error) }
        }
        return true
    }

    @discardableResult
    static func together(_ a: PlayAction, fleet: Fleet) -> Bool {
        guard let c = fleet.hubClient() else {
            fleet.show(TVError.notPaired)
            return false
        }
        Task {
            do {
                let r = try await c.start(a, on: "all")
                let n = r.started?.int ?? 0
                let of = r.of ?? n
                let missed = r.failed ?? []
                var words = n == of ? "Playing on \(n) TVs." : "Playing on \(n) of \(of) TVs."
                if !missed.isEmpty { words += " Not on " + missed.joined(separator: ", ") + "." }
                fleet.say("Watching Together", words)
            } catch { fleet.show(error) }
        }
        return true
    }
}

/// A film's or show's page, as a sheet: backdrop, Play, the story, seasons and episodes.
struct TitleSheet: View {
    @Environment(Fleet.self) private var fleet
    @Environment(\.dismiss) private var dismiss
    @Environment(\.watchChanged) private var watchChanged
    var id: String
    @State private var d: TitleDetails?
    @State private var season = 0
    @State private var episodes: [Episode] = []
    @State private var loadingEpisodes = false
    /// The season the episodes shown belong to.
    @State private var episodesSeason: String?
    @State private var episodesNote: String?
    /// Why the title couldn't be read (with Try Again, instead of a spinner that never ends).
    @State private var failed: String?
    @State private var marking = false

    private var client: TVClient? { fleet.hubClient() }

    var body: some View {
        NavigationStack {
            ScrollView {
                if let d {
                    VStack(alignment: .leading, spacing: 0) {
                        header(d)
                        VStack(alignment: .leading, spacing: 14) {
                            if let o = d.overview { Text(o).font(.body).foregroundStyle(.primary.opacity(0.9)) }
                            if let cast = d.cast, !cast.isEmpty { Text("Starring " + cast.joined(separator: ", ")).font(.footnote).foregroundStyle(.secondary) }
                            if let key = d.watchKey, d.kind != "show" {
                                Button { mark(key, watched: !(d.watched ?? false)) } label: {
                                    HStack(spacing: 8) {
                                        Text(d.watched == true ? "Mark as Unwatched" : "Mark as Watched")
                                        if marking { ProgressView().controlSize(.small) }
                                    }
                                }
                                .buttonStyle(.glass)
                                .disabled(marking)
                            }
                            if let seasons = d.seasons, !seasons.isEmpty {
                                Menu {
                                    Picker("Season", selection: $season) {
                                        ForEach(Array(seasons.enumerated()), id: \.offset) { i, s in Text(s.name).tag(i) }
                                    }
                                } label: {
                                    HStack(spacing: 6) {
                                        Text(seasons[safe: season]?.name ?? "Season").font(.title3.bold())
                                        Image(systemName: "chevron.down").font(.subheadline.weight(.bold)).foregroundStyle(.secondary)
                                    }
                                    .foregroundStyle(.primary)
                                }
                                .padding(.top, 8)
                                if loadingEpisodes && episodes.isEmpty { ProgressView().frame(maxWidth: .infinity) }
                                if let episodesNote, episodes.isEmpty && !loadingEpisodes {
                                    Text(episodesNote).font(.subheadline).foregroundStyle(.secondary)
                                    ActionButton(action: { await loadEpisodes() }) { Text("Try Again") }
                                        .buttonStyle(.glass)
                                }
                                ForEach(episodes) { e in
                                    EpisodeRow(episode: e, changed: { watchChanged(); Task { await loadEpisodes() } }, played: { dismiss() })
                                }
                            }
                            if let films = d.films, !films.isEmpty {
                                Text("In This Collection").font(.title3.bold()).padding(.top, 8)
                                ForEach(films) { e in
                                    EpisodeRow(episode: e, changed: { watchChanged(); Task { await load() } }, played: { dismiss() })
                                }
                            }
                        }
                        .padding(20)
                    }
                } else if let failed {
                    VStack(spacing: 14) {
                        EmptyState(symbol: "wifi.exclamationmark", title: "Can’t Load This Title", message: failed)
                        ActionButton(action: { await load() }) { Text("Try Again") }
                            .buttonStyle(.glass)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 120)
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 160)
                }
            }
            .ignoresSafeArea(edges: .top)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(role: .close) { dismiss() } } }
            .task { await load() }
            // The episodes of the season picked (and of the first one shown, once the title arrives).
            .task(id: "\(d?.id ?? "")|\(season)") { await loadEpisodes() }
        }
        // Errors from here (a play that failed, Mark as Watched) show over the sheet, not hidden behind it.
        .sheetBanner()
        #if os(macOS)
        .frame(minWidth: 620, idealWidth: 620, maxWidth: .infinity, minHeight: 700, idealHeight: 700, maxHeight: .infinity)
        #endif
    }

    private func header(_ d: TitleDetails) -> some View {
        ZStack(alignment: .bottomLeading) {
            Color.clear.aspectRatio(0.95, contentMode: .fit)
                .overlay { Artwork(url: client?.art(d.backdrop ?? d.poster)) }
                .clipped()
            LinearGradient(stops: [.init(color: .clear, location: 0.3), .init(color: .black.opacity(0.9), location: 1)], startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 8) {
                Text(d.title).font(.largeTitle.bold()).foregroundStyle(.white)
                Text(facts(d)).font(.footnote.weight(.medium)).foregroundStyle(.white.opacity(0.75))
                HStack(spacing: 10) {
                    // Closes once the play has gone out; if there's nowhere to play it, stays open and says why.
                    if let p = d.play { CapsuleButton(title: p.label ?? "Play", symbol: "play.fill") { if PlayRouter.start(p, fleet: fleet) { dismiss() } } }
                    if let r = d.restart {
                        Button { if PlayRouter.start(r, fleet: fleet, fromStart: true) { dismiss() } } label: {
                            Image(systemName: "arrow.counterclockwise").font(.headline).foregroundStyle(.white)
                                .frame(width: 40, height: 40).glass(Circle()).environment(\.colorScheme, .dark)
                        }
                        .buttonStyle(PressScale())
                        .accessibilityLabel(r.label ?? "Start Over")
                    }
                    if let p = d.play, fleet.tvs.filter({ !$0.isUnpaired }).count > 1 {
                        Menu { PlayOnMenu(action: p, then: { dismiss() }) } label: {
                            Image(systemName: "ellipsis").font(.headline).foregroundStyle(.white).frame(width: 40, height: 40).glass(Circle()).environment(\.colorScheme, .dark)
                        }
                        .menuStyle(.button).buttonStyle(.plain)
                        .accessibilityLabel("Play On…")
                    }
                }
                .padding(.top, 4)
            }
            .padding(20)
        }
    }

    private func facts(_ d: TitleDetails) -> String {
        var f: [String] = []
        if let name = d.playName, let code = d.play?.title { f.append("\(code) · \(name)") }
        else if let y = d.year { f.append(String(y)) }
        if let m = d.playMinutes ?? d.runtime {
            if d.playName == nil { f.append("\(Int(m)) min") }
            f.append("Ends at " + Date().addingTimeInterval(m * 60 - (d.play?.position ?? 0) / 1000).formatted(date: .omitted, time: .shortened))
        }
        if let a = d.ageRating { f.append(a) }
        return f.joined(separator: " · ")
    }

    private func load() async {
        guard let c = client else { failed = TVError.notPaired.localizedDescription; return }
        do {
            let t = try await c.title(id)
            let first = d == nil
            withAnimation(.smooth) { d = t }
            failed = nil
            // The season the TV suggests (the one in progress), the first time only: a reload keeps the one picked.
            if first { season = t.season ?? 0 }
        } catch {
            if Task.isCancelled { return }
            if d == nil { failed = error.localizedDescription } else { fleet.show(error) }
        }
    }

    private func mark(_ key: String, watched: Bool) {
        marking = true
        Task {
            do {
                guard let c = client else { throw TVError.notPaired }
                try await c.markWatched([key], watched)
                await load()
                watchChanged()
            } catch { fleet.show(error) }
            marking = false
        }
    }

    private func loadEpisodes() async {
        guard let d, let s = d.seasons?[safe: season], let c = client else { return }
        // Another season: not the last one's episodes while this one's arrive.
        if episodesSeason != s.id { episodes = [] }
        episodesNote = nil
        loadingEpisodes = true
        defer { loadingEpisodes = false }
        do {
            let list = try await c.episodes(show: d.id, season: s.id)
            guard !Task.isCancelled else { return }
            withAnimation(.smooth) { episodes = list.episodes }
            episodesSeason = s.id
            if list.episodes.isEmpty {
                episodesNote = list.state == "loading" ? "\(c.hub.name) is still getting these episodes ready." : "No episodes in \(s.name)."
            }
        } catch {
            if Task.isCancelled { return }
            episodesNote = error.localizedDescription
        }
    }
}

struct EpisodeRow: View {
    @Environment(Fleet.self) private var fleet
    var episode: Episode
    var changed: () -> Void
    /// A play went out (the title's sheet closes, so what's playing shows).
    var played: () -> Void = {}

    private var action: PlayAction {
        PlayAction(key: episode.key, title: episode.playTitle, position: episode.position, label: nil, duration: episode.duration, resume: true, latest: nil)
    }

    var body: some View {
        Button { if PlayRouter.start(action, fleet: fleet) { played() } } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 14) {
                    Color.clear.frame(width: 132, height: 74)
                        .overlay { Artwork(url: fleet.hubClient()?.art(episode.still, small: true)) }
                        .overlay {
                            Image(systemName: "play.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                                .frame(width: 28, height: 28).glass(Circle(), interactive: false).environment(\.colorScheme, .dark)
                        }
                        .overlay(alignment: .topTrailing) {
                            if episode.watched == true {
                                Image(systemName: "checkmark.circle.fill").font(.callout).symbolRenderingMode(.palette).foregroundStyle(.black, .white).padding(5)
                            }
                        }
                        .overlay(alignment: .bottom) {
                            if episode.progress > 0 && episode.watched != true {
                                Capsule().fill(.white.opacity(0.3)).frame(height: 3)
                                    .overlay(alignment: .leading) { GeometryReader { g in Capsule().fill(.white).frame(width: g.size.width * episode.progress) } }
                                    .padding(.horizontal, 8).padding(.bottom, 6)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(caption).font(.caption2.weight(.semibold)).foregroundStyle(episode.new == true ? Color.accentColor : .secondary).textCase(.uppercase)
                        Text(episode.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
                if let o = episode.overview { Text(o).font(.footnote).foregroundStyle(.secondary).lineLimit(3) }
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { if PlayRouter.start(action, fleet: fleet, fromStart: true) { played() } } label: { Label("Play from the Start", systemImage: "arrow.counterclockwise") }
            PlayOnMenu(action: action, then: played)
            Button {
                Task {
                    do {
                        guard let c = fleet.hubClient() else { throw TVError.notPaired }
                        try await c.markWatched([episode.key], !(episode.watched ?? false))
                        changed()
                    } catch { fleet.show(error) }
                }
            } label: { Label(episode.watched == true ? "Mark as Unwatched" : "Mark as Watched", systemImage: "checkmark.circle") }
        }
    }

    private var caption: String {
        var c: [String] = []
        if episode.new == true { c.append("New") }
        if let n = episode.number { c.append(episode.special == true ? "Special" : "Episode \(n)") }
        if let r = episode.runtime { c.append("\(Int(r)) min") }
        return c.joined(separator: " · ")
    }
}

/// All Movies or TV Shows, sorted and filtered, loading more as you scroll.
struct LibraryGrid: View {
    @Environment(Fleet.self) private var fleet
    @Environment(\.watchChanged) private var watchChanged
    @State private var openTitle: String?
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
    /// Each new sort, filter or search gets a number: an answer for an older one is dropped, never shown.
    @State private var generation = 0
    @State private var loaded = false
    @State private var failed: String?

    private var heading: String { place == "shows" ? "TV Shows" : "Movies" }
    private var filtered: Bool { unwatched || genre != nil || !query.isEmpty }

    var body: some View {
        ScrollView {
            if items.isEmpty, let failed {
                VStack(spacing: 14) {
                    EmptyState(symbol: "wifi.exclamationmark", title: "Can’t Load \(heading)", message: failed)
                    ActionButton(action: { await load(more: false) }) { Text("Try Again") }
                        .buttonStyle(.glass)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 80)
            } else if items.isEmpty && loaded && !loading {
                EmptyState(symbol: "film.stack", title: "Nothing Here", message: filtered ? "Nothing in \(heading) matches these choices." : "Nothing in \(heading) yet.")
                    .padding(.top, 80)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104, maximum: 150), spacing: 12, alignment: .top)], spacing: 18) {
                ForEach(items) { t in
                    PosterTile(title: t, width: 104)
                        .onAppear { if t.id == items.last?.id && items.count < count { Task { await load(more: true) } } }
                }
            }
            .padding(16)
            if loading { ProgressView().padding() }
        }
        .navigationTitle(heading)
        #if os(macOS)
        .pageSearch(text: $query, prompt: heading) { filterMenu }
        #else
        .pageSearch(text: $query, prompt: heading)
        #endif
        .environment(\.openTitle, OpenTitleAction { openTitle = $0 })
        // Marked watched here: the checkmarks (and an Unwatched list) follow at once, and so does Watch.
        .environment(\.watchChanged, WatchChanged { key in
            watchChanged(removed: key)
            Task { await reloadShown() }
        })
        .sheet(item: Binding(get: { openTitle.map { TitleRef(id: $0) } }, set: { openTitle = $0?.id })) { TitleSheet(id: $0.id).macResizable(width: 760, height: 820, minWidth: 520, minHeight: 500) }
        #if os(iOS)
        .toolbar { filterMenu }
        #endif
        .task(id: "\(sort)|\(unwatched)|\(genre ?? "")|\(query)") {
            try? await Task.sleep(nanoseconds: 200_000_000)
            // Changed again while waiting (typing): only the newest choice is asked for.
            guard !Task.isCancelled else { return }
            await load(more: false)
        }
    }

    private func load(more: Bool) async {
        guard let c = fleet.hubClient() else { failed = TVError.notPaired.localizedDescription; return }
        if more {
            guard !loading, items.count < count else { return }
        } else {
            generation += 1
        }
        let gen = generation
        loading = true
        defer { if gen == generation { loading = false } }
        do {
            let p = try await c.library(place: place, sort: sort, unwatched: unwatched, genre: genre, q: query, offset: more ? items.count : 0)
            guard gen == generation, !Task.isCancelled else { return }
            items = more ? items + p.items : p.items
            count = p.count
            genres = p.genres ?? genres
            rated = p.rated ?? rated
            failed = nil
            loaded = true
        } catch {
            guard gen == generation, !Task.isCancelled else { return }
            if items.isEmpty { failed = error.localizedDescription } else { fleet.show(error) }
        }
    }

    /// Show (all or unwatched), sort and genre.
    private var filterMenu: some View {
        Menu {
            Picker("Show", selection: $unwatched) { Text("All").tag(false); Text("Unwatched").tag(true) }
            Picker("Sort By", selection: $sort) {
                Text("A–Z").tag("az"); Text("Recently Added").tag("recent"); Text("Newest").tag("newest")
                if rated { Text("Top Rated").tag("rated") }
            }
            Picker("Genre", selection: $genre) {
                Text("All Genres").tag(String?.none)
                ForEach(genres, id: \.self) { Text($0).tag(String?.some($0)) }
            }
        } label: { Image(systemName: "line.3.horizontal.decrease") }
    }

    /// Asks again for everything shown (a title was just marked watched), keeping the place in the list.
    private func reloadShown() async {
        guard let c = fleet.hubClient(), !items.isEmpty else { return }
        generation += 1
        let gen = generation
        defer { if gen == generation { loading = false } }
        do {
            let p = try await c.library(place: place, sort: sort, unwatched: unwatched, genre: genre, q: query, offset: 0, limit: max(60, items.count))
            guard gen == generation else { return }
            items = p.items
            count = p.count
        } catch {
            // The list stays as it was; the next scroll or filter asks again.
        }
    }
}

/// Search Movies and TV Shows.
struct SearchPage: View {
    @Environment(Fleet.self) private var fleet
    @Environment(\.watchChanged) private var watchChanged
    @State private var query = ""
    @State private var r: SearchResults?
    @State private var openTitle: String?
    @State private var failed: String?
    /// Asked again (a result was marked watched).
    @State private var again = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                if !query.isEmpty, let failed {
                    EmptyState(symbol: "wifi.exclamationmark", title: "Can’t Search", message: failed).padding(.top, 60)
                } else if let r, !query.isEmpty {
                    let sections = r.first == "shows" ? [("TV Shows", r.shows), ("Movies", r.movies)] : [("Movies", r.movies), ("TV Shows", r.shows)]
                    ForEach(sections, id: \.0) { name, list in
                        if !list.isEmpty { ShelfRow(name) { ForEach(list) { PosterTile(title: $0) } } }
                    }
                    if r.movies.isEmpty && r.shows.isEmpty {
                        EmptyState(symbol: "magnifyingglass", title: "No Results", message: "Nothing in Movies or TV Shows matches “\(query)”.")
                    }
                } else {
                    EmptyState(symbol: "magnifyingglass", title: "Search the Library", message: "Find a film or show in Movies and TV Shows.").padding(.top, 60)
                }
            }
            .padding(.vertical)
        }
        .navigationTitle("Search")
        .pageSearch(text: $query, prompt: "Movies and TV Shows")
        .environment(\.openTitle, OpenTitleAction { openTitle = $0 })
        .environment(\.watchChanged, WatchChanged { key in
            watchChanged(removed: key)
            again += 1
        })
        .sheet(item: Binding(get: { openTitle.map { TitleRef(id: $0) } }, set: { openTitle = $0?.id })) { TitleSheet(id: $0.id).macResizable(width: 760, height: 820, minWidth: 520, minHeight: 500) }
        .task(id: "\(query)|\(again)") {
            guard !query.isEmpty else { r = nil; failed = nil; return }
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            guard let c = fleet.hubClient() else { failed = TVError.notPaired.localizedDescription; return }
            do {
                let found = try await c.search(query)
                guard !Task.isCancelled else { return }
                r = found
                failed = nil
            } catch {
                // Never an empty page that looks like "no results" when the TV didn't answer.
                if !Task.isCancelled { failed = error.localizedDescription }
            }
        }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

/// Watch while the library loads: the billboard and two shelves as soft shimmering shapes.
struct WatchPlaceholder: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            Placeholder(corner: 0).aspectRatio(0.82, contentMode: .fit).frame(maxWidth: .infinity)
            ForEach(0..<2, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 10) {
                    Placeholder(corner: 6).frame(width: 170, height: 22)
                    HStack(spacing: 10) { ForEach(0..<4, id: \.self) { _ in Placeholder().frame(width: 112, height: 168) } }
                }
                .padding(.horizontal, 20)
            }
        }
        .shimmer()
        .accessibilityLabel("Loading")
    }
}
