import SwiftUI
import UserNotifications
import WoodruffKit
#if os(iOS) || os(tvOS)
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
    /// Whether the app has been in front at all since it started (iOS also starts it by itself, in the background).
    static var beenActive = false
    /// When the app started running (set as it does).
    static var started: Date?
}

#if os(iOS)
/// Back in front on the iPhone or iPad: the accounts (SmartThings, the cameras, Cync, Dreo, the Wi‑Fi) are asked
/// again now. Each looks on a clock of its own, from every half minute to every ten, and one whose sign-in ran out
/// or whose connection died while the app was away kept saying so until that clock came round, or until the app
/// was closed and opened again.
@MainActor
enum AccountsWake {
    /// Goes up each time the app comes back: an earlier round's later looks are dropped for the newer one's. (Nothing
    /// is ever called off mid-request: a request cut short would itself read as something being wrong.)
    private static var round = 0

    static func now() {
        round += 1
        let mine = round
        Task {
            // The connections kept open to the services died while the app slept: new ones from here on.
            URLSession.shared.freshConnections()
            // A moment first for the family's newest sign-ins (another device may have renewed one while this one
            // was away): the settings sync, woken just before this, is reading them from the TVs. Then every account;
            // then, twice more, any that still says something is wrong (the Wi‑Fi, or the TVs that hold the
            // family's sign-ins, may only just be back).
            for (pass, wait) in ([1.5, 6, 20] as [Double]).enumerated() {
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                guard mine == round else { return }
                await ask(onlyFailing: pass > 0)
            }
        }
    }

    private static func ask(onlyFailing: Bool) async {
        let st = SmartThings.shared, nest = NestCameras.shared, cync = Cync.shared, dreo = Dreo.shared, deco = DecoWifi.shared
        let askST = st.connected && (!onlyFailing || st.error != nil)
        let askNest = nest.connected && (!onlyFailing || nest.error != nil)
        let askCync = cync.connected && (!onlyFailing || cync.error != nil)
        let askDreo = dreo.connected && (!onlyFailing || dreo.error != nil)
        let askDeco = deco.connected && (!onlyFailing || deco.error != nil)
        await withTaskGroup(of: Void.self) { g in
            if askST { g.addTask { await st.refresh(full: false) } }
            if askNest { g.addTask { await nest.load() } }
            if askCync { g.addTask { await cync.wake() } }
            if askDreo { g.addTask { await dreo.refresh(full: false) } }
            if askDeco { g.addTask { await deco.refresh() } }
        }
    }
}
#endif

#if !os(tvOS)
@main
struct WoodruffApp: App {
    @State private var fleet = Fleet.shared
    @Environment(\.scenePhase) private var scenePhase
    #if os(iOS) || os(tvOS)
    @UIApplicationDelegateAdaptor(PushAppDelegate.self) private var pushDelegate
    #endif
    #if os(macOS)
    /// Clicking the Dock icon brings the window back (from the Dock, from behind, or anew after it was closed).
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate
    #endif

    init() {
        AppWake.started = Date()
        // The saved sign-ins and keys the settings sync reads before the TVs are first asked, read now in the
        // background (each Keychain read is slow), so by then they're at hand instead of holding up the main thread.
        // The cameras' sign-in first: a tapped camera alert that opened the app needs it straight away.
        // Then the family's code and each TV's key, which the settings sync reads before the TVs are first asked.
        let keys = ["nest.refresh", "nest.scopes", "nest.access", "nest.expires", "nest.project", "nest.client", "nest.secret"]
            + ["family.code"] + Fleet.shared.hubs.map { "family.hub.\($0.id)" }
            + SettingsSync.keychainKeys + Fleet.shared.tvs.map { "lg.\($0.id)" }
        Task.detached(priority: .userInitiated) { for k in keys { _ = Keychain.read(k) } }
        // Watch's saved library and TMDB's answers start being read now, in the background: opened on Watch, the
        // first frame needs them, and read then they were decoded on the main thread.
        DriveLibrary.prewarm()
        TMDB.prewarm()
        // Before launch finishes, as Apple asks: a tapped doorbell or camera alert that opened the app (Woodruff
        // wasn't running) still arrives here and opens that camera live, instead of being dropped.
        UNUserNotificationCenter.current().delegate = Notifier.handler
        #if os(macOS)
        // An update replacing the app asks it to quit first (a notification from deploy.sh): it quits itself.
        UpdaterStatus.listenForQuit()
        // Woodruff has one window: no window tabs (each tab was another copy of it, sharing the first one's pages).
        NSWindow.allowsAutomaticWindowTabbing = false
        #else
        // Control Center's Movie Night and Bedtime run here, in the app (their intents land in this process).
        SceneHook.run = { id in _ = await SceneRunner.run(id: id) }
        ControlHook.lights = { on in await ControlActions.lights(on) }
        ControlHook.sonosVolume = { up in await ControlActions.sonosVolume(up: up) }
        // A fresh start never opens on Search with nothing typed: on Watch, whose library it searches.
        if UserDefaults.standard.string(forKey: "section") == AppSection.search.rawValue {
            UserDefaults.standard.set(AppSection.watch.rawValue, forKey: "section")
        }
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
                // One window: a link from a widget or Handoff comes to this one when it's open (each opened another
                // window beside it, sharing its pages, its remote and its sheets). Closed, a new one still opens.
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
                #endif
                .task {
                    // Launch in steps, so the TVs come first and nothing else holds up the first screen. (Every start
                    // below is safe to run again, as it is for a window opened again.)
                    // 1. What has to be there before the TVs are asked, then the TVs: the Mac's pairing backup (it may
                    //    bring pairings back), notifications (the first answers can already be news), and the settings
                    //    sync's starting point (before anything below can write a setting that travels: a sign-in
                    //    renewed as the app opens must count as new, or the family's older copy could replace it).
                    // Notes any moment the screen freezes, and where (Settings → General → Speed).
                    StallMonitor.start()
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
                    #if os(iOS) || os(tvOS)
                    // Lock Screen Now Playing follows the TVs from launch, also while the app is in the background.
                    LiveActivitySync.shared.sync(fleet)
                    // The doorbell's Live Activity: its start address for the Macs, and any left over cleared.
                    DoorbellActivitySync.shared.start()
                    #endif
                    // 2. A moment later, what Home shows besides the TVs: speakers and lights, Samsung, the fans, the
                    //    cameras and Apple Home.
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    // Opened by a tapped camera alert: the cameras first, and the rest a moment later, once the
                    // camera's picture is up and its stream has the network to itself.
                    let forCamera = CameraStreams.shared.requested != nil
                        || (CameraStreams.shared.openedFromAlertAt.map { $0.timeIntervalSinceNow > -5 } ?? false)
                    if forCamera {
                        NestCameras.shared.start()
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                    }
                    SmartHome.shared.start()
                    SmartThings.shared.start()
                    Dreo.shared.start()
                    Cync.shared.start()
                    #if os(iOS) || os(tvOS)
                    DriveDownloads.shared.start()   // the Mac's starts with Watch's pictures, below
                    #endif
                    if !forCamera { NestCameras.shared.start() }
                    #if os(iOS) || os(tvOS)
                    HomeKitLights.shared.start()
                    #else
                    // Apple Home on the Mac, through Woodruff Home Helper.
                    HomeBridgeClient.shared.start()
                    #endif
                    // 3. About a second in, what works behind the scenes: push, the weather's place, settings sync,
                    //    doorbell alerts, the Wi‑Fi, Siri's names and the pictures' disk cache.
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if !Demo.isOn { PushRelay.shared.start() }
                    #if os(macOS)
                    // The Mac: Watch's pictures and Apple's reports a few seconds later still (the window and the TVs first).
                    Task {
                        try? await Task.sleep(nanoseconds: 4_000_000_000)
                        DriveDownloads.shared.start()
                        WatchPrefetch.start(fleet)
                        Diagnostics.shared.start()
                    }
                    #else
                    WatchPrefetch.start(fleet)
                    // Crash and freeze reports from Apple, passed to the family's Macs.
                    Diagnostics.shared.start()
                    #endif
                    if !Demo.isOn && !fleet.hubs.isEmpty { LocationWeather.shared.start(fleet) }
                    SettingsSync.shared.start(fleet)
                    NestAlerts.shared.start(fleet)
                    GoogleGrants.start(fleet)
                    #if os(macOS)
                    VehicleWatch.shared.start()
                    // The cameras' pictures for the family's Apple TVs (the Mac Studio only).
                    CameraShare.shared.start()
                    // A film played by the app itself, when it was opened with -filmCheck (see `FilmCheck`).
                    FilmCheck.startIfAsked()
                    // Pictures of its own window, when it was opened with -macSnapshot (see `MacSnapshot`).
                    MacSnapshot.startIfAsked()
                    #endif
                    DecoWifi.shared.start()
                    // Siri learns the family's light, room, speaker and TV names (and again whenever they change).
                    SiriVocabulary.start()
                    // Keeps the pictures' disk cache from growing past its limit.
                    Task.detached(priority: .background) { await ImageStore.shared.trim() }
                }
                .onOpenURL { url in
                    #if os(macOS)
                    // The link came to this window (not to a new one): out of the Dock, or back from ⌘H, if it's there.
                    MainWindowOpener.front()
                    #endif
                    // woodruff://remote (widgets, Control Center): open the remote; anything else is a pairing link.
                    if url.scheme == "woodruff" && url.host == "signed-in" { return }  // the end of a camera/Samsung sign-in
                    if url.scheme == "woodruff" && url.host == "join" {   // an Apple TV's QR code: give it the family's code
                        Task { await JoinTV.send(url, fleet: fleet) }
                        return
                    }
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
                        else { fleet.alert("Not Paired", "That link isn’t for a TV on this Wi‑Fi. Pair from the TV’s Phone screen.") }
                    }
                }
                .onContinueUserActivity("com.woodruff.family.remote") { a in
                    if let id = a.userInfo?["tv"] as? String, fleet.tv(id) != nil { fleet.remoteAll = false; fleet.selectedID = id }
                    #if os(macOS)
                    MainWindowOpener.front()
                    fleet.remotePanel = true
                    #else
                    UserDefaults.standard.set("remote", forKey: "section")
                    #endif
                }
        }
        .onChange(of: scenePhase) { _, phase in
            // Only really leaving pauses things (not a glance at Notification Center or the app switcher). On the Mac,
            // `WindowActivity` says whether the app is in use (its windows shown or hidden).
            #if os(iOS) || os(tvOS)
            if phase == .active { fleet.setActive(true) } else if phase == .background { fleet.setActive(false) }
            #endif
            if phase == .background {
                AppWake.wentAway = true
                CameraStreams.shared.background()
                // Where things were left off, written before the system can end the app.
                DriveLibrary.shared.flush()
                #if os(iOS) || os(tvOS)
                AlertsRefresh.schedule()
                WidgetRefresh.schedule()
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
                #if os(iOS) || os(tvOS)
                DoorbellActivitySync.shared.tidy()
                // Any camera alert in the last quarter hour this iPhone never got (its push was missed): fetched now.
                Task { await NestAlerts.shared.pullOnce(timeout: 8) }
                #endif
                // Back from the background (on the iPhone, not a glance at Control Center or Notification Center, which
                // only makes the app inactive for a moment): Home's weather if it's been a while, a new one-liner, and
                // everything else asked afresh.
                #if os(iOS)
                // iOS also starts the app by itself, in the background (to look for camera alerts, to refresh the
                // widgets). Opened by hand long after that, it has been away just the same, though it was never sent
                // to the background: what it knows is from then, often asked with the iPhone locked or away from home.
                if !AppWake.beenActive, let started = AppWake.started, Date().timeIntervalSince(started) > 20 { AppWake.wentAway = true }
                #endif
                AppWake.beenActive = true
                if AppWake.wentAway {
                    AppWake.wentAway = false
                    HomeWeather.shared.refresh()
                    HomeGreeting.shared.refresh()
                    SmartHome.shared.wake()
                    SettingsSync.shared.wake()
                    PushRelay.shared.wake()
                    #if os(iOS)
                    AccountsWake.now()
                    #endif
                    #if os(iOS) || os(tvOS)
                    HomeKitLights.shared.refresh()
                    #endif
                    if !Demo.isOn && !fleet.hubs.isEmpty { LocationWeather.shared.start(fleet) }
                }
            }
        }
        #if os(iOS) || os(tvOS)
        // Closed a while: iOS wakes the app now and then to check for doorbell and camera alerts.
        .backgroundTask(.appRefresh(AlertsRefresh.id)) {
            await NestAlerts.shared.pullOnce(timeout: 15)
            await AlertsRefresh.schedule()
        }
        // Now and then: the cameras' latest pictures and the TVs' state, for the widgets.
        .backgroundTask(.appRefresh(WidgetRefresh.id)) {
            await WidgetRefresh.run()
            await WidgetRefresh.schedule()
        }
        #endif
        #if os(macOS)
        .defaultSize(width: 1180, height: 800)
        .windowToolbarStyle(.unified)
        // (No sidebar commands: the window has no sidebar, and View › Show Sidebar did nothing.)
        .commands {
            WoodruffCommands(fleet: fleet)
        }
        #elseif os(iOS)
        // iPad's menu bar, and the same shortcuts on a keyboard.
        .commands { PadCommands(fleet: fleet) }
        #endif

        #if os(macOS)
        Window("Mini Player", id: "mini") {
            MiniPlayerView().environment(fleet)
                // Floating over other apps it's still Woodruff in use: the TVs are asked at full speed while it shows.
                .background(WindowActivityWatcher())
        }
        // A small panel, not a window with a title bar: the player draws it (and its close button), it's as big as
        // what it shows, it's moved by dragging it anywhere, and it isn't put back by itself when Woodruff next opens.
        .windowStyle(.plain)
        .windowResizability(.contentSize)
        .windowBackgroundDragBehavior(.enabled)
        .restorationBehavior(.disabled)
        .windowLevel(.floating)
        .defaultPosition(.topTrailing)
        // The Window menu lists it by itself (a second Mini Player item of Woodruff's own sat beside it): ⇧⌘M is
        // that item's key.
        .keyboardShortcut("m", modifiers: [.command, .shift])

        MenuBarExtra {
            MenuBarFleetView().environment(fleet)
                // Open, it shows the TVs live: asked at full speed while it's showing, as for the main window.
                .background(WindowActivityWatcher())
        } label: {
            MenuBarIcon(fleet: fleet)
        }
        .menuBarExtraStyle(.window)

        // Settings… (⌘,): this Mac's own settings, in the Mac's standard Settings window. (The family's are the
        // Settings page of Woodruff's window.)
        Settings {
            MacSettingsWindow().environment(fleet)
        }
        #endif
    }
}

#endif

#if os(iOS)
/// iPad's menu bar (and a keyboard's shortcuts): the Mac's TVs menu, without what only a Mac has (its updater, the
/// Mini Player, updating every Android TV). The shortcuts are the Mac's.
struct PadCommands: Commands {
    var fleet: Fleet

    var body: some Commands {
        CommandMenu("TVs") {
            Button("Refresh All") { Task { await fleet.refresh(); await fleet.loadAllHealth() } }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            // The remote is a tab of its own here.
            Button("Remote") { UserDefaults.standard.set("remote", forKey: "section") }
                .keyboardShortcut("r", modifiers: [.command, .option])
            Divider()
            // Each TV, to point the remote at (⌘1 to ⌘9).
            ForEach(Array(tvNames().enumerated()), id: \.offset) { i, name in
                Button(name) { pick(i) }.keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
            }
            Divider()
            Button("Play / Pause") { send("playpause") }.keyboardShortcut("p", modifiers: [.command, .option])
            Button("Home") { send("home") }.keyboardShortcut("h", modifiers: [.command, .shift])
            Button("Mute") { send("mute") }.keyboardShortcut("m", modifiers: [.command, .option])
            Button("Volume Up") { send("volup") }.keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Button("Volume Down") { send("voldown") }.keyboardShortcut(.downArrow, modifiers: [.command, .option])
        }
    }

    /// The first nine paired TVs' names. From `pairedNames` (the same TVs in the same order), not the TVs themselves:
    /// the menu is rebuilt whenever what it reads changes, and the TVs change every second or two while their names
    /// hardly ever do.
    @MainActor private func tvNames() -> [String] { Array(fleet.pairedNames.prefix(9)) }

    /// The remote, pointed at the paired TV [i] places down the list (the order the menu shows them in).
    @MainActor private func pick(_ i: Int) {
        let list = fleet.tvs.filter { !$0.isUnpaired }
        guard i < list.count else { return }
        fleet.remoteAll = false
        fleet.selectedID = list[i].id
    }

    /// The remote's keys, sent as the remote sends them: to its TV, or to every TV that's on when it's set to All TVs
    /// (where one TV not answering isn't worth a message, as on the remote itself).
    @MainActor private func send(_ key: String) {
        let all = fleet.remoteAll
        let targets = all ? fleet.tvs.filter { $0.online && !$0.isUnpaired } : (fleet.selected.map { [$0] } ?? [])
        for tv in targets {
            Task {
                do { try await RemoteKeys.press(key, on: tv, fleet: fleet) } catch { if !all { fleet.show(error) } }
            }
        }
    }
}
#endif

#if os(iOS)
/// What's typed in the Search tab's field on iPhone and iPad. Kept outside the views: on iPad the field is the tab
/// view's own (in the top bar), on iPhone the Search page's, and the Search page reads what's typed either way.
@Observable @MainActor
final class PhoneSearch {
    static let shared = PhoneSearch()
    var query = ""
}
#endif

/// The phone page's five sections.
enum AppSection: String, CaseIterable, Identifiable, Hashable {
    case home, remote, watch, send, memories, settings
    /// iPhone and iPad: the tab bar's own Search tab (Watch's library). Not one of `phone`'s: it's a tab apart.
    case search
    var id: String { rawValue }
    /// iPhone tabs (Send is in Settings); the Mac has no Remote tab (the remote slides out on the right).
    // Memories is no longer in the app's navigation (the TVs' slideshow still shows them).
    #if os(tvOS)
    static let phone: [AppSection] = [.home, .watch, .settings]
    #else
    static let phone: [AppSection] = [.home, .remote, .watch, .settings]
    #endif
    static let mac: [AppSection] = [.home, .watch, .settings]   // Send is in Settings (TVs group)
    var title: String {
        switch self {
        case .home: return "Home"
        case .remote: return "Remote"
        case .watch: return "Watch"
        case .send: return "Send"
        case .memories: return "Memories"
        case .settings: return "Settings"
        case .search: return "Search"
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
        case .search: return "magnifyingglass"
        }
    }
    @ViewBuilder var view: some View {
        switch self {
        case .home: HomeView()
        case .remote: RemoteView()
        case .watch: WatchView()
        case .send: SendView()
        case .memories: MemoriesView()
        case .search: SearchPage()
        case .settings:
            #if os(macOS)
            MacSettingsView()
            #else
            SettingsView()
            #endif
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
            // The four tabs, and the tab bar's own Search beside them.
            return AppSection.phone.contains(s) || s == .search ? s : .home
            #elseif os(tvOS)
            return AppSection.phone.contains(s) ? s : .home
            #else
            // The remote (a panel) or a page that's left the bar (Memories) opens Home instead.
            return AppSection.mac.contains(s) || s == .remote ? s : .home
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
        #if !os(macOS)
        let banner = fleet.banner
        #endif
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
        #if os(macOS)
        // What the app says back, on the Mac: a result that only confirms ("Sent") is a line at the foot of the window
        // that goes by itself; what went wrong is still an alert; and anything said while the window was closed is
        // dropped, not shown whenever it next opens.
        .windowBanner()
        #else
        .alert(item: Binding(get: { banner }, set: { fleet.banner = $0 })) { b in
            Alert(title: Text(b.title), message: Text(b.message), dismissButton: .default(Text("OK")))
        }
        #endif
        // The thermostat controls, from the pill in Home's header (iPhone) or the toolbar (Mac). Shown from here, the
        // window's root, so the screen redrawing (it does every second or two while the TVs report) can't close it.
        #if os(macOS)
        // The Mac: a popover pointing at the pill (where it was when it was clicked: `MacPopoverRoot`), not a sheet.
        .background { MacAnchor { MacPopoverRoot.view = $0 }.allowsHitTesting(false) }
        .popover(isPresented: Binding(get: { thermostatOpen }, set: { open in
            ThermostatUI.shared.open = open
            if !open { ThermostatUI.shared.closedAt = Date() }
        }), attachmentAnchor: ThermostatUI.shared.popoverAnchor, arrowEdge: .bottom) {
            ThermostatPanel()
        }
        #else
        // (Not on iPad, where they come out of the pill itself as a popover: `ThermostatChip`.)
        .sheet(isPresented: Binding(get: { thermostatOpen && !PillPanels.popOver }, set: { ThermostatUI.shared.open = $0 })) {
            ThermostatPanel()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        #endif
        #if os(iOS)
        // iPhone and iPad: opened from the topmost screen, so it comes up over a sheet or the film player too
        // (`CameraRequest`).
        .onChange(of: requested?.id, initial: true) { _, _ in CameraRequest.changed(requested) }
        #else
        .cameraPresenter(Binding(
            get: { requested },
            set: { if $0 == nil { CameraStreams.shared.requested = nil } }
        ))
        #endif
    }

    #if os(iOS) || os(tvOS)
    /// The Liquid Glass tab bar (on iPhone it tucks away while a page scrolls down), with what's playing as its accessory.
    /// (The Lock Screen's Live Activity follows the remote's TV by itself: `LiveActivitySync.watch`.)
    private var tabs: some View {
        tabView
            // Once the first frame is on screen: what it watches (the thermostat, the weather) makes the smart-home
            // stores read everything they keep, which opening on Remote or Watch needs nowhere in its first frame.
            .background { AfterFirstFrame { FleetSideEffects() } }
    }

    private var tabView: some View {
        TabView(selection: selection) {
            ForEach(AppSection.phone) { s in
                Tab(s.title, systemImage: s.symbol, value: s) {
                    PhoneTabPage(section: s)
                }
                #if os(iOS)
                .badge(s == .settings ? fleet.settingsBadge : 0)
                #endif
            }
            #if os(iOS)
            // Search. On iPad it's the tab view's own Search tab: its field sits in the top bar, whichever tab is
            // showing. On iPhone it's a tab like the others, with its field at the top of its page: an iPhone's own
            // Search tab needs the tab view itself to be searchable, and iOS then shows that field on Watch's page too.
            Tab("Search", systemImage: "magnifyingglass", value: AppSection.search, role: Self.pad ? .search : nil) {
                PhoneTabPage(section: .search)
            }
            #endif
        }
        // On iPad the tabs float at the top and turn into a sidebar, like the Mac's; on iPhone, the usual tab bar.
        .tabViewStyle(.sidebarAdaptable)
        #if os(iOS)
        // iPad: the Search tab's field is the tab view's own (`searchable` on the tab view: the tab with the search
        // role gets it). Picking the tab starts a search; closing the search goes back to the tab before.
        .modifier(TabViewSearch(onSearch: selection.wrappedValue == .search))
        // iPhone: the tab bar tucks away while a page scrolls down, and comes back on the way up.
        .modifier(TabBarTucksAway())
        // What's playing, as the tab bar's own accessory: above it, and in line with it once it has tucked away.
        .modifier(TabViewNowPlaying(onRemote: selection.wrappedValue == .remote))
        #endif
    }

    #if os(iOS)
    /// An iPad (whatever its window's width).
    private static let pad = UIDevice.current.userInterfaceIdiom == .pad

    /// iPad: the tab view's search field, for its Search tab. (Not on iPhone, whose Search page has its own field:
    /// `SearchPage`.) A modifier of its own, so typing redraws this and the Search page, not the window's root.
    private struct TabViewSearch: ViewModifier {
        /// The Search tab is the one showing.
        var onSearch: Bool
        @Bindable private var search = PhoneSearch.shared

        func body(content: Content) -> some View {
            if UIDevice.current.userInterfaceIdiom == .pad {
                content
                    .searchable(text: $search.query, prompt: "Movies and TV Shows")
                    // Names of films and shows: no corrections while the Search tab is the one typed in. (Only then:
                    // this reaches every field in the tabs.)
                    .autocorrectionDisabled(onSearch)
                    .tabViewSearchActivation(.searchTabSelection)
            } else {
                content
            }
        }
    }

    /// iPhone: the tab bar tucks away while a page scrolls down, and comes back on the way up
    /// (`tabBarMinimizeBehavior(.onScrollDown)`). Not from the app's very first moment: told so then, iOS 26 and 27
    /// show the first tab picked as the app opens and slide to the one it really opened on. So it's told a second later.
    private struct TabBarTucksAway: ViewModifier {
        @State private var behavior: TabBarMinimizeBehavior = .never

        func body(content: Content) -> some View {
            content
                .tabBarMinimizeBehavior(behavior)
                .task {
                    guard behavior == .never else { return }
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if !Task.isCancelled { behavior = .onScrollDown }
                }
        }
    }
    #endif
    #endif
}

#if os(iOS) || os(tvOS)
/// One tab's page: its pages as `PhoneTabStack` lays them out. (What's playing isn't part of the page: on iPhone and
/// iPad it's the tab bar's accessory, which iOS keeps clear of every page by itself.)
private struct PhoneTabPage: View {
    let section: AppSection

    var body: some View {
        let s = section
        PhoneTabStack(section: s)
    }
}
#endif

/// What follows the TVs outside the app's pages (the widgets, and on the Mac Control Center). Nothing to draw: it's
/// a view of its own so a change to the TVs redraws only this, not the whole window.
/// What it holds is made a moment after the first frame is on screen, not with it.
struct AfterFirstFrame<Content: View>: View {
    @ViewBuilder var content: () -> Content
    @State private var ready = false

    var body: some View {
        ZStack { if ready { content() } }
            .task {
                guard !ready else { return }
                try? await Task.sleep(nanoseconds: 250_000_000)
                ready = true
            }
    }
}

struct FleetSideEffects: View {
    @Environment(Fleet.self) private var fleet

    #if os(iOS) || os(tvOS)
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
/// See `MacRoot.rootChrome`.
struct MacPageChrome<Header: View, Bottom: View>: ViewModifier {
    var header: Header
    /// The room between the header and the page: none when there's no header (the page starts right under the toolbar).
    var headerSpacing: CGFloat?
    /// The window's toolbar over this page: see-through (hidden) where the page's backdrop and its own row run up
    /// under it; the system's own (automatic) where the page scrolls straight under the toolbar, so what passes under
    /// the title and the buttons stays readable.
    var toolbarBackground: Visibility
    var bottom: Bottom

    func body(content: Content) -> some View {
        content
            .safeAreaBar(edge: .top, spacing: headerSpacing) { header }
            .safeAreaInset(edge: .bottom) { bottom }
            .toolbarBackgroundVisibility(toolbarBackground, for: .windowToolbar)
            .environment(\.macPageStack, true)
    }
}

/// Watch's search field in the window's toolbar, for the page it's on (Watch's first page, or its search results).
private struct MacWatchSearch: ViewModifier {
    /// Watch is the section showing.
    var shown: Bool
    @Binding var text: String
    /// The field has the keyboard (Find, ⌘F, puts it there).
    @Binding var searching: Bool
    var focused: FocusState<Bool>.Binding

    func body(content: Content) -> some View {
        if shown {
            content
                .searchable(text: $text, isPresented: $searching, placement: .toolbar, prompt: Text("Movies and TV Shows"))
                .searchFocused(focused)
        } else {
            content
        }
    }
}

/// Mac: the window's own toolbar (Back while it goes somewhere, the page's name or on Home the greeting, Home | Watch
/// | Settings in the middle, the thermostat, Edit Home on Home, the remote, and Watch's search), the page under it,
/// and the remote as a sidebar on the right that slides out when it's wanted. Watch keeps one row of its own above
/// the page (`headerRow`): Movies | TV Shows and the TV it plays on.
struct MacRoot: View {
    @Environment(Fleet.self) private var fleet
    @Binding var selection: AppSection
    @SceneStorage("mac.tv") private var tvSelection: String?
    @State private var deviceSelection: String?
    /// (Asked for only when a speaker's or a light's page is the one showing: the store reads everything it keeps as
    /// it's first made.)
    private var home: SmartHome { SmartHome.shared }
    private let nav = MacNav.shared
    private let bar = MacBar.shared
    private let layout = HomeLayout.shared
    /// How wide the page area is: the greeting and the thermostat get shorter as it narrows so everything stays in
    /// one row.
    @State private var width: CGFloat = 1000
    private var narrow: Bool { width < 760 }
    /// Bumped by every pick in the toolbar, so the page it opens starts fresh (Home's open TV closes, and so on).
    @State private var visit = 0
    /// The sections whose pages have been shown, and so are kept (`keptPage`), and how often each has been started
    /// over.
    @State private var kept: Set<AppSection> = []
    @State private var fresh: [AppSection: Int] = [:]
    /// Where the toolbar last went, and when: the same place again straight away is the same click.
    @State private var lastGo = SidebarGo()
    /// The remote's sidebar has the keyboard (arrows, Return, Esc, H, M, + and − go to the TV).
    @FocusState private var remoteFocused: Bool
    /// The toolbar's search field has the cursor (Find, ⌘F, puts it there), and its search is in use.
    @FocusState private var searchFocused: Bool
    @State private var searching = false
    @AppStorage("macWelcomeShown") private var welcomeShown = false

    private var section: AppSection { selection == .remote ? .home : selection }

    /// What's typed in the toolbar's search field (Watch's): its results take the first page's place while there's any.
    private var query: String { bar.query }

    /// The camera filling everything right of the sidebar (one that's still in the camera list).
    private var fullCamera: NestCameras.Camera? {
        // One not in the list yet (the app just opened by its alert, before the list is read) still opens: the live
        // view then says what's missing, instead of the click doing nothing (as on iPhone).
        CameraStreams.shared.full.flatMap { id in
            NestCameras.shared.cameras.first { $0.id == id }
                ?? NestCameras.Camera(id: id, name: "Camera", room: nil, doorbell: false, webRTC: true)
        }
    }

    /// Home's own first page (no TV or speaker picked, no search, nothing opened on top): Edit Home belongs here.
    private var onHome: Bool {
        section == .home && tvSelection == nil && deviceSelection == nil && query.isEmpty && nav.path.isEmpty
    }

    /// Watch's library showing: Movies or TV Shows (picked in the row above Watch's first page).
    @AppStorage("watch.section") private var watchSection = "movies"

    /// Watch and anything opened from it (its lists, its search): Watch's blue background.
    private var inWatch: Bool { section == .watch && tvSelection == nil && deviceSelection == nil }

    /// Settings' own page: no row above it, so the page sits right under the toolbar.
    private var onSettings: Bool {
        section == .settings && tvSelection == nil && deviceSelection == nil && query.isEmpty && nav.path.isEmpty
    }

    /// The section lit in the toolbar (none on a TV's, a speaker's or a light's own page).
    private var shownSection: AppSection? {
        tvSelection == nil && (deviceSelection == nil || deviceSelection?.hasPrefix("set:") == true) ? section : nil
    }

    /// Watch's first page, or its search results over it: the toolbar has the search field (a list opened from Watch
    /// has a field of its own).
    private var showsSearch: Bool { inWatch && nav.path.isEmpty }

    var body: some View {
        @Bindable var fleet = fleet
        @Bindable var nav = nav
        @Bindable var bar = bar
        let camera = fullCamera
        // No sidebar: Home, Watch and Settings are in the middle of the window's toolbar.
        Group {
            NavigationStack(path: $nav.path) {
                ZStack {
                    // Home and Settings, kept as they were left while another page shows: hidden then, not gone
                    // (`keptPage`). Each was built again at every visit: Home's tiles and cameras, Settings' lists.
                    ForEach(Self.keptSections, id: \.self) { s in
                        if kept.contains(s) || showing(s) { keptPage(s) }
                    }
                    watchAndOthers
                }
                .environment(\.macPageTitle, query.isEmpty ? rootTitle : "Search")
                // The window's title is the page's name; under it on Watch, the library showing.
                .navigationTitle(query.isEmpty ? rootTitle : "Search")
                .navigationSubtitle(rootSubtitle)
                .modifier(rootChrome)
                .navigationDestination(for: PageRoute.self) { page in
                    page.view
                        // Back is the toolbar's own button (below), on every page alike.
                        .navigationBarBackButtonHidden(true)
                        .navigationTitle(page.title)
                        .modifier(openedChrome)
                }
            }
            .environment(\.macPageStack, true)
            // Not under Home's own first page: its backdrop covers the whole page (and draws what's playing itself).
            // Settings and Watch have Home's blues (the icon's background); Home draws its own.
            .background { if onSettings || inWatch { IconBackdrop() } else if !onHome { AmbientArtwork() } }
            // A clicked camera fills everything right of the sidebar (Esc or ✕ to close).
            .overlay {
                if let cam = camera {
                    CameraLiveView(camera: cam)
                        .id(cam.id)
                        .transition(.opacity)
                }
            }
            // The window's own toolbar, once for every page (not one per page: the same buttons stay put as pages
            // open and close). Each page says whether it's see-through over it (`MacPageChrome`).
            .toolbar { windowToolbar }
            // (Watch's search field is its first page's own, on that page: `MacWatchSearch`.)
            // Never narrower than Home's tiles: the window stops shrinking before anything is clipped.
            .frame(minWidth: 480)
            .onGeometryChange(for: CGFloat.self) { ($0.size.width / 20).rounded() * 20 } action: { width = $0 }
            // Each time Home's first page shows: the weather if it's been a while, and a fresh one-liner.
            .task(id: onHome) {
                guard onHome else { return }
                HomeWeather.shared.refresh()
                HomeGreeting.shared.refresh()
            }
        }
        // ⌘K, or View > Command Palette.
        .sheet(isPresented: $bar.palette) { CommandPalette().sheetBanner().macResizable(width: 620, height: 480) }
        // A search starts from the page you're on; going to another section (from here, a notification or a widget)
        // starts it at its first page.
        .onChange(of: query) { old, new in
            guard old.isEmpty && !new.isEmpty else { return }
            nav.reset()
            // Search is Watch's: its results show there, wherever it was started.
            if selection != .watch { selection = .watch }
        }
        // Leaving Watch leaves its search behind (the field is only there): no other page opens on old results.
        .onChange(of: selection) { _, new in nav.reset(); if new != .watch && !query.isEmpty { bar.query = "" } }
        // A section shown once is kept from then on.
        .onChange(of: section, initial: true) { _, s in if Self.keptSections.contains(s) { kept.insert(s) } }
        // The menu bar follows the window: View ticks the section showing, and Edit > Find is there to choose while
        // the search field is. Find (⌘F) puts the cursor in it.
        .onChange(of: shownSection, initial: true) { _, now in bar.section = now }
        .onChange(of: showsSearch, initial: true) { _, now in bar.searchShown = now }
        .onDisappear { bar.searchShown = false }
        .onChange(of: bar.finds) { _, _ in
            searching = true
            searchFocused = true
        }
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
                // Opened (the toolbar, ⌥⌘R, a TV's Remote button): the keyboard drives it straight away, without a
                // click into it first.
                .focused($remoteFocused)
                .onAppear { remoteFocused = true }
        }
    }

    /// The page the toolbar picked (or the search's results: the toolbar's Back, or Esc in the field, leaves them),
    /// under anything opened from it.
    @ViewBuilder private var root: some View {
        if !query.isEmpty { LibrarySearchResults(query: query) }
        // .id: a new item gets a fresh page (no name or level left over from the last one).
        else if let d = deviceSelection, d.hasPrefix("spk:") { SpeakerDetailView(speakerID: String(d.dropFirst(4))).id(d) }
        else if let d = deviceSelection, d.hasPrefix("light:") { LightDetailView(lightID: String(d.dropFirst(6))).id(d) }
        else if let d = deviceSelection, d.hasPrefix("set:"), let p = MacSettingsPage(rawValue: String(d.dropFirst(4))) {
            p.view.id(d).task { await HubSettings.shared.loadIfNeeded(fleet) }
        }
        else if let id = tvSelection { TVDetailView(tvID: id).id(id) }
        else if !Self.keptSections.contains(section) {
            // Watch. (Home and Settings are the pages kept behind this: `keptPage`.)
            section.view.id(section)
                // A new page fades and rises into place.
                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 10)), removal: .opacity))
        }
    }

    /// Watch, its search results and the pages that take the window's first page over (a TV's, a speaker's, a
    /// light's, one of Settings' own): built afresh at each pick, as ever. Watch's search is the toolbar's own field,
    /// there on Watch's first page and over its results. That page has it itself, so it's in the toolbar whenever it
    /// is the one showing and on no other page. (One field for the window: a second one crashes AppKit. And it isn't
    /// taken out of the toolbar on the other pages by `toolbar(removing:)`: taken out that way, it never came back.)
    /// It's round these pages only, not round Home and Settings kept behind them: the field is there or not by this
    /// being a different view, and they'd be built again every time Watch was picked or left.
    private var watchAndOthers: some View {
        root
            .id(visit)
            .modifier(MacWatchSearch(shown: inWatch, text: Bindable(bar).query, searching: $searching, focused: $searchFocused))
    }

    // MARK: Pages kept

    /// The sections kept as they were left while another page shows.
    private static let keptSections: [AppSection] = [.home, .settings]

    /// The window's first page is a section's own, not a search, a TV's, a speaker's or a light's page, or one of
    /// Settings' pages opened by itself (the same tests, in the same order, as `root`).
    private var sectionIsRoot: Bool {
        guard query.isEmpty else { return false }
        if let d = deviceSelection {
            if d.hasPrefix("spk:") || d.hasPrefix("light:") { return false }
            if d.hasPrefix("set:"), MacSettingsPage(rawValue: String(d.dropFirst(4))) != nil { return false }
        }
        return tvSelection == nil
    }

    /// [s]'s own first page is the one showing.
    private func showing(_ s: AppSection) -> Bool { section == s && sectionIsRoot }

    /// Home's or Settings' page. While another page shows it stays where it is, hidden: it can't be seen, clicked,
    /// reached by the keyboard or read out, and it's told so (`pageHidden`), so its cameras let go of their streams,
    /// what moves by itself rests, and it leaves the window's title and toolbar to the page showing. Picked again
    /// while it's already the page showing, it starts over (`fresh`).
    private func keptPage(_ s: AppSection) -> some View {
        let shown = showing(s)
        return s.view
            .id(fresh[s] ?? 0)
            .environment(\.pageHidden, !shown)
            .disabled(!shown)
            .opacity(shown ? 1 : 0)
            // It fades and rises into place, as a new page does.
            .offset(y: shown ? 0 : 10)
            .allowsHitTesting(shown)
            .accessibilityHidden(!shown)
    }

    /// Where the toolbar takes you, always: that section's (or TV's, speaker's, light's) first page, with the search
    /// cleared, anything opened on top closed, and a camera filling the window put away.
    private func go(to v: String) {
        // The same place again straight away is the same click: the page it opened isn't started over a second time.
        let now = Date()
        if lastGo.target == v && now.timeIntervalSince(lastGo.at) < 0.4 { return }
        lastGo.target = v
        lastGo.at = now
        if CameraStreams.shared.full != nil { withAnimation(.smooth(duration: 0.25)) { CameraStreams.shared.full = nil } }
        // A kept section picked again while its own first page is already the one showing: it starts over (Home's
        // open TV closes, Settings goes back to its first page), as every pick used to. Picked from anywhere else,
        // it's as it was left.
        if let s = AppSection(rawValue: v), Self.keptSections.contains(s), showing(s), nav.path.isEmpty {
            fresh[s, default: 0] += 1
        }
        nav.reset()
        if !query.isEmpty { bar.query = "" }
        layout.stopArranging()
        visit += 1
        if v.hasPrefix("tv:") { deviceSelection = nil; tvSelection = String(v.dropFirst(3)) }
        else if v.hasPrefix("spk:") || v.hasPrefix("light:") { tvSelection = nil; deviceSelection = v }
        else if v.hasPrefix("set:") { tvSelection = nil; deviceSelection = v; selection = .settings }
        else if let s = AppSection(rawValue: v) {
            tvSelection = nil; deviceSelection = nil
            withAnimation(.smooth(duration: 0.28)) { selection = s }
        }
    }

    // MARK: The toolbar

    /// The window's toolbar: at the left, Back while there's somewhere to go back to, and on Home's first page the
    /// weather and the greeting; Home | Watch | Settings in the middle; then the thermostat (on Home's and Watch's
    /// first pages), Edit Home (on Home) and the remote, level with one another. Watch's search field comes after
    /// them (`searchable`, in `body`).
    @ToolbarContentBuilder private var windowToolbar: some ToolbarContent {
        // Back is there only while it goes somewhere. (It sat at the top left of every first page, dimmed, doing
        // nothing when clicked.)
        if MacActions.canGoBack {
            ToolbarItem(placement: .navigation) {
                Button { MacActions.back() } label: { Label("Back", systemImage: "chevron.backward") }
                    .help(backHelp)
            }
        }
        // Home's first page: the weather and the greeting at the window's top left, in the toolbar itself. (They had
        // a row of their own under the toolbar, in its middle, with the thermostat at its far right: a strip of
        // mostly empty space above Home.)
        // (Only where there's room beside Home | Watch | Settings: the greeting from a middling window up, at its full
        // size from a fairly wide one, and the weather with it in a wide one.)
        if onHome && width >= 1040 {
            ToolbarItem(placement: .navigation) { MacToolbarGreeting(weather: width >= 1400, large: width >= 1160) }
                .sharedBackgroundVisibility(.hidden)
        }
        ToolbarItem(placement: .principal) {
            Picker("Section", selection: sectionChoice) {
                ForEach(AppSection.mac) { s in Text(s.title).tag(AppSection?.some(s)) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        // The thermostat, level with Edit Home and the remote, as tall as they are: on the pages that had it in the
        // row under the toolbar (Home's and Watch's first pages). It draws its own glass.
        if thermostatInToolbar {
            ToolbarItem(placement: .primaryAction) { ThermostatChip(compact: thermostatCompact, height: 36) }
                .sharedBackgroundVisibility(.hidden)
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }
        if onHome {
            ToolbarItem(placement: .primaryAction) { editHomeButton }
            // Apart from the remote's button: the two aren't a pair.
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }
        ToolbarItem(placement: .primaryAction) {
            Toggle(isOn: remoteOpen) { Label("Remote", systemImage: "appletvremote.gen4") }
                .toggleStyle(.button)
                .help("Remote (⌥⌘R)")
        }
    }

    /// Home's or Watch's first page, with nothing opened on top: the toolbar has the thermostat.
    private var thermostatInToolbar: Bool { (homeRow || watchRow) && nav.path.isEmpty }
    /// Without its − and + where the toolbar is short of room: a small window, or Watch's (which has the search
    /// field too) in a middling one.
    private var thermostatCompact: Bool { narrow || width < 1100 || (inWatch && width < 1500) }

    /// Where the toolbar's Back goes ("Back to Watch"), for its tooltip.
    private var backHelp: String {
        if let open = nav.path.last { return "Back to \(open.backTo) (⌘[)" }
        if MacActions.canGoBack && query.isEmpty { return "Back (⌘[)" }
        if !query.isEmpty { return "Back to \(rootTitle) (⌘[)" }
        return "Back"
    }

    /// The toolbar's Home | Watch | Settings: picking one goes to its first page.
    private var sectionChoice: Binding<AppSection?> {
        let shown = shownSection
        return Binding(get: { shown }, set: { if let s = $0 { go(to: s.rawValue) } })
    }

    /// The remote's panel, out or put away: the toolbar's button, on every page (⌥⌘R and the TVs menu too).
    private var remoteOpen: Binding<Bool> {
        let open = fleet.remotePanel
        return Binding(get: { open }, set: { now in withAnimation(.smooth) { fleet.remotePanel = now } })
    }

    /// Home's Edit Home, and Done while its tiles are being arranged.
    @ViewBuilder private var editHomeButton: some View {
        if layout.arranging {
            Button("Done") { layout.stopArranging() }
                .buttonStyle(.glassProminent)
        } else {
            Button("Edit Home") { layout.startArranging() }
        }
    }

    // MARK: The page's own row

    /// The first page is Home's own, or Watch's own, whatever is opened on top of it. Watch's keeps a row of its own
    /// above it (`headerRow`); not by what's on top (as `onHome` goes): the row stays as it is under an opened page,
    /// so the page doesn't move as one opens or closes over it. (Home has no row: its greeting and the thermostat are
    /// in the toolbar.)
    private var homeRow: Bool { section == .home && tvSelection == nil && deviceSelection == nil && query.isEmpty }
    private var watchRow: Bool { inWatch && query.isEmpty }

    /// What the window's first page has around it: its own row on top (Home's and Watch's; nothing on Settings or
    /// over search results, which start right under the toolbar), what's playing at the bottom, and the window's
    /// toolbar see-through (not over search results, which scroll straight under it).
    private var rootChrome: MacPageChrome<some View, some View> {
        MacPageChrome(header: rootHeader, headerSpacing: watchRow ? nil : 0,
                      toolbarBackground: query.isEmpty ? .hidden : .automatic, bottom: nowPlaying)
    }

    /// The same for a page opened on it, which starts right under the toolbar and scrolls under it (the toolbar is
    /// the system's own there). Each page needs its own: an opened page is drawn over anything put on the stack
    /// around it (what's playing vanished on opened pages), and a page opened from an opened page only goes on the
    /// window's stack when it says so (`macPageStack`).
    private var openedChrome: MacPageChrome<EmptyView, some View> {
        MacPageChrome(header: EmptyView(), headerSpacing: 0, toolbarBackground: .automatic, bottom: nowPlaying)
    }

    /// What's playing, at the bottom of a page (not on Home, a TV's or a device's page, or with the remote open).
    @ViewBuilder private var nowPlaying: some View {
        if tvSelection == nil && deviceSelection == nil && section != .home && !fleet.remotePanel {
            NowPlayingBar().frame(maxWidth: 600).padding(.bottom, 8)
        }
    }

    /// The name of the page the toolbar picked (the window's title, and where Back goes from a page opened on it).
    private var rootTitle: String {
        if let d = deviceSelection, d.hasPrefix("spk:") { return home.speaker(String(d.dropFirst(4)))?.name ?? "Speaker" }
        if let d = deviceSelection, d.hasPrefix("light:") { return home.light(String(d.dropFirst(6)))?.name ?? "Light" }
        if let d = deviceSelection, d.hasPrefix("set:"), let p = MacSettingsPage(rawValue: String(d.dropFirst(4))) { return p.title }
        if let id = tvSelection { return fleet.tv(id)?.name ?? "TV" }
        return section.title
    }

    /// Under the window's title: on Watch the library showing, and over its search results what's searched.
    private var rootSubtitle: String {
        guard inWatch else { return "" }
        if !query.isEmpty { return "Movies and TV Shows" }
        return watchSection == "shows" ? "TV Shows" : "Movies"
    }

    @ViewBuilder private var rootHeader: some View {
        if watchRow { headerRow }
    }

    /// Watch's Movies | TV Shows.
    private var libraryPicker: some View {
        Picker("Library", selection: $watchSection) {
            Text("Movies").tag("movies")
            Text("TV Shows").tag("shows")
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    /// The row above Watch's first page, under the toolbar: Movies | TV Shows and the TV it plays on. (The thermostat
    /// that was at its right is in the toolbar.)
    private var headerRow: some View {
        let watchBarHidden = MacWatchScroll.shared.barHidden
        // Wide enough: Movies | TV Shows sits in the very middle, under the toolbar's Home | Watch | Settings.
        let libraryCentred = width >= 1150
        return ZStack {
            HStack(spacing: 10) {
                Spacer(minLength: 8)
                if !libraryCentred {
                    libraryPicker
                    Spacer(minLength: 8)
                }
                TVPicker()
            }
            if libraryCentred { libraryPicker }
        }
        // Always the same height, so the page below never jumps as the row's contents change.
        .frame(height: 46)
        // Watch scrolled down: Movies | TV Shows and the rest of this row fade away (back when it scrolls up).
        .opacity(watchBarHidden ? 0 : 1)
        .allowsHitTesting(!watchBarHidden)
        .padding(.horizontal, 18)
        .padding(.top, 4)
        .padding(.bottom, 8)
        // Dragging the row's empty space moves the window, as the toolbar above it does.
        .background { Color.clear.contentShape(Rectangle()).gesture(WindowDragGesture()) }
    }
}

/// Space plays or pauses the remote's TV from anywhere in the app (every TV that's on when the remote is set to
/// All TVs), except while typing, in a sheet or alert, in the menu bar's panel, or while a film plays on this Mac in
/// a window of its own (there Space is the film's). One monitor for the whole app (a window each would press it
/// twice).
@MainActor
enum SpaceKey {
    private static var monitor: Any?
    /// A page's own use for Space, tried before the TV's play and pause (this monitor has every Space before any
    /// page does): Files' Quick Look for the file picked. True when it took the press.
    static var page: (() -> Bool)?
    /// When a letter was last typed into a list (a Mac's list jumps to the row whose name is typed): a Space just
    /// after it is part of that name ("Camera Alerts"), not the TV's.
    private static var typedInList = Date.distantPast

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            let plain = e.modifierFlags.intersection([.command, .option, .control]).isEmpty
            guard e.keyCode == 49 else {
                if plain, NSApp.keyWindow?.firstResponder is NSTableView,
                   e.charactersIgnoringModifiers?.rangeOfCharacter(from: .alphanumerics) != nil {
                    typedInList = Date()
                }
                return e
            }
            // Only in Woodruff's own window (the Mini Player's too): not in this Mac's Settings window, where Space
            // presses the control the keyboard is on.
            guard plain, !e.modifierFlags.contains(.shift),
                  let window = NSApp.keyWindow, window.sheetParent == nil, !(window is NSPanel),
                  window === MainWindow.current || window.identifier?.rawValue.hasPrefix("mini") == true,
                  !(window.firstResponder is NSText) else { return e }
            // A film playing here, and its window (or Apple's full screen for it) has the keyboard, not Woodruff's
            // own: Space goes on to the player, which pauses the film. (It paused the TV instead.)
            if MacPlayer.shared.isOpen, window !== MainWindow.current { return e }
            // In the middle of a name typed into a list: the list's.
            if window.firstResponder is NSTableView, Date().timeIntervalSince(typedInList) < 1 {
                typedInList = Date()
                return e
            }
            // The keyboard is on a button, a switch or a menu (Tab put it there): Space presses that, as it does in
            // every Mac app. (It went to the TV instead, so nothing could be pressed from the keyboard.)
            if let control = window.firstResponder as? NSControl, !(control is NSTableView) { return e }
            // The keyboard is on one of Home's tiles: Space presses the tile (`MacKeyTile`).
            if MacTileFocus.holder != nil { return e }
            // Held down: one press, not play-pause-play.
            if !e.isARepeat {
                if let take = page, take() { return nil }
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
            CameraStreams.shared.keepWarm(any)
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
/// The menu bar icon. It's there even with every window closed, so it opens Woodruff's window when a camera or
/// doorbell alert is clicked and no window is open to show the camera in.
struct MenuBarIcon: View {
    var fleet: Fleet
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: fleet.menuBarSymbol)
            // The Dock's click opens Woodruff's window with this (once it's been closed).
            .onAppear { MainWindowOpener.openWindow = openWindow }
            .onChange(of: CameraStreams.shared.requested) { _, id in
                guard id != nil else { return }
                // Still open (in the Dock, behind, or hidden with the app): the alert or link brings it forward itself.
                if MainWindow.current != nil { return }
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


#if os(macOS)
/// Mac: Settings' pages, listed under Settings in the sidebar and each opened beside it, like System Settings.
enum MacSettingsPage: String, CaseIterable, Identifiable {
    case tvs, smartHome, watch, notifications, accounts, general
    var id: String { rawValue }

    var title: String {
        switch self {
        case .tvs: return "TVs"
        case .smartHome: return "Smart Home"
        case .watch: return "Watch"
        case .notifications: return "Notifications"
        case .accounts: return "Accounts"
        case .general: return "General"
        }
    }

    @MainActor @ViewBuilder var view: some View {
        switch self {
        case .tvs: TVsView()
        case .smartHome: SmartHomeSettingsView(hub: HubSettings.shared)
        case .watch: WatchSettingsView()
        case .notifications: PhoneSettingsView(hub: HubSettings.shared)
        case .accounts: ConnectionsView(hub: HubSettings.shared)
        case .general: GeneralSettingsView(hub: HubSettings.shared)
        }
    }
}
#endif


#if os(macOS)
/// Mac Settings like System Settings: its pages in a sidebar down the left (the Mac's own list: the arrow keys move
/// through it, typing a name jumps to it, and the system lights the one picked), the page picked open on the right
/// to change. A link inside a page to one in the list picks it there; any other shows its page on the right, over
/// the one it was opened from: the toolbar's Back (⌘[) goes back a page, and the row it belongs to stays lit in the
/// list (a click there goes back to that page too).
struct MacSettingsView: View {
    @Environment(Fleet.self) private var fleet
    @AppStorage("mac.settingsPage") private var picked = "TVs"
    /// The pages links inside the right side showed (not ones in the list), each over the one it was opened from:
    /// until Back, or something in the list, is clicked.
    @State private var opened: [Opened] = []

    struct Item: Identifiable {
        let id: String
        /// Stays as it is under a page opened from it, instead of being made afresh on the way back (Send: the
        /// message being written, and who it goes to once To has been to and back).
        var keep = false
        let view: () -> AnyView
    }

    /// A group of the list, known by its first row, not by its place: Needs Attention coming or going above the rest
    /// doesn't make every row below it new. (An id of its own kind, which the list can't take for a row's.)
    private struct RowGroup: Identifiable {
        struct ID: Hashable { let first: String? }
        let items: [Item]
        var id: ID { ID(first: items.first?.id) }
    }

    /// A page a link inside the right side showed.
    struct Opened: Identifiable {
        let id = UUID()
        let title: String
        let view: AnyView
    }

    private static func item<V: View>(_ title: String, keep: Bool = false, @ViewBuilder _ v: @escaping () -> V) -> Item {
        Item(id: title, keep: keep) { AnyView(v()) }
    }

    /// Back a page: the one on top closes, and the one it was opened from shows again.
    private func back() {
        if !opened.isEmpty { opened.removeLast() }
    }

    /// A page closing itself (Delete Scene, Clear, a link opened): it goes, with any opened from it, and the one it
    /// was opened from shows again. Nothing when it's gone already (it asked a TV first, and Back was clicked
    /// meanwhile).
    private func close(_ id: UUID) {
        if let i = opened.firstIndex(where: { $0.id == id }) { opened.removeSubrange(i...) }
    }


    /// A row of the list picked: by a click, the arrow keys, or its name typed. Its page shows, and any page opened
    /// over the last one closes (the row already lit, clicked again, goes back to its own page this way).
    private func pick(_ id: String) {
        if !opened.isEmpty { opened = [] }
        if picked != id { picked = id }
        keepKeysInList()
    }

    /// The keyboard stays with the list while the arrow keys (or a typed name) move through it. A page that takes
    /// the keyboard as it opens (Send, for its message) would end them at its row: for a moment after a key picked a
    /// row, the list takes the keyboard back from a text field. (A click on the row leaves it with the page, and Tab
    /// still moves on into it.)
    private func keepKeysInList() {
        guard let event = NSApp.currentEvent, event.type == .keyDown, let window = NSApp.keyWindow,
              let list = window.firstResponder as? NSView, !(list is NSText) else { return }
        let clicks: [NSEvent.EventType] = [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown, .rightMouseUp]
        Task {
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 20_000_000)
                if let now = NSApp.currentEvent {
                    // A click or Tab meanwhile: the keyboard was sent somewhere on purpose.
                    if clicks.contains(now.type) { return }
                    if now.type == .keyDown, now.keyCode == 48 { return }
                }
                if window.firstResponder is NSText, list.window === window { _ = window.makeFirstResponder(list) }
            }
        }
    }

    /// The list, in groups with a little space between them.
    private var groups: [[Item]] {
        var g: [[Item]] = []
        if !NeedsAttentionSection.issues(fleet).isEmpty {
            g.append([Self.item("Needs Attention") { Form { NeedsAttentionSection(hub: HubSettings.shared) }.familyFormStyle() }])
        }
        g.append([
            Self.item("TVs") { TVsView() },
            Self.item("Notes") { NotesView() },
            // The TVs' updates, by that name: "Software Update" read as this Mac's own, which is Check for Updates…
            // in the Woodruff Family menu (and under General here).
            Self.item("TV Updates") { SoftwareUpdateView() },
            Self.item("Send", keep: true) { SendView() },
        ])
        g.append([
            Self.item("Speakers") { SpeakersListView() },
            Self.item("Lights") { LightsListView() },
            Self.item("Cameras") { CamerasPhoneView(hub: HubSettings.shared) },
            Self.item("Devices") { DevicesListView() },
            Self.item("Wi‑Fi") { WifiView() },
            Self.item("Scenes") { ScenesSettingsView() },
        ])
        g.append([
            Self.item("Watch") { WatchSettingsView() },
            Self.item("Notifications") { PhoneSettingsView(hub: HubSettings.shared) },
            Self.item("Camera Alerts") { CameraAlertsView(hub: HubSettings.shared) },
            Self.item("Accounts") { ConnectionsView(hub: HubSettings.shared) },
        ])
        g.append([
            Self.item("General") { GeneralSettingsView(hub: HubSettings.shared) },
            Self.item("Shortcuts") { ShortcutsView(hub: HubSettings.shared) },
            Self.item("Sync Across Devices") { SyncSettingsView() },
        ])
        return g
    }

    var body: some View {
        let groups = self.groups
        let all = groups.flatMap { $0 }
        let current = all.first { $0.id == picked } ?? all.first { $0.id == "TVs" }
        // A link inside a page: to a page in the list, that one is picked there; any other opens over the page it's on.
        let push: (String, AnyView) -> Void = { title, view in
            if all.contains(where: { $0.id == title }) { opened = []; picked = title } else {
                // A page that stays under it (Send) lets go of a field being typed in: nothing typed goes on into a
                // field that's out of sight. (Only a text field: the remote's panel keeps the keyboard.)
                if let w = MainWindow.current, w.firstResponder is NSText { _ = w.makeFirstResponder(nil) }
                opened.append(Opened(title: title, view: view))
            }
        }
        HStack(alignment: .top, spacing: 18) {
            // The list, as the Mac's own sidebar: one row is always picked (a click on the empty space under the
            // rows can't leave it without one), and it stays lit under a page opened from it: that's where you
            // are, and the way back.
            List(selection: Binding<String>(get: { current?.id ?? "TVs" }, set: { id in
                // Only another row counts as picked here (against the row lit now, not as it was when this was
                // drawn): the list may name the same one again as its rows change (Needs Attention coming or
                // going), which mustn't close a page opened from it.
                let lit = all.contains(where: { $0.id == picked }) ? picked : "TVs"
                if id != lit { pick(id) }
            })) {
                ForEach(groups.map(RowGroup.init)) { group in
                    Section {
                        ForEach(group.items) { it in
                            Text(it.id)
                                // (Its own colour only while it isn't the one picked: the system colours that one.)
                                .foregroundStyle(it.id == "Needs Attention" && it.id != current?.id ? AnyShapeStyle(Palette.attention) : AnyShapeStyle(.foreground))
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                                .tag(it.id)
                                // How many TVs have an update waiting, as the sidebar's own count (none: no count).
                                .badge(it.id == "TV Updates" ? fleet.updatesWaiting : 0)
                                // The list says nothing when the row already picked is clicked again: this does, so
                                // that click still goes back to its page from one opened over it.
                                .simultaneousGesture(TapGesture().onEnded { pick(it.id) })
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            // On the panel behind it, not the list's own background.
            .scrollContentBackground(.hidden)
            // As wide as System Settings' own list.
            .frame(width: 220)
            // Its rows stop at the panel's rounded corners as they scroll.
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .modifier(SettingsPanel())
            .padding(.leading, 18).padding(.vertical, 6)

            // The page: its name large at the top, then its settings, all on one plain panel matching the list's.
            VStack(alignment: .leading, spacing: 0) {
                // (A page opened from the one picked, or from one opened from it, goes back with the toolbar's Back,
                // ⌘[: `MacActions.back`. There's no second Back here.)
                Text(opened.last?.title ?? current?.id ?? "Settings")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .padding(.horizontal, 28).padding(.top, 22).padding(.bottom, 4)
                ZStack {
                    // The page picked in the list. Under a page opened from it, it's put away (and made afresh on
                    // the way back) unless it's one that's kept: that one stays as it was, out of sight.
                    if let current, opened.isEmpty || current.keep {
                        current.view().id(current.id).modifier(PaneLayer(onTop: opened.isEmpty))
                    }
                    // The pages opened from it, each over the one before: the one on top shows. Each can close itself.
                    ForEach(opened) { page in
                        page.view
                            .environment(\.macPanePush, MacPanePush(push: push, pop: { close(page.id) }))
                            .modifier(PaneLayer(onTop: page.id == opened.last?.id))
                    }
                }
                // One look for every page here: on the panel itself, roomier rows, slightly larger type, and the
                // family's light blue for switches, buttons and links.
                .scrollContentBackground(.hidden)
                .environment(\.defaultMinListRowHeight, 40)
                .font(.system(size: 14))
                .tint(IconPalette.cyan)
                .contentMargins(.horizontal, 12, for: .scrollContent)
                .transition(.opacity)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .modifier(SettingsPanel())
            .padding(.trailing, 18).padding(.vertical, 6)
            // (The page picked in the list has no page under it to go back to.)
            .environment(\.macPanePush, MacPanePush(push: push, pop: {}))
            .environment(\.macPageTitle, current?.id ?? "Settings")
            // The page picked fades in over the last one (the list lights its own row).
            .animation(.smooth(duration: 0.2), value: picked)
        }
        // The toolbar's Back and View > Back (⌘[) go back a page here while one is open over the page picked.
        .onChange(of: opened.count, initial: true) { _, n in MacBar.shared.settingsDepth = n }
        .onAppear { MacBar.shared.settingsBack = { back() } }
        .onDisappear {
            MacBar.shared.settingsDepth = 0
            MacBar.shared.settingsBack = nil
        }
        .task {
            // What the family's updater last said, read once for Needs Attention (an update that failed shows
            // there). Its own rows are in this Mac's Settings window, which keeps reading it while they show.
            UpdaterStatus.shared.reload()
            await HubSettings.shared.loadIfNeeded(fleet)
        }
    }
}

/// The panel behind Settings' list, and the one behind its page: a plain material in the panel's shape, not glass.
/// What's on them has glass of its own (Back, Update, Send's card), and glass laid over glass has only that glass to
/// sample, not what's behind it. Glass is for the controls; what holds them is plain.
private struct SettingsPanel: ViewModifier {
    func body(content: Content) -> some View {
        content.background { RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.regularMaterial) }
    }
}

/// One page of Settings' right-hand side. The one on top shows; one under it stays as it was (what was being
/// written, where it was scrolled to), out of sight and out of reach: its buttons and their keys do nothing.
private struct PaneLayer: ViewModifier {
    var onTop: Bool

    func body(content: Content) -> some View {
        content
            .opacity(onTop ? 1 : 0)
            .disabled(!onTop)
            .allowsHitTesting(onTop)
            .accessibilityHidden(!onTop)
    }
}
#endif
