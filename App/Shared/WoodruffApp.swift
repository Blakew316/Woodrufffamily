import SwiftUI
import WoodruffKit

@main
struct WoodruffApp: App {
    @State private var fleet = Fleet.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(fleet)
                .task {
                    #if os(macOS)
                    if !Demo.isOn { MacPairingBackup.attach(fleet) }
                    #endif
                    // Apple's own prompts on first launch: notifications, then location while using (for weather).
                    if !Demo.isOn { Notifier.attach(to: fleet) }
                    if !Demo.isOn && !fleet.hubs.isEmpty { LocationWeather.shared.start(fleet) }
                    SmartHome.shared.start()
                    await fleet.start()
                }
                .onOpenURL { url in
                    // woodruff://remote (widgets, Control Center): open the remote; anything else is a pairing link.
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
            fleet.setActive(phase == .active)
            if phase == .active { SmartHome.shared.wake() }
            if phase == .active && !Demo.isOn && !fleet.hubs.isEmpty { LocationWeather.shared.start(fleet) }
        }
        #if os(macOS)
        .defaultSize(width: 1180, height: 800)
        .windowToolbarStyle(.unified)
        .commands { WoodruffCommands(fleet: fleet) }
        #endif

        #if os(macOS)
        Window("Mini Player", id: "mini") {
            MiniPlayerView().environment(fleet)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .windowLevel(.floating)
        .defaultPosition(.topTrailing)

        MenuBarExtra {
            MenuBarFleetView().environment(fleet)
        } label: {
            Image(systemName: fleet.menuBarSymbol)
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
        .alert(item: Binding(get: { fleet.banner }, set: { fleet.banner = $0 })) { b in
            Alert(title: Text(b.title), message: Text(b.message), dismissButton: .default(Text("OK")))
        }
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
    @State private var palette = false
    @State private var query = ""
    @State private var keyMonitor: Any?
    @AppStorage("macWelcomeShown") private var welcomeShown = false

    private var section: AppSection { selection == .remote ? .home : selection }

    var body: some View {
        @Bindable var fleet = fleet
        NavigationSplitView {
            List(selection: Binding<String?>(
                get: { deviceSelection ?? tvSelection.map { "tv:\($0)" } ?? section.rawValue },
                set: { v in
                    guard let v else { return }
                    if v.hasPrefix("tv:") { deviceSelection = nil; tvSelection = String(v.dropFirst(3)) }
                    else if v.hasPrefix("spk:") || v.hasPrefix("light:") { tvSelection = nil; deviceSelection = v }
                    else if let s = AppSection(rawValue: v) { tvSelection = nil; deviceSelection = nil; selection = s }
                })) {
                Section {
                    ForEach(AppSection.mac) { s in Label(s.title, systemImage: s.symbol).tag(s.rawValue) }
                }
                Section("TVs") {
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
                    Section("Speakers") {
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
                    Section("Lights") {
                        ForEach(home.lights) { l in
                            HStack {
                                Text(l.name)
                                Spacer()
                                Circle().fill(l.on ? l.shade : Color.secondary.opacity(0.3)).frame(width: 7, height: 7)
                            }
                            .tag("light:\(l.id)")
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
        } detail: {
            NavigationStack {
                if !query.isEmpty { LibrarySearchResults(query: query) }
                else if let d = deviceSelection, d.hasPrefix("spk:") { SpeakerDetailView(speakerID: String(d.dropFirst(4))) }
                else if let d = deviceSelection, d.hasPrefix("light:") { LightDetailView(lightID: String(d.dropFirst(6))) }
                else if let id = tvSelection { TVDetailView(tvID: id) } else { section.view }
            }
            .background { AmbientArtwork() }
            .safeAreaInset(edge: .bottom) {
                if tvSelection == nil && deviceSelection == nil && section != .home && !fleet.remotePanel {
                    NowPlayingBar().frame(maxWidth: 600).padding(.bottom, 8)
                }
            }
        }
        .searchable(text: $query, placement: .toolbar, prompt: "Movies and TV Shows")
        .background(WindowMemory())
        .sheet(isPresented: $palette) { CommandPalette() }
        .background {
            Button("Command Palette") { palette = true }.keyboardShortcut("k", modifiers: .command).opacity(0).frame(width: 0, height: 0)
        }
        .onChange(of: fleet.tvs) { _, _ in NowPlayingBridge.shared.update(fleet); WidgetSync.update(fleet) }
        .onChange(of: fleet.selectedID) { _, _ in NowPlayingBridge.shared.update(fleet); WidgetSync.update(fleet) }
        .onAppear { SmartHome.shared.onChange = { WidgetSync.update(fleet) } }
        .sheet(isPresented: Binding(get: { !welcomeShown && !Demo.isOn }, set: { if !$0 { welcomeShown = true } })) { MacWelcome() }
        .userActivity("com.woodruff.family.remote", isActive: fleet.remotePanel) { a in
            a.title = "Woodruff Remote"
            a.isEligibleForHandoff = true
            if let id = fleet.selectedID { a.addUserInfoEntries(from: ["tv": id]) }
        }
        .onAppear { installSpaceKey() }
        .onDisappear { if let m = keyMonitor { NSEvent.removeMonitor(m) } }
        .inspector(isPresented: $fleet.remotePanel) {
            RemoteView(embedded: true)
                .inspectorColumnWidth(min: 300, ideal: 320, max: 380)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { withAnimation(.smooth) { fleet.remotePanel.toggle() } } label: {
                    Image(systemName: "appletvremote.gen4")
                }
                .help("Remote (⌥⌘R)")
                .keyboardShortcut("r", modifiers: [.command, .option])
            }
        }
    }

    /// Space plays or pauses the remote's TV from anywhere, except while typing in a text field.
    private func installSpaceKey() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            guard e.keyCode == 49, e.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
                  !(NSApp.keyWindow?.firstResponder is NSText) else { return e }
            Task { @MainActor in
                if let tv = Fleet.shared.selected { try? await Fleet.shared.client(for: tv)?.key("playpause") }
            }
            return nil
        }
    }
}
#endif

