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

    private var groups: [(String, [Row])] {
        var g: [(String, [Row])] = []
        if !NeedsAttentionSection.issues(fleet).isEmpty {
            g.append(("", [Self.row("Needs Attention") { Form { NeedsAttentionSection(hub: HubSettings.shared) } }]))
        }
        g.append(("", [
            Self.row("TVs") { TVsView() },
            Self.row("Notes") { NotesView() },
            Self.row("Software Update") { SoftwareUpdateView() },
            Self.row("Send") { SendView() },
        ]))
        g.append(("Home", [
            Self.row("Speakers") { SpeakersListView() },
            Self.row("Lights") { LightsListView() },
            Self.row("Cameras") { CamerasPhoneView(hub: HubSettings.shared) },
            Self.row("Devices") { DevicesListView() },
            Self.row("Wi‑Fi") { WifiView() },
            Self.row("Scenes") { ScenesSettingsView() },
        ]))
        g.append(("Watch & Notifications", [
            Self.row("Watch") { WatchSettingsView() },
            Self.row("Notifications") { PhoneSettingsView(hub: HubSettings.shared) },
            Self.row("Camera Alerts") { CameraAlertsView(hub: HubSettings.shared) },
            Self.row("Accounts") { ConnectionsView(hub: HubSettings.shared) },
        ]))
        g.append(("More", [
            Self.row("General") { GeneralSettingsView(hub: HubSettings.shared) },
            Self.row("Shortcuts") { ShortcutsView(hub: HubSettings.shared) },
            Self.row("Sync Across Devices") { SyncSettingsView() },
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
                                r.page()
                                    .navigationTitle(r.id)
                                    .toolbar(.visible, for: .navigationBar)
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
