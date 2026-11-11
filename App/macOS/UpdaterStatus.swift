import AppKit
import Foundation
import Observation
import WoodruffKit

// MARK: - The family's updater on this Mac
//
// scripts/updater.py, which launchd runs every 5 minutes (com.woodruff.family.updater), keeps this Mac (and, on the Mac
// Studio, the iPhones and the Apple TVs) on the newest release and writes how that's going in status.json. Woodruff only reads that
// file, asks launchd to run the updater now (Check for Updates), and quits itself when deploy.sh is about to replace
// it. It never changes what the updater does.

/// What the updater last said, for Settings → General → Woodruff Family, and Check for Updates.
@Observable @MainActor
final class UpdaterStatus {
    static let shared = UpdaterStatus()

    /// The updater's LaunchAgent (`scripts/updater.py install` makes it).
    static let label = "com.woodruff.family.updater"

    /// What status.json said when it was last read; nil before the updater has written one.
    private(set) var snapshot: Snapshot?
    /// The updater is set up on this Mac: its LaunchAgent is there.
    private(set) var isSetUp = false
    /// The updater is in a run right now (an update, or just a look for one).
    private(set) var running = false
    /// Check Now was pressed in the last minute and the updater hasn't looked since.
    private(set) var checking = false
    /// Check Now couldn't start the updater: launchctl's own words, until it's pressed again.
    private(set) var startProblem: String?

    /// When Check Now was last pressed: status.json is read every 2 seconds for a minute after it.
    @ObservationIgnored private var requestedAt: Date?
    /// When status.json is read next while Settings → General follows it.
    @ObservationIgnored private var nextRead = Date.distantPast
    /// Check for Updates… in the menu, waiting to say what the updater found.
    @ObservationIgnored private var reporting: Task<Void, Never>?

    private init() {}

    // MARK: Reading

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    static var plistURL: URL { home.appendingPathComponent("Library/LaunchAgents/\(label).plist") }
    static var statusURL: URL { home.appendingPathComponent("Library/Application Support/Woodruff Family/Updater/status.json") }
    /// Touched by Check for Updates Now: the updater then installs at once instead of waiting until the app isn't in use.
    static var requestURL: URL { home.appendingPathComponent("Library/Application Support/Woodruff Family/Updater/check-now") }

    /// Reads status.json, and whether the LaunchAgent is there, again. A missing file means there's nothing to show;
    /// one that can't be read or decoded (it's being written at that moment) keeps what was read last. Only what
    /// changed is set, so the rows don't redraw at every read.
    func reload() {
        let files = FileManager.default
        let setUp = files.fileExists(atPath: Self.plistURL.path)
        if setUp != isSetUp { isSetUp = setUp }
        let now = Date()
        let fast = requestedAt.map { now.timeIntervalSince($0) < 60 } ?? false
        nextRead = now.addingTimeInterval(fast ? 2 : 5)
        if let data = try? Data(contentsOf: Self.statusURL) {
            if let read = try? JSONDecoder().decode(Snapshot.self, from: data), read != snapshot { snapshot = read }
        } else if snapshot != nil && !files.fileExists(atPath: Self.statusURL.path) {
            snapshot = nil
        }
        // A run that ended without saying so (the Mac lost power in the middle) stops counting once what it wrote is
        // three hours old.
        let inRun = snapshot.map { s in s.running && (s.updatedAt.map { now.timeIntervalSince($0) < 3 * 3600 } ?? true) } ?? false
        if inRun != running { running = inRun }
        let waiting = fast && !hasLooked(since: requestedAt)
        if waiting != checking { checking = waiting }
    }

    /// The updater has looked for a new version since [asked] (status.json keeps whole seconds).
    private func hasLooked(since asked: Date?) -> Bool {
        guard let asked, let looked = snapshot?.lastCheck else { return false }
        return looked >= asked.addingTimeInterval(-1)
    }

    /// Keeps Settings → General current while it shows (its task, cancelled when the page goes): status.json is read
    /// at once, then every 5 seconds, and every 2 seconds for a minute after Check Now.
    func follow() async {
        reload()
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if !Task.isCancelled && Date() >= nextRead { reload() }
        }
    }

    // MARK: Check Now

    /// Asks launchd to run the updater now, as if its 5 minutes were up. Never with -k: an update that's already
    /// running is left to finish (asking again then does nothing). [reportTo] is Check for Updates… in the menu: like a
    /// Mac app's own, it then says what the updater found, once it has looked (nothing if that takes over a minute;
    /// Settings → General still shows it).
    func checkNow(reportTo fleet: Fleet? = nil) {
        reload()
        guard isSetUp else {
            if let fleet { tell(fleet, "Updates Aren’t Set Up", "The family’s updater isn’t set up on this Mac yet, so it can’t look for a new version.") }
            return
        }
        let asked = Date()
        let wasRunning = running
        requestedAt = asked
        startProblem = nil
        if !checking { checking = true }
        // Someone asked: the updater installs now, even though the app is in use (it's the one asking).
        try? Data().write(to: Self.requestURL)
        let target = "gui/\(getuid())/\(Self.label)"
        Task.detached(priority: .userInitiated) { [weak self] in
            let problem = UpdaterStatus.kickstart(target)
            await self?.started(problem)
        }
        guard let fleet else { return }
        reporting?.cancel()
        reporting = Task { [weak self] in
            while Date().timeIntervalSince(asked) < 60 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, !Task.isCancelled else { return }
                self.reload()
                if let problem = self.startProblem {
                    self.tell(fleet, "Couldn’t Check for Updates", problem)
                    return
                }
                // A run already going when it was asked (launchd doesn't start another) answers when it ends.
                if self.hasLooked(since: asked) || (wasRunning && !self.running) {
                    if let r = self.report { self.tell(fleet, r.title, r.message) }
                    return
                }
            }
        }
    }

    /// Check for Updates… answers in Woodruff's own window, where its alerts show. With that window closed it says
    /// nothing, rather than leaving an old answer for whenever the window next opens.
    private func tell(_ fleet: Fleet, _ title: String, _ message: String) {
        guard let w = MainWindow.current, w.isVisible || w.isMiniaturized else { return }
        fleet.alert(title, message)
    }

    /// launchctl's answer to Check Now: read status.json at once (the updater may already say it's running).
    private func started(_ problem: String?) {
        if let problem {
            startProblem = "Couldn’t start the updater: \(problem)"
            requestedAt = nil
        }
        reload()
    }

    /// Runs `/bin/launchctl kickstart <target>` (no shell). Nil when launchd took it, otherwise what launchctl said.
    private nonisolated static func kickstart(_ target: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["kickstart", target]
        let said = Pipe()
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = said
        p.standardError = said
        do { try p.run() } catch { return error.localizedDescription }
        let out = said.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        if p.terminationStatus == 0 { return nil }
        let text = String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let first = text.split(separator: "\n").first.map(String.init) ?? ""
        return first.isEmpty ? "launchctl stopped with status \(p.terminationStatus)." : first
    }

    // MARK: What the rows say

    /// The Updates row: how this Mac's Woodruff Family is doing.
    var summary: String {
        guard isSetUp else { return "Not set up on this Mac" }
        let state = snapshot?.mac?.state
        if checking && state != "updating" { return "Checking…" }
        switch state {
        case "current"?: return "Up to date"
        case "updating"?: return "Installing update…"
        case "waiting"?: return snapshot?.role == "hub" ? "Waiting to install" : "Waiting for the Mac Studio’s build"
        case "postponed"?: return postponedForBattery ? "Postponed while on battery" : "Postponed while you’re using it"
        case "failed"?: return "Couldn’t update"
        case let other?: return spoken(other)
        case nil: return running ? "Checking…" : "Not checked yet"
        }
    }

    /// The Updates row says something went wrong.
    var hasProblem: Bool { startProblem != nil || (isSetUp && snapshot?.mac?.state == "failed") }

    /// A line under it when there's something to explain: why the update failed, why Check Now couldn't start the
    /// updater, or (on the Mac Studio) why the other Macs didn't get its build.
    var detail: String? {
        if let startProblem { return startProblem }
        guard isSetUp, let s = snapshot else { return nil }
        if s.mac?.state == "failed" { return nonEmpty(s.mac?.detail) ?? nonEmpty(s.lastError) }
        // The last check itself failed (no internet, GitHub unreachable): "Up to date" can't be trusted, so say why.
        if let error = nonEmpty(s.lastError) { return "Couldn’t check for a new version: \(error)" }
        if s.role == "hub", s.share?.state == "failed" {
            return "Couldn’t share this build with the other Macs" + (nonEmpty(s.share?.detail).map { ": \($0)" } ?? ".")
        }
        return nil
    }

    /// When the updater last looked for a new version.
    var lastChecked: Date? { isSetUp ? snapshot?.lastCheck : nil }

    /// The TestFlight row (the Mac Studio only): how the upload of the release went, and why when it didn't.
    var testFlight: (value: String, detail: String?, problem: Bool)? {
        guard isSetUp, let s = snapshot, s.role == "hub", let tf = s.testflight, let state = tf.state else { return nil }
        switch state {
        case "ok": return ("Uploaded", nil, false)
        case "uploading": return ("Uploading…", nil, false)
        case "skipped": return ("Not Set Up", nonEmpty(tf.detail), false)
        case "failed": return ("Couldn’t Upload", nonEmpty(tf.detail), true)
        default: return (spoken(state), nonEmpty(tf.detail), false)
        }
    }

    /// The iPhones the Mac Studio installs on (only it has them).
    var iPhones: [Phone] { isSetUp && snapshot?.role == "hub" ? snapshot?.iphones ?? [] : [] }

    /// The Apple TVs the Mac Studio installs on, over the home network (never while a film is playing there).
    var appleTVs: [Phone] { isSetUp && snapshot?.role == "hub" ? snapshot?.appletvs ?? [] : [] }

    /// The update waits for power, not for you (builds wait while the battery is low).
    private var postponedForBattery: Bool {
        snapshot?.mac?.detail?.range(of: "battery", options: .caseInsensitive) != nil
    }

    /// What Check for Updates… says once the updater has looked.
    private var report: (title: String, message: String)? {
        guard let s = snapshot else { return nil }
        switch s.mac?.state {
        case "current"?:
            return ("Woodruff Family Is Up to Date", "This Mac has the newest version (\(AppBuild.label)).")
        case "updating"?:
            return ("Installing the New Version", "Woodruff Family quits in a moment and opens again by itself.")
        case "waiting"?:
            return s.role == "hub" ? nil : ("Waiting for the Mac Studio’s Build", "This Mac installs the new version as soon as the Mac Studio has built it.")
        case "postponed"?:
            return ("Update Postponed", postponedForBattery
                ? "This Mac builds the new version once it’s plugged in."
                : "It installs once Woodruff Family hasn’t been used for a couple of minutes, and within half an hour at most.")
        case "failed"?:
            return ("Couldn’t Update", nonEmpty(s.mac?.detail) ?? nonEmpty(s.lastError) ?? "The updater couldn’t install the new version.")
        default:
            return nil
        }
    }

    // MARK: Quit for an update

    /// deploy.sh posts this Darwin notification just before it replaces the app, and Woodruff quits itself: the updater
    /// runs in the background, where it can't count on permission to tell Woodruff to quit. Call once at launch
    /// (again does nothing).
    nonisolated static func listenForQuit() { _ = quitForUpdateObserver }
}

/// Registered the first time listenForQuit() reads it (a global is set up only once). The callback is a C function, so
/// it captures nothing: it quits Woodruff on the main queue.
private let quitForUpdateObserver: Void = CFNotificationCenterAddObserver(
    CFNotificationCenterGetDarwinNotifyCenter(),
    nil,
    { _, _, _, _, _ in DispatchQueue.main.async { MainActor.assumeIsolated { NSApp.terminate(nil) } } },
    "com.woodruff.family.mac.quit-for-update" as CFString,
    nil,
    .deliverImmediately)

// MARK: - status.json

extension UpdaterStatus {
    /// status.json, format 1. Read leniently: a field that's missing or of another type is skipped (an iPhone that
    /// can't be read is left out, not the list), and a state this version doesn't know shows as it's written, so an
    /// older or newer updater never blanks the page.
    struct Snapshot: Decodable, Equatable {
        var role: String?
        var running = false
        var updatedAt: Date?
        var release: Release?
        var mac: Mac?
        var iphones: [Phone] = []
        /// The Apple TVs, as the iPhones (an updater from before it kept them current says nothing of them).
        var appletvs: [Phone] = []
        var share: Share?
        /// The release uploaded to TestFlight (the Mac Studio only).
        var testflight: Share?
        var lastCheck: Date?
        var lastError: String?

        private enum CodingKeys: String, CodingKey {
            case role, running, release, mac, iphones, appletvs, share, testflight
            case updatedAt = "updated_at", lastCheck = "last_check", lastError = "last_error"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            role = c.text(.role)
            running = c.flag(.running) ?? false
            updatedAt = c.time(.updatedAt)
            release = c.lenient(.release)
            mac = c.lenient(.mac)
            share = c.lenient(.share)
            testflight = c.lenient(.testflight)
            lastCheck = c.time(.lastCheck)
            lastError = c.text(.lastError)
            // Each keeps a distinct id for its row: its UDID, or its place in the list.
            func rows(_ key: CodingKeys, _ kind: String) -> [Phone] {
                var seen = Set<String>()
                let devices = (c.lenient(key) as [Lossy<Phone>]?)?.compactMap(\.value) ?? []
                return devices.enumerated().map { i, device in
                    var device = device
                    let udid = device.udid ?? ""
                    device.id = udid.isEmpty || seen.contains(udid) ? "\(kind) #\(i)" : udid
                    seen.insert(device.id)
                    device.kind = kind
                    return device
                }
            }
            iphones = rows(.iphones, "iPhone")
            appletvs = rows(.appletvs, "Apple TV")
        }
    }

    /// The newest release the updater knows of.
    struct Release: Decodable, Equatable {
        var commit: String?
        var build: Int?
        var subject: String?
        var seenAt: Date?

        private enum CodingKeys: String, CodingKey {
            case commit, build, subject
            case seenAt = "seen_at"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            commit = c.text(.commit)
            build = c.number(.build)
            subject = c.text(.subject)
            seenAt = c.time(.seenAt)
        }
    }

    /// This Mac's Woodruff Family.
    struct Mac: Decodable, Equatable {
        var commit: String?
        var build: Int?
        var updatedAt: Date?
        var state: String?
        var detail: String?

        private enum CodingKeys: String, CodingKey {
            case commit, build, state, detail
            case updatedAt = "updated_at"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            commit = c.text(.commit)
            build = c.number(.build)
            updatedAt = c.time(.updatedAt)
            state = c.text(.state)
            detail = c.text(.detail)
        }
    }

    /// One iPhone, or one Apple TV, the Mac Studio keeps current.
    struct Phone: Decodable, Equatable, Identifiable {
        var id = ""
        /// What it is, for a row whose device gave no name: "iPhone" or "Apple TV".
        var kind = "iPhone"
        var udid: String?
        var name: String?
        var commit: String?
        var updatedAt: Date?
        var state: String?
        var detail: String?
        var nextTry: Date?

        private enum CodingKeys: String, CodingKey {
            case udid, name, commit, state, detail
            case updatedAt = "updated_at", nextTry = "next_try"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            udid = c.text(.udid)
            name = c.text(.name)
            commit = c.text(.commit)
            updatedAt = c.time(.updatedAt)
            state = c.text(.state)
            detail = c.text(.detail)
            nextTry = c.time(.nextTry)
        }

        /// Its name as the iPhone (or Apple TV) gives it.
        var displayName: String { nonEmpty(name) ?? kind }

        /// Its row's value.
        var summary: String? {
            switch state {
            case "current"?: return "Up to date"
            case "unreachable"?: return kind == "Apple TV" ? "Waiting to reach it" : "Waiting for it to be on Wi‑Fi"
            case "waiting"?: return "After the film"   // an Apple TV with a film playing
            case "pending"?: return (detail ?? "").hasPrefix("Installing") ? "Installing…" : "Waiting to install"
            case "failed"?: return "Couldn’t install"
            case let other?: return spoken(other)
            case nil: return nil
            }
        }

        /// Why it couldn't be installed, when it couldn't.
        var problem: String? { state == "failed" ? nonEmpty(detail) : nil }
    }

    /// The build the Mac Studio shared with the other Macs (iCloud Drive).
    struct Share: Decodable, Equatable {
        var commit: String?
        var state: String?
        var detail: String?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            commit = c.text(.commit)
            state = c.text(.state)
            detail = c.text(.detail)
        }

        private enum CodingKeys: String, CodingKey { case commit, state, detail }
    }
}

/// An item of a list that's nil when it can't be read, instead of failing the whole list.
private struct Lossy<T: Decodable>: Decodable {
    var value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

private extension KeyedDecodingContainer {
    /// The value at [key] when it's there and of the right type; otherwise nil, never an error.
    func lenient<T: Decodable>(_ key: Key) -> T? { try? decodeIfPresent(T.self, forKey: key) }
    func text(_ key: Key) -> String? { lenient(key) }
    func flag(_ key: Key) -> Bool? { lenient(key) }
    /// A whole number, also when it was written as 412.0 or "412".
    func number(_ key: Key) -> Int? {
        if let n: Int = lenient(key) { return n }
        if let d: Double = lenient(key), d.isFinite, abs(d) < 1e15 { return Int(d) }
        if let s: String = lenient(key) { return Int(s.trimmingCharacters(in: .whitespaces)) }
        return nil
    }
    func time(_ key: Key) -> Date? { text(key).flatMap(updaterDate) }
}

/// "2026-11-04T19:05:00Z", with or without fractions of a second.
private func updaterDate(_ text: String) -> Date? {
    (try? wholeSeconds.parse(text)) ?? (try? fractionalSeconds.parse(text))
}

private let wholeSeconds = Date.ISO8601FormatStyle()
private let fractionalSeconds = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

/// [text] unless it's empty (or only spaces).
private func nonEmpty(_ text: String?) -> String? {
    guard let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
    return t
}

/// A state this version doesn't know ("verifying"), as a row's value ("Verifying").
private func spoken(_ state: String) -> String {
    let words = state.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
    return words.prefix(1).uppercased() + words.dropFirst()
}
