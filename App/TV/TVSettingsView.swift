import SwiftUI
import WoodruffKit

/// Settings as Apple TV's own Settings app lays it out: the app's emblem and name large on the left, the list on the
/// right (every page the Mac's Settings has, in its groups), each row opening its page with the remote.
struct TVSettingsView: View {
    @Environment(Fleet.self) private var fleet

    private struct Row: Identifiable {
        let id: String
        let page: () -> AnyView
    }

    private static func row<V: View>(_ title: String, @ViewBuilder _ v: @escaping () -> V) -> Row {
        Row(id: title) { AnyView(v()) }
    }

    /// Only what an Apple TV needs (no Shortcuts, Send, Notes or alerts, which are the iPhone's and Mac's).
    private var groups: [(String, [Row])] {
        var g: [(String, [Row])] = []
        if !NeedsAttentionSection.issues(fleet).isEmpty {
            g.append(("", [Self.row("Needs Attention") { Form { NeedsAttentionSection(hub: HubSettings.shared) } }]))
        }
        g.append(("", [
            // The TVs with their speakers.
            Self.row("TVs") { TVsView() },
            // Lights, cameras, devices, scenes and the accounts they sign in with, all in one place.
            Self.row("Smart Devices") { TVSmartDevices() },
            Self.row("Watch") { WatchSettingsView() },
            Self.row("Top Shelf") { TopShelfSettings() },
            // Sync Across Devices is inside General.
            Self.row("General") { GeneralSettingsView(hub: HubSettings.shared) },
        ]))
        return g
    }

    var body: some View {
        HStack(alignment: .top, spacing: 80) {
            // As the Settings app does: the app itself, large, on the left.
            VStack(spacing: 30) {
                Image("Emblem")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 360, height: 360)
                    .shadow(color: IconPalette.cyan.opacity(0.45), radius: 40)
                Text("Woodruff")
                    .font(.title2.bold())
                    .foregroundStyle(IconPalette.white)
            }
            .frame(width: 560)
            .frame(maxHeight: .infinity)

            List {
                // Each group known by its first row, not by its place: Needs Attention coming or going above the rest
                // (a sign-in failing for a moment) made every row below it new, which took the remote off its row.
                ForEach(groups, id: \.1.first?.id) { group in
                    let (title, rows) = group
                    Section {
                        ForEach(rows) { r in
                            NavigationLink(value: r.id) {
                                Text(r.id).foregroundStyle(r.id == "Needs Attention" ? Palette.attention : .primary)
                            }
                        }
                    } header: {
                        if !title.isEmpty { Text(title) }
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .navigationDestination(for: String.self) { id in
            if let r = groups.flatMap(\.1).first(where: { $0.id == id }) {
                TVSettingsPage(title: r.id) { r.page() }
            }
        }
        .task { await HubSettings.shared.loadIfNeeded(fleet) }
    }
}

/// A page inside Settings, laid out as the first one (Apple TV's own Settings keeps it the same throughout): the
/// page's name large on the left over the backdrop, its settings on the right. Every page opened from one of these
/// is laid out the same way, however deep (`PageLink` sees to it).
struct TVSettingsPage<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 80) {
            VStack(spacing: 24) {
                Image("Emblem")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 220, height: 220)
                    .shadow(color: IconPalette.cyan.opacity(0.45), radius: 30)
                Text(title)
                    .font(.system(size: 48, weight: .bold))
                    .foregroundStyle(IconPalette.white)
                    .multilineTextAlignment(.center)
            }
            .frame(width: 560)
            .frame(maxHeight: .infinity)
            content
                .listStyle(.plain)
                .frame(maxWidth: .infinity)
                .environment(\.tvSettingsPage, true)
        }
        .background { IconBackdrop().ignoresSafeArea() }
        .toolbar(.hidden, for: .navigationBar)
    }
}

private struct TVSettingsPageKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// On one of Settings' pages (`TVSettingsPage`): a page opened from here is laid out as this one is, and a page
    /// that fills the screen with a backdrop of its own elsewhere (a speaker, a device) sits on Settings' instead.
    var tvSettingsPage: Bool {
        get { self[TVSettingsPageKey.self] }
        set { self[TVSettingsPageKey.self] = newValue }
    }
}

/// Settings → Smart Devices: everything besides the TVs, and the accounts they sign in with.
private struct TVSmartDevices: View {
    var body: some View {
        List {
            Section {
                PageLink("Lights") { LightsListView() } label: { Text("Lights") }
                PageLink("Cameras") { CamerasPhoneView(hub: HubSettings.shared) } label: { Text("Cameras") }
                PageLink("Devices") { DevicesListView() } label: { Text("Devices") }
                PageLink("Scenes") { ScenesSettingsView() } label: { Text("Scenes") }
            }
            Section {
                PageLink("Accounts") { ConnectionsView(hub: HubSettings.shared) } label: { Text("Accounts") }
            }
        }
    }
}
