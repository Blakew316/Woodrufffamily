import SwiftUI
import WoodruffKit

// MARK: - Categories
//
// Settings is five rows, grouped the way iOS Settings groups things: TVs and Smart Home (the house), Notifications
// and Accounts (what reaches you, and what the TVs sign in to), and General (the rest). These are the pages those
// rows open; the pages they lead to are the ones Settings always had.

/// Reads the TVs' settings for the Settings pages, again when the remote moves to a TV with another hub (its keys and
/// links are that hub's), and every 20 seconds while Settings shows. A view of its own behind the page: the TVs report
/// every couple of seconds, and only this notices, so the rows of Settings don't redraw each time.
struct HubSettingsLoader: View {
    @Environment(Fleet.self) private var fleet
    var hub: HubSettings

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .task(id: fleet.hubClient()?.hub.id) {
                SiriVocabulary.start()
                await hub.load(fleet.hubClient())
            }
            .task { await hub.follow(fleet) }
    }
}

/// The red count of TVs with an update waiting, as iOS shows it on Software Update.
struct UpdateCountBadge: View {
    var count: Int

    var body: some View {
        Text("\(count)").font(.subheadline.weight(.semibold)).foregroundStyle(.white)
            .frame(minWidth: 22, minHeight: 22).background(Circle().fill(.red))
            .accessibilityLabel(spoken)
    }

    private var spoken: String { count == 1 ? "1 update waiting" : "\(count) updates waiting" }
}

/// TVs → Software Update's row: how many TVs have an update waiting, or Up to Date once the releases are known.
struct SoftwareUpdateRow: View {
    @Environment(Fleet.self) private var fleet

    var body: some View {
        let waiting = fleet.updatesWaiting
        HStack {
            IconRow(symbol: "", color: .clear, title: "Software Update", value: waiting > 0 || fleet.latest.isEmpty ? nil : "Up to Date")
            if waiting > 0 { UpdateCountBadge(count: waiting) }
        }
    }
}

/// Settings' Smart Home row: "Internet Down" when the Deco says so, otherwise what's in the house ("3 Speakers ·
/// 8 Lights"). It redraws whenever a speaker or light reports, so it reads only what the app keeps in memory (never
/// the Keychain).
struct SmartHomeSummaryRow: View {
    private let home = SmartHome.shared
    private let nest = NestCameras.shared
    private let deco = DecoWifi.shared
    private let devices = AccessoryStore.shared

    var body: some View {
        let down = deco.internetUp == false
        IconRow(symbol: "", color: .clear, title: "Smart Home", value: down ? "Internet Down" : summary, valueColor: down ? Palette.attention : .secondary)
    }

    /// The first two kinds of thing the house has, counted (just the Wi‑Fi's Decos when that's all there is).
    private var summary: String {
        let counts: [(Int, String)] = [
            (home.speakers.count, "Speaker"),
            (home.lights.count, "Light"),
            (nest.connected ? nest.cameras.count : 0, "Camera"),
            (devices.all.count, "Device"),
        ]
        let parts = counts.filter { $0.0 > 0 }.prefix(2).map { "\($0.0) \($0.1)\($0.0 == 1 ? "" : "s")" }
        if !parts.isEmpty { return parts.joined(separator: " · ") }
        let decos = deco.nodes.count
        return decos == 0 ? "Not Set Up" : decos == 1 ? "1 Deco" : "\(decos) Decos"
    }
}

/// Settings → Smart Home: speakers, lights, cameras, devices and the Wi‑Fi, each on its own page (where each one is
/// renamed, given its room, and signed in).
struct SmartHomeSettingsView: View {
    var hub: HubSettings

    var body: some View {
        Form {
            Section {
                PageLink("Speakers") { SpeakersListView() } label: {
                    IconRow(symbol: "", color: .clear, title: "Speakers", value: SmartHome.shared.speakers.isEmpty ? "None" : "\(SmartHome.shared.speakers.count)")
                }
                PageLink("Lights") { LightsListView() } label: {
                    IconRow(symbol: "", color: .clear, title: "Lights", value: SmartHome.shared.lights.isEmpty ? "None" : "\(SmartHome.shared.lights.count)")
                }
                PageLink("Cameras") { CamerasPhoneView(hub: hub) } label: {
                    IconRow(symbol: "", color: .clear, title: "Cameras", value: NestCameras.shared.connected ? "\(NestCameras.shared.cameras.count)" : "Not Connected")
                }
                PageLink("Devices") { DevicesListView() } label: {
                    IconRow(symbol: "", color: .clear, title: "Devices", value: AccessoryStore.shared.all.isEmpty ? "None" : "\(AccessoryStore.shared.all.count)")
                }
                PageLink("Wi‑Fi") { WifiView() } label: {
                    IconRow(symbol: "", color: .clear, title: "Wi‑Fi", value: wifiSummary, valueColor: DecoWifi.shared.internetUp == false ? Palette.attention : .secondary)
                }
            } footer: {
                Text("Rename things and choose their rooms on their pages; Govee, Samsung, Dreo, the cameras and the Deco sign in there too.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Smart Home")
        .inlineTitle()
    }

    /// The Deco: signed in or not (its password is in the Keychain, read only here, never on Settings itself).
    private var wifiSummary: String {
        let deco = DecoWifi.shared
        guard deco.connected else { return "Not Connected" }
        if deco.internetUp == false { return "Internet Down" }
        return deco.nodes.count == 1 ? "1 Deco" : "\(deco.nodes.count) Decos"
    }
}

/// Settings → General: Away From Home, Shortcuts, the Mac's click sound, keeping every device in step, and the TV's
/// last crash when there is one.
struct GeneralSettingsView: View {
    @Environment(Fleet.self) private var fleet
    var hub: HubSettings
    #if os(macOS)
    // Read and written through UserDefaults, so a change synced from another Mac shows here at once.
    @AppStorage("remoteClick") private var remoteClick = true
    #endif

    var body: some View {
        Form {
            Section {
                PageLink("Away From Home") { AwayView(hub: hub) } label: {
                    IconRow(symbol: "", color: .clear, title: "Away From Home", value: awaySummary)
                }
                PageLink("Shortcuts") { ShortcutsView(hub: hub) } label: {
                    IconRow(symbol: "", color: .clear, title: "Shortcuts")
                }
            }
            #if os(macOS)
            Section {
                Toggle("Click Sound on Remote Keys", isOn: $remoteClick)
            }
            #endif
            SyncSection()
            if let crash = hub.s?.crash, !crash.isEmpty {
                Section {
                    PageLink("Last Crash") { CrashView(hub: hub) } label: {
                        IconRow(symbol: "", color: .clear, title: "Last Crash on This TV")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("General")
        .inlineTitle()
        .refreshable { await hub.load(fleet.hubClient()) }
        // Opened before Settings had read them (or they couldn't be read then): read them now, and keep them current.
        .task { await hub.loadIfNeeded(fleet) }
        .task { await hub.follow(fleet) }
    }

    /// On or Off once the settings are read (nothing before then, rather than a guess).
    private var awaySummary: String? {
        guard let s = hub.s else { return nil }
        return (s.awayUrl ?? "").isEmpty ? "Off" : "On"
    }
}

/// Notifications → Recent Messages: what the TVs and the family sent this device in the last week.
struct RecentMessagesView: View {
    @Environment(Fleet.self) private var fleet

    var body: some View {
        Form {
            Section {
                if fleet.recentMessages.isEmpty { Text("No messages in the last week.").foregroundStyle(.secondary) }
                ForEach(fleet.recentMessages) { m in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(m.title).font(.subheadline.weight(.semibold))
                        // (A TV not yet updated names Settings pages as they used to be.)
                        if let b = m.body, !b.isEmpty { Text(currentSettingsPaths(b)).font(.subheadline) }
                        Text([m.from, m.at.map { Date(timeIntervalSince1970: $0 / 1000).formatted(date: .abbreviated, time: .shortened) }].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Recent Messages")
        .inlineTitle()
    }
}
