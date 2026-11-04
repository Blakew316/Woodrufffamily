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

@main
struct WoodruffApp: App {
    @State private var fleet = Fleet.shared
    @Environment(\.scenePhase) private var scenePhase
    #if os(iOS)
    @UIApplicationDelegateAdaptor(PushAppDelegate.self) private var pushDelegate
    #endif

    init() {
        // Before launch finishes, as Apple asks: a tapped doorbell or camera alert that opened the app (Woodruff
        // wasn't running) still arrives here and opens that camera live, instead of being dropped.
        UNUserNotificationCenter.current().delegate = Notifier.handler
    }

    var body: some Scene {
        // An id, so the menu bar's Open Woodruff can bring the window back after it's been closed.
        WindowGroup(id: "main") {
            RootView()
                .environment(fleet)
                #if os(macOS)
                // Remembers the window's size and place, and which window is Woodruff's own.
                .background(WindowMemory())
                #endif
                .task {
                    #if os(macOS)
                    if !Demo.isOn { MacPairingBackup.attach(fleet) }
                    #endif
                    // Apple's own prompts on first launch: notifications, then location while using (for weather).
                    if !Demo.isOn { Notifier.attach(to: fleet); PushRelay.shared.start() }
                    if !Demo.isOn && !fleet.hubs.isEmpty { LocationWeather.shared.start(fleet) }
                    SmartHome.shared.start()
                    // Siri learns the family's light, room, speaker and TV names (and again whenever they change).
                    SiriVocabulary.start()
                    SmartThings.shared.start()
                    Dreo.shared.start()
                    DecoWifi.shared.start()
                    NestCameras.shared.start()
                    NestAlerts.shared.start(fleet)
                    SettingsSync.shared.start(fleet)
                    #if os(iOS)
                    HomeKitLights.shared.start()
                    #else
                    // Apple Home on the Mac, through Woodruff Home Helper.
                    HomeBridgeClient.shared.start()
                    #endif
                    await fleet.start()
                    #if os(iOS)
                    // Lock Screen Now Playing follows the TVs from launch, also while the app is in the background.
                    LiveActivitySync.shared.sync(fleet)
                    #endif
                }
                .onOpenURL { url in
                    // woodruff://remote (widgets, Control Center): open the remote; anything else is a pairing link.
                    if url.scheme == "woodruff" && url.host == "signed-in" { return }  // the end of a camera/Samsung sign-in
                    if url.scheme == "woodruff" && url.host == "remote" {
                        #if os(macOS)
                        fleet.remotePanel = true
                        #else
                        UserDefaults.standard.set("remote", forKey: "section")
                        #endif
                    } else { fleet.handle(url: url) }
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
            // Only really leaving pauses things (not a glance at Notification Center or the app switcher).
            if phase == .active { fleet.setActive(true) } else if phase == .background { fleet.setActive(false) }
            if phase == .background {
                CameraStreams.shared.background()
                #if os(iOS)
                AlertsRefresh.schedule()
                #endif
            }
            if phase == .active {
                CameraStreams.shared.foreground()
                SmartHome.shared.wake()
                SettingsSync.shared.wake()
                PushRelay.shared.wake()
                #if os(iOS)
                HomeKitLights.shared.refresh()
                #endif
            }
            if phase == .active && !Demo.isOn && !fleet.hubs.isEmpty { LocationWeather.shared.start(fleet) }
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
        .commands { WoodruffCommands(fleet: fleet) }
        #endif

        #if os(macOS)
        Window("Mini Player", id: "mini") {
            MiniPlayerView().environment(fleet)
        }
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)
        .windowLevel(.floating)
        .defaultPosition(.topTrailing)

        MenuBarExtra {
            MenuBarFleetView().environment(fleet)
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
        let requested = CameraStreams.shared.requested.flatMap { id in NestCameras.shared.cameras.first { $0.id == id } }
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
    private var tabs: some View {
        tabView
            .onChange(of: fleet.selected?.playing) { _, _ in LiveActivitySync.shared.sync(fleet) }
            .onChange(of: fleet.selectedID) { _, _ in LiveActivitySync.shared.sync(fleet) }
            .onChange(of: fleet.remoteAll) { _, _ in LiveActivitySync.shared.sync(fleet) }
    }

    private var tabView: some View {
        TabView(selection: selection) {
            ForEach(AppSection.phone) { s in
                Tab(s.title, systemImage: s.symbol, value: s) {
                    NavigationStack { s.view }
                        // What's playing floats above the tabs everywhere but Remote, which shows it itself.
                        .safeAreaInset(edge: .bottom, spacing: 0) { if s != .remote { NowPlayingBar() } }
                        // Room under every page's last row for the bar, so nothing ends up stuck behind it.
                        .contentMargins(.bottom, s != .remote && fleet.selected?.playing != nil ? 96 : 0, for: .scrollContent)
                        .animation(.smooth, value: fleet.selected?.playing?.title)
                }
                .badge(s == .settings ? fleet.attentionCount + fleet.updatesWaiting : 0)
            }
        }
    }
    #endif
}

#if os(macOS)
/// Mac: a glass sidebar (Home, Watch, Send, Memories, Settings, and the TVs like rooms), and the remote as a
/// sidebar on the right that slides out only when it's wanted.
struct MacRoot: View {
    @Environment(Fleet.self) private var fleet
    @Binding var selection: AppSection
    @SceneStorage("mac.tv") private var tvSelection: String?
    @State private var deviceSelection: String?
    private let home = SmartHome.shared
    // Each group in the sidebar folds away (click its heading's arrow); remembered between launches.
    @AppStorage("sidebar.tvs") private var showTVs = true
    @AppStorage("sidebar.speakers") private var showSpeakers = false
    @AppStorage("sidebar.lights") private var showLights = false
    @State private var palette = false
    @State private var query = ""
    /// The page area is too narrow for the full toolbar: the search field gets shorter so the thermostat stays.
    @State private var narrow = false
    /// The remote's sidebar has the keyboard (arrows, Return, Esc, H, M, + and − go to the TV).
    @FocusState private var remoteFocused: Bool
    @AppStorage("macWelcomeShown") private var welcomeShown = false

    private var section: AppSection { selection == .remote ? .home : selection }

    /// The camera filling everything right of the sidebar (one that's still in the camera list).
    private var fullCamera: NestCameras.Camera? {
        CameraStreams.shared.full.flatMap { id in NestCameras.shared.cameras.first { $0.id == id } }
    }

    var body: some View {
        @Bindable var fleet = fleet
        let camera = fullCamera
        NavigationSplitView {
            List(selection: Binding<String?>(
                get: { deviceSelection ?? tvSelection.map { "tv:\($0)" } ?? section.rawValue },
                set: { v in
                    guard let v else { return }
                    // Going somewhere in the sidebar closes a camera that's filling the window.
                    if CameraStreams.shared.full != nil { withAnimation(.smooth(duration: 0.25)) { CameraStreams.shared.full = nil } }
                    if v.hasPrefix("tv:") { deviceSelection = nil; tvSelection = String(v.dropFirst(3)) }
                    else if v.hasPrefix("spk:") || v.hasPrefix("light:") { tvSelection = nil; deviceSelection = v }
                    else if let s = AppSection(rawValue: v) { tvSelection = nil; deviceSelection = nil; selection = s }
                })) {
                Section {
                    ForEach(AppSection.mac) { s in Label(s.title, systemImage: s.symbol).tag(s.rawValue) }
                }
                Section("TVs", isExpanded: $showTVs) {
                    ForEach(fleet.tvs) { tv in
                        HStack {
                            Text(tv.name)
                            Spacer()
                            if tv.needsAttention { Circle().fill(Palette.attention).frame(width: 7, height: 7) }
                        }
                        .foregroundStyle(tv.online ? .primary : .secondary)
                        .tag("tv:\(tv.id)")
                    }
                }
                if !home.speakers.isEmpty {
                    Section("Speakers", isExpanded: $showSpeakers) {
                        ForEach(home.speakers) { r in
                            HStack {
                                Text(r.name)
                                Spacer()
                                if r.isPlaying { Image(systemName: "waveform").font(.caption).foregroundStyle(.secondary).symbolEffect(.variableColor.iterative) }
                            }
                            .tag("spk:\(r.id)")
                        }
                    }
                }
                if !home.lights.isEmpty {
                    Section("Lights", isExpanded: $showLights) {
                        ForEach(home.lights) { l in
                            Text(l.name)
                                .tag("light:\(l.id)")
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
        } detail: {
            NavigationStack {
                if !query.isEmpty { LibrarySearchResults(query: query) }
                // .id: a new item gets a fresh page (no name or level left over from the last one).
                else if let d = deviceSelection, d.hasPrefix("spk:") { SpeakerDetailView(speakerID: String(d.dropFirst(4))).id(d) }
                else if let d = deviceSelection, d.hasPrefix("light:") { LightDetailView(lightID: String(d.dropFirst(6))).id(d) }
                else if let id = tvSelection { TVDetailView(tvID: id).id(id) } else { section.view }
            }
            .background { AmbientArtwork() }
            // A clicked camera fills everything right of the sidebar (Esc or ✕ to close).
            .overlay {
                if let cam = camera {
                    CameraLiveView(camera: cam)
                        .id(cam.id)
                        .transition(.opacity)
                }
            }
            .toolbar(camera == nil ? .automatic : .hidden, for: .windowToolbar)
            .safeAreaInset(edge: .bottom) {
                if tvSelection == nil && deviceSelection == nil && section != .home && !fleet.remotePanel {
                    NowPlayingBar().frame(maxWidth: 600).padding(.bottom, 8)
                }
            }
            // Never narrower than Home's tiles: the window stops shrinking before anything is clipped.
            .frame(minWidth: 480)
            .onGeometryChange(for: Bool.self) { $0.size.width < 760 } action: { narrow = $0 }
        }
        .sheet(isPresented: $palette) { CommandPalette().sheetBanner().macResizable(width: 620, height: 480) }
        .background {
            Button("Command Palette") { palette = true }.keyboardShortcut("k", modifiers: .command).opacity(0).frame(width: 0, height: 0)
        }
        .onChange(of: fleet.tvs) { _, _ in NowPlayingBridge.shared.update(fleet); WidgetSync.update(fleet) }
        .onChange(of: fleet.selectedID) { _, _ in NowPlayingBridge.shared.update(fleet); WidgetSync.update(fleet) }
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
                // Opened (the toolbar, ⌥⌘R, a TV's Remote button): the keyboard drives it straight away, without a
                // click into it first.
                .focused($remoteFocused)
                .onAppear { remoteFocused = true }
        }
        .toolbar {
            // Left: the remote, Edit Home (on Home) and search, side by side.
            ToolbarItemGroup(placement: .navigation) {
                Button { withAnimation(.smooth) { fleet.remotePanel.toggle() } } label: {
                    Image(systemName: "appletvremote.gen4")
                }
                .help("Remote (⌥⌘R)")
                .keyboardShortcut("r", modifiers: [.command, .option])
                if section == .home && tvSelection == nil && deviceSelection == nil && query.isEmpty {
                    Button("Edit Home") { HomeLayout.shared.editing = true }
                }
                ToolbarSearchField(text: $query, prompt: narrow ? "Search" : "Movies and TV Shows", width: narrow ? 170 : 260)
            }
            ToolbarSpacer(.flexible)
            // Right: the thermostat, always there.
            ToolbarItem { ThermostatChip() }
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
#endif


#if os(macOS)
/// The Mac's search: a field in the toolbar beside Edit Home (⌘F to jump to it).
struct ToolbarSearchField: View {
    @Binding var text: String
    var prompt: String
    /// Shorter when the window is narrow, so the toolbar's other items keep their place.
    var width: CGFloat = 260
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
            }
        }
        .padding(.horizontal, 10)
        .frame(width: width, height: 28)
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
