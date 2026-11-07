import SwiftUI
import WoodruffKit

/// Home, like Apple's Home app: a tab for Favorites and for each room, each a grid of tiles (cameras live, TVs with
/// what they're playing, speakers, lights and devices) arranged and sized the way the family likes. Edit (or press
/// and hold) and the tiles jiggle: drag them anywhere, drag a corner to resize. The remote slides out on the right.
struct HomeView: View {
    @Environment(Fleet.self) private var fleet
    /// Settings → General → Away From Home Note.
    @AppStorage("home.awayNote") private var awayNote = true
    @State private var openTV: String?
    /// The room bar's choice: Favorites (first, and where Home opens), All Rooms (""), or a room.
    @AppStorage("home.room2") private var picked = favoritesKey
    /// The TV whose player is open (iPhone: tapping a TV opens straight into what it's playing).
    @State private var playerTV: String?
    /// The page's scrolling, so a tile dragged to an edge scrolls the page under it.
    @State private var scroller = HomeScroller()
    @Namespace private var zoom
    private let layout = HomeLayout.shared

    /// What one drawing of Home works from, found once and handed to every part (each part used to work these out
    /// for itself, again for every room).
    private struct Contents {
        /// The room bar's choice as shown (see `shownRoom`): Favorites, "" for All Rooms, or a room.
        var room: String
        /// The rooms with something in them.
        var rooms: [String]
        /// Every device (Apple Home, SmartThings, Dreo).
        var devices: [HomeDevice]
        /// The favourites' ids.
        var favorites: Set<String>
        /// Each room's speakers, lights and devices (``noRoom`` for those in none), sorted out once for this drawing.
        var speakers: [String: [SonosRoom]]
        var lights: [String: [GoveeLight]]
        var roomDevices: [String: [HomeDevice]]
    }

    /// A room on Home with its tiles.
    private struct RoomGroup: Identifiable {
        var id: String
        var tiles: [HomeTile]
    }

    /// What Home shows for the room bar's choice. A room with nothing in it just now (its cameras or linked TVs
    /// still loading at launch, say) shows All Rooms until it's back, without forgetting the choice; with the room
    /// bar hidden there's no way to pick a room, so everything shows.
    private func shownRoom(_ rooms: [String]) -> String {
        if layout.hiddenSections.contains("rooms") { return "" }
        return picked == favoritesKey || picked == allDevicesKey || picked.isEmpty || rooms.contains(picked) ? picked : ""
    }

    #if os(macOS)
    private let columns = [GridItem(.adaptive(minimum: 400), spacing: 22)]
    #else
    private let columns = [GridItem(.adaptive(minimum: 320), spacing: 18)]
    #endif

    /// iPhone: the height of the weather, Edit and thermostat pills under the greeting.
    static let pillHeight: CGFloat = 52

    var body: some View {
        // Read here, so Home redraws the moment any of these changes (Rooms & Sections, a tapped TV, Edit).
        let editing = layout.editing
        let arranging = layout.arranging
        let player = playerTV
        // Every device, the rooms and the room showing: worked out once for this drawing.
        let devices = AccessoryStore.shared.all
        let h = SmartHome.shared
        let roomOf = h.roomIndex
        let rooms = homeRooms(fleet, devices: devices, roomOf: roomOf)
        let c = Contents(room: shownRoom(rooms), rooms: rooms, devices: devices, favorites: Set(layout.favorites),
                         speakers: itemsByRoom(h.speakers) { roomOf[$0.id] }, lights: itemsByRoom(h.lights) { roomOf[$0.id] },
                         roomDevices: itemsByRoom(devices) { roomOf[$0.id] })
        let room = c.room
        @Bindable var scroller = scroller
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                #if os(iOS)
                // The greeting with its one-liner floating at the top, then the weather and Edit on the left and the thermostat
                // on the right under it. (While arranging, Done stays pinned at the top right instead.)
                VStack(spacing: 14) {
                    // Floating on the background (no card behind it), with a soft shadow to keep it crisp.
                    GreetingText()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 6).padding(.horizontal, 8)
                        .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
                    // All three the same height: the thermostat a touch larger than before, the weather and Edit matching it.
                    HStack(alignment: .center, spacing: 10) {
                        // No Edit button: press and hold a tile to arrange Home.
                        WeatherPill(height: Self.pillHeight)
                            .fixedSize()
                        Spacer(minLength: 8)
                        // Wider than before, the same height: − and + beside it, as on the Mac.
                        if !arranging { ThermostatChip(compact: true, steppers: true, height: Self.pillHeight) }
                    }
                    .frame(minHeight: Self.pillHeight)
                    // Movie Night, Bedtime and the family's own scenes: one tap each.
                    if !arranging { ScenesStrip() }
                    // Away from home most things can't be reached from here: said once, not on every tile.
                    if !arranging && awayNote && fleet.probablyAway {
                        Text("Away from home. Devices update when you’re back.")
                            .font(.footnote).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.bottom, -10)
                #else
                if !arranging { ScenesStrip().padding(.bottom, -14) }
                #endif
                ForEach(layout.visibleSections.filter { $0 == "status" || $0 == "rooms" }, id: \.self) { key in
                    section(key, c)
                }
                if room == allDevicesKey {
                    // Every device, room by room: tap to turn on or off, press and hold for its controls.
                    AllDevicesView()
                }
                if room == favoritesKey || (room.isEmpty && !layout.favorites.isEmpty) {
                    favoritesGroup(c)
                }
                if room != favoritesKey && room != allDevicesKey {
                    if !room.isEmpty {
                        // One room picked in the room bar: its tiles, to arrange as you like.
                        let tiles = roomTiles(room, c)
                        if !tiles.isEmpty { roomGroup(room, tiles, c) }
                    } else if layout.groupByRoom {
                        // Like the Home app: each room with everything in it.
                        ForEach(roomGroups(c)) { g in roomGroup(g.id, g.tiles, c) }
                        if !layout.hiddenSections.contains("wifi") { WifiSection() }
                    } else {
                        ForEach(layout.visibleSections.filter { $0 != "status" && $0 != "rooms" }, id: \.self) { key in
                            section(key, c)
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
            // Like the Home Screen: press and hold an empty spot to arrange the tiles; tap one to finish.
            .background {
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(TapGesture().onEnded { layout.stopArranging() }, including: arranging ? .all : .none)
                    .gesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in startArranging() }, including: arranging ? .none : .all)
            }
        }
        .scrollPosition($scroller.position)
        .onScrollGeometryChange(for: HomeScrollSpot.self) { HomeScrollSpot($0) } action: { _, spot in scroller.take(spot) }
        // While the page moves, Home's backdrop holds still (it's the only thing that reads this).
        .onScrollPhaseChange { _, phase in
            let moving = phase.isScrolling
            if scroller.scrolling != moving { scroller.scrolling = moving }
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { f in scroller.frame = f }
        // A tile being dragged holds the page still (it scrolls by itself at the edges).
        .scrollDisabled(layout.draggingTile != nil)
        #if os(iOS)
        // Pull down: every TV, speaker, light and device asked again now.
        .refreshable { await HomeRefresh.everything(fleet) }
        #endif
        .environment(scroller)
        .blur(radius: openTV == nil ? 0 : 8)
        .overlay { if openTV != nil { Color.black.opacity(0.25).ignoresSafeArea().onTapGesture { close() } } }
        .overlay {
            // The tile grows into the TV's page (and shrinks back into its tile).
            if let id = openTV {
                TVDetailView(tvID: id)
                    .overlay(alignment: .topTrailing) {
                        GlassCircle(symbol: "xmark", size: 34) { close() }.accessibilityLabel("Close").padding(14)
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
        #if os(iOS)
        .overlay(alignment: .topTrailing) {
            if arranging {
                Button("Done") { layout.stopArranging() }
                    .buttonStyle(.glassProminent)
                    .padding(.trailing, 16).padding(.top, 8)
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
        }
        #endif
        .background { HomeBackdrop(playing: featuredTV?.nowPlaying, scroller: scroller) }
        // Home is always the dark, cinematic room: its glass and text read over the backdrop.
        .environment(\.colorScheme, .dark)
        .navigationTitle(openTV.flatMap { fleet.tv($0)?.name } ?? "Home")
        #if os(iOS)
        // The title sits in the page itself, right under the status bar.
        .toolbar(.hidden, for: .navigationBar)
        #else
        // No title strip: the room bar and tiles run right up under Woodruff's own bar, over the backdrop.
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        // Everything a size up on the Mac's big screens.
        .dynamicTypeSize(.xxLarge)
        #endif
        .sheet(isPresented: Binding(get: { editing }, set: { layout.editing = $0 })) { EditHomeView().macResizable(width: 520, height: 720) }
        .sheet(item: Binding(get: { player.map { TitleRef(id: $0) } }, set: { playerTV = $0?.id })) { NowPlayingSheet(tvID: $0.id).sheetBanner().macResizable(width: 560, height: 780) }
        .refreshable { await refreshEverything() }
        // Each time Home opens: a fresh one-liner, and the weather if it's been a while.
        .onAppear {
            HomeWeather.shared.refresh()
            HomeGreeting.shared.refresh()
        }
        // Leaving Home (another tab, another page) finishes arranging.
        .onDisappear { layout.stopArranging() }
    }

    @ViewBuilder private func section(_ key: String, _ c: Contents) -> some View {
        let room = c.room
        switch key {
        case "rooms": roomBar(c)
        case "tvs":
            let tvs = shownTVs(room)
            if !tvs.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    Text("TVs").font(.title2.bold())
                    LazyVGrid(columns: columns, spacing: 18) {
                        ForEach(tvs) { tv in
                            HomeTVTile(tv: tv) { open(tv.id) }
                                .equatable()
                                .matchedGeometryEffect(id: tv.id, in: zoom, isSource: openTV != tv.id)
                                .opacity(openTV == tv.id ? 0 : 1)
                        }
                    }
                }
            }
        case "speakers": SpeakersSection(room: room.isEmpty ? nil : room)
        case "lights": LightsSection(room: room.isEmpty ? nil : room)
        case "cameras": CamerasSection(room: room.isEmpty ? nil : room, excluding: room.isEmpty ? c.favorites : [])
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

    // MARK: By room

    /// The rooms Home shows (the one picked in the room bar, or all with something in them, then Other), each with
    /// its tiles; a room with nothing to show isn't there.
    private func roomGroups(_ c: Contents) -> [RoomGroup] {
        let list = c.room.isEmpty ? layout.arrangeRooms(c.rooms) + [noRoom] : [c.room]
        return list.compactMap { r in
            let tiles = roomTiles(r, c)
            return tiles.isEmpty ? nil : RoomGroup(id: r, tiles: tiles)
        }
    }

    /// Favorites: everything starred, whatever room it's in.
    private func favoritesGroup(_ c: Contents) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if layout.favorites.isEmpty {
                Text("Touch and hold anything on Home (a camera, TV, speaker, light or device) and choose Add to Favorites. It shows up here.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    .glass(RoundedRectangle(cornerRadius: 20, style: .continuous), interactive: false)
            }
            // The same TV may also sit in its room below; only that one zooms.
            HomeBoard(page: favoritesKey, tiles: favoriteTiles(c), openTV: { open($0) })
                .equatable()
        }
    }

    /// Every favourite there is, cameras first, then TVs, then the rest, until they're arranged by hand. Each kind is
    /// looked up by id (not searched for again for every favourite).
    private func favoriteTiles(_ c: Contents) -> [HomeTile] {
        let h = SmartHome.shared
        func byID<T: Identifiable>(_ items: [T]) -> [String: T] where T.ID == String {
            Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
        let cams = byID(NestCameras.shared.cameras), tvs = byID(fleet.tvs)
        let speakers = byID(h.speakers), lights = byID(h.lights), devices = byID(c.devices)
        var cameraTiles: [HomeTile] = [], tvTiles: [HomeTile] = [], small: [HomeTile] = []
        for id in layout.favorites {
            if let cam = cams[id] { cameraTiles.append(.camera(cam)) }
            else if let t = tvs[id] { tvTiles.append(.tv(t)) }
            else if let r = speakers[id] { small.append(.speaker(r)) }
            else if let l = lights[id] { small.append(.light(l)) }
            else if let d = devices[id] { small.append(.device(d)) }
        }
        return cameraTiles + tvTiles + small
    }

    /// Everything in room [r] Home shows: its cameras, TVs, speakers, lights and devices (not ones hidden, nor kinds
    /// turned off in Rooms & Sections).
    private func roomTiles(_ r: String, _ c: Contents) -> [HomeTile] {
        let h = SmartHome.shared
        let shown = { (k: String) in !layout.hiddenSections.contains(k) }
        // Every room listed: a favourite camera is already playing under Favorites (one live picture, one place).
        let everyRoom = c.room.isEmpty
        var out: [HomeTile] = []
        if shown("cameras") {
            let cams = NestCameras.shared.cameras.filter { roomMatches(h.rooms[$0.id] ?? $0.room, r) && !(everyRoom && c.favorites.contains($0.id)) }
            out += layout.arrange(cams, in: "cameras").map { HomeTile.camera($0) }
        }
        if shown("tvs") { out += tvs(in: r).map { HomeTile.tv($0) } }
        if shown("speakers") {
            out += layout.arrange(c.speakers[r] ?? [], in: "speakers").map { HomeTile.speaker($0) }
        }
        if shown("lights") {
            out += layout.arrange(c.lights[r] ?? [], in: "lights").map { HomeTile.light($0) }
        }
        if shown("devices") {
            out += layout.arrange(c.roomDevices[r] ?? [], in: "devices").map { HomeTile.device($0) }
        }
        // Each thing once (a light found twice would otherwise upset the grid).
        var seen = Set<String>()
        return out.filter { seen.insert($0.id).inserted }
    }

    private func tvs(in r: String) -> [FleetTV] {
        // A TV not set up yet has no room of its own (its name isn't a room): it shows under Other.
        layout.arrange(fleet.tvs.filter { roomMatches(SmartHome.shared.rooms[$0.id] ?? ($0.isUnpaired ? nil : $0.name), r) }, in: "tvs")
    }

    private func roomGroup(_ r: String, _ tiles: [HomeTile], _ c: Contents) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // The room picked in the room bar is already its title; names only when every room is listed.
            if c.room.isEmpty { Text(r == noRoom ? "Other" : r).font(.title3.bold()) }
            #if os(macOS)
            HomeBoard(page: r, tiles: tiles, openTV: { open($0) }, zoom: zoom, zoomed: openTV)
                .equatable()
            #else
            HomeBoard(page: r, tiles: tiles, openTV: { open($0) })
                .equatable()
            #endif
        }
    }

    private func shownTVs(_ room: String) -> [FleetTV] {
        room.isEmpty ? layout.arrange(fleet.tvs, in: "tvs") : tvs(in: room)
    }

    /// The room bar: Favorites, the few rooms chosen for it (Kitchen, Front Yard, Living Room, Backyard), and
    /// More for All Rooms and every other room.
    private func roomBar(_ c: Contents) -> some View {
        let room = c.room, rooms = c.rooms
        let pinned = layout.pinned(in: rooms)
        let others = rooms.filter { !pinned.contains($0) }
        let inMore = room.isEmpty || others.contains(room)
        return ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach([favoritesKey, allDevicesKey] + pinned, id: \.self) { r in
                    Button { withAnimation(.smooth) { picked = r } } label: {
                        chip(r == favoritesKey ? "Favorites" : r == allDevicesKey ? "All Devices" : r, selected: room == r)
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
                    Button("Rooms & Sections…") { layout.editing = true }
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

    /// The TV whose picture warms Home's backdrop: the remote's, if it's playing right now, else any that is. None
    /// while nothing plays (no picture of something that's stopped or paused).
    private var featuredTV: FleetTV? {
        if let s = fleet.selected, s.nowPlaying?.isPlaying == true { return s }
        return fleet.tvs.first { $0.nowPlaying?.isPlaying == true }
    }

    private func open(_ id: String) {
        guard layout.tapsAllowed else { return }
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

    private func startArranging() {
        guard !layout.arranging else { return }
        layout.startArranging()
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        #else
        MacFeedback.snap()
        #endif
    }
}

/// One TV, as a Home app tile: its name and state, what it's playing over the title's artwork, the transport,
/// and the remote.
struct HomeTVTile: View, Equatable {
    #if os(macOS)
    static let macBig = true
    #else
    static let macBig = false
    #endif
    @Environment(Fleet.self) private var fleet
    /// Home's tiles are being arranged: the hover lift and tilt rest (the tile is being moved or resized).
    @Environment(\.homeArranging) private var arranging
    var tv: FleetTV
    var height: CGFloat = 230
    var open: () -> Void
    @State private var hovering = false
    @State private var dropTarget = false

    /// Drawn again for a change to the TV or the tile's height, not each time the grid around it is (a tile being
    /// dragged past it, say); the action is the same each time. (Off: "Seen 5 min. ago" keeps up by itself, below.)
    nonisolated static func == (a: HomeTVTile, b: HomeTVTile) -> Bool { a.tv == b.tv && a.height == b.height }

    /// Photos and videos dropped on a tile go into Family Memories and show on that TV.
    private func dropped(_ urls: [URL]) {
        guard let hub = fleet.hub(tv.id) ?? fleet.hub(tv.hubID) else {
            // Dropped and nothing happened, with no word why.
            fleet.say("Couldn’t Add to Family Memories", "Woodruff can’t reach \(tv.name) right now. Check it’s on, then try again.")
            return
        }
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
        // Only what's on the TV right now (`nowPlaying`): a TV that's off, has stopped, or was left paused shows no
        // picture and reads as nothing playing (never the last thing it played).
        let p = tv.nowPlaying
        let pictured = hasPicture(fleet, p)
        // Lifted under the pointer, but not while the tiles are being arranged.
        let hot = hovering && !arranging
        ZStack(alignment: .bottomLeading) {
            if pictured {
                Color.clear
                    .overlay { NowPlayingArt(playing: p, backdrop: true, maxPixel: 1024) }
                    .clipped()
                    // Paused a moment ago: a little quieter until it plays again.
                    .saturation(p?.isPlaying == false ? 0.7 : 1)
                    .animation(.easeInOut(duration: 0.4), value: p?.isPlaying)
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
                } else if !tv.online {
                    // "Seen 5 min. ago" keeps up by itself: the tile is drawn again only when the TV changes, and one
                    // that's off doesn't.
                    TimelineView(.periodic(from: .now, by: 30)) { _ in idleText }
                } else {
                    idleText
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
        .modifier(TileTilt(enabled: !arranging))
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
        .onTapGesture { if HomeLayout.shared.tapsAllowed { open() } }
        .onHover { hovering = $0 }
        .alert("Rename TV", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Save") { fleet.rename(tv, to: newName) }
            Button("Cancel", role: .cancel) {}
        }
        .contextMenu {
            ArrangeHomeButton()
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
            Button("Update Now") {
                Task {
                    do {
                        try await fleet.pushUpdate(tv, now: true)
                        fleet.say("Updating", "\(tv.name) is updating now. It restarts into the new version in a minute or two (after the film, if one is playing).")
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
        if let p = tv.nowPlaying { return p.isPlaying ? "Playing" : "Paused" }
        return "On"
    }

    private var idleLine: String {
        if tv.isUnpaired { return "Found on your Wi‑Fi" }
        if tv.link == "refused" { return tv.alertsHidden ? "Off" : "Its link stopped working" }
        if !tv.online { return "Seen \(relative(tv.seen))" }
        return tv.onScreen ? "Woodruff is on screen" : "Nothing playing"
    }

    private var idleText: some View {
        Text(idleLine).font(Self.macBig ? .title3.weight(.semibold) : .headline).foregroundStyle(tv.online ? .primary : .secondary)
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
        // Watch's library (the TV's or the Drive one, as Settings → Watch picks), worked out once for the page.
        let client = WatchSources.current(fleet)
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                if let r {
                    let sections = r.first == "shows" ? [("TV Shows", r.shows), ("Movies", r.movies)] : [("Movies", r.movies), ("TV Shows", r.shows)]
                    ForEach(sections, id: \.0) { name, list in
                        if !list.isEmpty { ShelfRow(name) { ForEach(list) { PosterTile(title: $0, poster: client?.artURL($0.poster)) } } }
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
            guard let source = WatchSources.current(fleet) else {
                r = nil
                failed = "Pair a TV first: the library lives on the TVs."
                return
            }
            do {
                let found = try await source.search(query)
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

/// Home's background: a slow, quiet gradient in the app's blues that drifts over half a minute. Always blue: what's
/// playing doesn't tint it.
struct HomeBackdrop: View {
    @Environment(Fleet.self) private var fleet
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var playing: NowPlaying?
    /// Home's scrolling: the drift rests while the page moves.
    var scroller: HomeScroller? = nil
    /// Low Power Mode: the drift rests.
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled

    var body: some View {
        // Also resting while the window can't be seen (hidden, minimised, covered) or the app is in the background.
        let resting = reduceMotion || lowPower || (scroller?.scrolling ?? false) || !fleet.isActive
        ZStack {
            Color(red: 0.03, green: 0.05, blue: 0.09)
            // Twice a second is plenty for a drift this slow (each step moves it a fraction of a point), and none
            // while the page scrolls, under Reduce Motion, or in Low Power Mode.
            TimelineView(.animation(minimumInterval: 0.5, paused: resting)) { ctx in
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
            LinearGradient(colors: [.clear, .black.opacity(0.35)], startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .task {
            // As it is now (it may have changed while Home was away), then as it changes.
            lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
            for await _ in NotificationCenter.default.notifications(named: .NSProcessInfoPowerStateDidChange) {
                lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
            }
        }
    }
}

#if os(macOS)
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

#endif


/// Home's pull to refresh: everything asked again at once, back when the slowest has answered (or given up).
@MainActor
enum HomeRefresh {
    static func everything(_ fleet: Fleet) async {
        let home = SmartHome.shared, st = SmartThings.shared, dreo = Dreo.shared, cync = Cync.shared, nest = NestCameras.shared
        let stOn = st.connected, dreoOn = dreo.connected, cyncOn = cync.connected, nestOn = nest.connected
        home.wake()
        await withTaskGroup(of: Void.self) { g in
            g.addTask { await fleet.refresh() }
            g.addTask { await home.refreshSpeakers() }
            if stOn { g.addTask { await st.refresh(full: false) } }
            if dreoOn { g.addTask { await dreo.refresh(full: false) } }
            if cyncOn { g.addTask { await cync.refresh() } }
            if nestOn { g.addTask { await nest.load() } }
        }
    }
}
