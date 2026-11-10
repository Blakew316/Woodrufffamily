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
    /// The hub `home` came from.
    @State private var homeFrom: String?
    /// Taken off Continue Watching here, hidden until the TV's next answer (which no longer has them).
    @State private var removed: Set<String> = []
    /// The sections being read now (a second read of the same one waits for nothing: it's skipped).
    @State private var readingSections: Set<String> = []
    /// Movies or TV Shows, as on the TV's streaming screen.
    @AppStorage("watch.section") private var section = "movies"
    #if os(tvOS)
    /// Apple TV: the library this page is for ("movies" or "shows"). Movies and TV Shows are two tabs in the sidebar
    /// there (`TVMacRoot`), each with a page of its own, so nothing on the page switches between them.
    var library: String? = nil
    #endif
    /// The TV's library or the Drive one (Settings → Watch).
    @AppStorage("watch.source") private var source = "tv"
    /// The posters' width (fitted to the window on the Mac; on Apple TV its one size, read from across the room).
    #if os(tvOS)
    @State private var posterWidth: CGFloat = TVWatch.poster
    #else
    @State private var posterWidth: CGFloat = 112
    #endif
    /// Every title of each, for its banner and rows, and when it was read.
    @State private var sectionTitles: [String: [Title]] = [:]
    @State private var sectionRead: [String: Date] = [:]
    /// The banner's five and the rows, worked out once per list (not at every redraw: the banner turning every 12
    /// seconds redraws the page).
    @State private var shelves = ShelfCache()
    #if os(iOS) || os(tvOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    /// Posters sized so each row fills the page: on the Mac and iPad about 150 points each, as many as fit; 112 on
    /// iPhone. (Apple TV: always `TVWatch.poster`, whatever the page's width. They were fitted as on iPad, about
    /// 160 points each.)
    private func fitPosters(_ w: CGFloat) {
        #if !os(tvOS)
        #if os(iOS)
        guard sizeClass == .regular else { if posterWidth != 112 { posterWidth = 112 }; return }
        let target: CGFloat = 160
        #else
        let target: CGFloat = 150
        #endif
        let fit = fittedPosterWidth(w, target: target)
        if abs(fit - posterWidth) > 0.5 { posterWidth = fit }
        #endif
    }

    private var client: (any WatchSource)? { WatchSources.current(fleet) }

    /// The library shown: "movies" or "shows".
    private var place: String {
        #if os(tvOS)
        // Apple TV: its tab's own.
        if let library { return library }
        #endif
        return section == "shows" ? "shows" : "movies"
    }

    var body: some View {
        // Worked out once for the page: the tiles are handed their pictures' addresses, so none of them looks at the
        // fleet (which would redraw every one whenever the TVs change).
        let client = self.client
        // Until this page's own answer arrives, the library the app already has (it keeps one for the pictures of
        // what's playing): Watch opens with its shelves instead of placeholders. Only when it came from this page's
        // TV: another TV's library may hold titles this one doesn't.
        let kept = client.flatMap { c in fleet.libraryFrom == c.sourceID ? fleet.library : nil }
        // Never the last TV's answer once the remote has moved to another (its Continue Watching isn't this one's).
        let mine = homeFrom == client?.sourceID ? home : nil
        let shown = mine ?? (error == nil ? kept : nil)
        ScrollView {
            #if os(tvOS)
            // Apple TV: the banner first, always there (never unloaded); the rows under it load as they come up.
            VStack(alignment: .leading, spacing: 28) {
                if let h = shown { tvBanner(h, client) }
                shelfStack(shown, client)
            }
            #else
            shelfStack(shown, client)
            #endif
        }
        #if os(tvOS)
        // Apple TV: the page's scrolling, in the banner's hands (back on its Play, the page goes back to its top).
        .modifier(WatchScrollReader())
        #endif
        .scrollIndicators(.hidden)
        #if os(macOS)
        // Scrolling down fades the bar's row with Movies | TV Shows away; scrolling up brings it back. (How far down,
        // kept within the page's ends, so the bounce at either end doesn't count.)
        .onScrollGeometryChange(for: CGFloat.self, of: { g in
            let end = g.contentSize.height + g.contentInsets.top + g.contentInsets.bottom - g.containerSize.height
            return min(max(0, g.contentOffset.y + g.contentInsets.top), max(0, end))
        }) { old, new in
            MacWatchScroll.shared.follow(from: old, to: new)
        }
        .onDisappear { MacWatchScroll.shared.reset() }
        #endif
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { w in fitPosters(w) }
        .environment(\.posterWidth, posterWidth)
        #if os(iOS)
        .toolbar {
            ToolbarItem(placement: .principal) {
                // iPad: Movies | TV Shows on the same row as the TV.
                HStack(spacing: 12) {
                    TVPicker()
                    if sizeClass == .regular { sectionPicker.frame(width: 260) }
                }
            }
            #if !os(tvOS)
            .sharedBackgroundVisibility(.hidden)
            #endif
        }
        #else
        // The window's own bar has the search; the TV that plays is picked at the top of the page.
        // The TV it plays on and Movies | TV Shows are in the window's top bar.
        #endif
        .inlineTitle()
        #if os(macOS)
        .navigationTitle("Watch")
        #endif
        .navigationDestination(for: LibraryRef.self) { LibraryGrid(place: $0.place, genre: $0.genre, sort: $0.sort ?? "az") }
        .titleSheet(Binding(get: { openTitle.map { TitleRef(id: $0) } }, set: { openTitle = $0?.id })) { (ref: TitleRef) in
            #if os(tvOS)
            TitleSheet(id: ref.id)
            #else
            TitleSheet(id: ref.id).zoomDestination(ref.id, zoom)
            #endif
        }
        .environment(\.openTitle, OpenTitleAction { openTitle = $0 })
        .environment(\.zoomNamespace, zoom)
        // Marked watched or taken off Continue Watching anywhere in Watch: gone at once, then asked again.
        .environment(\.watchChanged, WatchChanged { key in
            if let key { withAnimation(.smooth) { _ = removed.insert(key) } }
            Task {
                await load()
                await loadSection(force: true)
            }
        })
        .refreshable { await load() }
        // A film or episode played on this device stopped: Continue Watching (and each Resume) shows where it was left
        // off at once, not a minute later.
        .onChange(of: DriveLibrary.shared.stoppedHere) { _, _ in
            Task {
                await load()
                if client?.sourceID == "drive" { await loadSection(force: true) }
            }
        }
        #if !os(tvOS)
        // Movies | TV Shows (on the Mac, switched in the window's top bar). (Not on Apple TV, where each has a page
        // of its own: the other tab being opened is no reason to start this page's banner again.)
        .onChange(of: section) { _, _ in
            page = 0
            Task { await loadSection(force: false) }
        }
        #endif
        // Again from the start when the remote moves to a TV with another library.
        .task(id: client?.sourceID) { await loop() }
        // A Google token ready before Play is pressed (fetching one then adds a round trip to the start), lasting most
        // of an hour: Play on the banner or a poster's menu starts without a title's page warming one up, and one with
        // under 15 minutes left sends a film the slower way. Looked at every 10 minutes while Watch is open.
        .task {
            while !Task.isCancelled, GoogleDrive.signedIn {
                _ = try? await GoogleDrive.token(minLife: 2700)
                try? await Task.sleep(nanoseconds: 600_000_000_000)
            }
        }
        // The other library picked in Settings → Watch: its titles, read afresh.
        .onChange(of: source) { _, _ in
            sectionTitles = [:]
            sectionRead = [:]
            Task { await load() }
        }
        // Something started, paused or stopped on a TV: Continue Watching follows (the TV saves where it got to).
        .background {
            PlayingWatcher {
                guard home != nil else { return }
                await load()
            }
        }
        .onAppear { if UserDefaults.standard.string(forKey: "route") == "title" { openTitle = "t_backyard_science" } }
        // How long Watch takes to show its titles (Settings → General → Speed).
        .background { TimingProbe(name: "Watch", ready: shown != nil) }
    }

    /// The page: Movies | TV Shows on iPhone, then the banner and the rows, or why there are none. (Search is the tab
    /// bar's own tab on iPhone and iPad: `SearchPage`.)
    @ViewBuilder private func shelfStack(_ shown: WatchHome?, _ client: (any WatchSource)?) -> some View {
        LazyVStack(alignment: .leading, spacing: 28) {
            #if os(iOS)
            // iPhone: Movies | TV Shows at the top of the page (on iPad the switch is in the bar at the top).
            if sizeClass != .regular {
                sectionPicker
                    .padding(.horizontal)
                    .padding(.top, 8)
            }
            #endif
            if let h = shown {
                content(h, client)
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

    @ViewBuilder private func content(_ h: WatchHome, _ client: (any WatchSource)?) -> some View {
        if h.state != "ready" && (h.featured ?? []).isEmpty && (h.continue ?? []).isEmpty {
            EmptyState(symbol: "film.stack", title: stateTitle(h.state), message: stateMessage(h.state, tv: h.tv, drive: client?.sourceID == "drive")).padding(.top, 60)
        }
        // Movies or TV Shows, as on the TV: the day's five across the top, then the rows.
        let place = self.place
        let titles = sectionTitles[place] ?? []
        let watchingIDs = Set((h.continue ?? []).filter { ($0.kind == "show") == (place == "shows") }.compactMap(\.titleId))
        let worked = shelves.get(place: place, titles: titles, shown: watchingIDs)
        #if !os(tvOS)
        // Until the whole list is read, the library's own featured titles, so the banner shows at once.
        // (Apple TV's banner is above the rows, in tvBanner.)
        let featured = worked.featured.isEmpty ? (h.featured ?? []).filter { ($0.kind == "show") == (place == "shows") } : worked.featured
        if !featured.isEmpty {
            Billboard(titles: featured, page: $page, client: client).id(place)
        }
        #endif
        let watching = (h.continue ?? []).filter { !removed.contains($0.key) && ($0.kind == "show") == (place == "shows") }
        if !watching.isEmpty {
            #if os(tvOS)
            // Apple TV: wide stills, each its title's own wide picture (the row's titles have them).
            ShelfRow("Continue Watching") {
                ForEach(watching) { ContinueTile(item: $0, poster: client?.artURL($0.poster), still: client?.artURL(worked.wide[$0.titleId ?? ""])) }
            }
            #else
            ShelfRow("Continue Watching") { ForEach(watching) { ContinueTile(item: $0, poster: client?.artURL($0.poster)) } }
            #endif
        }
        ForEach(worked.rows, id: \.name) { row in
            ShelfRow(row.name, all: LibraryRef(place: place, genre: row.genre, sort: row.name == "Top Rated" ? "rated" : row.name == "Recently Added" ? "recent" : nil)) {
                ForEach(row.titles) { PosterTile(title: $0, poster: client?.artURL($0.poster)) }
            }
            // As the row comes into view, the posters further along it are fetched ahead (a few at a time, on disk
            // only), so scrolling sideways never waits on one.
            .task(id: row.name + place) {
                // A moment after the row shows, so the posters on screen are asked for first.
                try? await Task.sleep(nanoseconds: 400_000_000)
                await ShelfWarmer.warm(row.titles.prefix(18).compactMap { client?.artURL($0.poster) })
            }
        }
    }

    #if os(tvOS)
    /// Apple TV: the banner, the whole screen, with the first row over its foot, far enough up that all of the row
    /// shows (it was cut off by the bottom of the screen). Always there (not in the lazy stack of rows, which unloads
    /// what's scrolled off: Up from the first row then found nothing above it and went to the sidebar).
    @ViewBuilder private func tvBanner(_ h: WatchHome, _ client: (any WatchSource)?) -> some View {
        let place = self.place
        let titles = sectionTitles[place] ?? []
        let watching = (h.continue ?? []).filter { ($0.kind == "show") == (place == "shows") }
        let worked = shelves.get(place: place, titles: titles, shown: Set(watching.compactMap(\.titleId)))
        // Until the whole list is read, the library's own featured titles, so the banner shows at once.
        let featured = worked.featured.isEmpty ? (h.featured ?? []).filter { ($0.kind == "show") == (place == "shows") } : worked.featured
        // The first row is Continue Watching's stills when there's anything in it (less what was just taken off it
        // here), else a row of posters, which is taller and so starts higher.
        let rowsTop = watching.contains(where: { !removed.contains($0.key) }) ? TVWatch.stillsTop : TVWatch.postersTop
        ZStack(alignment: .top) {
            if !featured.isEmpty {
                Billboard(titles: featured, page: $page, client: client, rowsTop: rowsTop)
                    // Fading out as the page moves down to the rows (and back in on the way up), as the TV app's does.
                    .visualEffect { c, p in c.opacity(max(0, min(1, 1 + p.frame(in: .scrollView).minY / 650))) }
                    // The banner is the whole screen (1080); the rows start at `rowsTop` (the stack puts 28 points
                    // between the banner and them).
                    .padding(.bottom, rowsTop - 28 - 1080)
            } else {
                // No banner yet (nothing with a wide picture): room for the sidebar's corner above the first row.
                Color.clear.frame(height: 140)
            }
        }
        // The top of the page, for the banner to send the page back to (`WatchScrollReader`).
        .id(WatchScrollReader.top)
    }
    #endif

    /// Movies | TV Shows above the banner.
    private var sectionPicker: some View {
        Picker("Library", selection: $section) {
            Text("Movies").tag("movies")
            Text("TV Shows").tag("shows")
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 420)
        .labelsHidden()
        .frame(maxWidth: 300)
        .frame(maxWidth: .infinity)

    }

    /// Every title of the section shown (a page at a time from the library), for its banner and rows.
    private func loadSection(force: Bool = false) async {
        guard let c = client else { return }
        let place = self.place
        // Read again at most every 10 minutes (Watch asks for its page every minute).
        if !force, sectionTitles[place] != nil, let at = sectionRead[place], Date().timeIntervalSince(at) < 600 { return }
        let source = c.sourceID
        // Already being read (the page asks as it opens, every minute, and when the section or library changes):
        // one read of the whole list at a time, unless asked for a fresh one.
        let reading = source + "|" + place
        if !force && readingSections.contains(reading) { return }
        readingSections.insert(reading)
        defer { readingSections.remove(reading) }
        var all: [Title] = []
        var offset = 0
        var read = false
        while let p = try? await c.library(place: place, sort: "recent", unwatched: false, genre: nil, q: nil, offset: offset, limit: 120) {
            // The remote moved to a TV with another library meanwhile: these are the old one's.
            guard client?.sourceID == source else { return }
            read = true
            all += p.items
            offset += p.items.count
            // The first page shows at once (the rows fill in as the rest arrives), unless the rows kept from last time
            // are already showing: they stay until the whole list is here.
            if offset == p.items.count, (sectionTitles[place] ?? []).isEmpty { sectionTitles[place] = all }
            if p.items.isEmpty || offset >= p.count || offset >= 3000 { break }
        }
        guard client?.sourceID == source else { return }
        if !all.isEmpty || sectionTitles[place] == nil { sectionTitles[place] = all }
        // An empty or failed read is tried again with the next one (a library still being read, a TV that didn't
        // answer), not ten minutes later.
        if read && !all.isEmpty {
            sectionRead[place] = Date()
            ShelfStore.shared.keep(all, source: source, place: place)
        }
    }

    /// The rows as kept from last time, for this library, until it's read again.
    private func restoreSections() async {
        guard let c = client else { return }
        let source = c.sourceID
        if loadedHub != source {
            loadedHub = source; sectionTitles = [:]; sectionRead = [:]
            // Another TV's library: its error, what was hidden from its Continue Watching and its banner's page go too.
            error = nil
            removed = []
            page = 0
        }
        for place in ["movies", "shows"] where sectionTitles[place] == nil {
            guard let kept = await ShelfStore.shared.titles(source: source, place: place), !kept.isEmpty else { continue }
            // Meanwhile read afresh, or the remote moved to another TV.
            guard client?.sourceID == source, sectionTitles[place] == nil else { return }
            sectionTitles[place] = kept
        }
    }

    private func load() async {
        guard let c = client else { error = TVError.notPaired.localizedDescription; return }
        let hubID = c.sourceID
        if loadedHub != hubID { loadedHub = hubID; sectionTitles = [:]; sectionRead = [:] }
        // The rows' titles are read alongside the home, not after it: the rows show a round trip sooner.
        async let rows: Void = loadSection()
        do {
            let h = try await c.watchHome()
            // The remote moved to a TV with another library meanwhile: this answer is for the old one.
            guard client?.sourceID == hubID else { return }
            // The Drive library read again, or TMDB's posters come in: its rows are read again too.
            let newer = hubID == "drive" && home != nil && h.updated != home?.updated
            // Asked again every minute and after every play: the page redraws only for an answer that's new (what was
            // taken off Continue Watching here comes back if the TV still has it, as it always did).
            let changed = h != home
            if changed || !removed.isEmpty {
                withAnimation(.smooth) {
                    if changed { home = h }
                    if !removed.isEmpty { removed = [] }
                }
            }
            if homeFrom != hubID { homeFrom = hubID }
            if error != nil { error = nil }
            await rows
            let place = self.place
            // A library that was still being read when the rows were asked for (a fresh install): asked again now.
            if newer || (h.state == "ready" && sectionRead[place] == nil) { await loadSection(force: true) }
        } catch {
            if Task.isCancelled { return }
            // A library already shown stays (a blink in the Wi‑Fi isn't worth an empty page); another TV's doesn't.
            if home == nil || homeFrom != hubID {
                home = nil
                self.error = error.localizedDescription
            }
        }
    }

    private func loop() async {
        // Last time's rows at once (an app update keeps them), then read afresh behind them.
        await restoreSections()
        while !Task.isCancelled {
            await load()
            // Sooner while the library is still being read, or TMDB's posters are still coming in (Drive).
            let filling = (client as? DriveLibrary)?.isFilling == true
            try? await Task.sleep(nanoseconds: home?.state == "loading" ? 3_000_000_000 : filling ? 5_000_000_000 : 60_000_000_000)
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
    private func stateMessage(_ s: String, tv: String?, drive: Bool) -> String {
        let t = tv ?? "the TV"
        if drive {
            switch s {
            case "loading": return "Reading Movies and TV Shows from Google Drive."
            case "notSignedIn": return "Sign in to Google Drive in Settings → Watch."
            default: break
            }
        }
        switch s {
        case "empty": return "Make folders named Movies and TV Shows in Google Drive."
        case "expired", "expiredEmpty", "notSignedIn": return "Sign \(t) in again from Settings → TVs → \(t)."
        case "loading": return "\(t) is reading Movies and TV Shows."
        default: return "Add the Google Drive keys in Settings → Accounts → Google Drive."
        }
    }
}

/// Notices when what any TV plays (or whether it plays) changes, and says so a moment later: Continue Watching has
/// changed then too. A view of its own behind Watch: the TVs report every couple of seconds, and only this redraws.
private struct PlayingWatcher: View {
    @Environment(Fleet.self) private var fleet
    var changed: () async -> Void
    /// What it last saw (nothing to say the first time: the page reads the library as it opens anyway).
    @State private var last: String?

    var body: some View {
        let key = fleet.tvs.map { "\($0.id)|\($0.playing?.key ?? $0.playing?.title ?? "")|\($0.playing?.isPlaying == true)" }.joined(separator: ";")
        Color.clear
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .task(id: key) {
                guard let before = last else { last = key; return }
                last = key
                guard before != key else { return }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard !Task.isCancelled else { return }
                await changed()
            }
    }
}

struct TitleRef: Hashable, Identifiable { var id: String }

extension View {
    /// A title's sheet: on Apple TV its own page over the whole screen (Menu closes it), elsewhere a sheet.
    @ViewBuilder func titleSheet<C: View>(_ item: Binding<TitleRef?>, @ViewBuilder content: @escaping (TitleRef) -> C) -> some View {
        #if os(tvOS)
        fullScreenCover(item: item) { content($0).presentationBackground(.clear) }
        #else
        sheet(item: item, content: content)
        #endif
    }
}
struct LibraryRef: Hashable {
    var place: String
    /// Opened from a genre's row: the list filtered to it.
    var genre: String? = nil
    /// Opened from Recently Added or Top Rated: sorted that way.
    var sort: String? = nil
}

/// Opens a title's sheet from anywhere in Watch.
struct OpenTitleAction { var open: (String) -> Void; func callAsFunction(_ id: String) { open(id) } }
private struct OpenTitleKey: EnvironmentKey { static let defaultValue = OpenTitleAction { _ in } }

/// Tells Watch the library changed here (marked watched, taken off Continue Watching), so it shows at once
/// instead of on its next round. [removed] is a Continue Watching key to hide straight away.
struct WatchChanged { var changed: (String?) -> Void; func callAsFunction(removed: String? = nil) { changed(removed) } }
private struct WatchChangedKey: EnvironmentKey { static let defaultValue = WatchChanged { _ in } }

/// How wide Watch's posters are: the Mac fits them to the window; elsewhere the usual 112 (Apple TV: its one size).
private struct PosterWidthKey: EnvironmentKey {
    #if os(tvOS)
    static let defaultValue: CGFloat = TVWatch.poster
    #else
    static let defaultValue: CGFloat = 112
    #endif
}

/// A poster's width in a page [width] points wide, so each row fills it: about [target] points each, as many as fit.
func fittedPosterWidth(_ width: CGFloat, target: CGFloat) -> CGFloat {
    let usable = max(300, width - 40), gap: CGFloat = 10
    let n = max(4, Int((usable + gap) / (target + gap)))
    return ((usable - gap * CGFloat(n - 1)) / CGFloat(n)).rounded(.down)
}

extension EnvironmentValues {
    var openTitle: OpenTitleAction {
        get { self[OpenTitleKey.self] }
        set { self[OpenTitleKey.self] = newValue }
    }
    var posterWidth: CGFloat {
        get { self[PosterWidthKey.self] }
        set { self[PosterWidthKey.self] = newValue }
    }
    var watchChanged: WatchChanged {
        get { self[WatchChangedKey.self] }
        set { self[WatchChangedKey.self] = newValue }
    }
}

#if os(tvOS)
/// Apple TV's sizes for Watch, in points on its 1920 by 1080 screen (read from across the room), as the TV app's own.
enum TVWatch {
    /// A poster: 250 by 375. Six across, the seventh showing at the edge.
    static let poster: CGFloat = 250
    /// A wide picture (Continue Watching, an episode, a collection's film): 400 by 225. Four across, the fifth showing.
    static let still: CGFloat = 400
    /// Between the tiles of a row.
    static let gap: CGFloat = 40
    /// A row's heading.
    static let heading = Font.system(size: 38, weight: .bold)
    /// Where the first row under the banner starts (its heading's top, from the top of the screen), so the whole of
    /// it shows with its names, clear of the bottom edge (and the page needn't move when the remote comes down onto
    /// it): a row of stills, or the taller row of posters.
    static let stillsTop: CGFloat = 568
    static let postersTop: CGFloat = 456
    /// How tall the words under a Continue Watching still are: a name on up to two lines, and the line under it.
    static let continueWords: CGFloat = 106
    /// On a title's page: how tall the words under a still are (an episode's number, name and story; a film's name),
    /// the room over the stills for the one under the remote to lift into, and how tall the shelf is with both.
    static let episodeWords: CGFloat = 136
    static let filmWords: CGFloat = 70
    static let shelfLift: CGFloat = 20
    static func shelfHeight(words: CGFloat) -> CGFloat { shelfLift + still * 9 / 16 + 16 + words }
}

/// Apple TV draws posters and stills two or three times the size a phone does, on a screen up to 4K: TMDB's larger
/// copy of each (a poster 500 across in place of 342, a still 780 in place of 300). Any other picture is left as it is.
private func tvLarge(_ url: URL?) -> URL? {
    guard let url, url.host == "image.tmdb.org" else { return url }
    let address = url.absoluteString
    for (small, large) in [("/t/p/w342/", "/t/p/w500/"), ("/t/p/w300/", "/t/p/w780/")] where address.contains(small) {
        return URL(string: address.replacingOccurrences(of: small, with: large)) ?? url
    }
    return url
}

/// Apple TV: how far a still's film or episode has got, across the foot of the still (shaded, so it reads over any
/// picture).
private struct TVProgressFoot: View {
    var progress: Double

    var body: some View {
        ZStack(alignment: .bottom) {
            LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom).frame(height: 72)
            Capsule().fill(.white.opacity(0.3)).frame(height: 6)
                .overlay(alignment: .leading) { GeometryReader { g in Capsule().fill(.white).frame(width: g.size.width * progress) } }
                .padding(.horizontal, 20).padding(.bottom, 16)
        }
    }
}

/// Apple TV: Watch's own scrolling, for its banner. Moving back up to Play from the rows left the page where it was
/// (Play was already on screen, so nothing scrolled): the banner cut off and dimmed.
private struct WatchScrollerKey: EnvironmentKey { static let defaultValue: ScrollViewProxy? = nil }
extension EnvironmentValues {
    var watchScroller: ScrollViewProxy? {
        get { self[WatchScrollerKey.self] }
        set { self[WatchScrollerKey.self] = newValue }
    }
}

/// Hands Watch's scrolling to what's on the page (around its scroll view).
private struct WatchScrollReader: ViewModifier {
    /// The top of the page (the banner).
    static let top = "watch.top"

    func body(content: Content) -> some View {
        ScrollViewReader { proxy in content.environment(\.watchScroller, proxy) }
    }
}
#endif

/// The featured titles, one card at a time, swiping.
struct Billboard: View {
    @Environment(Fleet.self) private var fleet
    @Environment(\.openTitle) private var openTitle
    var titles: [Title]
    @Binding var page: Int
    /// The TV the library is from (Watch works it out once for every picture on the page).
    var client: (any WatchSource)?
    #if os(tvOS)
    /// Apple TV: where the first row under the banner starts, from the top of the screen. The banner's words and
    /// buttons sit just above it.
    var rowsTop: CGFloat = TVWatch.stillsTop
    #endif
    /// What each featured title is about (the wide banner shows it), read once each.
    @State private var overviews: [String: String] = [:]
    #if os(iOS) || os(tvOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var width: CGFloat = 0
    #endif
    #if os(iOS)
    /// VoiceOver or Reduce Motion on: the banner doesn't turn by itself (a swipe still turns it).
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #endif
    #if os(tvOS)
    /// Play or Details picked with the remote: the banner stays on this title (moving on would take the focus away).
    @FocusState private var focusedButton: String?
    /// Watch's scrolling (see `tvButtons`).
    @Environment(\.watchScroller) private var scroller
    #endif

    var body: some View {
        pages
            .overlay(alignment: .bottomTrailing) { dots }
            .frame(maxWidth: .infinity)
            // A shorter list after a refresh: never a page that isn't there.
            .onChange(of: titles.count) { _, n in if page >= n { page = 0 } }
    }

    #if os(iOS)
    private var pages: some View {
        // iPad: the wide banner, as on the Mac (the words and buttons on the left, the picture on the right), short
        // enough that Continue Watching shows under it. iPhone: the picture's own shape, across the screen.
        let wide = sizeClass == .regular
        return TabView(selection: $page) {
            ForEach(Array(titles.enumerated()), id: \.offset) { i, t in
                Group { if wide { wideCard(t) } else { card(t) } }.tag(i)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .aspectRatio(wide ? (width > 1000 ? 2.7 : 2.1) : 16.0 / 9.0, contentMode: .fit)
        .padding(.horizontal, wide ? 24 : 16)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
        // On to the next after 12 seconds, as on the TV (a swipe starts the 12 seconds again). Not with VoiceOver on (it
        // would change under the finger reading it) or Reduce Motion: then only a swipe turns it.
        .task(id: "\(page)|\(voiceOver || reduceMotion)") {
            guard !voiceOver, !reduceMotion else { return }
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            guard !Task.isCancelled, titles.count > 1 else { return }
            withAnimation(.easeInOut(duration: 0.7)) { page = (page + 1) % titles.count }
        }
    }
    #elseif os(tvOS)
    /// Apple TV: the whole screen, edge to edge, as the TV app's own banner: one title at a time that moves on by
    /// itself, its picture behind, its words and Play and Details over the lower left, just above the first row, which
    /// sits over the banner's foot (`rowsTop`) so that all of it shows.
    private var pages: some View {
        ZStack(alignment: .bottomLeading) {
            if let t = titles[safe: page] ?? titles.first {
                tvPicture(t).id(t.id).transition(.opacity)
            }
            // The same for every title, so they stay while the picture changes under them.
            tvScrims.zIndex(1)
            if let t = titles[safe: page] ?? titles.first {
                VStack(alignment: .leading, spacing: 22) {
                    tvWords(t).id(t.id).transition(.opacity)
                    // Play and Details: one pair that stays while the picture and the words over them change.
                    tvButtons(t)
                }
                // In line with the rows' tiles, and clear of the first row's heading.
                .padding(.leading, 100).padding(.trailing, 90).padding(.bottom, 1080 - rowsTop + 40)
                .zIndex(2)
            }
        }
        .frame(height: 1080)
        .frame(maxWidth: .infinity)
        .ignoresSafeArea(edges: [.top, .horizontal])
        .task(id: page) {
            // The next title's picture made ready meanwhile (it fills the screen), so it fades in whole instead of as a
            // grey placeholder its picture then fades into.
            if titles.count > 1, let next = titles[safe: (page + 1) % titles.count],
               let art = client?.artURL(next.backdrop ?? next.poster), ImageStore.shared.cached(art, maxPixel: 2400) == nil {
                Task(priority: .utility) { _ = await ImageStore.shared.image(art, maxPixel: 2400) }
            }
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            // Not while its Play or Details has the focus: the next title would take it away, and Down would stop working.
            while !Task.isCancelled && focusedButton != nil { try? await Task.sleep(nanoseconds: 1_000_000_000) }
            guard !Task.isCancelled, titles.count > 1 else { return }
            withAnimation(.easeInOut(duration: 0.7)) { page = (page + 1) % titles.count }
        }
    }
    #else
    /// The Mac has no swiping pages (a plain TabView there is a strip of blank tabs): one card at a time that moves
    /// on by itself; the dots pick one.
    private var pages: some View {
        ZStack {
            if let t = titles[safe: page] ?? titles.first {
                wideCard(t).id(t.id).transition(.opacity)
            }
        }
        // The window's whole width, a third as tall: it grows and shrinks with the window, and the rows show under it.
        .aspectRatio(3.0, contentMode: .fit)
        .padding(.horizontal, 20)
        .task(id: page) {
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            guard !Task.isCancelled, titles.count > 1 else { return }
            withAnimation(.easeInOut(duration: 0.7)) { page = (page + 1) % titles.count }
        }
    }
    #endif

    #if os(tvOS)
    /// Apple TV: the title's picture, filling the screen.
    private func tvPicture(_ t: Title) -> some View {
        Color.clear.overlay { Artwork(url: client?.artURL(t.backdrop ?? t.poster), maxPixel: 2400) }.clipped()
    }

    /// Apple TV: over the picture, the system's material rising from its foot (whole behind the rows that sit over it,
    /// thinning out above the first row's heading, as the TV app's banner has it, so the rows' names read over any
    /// picture), and a shade from the left for the words.
    private var tvScrims: some View {
        // How far up the screen the first row starts, from the bottom (0 to 1).
        let rows = (1080 - rowsTop) / 1080
        return ZStack {
            Rectangle().fill(.regularMaterial)
                .mask {
                    LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: rows),
                                           .init(color: .black.opacity(0.35), location: rows + 0.1),
                                           .init(color: .clear, location: rows + 0.22)],
                                   startPoint: .bottom, endPoint: .top)
                }
            LinearGradient(stops: [.init(color: .black.opacity(0.7), location: 0), .init(color: .black.opacity(0.25), location: 0.5),
                                   .init(color: .clear, location: 0.8)], startPoint: .leading, endPoint: .trailing)
        }
    }

    /// Apple TV: the words over the picture's lower left, as the TV app does: the name large, what it is, what it's
    /// about.
    private func tvWords(_ t: Title) -> some View {
        // Over a row of posters there's less room than over the shorter stills: a smaller name, on one line.
        let compact = rowsTop < TVWatch.stillsTop
        return VStack(alignment: .leading, spacing: 14) {
            Text(t.title)
                .font(.system(size: compact ? 60 : 76, weight: .heavy))
                .foregroundStyle(.white)
                .lineLimit(compact ? 1 : 2)
                .minimumScaleFactor(0.6)
                .shadow(color: .black.opacity(0.5), radius: 12)
            Text(meta(t)).font(.system(size: 26, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
            if let o = overviews[t.id], !o.isEmpty {
                Text(o)
                    .font(.system(size: 25, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(2)
                    .frame(maxWidth: 820, alignment: .leading)
                    .transition(.opacity)
            }
        }
        .task(id: t.id) { await overview(t) }
    }

    /// Apple TV: Play and Details, under the words. One pair for every title: buttons that were part of each title's
    /// own card were rebuilt whenever the title changed, and the one the remote was on lost the focus, which then
    /// landed anywhere (the sidebar too).
    private func tvButtons(_ t: Title) -> some View {
        HStack(spacing: 22) {
            if let p = t.play {
                CapsuleButton(title: p.label ?? "Play", symbol: "play.fill") { PlayRouter.start(p, fleet: fleet) }
                    .focused($focusedButton, equals: "play")
            }
            CapsuleButton(title: "Details", symbol: nil, prominent: false) { open(t) }
                .focused($focusedButton, equals: "details")
        }
        // A section across the screen: Up from the first row always lands here, on Play.
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
        .defaultFocus($focusedButton, t.play != nil ? "play" : "details", priority: .userInitiated)
        // Back on Play or Details (up from the rows): the page goes back to its top, the banner whole again. By itself
        // it stayed where it was, as the buttons were already on screen. (Only on reaching these two, and only to the
        // top, where they stay in view: the page never chases the focus.)
        .onChange(of: focusedButton) { _, now in
            guard now != nil, let scroller else { return }
            withAnimation(.smooth(duration: 0.3)) { scroller.scrollTo(WatchScrollReader.top, anchor: .top) }
        }
        // Play/Pause on the remote plays it from either button, as the TV app's banner does.
        .onPlayPauseCommand { if let p = t.play { PlayRouter.start(p, fleet: fleet) } }
    }
    #else
    /// The Mac's and iPad's banner, as on the TV: the words on the left, the whole 16:9 picture on the right in a
    /// rounded frame, over a blurred copy of it filling the banner.
    private func wideCard(_ t: Title) -> some View {
        let art = client?.artURL(t.backdrop ?? t.poster)
        return GeometryReader { g in
            let inset: CGFloat = 18
            let picH = g.size.height - inset * 2
            let picW = min(g.size.width * 0.62, picH * 16 / 9)
            ZStack {
                BlurredArtwork(url: art, radius: 40, maxPixel: 900).opacity(0.75)
                Color.black.opacity(0.45)
                HStack(spacing: 24) {
                    // From the top: the name, its facts, Play and Details, then what it's about.
                    VStack(alignment: .leading, spacing: 8) {
                        Text(t.title).font(.system(size: max(22, min(40, g.size.height * 0.11)), weight: .bold))
                            .foregroundStyle(.white).lineLimit(2).minimumScaleFactor(0.7)
                        Text(meta(t)).font(.callout.weight(.medium)).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                        HStack(spacing: 10) {
                            if let p = t.play {
                                CapsuleButton(title: p.label ?? "Play", symbol: "play.fill") { PlayRouter.start(p, fleet: fleet) }
                            }
                            CapsuleButton(title: "Details", symbol: nil, prominent: false) { open(t) }
                        }
                        .padding(.top, 4)
                        if let o = overviews[t.id], !o.isEmpty {
                            Text(o).font(.body).foregroundStyle(.white.opacity(0.85))
                                .lineLimit(max(2, Int((g.size.height - 190) / 22)))
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.top, 8)
                                .transition(.opacity)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.top, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear
                        .overlay { Artwork(url: art, maxPixel: 1800) }
                        .frame(width: picW, height: picW * 9 / 16)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
                }
                .padding(.leading, 28).padding(.trailing, inset).padding(.vertical, inset)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        #if os(tvOS)
        .modifier(TVFocusTile())
        .onTapGesture { open(t) }
        #else
        .onTapGesture { open(t) }
        .contextMenu { TitleMenu(title: t) }
        #endif
        .task(id: t.id) { await overview(t) }
    }

    #endif

    /// The title's story, from the details kept from an earlier look or read now.
    private func overview(_ t: Title) async {
        guard overviews[t.id] == nil, let c = client else { return }
        if let kept = TitleCache.shared.details(hub: c.sourceID, id: t.id)?.overview {
            overviews[t.id] = kept
            return
        }
        // The Drive library has each story already: no need to read the whole title (its seasons, TMDB's details).
        if let drive = c as? DriveLibrary, let kept = drive.overview(t.id), !kept.isEmpty {
            overviews[t.id] = kept
            return
        }
        guard let d = try? await c.title(t.id) else { return }
        TitleCache.shared.keep(d, hub: c.sourceID, id: t.id)
        withAnimation(.easeOut(duration: 0.3)) { overviews[t.id] = d.overview ?? "" }
    }

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
        #if os(macOS)
        .padding(.trailing, 44).padding(.bottom, 26)
        #else
        #if os(tvOS)
        // Level with Play and Details, at the other side.
        .padding(.trailing, 90).padding(.bottom, 1080 - rowsTop + 66)
        #else
        .padding(.trailing, 30).padding(.bottom, 14)
        #endif
        #endif
        .animation(.snappy, value: page)
    }

    private func card(_ t: Title) -> some View {
        ZStack(alignment: .bottomLeading) {
            Color.clear.overlay { Artwork(url: client?.artURL(t.backdrop ?? t.poster), maxPixel: 1800) }.clipped()
            // Darker toward the bottom, for the words.
            LinearGradient(stops: [.init(color: .clear, location: 0.45), .init(color: .black.opacity(0.8), location: 1)],
                           startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 3) {
                Text(t.title).font(.title3.bold()).foregroundStyle(.white).lineLimit(1).shadow(color: .black.opacity(0.4), radius: 6)
                Text(meta(t)).font(.caption.weight(.medium)).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                // Drawn at 85%, they'd be 34 points tall under a finger: each takes a touch a little past its edge (44).
                HStack(spacing: 8) {
                    if let p = t.play {
                        CapsuleButton(title: p.label ?? "Play", symbol: "play.fill", reach: 6) { PlayRouter.start(p, fleet: fleet) }
                    }
                    CapsuleButton(title: "Details", symbol: nil, prominent: false, reach: 6) { open(t) }
                }
                .controlSize(.small)
                .scaleEffect(0.85, anchor: .leading)
                .padding(.top, 2)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        #if os(tvOS)
        .modifier(TVFocusTile())
        .onTapGesture { open(t) }
        #else
        .onTapGesture { open(t) }
        .contextMenu { TitleMenu(title: t) }
        #endif
    }

    /// Its sheet, with this card's picture and name at the top while the rest loads.
    private func open(_ t: Title) {
        TitleCache.shared.opening(t)
        openTitle(t.id)
    }

    private func meta(_ t: Title) -> String {
        var m: [String] = []
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
    /// The name's size. (Apple TV: 38 points, as the TV app's rows. The phone's style is 57 points on a TV.)
    private var titleFont: Font {
        #if os(tvOS)
        return TVWatch.heading
        #else
        return .title2.bold()
        #endif
    }
    private var chevronFont: Font {
        #if os(tvOS)
        return .system(size: 26, weight: .bold)
        #else
        return .headline.weight(.bold)
        #endif
    }
    /// The shelf's name, with a chevron when it opens everything in it.
    private var heading: some View {
        HStack(spacing: 4) {
            Text(title).font(titleFont)
            Image(systemName: "chevron.right").font(chevronFont).foregroundStyle(.secondary)
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Group {
                if let all {
                    #if os(macOS)
                    // On the Mac's own page stack, so Woodruff's Back button returns from it.
                    PageLink(title) { LibraryGrid(place: all.place, genre: all.genre, sort: all.sort ?? "az") } label: { heading }
                        .buttonStyle(.plain)
                    #else
                    NavigationLink(value: all) { heading }
                        .buttonStyle(.plain)
                    #endif
                } else {
                    Text(title).font(titleFont)
                }
            }
            .padding(.horizontal, 20)
            ScrollView(.horizontal) {
                #if os(tvOS)
                FirstFocusRow(spacing: TVWatch.gap, alignment: .top) { content }
                    .scrollTargetLayout()
                    .padding(.horizontal, 20)
                    .padding(.vertical, 30)
                #else
                LazyHStack(alignment: .top, spacing: 10) { content }
                    .scrollTargetLayout()
                    .padding(.horizontal, 20)
                #endif
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.viewAligned)
            #if os(tvOS)
            .scrollClipDisabled()
            // The whole width is the row's, so Up and Down reach it from anywhere above or below, even when it's
            // only a poster or two (from the right of a longer row, the remote passed it by or stopped).
            .focusSection()
            #endif
        }
    }
}

struct PosterTile: View {
    @Environment(Fleet.self) private var fleet
    @Environment(\.openTitle) private var openTitle
    @Environment(\.zoomNamespace) private var zoom
    @Environment(\.posterWidth) private var fitted
    var title: Title
    /// A width of its own (a grid's), else Watch's (fitted to the window on the Mac).
    var fixedWidth: CGFloat?
    private var width: CGFloat { fixedWidth ?? fitted }
    /// The poster's address as the page worked it out (.none: the tile asks the fleet itself).
    private var given: URL??

    /// A tile whose page has its poster's address already (Watch, Movies and TV Shows, Search): it never looks at the
    /// fleet, so the TVs reporting doesn't redraw it.
    init(title: Title, width: CGFloat? = nil, poster: URL?) {
        self.title = title
        self.fixedWidth = width
        self.given = .some(poster)
    }

    init(title: Title, width: CGFloat? = nil) {
        self.title = title
        self.fixedWidth = width
        self.given = .none
    }

    private var poster: URL? {
        if let given { return given }
        return WatchSources.current(fleet)?.artURL(title.poster)
    }

    var body: some View {
        #if os(tvOS)
        tvLockup
        #else
        Button {
            TitleCache.shared.opening(title)
            openTitle(title.id)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Color.clear.frame(width: width, height: width * 1.5)
                    .overlay { Artwork(url: poster, maxPixel: 512) }
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
                    if let caption = title.caption {
                        Text(caption).font(.caption).foregroundStyle(Color.accentColor).lineLimit(1)
                    }
                }
                .frame(width: width, alignment: .leading)
            }
        }
        .buttonStyle(PressScale(scale: 0.96))
        #if os(macOS)
        .hoverTilt(cornerRadius: 12)
        #endif
        .contextMenu { TitleMenu(title: title) }
        #endif
    }

    #if os(tvOS)
    @Environment(\.displayScale) private var displayScale

    /// Apple TV: the system's own tile, as the TV app's posters. The poster (250 by 375) lifts, tilts and catches the
    /// light under the remote, and its name sits under it on up to two lines, moving out of its way. (It was a
    /// 160-point poster that grew by a tenth, with a name cut to one line.)
    private var tvLockup: some View {
        Button {
            open()
        } label: {
            Color.clear.frame(width: width, height: width * 1.5)
                .overlay { Artwork(url: tvLarge(poster), maxPixel: Int(width * 1.5 * displayScale)) }
                .overlay(alignment: .topTrailing) {
                    if title.watched == true {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 30)).symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.5)).padding(10)
                    }
                }
                .clipped()
                // The view the remote lifts (the style rounds its corners itself).
                .hoverEffect(.highlight)
            VStack(alignment: .leading, spacing: 2) {
                // Two lines kept for every name, so a row's tiles are all one height.
                Text(title.title).font(.caption.weight(.medium)).lineLimit(2, reservesSpace: true).multilineTextAlignment(.leading)
                if let caption = title.caption {
                    Text(caption).font(.caption2).foregroundStyle(Color.accentColor).lineLimit(1)
                }
            }
            .frame(width: width, alignment: .leading)
        }
        .buttonStyle(.borderless)
        // Play/Pause on the remote plays the title it's on, as the TV app does (one with nothing to play yet, a show
        // not started, opens its page).
        .onPlayPauseCommand {
            guard let p = title.play else { open(); return }
            PlayRouter.start(p, fleet: fleet)
        }
        .contextMenu { TitleMenu(title: title) }
    }

    /// Its page, with this tile's picture and name at the top while the rest loads.
    private func open() {
        TitleCache.shared.opening(title)
        openTitle(title.id)
    }
    #endif
}

struct ContinueTile: View {
    @Environment(Fleet.self) private var fleet
    @Environment(\.openTitle) private var openTitle
    @Environment(\.watchChanged) private var watchChanged
    @Environment(\.posterWidth) private var width
    var item: ContinueItem
    /// Its poster's address, as Watch worked it out.
    var poster: URL?
    #if os(tvOS)
    /// Apple TV: its title's wide picture, when it has one (the tile is a still there, as the TV app's Up Next).
    var still: URL? = nil
    @Environment(\.displayScale) private var displayScale
    #endif

    var body: some View {
        #if os(tvOS)
        tvLockup
        #else
        Button {
            PlayRouter.start(item.play, fleet: fleet)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Color.clear.frame(width: width, height: width * 1.5)
                    .overlay { Artwork(url: poster, maxPixel: 512) }
                    .overlay(alignment: .bottom) {
                        VStack(spacing: 8) {
                            Image(systemName: "play.fill").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                                .frame(width: 32, height: 32).glass(Circle(), interactive: false).environment(\.colorScheme, .dark)
                            if item.progress > 0 {
                                Capsule().fill(.white.opacity(0.3)).frame(height: 4)
                                    .overlay(alignment: .leading) { Capsule().fill(.white).frame(width: (width - 16) * item.progress) }
                                    .frame(width: width - 16)
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
                .frame(width: width, alignment: .leading)
            }
        }
        .buttonStyle(PressScale(scale: 0.96))
        .contextMenu { menu }
        #endif
    }

    /// The long-press menu.
    @ViewBuilder private var menu: some View {
        Button(item.play.label ?? "Play") { PlayRouter.start(item.play, fleet: fleet) }
        if let r = item.restart { Button(r.label ?? "Start Over") { PlayRouter.start(r, fleet: fleet, fromStart: true) } }
        PlayOnMenu(action: item.play)
        if let id = item.titleId { Button(item.kind == "show" ? "Episodes" : "Details") { openTitle(id) } }
        Button(role: .destructive) {
            act {
                guard let c = WatchSources.current(fleet) else { throw TVError.notPaired }
                try await c.removeContinue(key: item.key, title: item.playTitle)
                watchChanged(removed: item.key)
            }
        } label: { Text("Remove from Continue Watching") }
    }

    #if os(tvOS)
    /// Apple TV: a wide still (400 by 225), as the TV app's Up Next: the title's own wide picture with how far it got
    /// across its foot, then the name and what's next or what's left under it. The system's own tile, which lifts and
    /// catches the light under the remote. A click goes on from where it got to (it used to open the title's page
    /// under a play symbol; the page is still in the long-press menu), and so does Play/Pause on the remote.
    private var tvLockup: some View {
        let w = TVWatch.still, h = TVWatch.still * 9 / 16
        return Button {
            PlayRouter.start(item.play, fleet: fleet)
        } label: {
            Color.clear.frame(width: w, height: h)
                .overlay {
                    if let still {
                        Artwork(url: still, maxPixel: Int(w * displayScale))
                    } else {
                        // No wide picture: its poster whole, over a soft copy of itself.
                        BlurredArtwork(url: tvLarge(poster), radius: 30, maxPixel: 256)
                        Artwork(url: tvLarge(poster), contentMode: .fit, maxPixel: Int(h * displayScale))
                    }
                }
                .overlay(alignment: .bottom) { if item.progress > 0 { TVProgressFoot(progress: item.progress) } }
                .clipped()
                // The view the remote lifts (the style rounds its corners itself).
                .hoverEffect(.highlight)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.caption.weight(.semibold)).lineLimit(2).multilineTextAlignment(.leading)
                Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            // The same room under every still (a name on two lines fits), so the row's tiles are all one height.
            .frame(width: w, height: TVWatch.continueWords, alignment: .topLeading)
        }
        .buttonStyle(.borderless)
        .onPlayPauseCommand { PlayRouter.start(item.play, fleet: fleet) }
        .contextMenu { menu }
    }
    #endif

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
            Button(p.label ?? "Play") { PlayRouter.start(p, fleet: fleet) }
            if (p.position ?? 0) > 0 { Button("Start Over") { PlayRouter.start(p, fleet: fleet, fromStart: true) } }
            PlayOnMenu(action: p)
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
                    Button("Watch Together on All TVs") { if PlayRouter.together(action, fleet: fleet) { then() } }
                }
            } label: { Text("Play On…") }
        }
    }
}

/// Where a Play goes: the remote's TV (through the hub that holds the library), as the phone page routes it.
@MainActor
enum PlayRouter {
    /// Starts [a] on [tv] (the remote's TV when nil). False when there's nowhere to play it (and says so).
    @discardableResult
    static func start(_ a: PlayAction, fleet: Fleet, on tv: FleetTV? = nil, fromStart: Bool = false) -> Bool {
        // Settings → Watch: Play plays on this device (Play On… still picks a TV).
        if tv == nil, PhonePlayback.playsHere, PhonePlayback.canPlay(a) {
            guard let p = PhonePlayback.play(a, fleet: fleet, fromStart: fromStart) else { return false }
            #if os(iOS) || os(tvOS)
            // The film starts loading at once; Apple's player shows over the topmost screen as soon as the title page
            // that asked has closed.
            NativePlayer.shared.present(p)
            #else
            // In a player window of its own, straight away (it opens over the title page, which closes behind it).
            MacPlayer.shared.present(p)
            #endif
            return true
        }
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

/// A film's or show's page, as a sheet: backdrop, Play, the story, seasons and episodes. Opened again, it shows at once
/// what it showed last time (and reads the title again behind it); opened from a tile, the tile's picture and name are
/// at its top while the rest loads. (On Apple TV it's a page over the whole screen: `tvPage`.)
struct TitleSheet: View {
    @Environment(Fleet.self) private var fleet
    @Environment(\.dismiss) private var dismiss
    @Environment(\.watchChanged) private var watchChanged
    var id: String
    /// The title as the TV answered here (until then, what it said the last time this title was opened shows).
    @State private var d: TitleDetails?
    /// The season picked; nil until the title has been read here (the one the TV suggests: the one in progress).
    @State private var picked: Int?
    @State private var episodes: [Episode] = []
    @State private var loadingEpisodes = false
    /// The season the episodes shown belong to.
    @State private var episodesSeason: String?
    @State private var episodesNote: String?
    /// Why the title couldn't be read (with Try Again, instead of a spinner that never ends).
    @State private var failed: String?
    #if os(macOS)
    /// How tall the sheet's contents are (its window follows them).
    @State private var macContentHeight: CGFloat = 0
    #endif

    private var client: (any WatchSource)? { WatchSources.current(fleet) }

    /// What's shown: the answer read here, else the one kept from the last time this title was opened.
    private func details(_ c: (any WatchSource)?) -> TitleDetails? { d ?? TitleCache.shared.details(hub: c?.sourceID, id: id) }

    /// What Play would play, fetched ahead when it plays here (so it starts the moment Play is pressed).
    private var warmPlay: PlayAction? { details(client)?.play ?? TitleCache.shared.tile(id)?.play }

    /// The season shown: the one picked, else the one the TV suggests.
    private func season(of d: TitleDetails?) -> Int { picked ?? d?.season ?? 0 }

    #if os(tvOS)
    @FocusState private var tvFocus: String?
    #endif

    var body: some View {
        #if os(tvOS)
        tvPage
        #else
        sheetBody
        #endif
    }

    #if os(tvOS)
    /// Apple TV: the title's own page, as the TV app's. Its picture fills the screen; over the lower left are its name,
    /// the lines about it and its story; under them Play (where the remote starts) with Start Over and Play On beside
    /// it; and for a show its episodes (for a collection its films) as one shelf of large stills across the foot of
    /// the screen, starting at the one to watch next, with the season above it. Menu closes it. (It was a card the
    /// width of a phone, with an X in its corner and episodes one at a time.)
    private var tvPage: some View {
        let c = client
        let shown = details(c)
        let season = self.season(of: shown)
        let tile = TitleCache.shared.tile(id)
        let t: SheetTop? = shown.map { top($0, c) } ?? tile.map { top($0, c) }
        let films = shown?.films ?? []
        // What's on the shelf: a collection's films, else the episodes of the season shown.
        let shelf = films.isEmpty ? episodes : films
        // A show or a collection has a shelf across the foot of its page (a show's is known from its tile before the
        // title is read, so the page keeps its place when the episodes arrive).
        let hasShelf = !films.isEmpty || !(shown?.seasons ?? []).isEmpty || (shown == nil && tile?.kind == "show")
        // The one to go on with (what Play plays): the shelf starts there.
        let next = Self.nextUp(shelf, playing: t?.play?.key)
        // Where the remote starts: Play, or what stands in its place while the title is read; with no Play to come (a
        // collection), the one to go on with.
        let startOn: String = t?.play != nil || shown == nil ? "play" : (next ?? "play")
        return VStack(alignment: .leading, spacing: 0) {
            tvWords(t, shown, roomy: !hasShelf)
            tvActions(t, read: shown != nil)
                .padding(.top, 26)
            if hasShelf {
                tvShelf(shown, shelf, next: next, season: season, art: t?.art, c)
                    .padding(.top, 30)
            }
        }
        // At the foot of the screen, from its left edge. (No spacer above the words: one would be given half of the
        // room the buttons and the shelf leave, and the story cut short for it.)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .background { tvBackdrop(t?.art, shelf: hasShelf) }
        .defaultFocus($tvFocus, startOn)
        // Play/Pause plays the title from anywhere on its page (on an episode, that episode).
        .onPlayPauseCommand { if let p = t?.play, PlayRouter.start(p, fleet: fleet) { dismiss() } }
        // Play wasn't known as the page opened (a show not started yet, or a title opened before it was read) and now
        // is: the remote goes to it, unless it has been moved onto something else meanwhile. (The remote used to be
        // left on the X, and the next click closed the card.)
        .onChange(of: t?.play == nil) { wasMissing, missing in
            guard wasMissing, !missing, tvFocus == nil || tvFocus == "play" else { return }
            Task { @MainActor in tvFocus = "play" }
        }
        // No Play to come (a collection): the same for the one to go on with, as soon as it's there (and as the page
        // opens, when it's known already). Only from Play's place or from nowhere: never off something the remote was
        // moved to.
        .onChange(of: next == nil, initial: true) { _, missing in
            guard !missing, shown != nil, t?.play == nil, tvFocus == nil || tvFocus == "play" else { return }
            Task { @MainActor in tvFocus = next }
        }
        .task { await load() }
        .task(id: "\(shown?.id ?? "")|\(season)") { await loadEpisodes() }
        .task(id: warmPlay?.key) { if let p = warmPlay { PhonePlayback.warm(p) } }
        .sheetBanner()
    }

    /// Apple TV: the one to go on with on a shelf: the one Play plays; else the next one, one part watched, or the
    /// first not watched yet (the first of all when every one has been).
    private static func nextUp(_ shelf: [Episode], playing key: String?) -> String? {
        if let key, shelf.contains(where: { $0.key == key }) { return key }
        if let e = shelf.first(where: { $0.upNext == true }) { return e.id }
        if let e = shelf.first(where: { $0.progress > 0 && $0.watched != true }) { return e.id }
        return (shelf.first(where: { $0.watched != true }) ?? shelf.first)?.id
    }

    /// Apple TV: the title's picture across the whole screen, shaded from the left for the words over it, with the
    /// system's material rising from its foot behind the buttons and the shelf, as the TV app's own pages have it.
    private func tvBackdrop(_ art: URL?, shelf: Bool) -> some View {
        // How far up the screen the material is whole (0 to 1 from the bottom): behind a shelf, or only a film's foot.
        let whole: CGFloat = shelf ? 0.54 : 0.12
        return Color.black
            .overlay { Artwork(url: art, maxPixel: 2400) }
            .overlay {
                Rectangle().fill(.regularMaterial)
                    .mask {
                        LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: whole),
                                               .init(color: .black.opacity(0.35), location: whole + 0.12),
                                               .init(color: .clear, location: whole + 0.28)],
                                       startPoint: .bottom, endPoint: .top)
                    }
            }
            .overlay {
                LinearGradient(stops: [.init(color: .black.opacity(0.75), location: 0), .init(color: .black.opacity(0.3), location: 0.5),
                                       .init(color: .clear, location: 0.85)], startPoint: .leading, endPoint: .trailing)
            }
            .clipped()
            .ignoresSafeArea()
    }

    /// Apple TV: the name, the lines about it and the story. [roomy]: a film's page, with no shelf under them.
    private func tvWords(_ t: SheetTop?, _ d: TitleDetails?, roomy: Bool) -> some View {
        let about = d.map { tvAbout($0) } ?? ""
        return VStack(alignment: .leading, spacing: 12) {
            Text(t?.title ?? "")
                .font(.system(size: roomy ? 76 : 60, weight: .heavy))
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.6)
                .shadow(color: .black.opacity(0.5), radius: 12)
            if !about.isEmpty {
                Text(about).font(.system(size: 26, weight: .semibold)).foregroundStyle(.white.opacity(0.9)).lineLimit(1)
            }
            if let f = t?.facts, !f.isEmpty {
                Text(f).font(.system(size: 26, weight: .semibold)).foregroundStyle(.white.opacity(0.75)).lineLimit(2)
            }
            // The story gives way first when the page is full (the lines above it keep their room).
            if let o = d?.overview, !o.isEmpty {
                Text(o).font(.body).foregroundStyle(.white.opacity(0.9)).lineLimit(roomy ? 6 : 3).layoutPriority(-1)
            }
            if roomy, let cast = d?.cast, !cast.isEmpty {
                Text("Starring " + cast.joined(separator: ", ")).font(.caption).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
            }
            if let failed, d == nil {
                Text(failed).font(.body).foregroundStyle(.white.opacity(0.9)).lineLimit(3)
            }
        }
        .frame(maxWidth: 1000, alignment: .leading)
    }

    /// Apple TV: the year, what kind of film or show it is and how well it's rated, on a line of their own.
    private func tvAbout(_ d: TitleDetails) -> String {
        var about: [String] = []
        if let year = d.year { about.append(String(year)) }
        if let genres = d.genres, !genres.isEmpty { about.append(genres.prefix(3).joined(separator: ", ")) }
        if let rating = d.rating { about.append(String(format: "★ %.1f", rating)) }
        return about.joined(separator: " · ")
    }

    /// Apple TV: Play (or Resume), with Start Over and Play On beside it. Play is one button from the moment the page
    /// opens, never rebuilt, so the remote stays on it: it turns while the title is read (a click then does nothing),
    /// and offers Try Again if it can't be. [read]: the title has been read (now or before).
    private func tvActions(_ t: SheetTop?, read: Bool) -> some View {
        HStack(spacing: 24) {
            if t?.play != nil || !read {
                Button {
                    if let p = t?.play {
                        // Closes once the play has gone out; if there's nowhere to play it, stays open and says why.
                        if PlayRouter.start(p, fleet: fleet) { dismiss() }
                    } else if failed != nil {
                        failed = nil
                        Task { await load() }
                    }
                } label: {
                    if let p = t?.play {
                        Label((p.position ?? 0) > 0 ? "Resume" : (p.label ?? "Play"), systemImage: "play.fill")
                    } else if failed != nil {
                        Text("Try Again")
                    } else {
                        ProgressView()
                    }
                }
                .buttonStyle(.glassProminent)
                .focused($tvFocus, equals: "play")
            }
            if let p = t?.play {
                // Part watched: Start Over beside Resume.
                if (p.position ?? 0) > 0 || t?.restart != nil {
                    Button("Start Over") { if PlayRouter.start(t?.restart ?? p, fleet: fleet, fromStart: true) { dismiss() } }
                }
                PlayOnMenu(action: p, then: { dismiss() }).menuStyle(.button)
            }
        }
        .buttonStyle(.glass)
        // A section across the screen: Up from anywhere on the shelf lands here, on Play.
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
    }

    /// Apple TV: the season (a picker when there's more than one), then its episodes as a shelf across the screen. A
    /// collection's films the same way.
    private func tvShelf(_ d: TitleDetails?, _ shelf: [Episode], next: String?, season: Int, art: URL?, _ c: (any WatchSource)?) -> some View {
        let films = d?.films ?? []
        let seasons = d?.seasons ?? []
        // A film has only its name under its still; an episode its number, name and story.
        let words = films.isEmpty ? TVWatch.episodeWords : TVWatch.filmWords
        return VStack(alignment: .leading, spacing: 6) {
            if !films.isEmpty {
                Text("In This Collection").font(TVWatch.heading)
            } else if seasons.count > 1 {
                Picker("Season", selection: Binding(get: { season }, set: { picked = $0 })) {
                    ForEach(Array(seasons.enumerated()), id: \.offset) { i, s in Text(s.name).tag(i) }
                }
                .pickerStyle(.menu)
                .focused($tvFocus, equals: "season")
                // A section across the screen: Up from anywhere on the shelf lands here, not past it.
                .frame(maxWidth: .infinity, alignment: .leading)
                .focusSection()
            } else {
                Text(seasons.first?.name ?? "Episodes").font(TVWatch.heading)
            }
            if !shelf.isEmpty {
                TVEpisodeShelf(items: shelf, next: next, words: words, client: c, fallback: art, focus: $tvFocus,
                               changed: {
                                   watchChanged()
                                   Task { if films.isEmpty { await loadEpisodes() } else { await load() } }
                               },
                               played: { dismiss() })
            } else if let episodesNote, !loadingEpisodes {
                // Why there are none, with a way to ask again.
                VStack(alignment: .leading, spacing: 20) {
                    Text(episodesNote).font(.body).foregroundStyle(.secondary)
                    Button("Try Again") { Task { await loadEpisodes() } }
                        .buttonStyle(.glass)
                        .focused($tvFocus, equals: "again")
                }
                .frame(maxWidth: .infinity, minHeight: TVWatch.shelfHeight(words: words), alignment: .topLeading)
                .focusSection()
            } else {
                // Still being read: the shelf's own shapes, so the page keeps its place when they arrive.
                HStack(alignment: .top, spacing: TVWatch.gap) {
                    ForEach(0..<4, id: \.self) { _ in
                        Placeholder().frame(width: TVWatch.still, height: TVWatch.still * 9 / 16)
                    }
                }
                .padding(.top, TVWatch.shelfLift)
                .frame(height: TVWatch.shelfHeight(words: words), alignment: .top)
                .shimmer()
            }
        }
    }
    #endif

    /// The story and the episodes. On iPhone and iPad each row is built as it scrolls into view (a season is dozens of
    /// rows, each with a picture and a menu, all built as the page opened); elsewhere all at once: the Mac sizes the
    /// page from them, and the Apple TV's focus needs them there.
    @ViewBuilder private func detailStack<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        #if os(iOS)
        LazyVStack(alignment: .leading, spacing: 14) { content() }
        #else
        VStack(alignment: .leading, spacing: 14) { content() }
        #endif
    }

    @ViewBuilder private var sheetBody: some View {
        // Worked out once for the sheet (the episodes' pictures are handed their addresses).
        let c = client
        let shown = details(c)
        let season = self.season(of: shown)
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    if let d = shown {
                        VStack(alignment: .leading, spacing: 0) {
                            header(top(d, c))
                            detailStack {
                                if let o = d.overview { Text(o).font(.body).foregroundStyle(.primary.opacity(0.9)) }
                                if let cast = d.cast, !cast.isEmpty { Text("Starring " + cast.joined(separator: ", ")).font(.footnote).foregroundStyle(.secondary) }
                                if let seasons = d.seasons, !seasons.isEmpty {
                                    Menu {
                                        Picker("Season", selection: Binding(get: { season }, set: { picked = $0 })) {
                                            ForEach(Array(seasons.enumerated()), id: \.offset) { i, s in Text(s.name).tag(i) }
                                        }
                                    } label: {
                                        HStack(spacing: 6) {
                                            Text(seasons[safe: season]?.name ?? "Season").font(.title3.bold())
                                            Image(systemName: "chevron.down").font(.subheadline.weight(.bold)).foregroundStyle(.secondary)
                                        }
                                        .foregroundStyle(.primary)
                                    }
                                    #if os(macOS)
                                    // Just its name and the arrow, lined up with the text above (no pop-up button around it).
                                    .menuStyle(.button)
                                    .buttonStyle(.plain)
                                    .menuIndicator(.hidden)
                                    .fixedSize()
                                    #endif
                                    .padding(.top, 8)
                                    if loadingEpisodes && episodes.isEmpty { ProgressView().frame(maxWidth: .infinity) }
                                    if let episodesNote, episodes.isEmpty && !loadingEpisodes {
                                        Text(episodesNote).font(.subheadline).foregroundStyle(.secondary)
                                        ActionButton(action: { await loadEpisodes() }) { Text("Try Again") }
                                            .buttonStyle(.glass)
                                    }
                                    ForEach(episodes) { e in
                                        EpisodeRow(episode: e, still: c?.artURL(e.still, small: true), show: d.title, poster: d.poster,
                                                   changed: { watchChanged(); Task { await loadEpisodes() } }, played: { dismiss() })
                                    }
                                }
                                if let films = d.films, !films.isEmpty {
                                    Text("In This Collection").font(.title3.bold()).padding(.top, 8)
                                    ForEach(films) { e in
                                        EpisodeRow(episode: e, still: c?.artURL(e.still, small: true), changed: { watchChanged(); Task { await load() } }, played: { dismiss() })
                                    }
                                }
                            }
                            .modifier(SheetSectionPadding())
                        }
                    } else if let t = TitleCache.shared.tile(id) {
                        // Opened from a tile: its picture and name at once, the rest as it arrives.
                        VStack(alignment: .leading, spacing: 0) {
                            header(top(t, c))
                            Group {
                                if let failed {
                                    VStack(alignment: .leading, spacing: 10) {
                                        Text("Can’t Load This Title").font(.headline)
                                        Text(failed).font(.subheadline).foregroundStyle(.secondary)
                                        ActionButton(action: { await load() }) { Text("Try Again") }
                                            .buttonStyle(.glass)
                                    }
                                } else {
                                    ProgressView().frame(maxWidth: .infinity).padding(.top, 20)
                                }
                            }
                            .modifier(SheetSectionPadding())
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
                #if os(macOS)
                // How tall it all is, so the window is as tall as what it shows (up to a point, then it scrolls).
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height.rounded() }) { h in
                    if abs(h - macContentHeight) > 1 { macContentHeight = h }
                }
                #endif
            }
            #if os(macOS)
            // The app's blues behind it, as on Home, Watch and Settings.
            .background { IconBackdrop() }
            #endif
            .ignoresSafeArea(edges: .top)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(role: .close) { dismiss() } } }
            .task { await load() }
            // The episodes of the season picked (and of the first one shown, as soon as the title shows).
            .task(id: "\(shown?.id ?? "")|\(season)") { await loadEpisodes() }
            // Its Play made ready to start at once.
            .task(id: warmPlay?.key) { if let p = warmPlay { PhonePlayback.warm(p) } }
        }
        // Errors from here (a play that failed, Mark as Watched) show over the sheet, not hidden behind it.
        .sheetBanner()
        #if os(macOS)
        // Light text on the blues, as everywhere else in the app.
        .environment(\.colorScheme, .dark)
        .frame(width: Self.macWidth, height: macHeight)
        #endif
    }

    #if os(macOS)
    /// The Mac's window: as wide as a 16:9 banner reads well, and as tall as what it shows, between a floor (so a
    /// title still loading isn't a sliver) and most of the screen.
    static let macWidth: CGFloat = 700
    private var macHeight: CGFloat {
        let screen = (NSScreen.main?.visibleFrame.height ?? 900) - 120
        let tallest = max(480, min(860, screen))
        return min(tallest, max(480, macContentHeight))
    }
    #endif

    private func top(_ d: TitleDetails, _ c: (any WatchSource)?) -> SheetTop {
        SheetTop(title: d.title, art: c?.artURL(d.backdrop ?? d.poster), facts: facts(d), play: d.play, restart: d.restart,
                 isFilm: d.kind == "movie", poster: d.poster)
    }

    /// The top as the tile it was opened from knew it (its year: the rest of the line comes with the details).
    private func top(_ t: Title, _ c: (any WatchSource)?) -> SheetTop {
        SheetTop(title: t.title, art: c?.artURL(t.backdrop ?? t.poster), facts: "", play: t.play, restart: nil,
                 isFilm: t.kind == "movie", poster: t.poster)
    }

    @ViewBuilder private func header(_ top: SheetTop) -> some View {
        #if os(macOS)
        // The Mac: the picture as a 16:9 banner across the top, then the name, the line about it and the buttons
        // under it, on the same edge as everything below.
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.aspectRatio(16.0 / 9.0, contentMode: .fit)
                .overlay { Artwork(url: top.art, maxPixel: 1800) }
                .overlay {
                    LinearGradient(stops: [.init(color: .clear, location: 0.6), .init(color: .black.opacity(0.35), location: 1)], startPoint: .top, endPoint: .bottom)
                }
                .clipped()
            VStack(alignment: .leading, spacing: 8) {
                Text(top.title)
                    .font(.largeTitle.bold())
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if !top.facts.isEmpty {
                    Text(top.facts).font(.subheadline.weight(.medium)).foregroundStyle(.white.opacity(0.75))
                }
                playButtons(top).padding(.top, 6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 20)
        }
        #else
        ZStack(alignment: .bottomLeading) {
            Color.clear.aspectRatio(0.95, contentMode: .fit)
                .overlay { Artwork(url: top.art, maxPixel: 1800) }
                .clipped()
            LinearGradient(stops: [.init(color: .clear, location: 0.3), .init(color: .black.opacity(0.9), location: 1)], startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 8) {
                Text(top.title).font(.largeTitle.bold()).foregroundStyle(.white)
                Text(top.facts).font(.footnote.weight(.medium)).foregroundStyle(.white.opacity(0.75))
                playButtons(top).padding(.top, 4)
            }
            .padding(20)
        }
        #endif
    }

    /// Play, Start Over and Play On.
    private func playButtons(_ top: SheetTop) -> some View {
        HStack(spacing: 10) {
            // Closes once the play has gone out; if there's nowhere to play it, stays open and says why.
            if let p = top.play { CapsuleButton(title: p.label ?? "Play", symbol: "play.fill") { if PlayRouter.start(p, fleet: fleet) { dismiss() } } }
            if let r = top.restart {
                Button { if PlayRouter.start(r, fleet: fleet, fromStart: true) { dismiss() } } label: {
                    Image(systemName: "arrow.counterclockwise").font(.headline).foregroundStyle(.white)
                        .frame(width: 40, height: 40).glass(Circle()).environment(\.colorScheme, .dark)
                }
                .buttonStyle(PressScale())
                .accessibilityLabel(r.label ?? "Start Over")
                #if os(macOS)
                .help(r.label ?? "Start Over")
                #endif
            }
            if let p = top.play { PlayOnButton(action: p, film: top.isFilm ? top.title : nil, poster: top.poster, then: { dismiss() }) }
        }
    }

    private func facts(_ d: TitleDetails) -> String {
        var f: [String] = []
        if let name = d.playName, let code = d.play?.title { f.append("\(code) · \(name)") }
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
            TitleCache.shared.keep(t, hub: c.sourceID, id: id)
            withAnimation(.smooth) { d = t }
            failed = nil
            // The season the TV suggests (the one in progress), the first time only: a reload keeps the one picked.
            if picked == nil { picked = t.season ?? 0 }
        } catch {
            if Task.isCancelled { return }
            if details(c) == nil { failed = error.localizedDescription } else { fleet.show(error) }
        }
    }

    private func loadEpisodes() async {
        guard let c = client, let d = details(c), let s = d.seasons?[safe: season(of: d)] else { return }
        // Another season: its episodes as they were last time (or none, never the last season's) while they're read.
        if episodesSeason != s.id {
            let kept = TitleCache.shared.episodes(hub: c.sourceID, show: d.id, season: s.id)
            episodes = kept ?? []
            episodesSeason = kept == nil ? nil : s.id
        }
        episodesNote = nil
        loadingEpisodes = true
        // Not when another season was picked meanwhile: its own read is still going.
        defer { if !Task.isCancelled { loadingEpisodes = false } }
        do {
            let list = try await c.episodes(show: d.id, season: s.id)
            guard !Task.isCancelled else { return }
            if !list.episodes.isEmpty { TitleCache.shared.keep(list.episodes, hub: c.sourceID, show: d.id, season: s.id) }
            withAnimation(.smooth) { episodes = list.episodes }
            episodesSeason = s.id
            if list.episodes.isEmpty {
                episodesNote = list.state == "loading" ? "The library is still getting these episodes ready." : "No episodes in \(s.name)."
            }
        } catch {
            if Task.isCancelled { return }
            episodesNote = error.localizedDescription
        }
    }
}

/// The padding around a title sheet's details: on the Mac, the same edge as its name and buttons above.
private struct SheetSectionPadding: ViewModifier {
    func body(content: Content) -> some View {
        #if os(macOS)
        content.padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 24)
        #else
        content.padding(20)
        #endif
    }
}

/// The top of a title's sheet: its picture, its name, a line about it, and Play.
private struct SheetTop {
    var title: String
    var art: URL?
    var facts: String
    var play: PlayAction?
    var restart: PlayAction?
    /// A film (not a show or a collection), and its poster: for Download in its menu on iPhone and iPad.
    var isFilm = false
    var poster: String? = nil
}

/// "…" beside Play, with Play On, when there's more than one TV; on iPhone and iPad also with Download, for a film that
/// can be kept on the device. A view of its own: it follows the TVs (they report every couple of seconds) without the
/// whole sheet redrawing with them.
private struct PlayOnButton: View {
    @Environment(Fleet.self) private var fleet
    var action: PlayAction
    /// The film's name (nil for a show: its episodes each have Download in their own menus) and its poster.
    var film: String? = nil
    var poster: String? = nil
    var then: () -> Void

    var body: some View {
        if fleet.tvs.filter({ !$0.isUnpaired }).count > 1 || downloadable {
            Menu {
                PlayOnMenu(action: action, then: then)
                #if os(iOS)
                if let film { DownloadMenuItem(play: action, name: film, poster: poster) }
                #endif
            } label: {
                Image(systemName: "ellipsis").font(.headline).foregroundStyle(.white).frame(width: 40, height: 40).glass(Circle()).environment(\.colorScheme, .dark)
            }
            .menuStyle(.button).buttonStyle(.plain)
            #if os(iOS)
            .accessibilityLabel("More")
            #else
            .accessibilityLabel("Play On…")
            #endif
        }
    }

    /// A film that can be kept on this device (iPhone and iPad): the menu is there for its Download even with one TV.
    private var downloadable: Bool {
        #if os(iOS)
        return film != nil && DownloadMenuItem.offered(action)
        #else
        return false
        #endif
    }
}

/// Titles as their sheets last showed them, so one opened again shows at once (and is read again behind it), and the
/// tiles sheets are opened from, for a sheet's top while the rest loads. The last 50 of each.
@MainActor
final class TitleCache {
    static let shared = TitleCache()
    private var kept = Recent<TitleDetails>(limit: 50)
    private var keptEpisodes = Recent<[Episode]>(limit: 50)
    private var tiles = Recent<Title>(limit: 50)

    func details(hub: String?, id: String) -> TitleDetails? { kept["\(hub ?? "")|\(id)"] }
    func keep(_ d: TitleDetails, hub: String, id: String) { kept.put("\(hub)|\(id)", d) }

    func episodes(hub: String, show: String, season: String) -> [Episode]? { keptEpisodes["\(hub)|\(show)|\(season)"] }
    func keep(_ e: [Episode], hub: String, show: String, season: String) { keptEpisodes.put("\(hub)|\(show)|\(season)", e) }

    /// A tile is opening its title's sheet.
    func opening(_ t: Title) { tiles.put(t.id, t) }
    func tile(_ id: String) -> Title? { tiles[id] }
}

/// The last [limit] things kept, by key (the oldest goes first).
private struct Recent<Value> {
    private var values: [String: Value] = [:]
    private var order: [String] = []
    let limit: Int

    init(limit: Int) { self.limit = limit }

    subscript(key: String) -> Value? { values[key] }

    mutating func put(_ key: String, _ value: Value) {
        if values.updateValue(value, forKey: key) != nil { order.removeAll { $0 == key } }
        order.append(key)
        if order.count > limit { values[order.removeFirst()] = nil }
    }
}

#if os(tvOS)
/// Apple TV: a title's episodes (or a collection's films) as one shelf of large stills across the screen. It starts at
/// the one to watch next: that one is at the shelf's left edge, under Play, so the remote lands on it coming down.
private struct TVEpisodeShelf: View {
    var items: [Episode]
    /// The one to start at.
    var next: String?
    /// How tall the words under each still are (every tile the same).
    var words: CGFloat
    var client: (any WatchSource)?
    /// The picture for one with no still of its own: the title's.
    var fallback: URL?
    /// The page's focus: each tile is known to it by its episode.
    var focus: FocusState<String?>.Binding
    var changed: () -> Void
    var played: () -> Void
    /// The one at the shelf's left edge.
    @State private var atEdge: String?

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: TVWatch.gap) {
                ForEach(items) { e in
                    EpisodeRow(episode: e, still: tvLarge(client?.artURL(e.still)) ?? fallback, changed: changed, played: played, wordsHeight: words)
                        .focused(focus, equals: e.id)
                }
            }
            .scrollTargetLayout()
            // Room over the stills for the one under the remote to lift into.
            .padding(.top, TVWatch.shelfLift)
        }
        .scrollPosition(id: $atEdge, anchor: .leading)
        .scrollTargetBehavior(.viewAligned)
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
        // As tall as its tiles (a lazy row otherwise takes all the height the page has left).
        .fixedSize(horizontal: false, vertical: true)
        // The whole width is the shelf's, so Down reaches it from any button above it.
        .focusSection()
        // A new list (the title read, another season picked): from the one to watch next.
        .onChange(of: items.map(\.id), initial: true) { _, _ in atEdge = next }
    }
}
#endif

struct EpisodeRow: View {
    @Environment(Fleet.self) private var fleet
    var episode: Episode
    /// Its picture's address, as the sheet worked it out.
    var still: URL? = nil
    /// The show it's an episode of and that show's poster, for Download in its menu (iPhone and iPad). Without them
    /// (a film in a collection) there's no Download.
    var show: String? = nil
    var poster: String? = nil
    var changed: () -> Void
    /// A play went out (the title's sheet closes, so what's playing shows).
    var played: () -> Void = {}
    #if os(tvOS)
    /// Apple TV: how tall the words under its still are.
    var wordsHeight: CGFloat = TVWatch.episodeWords
    @Environment(\.displayScale) private var displayScale
    #endif

    private var action: PlayAction {
        PlayAction(key: episode.key, title: episode.playTitle, position: episode.position, label: nil, duration: episode.duration, resume: true, latest: nil)
    }

    #if os(tvOS)
    /// Apple TV: a large still (400 by 225) with the episode's number, its name and its story under it: the system's
    /// own tile, which lifts and catches the light under the remote. A click plays it. (It was a row the width of a
    /// phone, with a 132-point still and a play symbol.)
    var body: some View {
        let w = TVWatch.still, h = TVWatch.still * 9 / 16
        Button { if PlayRouter.start(action, fleet: fleet) { played() } } label: {
            Color.clear.frame(width: w, height: h)
                .overlay { Artwork(url: still, maxPixel: Int(w * displayScale)) }
                .overlay(alignment: .topTrailing) {
                    if episode.watched == true {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 30)).symbolRenderingMode(.palette)
                            .foregroundStyle(.black, .white).padding(10)
                    }
                }
                .overlay(alignment: .bottom) {
                    if episode.progress > 0 && episode.watched != true { TVProgressFoot(progress: episode.progress) }
                }
                .clipped()
                // The view the remote lifts (the style rounds its corners itself).
                .hoverEffect(.highlight)
            // The same height under every still, so the shelf's tiles line up: the story takes what the name leaves.
            VStack(alignment: .leading, spacing: 4) {
                if !caption.isEmpty {
                    Text(caption).font(.caption2.weight(.semibold)).foregroundStyle(episode.new == true ? Color.accentColor : .secondary)
                        .textCase(.uppercase).lineLimit(1)
                }
                Text(episode.name).font(.caption.weight(.semibold)).lineLimit(2).multilineTextAlignment(.leading)
                if let o = episode.overview {
                    Text(o).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.leading).layoutPriority(-1)
                }
            }
            .frame(width: w, height: wordsHeight, alignment: .topLeading)
        }
        .buttonStyle(.borderless)
        // Play/Pause plays this episode, as a click does (not the show's own Play, which the page's Play/Pause plays).
        .onPlayPauseCommand { if PlayRouter.start(action, fleet: fleet) { played() } }
        .contextMenu {
            Button("Play from the Start") { if PlayRouter.start(action, fleet: fleet, fromStart: true) { played() } }
            PlayOnMenu(action: action, then: played)
        }
    }
    #else
    var body: some View {
        Button { if PlayRouter.start(action, fleet: fleet) { played() } } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 14) {
                    Color.clear.frame(width: 132, height: 74)
                        .overlay { Artwork(url: still, maxPixel: 512) }
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
            Button("Play from the Start") { if PlayRouter.start(action, fleet: fleet, fromStart: true) { played() } }
            PlayOnMenu(action: action, then: played)
            #if os(iOS)
            if let show {
                DownloadMenuItem(play: action, name: show, detail: [episode.code, episode.name].compactMap { $0 }.joined(separator: " · "), poster: poster)
            }
            #endif
        }
    }
    #endif

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

    init(place: String, genre: String? = nil, sort: String = "az") {
        self.place = place
        _genre = State(initialValue: genre)
        _sort = State(initialValue: sort)
    }
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
    /// The sorting and filters of what's shown now (the same again when the page comes back: nothing is started over).
    @State private var shownKey: String?
    @State private var failed: String?
    /// The posters of the page just read, being fetched before they're scrolled to.
    @State private var warming: Task<Void, Never>?

    private var heading: String { place == "shows" ? "TV Shows" : "Movies" }
    private var filtered: Bool { unwatched || genre != nil || !query.isEmpty }

    var body: some View {
        // Worked out once for the page: the tiles are handed their posters' addresses.
        let client = WatchSources.current(fleet)
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
            #if os(tvOS)
            // Apple TV: the same posters as Watch's rows (250 by 375), six across, with room around each for it to lift
            // under the remote. (They were 104 points across, under a search keyboard.)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: TVWatch.poster, maximum: TVWatch.poster), spacing: TVWatch.gap, alignment: .top)], spacing: 50) {
                ForEach(items) { t in
                    PosterTile(title: t, width: TVWatch.poster, poster: client?.artURL(t.poster))
                        .onAppear { nearEnd(t) }
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 30)
            #else
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104, maximum: 150), spacing: 12, alignment: .top)], spacing: 18) {
                ForEach(items) { t in
                    PosterTile(title: t, width: 104, poster: client?.artURL(t.poster))
                        .onAppear { nearEnd(t) }
                }
            }
            .padding(16)
            #endif
            if loading { ProgressView().padding() }
        }
        .navigationTitle(heading)
        #if os(macOS)
        .pageSearch(text: $query, prompt: heading) { filterMenu }
        #elseif !os(tvOS)
        // (Not on Apple TV: no keyboard over the posters there. Search is its own tab in the sidebar.)
        .pageSearch(text: $query, prompt: heading)
        #endif
        .environment(\.openTitle, OpenTitleAction { openTitle = $0 })
        // Marked watched here: the checkmarks (and an Unwatched list) follow at once, and so does Watch.
        .environment(\.watchChanged, WatchChanged { key in
            watchChanged(removed: key)
            Task { await reloadShown() }
        })
        .titleSheet(Binding(get: { openTitle.map { TitleRef(id: $0) } }, set: { openTitle = $0?.id })) { TitleSheet(id: $0.id) }
        #if os(iOS) || os(tvOS)
        .toolbar { filterMenu }
        #endif
        .task(id: "\(sort)|\(unwatched)|\(genre ?? "")|\(query)") {
            // Back on this page with nothing changed (another tab and back): what's shown stays where it was scrolled
            // to and is read again in place, instead of starting over from the first page.
            let key = "\(sort)|\(unwatched)|\(genre ?? "")|\(query)"
            if loaded, !items.isEmpty, key == shownKey {
                await reloadShown()
                return
            }
            // The first page at once; after that a moment's wait, so typing asks only for the newest choice.
            if loaded || !items.isEmpty || failed != nil {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }
            await load(more: false)
            if !Task.isCancelled { shownKey = key }
        }
        .onDisappear { warming?.cancel() }
    }

    /// One of the last tiles came into view: the next page is read now, before the bottom is reached.
    private func nearEnd(_ t: Title) {
        guard !loading, items.count < count, let i = items.lastIndex(where: { $0.id == t.id }), i >= items.count - 15 else { return }
        Task { await load(more: true) }
    }

    private func load(more: Bool) async {
        guard let c = WatchSources.current(fleet) else { failed = TVError.notPaired.localizedDescription; return }
        if more {
            guard !loading, items.count < count else { return }
        } else {
            generation += 1
            warming?.cancel()
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
            if more { warm(p.items, c) }
        } catch {
            guard gen == generation, !Task.isCancelled else { return }
            if items.isEmpty { failed = error.localizedDescription } else { fleet.show(error) }
        }
    }

    /// The page just read (below what's on screen): its posters are downloaded a few at a time, so they're there by the
    /// time it's scrolled to.
    private func warm(_ titles: [Title], _ c: any WatchSource) {
        #if os(tvOS)
        // The copies Apple TV's posters are drawn from (`tvLarge`).
        let urls = titles.compactMap { tvLarge(c.artURL($0.poster)) }
        #else
        let urls = titles.compactMap { c.artURL($0.poster) }
        #endif
        warming?.cancel()
        warming = Task(priority: .utility) {
            await withTaskGroup(of: Void.self) { g in
                for (i, u) in urls.enumerated() {
                    if i >= 3 { _ = await g.next() }
                    if Task.isCancelled { break }
                    g.addTask(priority: .utility) { await ImageStore.shared.prefetch(u) }
                }
            }
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
        .accessibilityLabel("Filter and Sort")
    }

    /// Asks again for everything shown (a title was just marked watched), keeping the place in the list.
    private func reloadShown() async {
        guard let c = WatchSources.current(fleet), !items.isEmpty else { return }
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

/// Search Movies and TV Shows: the Search tab's page on iPhone and iPad. Its field is iOS's own for a Search tab (where
/// the tab bar is on iPhone, at the top of the page on iPad); what's typed shows its results as shelves.
struct SearchPage: View {
    @Environment(Fleet.self) private var fleet
    @Environment(\.watchChanged) private var watchChanged
    @State private var query = ""
    @State private var openTitle: String?
    /// Asked again (a result was marked watched).
    @State private var again = 0
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Namespace private var zoom
    /// The posters' width: as Watch's own (112 on iPhone; fitted to the page on iPad).
    @State private var posterWidth: CGFloat = 112
    #endif

    var body: some View {
        ScrollView {
            WatchSearchResults(query: query, again: again).padding(.vertical)
        }
        .navigationTitle("Search")
        #if os(iOS)
        .searchable(text: $query, prompt: "Movies and TV Shows")
        .autocorrectionDisabled()
        // Scrolling the results puts the keyboard away.
        .scrollDismissesKeyboard(.immediately)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { w in fitPosters(w) }
        .environment(\.posterWidth, posterWidth)
        #else
        .pageSearch(text: $query, prompt: "Movies and TV Shows")
        #endif
        // Before what follows, so a title's sheet has them too (marked watched there, the results are asked again).
        .titleSheet(Binding(get: { openTitle.map { TitleRef(id: $0) } }, set: { openTitle = $0?.id })) { (ref: TitleRef) in
            #if os(iOS)
            TitleSheet(id: ref.id).zoomDestination(ref.id, zoom)
            #else
            TitleSheet(id: ref.id)
            #endif
        }
        .environment(\.openTitle, OpenTitleAction { openTitle = $0 })
        #if os(iOS)
        .environment(\.zoomNamespace, zoom)
        #endif
        .environment(\.watchChanged, WatchChanged { key in
            watchChanged(removed: key)
            again += 1
        })
    }

    #if os(iOS)
    /// Posters as wide as Watch's: on iPad about 160 points each, as many as fit the page; 112 on iPhone.
    private func fitPosters(_ w: CGFloat) {
        guard sizeClass == .regular else { if posterWidth != 112 { posterWidth = 112 }; return }
        let fit = fittedPosterWidth(w, target: 160)
        if abs(fit - posterWidth) > 0.5 { posterWidth = fit }
    }
    #endif
}

/// What [query] finds in Movies and TV Shows, as shelves (or why nothing came back). Opening a title is the page's
/// (its `openTitle`). [again]: asked again when it changes.
struct WatchSearchResults: View {
    @Environment(Fleet.self) private var fleet
    var query: String
    var again = 0
    @State private var r: SearchResults?
    @State private var failed: String?

    var body: some View {
        // Worked out once: the tiles are handed their posters' addresses.
        let client = WatchSources.current(fleet)
        VStack(alignment: .leading, spacing: 26) {
            if !query.isEmpty, let failed {
                EmptyState(symbol: "wifi.exclamationmark", title: "Can’t Search", message: failed).padding(.top, 60)
            } else if let r, !query.isEmpty {
                let sections = r.first == "shows" ? [("TV Shows", r.shows), ("Movies", r.movies)] : [("Movies", r.movies), ("TV Shows", r.shows)]
                ForEach(sections, id: \.0) { name, list in
                    if !list.isEmpty { ShelfRow(name) { ForEach(list) { PosterTile(title: $0, poster: client?.artURL($0.poster)) } } }
                }
                if r.movies.isEmpty && r.shows.isEmpty {
                    EmptyState(symbol: "magnifyingglass", title: "No Results", message: "Nothing in Movies or TV Shows matches “\(query)”.")
                        .padding(.top, 60)
                }
            } else if query.isEmpty {
                EmptyState(symbol: "magnifyingglass", title: "Search the Library", message: "Find a film or show in Movies and TV Shows.").padding(.top, 60)
            } else {
                ProgressView().frame(maxWidth: .infinity).padding(.top, 60)
            }
        }
        .task(id: "\(query)|\(again)") {
            guard !query.isEmpty else { r = nil; failed = nil; return }
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            guard let c = WatchSources.current(fleet) else { failed = TVError.notPaired.localizedDescription; return }
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
        #if os(tvOS)
        // Apple TV: two rows of its own posters, under where the banner will be. (The phone's shapes were drawn
        // there: a billboard taller than the screen.)
        VStack(alignment: .leading, spacing: 28) {
            ForEach(0..<2, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 40) {
                    Placeholder(corner: 8).frame(width: 320, height: 38)
                    HStack(spacing: TVWatch.gap) {
                        ForEach(0..<6, id: \.self) { _ in Placeholder().frame(width: TVWatch.poster, height: TVWatch.poster * 1.5) }
                    }
                }
                .padding(.horizontal, 20)
            }
        }
        .padding(.top, TVWatch.postersTop)
        .shimmer()
        .accessibilityLabel("Loading")
        #else
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
        #endif
    }
}


/// The banner's five and the rows for a list, kept until the list (or what's in Continue Watching) changes.
final class ShelfCache {
    struct Worked {
        var featured: [Title]; var rows: [(name: String, genre: String?, titles: [Title])]
        #if os(tvOS)
        /// Apple TV: each title's wide picture, by title (Continue Watching's stills).
        var wide: [String: String] = [:]
        #endif
    }
    private var lastTitles: [Title] = []
    private var lastShown: Set<String> = []
    private var lastDay = -1
    private var lastPlace = ""
    private var value = Worked(featured: [], rows: [])

    /// Worked out again when anything about a title changes (a poster, a rating), not only the list's length.
    func get(place: String, titles: [Title], shown: Set<String>) -> Worked {
        let day = Calendar.current.ordinality(of: .day, in: .era, for: Date()) ?? 0
        if titles != lastTitles || shown != lastShown || day != lastDay || place != lastPlace {
            lastTitles = titles; lastShown = shown; lastDay = day; lastPlace = place
            value = Worked(featured: WatchRows.featured(titles, section: place), rows: WatchRows.rows(titles, shown: shown))
            #if os(tvOS)
            value.wide = Dictionary(titles.compactMap { t in t.backdrop.map { (t.id, $0) } }, uniquingKeysWith: { first, _ in first })
            #endif
        }
        return value
    }
}

/// Each library's titles (the banner's and the rows' source) as Watch last read them, kept on disk in the Watch
/// folder (Application Support; Caches on Apple TV), which an app update leaves alone. Watch opens with its rows from
/// here at once and reads them again behind them, instead of waiting for the whole library, a page at a time.
final class ShelfStore: @unchecked Sendable {
    static let shared = ShelfStore()

    private struct Kept: Codable {
        var lists: [String: [Title]] = [:]
        /// The keys, the newest last (only the last few libraries are kept).
        var order: [String] = []
    }
    private let file = watchFile("shelves.json")
    private let lock = NSLock()
    private var kept = Kept()
    private var reading: Task<Void, Never>?

    /// Starts reading the file in the background, as the app opens.
    static func prewarm() { _ = shared.read() }

    private func read() -> Task<Void, Never> {
        lock.lock()
        defer { lock.unlock() }
        if let reading { return reading }
        let file = self.file
        let t = Task.detached(priority: .userInitiated) { [self] in
            guard let d = try? Data(contentsOf: file, options: .mappedIfSafe),
                  let k = try? JSONDecoder().decode(Kept.self, from: d) else { return }
            merge(k)
        }
        reading = t
        return t
    }

    /// What was on disk, under anything kept since the app opened (that's newer).
    private func merge(_ k: Kept) {
        lock.lock()
        defer { lock.unlock() }
        for key in k.order.reversed() where kept.lists[key] == nil {
            guard let list = k.lists[key] else { continue }
            kept.lists[key] = list
            kept.order.insert(key, at: 0)
        }
    }

    private func get(_ key: String) -> [Title]? {
        lock.lock()
        defer { lock.unlock() }
        return kept.lists[key]
    }

    /// [place]'s titles from [source] as last kept (read off the main thread).
    func titles(source: String, place: String) async -> [Title]? {
        await read().value
        return get(source + "|" + place)
    }

    /// Keeps [titles] for next time (written in the background, only when they changed).
    func keep(_ titles: [Title], source: String, place: String) {
        let key = source + "|" + place
        lock.lock()
        if kept.lists[key] == titles { lock.unlock(); return }
        kept.lists[key] = titles
        kept.order.removeAll { $0 == key }
        kept.order.append(key)
        while kept.order.count > 6 { kept.lists[kept.order.removeFirst()] = nil }
        let snapshot = kept
        lock.unlock()
        DiskWriter.write(snapshot, to: file)
    }
}

/// Watch's first pictures fetched while the app opens (when the library the app keeps is Watch's own): the titles at
/// the top and Continue Watching on disk, and the first few posters ready to draw, so Watch opens with its pictures.
@MainActor
enum WatchPrefetch {
    private static var done = false

    static func start(_ fleet: Fleet) {
        guard !done, !Demo.isOn else { return }
        done = true
        ShelfStore.prewarm()
        Task {
            // The Drive library (and the Apple TV, which uses it whenever it's signed in): the banner's first picture
            // and the first row's posters from the rows kept last time.
            if WatchSources.usesDrive {
                await warmKept(source: DriveLibrary.shared.sourceID, client: DriveLibrary.shared)
                return
            }
            // The library comes with the TVs' first answers: a little while at most.
            for _ in 0..<40 where fleet.library == nil { try? await Task.sleep(nanoseconds: 500_000_000) }
            guard let h = fleet.library, let client = WatchSources.current(fleet),
                  fleet.libraryFrom == client.sourceID else { return }
            let continuing = (h.continue ?? []).prefix(8).compactMap { client.artURL($0.poster) }
            let top = (h.featured ?? []).prefix(3).compactMap { client.artURL($0.backdrop ?? $0.poster) }
            let recent = (h.recent ?? []).prefix(12).compactMap { client.artURL($0.poster) }
            // The ones seen first, ready to draw; the rest only downloaded.
            for u in continuing.prefix(6) { _ = await ImageStore.shared.image(u, maxPixel: 512) }
            if let first = top.first { _ = await ImageStore.shared.image(first, maxPixel: 1800) }
            for u in Array(continuing.dropFirst(6)) + Array(top.dropFirst()) + recent { await ImageStore.shared.prefetch(u) }
            await warmKept(source: client.sourceID, client: client)
        }
    }

    /// The section Watch opens on, from the rows kept last time: its banner's first picture and the first row's
    /// first posters ready to draw, the rest of that row downloaded.
    private static func warmKept(source: String, client: any WatchSource) async {
        let place = UserDefaults.standard.string(forKey: "watch.section") == "shows" ? "shows" : "movies"
        guard let titles = await ShelfStore.shared.titles(source: source, place: place), !titles.isEmpty else { return }
        let banner = WatchRows.featured(titles, section: place).first.flatMap { client.artURL($0.backdrop ?? $0.poster) }
        #if os(tvOS)
        // Apple TV: the copies its posters are drawn from (`tvLarge`), made ready at the size they're drawn at on a
        // 4K screen, and the banner's picture at the size its banner asks for.
        let first = (WatchRows.rows(titles).first?.titles ?? []).prefix(14).compactMap { tvLarge(client.artURL($0.poster)) }
        if let banner { _ = await ImageStore.shared.image(banner, maxPixel: 2400) }
        for u in first.prefix(6) { _ = await ImageStore.shared.image(u, maxPixel: 1024) }
        #else
        let first = (WatchRows.rows(titles).first?.titles ?? []).prefix(14).compactMap { client.artURL($0.poster) }
        if let banner { _ = await ImageStore.shared.image(banner, maxPixel: 1800) }
        for u in first.prefix(6) { _ = await ImageStore.shared.image(u, maxPixel: 512) }
        #endif
        for u in first.dropFirst(6) { await ImageStore.shared.prefetch(u) }
    }
}


#if os(macOS)
/// Whether Watch's row in the Mac's top bar (Movies | TV Shows, search, the TV) is faded away: it goes as the page
/// scrolls down and comes back as it scrolls up or nears the top. Only set when that changes, so the bar isn't
/// drawn again while scrolling.
@Observable @MainActor
final class MacWatchScroll {
    static let shared = MacWatchScroll()
    private(set) var barHidden = false
    /// How far the page has gone in one direction (down positive), since it last turned.
    @ObservationIgnored private var travel: CGFloat = 0

    func follow(from old: CGFloat, to new: CGFloat) {
        // Near the top: always there.
        if new < 40 { travel = 0; set(false); return }
        let step = new - old
        guard step != 0 else { return }
        if (step > 0) != (travel > 0) { travel = 0 }
        travel += step
        if travel > 24 { set(true) } else if travel < -24 { set(false) }
    }

    func reset() {
        travel = 0
        set(false)
    }

    private func set(_ hidden: Bool) {
        guard hidden != barHidden else { return }
        withAnimation(.smooth(duration: 0.3)) { barHidden = hidden }
    }
}
#endif

/// Fetches a shelf's posters ahead of being scrolled to, a few at a time, onto disk (not into memory).
enum ShelfWarmer {
    static func warm(_ urls: [URL]) async {
        #if os(tvOS)
        // The copies Apple TV's posters are drawn from (`tvLarge`).
        let urls = urls.map { tvLarge($0) ?? $0 }
        #endif
        await withTaskGroup(of: Void.self) { g in
            for (i, u) in urls.enumerated() {
                if i >= 3 { _ = await g.next() }
                if Task.isCancelled { break }
                g.addTask(priority: .utility) { await ImageStore.shared.prefetch(u) }
            }
        }
    }
}
