import SwiftUI
import WoodruffKit

// MARK: - Categories
//
// Settings is five rows, grouped the way iOS Settings groups things: TVs and Smart Home (the house), Notifications
// and Accounts (what reaches you, and every sign-in), and General (the rest). These are the pages those
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
    /// Whether the Deco is signed in: its password is in the Keychain, read as the page opens (and each time it's back
    /// on screen), not every time a speaker or light reports and the page redraws.
    @State private var decoSignedIn = false
    /// Home → All Devices: an Other section for devices that have no room.
    @AppStorage("allDevices.showOther") private var showOtherDevices = false

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
            Section {
                PageLink("Scenes") { ScenesSettingsView() } label: {
                    IconRow(symbol: "", color: .clear, title: "Scenes", value: SceneStore.shared.scenes.count == 1 ? "1 Scene" : "\(SceneStore.shared.scenes.count) Scenes")
                }
                Toggle("Show Devices Without a Room", isOn: $showOtherDevices)
            }
        }
        .familyFormStyle()
        .navigationTitle("Smart Home")
        .inlineTitle()
        .onAppear {
            let now = DecoWifi.shared.connected
            if now != decoSignedIn { decoSignedIn = now }
        }
    }

    /// The Deco: signed in or not (read on this page only, never on Settings itself).
    private var wifiSummary: String {
        let deco = DecoWifi.shared
        guard decoSignedIn else { return "Not Connected" }
        if deco.internetUp == false { return "Internet Down" }
        return deco.nodes.count == 1 ? "1 Deco" : "\(deco.nodes.count) Decos"
    }
}

/// Settings → General: Shortcuts, the Mac's click sound, keeping every device in step, the TV's last
/// crash when there is one, and which build of Woodruff Family this is (on a Mac, with how its updates are going).
/// On the Mac, Shortcuts and Sync Across Devices aren't repeated here: they're in Settings' list, beside this page.
struct GeneralSettingsView: View {
    @Environment(Fleet.self) private var fleet
    var hub: HubSettings
    #if os(macOS)
    // Read and written through UserDefaults, so a change synced from another Mac shows here at once.
    @AppStorage("remoteClick") private var remoteClick = true
    #else
    /// Home's "Away from home" line (on unless turned off here).
    @AppStorage("home.awayNote") private var awayNote = true
    #endif

    var body: some View {
        Form {
            // (Not on Apple TV. On the Mac, Shortcuts and Sync Across Devices are in Settings' list, beside this page.)
            #if os(iOS)
            Section {
                PageLink("Shortcuts") { ShortcutsView(hub: hub) } label: {
                    IconRow(symbol: "", color: .clear, title: "Shortcuts")
                }
            }
            #endif
            #if os(macOS)
            Section {
                Toggle("Click Sound on Remote Keys", isOn: $remoteClick)
            }
            #elseif os(iOS)
            Section {
                Toggle("Away From Home Note", isOn: $awayNote)
            } footer: {
                Text("The line on Home that says you’re away from home.")
            }
            #endif
            #if !os(macOS)
            SyncSection()
            #endif
            if let crash = hub.s?.crash, !crash.isEmpty {
                Section {
                    PageLink("Last Crash") { CrashView(hub: hub) } label: {
                        IconRow(symbol: "", color: .clear, title: "Last Crash on This TV")
                    }
                }
            }
            WoodruffFamilySection()
        }
        .familyFormStyle()
        .navigationTitle("General")
        .inlineTitle()
        .refreshable { await hub.load(fleet.hubClient()) }
        // Opened before Settings had read them (or they couldn't be read then): read them now, and keep them current.
        .task { await hub.loadIfNeeded(fleet) }
        .task { await hub.follow(fleet) }
        #if os(macOS)
        // The family's updater: what it says is read as the page opens, every 5 seconds while it shows, and every 2
        // seconds for a minute after Check Now.
        .task { await UpdaterStatus.shared.follow() }
        #endif
    }
}

/// Settings → General → Woodruff Family: which build this is and, on a Mac, how the family's updater is doing here (on
/// the Mac Studio, also each iPhone it installs on), with Check for Updates Now. A view of its own: what the updater
/// says is read every few seconds while General shows, and only these rows redraw when it changes.
struct WoodruffFamilySection: View {
    #if os(macOS)
    private let updater = UpdaterStatus.shared
    #endif

    var body: some View {
        #if os(macOS)
        Section {
            LabeledContent("Version", value: AppBuild.label)
            SpeedRows()
            updatesRow
            ForEach(updater.iPhones) { IPhoneUpdateRow(phone: $0) }
            if let tf = updater.testFlight {
                VStack(alignment: .leading, spacing: 3) {
                    IconRow(symbol: "", color: .clear, title: "TestFlight", value: tf.value, valueColor: tf.problem ? Palette.attention : .secondary)
                    if let d = tf.detail { Text(d).font(.footnote).foregroundStyle(.secondary).lineLimit(4) }
                }
            }
            Button("Check for Updates Now") { updater.checkNow() }
                .disabled(!updater.isSetUp || updater.running || updater.checking)
        } header: {
            Text("Woodruff Family")
        }
        #else
        Section {
            LabeledContent("Version", value: AppBuild.label)
            SpeedRows()
        } header: {
            Text("Woodruff Family")
        } footer: {
            Text("New versions come from TestFlight, on Wi‑Fi or cellular, or from the family’s Mac on home Wi‑Fi.")
        }
        #endif
    }

    #if os(macOS)
    /// "Updates: Up to date", with why it went wrong (when it did) and when the updater last looked.
    private var updatesRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            IconRow(symbol: "", color: .clear, title: "Updates", value: updater.summary, valueColor: updater.hasProblem ? Palette.attention : .secondary)
            if let detail = updater.detail {
                Text(detail).font(.footnote).foregroundStyle(.secondary).lineLimit(4)
            }
            if let checked = updater.lastChecked {
                // Redrawn now and then, so "3 min. ago" keeps up while the page stays open.
                TimelineView(.periodic(from: .now, by: 20)) { _ in
                    Text("Last checked \(relative(checked.timeIntervalSince1970 * 1000))").font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }
    #endif
}

#if os(macOS)
/// One iPhone the Mac Studio installs Woodruff Family on: up to date, waiting for it to be on the home Wi‑Fi,
/// installing, or why it couldn't.
struct IPhoneUpdateRow: View {
    var phone: UpdaterStatus.Phone

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            IconRow(symbol: "", color: .clear, title: phone.displayName, value: phone.summary, valueColor: phone.state == "failed" ? Palette.attention : .secondary)
            if let problem = phone.problem {
                Text(problem).font(.footnote).foregroundStyle(.secondary).lineLimit(4)
            }
        }
    }
}
#endif

/// Notifications → Recent Messages: what the TVs and the family sent this device in the last week.
struct RecentMessagesView: View {
    @Environment(Fleet.self) private var fleet

    var body: some View {
        Form {
            Section {
                if fleet.recentMessages.isEmpty { Text("No messages in the last week.").foregroundStyle(.secondary) }
                // By position, not by the message's id: two TVs can send messages with the same id ("seq-1"), and a
                // list with a repeated id crashes the Mac's form.
                ForEach(Array(fleet.recentMessages.enumerated()), id: \.offset) { _, m in
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
        .familyFormStyle()
        .navigationTitle("Recent Messages")
        .inlineTitle()
    }
}
