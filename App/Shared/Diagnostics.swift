import Foundation
import MetricKit
import WoodruffKit

/// Crashes, freezes and slow launches as Apple reports them (MetricKit, about once a day): each kept in full on this
/// device, summed up in a few lines that travel with the family's settings, and written on every Mac to
/// ~/Library/Logs/Woodruff Family/diagnostics.log (every device's), so a problem on any device can be looked into
/// without anyone sending a report.
@MainActor
final class Diagnostics: NSObject {
    static let shared = Diagnostics()

    /// The synced settings item: device id → that device's latest summaries (newest first, a few).
    static let key = "diagnostics"
    private static let keptPerDevice = 6

    struct Report: Codable, Equatable {
        var at: Double
        var kind: String        // "Crash", "Freeze", "Slow Launch", "CPU", "Disk Writes"
        var build: String
        var detail: String
    }

    private var started = false

    func start() {
        guard !started, !Demo.isOn else { return }
        started = true
        MXMetricManager.shared.add(self)
        // What was delivered while the app wasn't running.
        take(MXMetricManager.shared.pastDiagnosticPayloads)
        #if os(macOS)
        writeFamilyLog()
        #endif
    }

    /// This device's reports in the last [days] days.
    func recent(days: Double = 7) -> [Report] {
        let since = Date().timeIntervalSince1970 - days * 86_400
        return mine().filter { $0.at >= since }
    }

    // MARK: Taking reports in

    fileprivate func take(_ payloads: [MXDiagnosticPayload]) {
        var new: [Report] = []
        for p in payloads {
            saveFull(p)
            for c in p.crashDiagnostics ?? [] { new.append(report(c, "Crash", crashDetail(c))) }
            for h in p.hangDiagnostics ?? [] {
                new.append(report(h, "Freeze", "\(seconds(h.hangDuration)) without responding" + frames(h.callStackTree)))
            }
            for c in p.cpuExceptionDiagnostics ?? [] { new.append(report(c, "CPU", "\(seconds(c.totalCPUTime)) of CPU" + frames(c.callStackTree))) }
            for d in p.diskWriteExceptionDiagnostics ?? [] { new.append(report(d, "Disk Writes", "\(d.totalWritesCaused)" + frames(d.callStackTree))) }
            if #available(iOS 16.0, macOS 13.0, *) {
                for l in p.appLaunchDiagnostics ?? [] { new.append(report(l, "Slow Launch", "\(seconds(l.launchDuration)) to open" + frames(l.callStackTree))) }
            }
        }
        guard !new.isEmpty else { return }
        var list = mine()
        for r in new where !list.contains(r) { list.append(r) }
        list.sort { $0.at > $1.at }
        if list.count > Self.keptPerDevice { list = Array(list.prefix(Self.keptPerDevice)) }
        var family = Saved.load(Self.key, as: [String: String].self) ?? [:]
        if let data = try? JSONEncoder().encode(list), let text = String(data: data, encoding: .utf8) {
            family[deviceKey] = text
            Saved.save(Self.key, family)   // the settings sync notices and passes it on
        }
        #if os(macOS)
        writeFamilyLog()
        #endif
    }

    private func report(_ d: MXDiagnostic, _ kind: String, _ detail: String) -> Report {
        Report(at: Date().timeIntervalSince1970, kind: kind, build: d.metaData.applicationBuildVersion, detail: detail)
    }

    private func crashDetail(_ c: MXCrashDiagnostic) -> String {
        var bits: [String] = []
        if let t = c.exceptionType { bits.append("exception \(t)") }
        if let s = c.signal { bits.append("signal \(s)") }
        if let r = c.terminationReason, !r.isEmpty { bits.append(r) }
        if let o = c.virtualMemoryRegionInfo, !o.isEmpty { bits.append(String(o.prefix(120))) }
        return (bits.isEmpty ? "crashed" : bits.joined(separator: ", ")) + frames(c.callStackTree)
    }

    private func seconds(_ m: Measurement<UnitDuration>) -> String {
        String(format: "%.1f s", m.converted(to: .seconds).value)
    }

    /// The first frames of the thread that was running (binary and offset; symbols are matched to the build later).
    private func frames(_ tree: MXCallStackTree) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: tree.jsonRepresentation()) as? [String: Any],
              let stacks = json["callStacks"] as? [[String: Any]] else { return "" }
        let stack = stacks.first { ($0["threadAttributed"] as? Bool) == true } ?? stacks.first
        var out: [String] = []
        var frame = (stack?["callStackRootFrames"] as? [[String: Any]])?.first
        while let f = frame, out.count < 8 {
            let name = f["binaryName"] as? String ?? "?"
            let offset = f["offsetIntoBinaryTextSegment"] as? Int ?? 0
            out.append("\(name)+\(offset)")
            frame = (f["subFrames"] as? [[String: Any]])?.first
        }
        return out.isEmpty ? "" : " | " + out.joined(separator: " < ")
    }

    // MARK: Where they're kept

    /// This device, as the family's settings know it.
    private var deviceKey: String {
        let p = Fleet.shared.phone
        return "\(p.name) (\(p.id.prefix(8)))"
    }

    private func mine() -> [Report] {
        let family = Saved.load(Self.key, as: [String: String].self) ?? [:]
        guard let text = family[deviceKey], let data = text.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([Report].self, from: data)) ?? []
    }

    private static var folder: URL? {
        #if os(macOS)
        guard let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else { return nil }
        let dir = lib.appendingPathComponent("Logs/Woodruff Family/Diagnostics", isDirectory: true)
        #else
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let dir = caches.appendingPathComponent("Diagnostics", isDirectory: true)
        #endif
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The whole report as Apple gave it (the last 20 kept).
    private func saveFull(_ p: MXDiagnosticPayload) {
        guard let dir = Self.folder else { return }
        let data = p.jsonRepresentation()
        let name = "\(Int(p.timeStampEnd.timeIntervalSince1970)).json"
        DispatchQueue.global(qos: .utility).async {
            try? data.write(to: dir.appendingPathComponent(name), options: .atomic)
            let fm = FileManager.default
            let all = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
            for old in all.dropFirst(20) { try? fm.removeItem(at: old) }
        }
    }

    #if os(macOS)
    /// Every device's summaries, newest first, in ~/Library/Logs/Woodruff Family/diagnostics.log.
    func writeFamilyLog() {
        let family = Saved.load(Self.key, as: [String: String].self) ?? [:]
        var lines: [(Double, String)] = []
        let f = ISO8601DateFormatter.plain
        for (device, text) in family {
            guard let data = text.data(using: .utf8), let list = try? JSONDecoder().decode([Report].self, from: data) else { continue }
            for r in list {
                lines.append((r.at, "\(f.string(from: Date(timeIntervalSince1970: r.at)))\t\(device)\tbuild \(r.build)\t\(r.kind)\t\(r.detail)"))
            }
        }
        let text = lines.sorted { $0.0 > $1.0 }.map(\.1).joined(separator: "\n") + "\n"
        guard let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else { return }
        let file = lib.appendingPathComponent("Logs/Woodruff Family/diagnostics.log")
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? text.data(using: .utf8)?.write(to: file, options: .atomic)
        }
    }
    #endif
}

extension Diagnostics: MXMetricManagerSubscriber {
    nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        Task { @MainActor in Diagnostics.shared.take(payloads) }
    }
}
