import Foundation
import SwiftUI
import os
import WoodruffKit

/// How long the things that should feel quick took on this device: opening the app, the TVs' first answer, Watch's
/// first page and a camera going live. Each is kept (the last 40, with the build they were on), written to a log
/// file, and shown in Settings → General, so every build's speed can be compared with the one before.
@MainActor
enum Timings {
    struct Entry: Codable, Equatable {
        var name: String
        var seconds: Double
        var build: String
        var at: Double
    }

    private static let log = Logger(subsystem: "com.woodruff.family", category: "timings")
    private static let key = "timings"
    private static var done: Set<String> = []

    /// When this process started (from the system), so opening counts from the tap, not from the app's own code.
    nonisolated static let processStart: Date = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else { return Date() }
        let t = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000)
    }()

    /// Every entry kept, oldest first.
    static var all: [Entry] { Saved.load(key, as: [Entry].self) ?? [] }

    /// [name] took from [start] to now. Only the first of each per launch (later ones are warm and say less).
    static func note(_ name: String, since start: Date) {
        guard !Demo.isOn, done.insert(name).inserted else { return }
        let s = Date().timeIntervalSince(start)
        guard s >= 0, s < 120 else { return }
        let e = Entry(name: name, seconds: s, build: AppBuild.label, at: Date().timeIntervalSince1970)
        var list = all
        list.append(e)
        if list.count > 40 { list.removeFirst(list.count - 40) }
        Saved.save(key, list)
        log.notice("\(name, privacy: .public): \(String(format: "%.2f", s), privacy: .public) s (\(e.build, privacy: .public))")
        let line = "\(ISO8601DateFormatter.plain.string(from: Date()))\t\(e.build)\t\(name)\t\(String(format: "%.3f", s))\n"
        let file = logFile
        DispatchQueue.global(qos: .utility).async {
            guard let file, let data = line.data(using: .utf8) else { return }
            if let h = try? FileHandle(forWritingTo: file) {
                defer { try? h.close() }
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: data)
            } else {
                try? data.write(to: file)
            }
        }
    }

    /// The Mac: next to the updater's logs. The iPhone: in the app's caches.
    private static var logFile: URL? {
        #if os(macOS)
        guard let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else { return nil }
        let dir = lib.appendingPathComponent("Logs/Woodruff Family", isDirectory: true)
        #else
        guard let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        #endif
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("timings.log")
    }

    /// The latest of [name], with the one before it from an earlier build (for "was").
    static func latest(_ name: String) -> (now: Entry, before: Entry?)? {
        let list = all.filter { $0.name == name }
        guard let last = list.last else { return nil }
        return (last, list.dropLast().last { $0.build != last.build })
    }
}

/// Notes how long it took from this appearing until [ready] (the first time per launch).
struct TimingProbe: View {
    let name: String
    let ready: Bool
    @State private var since: Date?

    var body: some View {
        Color.clear
            .onAppear {
                // Already there as it opened (kept from before): that's how long it took.
                if ready { Timings.note(name, since: Date()); return }
                if since == nil { since = Date() }
            }
            .onChange(of: ready) { _, now in
                if now, let since { Timings.note(name, since: since) }
            }
    }
}

/// Settings → General: how quick this device was on this build (and the build before, when it differed).
struct SpeedRows: View {
    private struct Line: Identifiable { let id: String; let title: String }
    private static let lines = [Line(id: "Open", title: "Opening"), Line(id: "TVs", title: "TVs Answering"),
                                Line(id: "Watch", title: "Watch"), Line(id: "Camera", title: "Camera Going Live")]
    var body: some View {
        let problems = Diagnostics.shared.recent()
        LabeledContent("Crashes and Freezes", value: problems.isEmpty ? "None This Week" : "\(problems.count) This Week")
        ForEach(Self.lines) { line in
            if let t = Timings.latest(line.id) {
                LabeledContent(line.title, value: text(t))
            }
        }
    }

    private func text(_ t: (now: Timings.Entry, before: Timings.Entry?)) -> String {
        let now = String(format: "%.1f s", t.now.seconds)
        guard let b = t.before else { return now }
        return now + String(format: " (was %.1f s)", b.seconds)
    }
}
