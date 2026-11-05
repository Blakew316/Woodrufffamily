import AppKit
import SwiftUI
import WoodruffKit

/// Woodruff on the Mac reaching Apple Home through Woodruff Home Helper (see HomeBridge). It starts the helper
/// (hidden), takes what's in Apple Home every second while Woodruff is in use (a 204 when nothing changed; every 5
/// seconds while its window is hidden), puts it where the iPhone app's Apple Home code puts it (so tiles, the
/// thermostat pill and lights work unchanged), and sends changes back.
@Observable @MainActor
final class HomeBridgeClient {
    static let shared = HomeBridgeClient()

    enum Status: Equatable {
        case starting
        case notInstalled
        case needsAccess(String)
        case connected(Int)
        case notAnswering
    }

    private(set) var status: Status = .starting

    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var hash = ""
    @ObservationIgnored private var misses = 0
    @ObservationIgnored private var launchedAt = Date.distantPast
    /// When macOS last refused to start the helper (it then shows its own message each time): tried again only
    /// after an hour, so that message isn't shown over and over.
    @ObservationIgnored private var refusedAt = Date.distantPast
    /// The helper's port and secret as last read from its file: kept until it stops answering (it may have started
    /// again with new ones), instead of read and decoded again every second.
    @ObservationIgnored private var bridgeInfo: HomeBridge.Info?
    /// Where the helper was found, and when it was looked for (asking the Mac takes a moment; it's asked after every
    /// unanswered look while the helper isn't running).
    @ObservationIgnored private var helperFound: (url: URL?, at: Date)?
    @ObservationIgnored private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 3
        c.connectionProxyDictionary = [:]   // straight to this Mac, never through a proxy
        return URLSession(configuration: c)
    }()

    /// The installed helper, if there is one (one found is looked for again at most once a minute; while there's none,
    /// it's looked for at every look, so one just installed is started at the next).
    var helperURL: URL? {
        if let found = helperFound, let url = found.url, Date().timeIntervalSince(found.at) < 60 { return url }
        return lookForHelper()
    }

    /// Asks the Mac where the helper is now.
    private func lookForHelper() -> URL? {
        var url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: HomeBridge.helperBundleID)
        if url == nil {
            let fixed = URL(fileURLWithPath: "/Applications/\(HomeBridge.helperName).app")
            if FileManager.default.fileExists(atPath: fixed.path) { url = fixed }
        }
        helperFound = (url, Date())
        return url
    }

    func start() {
        guard loop == nil, !Demo.isOn else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                let wait = self?.pollEvery ?? 1
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
        }
    }

    /// Seconds between looks: every second while Woodruff is in use, every 5 while it isn't (its window hidden), and
    /// every 30 while the helper isn't installed.
    private var pollEvery: TimeInterval {
        if status == .notInstalled { return 30 }
        return Fleet.shared.isActive ? 1 : 5
    }

    /// Opens the helper's window (to allow Apple Home access when the Mac asks, or to see what it's doing).
    func openHelper() {
        // Looked for afresh: it may have been installed a moment ago.
        guard let url = lookForHelper() else { status = .notInstalled; return }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, _ in }
    }

    /// Starts the helper in the background (at most every 15 seconds).
    private func launchQuietly() {
        guard Date().timeIntervalSince(launchedAt) > 15, Date().timeIntervalSince(refusedAt) > 3600 else { return }
        guard let url = helperURL else { status = .notInstalled; return }
        launchedAt = Date()
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = false
        cfg.hides = true
        cfg.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, error in
            guard error != nil else { return }
            Task { @MainActor in HomeBridgeClient.shared.refusedAt = Date() }
        }
    }

    /// The helper's port and secret (also looked for in its container, in case macOS gave it one).
    private static func info() -> HomeBridge.Info? {
        if let i = HomeBridge.readInfo() { return i }
        let contained = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Containers/\(HomeBridge.helperBundleID)/Data/Library/Application Support/\(HomeBridge.helperName)/bridge.json")
        guard let d = try? Data(contentsOf: contained) else { return nil }
        return try? JSONDecoder().decode(HomeBridge.Info.self, from: d)
    }

    /// The helper's details as kept (`bridgeInfo`), read from its file when there are none.
    private func currentInfo() -> HomeBridge.Info? {
        if let kept = bridgeInfo { return kept }
        bridgeInfo = Self.info()
        return bridgeInfo
    }

    private func poll() async {
        guard let info = currentInfo(), let url = info.url("/state?have=\(hash)") else {
            lost()
            launchQuietly()
            return
        }
        var req = URLRequest(url: url)
        req.setValue(info.token, forHTTPHeaderField: HomeBridge.tokenHeader)
        do {
            let (data, response) = try await session.data(for: req)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            misses = 0
            if code == 204 { return }
            // Turned away (a helper started again has a new secret): its file is read again next time.
            if code != 200 { bridgeInfo = nil }
            guard code == 200, let state = try? JSONDecoder().decode(HomeBridge.State.self, from: data) else { return }
            hash = state.hash
            apply(state)
        } catch {
            // Its file is read again next time (the helper may have started again elsewhere).
            bridgeInfo = nil
            // Left-over details from a helper that has quit: start it again.
            misses += 1
            if misses >= 3 {
                lost()
                launchQuietly()
            }
        }
    }

    private func apply(_ s: HomeBridge.State) {
        let store = AccessoryStore.shared
        if store.fromHome != s.devices { store.fromHome = s.devices }
        SmartHome.shared.setHomeLights(s.lights)
        if store.homeProblem != s.problem { store.homeProblem = s.problem }
        // From here a change to an Apple Home device or light goes to the helper.
        if store.homeControl == nil { store.homeControl = { [weak self] d, c in self?.send(device: d.id, c) } }
        if SmartHome.shared.homeControl == nil { SmartHome.shared.homeControl = { [weak self] l, c in self?.send(light: l.id, c) } }
        let next: Status
        if let p = s.problem, s.devices.isEmpty && s.lights.isEmpty { next = .needsAccess(p) } else { next = .connected(s.devices.count + s.lights.count) }
        if status != next { status = next }
    }

    /// The helper isn't answering: what was last seen stays listed, shown as not responding.
    private func lost() {
        let store = AccessoryStore.shared
        store.homeControl = nil
        // Only when set (this runs on every unanswered look, and each write tells everything that shows the lights).
        if SmartHome.shared.homeControl != nil { SmartHome.shared.homeControl = nil }
        let dimmed = store.fromHome.map { d -> HomeDevice in
            var d = d
            d.reachable = false
            return d
        }
        if dimmed != store.fromHome { store.fromHome = dimmed }
        hash = ""
        let next: Status = helperURL == nil ? .notInstalled : (status == .starting ? .starting : .notAnswering)
        if status != next { status = next }
    }

    // MARK: Changes

    func send(device id: String, _ command: DeviceCommand) {
        Task {
            let ok = await post("/device", HomeBridge.DeviceRequest(id: id, command: command))
            if !ok {
                Fleet.shared.say("Apple Home Didn’t Answer", "Woodruff Home Helper isn’t responding on this Mac. Settings → Smart Home → Devices can open it.")
            }
            await quickLook()
        }
    }

    func send(light id: String, _ command: LightCommand) {
        Task {
            let ok = await post("/light", HomeBridge.LightRequest(id: id, command: HomeBridge.Light(command)))
            if !ok { SmartHome.shared.homeControlFailed(id, "Woodruff Home Helper isn’t responding on this Mac.") }
            await quickLook()
        }
    }

    /// Looks again a moment after a change, so it shows straight away.
    private func quickLook() async {
        try? await Task.sleep(nanoseconds: 300_000_000)
        await poll()
    }

    private func post<T: Encodable>(_ path: String, _ body: T) async -> Bool {
        guard let info = currentInfo(), let url = info.url(path), let data = try? JSONEncoder().encode(body) else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = data
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(info.token, forHTTPHeaderField: HomeBridge.tokenHeader)
        do {
            let (_, response) = try await session.data(for: req)
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            if !ok { bridgeInfo = nil }   // read its file again next time
            return ok
        } catch {
            bridgeInfo = nil
            return false
        }
    }
}

/// How Apple Home reaches Woodruff on this Mac, and the button to fix it (Settings → Smart Home → Devices, the
/// thermostat panel).
struct HomeBridgeStatusView: View {
    private let bridge = HomeBridgeClient.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text)
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            switch bridge.status {
            case .needsAccess, .notAnswering:
                Button("Open \(HomeBridge.helperName)") { bridge.openHelper() }
            default:
                EmptyView()
            }
        }
    }

    private var text: String {
        switch bridge.status {
        case .starting:
            return "Connecting to Apple Home through \(HomeBridge.helperName)…"
        case .notInstalled:
            return "Apple Home reaches Woodruff on the Mac through \(HomeBridge.helperName), which isn’t installed on this Mac yet."
        case .needsAccess(let problem):
            return problem + " Open \(HomeBridge.helperName) and click Allow when the Mac asks."
        case .connected(let n):
            return "Apple Home is connected through \(HomeBridge.helperName) (\(n) accessories)."
        case .notAnswering:
            return "\(HomeBridge.helperName) isn’t answering. Starting it again…"
        }
    }
}
