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
                .task { Notifier.attach(to: fleet); await fleet.start() }
                .onOpenURL { url in fleet.handle(url: url) }
        }
        .onChange(of: scenePhase) { _, phase in
            fleet.setActive(phase == .active)
        }
        #if os(macOS)
        .defaultSize(width: 1180, height: 780)
        .commands { WoodruffCommands(fleet: fleet) }
        #endif

        #if os(macOS)
        MenuBarExtra {
            MenuBarFleetView().environment(fleet)
        } label: {
            Label("Woodruff", systemImage: fleet.menuBarSymbol)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView().environment(fleet).frame(minWidth: 560, minHeight: 520)
        }
        #endif
    }
}

/// The app's sections: the same on iPhone (tabs), iPad and Mac (sidebar).
enum Section: String, CaseIterable, Identifiable, Hashable {
    case tvs, remote, send, memories, watch, updates, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .tvs: return "TVs"
        case .remote: return "Remote"
        case .send: return "Send"
        case .memories: return "Memories"
        case .watch: return "Watch"
        case .updates: return "Updates"
        case .settings: return "Settings"
        }
    }
    var symbol: String {
        switch self {
        case .tvs: return "tv.and.mediabox"
        case .remote: return "appletvremote.gen4"
        case .send: return "paperplane"
        case .memories: return "photo.on.rectangle.angled"
        case .watch: return "play.rectangle.on.rectangle"
        case .updates: return "arrow.down.circle"
        case .settings: return "gearshape"
        }
    }
}

struct RootView: View {
    @Environment(Fleet.self) private var fleet
    @AppStorage("section") private var stored: String = Section.tvs.rawValue
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        Group {
            if fleet.hubs.isEmpty {
                WelcomeView()
            } else {
                #if os(macOS)
                sidebar
                #else
                if sizeClass == .regular { sidebar } else { tabs }
                #endif
            }
        }
        .alert(item: Binding(get: { fleet.banner }, set: { fleet.banner = $0 })) { b in
            Alert(title: Text(b.title), message: Text(b.message), dismissButton: .default(Text("OK")))
        }
    }

    private var selection: Binding<Section> {
        Binding(get: { Section(rawValue: stored) ?? .tvs }, set: { stored = $0.rawValue })
    }

    @ViewBuilder private var tabs: some View {
        TabView(selection: selection) {
            ForEach(Section.allCases) { s in
                NavigationStack { s.view }
                    .tabItem { Label(s.title, systemImage: s.symbol) }
                    .tag(s)
            }
        }
    }

    @ViewBuilder private var sidebar: some View {
        NavigationSplitView {
            List(selection: Binding<Section?>(get: { selection.wrappedValue }, set: { if let s = $0 { selection.wrappedValue = s } })) {
                ForEach(Section.allCases) { s in
                    Label(s.title, systemImage: s.symbol)
                        .badge(s == .updates ? fleet.updatesWaiting : (s == .tvs ? fleet.attentionCount : 0))
                        .tag(s)
                }
                Spacer().frame(height: 8)
                FleetSidebarSummary()
            }
            .navigationTitle("Woodruff")
            #if os(macOS)
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
            #endif
        } detail: {
            NavigationStack { selection.wrappedValue.view }
        }
    }
}

extension Section {
    @ViewBuilder var view: some View {
        switch self {
        case .tvs: DashboardView()
        case .remote: RemoteView()
        case .send: SendView()
        case .memories: MemoriesView()
        case .watch: WatchView()
        case .updates: UpdatesView()
        case .settings: SettingsView()
        }
    }
}
