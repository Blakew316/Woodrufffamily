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
                }
                .badge(s == .settings ? fleet.attentionCount + fleet.updatesWaiting : 0)
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .tabViewBottomAccessory { NowPlayingAccessory() }
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
                    NowPlayingAccessory().frame(maxWidth: 560).padding(.bottom, 14)
                }
            }
        }
    }
}
#endif

/// What the remote's TV is playing, with ↺10, Play/Pause and 30↻ (the phone page's now-playing bar).
struct NowPlayingAccessory: View {
    @Environment(Fleet.self) private var fleet
    @State private var showScreen = false

    var body: some View {
        let tv = fleet.selected
        let p = tv?.playing
        HStack(spacing: 12) {
            Button { if tv != nil { showScreen = true } } label: {
                HStack(spacing: 10) {
                    NowPlayingArt(playing: p)
                        .frame(width: 36, height: 36)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(p?.title ?? "Nothing Playing").font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(tv?.name ?? "No TV").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if let tv, let p {
                if p.can("back10") { control("gobackward.10") { await media(tv, "back10") } }
                control(p.isPlaying ? "pause.fill" : "play.fill") { await media(tv, "playpause") }
                if p.can("fwd30") { control("goforward.30") { await media(tv, "fwd30") } }
            }
        }
        .padding(.horizontal, 14)
        #if os(macOS)
        .padding(.vertical, 8)
        .glass(Capsule())
        #endif
        .sheet(isPresented: $showScreen) { if let tv { TVScreenSheet(tvID: tv.id) } }
    }

    private func control(_ symbol: String, _ op: @escaping () async -> Void) -> some View {
        Button { Task { await op() } } label: {
            Image(systemName: symbol).font(.system(size: 17, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 34, height: 34).contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
    }

    private func media(_ tv: FleetTV, _ action: String) async {
        guard let c = fleet.client(for: tv) else { return }
        do {
            if action == "playpause" { try await c.key("playpause") } else { try await c.media(action) }
            try? await Task.sleep(nanoseconds: 700_000_000)
            await fleet.refresh()
        } catch { fleet.show(error) }
    }
}

/// The poster of what's playing when it's a Woodruff video, else the app's tile.
struct NowPlayingArt: View {
    @Environment(Fleet.self) private var fleet
    var playing: NowPlaying?
    var body: some View {
        if let key = playing?.key, key.hasPrefix("drive:"), let c = fleet.hubClient() {
            Artwork(url: c.art("/api/poster?id=\(key.dropFirst(6))&kind=poster&v=1"))
        } else {
            ZStack {
                LinearGradient(colors: [appColor, appColor.opacity(0.65)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: playing == nil ? "tv" : "play.fill").font(.caption.weight(.bold)).foregroundStyle(.white)
            }
        }
    }
    private var appColor: Color {
        switch playing?.app?.lowercased() ?? "" {
        case let a where a.contains("netflix"): return .red
        case let a where a.contains("youtube"): return Color(red: 0.9, green: 0.1, blue: 0.1)
        default: return .accentColor
        }
    }
}
