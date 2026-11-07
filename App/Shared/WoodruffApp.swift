import SwiftUI
import UserNotifications
import WoodruffKit
#if os(iOS)
import BackgroundTasks

/// The next background check for camera alerts.
enum AlertsRefresh {
    static let id = "com.woodruff.family.alerts"
    @MainActor static func schedule() {
        let r = BGAppRefreshTaskRequest(identifier: id)
        r.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(r)
    }
}
#endif

/// Whether the app has really been in the background since it was last in front: coming back from there wakes
/// everything; coming back from a glance at Control Center (only inactive for a moment) doesn't.
@MainActor
enum AppWake {
    static var wentAway = false
}

@main
struct WoodruffApp: App {
    @State private var fleet = Fleet.shared
    @Environment(\.scenePhase) private var scenePhase
    #if os(iOS)
    @UIApplicationDelegateAdaptor(PushAppDelegate.self) private var pushDelegate
    #endif

    init() {
        // The saved sign-ins and keys the settings sync reads before the TVs are first asked, read now in the
        // background (each Keychain read is slow), so by then they're at hand instead of holding up the main thread.
        let keys = SettingsSync.keychainKeys + Fleet.shared.tvs.map { "lg.\($0.id)" }
        Task.detached(priority: .userInitiated) { for k in keys { _ = Keychain.read(k) } }
        // Before launch finishes, as Apple asks: a tapped doorbell or camera alert that opened the app (Woodruff
        // wasn't running) still arrives here and opens that camera live, instead of being dropped.
        UNUserNotificationCenter.current().delegate = Notifier.handler
        #if os(macOS)
        // An update replacing the app asks it to quit first (a notification from deploy.sh): it quits itself.
        UpdaterStatus.listenForQuit()
        #else
        // Control Center's Movie Night and Bedtime run here, in the app (their intents land in this process).
        SceneHook.run = { id in _ = await SceneRunner.run(id: id) }
        ControlHook.lights = { on in await ControlActions.lights(on) }
        ControlHook.sonosVolume = { up in await ControlActions.sonosVolume(up: up) }
        #endif
    }

    var body: some Scene {
        // An id, so the menu bar's Open Woodruff can bring the window back after it's been closed.
        WindowGroup(id: "main") {
            RootView()
                .environment(fleet)
                // How long from the tap until the window first showed (Settings → General → Speed).
                .onAppear { Timings.note("Open", since: Timings.processStart) }
                #if os(macOS)
                // Remembers the window's size and place, and which window is Woodruff's own.
                .background(WindowMemory())
                // How often the TVs are asked follows whether this window can be seen.
                .background(WindowActivityWatcher())
                #endif
                .task {
                    // Launch in steps, so the TVs come first and nothing else holds up the first screen. (Every start
                    // below is safe to run again, as it is for a window opened again.)
                    // 1. What has to be there before the TVs are asked, then the TVs: the Mac's pairing backup (it may
                    //    bring pairings back), notifications (the first answers can already be news), and the settings
                    //    sync's starting point (before anything below can write a setting that travels: a sign-in
                    //    renewed as the app opens must count as new, or the family's older copy could replace it).
                    // Watch's saved library and TMDB's answers, read in the background meanwhile.
                    DriveLibrary.prewarm()
                    TMDB.prewarm()
                    #if os(macOS)
                    if !Demo.isOn { MacPairingBackup.attach(fleet) }
                    #endif
                    // Apple's own prompts on first launch: notifications, then location while using (for weather).
                    if !Demo.isOn { Notifier.attach(to: fleet) }
                    SettingsSync.shared.prepare(fleet)
                    await fleet.start()
                    // How long until the TVs first answered (Settings → General → Speed).
                    Task {
                        for _ in 0..<600 where fleet.refreshedAt == nil { try? await Task.sleep(nanoseconds: 50_000_000) }
                        if fleet.refreshedAt != nil { Timings.note("TVs", since: Timings.processStart) }
                    }
                    #if os(iOS)
                    // Lock Screen Now Playing follows the TVs from launch, also while the app is in the background.
                    LiveActivitySync.shared.sync(fleet)
                    // The doorbell's Live Activity: its start address for the Macs, and any left over cleared.
                    DoorbellActivitySync.shared.start()
                    #endif
                    // 2. A moment later, what Home shows besides the TVs: speakers and lights, Samsung, the fans, the
                    //    cameras and Apple Home.
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    SmartHome.shared.start()
                    SmartThings.shared.start()
                    Dreo.shared.start()
                    Cync.shared.start()
                    DriveDownloads.shared.start()
                    NestCameras.shared.start()
                    #if os(iOS)
                    HomeKitLights.shared.start()
                    #else
                    // Apple Home on the Mac, through Woodruff Home Helper.
                    HomeBridgeClient.shared.start()
                    #endif
                    // 3. About a second in, what works behind the scenes: push, the weather's place, settings sync,
                    //    doorbell alerts, the Wi‑Fi, Siri's names and the pictures' disk cache.
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if !Demo.isOn { PushRelay.shared.start() }
                    WatchPrefetch.start(fleet)
                    // Crash and freeze reports from Apple, passed to the family's Macs.
                    Diagnostics.shared.start()
                    if !Demo.isOn && !fleet.hubs.isEmpty { LocationWeather.shared.start(fleet) }
                    SettingsSync.shared.start(fleet)
                    NestAlerts.shared.start(fleet)
                    #if os(macOS)
                    VehicleWatch.shared.start()
                    #endif
                    DecoWifi.shared.start()
                    // Siri learns the family's light, room, speaker and TV names (and again whenever they change).
                    SiriVocabulary.start()
                    // Keeps the pictures' disk cache from growing past its limit.
                    Task.detached(priority: .background) { await ImageStore.shared.trim() }
                }
                .onOpenURL { url in
                    // woodruff://remote (widgets, Control Center): open the remote; anything else is a pairing link.
                    if url.scheme == "woodruff" && url.host == "signed-in" { return }  // the end of a camera/Samsung sign-in
                    if url.scheme == "woodruff" && url.host == "home" {   // an appliance's Live Activity
                        UserDefaults.standard.set("home", forKey: "section")
                        return
                    }
                    // woodruff://camera?id=… (the TVs & Cameras widget): that camera, live.
                    if url.scheme == "woodruff" && url.host == "camera" {
                        let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "id" }?.value
                        UserDefaults.standard.set("home", forKey: "section")
                        if let id, !id.isEmpty { CameraStreams.shared.requested = id }
                        return
                    }
                    if url.scheme == "woodruff" && url.host == "remote" {
                        // woodruff://remote?tv=… (the TVs & Cameras widget): the remote on that TV.
                        if let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "tv" })?.value,
                           fleet.tv(id) != nil {
                            fleet.remoteAll = false
                            fleet.selectedID = id
                        }
                        #if os(macOS)
                        fleet.remotePanel = true
                        #else
                        UserDefaults.standard.set("remote", forKey: "section")
                        #endif
                    } else if let local = pairingLinkIsLocal(url) {
                        if local { fleet.handle(url: url) }
                        // A link for a TV elsewhere (from a web page, a message) can't add one, or put another in its place.
                        else { fleet.say("Not Paired", "That link isn’t for a TV on this Wi‑Fi. Pair from the TV’s Phone screen.") }
                    }
                }
                .onContinueUserActivity("com.woodruff.family.remote") { a in
                    if let id = a.userInfo?["tv"] as? String, fleet.tv(id) != nil { fleet.remoteAll = false; fleet.selectedID = id }
                    #if os(macOS)
                    fleet.remotePanel = true
                    #else
                    UserDefaults.standard.set("remote", forKey: "section")
                    #endif
                }
        }
        .onChange(of: scenePhase) { _, phase in
            // Only really leaving pauses things (not a glance at Notification Center or the app switcher). On the Mac,
            // `WindowActivity` says whether the app is in use (its windows shown or hidden).
            #if os(iOS)
            if phase == .active { fleet.setActive(true) } else if phase == .background { fleet.setActive(false) }
            #endif
            if phase == .background {
                AppWake.wentAway = true
                CameraStreams.shared.background()
                // Where things were left off, written before the system can end the app.
                DriveLibrary.shared.flush()
                #if os(iOS)
                AlertsRefresh.schedule()
                // A smaller app in the background is less likely to be closed by iOS (so it opens at once): pictures
                // not on screen are let go (they're on disk; the ones shown are kept by their views).
                ImageStore.shared.memory.empty()
                BlurStore.empty()
                #endif
            }
            #if os(macOS)
            // The Mac leaves the front for another app without going into the background: coming back from there is
            // coming back too (a new one-liner, the weather if it's been a while, everything asked afresh).
            if phase == .inactive { AppWake.wentAway = true }
            #endif
            if phase == .active {
                CameraStreams.shared.foreground()
                #if os(iOS)
                DoorbellActivitySync.shared.tidy()
                #endif
                // Back from the background (on the iPhone, not a glance at Control Center or Notification Center, which
                // only makes the app inactive for a moment): Home's weather if it's been a while, a new one-liner, and
                // everything else asked afresh.
                if AppWake.wentAway {
                    AppWake.wentAway = false
                    HomeWeather.shared.refresh()
                    HomeGreeting.shared.refresh()
                    SmartHome.shared.wake()
                    SettingsSync.shared.wake()
                    PushRelay.shared.wake()
                    #if os(iOS)
                    HomeKitLights.shared.refresh()
                    #endif
                    if !Demo.isOn && !fleet.hubs.isEmpty { LocationWeather.shared.start(fleet) }
                }
            }
        }
        #if os(iOS)
        // Closed a while: iOS wakes the app now and then to check for doorbell and camera alerts.
        .backgroundTask(.appRefresh(AlertsRefresh.id)) {
            await NestAlerts.shared.pullOnce(timeout: 15)
            await AlertsRefresh.schedule()
        }
        #endif
        #if os(macOS)
        .defaultSize(width: 1180, height: 800)
        .windowToolbarStyle(.unified)
        .commands {
            SidebarCommands()
            WoodruffCommands(fleet: fleet)
        }
        #endif

        #if os(macOS)
        Window("Mini Player", id: "mini") {
            MiniPlayerView().environment(fleet)
                // Floating over other apps it's still Woodruff in use: the TVs are asked at full speed while it shows.
                .background(WindowActivityWatcher())
        }
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)
        .windowLevel(.floating)
        .defaultPosition(.topTrailing)

        MenuBarExtra {
            MenuBarFleetView().environment(fleet)
                // Open, it shows the TVs live: asked at full speed while it's showing, as for the main window.
                .background(WindowActivityWatcher())
        } label: {
            MenuBarIcon(fleet: fleet)
        }
        .menuBarExtraStyle(.window)
        #endif
    }
}

/// The phone page's five sections.
enum AppSection: String, CaseIterable, Identifiable, Hashable {
    case home, remote, watch, send, memories, settings
    var id: String { rawValue }
    /// iPhone tabs (Send is in Settings); the Mac has no Remote tab (the remote slides out on the right).
    static let phone: [AppSection] = [.home, .remote, .watch, .memories, .settings]
    static let mac: [AppSection] = [.home, .watch, .send, .memories, .settings]
    var title: String {
        switch self {
        case .home: return "Home"
        case .remote: return "Remote"
        case .watch: return "Watch"
        case .send: return "Send"
        case .memories: return "Memories"
        case .settings: return "Settings"
        }
    }
    var symbol: String {
        switch self {
        case .home: return "house.fill"
        case .remote: return "appletvremote.gen4.fill"
        case .watch: return "play.tv.fill"
        case .send: return "paperplane.fill"
        case .memories: return "photo.stack.fill"
        case .settings: return "gearshape.fill"
        }
    }
    @ViewBuilder var view: some View {
        switch self {
        case .home: HomeView()
        case .remote: RemoteView()
        case .watch: WatchView()
        case .send: SendView()
        case .memories: MemoriesView()
        case .settings: SettingsView()
        }
    }
}

struct RootView: View {
    @Environment(Fleet.self) private var fleet
    @AppStorage("section") private var stored: String = AppSection.remote.rawValue

    private var selection: Binding<AppSection> {
        Binding(get: {
            let s = AppSection(rawValue: stored) ?? .home
            #if os(iOS)
            return AppSection.phone.contains(s) ? s : .home
            #else
            return s
            #endif
        }, set: { stored = $0.rawValue })
    }

    var body: some View {
        // A tapped "Person seen at the doorbell" opens that camera live. Waits for the camera list if the app was
        // just launched by the tap. (Read here, so the page redraws the moment the tap arrives.)
        // A camera this device doesn't list (its own camera sign-in isn't there, or not loaded yet) still opens: the live
        // view then says what's missing, instead of the tap doing nothing.
        let requested = CameraStreams.shared.requested.map { id in
            NestCameras.shared.cameras.first { $0.id == id }
                ?? NestCameras.Camera(id: id, name: "Camera", room: nil, doorbell: false, webRTC: true)
        }
        let banner = fleet.banner
        // Read here so the window notices the moment the thermostat pill is tapped.
        let thermostatOpen = ThermostatUI.shared.open
        Group {
            if fleet.hubs.isEmpty {
                WelcomeView()
            } else {
                #if os(macOS)
                MacRoot(selection: selection)
                #else
                tabs
                #endif
            }
        }
        .alert(item: Binding(get: { banner }, set: { fleet.banner = $0 })) { b in
            Alert(title: Text(b.title), message: Text(b.message), dismissButton: .default(Text("OK")))
        }
        // The thermostat controls, from the pill in Home's header (iPhone) or the toolbar (Mac). Shown from here, the
        // window's root, so the screen redrawing (it does every second or two while the TVs report) can't close it.
        .sheet(isPresented: Binding(get: { thermostatOpen }, set: { ThermostatUI.shared.open = $0 })) {
            ThermostatPanel()
                #if os(iOS)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                #endif
        }
        .cameraPresenter(Binding(
            get: { requested },
            set: { if $0 == nil { CameraStreams.shared.requested = nil } }
        ))
    }

    #if os(iOS)
    /// The Liquid Glass tab bar (it tucks away while scrolling), with what's playing riding above it.
    /// (The Lock Screen's Live Activity follows the remote's TV by itself: `LiveActivitySync.watch`.)
    private var tabs: some View {
        tabView
            .background { FleetSideEffects() }
    }

    private var tabView: some View {
        TabView(selection: selection) {
            ForEach(AppSection.phone) { s in
                Tab(s.title, systemImage: s.symbol, value: s) {
                    PhoneTabPage(section: s)
                }
                .badge(s == .settings ? fleet.settingsBadge : 0)
            }
        }
        // On iPad the tabs float at the top and turn into a sidebar, like the Mac's; on iPhone, the usual tab bar.
        .tabViewStyle(.sidebarAdaptable)
    }
    #endif
}

#if os(iOS)
/// One tab's page, with what's playing above the tabs. Apart from the window's root, so what's playing redraws only this.
private struct PhoneTabPage: View {
    @Environment(Fleet.self) private var fleet
    let section: AppSection

    var body: some View {
        let s = section
        let playing = fleet.selected?.nowPlaying
        NavigationStack { s.view }
            // What's playing floats above the tabs everywhere but Remote, which shows it itself.
            .safeAreaInset(edge: .bottom, spacing: 0) { if s != .remote { NowPlayingBar() } }
            // Room under every page's last row for the bar, so nothing ends up stuck behind it.
            .contentMargins(.bottom, s != .remote && playing != nil ? 96 : 0, for: .scrollContent)
            .animation(.smooth, value: playing?.title)
    }
}
#endif

/// What follows the TVs outside the app's pages (the widgets, and on the Mac Control Center). Nothing to draw: it's
/// a view of its own so a change to the TVs redraws only this, not the whole window.
struct FleetSideEffects: View {
    @Environment(Fleet.self) private var fleet

    #if os(iOS)
    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            // The Home Screen widgets: what's playing, the weather and the thermostat.
            .onChange(of: fleet.selected?.nowPlaying) { _, _ in PhoneWidgetSync.update(fleet) }
            .onChange(of: fleet.selectedID) { _, _ in PhoneWidgetSync.update(fleet) }
            .onChange(of: fleet.tvs.map { "\($0.id)|\($0.online)|\($0.nowPlaying?.title ?? "")|\($0.nowPlaying?.isPlaying ?? false)" }) { _, _ in PhoneWidgetSync.update(fleet) }
            .onChange(of: HomeWeather.shared.now) { _, _ in PhoneWidgetSync.update(fleet) }
            .onChange(of: AccessoryStore.shared.thermostat) { _, _ in PhoneWidgetSync.update(fleet) }
            .onChange(of: fleet.artwork(for: fleet.selected?.nowPlaying)) { _, _ in PhoneWidgetSync.update(fleet) }
            .task { PhoneWidgetSync.update(fleet) }
    }
    #else
    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: fleet.tvs) { _, _ in NowPlayingBridge.shared.update(fleet); WidgetSync.update(fleet) }
            .onChange(of: fleet.selectedID) { _, _ in NowPlayingBridge.shared.update(fleet); WidgetSync.update(fleet) }
            // Control Center's poster as soon as the library has it (the TV's first report usually comes before the
            // library does, and the TVs only change now and then once something plays steadily).
            .onChange(of: fleet.artwork(for: fleet.selected?.nowPlaying)) { _, _ in NowPlayingBridge.shared.update(fleet) }
    }
    #endif
}

#if os(macOS)
/// See `MacRoot.pageChrome`.
struct MacPageChrome<Bar: View, Bottom: View>: ViewModifier {
    var bar: Bar
    var bottom: Bottom

    func body(content: Content) -> some View {
        content
            .safeAreaBar(edge: .top) { bar }
            .safeAreaInset(edge: .bottom) { bottom }
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            .toolbar(removing: .title)
            .environment(\.macPageStack, true)
    }
}

/// Mac: a glass sidebar (Home, Watch, Send, Memories, Settings, and the TVs like rooms), Woodruff's own bar across the
/// top of the page (search on the left; the remote, Edit Home and the thermostat on the right; Back under the search
/// when there's somewhere to go back to), and the remote as a sidebar on the right that slides out when it's wanted.
struct MacRoot: View {
    @Environment(Fleet.self) private var fleet
    @Binding var selection: AppSection
    @SceneStorage("mac.tv") private var tvSelection: String?
    @State private var deviceSelection: String?
    private let home = SmartHome.shared
    private let nav = MacNav.shared
    private let layout = HomeLayout.shared
    // Each group in the sidebar folds away (click its heading's arrow); remembered between launches.
    @AppStorage("sidebar.tvs") private var showTVs = true
    @AppStorage("sidebar.speakers") private var showSpeakers = false
    @AppStorage("sidebar.lights") private var showLights = false
    @State private var palette = false
    @State private var query = ""
    @State private var columns: NavigationSplitViewVisibility = .all
    /// How wide the page area is: the search field, the greeting and the thermostat get shorter as it narrows so
    /// everything stays in one row.
    @State private var width: CGFloat = 1000
    private var narrow: Bool { width < 760 }
    /// Bumped by every click in the sidebar, so the page it opens starts fresh (Home's open TV closes, and so on).
    @State private var visit = 0
    /// Where the sidebar last went, and when: one click calls `go(to:)` twice (the list's selection and the click).
    @State private var lastGo = SidebarGo()
    /// The remote's sidebar has the keyboard (arrows, Return, Esc, H, M, + and − go to the TV).
    @FocusState private var remoteFocused: Bool
    @AppStorage("macWelcomeShown") private var welcomeShown = false

    private var section: AppSection { selection == .remote ? .home : selection }

    /// The camera filling everything right of the sidebar (one that's still in the camera list).
    private var fullCamera: NestCameras.Camera? {
        CameraStreams.shared.full.flatMap { id in NestCameras.shared.cameras.first { $0.id == id } }
    }

    /// Home's own first page (no TV or speaker picked, no search, nothing opened on top): Edit Home belongs here.
    private var onHome: Bool {
        section == .home && tvSelection == nil && deviceSelection == nil && query.isEmpty && nav.path.isEmpty
    }

    /// Watch's own page (not a list opened from it): its Movies | TV Shows and the TV it plays on sit in the top bar.
    private var onWatch: Bool {
        section == .watch && tvSelection == nil && deviceSelection == nil && query.isEmpty && nav.path.isEmpty
    }
    @AppStorage("watch.section") private var watchSection = "movies"

    var body: some View {
        @Bindable var fleet = fleet
        @Bindable var nav = nav
        let camera = fullCamera
        NavigationSplitView(columnVisibility: $columns) {
            List(selection: Binding<String?>(
                // Nothing is highlighted while searching, so a click on any item (Home too) always takes you there.
                get: { query.isEmpty ? (deviceSelection ?? tvSelection.map { "tv:\($0)" } ?? section.rawValue) : nil },
                set: { v in if let v { go(to: v) } })) {
                Section {
                    ForEach(AppSection.mac) { s in
                        Label(s.title, systemImage: s.symbol)
                            .tag(s.rawValue)
                            // A click on the section you're already in goes back to its first page.
                            .simultaneousGesture(TapGesture().onEnded { go(to: s.rawValue) })
                    }
                }
                Section("TVs", isExpanded: $showTVs) {
                    MacSidebarTVs(go: { go(to: $0) })
                }
                if !home.speakers.isEmpty {
                    Section("Speakers", isExpanded: $showSpeakers) {
                        ForEach(home.speakers) { r in
                            HStack {
                                Text(r.name)
                                Spacer()
                                if r.isPlaying { Image(systemName: "waveform").font(.caption).foregroundStyle(.secondary).symbolEffect(.variableColor.iterative) }
                            }
                            .contentShape(Rectangle())
                            .tag("spk:\(r.id)")
                            .simultaneousGesture(TapGesture().onEnded { go(to: "spk:\(r.id)") })
                        }
                    }
                }
                if !home.lights.isEmpty {
                    Section("Lights", isExpanded: $showLights) {
                        ForEach(home.lights) { l in
                            Text(l.name)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                                .tag("light:\(l.id)")
                                .simultaneousGesture(TapGesture().onEnded { go(to: "light:\(l.id)") })
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
        } detail: {
            NavigationStack(path: $nav.path) {
                root
                    .id(visit)
                    .environment(\.macPageTitle, query.isEmpty ? rootTitle : "Search")
                    .modifier(pageChrome)
                    .navigationDestination(for: PageRoute.self) { page in
                        page.view
                            .navigationBarBackButtonHidden(true)
                            .modifier(pageChrome)
                    }
            }
            .environment(\.macPageStack, true)
            // Not under Home's own first page: its backdrop covers the whole page (and draws what's playing itself).
            .background { if !onHome { AmbientArtwork() } }
            // A clicked camera fills everything right of the sidebar (Esc or ✕ to close).
            .overlay {
                if let cam = camera {
                    CameraLiveView(camera: cam)
                        .id(cam.id)
                        .transition(.opacity)
                }
            }
            // The window's own toolbar stays (hiding it took the close, minimize and full-screen buttons with it on
            // every page that has no title of its own), see-through and without a title, so Woodruff's bar shows.
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            .toolbar(removing: .title)
            // Never narrower than Home's tiles: the window stops shrinking before anything is clipped.
            .frame(minWidth: 480)
            .onGeometryChange(for: CGFloat.self) { ($0.size.width / 20).rounded() * 20 } action: { width = $0 }
        }
        .sheet(isPresented: $palette) { CommandPalette().sheetBanner().macResizable(width: 620, height: 480) }
        .background {
            Button("Command Palette") { palette = true }.keyboardShortcut("k", modifiers: .command).opacity(0).frame(width: 0, height: 0)
        }
        // A search starts from the page you're on; going to another section (from here, a notification or a widget)
        // starts it at its first page.
        .onChange(of: query) { old, new in if old.isEmpty && !new.isEmpty { nav.reset() } }
        // Leaving Watch leaves its search behind (the field is only there): no other page opens on old results.
        .onChange(of: selection) { _, new in nav.reset(); if new != .watch && !query.isEmpty { query = "" } }
        .background { FleetSideEffects() }
        .onAppear { SmartHome.shared.onChange = { WidgetSync.update(fleet) } }
        .sheet(isPresented: Binding(get: { !welcomeShown && !Demo.isOn }, set: { if !$0 { welcomeShown = true } })) { MacWelcome().macResizable(width: 520, height: 420) }
        .userActivity("com.woodruff.family.remote", isActive: fleet.remotePanel) { a in
            a.title = "Woodruff Remote"
            a.isEligibleForHandoff = true
            if let id = fleet.selectedID { a.addUserInfoEntries(from: ["tv": id]) }
        }
        .onAppear { SpaceKey.install() }
        .inspector(isPresented: $fleet.remotePanel) {
            RemoteView(embedded: true)
                .inspectorColumnWidth(min: 300, ideal: 320, max: 380)
                // Opened (the bar, ⌥⌘R, a TV's Remote button): the keyboard drives it straight away, without a
                // click into it first.
                .focused($remoteFocused)
                .onAppear { remoteFocused = true }
        }
    }

    /// The page the sidebar picked (or the search's results), under anything opened from it.
    @ViewBuilder private var root: some View {
        if !query.isEmpty {
            LibrarySearchResults(query: query)
                .safeAreaBar(edge: .top, spacing: 0) {
                    MacBackRow(title: "Search", backTo: rootTitle) { withAnimation(.smooth(duration: 0.25)) { query = "" } }
                }
        }
        // .id: a new item gets a fresh page (no name or level left over from the last one).
        else if let d = deviceSelection, d.hasPrefix("spk:") { SpeakerDetailView(speakerID: String(d.dropFirst(4))).id(d) }
        else if let d = deviceSelection, d.hasPrefix("light:") { LightDetailView(lightID: String(d.dropFirst(6))).id(d) }
        else if let id = tvSelection { TVDetailView(tvID: id).id(id) }
        else { section.view.id(section) }
    }

    /// Where the sidebar takes you, always: that section's (or TV's, speaker's, light's) first page, with the search
    /// cleared, anything opened on top closed, and a camera filling the window put away.
    private func go(to v: String) {
        // The same place again straight away is the same click (its selection, then the click itself): the page it
        // opened isn't started over a second time.
        let now = Date()
        if lastGo.target == v && now.timeIntervalSince(lastGo.at) < 0.4 { return }
        lastGo.target = v
        lastGo.at = now
        if CameraStreams.shared.full != nil { withAnimation(.smooth(duration: 0.25)) { CameraStreams.shared.full = nil } }
        nav.reset()
        if !query.isEmpty { query = "" }
        layout.stopArranging()
        visit += 1
        if v.hasPrefix("tv:") { deviceSelection = nil; tvSelection = String(v.dropFirst(3)) }
        else if v.hasPrefix("spk:") || v.hasPrefix("light:") { tvSelection = nil; deviceSelection = v }
        else if let s = AppSection(rawValue: v) { tvSelection = nil; deviceSelection = nil; selection = s }
    }

    // MARK: The bar

    /// The remote's button (the remote slides out at the right).
    private var remoteButton: some View {
        Button { withAnimation(.smooth) { fleet.remotePanel.toggle() } } label: {
                    Image(systemName: "appletvremote.gen4")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(fleet.remotePanel ? Color.white : .primary)
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                        .glass(Circle(), tint: fleet.remotePanel ? .accentColor : nil)
                }
                .buttonStyle(PressScale())
                .help("Remote (⌥⌘R)")
                .accessibilityLabel("Remote")
    }

    /// Home's Edit Home / Done, as tall as the greeting.
    private var editHomeButton: some View {
        Button { layout.arranging ? layout.stopArranging() : layout.startArranging() } label: {
                        Text(layout.arranging ? "Done" : "Edit Home")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(layout.arranging ? Color.white : .primary)
                            .padding(.horizontal, 18)
                            .frame(height: 44)
                            .contentShape(Capsule())
                            .glass(Capsule(), tint: layout.arranging ? .accentColor : nil)
                    }
                    .buttonStyle(PressScale())
    }

    /// What every page in the window has, its first page and every page opened on it alike, so nothing jumps from
    /// page to page: Woodruff's bar on top (with an opened page's Back under it), what's playing at the bottom, the
    /// window's toolbar see-through and without a title. Each page needs its own: an opened page is drawn over
    /// anything put on the stack around it (the bar and what's playing vanished on opened pages), and a page opened
    /// from an opened page only goes on the window's stack when it says so (`macPageStack`).
    private var pageChrome: MacPageChrome<some View, some View> {
        MacPageChrome(bar: topBar, bottom: nowPlaying)
    }

    /// What's playing, at the bottom of a page (not on Home, a TV's or a device's page, or with the remote open).
    @ViewBuilder private var nowPlaying: some View {
        if tvSelection == nil && deviceSelection == nil && section != .home && !fleet.remotePanel {
            NowPlayingBar().frame(maxWidth: 600).padding(.bottom, 8)
        }
    }

    /// The name of the page the sidebar picked (for Back).
    private var rootTitle: String {
        if let d = deviceSelection, d.hasPrefix("spk:") { return home.speaker(String(d.dropFirst(4)))?.name ?? "Speaker" }
        if let d = deviceSelection, d.hasPrefix("light:") { return home.light(String(d.dropFirst(6)))?.name ?? "Light" }
        if let id = tvSelection { return fleet.tv(id)?.name ?? "TV" }
        return section.title
    }

    /// Search on the left; on Home, the greeting with the weather in the middle; the remote, Edit Home (on Home)
    /// and the thermostat on the right, at any window size. (Back sits at the top of each opened page, under this.)
    private var topBar: some View {
        let greeting = onHome && width >= 900
        // Wide enough: the greeting sits in the very middle of the page, between the remote and Edit Home at the far left
        // and the thermostat at the far right. Narrower, it sits between them in the row (centred, it would collide).
        let centred = greeting && width >= 1000
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                // The sidebar's own button (in the window's title bar) shows it again when it's hidden: no second one here.
                // A page opened from another: Back, at the very left of this bar.
                if let open = nav.path.last {
                    Button { MacNav.shared.pop() } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "chevron.left").font(.body.weight(.semibold))
                            Text(open.backTo).lineLimit(1)
                        }
                        .padding(.horizontal, 4)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                    .keyboardShortcut("[", modifiers: .command)
                    .help("Back to \(open.backTo) (⌘[)")
                    // Clear of the window's close, minimise and zoom buttons when the sidebar is hidden.
                    .padding(.leading, columns == .detailOnly ? 64 : 0)
                }
                // Home: the remote and Edit Home at the far left, the greeting in the middle, the thermostat at the right.
                if onHome {
                    remoteButton
                    editHomeButton
                }
                // Search only on Watch, where it finds movies and shows.
                if section == .watch {
                    MacSearchField(text: $query, prompt: narrow || greeting ? "Search" : "Search Movies and TV Shows")
                        .frame(minWidth: 120, idealWidth: greeting ? 240 : 300, maxWidth: 320)
                }
                Spacer(minLength: 8)
                if greeting && !centred {
                    MacGreetingPill(compact: width < 1150)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    Spacer(minLength: 8)
                }
                if onWatch {
                    Picker("Library", selection: $watchSection) {
                        Text("Movies").tag("movies")
                        Text("TV Shows").tag("shows")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    Spacer(minLength: 8)
                    TVPicker()
                }
                // The remote's button is on Home only (⌥⌘R and the TVs menu open it anywhere).
                ThermostatChip(compact: narrow || (greeting && width < 1150), height: 44)
            }
            // Always the same height, so the pages below never jump as the bar's contents change.
            .frame(height: 46)
            .overlay {
                if centred {
                    MacGreetingPill(compact: width < 1100)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .animation(.smooth(duration: 0.3), value: greeting)
        .task(id: onHome) {
            guard onHome else { return }
            HomeWeather.shared.refresh()
            HomeGreeting.shared.refresh()
        }
        // Dragging the bar's empty space moves the window, like a title bar.
        .background { Color.clear.contentShape(Rectangle()).gesture(WindowDragGesture()) }
    }
}

/// The sidebar's TVs, apart from the window's root so a change to the TVs redraws only these rows.
private struct MacSidebarTVs: View {
    @Environment(Fleet.self) private var fleet
    let go: (String) -> Void

    var body: some View {
        ForEach(fleet.tvs) { tv in
            HStack {
                Text(tv.name)
                Spacer()
                if tv.needsAttention { Circle().fill(Palette.attention).frame(width: 7, height: 7) }
            }
            .foregroundStyle(tv.online ? .primary : .secondary)
            .contentShape(Rectangle())
            .tag("tv:\(tv.id)")
            .simultaneousGesture(TapGesture().onEnded { go("tv:\(tv.id)") })
        }
    }
}

/// Space plays or pauses the remote's TV from anywhere in the app (every TV that's on when the remote is set to
/// All TVs), except while typing, in a sheet or alert, or in the menu bar's panel. One monitor for the whole app
/// (a window each would press it twice).
@MainActor
enum SpaceKey {
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            guard e.keyCode == 49, e.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
                  let window = NSApp.keyWindow, window.sheetParent == nil, !(window is NSPanel),
                  !(window.firstResponder is NSText) else { return e }
            // Held down: one press, not play-pause-play.
            if !e.isARepeat {
                MacFeedback.key()
                MacActions.send("playpause", fleet: Fleet.shared)
            }
            return nil
        }
    }
}

/// Where the Mac's sidebar last went, and when. A plain class kept in `@State`: changing it redraws nothing.
final class SidebarGo {
    var target: String?
    var at = Date.distantPast
}

/// Mac: the TVs are asked at full speed while one of Woodruff's windows can be seen, and at the Mac's slower pace
/// (still enough for the menu bar, the widgets and the media keys) once every one is behind other windows, minimised
/// or closed. Each window (the main ones, the Mini Player and the menu bar's panel) says whether it can be seen
/// (`WindowActivityWatcher`); the fleet follows them all.
@MainActor
enum WindowActivity {
    private static var visible: Set<ObjectIdentifier> = []

    static func note(_ window: NSWindow, visible on: Bool) {
        let id = ObjectIdentifier(window)
        if on { visible.insert(id) } else { visible.remove(id) }
        let any = !visible.isEmpty
        // Only a change: the fleet asks every TV afresh each time it's made active.
        if any != Fleet.shared.isActive {
            Fleet.shared.setActive(any)
            // Nothing can be seen: the camera streams are let go after half a minute (they come back as a window is).
            // Alerts keep listening either way.
            if any { CameraStreams.shared.foreground() } else { CameraStreams.shared.background(after: 30) }
        }
    }
}

/// Tells `WindowActivity` whether its window can be seen, each time that changes.
struct WindowActivityWatcher: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Watcher() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class Watcher: NSView {
        private weak var watched: NSWindow?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window !== watched else { return }
            let center = NotificationCenter.default
            if let old = watched {
                center.removeObserver(self, name: nil, object: old)
                WindowActivity.note(old, visible: false)
            }
            watched = window
            guard let window else { return }
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
                center.addObserver(self, selector: #selector(changed), name: name, object: window)
            }
            center.addObserver(self, selector: #selector(closing), name: NSWindow.willCloseNotification, object: window)
            // Once the window is up (this runs while it's being put together).
            Task { @MainActor [weak self] in self?.changed() }
        }

        @objc private func changed() {
            guard let w = watched else { return }
            WindowActivity.note(w, visible: w.occlusionState.contains(.visible) && !w.isMiniaturized)
        }

        @objc private func closing() {
            guard let w = watched else { return }
            WindowActivity.note(w, visible: false)
        }
    }
}
#endif


#if os(macOS)
/// The Mac's search, at the top left of Woodruff's bar (⌘F to jump to it; Esc clears it).
struct MacSearchField: View {
    @Binding var text: String
    var prompt: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .focused($focused)
                .onExitCommand { text = ""; focused = false }
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear Search")
            }
        }
        .font(.system(size: 14))
        .padding(.horizontal, 16)
        // As tall as the greeting beside it.
        .frame(height: 44)
        .glass(Capsule(), interactive: false)
        .contentShape(Capsule())
        .onTapGesture { focused = true }
        .background { Button("") { focused = true }.keyboardShortcut("f", modifiers: .command).opacity(0) }
    }
}
#endif

#if os(macOS)
/// The menu bar icon. It's there even with every window closed, so it opens Woodruff's window when a camera or
/// doorbell alert is clicked and no window is open to show the camera in.
struct MenuBarIcon: View {
    var fleet: Fleet
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: fleet.menuBarSymbol)
            .onChange(of: CameraStreams.shared.requested) { _, id in
                guard id != nil else { return }
                if let w = MainWindow.current, w.isVisible || w.isMiniaturized { return }
                NSApp.activate()
                openWindow(id: "main")
            }
    }
}
#endif

/// Whether a pairing link (woodruff://…?url=…, or the TV's own address with its key) is for a TV on this network:
/// only those pair straight from a link, so a link from anywhere else can't add a TV or take another's place.
/// Nil when it isn't a pairing link at all (read the same way `Fleet.handle(url:)` reads it).
@MainActor
func pairingLinkIsLocal(_ url: URL) -> Bool? {
    var target = url
    if url.scheme == "woodruff", let inner = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "url" })?.value,
       let u = URL(string: inner) { target = u }
    guard let c = TVConnection.parse(target.absoluteString), let host = c.base.host else { return nil }
    return AndroidTVRemote.isLocal(host)
}
