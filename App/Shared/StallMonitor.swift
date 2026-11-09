import Foundation
import WoodruffKit

/// Finds the moments the app stutters: twice a second, a quiet check from the background asks the main thread to
/// answer, and when it takes more than a quarter of a second the screen was frozen that long. Each one is written to a
/// log with the screen it happened on (the Mac: ~/Library/Logs/Woodruff Family/stalls.log), and one of half a second
/// or more also goes in the crash and freeze reports the Macs collect, so the worst spots can be found and fixed.
/// Settings → General → Speed shows this week's count.
enum StallMonitor {
    nonisolated(unsafe) private static var started = false
    private static let queue = DispatchQueue(label: "com.woodruff.family.stalls", qos: .utility)

    @MainActor static func start() {
        guard !started, !Demo.isOn else { return }
        started = true
        tick()
    }

    private static func tick(after delay: Double = 0.5) {
        queue.asyncAfter(deadline: .now() + delay) {
            let asked = Date()
            DispatchQueue.main.async {
                let late = Date().timeIntervalSince(asked)
                // Only while the app is in use (a suspended app isn't stuttering), and not absurd gaps (the Mac asleep).
                let inUse: Bool = MainActor.assumeIsolated {
                    let on = Fleet.shared.isActive
                    if late > 0.25, late < 20, on { note(late) }
                    return on
                }
                // Not in use (the Mac's window hidden): looked at now and then, not twice a second for nothing.
                tick(after: inUse ? 0.5 : 5)
            }
        }
    }

    @MainActor private static var lastReport = Date.distantPast

    @MainActor private static func note(_ seconds: Double) {
        let screen = screenName
        // This week's count, for Settings.
        let d = UserDefaults.standard
        let week = Calendar.current.component(.weekOfYear, from: Date())
        if d.integer(forKey: "stalls.week") != week { d.set(week, forKey: "stalls.week"); d.set(0, forKey: "stalls.count"); d.set(0.0, forKey: "stalls.worst"); d.set("", forKey: "stalls.worstOn") }
        d.set(d.integer(forKey: "stalls.count") + 1, forKey: "stalls.count")
        if seconds > d.double(forKey: "stalls.worst") { d.set(seconds, forKey: "stalls.worst"); d.set(screen, forKey: "stalls.worstOn") }
        let line = "\(ISO8601DateFormatter.plain.string(from: Date()))\t\(AppBuild.label)\t\(screen)\t\(String(format: "%.2f", seconds))\n"
        queue.async {
            guard let file = logFile, let data = line.data(using: .utf8) else { return }
            if let h = try? FileHandle(forWritingTo: file) {
                defer { try? h.close() }
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: data)
            } else {
                try? data.write(to: file)
            }
        }
        // The bad ones go with the reports (no more than one every five minutes).
        if seconds >= 0.5, Date().timeIntervalSince(lastReport) > 300 {
            lastReport = Date()
            Diagnostics.shared.noteStall(seconds: seconds, screen: screen)
        }
    }

    /// The page on screen: Home, Watch or Settings (and, on the Mac, Settings' page; on Apple TV, a film or camera
    /// open over it).
    @MainActor static var screenName: String {
        let d = UserDefaults.standard
        #if os(tvOS)
        // Apple TV's sidebar keeps its page under its own name: read from "section" (the iPhone's), every stall said
        // Home, whatever was on screen.
        let page = (d.string(forKey: "tv.tab") ?? "home").capitalized
        if NativePlayer.shared.isOpen { return "\(page): Film" }
        if CameraStreams.shared.expanded != nil { return "\(page): Camera" }
        return page
        #else
        let s = (d.string(forKey: "section") ?? "home").capitalized
        #if os(macOS)
        if s == "Settings", let page = d.string(forKey: "mac.settingsPage") { return "Settings: \(page)" }
        #endif
        return s
        #endif
    }

    private static var logFile: URL? {
        #if os(macOS)
        guard let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else { return nil }
        let dir = lib.appendingPathComponent("Logs/Woodruff Family", isDirectory: true)
        #else
        guard let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        #endif
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("stalls.log")
    }

    /// "None This Week", or "3 This Week (worst 0.8 s on Watch)".
    @MainActor static var summary: String {
        let d = UserDefaults.standard
        guard d.integer(forKey: "stalls.week") == Calendar.current.component(.weekOfYear, from: Date()) else { return "None This Week" }
        let n = d.integer(forKey: "stalls.count")
        guard n > 0 else { return "None This Week" }
        return String(format: "%d This Week (worst %.1f s on %@)", n, d.double(forKey: "stalls.worst"), d.string(forKey: "stalls.worstOn") ?? "")
    }
}
