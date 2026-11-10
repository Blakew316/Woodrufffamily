import SwiftUI
import WoodruffKit

// MARK: - This Mac's own settings (⌘,)
//
// Settings in Woodruff's window are the family's: the TVs, the smart home, the accounts, what the TVs and the iPhones
// are told. What's about this Mac alone has the Mac's standard Settings window (Woodruff Family > Settings…, ⌘,), a
// tab for each kind: General (the remote's key click, which build this is, how quick it has been and how its updates
// are going) and Notifications (the alerts this Mac shows). Where those used to be in the window's Settings, a
// button opens this window on its tab (`MacSettingsWindowButton`).

/// The Settings window's tabs.
enum MacSettingsTab: String {
    case general, notifications
}

/// The Settings window: a tab for each kind of setting, opened on the one last shown.
struct MacSettingsWindow: View {
    @AppStorage("mac.settingsTab") private var tab = MacSettingsTab.general

    var body: some View {
        TabView(selection: $tab) {
            Tab("General", systemImage: "gearshape", value: MacSettingsTab.general) {
                MacGeneralSettings()
            }
            Tab("Notifications", systemImage: "bell.badge", value: MacSettingsTab.notifications) {
                MacNotificationSettings()
            }
        }
        // One width for every tab; as tall as it's dragged (a tab's rows scroll when there are more of them).
        .frame(width: 520)
        .frame(minHeight: 340, idealHeight: 460, maxHeight: 760)
    }
}

/// General: the remote's key click, which build this is, how quick it has been, and how the family's updater is
/// doing on this Mac (on the Mac Studio, each iPhone's too), with Check for Updates Now.
private struct MacGeneralSettings: View {
    // Read and written through UserDefaults, so a change synced from another Mac shows here at once.
    @AppStorage("remoteClick") private var remoteClick = true

    var body: some View {
        Form {
            Section {
                Toggle("Click Sound on Remote Keys", isOn: $remoteClick)
            }
            WoodruffFamilySection()
        }
        .formStyle(.grouped)
        // The family's updater: what it says is read as the tab opens, every 5 seconds while it shows, and every 2
        // seconds for a minute after Check Now.
        .task { await UpdaterStatus.shared.follow() }
    }
}

/// Notifications: the alerts this Mac shows, about the TVs and (once its cameras are connected) from the cameras,
/// with the vehicles it watches for. What pops up on the TVs, and the iPhones' instant alerts, are the family's:
/// they stay in the window's Settings.
private struct MacNotificationSettings: View {
    // Read and written through UserDefaults, so a switch synced from another device shows here at once.
    @AppStorage("notifyFleet") private var notifyFleet = true

    var body: some View {
        Form {
            Section {
                Toggle("TV Alerts", isOn: $notifyFleet)
            } footer: {
                Text("TV alerts tell you when a TV goes off or needs attention.")
            }
            if NestCameras.shared.connected {
                AlertsSection(title: "Camera Alerts", showsReconnect: false)
                VehicleAlertsSection()
            }
        }
        .formStyle(.grouped)
        .onChange(of: notifyFleet) { _, on in if on { Notifier.requestPermission() } }
    }
}

/// A button in the window's Settings that opens this Mac's Settings window on one of its tabs: for a page whose
/// switches for this Mac moved there.
struct MacSettingsWindowButton: View {
    private let title: String
    private let tab: MacSettingsTab
    @AppStorage("mac.settingsTab") private var shown = MacSettingsTab.general
    @Environment(\.openSettings) private var openSettings

    init(_ title: String, tab: MacSettingsTab) {
        self.title = title
        self.tab = tab
    }

    var body: some View {
        Button(title) {
            shown = tab
            openSettings()
        }
    }
}
