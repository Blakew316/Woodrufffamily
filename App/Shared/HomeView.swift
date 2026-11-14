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
    #if os(tvOS)
    @AppStorage("home.room2") private var picked = allDevicesKey
    #else
    @AppStorage("home.room2") private var picked = favoritesKey
    #endif
    /// The TV whose player is open (iPhone: tapping a TV opens straight into what it's playing).
    @State private var playerTV: String?
    /// The page's scrolling, so a tile dragged to an edge scrolls the page under it.
    @State private var scroller = HomeScroller()
    @Namespace private var zoom
    private let layout = HomeLayout.shared
    #if os(tvOS)
    /// Apple TV: the rows of tiles (Favorites, then the rooms) are where the remote starts on Home. With no starting
    /// place said, it could start on the first scene, which a stray click then ran.
    @FocusState private var tvStart: String?
    /// The remote has been on the tiles: from then on no starting place is said, and it's left wherever it's taken.
    @State private var tvStarted = false
    /// The starting place: the tiles, until the remote has been on them ("" is no one's).
    private var tvStartOn: String { tvStarted ? "" : "tiles" }
    #endif

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
        #if os(tvOS)
        // Apple TV: every device, room by room, one row each (Favorites above them).
        return allDevicesKey
        #else
        if layout.hiddenSections.contains("rooms") { return "" }
        return picked == favoritesKey || picked == allDevicesKey || picked.isEmpty || rooms.contains(picked) ? picked : ""
        #endif
    }

    #if os(macOS)
    private let columns = [GridItem(.adaptive(minimum: 400), spacing: 22)]
    #else
    private let columns = [GridItem(.adaptive(minimum: 320), spacing: 18)]
    #endif

    #if os(tvOS)
    private let isTV = true
    #else
    private let isTV = false
    #endif

    /// iPhone: the height of the weather, Edit and thermostat pills under the greeting.
    static let pillHeight: CGFloat = 52

    #if os(macOS)
    /// The Mac keeps Home behind the page showing (`pageHidden`); the name of that page.
    @Environment(\.pageHidden) private var pageHidden
    @Environment(\.macPageTitle) private var shownPageTitle
    #endif
    /// The Mac's toolbar has the rooms (`MacHomeRoomMenu`): Home's own row of room tabs is left out.
    @Environment(\.homeRoomsInBar) private var roomsInBar

    var body: some View {
        // Read here, so Home redraws the moment any of these changes (Rooms & Sections, a tapped TV, Edit).
        let editing = layout.editing
        let arranging = layout.arranging
        let player = playerTV
        // Every device, the rooms and the room showing: worked out once for this drawing.
        #if os(tvOS)
        // Apple TV shows Favorites and All Devices (which sorts out its own rooms): only Favorites' devices are needed
        // here. The rooms, and each room's speakers, lights and devices, were worked out at every redraw for nothing.
        let c = Contents(room: shownRoom([]), rooms: [], devices: layout.favorites.isEmpty ? [] : AccessoryStore.shared.all,
                         favorites: Set(layout.favorites), speakers: [:], lights: [:], roomDevices: [:])
        #else
        let devices = AccessoryStore.shared.all
        let h = SmartHome.shared
        let roomOf = h.roomIndex
        let rooms = homeRooms(fleet, devices: devices, roomOf: roomOf)
        let c = Contents(room: shownRoom(rooms), rooms: rooms, devices: devices, favorites: Set(layout.favorites),
                         speakers: itemsByRoom(h.speakers) { roomOf[$0.id] }, lights: itemsByRoom(h.lights) { roomOf[$0.id] },
                         roomDevices: itemsByRoom(devices) { roomOf[$0.id] })
        #endif
        let room = c.room
        @Bindable var scroller = scroller
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                #if os(tvOS)
                // The weather, the greeting and the thermostat across the top (as the Mac's bar), then the scenes.
                TVHomeHeader()
                if !arranging { ScenesStrip() }
                #elseif os(iOS)
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
                #if os(tvOS)
                ForEach(layout.visibleSections.filter { $0 == "status" }, id: \.self) { key in
                    section(key, c)
                }
                #else
                ForEach(layout.visibleSections.filter { $0 == "status" || $0 == "rooms" }, id: \.self) { key in
                    section(key, c)
                }
                #endif
                #if os(tvOS)
                // Favorites first, then every device room by room. Together they're where the remote starts (`tvStart`).
                VStack(alignment: .leading, spacing: 30) {
                    if !layout.favorites.isEmpty { favoritesGroup(c) }
                    AllDevicesView()
                }
                .focused($tvStart, equals: "tiles")
                #else
                if room == allDevicesKey {
                    // Every device, room by room: tap to turn on or off, press and hold for its controls.
                    AllDevicesView()
                }
                if room == favoritesKey || (room.isEmpty && !layout.favorites.isEmpty && !isTV) {
                    favoritesGroup(c)
                }
                #endif
                if room != favoritesKey && room != allDevicesKey {
                    if !room.isEmpty {
                        // One room picked in the room bar: its tiles, to arrange as you like.
                        let tiles = roomTiles(room, c)
                        if !tiles.isEmpty { roomGroup(room, tiles, c) }
                    } else if layout.groupByRoom || isTV {
                        // Like the Home app: each room with everything in it.
                        // The first rooms with the page; the ones further down as they come near (`HomeBoard.deferred`).
                        ForEach(Array(roomGroups(c).enumerated()), id: \.element.id) { i, g in
                            roomGroup(g.id, g.tiles, c, deferred: i >= 2)
                        }
                        if !layout.hiddenSections.contains("wifi") { WifiSection() }
                    } else {
                        ForEach(layout.visibleSections.filter { $0 != "status" && $0 != "rooms" }, id: \.self) { key in
                            section(key, c)
                        }
                    }
                }
            }
            #if os(iOS) || os(tvOS)
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
        #if os(tvOS)
        // Apple TV: Home starts on its first row of tiles. Once the remote has been there, nothing here answers to
        // the starting place any more, so coming back to Home, or back from a sheet, isn't changed.
        .defaultFocus($tvStart, tvStartOn)
        .onChange(of: tvStart) { _, now in if now != nil, !tvStarted { tvStarted = true } }
        #endif
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
        #if os(iOS) || os(tvOS)
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
        #if os(iOS) || os(tvOS)
        .overlay(alignment: .topTrailing) {
            if arranging {
                Button("Done") { layout.stopArranging() }
                    .buttonStyle(.glassProminent)
                    .padding(.trailing, 16).padding(.top, 8)
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
        }
        #endif
        #if !os(tvOS)
        .background { HomeBackdrop(scroller: scroller) }
        #endif
        // Home is always the dark, cinematic room: its glass and text read over the backdrop.
        .environment(\.colorScheme, .dark)
        #if os(macOS)
        // (Kept behind another page, it gives the window that page's name, not its own.)
        .navigationTitle(pageHidden ? shownPageTitle : (openTV.flatMap { fleet.tv($0)?.name } ?? "Home"))
        #else
        .navigationTitle(openTV.flatMap { fleet.tv($0)?.name } ?? "Home")
        #endif
        #if os(iOS) || os(tvOS)
        // The title sits in the page itself, right under the status bar.
        .toolbar(.hidden, for: .navigationBar)
        #else
        // No title strip: the room bar and tiles run right up under Woodruff's own bar, over the backdrop. Only while
        // Home is the page showing: the Mac keeps it behind Watch and Settings, which have their titles. (Said by a
        // view that's there only then. Changing what one view removes doesn't put the title back.)
        .background {
            if !pageHidden {
                Color.clear
                    .toolbar(removing: .title)
                    .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            }
        }
        // Everything a size up on the Mac's big screens.
        .dynamicTypeSize(.xxLarge)
        #endif
        .sheet(isPresented: Binding(get: { editing }, set: { layout.editing = $0 })) { EditHomeView().macResizable(width: 520, height: 720) }
        .sheet(item: Binding(get: { player.map { TitleRef(id: $0) } }, set: { playerTV = $0?.id })) { NowPlayingSheet(tvID: $0.id).sheetBanner().macResizable(width: 560, height: 780) }
        #if os(tvOS)
        // Menu closes a TV's page opened over Home (and otherwise does what it always does).
        .onExitCommand(perform: exitAction)
        #endif
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
        // (On the Mac the rooms are a pill in the window's toolbar when there's room for it there: no row of tabs.)
        case "rooms": if !roomsInBar { roomBar(c) }
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

    // How something gets into Favorites, in this device's words (a Mac is right-clicked, not touched and held).
    #if os(macOS)
    private static let howToFavorite: LocalizedStringKey = "Right-click anything on Home (a camera, TV, speaker, light or device) and choose Add to Favorites. It shows up here."
    #else
    private static let howToFavorite: LocalizedStringKey = "Touch and hold anything on Home (a camera, TV, speaker, light or device) and choose Add to Favorites. It shows up here."
    #endif

    /// Favorites: everything starred, whatever room it's in.
    private func favoritesGroup(_ c: Contents) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            #if os(tvOS)
            Text("Favorites").font(.system(size: 34, weight: .bold)).foregroundStyle(IconPalette.white)
            #endif
            if layout.favorites.isEmpty {
                Text(Self.howToFavorite)
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

    private func roomGroup(_ r: String, _ tiles: [HomeTile], _ c: Contents, deferred: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // The room picked in the room bar is already its title; names only when every room is listed.
            #if os(tvOS)
            if c.room.isEmpty { Text(r == noRoom ? "Other" : r).font(.system(size: 34, weight: .bold)).foregroundStyle(IconPalette.white) }
            #else
            if c.room.isEmpty { Text(r == noRoom ? "Other" : r).font(.title3.bold()) }
            #endif
            #if os(macOS)
            HomeBoard(page: r, tiles: tiles, openTV: { open($0) }, zoom: zoom, zoomed: openTV, deferred: deferred)
                .equatable()
            #elseif os(tvOS)
            // (Apple TV builds every room with the page: the remote can only move to a tile that's there.)
            HomeBoard(page: r, tiles: tiles, openTV: { open($0) })
                .equatable()
            #else
            HomeBoard(page: r, tiles: tiles, openTV: { open($0) }, deferred: deferred)
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
                    #if os(tvOS)
                    .buttonStyle(TVBarButtonStyle())
                    #else
                    .buttonStyle(.plain)
                    #endif
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
                #if os(tvOS)
                .buttonStyle(TVBarButtonStyle())
                #else
                .buttonStyle(.plain)
                #endif
                .glass(Capsule())
                .fixedSize()
            }
        }
        .scrollIndicators(.hidden)
        #if os(tvOS)
        .scrollClipDisabled()
        #endif
        #if os(macOS)
        // The Mac: in the middle of the page while they all fit (they sat at its left edge); when there are more than
        // fit, they start at the left and scroll, as before.
        .defaultScrollAnchor(.center, for: .alignment)
        #endif
    }

    private func chip(_ title: String, selected: Bool) -> some View {
        Text(title)
            #if os(macOS)
            .font(.title3.weight(.semibold))
            .padding(.horizontal, 20).padding(.vertical, 10)
            #elseif os(tvOS)
            .font(.system(size: 26, weight: .semibold))
            .padding(.horizontal, 30).padding(.vertical, 14)
            #else
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 14).padding(.vertical, 8)
            #endif
            .foregroundStyle(selected ? Color.black : .primary)
            .background { if selected { Capsule().fill(.white) } }
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

    #if os(tvOS)
    /// Menu on the Siri Remote: closes the TV's page while one is open; nil leaves Menu to do what it always does.
    private var exitAction: (() -> Void)? {
        guard openTV != nil else { return nil }
        return { close() }
    }
    #endif

    private func startArranging() {
        guard !layout.arranging else { return }
        layout.startArranging()
        #if os(iOS) || os(tvOS)
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
    // The tile's type. Apple TV has sizes of its own: the system's named sizes there are made for one line read
    // across a room (a title is 48 points, a headline 38), and in a tile 480 points wide they cut the TV's name
    // short ("Master Be…") and made the rest gigantic. These sit with Home's other tiles there (a name is 26).
    #if os(tvOS)
    private static let nameFont = Font.system(size: 28, weight: .bold)
    private static let stateFont = Font.system(size: 21, weight: .semibold)
    private static let titleFont = Font.system(size: 26, weight: .semibold)
    private static let detailFont = Font.system(size: 21)
    #else
    private static let nameFont: Font = macBig ? .title2.bold() : .title3.bold()
    private static let stateFont: Font = .caption.weight(.semibold)
    private static let titleFont: Font = macBig ? .title3.weight(.semibold) : .headline
    private static let detailFont: Font = .subheadline
    #endif

    @Environment(Fleet.self) private var fleet
    /// Home's tiles are being arranged: the hover lift rests (the tile is being moved or resized).
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
            fleet.alert("Couldn’t Add to Family Memories", "Woodruff can’t reach \(tv.name) right now. Check it’s on, then try again.")
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
            // Shown straight away on a TV that holds Memories itself; a linked TV gets them from Memories. (The app
            // has no Memories page to send anyone to any more: the TVs' slideshow shows them.)
            guard fleet.hub(tv.id) != nil else {
                fleet.say("Added to Family Memories", "The slideshow on \(tv.name) can show them.")
                return
            }
            do {
                try await c.showMemory(last)
                fleet.say("Added to Family Memories", "Showing on \(tv.name).")
            } catch {
                fleet.alert("Added to Family Memories", "They’re in Memories, but \(tv.name) didn’t show them: \(error.localizedDescription)")
            }
        }
    }
    @State private var renaming = false
    @State private var newName = ""

    /// The Mac: the tile's glass lights up under the pointer (the system's own highlight on glass), resting while the
    /// tiles are arranged. Elsewhere it's still glass: the tile takes the taps.
    private var glassResponds: Bool {
        #if os(macOS)
        return !arranging
        #else
        return false
        #endif
    }

    /// A click on the tile (on the Mac, Space or Return too, with the keyboard on it): opens its TV.
    private func tapped() {
        guard HomeLayout.shared.tapsAllowed else { return }
        #if os(tvOS)
        // Apple TV: the tile is the button. A click turns on a TV that's off, as its tile under its room does.
        if !tv.online, fleet.extras[tv.id]?.mac != nil { fleet.wake(tv) }
        #endif
        open()
    }

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
                    Text(tv.name).font(Self.nameFont)
                    if tv.needsAttention { Circle().fill(Palette.attention).frame(width: 8, height: 8) }
                    Spacer()
                    Text(state).font(Self.stateFont)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                if let p {
                    Text(p.title).font(Self.titleFont).lineLimit(1)
                    Text([p.subtitle, p.app].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · "))
                        .font(Self.detailFont).foregroundStyle(.secondary).lineLimit(1)
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
                #if os(tvOS)
                // (Remote, Turn On and Pair: the system's button type there is as large as a headline.)
                .font(.system(size: 22, weight: .semibold))
                #endif
                .padding(.top, 12)
            }
            .padding(18)
        }
        .foregroundStyle(pictured ? Color.white : Color.primary)
        .frame(height: height)
        .background {
            if pictured { RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Color.black) }
            else { Color.clear.glass(RoundedRectangle(cornerRadius: 24, style: .continuous), interactive: glassResponds) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(.white.opacity(hot ? 0.18 : 0.06)))
        .opacity(tv.online ? 1 : 0.6)
        .shadow(color: .black.opacity(hot ? 0.3 : 0.15), radius: hot ? 18 : 10, y: hot ? 10 : 5)
        .scaleEffect(hot ? 1.01 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: hot)
        .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        #if os(macOS)
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
        #if os(tvOS)
        .modifier(TVFocusTile())
        #endif
        .onTapGesture { tapped() }
        #if os(macOS)
        // The keyboard reaches it too: Tab (with the Mac's Keyboard Navigation on), then Space or Return.
        .modifier(MacKeyTile(radius: 24) { tapped() })
        #endif
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
        if tv.pairingRefused == true { return "Pair Again" }
        if !tv.online { return "Off" }
        if fleet.isBehind(tv) { return "Update Available" }
        if let p = tv.nowPlaying { return p.isPlaying ? "Playing" : "Paused" }
        return "On"
    }

    private var idleLine: String {
        if tv.isUnpaired { return "Found on your Wi‑Fi" }
        if tv.link == "refused" { return tv.alertsHidden ? "Off" : "Its link stopped working" }
        if tv.pairingRefused == true { return "Its pairing key changed" }
        if !tv.online { return "Seen \(relative(tv.seen))" }
        return tv.onScreen ? "Woodruff is on screen" : "Nothing playing"
    }

    private var idleText: some View {
        Text(idleLine).font(Self.titleFont).foregroundStyle(tv.online ? .primary : .secondary)
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
        .titleSheet(Binding(get: { opened.map { TitleRef(id: $0) } }, set: { openTitle = $0?.id })) { TitleSheet(id: $0.id) }
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Home's scrolling: the drift rests while the page moves.
    var scroller: HomeScroller? = nil
    /// Low Power Mode: the drift rests.
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    /// The app isn't in use, or (the Mac) its window isn't the one in use: the drift rests.
    @AmbientResting private var away: Bool

    var body: some View {
        // Also resting while the window can't be seen (hidden, minimised, covered), while the app is in the background,
        // and on the Mac while another window or app is the one in use.
        let resting = reduceMotion || lowPower || (scroller?.scrolling ?? false) || away
        ZStack {
            // The app icon's colours: steel blue at the top fading to deep navy, its cyan glowing softly in the middle.
            IconPalette.deep
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
                    Color(red: 0.20, green: 0.30, blue: 0.42), IconPalette.steel, Color(red: 0.19, green: 0.29, blue: 0.41),
                    Color(red: 0.10, green: 0.19, blue: 0.30), Color(red: 0.13, green: 0.30, blue: 0.45), Color(red: 0.10, green: 0.18, blue: 0.29),
                    IconPalette.deep, Color(red: 0.05, green: 0.10, blue: 0.17), IconPalette.deep,
                ])
            }
            LinearGradient(colors: [.clear, .black.opacity(0.15)], startPoint: .top, endPoint: .bottom)
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
            if cyncOn { g.addTask { _ = await cync.refresh() } }
            if nestOn { g.addTask { await nest.load() } }
        }
    }
}

#if os(macOS)
/// Home's rooms as one pill in the Mac window's toolbar: the room showing, and under it a menu of them all (Favorites,
/// All Devices, the rooms chosen for the bar, All Rooms and every other room). The size of the toolbar's other pills.
/// (They were a row of tabs across the top of Home, above its tiles, which now start that much higher.)
struct MacHomeRoomMenu: View {
    @Environment(Fleet.self) private var fleet
    /// Home's own choice of room (`HomeView.picked`).
    @AppStorage("home.room2") private var picked = favoritesKey
    private let layout = HomeLayout.shared

    var body: some View {
        let rooms = homeRooms(fleet)
        let pinned = layout.pinned(in: rooms)
        let others = rooms.filter { !pinned.contains($0) }
        // What Home shows for the choice: a room with nothing in it just now shows All Rooms (`HomeView.shownRoom`).
        let room = picked == favoritesKey || picked == allDevicesKey || picked.isEmpty || rooms.contains(picked) ? picked : ""
        Menu {
            choice("Favorites", favoritesKey, room)
            choice("All Devices", allDevicesKey, room)
            if !pinned.isEmpty {
                Divider()
                ForEach(pinned, id: \.self) { r in choice(r, r, room) }
            }
            Divider()
            choice("All Rooms", "", room)
            ForEach(others, id: \.self) { r in choice(r, r, room) }
            Divider()
            Button("Rooms & Sections…") { layout.editing = true }
        } label: {
            HStack(spacing: 8) {
                Text(room == favoritesKey ? "Favorites" : room == allDevicesKey ? "All Devices" : room.isEmpty ? "All Rooms" : room)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down").font(.caption.weight(.bold)).foregroundStyle(.secondary)
            }
            .foregroundStyle(.primary)
            // The same type and the same room round its name as the toolbar's other pills.
            .padding(.horizontal, 18).padding(.vertical, 10)
            .dynamicTypeSize(.xxLarge)
            .contentShape(Capsule())
            .glass(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Rooms")
    }

    /// One of the menu's rooms, ticked when it's the one showing.
    @ViewBuilder private func choice(_ title: String, _ value: String, _ room: String) -> some View {
        Button { withAnimation(.smooth) { picked = value } } label: {
            if room == value { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }
}
#endif
