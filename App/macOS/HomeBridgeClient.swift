import AppKit
import SwiftUI
import WoodruffKit

/// Woodruff on the Mac reaching Apple Home through Woodruff Home Helper (see HomeBridge). It starts the helper
/// (hidden), takes what's in Apple Home every second (a 204 when nothing changed), puts it where the iPhone app's
/// Apple Home code puts it (so tiles, the thermostat pill and lights work unchanged), and sends changes back.
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
    @ObservationIgnored private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 3
        c.connectionProxyDictionary = [:]   // straight to this Mac, never through a proxy
        return URLSession(configuration: c)
    }()

    /// The installed helper, if there is one.
    var helperURL: URL? {
        if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: HomeBridge.helperBundleID) { return u }
        let fixed = URL(fileURLWithPath: "/Applications/\(HomeBridge.helperName).app")
        return FileManager.default.fileExists(atPath: fixed.path) ? fixed : nil
    }

    func start() {
        guard loop == nil, !Demo.isOn else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    /// Opens the helper's window (to allow Apple Home access when the Mac asks, or to see what it's doing).
    func openHelper() {
        guard let url = helperURL else { status = .notInstalled; return }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, _ in }
    }

    /// Starts the helper in the background (at most every 15 seconds).
    private func launchQuietly() {
        guard Date().timeIntervalSince(launchedAt) > 15 else { return }
        guard let url = helperURL else { status = .notInstalled; return }
        launchedAt = Date()
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = false
        cfg.hides = true
        cfg.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, _ in }
    }

    /// The helper's port and secret (also looked for in its container, in case macOS gave it one).
    private static func info() -> HomeBridge.Info? {
        if let i = HomeBridge.readInfo() { return i }
        let contained = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Containers/\(HomeBridge.helperBundleID)/Data/Library/Application Support/\(HomeBridge.helperName)/bridge.json")
        guard let d = try? Data(contentsOf: contained) else { return nil }
        return try? JSONDecoder().decode(HomeBridge.Info.self, from: d)
    }

    private func poll() async {
        guard let info = Self.info(), let url = info.url("/state?have=\(hash)") else {
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
            guard code == 200, let state = try? JSONDecoder().decode(HomeBridge.State.self, from: data) else { return }
            hash = state.hash
            apply(state)
        } catch {
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
        SmartHome.shared.homeControl = nil
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
        guard let info = Self.info(), let url = info.url(path), let data = try? JSONEncoder().encode(body) else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = data
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(info.token, forHTTPHeaderField: HomeBridge.tokenHeader)
        do {
            let (_, response) = try await session.data(for: req)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
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
