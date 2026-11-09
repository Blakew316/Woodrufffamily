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
        // Watch plays right here on the Apple TV (no TV to pick).
        UserDefaults.standard.set("here", forKey: "watch.playOn")
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
                    // Home's slideshow from the first moment, so a photo is there when Home opens.
                    HomeSlideshow.shared.start()
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
                    // The Top Shelf's album, its newest photos ready for the slideshow.
                    Task { await TopShelfAlbum.shared.refresh() }
                    // The weather from where this Apple TV is (asked once), whether or not its TVs are paired yet.
                    if !Demo.isOn { LocationWeather.shared.start(fleet) }
                    HomeWeather.shared.refresh()
                    SettingsSync.shared.start(fleet)
                    NestAlerts.shared.start(fleet)
                    // The cameras' alerts, from the Mac Studio, as the pill at the top right.
                    TVAlerts.shared.start()
                    DecoWifi.shared.start()
                    Task.detached(priority: .background) { await ImageStore.shared.trim() }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { fleet.setActive(true) } else if phase == .background { fleet.setActive(false) }
            if phase == .background {
                AppWake.wentAway = true
                TVAlerts.shared.pause()
                CameraStreams.shared.background()
                DriveLibrary.shared.flush()
                // Pictures not on screen are let go (they're on disk), as the iPhone does: a smaller app in the
                // background is less likely to be closed, so it opens at once next time.
                ImageStore.shared.memory.empty()
                BlurStore.empty()
            }
            if phase == .active {
                CameraStreams.shared.foreground()
                // Asking the Mac Studio for alerts again (only once the launch has started everything else).
                if AppWake.wentAway { TVAlerts.shared.start() }
                let woke = AppWake.wentAway
                if woke {
                    AppWake.wentAway = false
                    HomeWeather.shared.refresh()
                    HomeGreeting.shared.refresh()
                    // The Top Shelf's photos picked again from the album (new ones in it show up).
                    Task { await TopShelfAlbum.shared.refresh() }
                    SettingsSync.shared.wake()
                    if !Demo.isOn && !fleet.hubs.isEmpty { LocationWeather.shared.start(fleet) }
                }
                // The TVs were asked again by `setActive`; the lights, speakers, Samsung, the fans, Cync, the Wi‑Fi
                // and the cameras now too, so Home's tiles are right as soon as it shows.
                TVFreshness.foreground(woke: woke)
            }
        }
    }
}

/// Apple TV: everything besides the TVs asked again when the app comes to the front: back from the background, and
/// back from the screen saver or the Control Center, which only make it inactive (the iPhone app asks on its return
/// from the background only, and its loops carry on from there). Not more than every 30 seconds, and the cameras not
/// more than every 5 minutes (as often as their own loop), so flicking in and out doesn't ask the clouds over and over.
@MainActor
enum TVFreshness {
    /// Since launch: the launch itself asks everything once.
    private static var askedAt = Date()
    private static var camerasAt = Date()

    static func foreground(woke: Bool) {
        guard !Demo.isOn else { return }
        let now = Date()
        // Back from the background: the lamps' listener opened again and every lamp and speaker asked, as on iPhone.
        if woke { SmartHome.shared.wake() }
        guard now.timeIntervalSince(askedAt) >= 30 else { return }
        askedAt = now
        if !woke { SmartHome.shared.wake() }
        Task {
            async let samsung: Void = SmartThings.shared.refresh(full: false)
            async let fans: Void = Dreo.shared.refresh(full: false)
            async let cync: Void = Cync.shared.refresh()
            async let wifi: Void = DecoWifi.shared.refresh()
            _ = await (samsung, fans, cync, wifi)
        }
        if now.timeIntervalSince(camerasAt) >= 300 {
            camerasAt = now
            Task { await NestCameras.shared.load() }
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
        // A camera alert's pill, over every page (in its own window over a video or an open camera).
        .overlay { TVAlertLayer() }
        // The pill selected: its camera, opened with the event's picture.
        .cameraPresenter(Binding(
            get: {
                CameraStreams.shared.requested.map { id in
                    NestCameras.shared.cameras.first { $0.id == id }
                        ?? NestCameras.Camera(id: id, name: "Camera", room: nil, doorbell: false, webRTC: true)
                }
            },
            set: { if $0 == nil { CameraStreams.shared.requested = nil } }
        ))
        .alert("Connect to the Family?", isPresented: Binding(get: { join.asking != nil }, set: { if !$0 { join.answer(false) } })) {
            Button("Allow") { join.answer(true) }
            Button("Don’t Allow", role: .cancel) { join.answer(false) }
        } message: {
            Text("\(join.asking ?? "A device") wants to give this Apple TV the family’s TVs, keys and settings.")
        }
    }
}
