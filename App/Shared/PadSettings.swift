import SwiftUI
import WoodruffKit

// MARK: - Settings on iPad
//
// An iPad wide enough for two columns shows Settings as the system's own Settings does: the list down the left, and
// the page picked there on the right, where everything opened from it stays. iPhone, and an iPad window too narrow
// for two columns (Slide Over, a small window), keep the one list that pushes its pages (`SettingsView`), unchanged.
// So does an iPad while its tabs are shown as a sidebar: one sidebar at a time.
//
// The pages need nothing new: a `PageLink` on iPhone and iPad is a plain navigation link, so on the right it pushes
// onto that column's own stack. (The Mac's Settings opens pages through `macPanePush` because its right-hand side
// isn't a navigation stack; here it is one, with the system's Back.)

#if os(iOS) || os(tvOS)
/// One tab's pages: a navigation stack of its own, except Settings on iPad, which lays itself out (`PadSettingsTab`).
struct PhoneTabStack: View {
    let section: AppSection

    var body: some View {
        #if os(iOS)
        // An iPad only: a large iPhone on its side is regular width too, and keeps its single list.
        if section == .settings && UIDevice.current.userInterfaceIdiom == .pad {
            PadSettingsTab()
        } else {
            NavigationStack { section.view }
        }
        #else
        NavigationStack { section.view }
        #endif
    }
}
#endif

#if os(iOS)
/// Settings on an iPad: two columns while there's room for them (regular width: full screen either way up, or a wide
/// window, with the tabs along the top), and the iPhone's single list otherwise.
private struct PadSettingsTab: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// Where the tabs are: along the top, or in a sidebar of their own once someone has turned them into one.
    @Environment(\.tabBarPlacement) private var tabs
    @Environment(\.scenePhase) private var phase
    /// In two columns, as last decided with the app in front. Away from the front it stays as it was: iPadOS lays
    /// the app out at other widths there (for the pictures the app switcher shows), and following those would swap
    /// the two layouts back and forth, closing whatever page was open.
    @State private var split: Bool?
    /// The page picked in the list. Kept here, so it's still the one picked after a while in the single list.
    @State private var picked = PadSettingsPage.tvs

    var body: some View {
        // Room for two columns: a regular width, and the tabs not in a sidebar of their own. (iPadOS lays the tabs'
        // sidebar over the list of a split view inside a tab; beside it, Settings keeps its single list.)
        let roomy = sizeClass == .regular && tabs != .sidebar
        let front = phase == .active
        Group {
            if front ? roomy : (split ?? roomy) {
                PadSettingsSplit(picked: $picked)
            } else {
                // The iPhone's Settings, as it is.
                NavigationStack { AppSection.settings.view }
            }
        }
        .onChange(of: roomy, initial: true) { _, now in if front { split = now } }
        .onChange(of: front) { _, now in if now { split = roomy } }
    }
}

/// The pages in the list on the left: the iPhone list's six, and Needs Attention above them while there's something
/// in it.
private enum PadSettingsPage: Hashable {
    case attention, tvs, smartHome, watch, notifications, accounts, general

    /// The page itself: the one its row opens on iPhone (`SettingsView`).
    @MainActor @ViewBuilder var view: some View {
        switch self {
        case .attention: PadAttentionPage()
        case .tvs: TVsView()
        case .smartHome: SmartHomeSettingsView(hub: HubSettings.shared)
        case .watch: WatchSettingsView()
        case .notifications: PhoneSettingsView(hub: HubSettings.shared)
        case .accounts: ConnectionsView(hub: HubSettings.shared)
        case .general: GeneralSettingsView(hub: HubSettings.shared)
        }
    }
}

/// Settings in two columns: the list on the left, its rows picked by the system, and the page picked there on the
/// right in a navigation stack of its own, so whatever a page opens is pushed there, beside the list.
private struct PadSettingsSplit: View {
    @Binding var picked: PadSettingsPage
    /// A TV's page open over TVs: the TV whose alert was tapped (or the den's, as the app was launched with).
    @State private var tv: String? = UserDefaults.standard.string(forKey: "route") == "tv" ? "tv-den" : nil
    /// Goes up as a TV's alert is tapped: its page opens over TVs afresh, whatever was open on the right.
    @State private var visit = 0
    /// The TV whose alert was just tapped (`NotificationHandler`): its page opens, and this is emptied.
    @AppStorage("settingsTV") private var alertTV = ""

    var body: some View {
        // What the list goes by: the system highlights this page's row, and a tap on another row shows that page.
        // (Always one of them: there is never nothing picked.)
        let selection = Binding<PadSettingsPage?>(get: { picked }, set: { page in
            guard let page, page != picked else { return }
            tv = nil
            picked = page
        })
        // Both columns, always: side by side in portrait too, as the system's Settings has them.
        NavigationSplitView(columnVisibility: .constant(.all)) {
            PadSettingsList(picked: selection)
        } detail: {
            NavigationStack {
                picked.view
                    // A tapped TV alert opens that TV's page, not just TVs (as on iPhone).
                    .navigationDestination(item: $tv) { TVDetailView(tvID: $0) }
            }
            // A page picked in the list starts at its first page: nothing opened from the last one is left on top.
            .id(picked)
            .id(visit)
        }
        .navigationSplitViewStyle(.balanced)
        .onAppear { if tv != nil { picked = .tvs } }
        .onChange(of: alertTV, initial: true) { _, id in
            guard !id.isEmpty else { return }
            alertTV = ""
            picked = .tvs
            tv = id
            visit += 1
        }
    }
}

/// The list on the left: Settings' rows as the iPhone's list has them (`SettingsView`), each with what it says beside
/// its name. Here a row is picked, not pushed: the system highlights it and its page shows on the right.
private struct PadSettingsList: View {
    @Environment(Fleet.self) private var fleet
    @Binding var picked: PadSettingsPage?
    /// The TVs' settings as last read (shown at once), read again while the list shows.
    private let hub = HubSettings.shared
    // Read through UserDefaults, so a switch turned on Notifications, or the library chosen on Watch, shows at once.
    @AppStorage("notifyFleet") private var notifyFleet = true
    @AppStorage("watch.source") private var watchSource = "tv"

    var body: some View {
        List(selection: $picked) {
            PadAttentionRow(showing: picked == .attention)
            Section {
                TVsSummaryRow().tag(PadSettingsPage.tvs)
                SmartHomeSummaryRow().tag(PadSettingsPage.smartHome)
                IconRow(symbol: "", color: .clear, title: "Watch", value: watchSource == "drive" && WatchSources.usesDrive ? "Google Drive" : "TV")
                    .tag(PadSettingsPage.watch)
            }
            Section {
                IconRow(symbol: "", color: .clear, title: "Notifications", value: notifyFleet ? "On" : "Off")
                    .tag(PadSettingsPage.notifications)
                IconRow(symbol: "", color: .clear, title: "Accounts", value: accounts)
                    .tag(PadSettingsPage.accounts)
            }
            Section {
                IconRow(symbol: "", color: .clear, title: "General", value: crashed ? "Crash Report" : nil, valueColor: Palette.attention)
                    .tag(PadSettingsPage.general)
            }
        }
        .listStyle(.sidebar)
        .screenTitle("Settings")
        // The list is always there (as in the system's Settings): no button that hides it.
        .toolbar(removing: .sidebarToggle)
        // Reads the TVs' settings from behind the list, as the iPhone's list does.
        .background { HubSettingsLoader(hub: hub) }
        .refreshable { await hub.load(fleet.hubClient()); await fleet.refresh() }
    }

    /// How many of the TVs' accounts are connected, counted as the iPhone's list counts them.
    private var accounts: String? {
        guard let s = hub.s else { return nil }
        let on = [s.google?.connected == true, s.tmdb == true, s.nest?.connected == true, !(s.mail ?? []).isEmpty].filter { $0 }.count
        return on == 0 ? "Not Set Up" : "\(on) Connected"
    }

    /// The TV that holds the settings has a crash report waiting.
    private var crashed: Bool { !(hub.s?.crash ?? "").isEmpty }
}

/// "Needs Attention" at the top of the list, with how many things: only while something isn't working on this
/// device, and for as long as its page is the one showing (so the page isn't taken away as the last one is put
/// right). A view of its own: what it reads changes as the TVs report, and only this row redraws then.
private struct PadAttentionRow: View {
    @Environment(Fleet.self) private var fleet
    var showing: Bool

    var body: some View {
        let count = NeedsAttentionSection.issues(fleet).count
        if count > 0 || showing {
            Section {
                Text("Needs Attention").foregroundStyle(Palette.attention)
                    .badge(count)
                    .tag(PadSettingsPage.attention)
            }
        }
    }
}

/// Needs Attention's page: everything not working on this device, each with where to fix it.
private struct PadAttentionPage: View {
    @Environment(Fleet.self) private var fleet

    var body: some View {
        Form {
            NeedsAttentionSection(hub: HubSettings.shared, titled: false)
            if NeedsAttentionSection.issues(fleet).isEmpty {
                Section { Text("Nothing needs attention.").foregroundStyle(.secondary) }
            }
        }
        .familyFormStyle()
        .navigationTitle("Needs Attention")
        .inlineTitle()
    }
}
#endif
