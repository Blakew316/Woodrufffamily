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
                .task { if !Demo.isOn { Notifier.attach(to: fleet) }; await fleet.start() }
                .onOpenURL { url in fleet.handle(url: url) }
        }
        .onChange(of: scenePhase) { _, phase in fleet.setActive(phase == .active) }
        #if os(macOS)
        .defaultSize(width: 1180, height: 800)
        .windowToolbarStyle(.unified)
        .commands { WoodruffCommands(fleet: fleet) }
        #endif

        #if os(macOS)
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
    case remote, watch, send, memories, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .remote: return "Remote"
        case .watch: return "Watch"
        case .send: return "Send"
        case .memories: return "Memories"
        case .settings: return "Settings"
        }
    }
    var symbol: String {
        switch self {
        case .remote: return "appletvremote.gen4.fill"
        case .watch: return "play.tv.fill"
        case .send: return "paperplane.fill"
        case .memories: return "photo.stack.fill"
        case .settings: return "gearshape.fill"
        }
    }
    @ViewBuilder var view: some View {
        switch self {
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
        Binding(get: { AppSection(rawValue: stored) ?? .remote }, set: { stored = $0.rawValue })
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
        TabView(selection: selection) {
            ForEach(AppSection.allCases) { s in
                Tab(s.title, systemImage: s.symbol, value: s) {
                    NavigationStack { s.view }
                        // What's playing floats above the tabs everywhere but Remote, which shows it itself.
                        .safeAreaInset(edge: .bottom, spacing: 0) { if s != .remote { NowPlayingBar() } }
                        .animation(.smooth, value: fleet.selected?.playing?.title)
                }
                .badge(s == .settings ? fleet.attentionCount + fleet.updatesWaiting : 0)
            }
        }
    }
    #endif
}

#if os(macOS)
/// Mac: a glass sidebar with the same sections and every TV under them; what's playing floats at the bottom.
struct MacRoot: View {
    @Environment(Fleet.self) private var fleet
    @Binding var selection: AppSection
    @State private var tvSelection: String?

    var body: some View {
        NavigationSplitView {
            List(selection: Binding<String?>(
                get: { tvSelection.map { "tv:\($0)" } ?? selection.rawValue },
                set: { v in
                    guard let v else { return }
                    if v.hasPrefix("tv:") { tvSelection = String(v.dropFirst(3)) }
                    else if let s = AppSection(rawValue: v) { tvSelection = nil; selection = s }
                })) {
                Section {
                    ForEach(AppSection.allCases) { s in Label(s.title, systemImage: s.symbol).tag(s.rawValue) }
                }
                Section("TVs") {
                    ForEach(fleet.tvs) { tv in
                        Label {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(tv.name)
                                Text(tv.needsAttention ? (tv.health?.first ?? "Needs attention") : statusWord(tv))
                                    .font(.caption).foregroundStyle(tv.needsAttention ? Palette.attention : .secondary).lineLimit(1)
                            }
                        } icon: {
                            Image(systemName: "tv.fill").foregroundStyle(tv.online ? Color.accentColor : .secondary)
                        }
                        .tag("tv:\(tv.id)")
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 250)
        } detail: {
            NavigationStack {
                if let id = tvSelection { TVDetailView(tvID: id) } else { selection.view }
            }
            .safeAreaInset(edge: .bottom) {
                if tvSelection == nil && selection != .remote {
                    NowPlayingBar().frame(maxWidth: 600).padding(.bottom, 8)
                }
            }
        }
    }
}
#endif

