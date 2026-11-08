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
        g.append(("Home", [
            Self.row("TVs") { TVsView() },
            Self.row("Speakers") { SpeakersListView() },
            Self.row("Lights") { LightsListView() },
            Self.row("Cameras") { CamerasPhoneView(hub: HubSettings.shared) },
            Self.row("Devices") { DevicesListView() },
            Self.row("Scenes") { ScenesSettingsView() },
        ]))
        g.append(("", [
            Self.row("Watch") { WatchSettingsView() },
            Self.row("Accounts") { ConnectionsView(hub: HubSettings.shared) },
            Self.row("Sync Across Devices") { SyncSettingsView() },
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
                ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                    let (title, rows) = group
                    Section {
                        ForEach(rows) { r in
                            NavigationLink {
                                TVSettingsPage(title: r.id) { r.page() }
                                    .onAppear { TVNav.shared.depth += 1 }
                                    .onDisappear { TVNav.shared.depth = max(0, TVNav.shared.depth - 1) }
                            } label: {
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
        .task { await HubSettings.shared.loadIfNeeded(fleet) }
    }
}

/// A page inside Settings, laid out as the first one (Apple TV's own Settings keeps it the same throughout): the
/// page's name large on the left over the backdrop, its settings on the right.
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
                .frame(maxWidth: .infinity)
        }
        .background { IconBackdrop().ignoresSafeArea() }
        .toolbar(.hidden, for: .navigationBar)
    }
}
