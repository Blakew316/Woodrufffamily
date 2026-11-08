import SwiftUI
import WoodruffKit

/// Woodruff Family on Apple TV: the iPhone app itself (its Home, Remote, Watch and Settings, App/Shared), laid out for
/// the TV and the Siri Remote. It starts the same things the iPhone app starts, minus what an Apple TV doesn't have
/// (Live Activities, widgets, Apple Home, live camera video).
@main
struct WoodruffTVApp: App {
    @State private var fleet = Fleet.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // The screenshot run (-tvTab home) opens a given tab.
        if let tab = UserDefaults.standard.string(forKey: "tvTab") { UserDefaults.standard.set(tab, forKey: "section") }
        let keys = SettingsSync.keychainKeys + Fleet.shared.tvs.map { "lg.\($0.id)" }
        Task.detached(priority: .userInitiated) { for k in keys { _ = Keychain.read(k) } }
    }

    var body: some Scene {
        WindowGroup {
            TVRoot()
                .environment(fleet)
                .preferredColorScheme(.dark)
                // How long from launch until the screen first showed (Settings → General → Speed), as on the Mac.
                .onAppear { Timings.note("Open", since: Timings.processStart) }
                .task {
                    // Announced on the Wi‑Fi from the start, so the iPhone app can find and connect it.
                    TVJoin.shared.start()
                    StallMonitor.start()
                    DriveLibrary.prewarm()
                    TMDB.prewarm()
                    SettingsSync.shared.prepare(fleet)
                    await fleet.start()
                    // How long until the TVs first answered (Settings → General → Speed).
                    Task {
                        for _ in 0..<600 where fleet.refreshedAt == nil { try? await Task.sleep(nanoseconds: 50_000_000) }
                        if fleet.refreshedAt != nil { Timings.note("TVs", since: Timings.processStart) }
                    }
                    // What Home shows besides the TVs comes a moment later, so the first screen isn't held up.
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    SmartHome.shared.start()
                    SmartThings.shared.start()
                    Dreo.shared.start()
                    Cync.shared.start()
                    NestCameras.shared.start()
                    // Behind-the-scenes work about a second in: Watch's first pictures, the weather, the sync.
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    WatchPrefetch.start(fleet)
                    if !Demo.isOn && !fleet.hubs.isEmpty { LocationWeather.shared.start(fleet) }
                    SettingsSync.shared.start(fleet)
                    NestAlerts.shared.start(fleet)
                    DecoWifi.shared.start()
                    Task.detached(priority: .background) { await ImageStore.shared.trim() }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { fleet.setActive(true) } else if phase == .background { fleet.setActive(false) }
            if phase == .background {
                AppWake.wentAway = true
                CameraStreams.shared.background()
                DriveLibrary.shared.flush()
                // Pictures not on screen are let go (they're on disk), as the iPhone does: a smaller app in the
                // background is less likely to be closed, so it opens at once next time.
                ImageStore.shared.memory.empty()
                BlurStore.empty()
            }
            if phase == .active {
                CameraStreams.shared.foreground()
                if AppWake.wentAway {
                    AppWake.wentAway = false
                    HomeWeather.shared.refresh()
                    HomeGreeting.shared.refresh()
                    SmartHome.shared.wake()
                    SettingsSync.shared.wake()
                    if !Demo.isOn && !fleet.hubs.isEmpty { LocationWeather.shared.start(fleet) }
                }
            }
        }
    }
}

/// The app's own root (the tabs, the family's alerts, the thermostat), with what only an Apple TV needs: a device
/// asking to connect it to the family, and the QR code until it's in the family.
struct TVRoot: View {
    @Environment(Fleet.self) private var fleet
    private let join = TVJoin.shared

    var body: some View {
        Group {
            if fleet.hubs.isEmpty && !Demo.isOn {
                ZStack {
                    HomeBackdrop()
                    ConnectPhoneCard().padding(80)
                }
            } else {
                TVMacRoot()
            }
        }
        .alert("Connect to the Family?", isPresented: Binding(get: { join.asking != nil }, set: { if !$0 { join.answer(false) } })) {
            Button("Allow") { join.answer(true) }
            Button("Don’t Allow", role: .cancel) { join.answer(false) }
        } message: {
            Text("\(join.asking ?? "A device") wants to give this Apple TV the family’s TVs, keys and settings.")
        }
    }
}
