import SwiftUI
import WoodruffKit

/// Home (Mac), like Apple's Home app: what's going on across the house at a glance, a large tile for every TV
/// with what it's playing and its controls, and actions for all of them. The remote slides out on the right.
struct HomeView: View {
    @Environment(Fleet.self) private var fleet
    @State private var openTV: String?
    /// The room bar's choice: Favorites (first, and where Home opens), All Rooms (""), or a room.
    @AppStorage("home.room2") private var picked = favoritesKey
    /// The TV whose player is open (iPhone: tapping a TV opens straight into what it's playing).
    @State private var playerTV: String?
    @Namespace private var zoom
    private let layout = HomeLayout.shared

    /// What Home shows for the room bar's choice. A room with nothing in it just now (its cameras or linked TVs
    /// still loading at launch, say) shows All Rooms until it's back, without forgetting the choice; with the room
    /// bar hidden there's no way to pick a room, so everything shows.
    private var room: String {
        if layout.hiddenSections.contains("rooms") { return "" }
        return picked == favoritesKey || picked.isEmpty || rooms.contains(picked) ? picked : ""
    }

    #if os(macOS)
    private let columns = [GridItem(.adaptive(minimum: 400), spacing: 22)]
    #else
    private let columns = [GridItem(.adaptive(minimum: 320), spacing: 18)]
    #endif

    var body: some View {
        // Read here, so Home redraws the moment either changes (Edit Home from the Mac's toolbar, a tapped TV).
        let editing = layout.editing
        let player = playerTV
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                #if os(iOS)
                // Home and Edit on the left; the thermostat on the right.
                HStack(alignment: .center, spacing: 12) {
                    Text("Home").font(.largeTitle.bold())
                    Button("Edit") { layout.editing = true }.buttonStyle(.glass).controlSize(.small)
                    Spacer()
                    ThermostatChip(compact: true)
                }
                .padding(.bottom, -14)
                #endif
                ForEach(layout.visibleSections.filter { $0 == "status" || $0 == "rooms" }, id: \.self) { key in
                    section(key)
                }
                if room == favoritesKey || (room.isEmpty && !layout.favorites.isEmpty) {
                    favoritesGroup
                }
                if room != favoritesKey {
                    if layout.groupByRoom {
                        // Like the Home app: each room with everything in it.
                        ForEach(roomGroups, id: \.self) { r in roomGroup(r) }
                        if room.isEmpty && !layout.hiddenSections.contains("wifi") { WifiSection() }
                    } else {
                        ForEach(layout.visibleSections.filter { $0 != "status" && $0 != "rooms" }, id: \.self) { key in
                            section(key)
                        }
                    }
                }
            }
            #if os(iOS)
            .padding(.horizontal, 16).padding(.vertical, 12)
            #else
            .padding(28)
            #endif
            // Fills the window: tiles reflow as it's resized (no fixed width on the Mac).
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .blur(radius: openTV == nil ? 0 : 8)
        .overlay { if openTV != nil { Color.black.opacity(0.25).ignoresSafeArea().onTapGesture { close() } } }
        .overlay {
            // The tile grows into the TV's page (and shrinks back into its tile).
            if let id = openTV {
                TVDetailView(tvID: id)
                    .overlay(alignment: .topTrailing) {
                        GlassCircle(symbol: "xmark", size: 34) { close() }.padding(14)
                    }
                    .background(Palette.groupedBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .matchedGeometryEffect(id: id, in: zoom, isSource: true)
                    .shadow(color: .black.opacity(0.35), radius: 40, y: 20)
                    .padding(28)
                    .frame(maxWidth: 820)
                    #if os(macOS)
                    .onExitCommand { close() }
                    // Esc closes it wherever the focus is (onExitCommand only hears it while something in it has focus);
                    // a camera opened over it takes Esc first.
                    .background {
                        if CameraStreams.shared.full == nil {
                            Button("Close") { close() }.keyboardShortcut(.cancelAction).opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
                        }
                    }
                    #endif
                    .transition(.asymmetric(insertion: .identity, removal: .opacity))
            }
        }
        .background { HomeBackdrop(playing: featuredTV?.playing) }
        // Home is always the dark, cinematic room: its glass and text read over the backdrop.
        .environment(\.colorScheme, .dark)
        .navigationTitle(openTV.flatMap { fleet.tv($0)?.name } ?? "Home")
        #if os(iOS)
        // The title sits in the page itself, right under the status bar.
        .toolbar(.hidden, for: .navigationBar)
        #else
        // No title strip: the room bar and tiles run right up under the window's buttons, over the backdrop.
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        // Everything a size up on the Mac's big screens.
        .dynamicTypeSize(.xxLarge)
        #endif
        .sheet(isPresented: Binding(get: { editing }, set: { layout.editing = $0 })) { EditHomeView().macResizable(width: 520, height: 720) }
        .sheet(item: Binding(get: { player.map { TitleRef(id: $0) } }, set: { playerTV = $0?.id })) { NowPlayingSheet(tvID: $0.id).sheetBanner().macResizable(width: 560, height: 780) }
        .refreshable { await refreshEverything() }
    }

    @ViewBuilder private func section(_ key: String) -> some View {
        switch key {
        case "rooms": roomBar
        case "tvs":
            if !shownTVs.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    Text("TVs").font(.title2.bold())
                    LazyVGrid(columns: columns, spacing: 18) {
                        ForEach(shownTVs) { tv in
                            HomeTVTile(tv: tv) { open(tv.id) }
                                .matchedGeometryEffect(id: tv.id, in: zoom, isSource: openTV != tv.id)
                                .opacity(openTV == tv.id ? 0 : 1)
                        }
                    }
                }
            }
        case "speakers": SpeakersSection(room: room.isEmpty ? nil : room)
        case "lights": LightsSection(room: room.isEmpty ? nil : room)
        case "cameras": CamerasSection(room: room.isEmpty ? nil : room, excluding: room.isEmpty ? Set(layout.favorites) : [])
        case "devices": DevicesSection(room: room.isEmpty ? nil : room)
        case "wifi": if room.isEmpty { WifiSection() }
        default: EmptyView()
        }
    }

    /// Pull down on Home: every TV, speaker, light, camera and device asked again.
    private func refreshEverything() async {
        SmartHome.shared.searchLights()
        SmartHome.shared.wake()
        #if os(iOS)
        HomeKitLights.shared.refresh()
        #endif
        async let tvs: Void = fleet.refresh()
        async let speakers: Void = SmartHome.shared.refreshSpeakers()
        async let samsung: Void = SmartThings.shared.refresh(full: false)
        async let cams: Void = NestCameras.shared.load()
        // The fans and the Wi‑Fi too (they're on Home as well).
        async let fans: Void = Dreo.shared.refresh(full: false)
        async let wifi: Void = DecoWifi.shared.refresh()
        _ = await (tvs, speakers, samsung, cams, fans, wifi)
        await fleet.loadAllHealth()
    }

    /// Rooms with something in them, like the Home app's room bar; picking one shows just that room.
    private var rooms: [String] { homeRooms(fleet) }

    // MARK: By room

    /// The rooms Home shows (the one picked in the room bar, or all with something in them), then Other.
    private var roomGroups: [String] {
        let list = room.isEmpty ? layout.arrangeRooms(rooms) + [noRoom] : [room]
        return list.filter(hasThings)
    }

    /// Favorites: everything starred, whatever room it's in.
    private var favoritesGroup: some View {
        let favTVs = layout.favoritesOnly(fleet.tvs)
        return VStack(alignment: .leading, spacing: 16) {
            if layout.favorites.isEmpty {
                Text("Touch and hold anything on Home (a camera, TV, speaker, light or device) and choose Add to Favorites. It shows up here.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    .glass(RoundedRectangle(cornerRadius: 20, style: .continuous), interactive: false)
            }
            #if os(macOS)
            MacFavoriteTiles(open: { open($0) })
            #else
            CamerasSection(favorites: true, compact: true, titled: false)
            if !favTVs.isEmpty {
                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(favTVs) { tv in
                        // The same TV may also sit in its room below; only that one zooms.
                        HomeTVTile(tv: tv) { open(tv.id) }
                    }
                }
            }
            #endif
            RoomTiles(favorites: true)
        }
    }

    private func tvs(in r: String) -> [FleetTV] {
        // A TV not set up yet has no room of its own (its name isn't a room): it shows under Other.
        layout.arrange(fleet.tvs.filter { roomMatches(SmartHome.shared.rooms[$0.id] ?? ($0.isUnpaired ? nil : $0.name), r) }, in: "tvs")
    }

    private func hasThings(_ r: String) -> Bool {
        let h = SmartHome.shared
        let shown = { (k: String) in !layout.hiddenSections.contains(k) }
        // Every room listed: a favourite camera is already playing under Favorites, so it doesn't count here.
        let everyRoom = room.isEmpty
        return (shown("tvs") && !tvs(in: r).isEmpty)
            || (shown("cameras") && NestCameras.shared.cameras.contains { roomMatches(h.rooms[$0.id] ?? $0.room, r) && !layout.hiddenItems.contains($0.id) && !(everyRoom && layout.favorites.contains($0.id)) })
            || (shown("speakers") && h.speakers.contains { roomMatches(h.room(of: $0.id), r) && !layout.hiddenItems.contains($0.id) })
            || (shown("lights") && h.lights.contains { roomMatches(h.room(of: $0.id), r) && !layout.hiddenItems.contains($0.id) })
            || (shown("devices") && AccessoryStore.shared.all.contains { roomMatches(h.room(of: $0.id), r) && !layout.hiddenItems.contains($0.id) })
    }

    private func roomGroup(_ r: String) -> some View {
        let shown = { (k: String) in !layout.hiddenSections.contains(k) }
        return VStack(alignment: .leading, spacing: 10) {
            // The room picked in the room bar is already its title; names only when every room is listed.
            if room.isEmpty { Text(r == noRoom ? "Other" : r).font(.title3.bold()) }
            // A favourite camera already playing under Favorites isn't repeated here (one picture, one place).
            if shown("cameras") { CamerasSection(room: r, compact: true, titled: false, excluding: room.isEmpty ? Set(layout.favorites) : []) }
            if shown("tvs") {
                let list = tvs(in: r)
                if !list.isEmpty {
                    LazyVGrid(columns: columns, spacing: 18) {
                        ForEach(list) { tv in
                            HomeTVTile(tv: tv) { open(tv.id) }
                                .matchedGeometryEffect(id: tv.id, in: zoom, isSource: openTV != tv.id)
                                .opacity(openTV == tv.id ? 0 : 1)
                        }
                    }
                }
            }
            RoomTiles(room: r)
        }
    }

    private var shownTVs: [FleetTV] {
        room.isEmpty ? layout.arrange(fleet.tvs, in: "tvs") : tvs(in: room)
    }

    /// The room bar: Favorites, the few rooms chosen for it (Kitchen, Front Yard, Living Room, Backyard), and
    /// More for All Rooms and every other room.
    private var roomBar: some View {
        let pinned = layout.pinned(in: rooms)
        let others = rooms.filter { !pinned.contains($0) }
        let inMore = room.isEmpty || others.contains(room)
        return ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach([favoritesKey] + pinned, id: \.self) { r in
                    Button { withAnimation(.smooth) { picked = r } } label: {
                        chip(r == favoritesKey ? "Favorites" : r, selected: room == r)
                    }
                    .buttonStyle(.plain)
                    .glass(Capsule())
                }
                Menu {
                    Button { withAnimation(.smooth) { picked = "" } } label: {
                        if room.isEmpty { Label("All Rooms", systemImage: "checkmark") } else { Text("All Rooms") }
                    }
                    if !others.isEmpty {
                        Section("Rooms") {
                            ForEach(others, id: \.self) { r in
                                Button { withAnimation(.smooth) { picked = r } } label: {
                                    if room == r { Label(r, systemImage: "checkmark") } else { Text(r) }
                                }
                            }
                        }
                    }
                    Divider()
                    Button("Choose Rooms for This Bar…") { layout.editing = true }
                } label: {
                    // Shows the room picked from here, so it's clear where you are.
                    chip(inMore ? (room.isEmpty ? "All Rooms" : room) + " ▾" : "More ▾", selected: inMore)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .glass(Capsule())
                .fixedSize()
            }
        }
        .scrollIndicators(.hidden)
    }

    private func chip(_ title: String, selected: Bool) -> some View {
        Text(title)
            #if os(macOS)
            .font(.title3.weight(.semibold))
            .padding(.horizontal, 20).padding(.vertical, 10)
            #else
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 14).padding(.vertical, 8)
            #endif
            .foregroundStyle(selected ? Color.black : .primary)
            .background { if selected { Capsule().fill(.white) } }
    }

    /// The TV the banner shows: the remote's, if it's playing, else any that is.
    private var featuredTV: FleetTV? {
        if let s = fleet.selected, s.playing != nil { return s }
        return fleet.tvs.first { $0.playing?.isPlaying == true } ?? fleet.tvs.first { $0.playing != nil }
    }

    private func open(_ id: String) {
        #if os(macOS)
        MacFeedback.snap()
        #else
        // Straight into the player; only a TV that still needs pairing opens its setup page.
        if let tv = fleet.tv(id), !tv.isUnpaired { playerTV = id; return }
        #endif
        withAnimation(.spring(response: 0.5, dampingFraction: 0.86)) { openTV = id }
    }

    private func close() {
        withAnimation(.spring(response: 0.45, dampingFraction: 0.9)) { openTV = nil }
    }
}

struct StatusPill: View {
    var title: String
    var tint: Color?
    var body: some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(tint ?? .primary)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .glass(Capsule(), interactive: false)
    }
}

/// One TV, as a Home app tile: its name and state, what it's playing over the title's artwork, the transport,
/// and the remote.
struct HomeTVTile: View {
    #if os(macOS)
    static let macBig = true
    #else
    static let macBig = false
    #endif
    @Environment(Fleet.self) private var fleet
    /// Its corner is being dragged (Mac Favorites): the hover lift and tilt rest so the tile follows the pointer.
    @Environment(\.tileResizing) private var resizing
    var tv: FleetTV
    var height: CGFloat = 230
    var open: () -> Void
    @State private var hovering = false
    @State private var dropTarget = false

    /// Photos and videos dropped on a tile go into Family Memories and show on that TV.
    private func dropped(_ urls: [URL]) {
        guard let hub = fleet.hub(tv.id) ?? fleet.hub(tv.hubID) else { return }
        let c = TVClient(hub: hub, routeID: "this")
        Task {
            var last: MemoryItem?
            for url in urls {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                do { last = try await c.addMemory(file: url, name: url.lastPathComponent, taken: nil) } catch { fleet.show(error) }
            }
            // Nothing went in: each failure has already said why (no "Added" that isn't true).
            guard let last else { return }
            // Shown straight away on a TV that holds Memories itself; a linked TV gets them from Memories.
            guard fleet.hub(tv.id) != nil else {
                fleet.say("Added to Family Memories", "Open Memories to show them on \(tv.name).")
                return
            }
            do {
                try await c.showMemory(last)
                fleet.say("Added to Family Memories", "Showing on \(tv.name).")
            } catch {
                fleet.say("Added to Family Memories", "They’re in Memories, but \(tv.name) didn’t show them: \(error.localizedDescription)")
            }
        }
    }
    @State private var renaming = false
    @State private var newName = ""

    var body: some View {
        let p = tv.playing
        // A TV that stopped keeps the picture of what it last played, dimmed, so the grid stays rich.
        let art = p ?? (tv.isUnpaired ? nil : fleet.lastPlaying[tv.id])
        let pictured = hasPicture(fleet, art)
        // Lifted under the pointer, but not while its corner is being dragged.
        let hot = hovering && !resizing
        ZStack(alignment: .bottomLeading) {
            if pictured {
                Color.clear
                    .overlay { NowPlayingArt(playing: art, backdrop: true) }
                    .clipped()
                    .saturation(p == nil ? 0.35 : 1)
                    .opacity(p == nil ? 0.55 : 1)
                LinearGradient(stops: [.init(color: .black.opacity(0.15), location: 0), .init(color: .black.opacity(0.88), location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center) {
                    Text(tv.name).font(Self.macBig ? .title2.bold() : .title3.bold())
                    if tv.needsAttention { Circle().fill(Palette.attention).frame(width: 8, height: 8) }
                    Spacer()
                    Text(state).font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                if let p {
                    Text(p.title).font(Self.macBig ? .title3.weight(.semibold) : .headline).lineLimit(1)
                    Text([p.subtitle, p.app].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · "))
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    LiveProgress(playing: p, times: false, tint: .white).padding(.top, 10)
                } else {
                    Text(idleLine).font(Self.macBig ? .title3.weight(.semibold) : .headline).foregroundStyle(tv.online ? .primary : .secondary)
                }
                HStack(spacing: 8) {
                    if let p { Transport(tv: tv, playing: p, compact: true) }
                    Spacer()
                    if !tv.online, fleet.extras[tv.id]?.mac != nil {
                        // Wake-on-LAN, and the TV is watched closely so it shows as on the moment it is.
                        Button("Turn On") { fleet.wake(tv) }
                            .buttonStyle(.glass)
                    }
                    if tv.isUnpaired {
                        Button("Pair") { open() }.buttonStyle(.glassProminent)
                    } else if tv.online {
                        Button("Remote") {
                            fleet.remoteAll = false
                            fleet.selectedID = tv.id
                            #if os(macOS)
                            withAnimation(.smooth) { fleet.remotePanel = true }
                            #else
                            // The iPhone's remote is its own tab.
                            UserDefaults.standard.set("remote", forKey: "section")
                            #endif
                        }
                        .buttonStyle(.glass)
                    }
                }
                .padding(.top, 12)
            }
            .padding(18)
        }
        .foregroundStyle(pictured ? Color.white : Color.primary)
        .frame(height: height)
        .background {
            if pictured { RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Color.black) }
            else { Color.clear.glass(RoundedRectangle(cornerRadius: 24, style: .continuous), interactive: false) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(.white.opacity(hot ? 0.18 : 0.06)))
        .opacity(tv.online ? 1 : 0.6)
        .shadow(color: .black.opacity(hot ? 0.3 : 0.15), radius: hot ? 18 : 10, y: hot ? 10 : 5)
        .scaleEffect(hot ? 1.01 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: hot)
        .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        #if os(macOS)
        .modifier(TileTilt(enabled: !resizing))
        .dropDestination(for: URL.self) { urls, _ in
            dropped(urls)
            return true
        } isTargeted: { dropTarget = $0 }
        .overlay {
            if dropTarget {
                RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Color.accentColor, lineWidth: 3)
                    .overlay(Text("Show on \(tv.name)").font(.headline).padding(10).glass(Capsule(), interactive: false))
            }
        }
        #endif
        .onTapGesture(perform: open)
        .onHover { hovering = $0 }
        .alert("Rename TV", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Save") { fleet.rename(tv, to: newName) }
            Button("Cancel", role: .cancel) {}
        }
        .contextMenu {
            Button("Open") { open() }
            Button("Rename…") { newName = tv.name; renaming = true }
            Button("Use for the Remote") {
                fleet.remoteAll = false; fleet.selectedID = tv.id
                #if os(macOS)
                fleet.remotePanel = true
                #else
                UserDefaults.standard.set("remote", forKey: "section")
                #endif
            }
            Button("Check for Updates") {
                Task {
                    do {
                        try await fleet.pushUpdate(tv)
                        fleet.say("Checking for Updates", "\(tv.name) checks GitHub now and installs once nobody’s watching.")
                    } catch { fleet.show(error) }
                }
            }
            if tv.needsAttention { Button("Hide Alerts") { fleet.hideAlerts(tv) } }
            if tv.alertsHidden { Button("Show Hidden Alerts") { fleet.showAlerts(tv) } }
            FavoriteButton(id: tv.id)
        }
    }

    private var state: String {
        if tv.isUnpaired { return "Not Paired" }
        if tv.link == "refused" && tv.needsAttention { return "Link Again" }
        if !tv.online { return "Off" }
        if fleet.isBehind(tv) { return "Update Available" }
        if let p = tv.playing { return p.isPlaying ? "Playing" : "Paused" }
        return "On"
    }

    private var idleLine: String {
        if tv.isUnpaired { return "Found on your Wi‑Fi" }
        if tv.link == "refused" { return tv.alertsHidden ? "Off" : "Its link stopped working" }
        if !tv.online { return "Seen \(relative(tv.seen))" }
        return tv.onScreen ? "Woodruff is on screen" : "Nothing playing"
    }
}

/// A Home app scene: one tap does it on every TV.
struct SceneTile: View {
    @Environment(Fleet.self) private var fleet
    var title: String
    var detail: String
    var action: () async -> Void
    @State private var busy = false

    var body: some View {
        Button {
            busy = true
            Task { await action(); busy = false }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(busy ? "Working…" : detail).font(.subheadline).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background { Color.clear.glass(RoundedRectangle(cornerRadius: 18, style: .continuous), interactive: false) }
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(PressScale(scale: 0.97))
        .disabled(busy)
    }
}

/// Search results for the Mac's toolbar search: Movies and TV Shows from the library.
struct LibrarySearchResults: View {
    @Environment(Fleet.self) private var fleet
    var query: String
    @State private var r: SearchResults?
    /// Why the search didn't come back (the TV holding the library is off, say), instead of a spinner forever.
    @State private var failed: String?
    @State private var openTitle: String?

    var body: some View {
        let opened = openTitle
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                if let r {
                    let sections = r.first == "shows" ? [("TV Shows", r.shows), ("Movies", r.movies)] : [("Movies", r.movies), ("TV Shows", r.shows)]
                    ForEach(sections, id: \.0) { name, list in
                        if !list.isEmpty { ShelfRow(name) { ForEach(list) { PosterTile(title: $0) } } }
                    }
                    if r.movies.isEmpty && r.shows.isEmpty {
                        EmptyState(symbol: "magnifyingglass", title: "No Results", message: "Nothing in Movies or TV Shows matches “\(query)”.")
                            .padding(.top, 60)
                    }
                } else if let failed {
                    EmptyState(symbol: "exclamationmark.triangle", title: "Couldn’t Search", message: failed)
                        .padding(.top, 60)
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 80)
                }
            }
            .padding(.vertical, 24)
        }
        .navigationTitle("Search")
        .environment(\.openTitle, OpenTitleAction { openTitle = $0 })
        .sheet(item: Binding(get: { opened.map { TitleRef(id: $0) } }, set: { openTitle = $0?.id })) { TitleSheet(id: $0.id).macResizable(width: 760, height: 820, minWidth: 520, minHeight: 500) }
        .task(id: query) {
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard !Task.isCancelled else { return }
            guard let client = fleet.hubClient() else {
                r = nil
                failed = "Pair a TV first: the library lives on the TVs."
                return
            }
            do {
                let found = try await client.search(query)
                guard !Task.isCancelled else { return }
                r = found
                failed = nil
            } catch {
                // Typed on: the next search takes over.
                guard !Task.isCancelled else { return }
                r = nil
                failed = error.localizedDescription
            }
        }
    }
}

/// Home's background: a slow, quiet gradient in the app's blues that drifts over half a minute, warmed by a
/// soft blur of whatever's playing.
struct HomeBackdrop: View {
    @Environment(Fleet.self) private var fleet
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var playing: NowPlaying?

    var body: some View {
        ZStack {
            Color(red: 0.03, green: 0.05, blue: 0.09)
            TimelineView(.animation(minimumInterval: 1 / 15)) { ctx in
                // Still under Reduce Motion.
                let t = reduceMotion ? 0 : ctx.date.timeIntervalSinceReferenceDate / 30
                let w = Float(sin(t) * 0.12), v = Float(cos(t * 0.8) * 0.12)
                MeshGradient(width: 3, height: 3, points: [
                    [0, 0], [0.5 + w, 0], [1, 0],
                    [0, 0.5 + v], [0.5 - v, 0.5 + w], [1, 0.5 - w],
                    [0, 1], [0.5 + v, 1], [1, 1],
                ], colors: [
                    Color(red: 0.05, green: 0.09, blue: 0.17), Color(red: 0.08, green: 0.18, blue: 0.30), Color(red: 0.04, green: 0.08, blue: 0.14),
                    Color(red: 0.06, green: 0.20, blue: 0.26), Color(red: 0.10, green: 0.24, blue: 0.40), Color(red: 0.05, green: 0.12, blue: 0.22),
                    Color(red: 0.03, green: 0.06, blue: 0.11), Color(red: 0.07, green: 0.14, blue: 0.24), Color(red: 0.04, green: 0.10, blue: 0.16),
                ])
                .opacity(0.9)
            }
            if hasPicture(fleet, playing) {
                GeometryReader { g in
                    NowPlayingArt(playing: playing, backdrop: true)
                        .frame(width: g.size.width, height: g.size.height)
                        .blur(radius: 110, opaque: true)
                        .saturation(1.2)
                        .clipped()
                }
                .opacity(0.32)
                .transition(.opacity)
                .id(playing?.title)
            }
            LinearGradient(colors: [.clear, .black.opacity(0.35)], startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 1.2), value: playing?.title)
        .allowsHitTesting(false)
    }
}

/// What's playing, large, at the top of Home: the picture, the title, the TV, live progress and the transport.
struct NowPlayingBanner: View {
    @Environment(Fleet.self) private var fleet
    var tv: FleetTV
    var playing: NowPlaying
    @State private var open = false

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color.clear
                .overlay { NowPlayingArt(playing: playing, backdrop: true) }
                .clipped()
            LinearGradient(stops: [.init(color: .clear, location: 0.25), .init(color: .black.opacity(0.88), location: 1)],
                           startPoint: .top, endPoint: .bottom)
            HStack(alignment: .bottom, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Now Playing on \(tv.name)".uppercased())
                        .font(.caption.weight(.bold)).tracking(1.2).foregroundStyle(.white.opacity(0.65))
                    Text(playing.title).font(.largeTitle.bold()).lineLimit(2)
                    if let s = [playing.subtitle, playing.app].compactMap({ $0?.isEmpty == false ? $0 : nil }).first {
                        Text(s).font(.title3).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                    }
                    LiveProgress(playing: playing, tint: .white).frame(maxWidth: 420).padding(.top, 8)
                }
                Spacer(minLength: 0)
                Transport(tv: tv, playing: playing, compact: true)
                    .font(.title2)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .glass(Capsule())
            }
            .foregroundStyle(.white)
            .padding(28)
        }
        .frame(height: 300)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(.white.opacity(0.08)))
        .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
        .contentShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .onTapGesture { open = true }
        .sheet(isPresented: $open) { NowPlayingSheet(tvID: tv.id).sheetBanner().macResizable(width: 560, height: 780) }
        .animation(.smooth, value: playing.title)
    }
}

private struct TileResizingKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// A tile's corner is being dragged (Mac Favorites): its hover effects rest so it follows the pointer cleanly.
    var tileResizing: Bool {
        get { self[TileResizingKey.self] }
        set { self[TileResizingKey.self] = newValue }
    }
}

#if os(macOS)
/// Each tile's chosen width on this Mac.
@Observable @MainActor
final class TileSizes {
    static let shared = TileSizes()
    private(set) var widths: [String: CGFloat] =
        ((UserDefaults.standard.dictionary(forKey: "tileWidths") as? [String: Double]) ?? [:]).mapValues { CGFloat($0) }
    func set(_ id: String, _ w: CGFloat) {
        widths[id] = w
        UserDefaults.standard.set(widths.mapValues { Double($0) }, forKey: "tileWidths")
    }
}

/// A tile sized by dragging its bottom-right corner. While dragging, only this tile's width changes (no
/// animation, no saving) so it follows the pointer exactly; it's saved when let go.
struct ResizableTile<Content: View>: View {
    let id: String
    let defaultWidth: CGFloat
    let minWidth: CGFloat
    var maxWidth: CGFloat
    var heightFor: (CGFloat) -> CGFloat
    @ViewBuilder var content: (CGFloat) -> Content
    /// The width while the corner is being dragged (nil otherwise).
    @State private var live: CGFloat?
    @State private var start: CGFloat = 0
    /// Width over height when the drag began: the corner moves along that diagonal, staying as close to the
    /// pointer as the tile's shape allows whichever way it's dragged (across, down, or both).
    @State private var aspect: CGFloat = 1
    @State private var hovering = false
    /// Goes back to false by itself if a drag is cut short (the window loses focus mid-drag), so the new width
    /// is still kept and the grip never stays lit.
    @GestureState private var dragging = false

    private var width: CGFloat {
        let w = live ?? TileSizes.shared.widths[id] ?? defaultWidth
        return min(max(minWidth, w), max(minWidth, maxWidth))
    }

    var body: some View {
        let w = width
        content(w)
            .frame(width: w, height: heightFor(w))
            // The tile's own hover lift and tilt rest while it's being resized (they'd fight the pointer).
            .environment(\.tileResizing, live != nil)
            .overlay(alignment: .bottomTrailing) {
                // In the overlay, apart from the tile: dragging it never counts as a click on the tile.
                ResizeGrip(trailing: true, shown: hovering, active: live != nil)
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .updating($dragging) { _, state, _ in state = true }
                            .onChanged { g in
                                still {
                                    // The width and shape when this drag began.
                                    var s = start, r = aspect
                                    if live == nil {
                                        s = width
                                        r = s / max(1, heightFor(s))
                                        start = s
                                        aspect = r
                                    }
                                    // The point on the tile's diagonal nearest the pointer.
                                    let grow = (r * r * g.translation.width + r * g.translation.height) / (r * r + 1)
                                    live = min(max(minWidth, (s + grow).rounded()), max(minWidth, maxWidth))
                                }
                            }
                            .onEnded { _ in commit() }
                    )
            }
            .onChange(of: dragging) { _, now in if !now { commit() } }
            .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
    }

    /// Keeps the dragged width (once, however the drag ended).
    private func commit() {
        still {
            if let w = live { TileSizes.shared.set(id, w) }
            live = nil
        }
    }

    /// A change with no animation at all, so the tile and the tiles flowing around it move with the pointer.
    private func still(_ change: () -> Void) {
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t, change)
    }
}

/// Favourite cameras and TVs, each sized by dragging its bottom-right corner; the rest flow around it. A view of
/// its own (with its own width), so resizing the window or a tile never re-runs the rest of Home.
private struct MacFavoriteTiles: View {
    @Environment(Fleet.self) private var fleet
    var open: (String) -> Void
    /// How wide Favorites is: a tile can't be dragged wider, and shrinks with the window.
    @State private var width: CGFloat = 1200
    private let layout = HomeLayout.shared

    var body: some View {
        let cams = NestCameras.shared.cameras
        let ids = layout.favorites.filter { id in cams.contains { $0.id == id } || fleet.tv(id) != nil }
        FlowLayout(spacing: 14) {
            ForEach(ids, id: \.self) { id in
                if let cam = cams.first(where: { $0.id == id }) {
                    ResizableTile(id: id, defaultWidth: 340, minWidth: 220, maxWidth: width, heightFor: { $0 * 3 / 4 }) { _ in
                        LiveCameraTile(camera: cam, compact: true) {
                            if cam.webRTC && cam.online { withAnimation(.smooth(duration: 0.25)) { CameraStreams.shared.full = cam.id } }
                        }
                    }
                } else if let tv = fleet.tv(id) {
                    ResizableTile(id: id, defaultWidth: 400, minWidth: 300, maxWidth: width, heightFor: { max(210, $0 * 9 / 16) }) { w in
                        HomeTVTile(tv: tv, height: max(210, w * 9 / 16)) { open(tv.id) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

/// The Mac's hover tilt (as `hoverTilt()`), resting while the tile is being resized, so the corner grip never
/// fights a tile that's turning under the pointer.
private struct TileTilt: ViewModifier {
    var enabled: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var point: CGPoint?
    @State private var size: CGSize = .zero

    func body(content: Content) -> some View {
        let at = enabled ? point : nil
        let dx = reduceMotion ? 0 : at.map { ($0.x / max(size.width, 1)) - 0.5 } ?? 0
        let dy = reduceMotion ? 0 : at.map { ($0.y / max(size.height, 1)) - 0.5 } ?? 0
        content
            .overlay {
                if let at {
                    RadialGradient(colors: [.white.opacity(0.16), .clear], center: UnitPoint(x: at.x / max(size.width, 1), y: at.y / max(size.height, 1)),
                                   startRadius: 0, endRadius: max(size.width, size.height) * 0.7)
                        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .allowsHitTesting(false)
                        .blendMode(.plusLighter)
                }
            }
            .rotation3DEffect(.degrees(Double(-dy) * 6), axis: (x: 1, y: 0, z: 0), perspective: 0.6)
            .rotation3DEffect(.degrees(Double(dx) * 6), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
            .animation(.spring(response: 0.35, dampingFraction: 0.75), value: at)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): point = p
                case .ended: point = nil
                }
            }
    }
}

/// Lays tiles out left to right, wrapping to a new row when one doesn't fit.
struct FlowLayout: Layout {
    var spacing: CGFloat = 14

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxW { y += rowH + spacing; x = 0; rowH = 0 }
            x += size.width + spacing
            rowH = max(rowH, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > bounds.width { y += rowH + spacing; x = 0; rowH = 0 }
            s.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowH = max(rowH, size.height)
        }
    }
}
#endif
