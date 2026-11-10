import AppKit
import WoodruffKit

/// Pictures of the Mac app's own window, taken by the app itself, to check its screens from Terminal without anyone
/// looking at the display:
///
///     open -n -a "Woodruff Family" --args -demo YES -macSnapshot /path/to/a/folder
///
/// Home, Watch and Settings are opened in turn and the window's content is drawn into a PNG in that folder
/// (home.png, watch.png, settings.png); "done.txt" is written last, a line for each. They're drawn by the app, not
/// read off the display, so it works with the screen locked; glass and other materials the system composites may
/// come out flat. Nothing happens unless the app was opened with -macSnapshot (this launch's own argument, never a
/// saved setting).
@MainActor
enum MacSnapshot {
    private static var asked = false

    static func startIfAsked() {
        guard !asked,
              let dir = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)["macSnapshot"] as? String,
              !dir.isEmpty else { return }
        asked = true
        Task {
            // The window and the first answers first.
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            let folder = URL(fileURLWithPath: dir, isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var lines: [String] = []
            for section in AppSection.mac {
                UserDefaults.standard.set(section.rawValue, forKey: "section")
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                lines.append(shoot(section.rawValue, into: folder))
            }
            try? (lines.joined(separator: "\n") + "\n").write(to: folder.appendingPathComponent("done.txt"), atomically: true, encoding: .utf8)
        }
    }

    /// The main window's content drawn into [name].png: what was written, or why it couldn't be.
    private static func shoot(_ name: String, into folder: URL) -> String {
        let window = MainWindow.current ?? NSApp.windows.first { $0.contentView != nil && $0.frame.width > 400 }
        guard let window, let view = window.contentView else { return "\(name): no window (\(NSApp.windows.count) in the app)" }
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0, let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else {
            return "\(name): nothing to draw"
        }
        view.cacheDisplay(in: bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return "\(name): no PNG" }
        do {
            try png.write(to: folder.appendingPathComponent("\(name).png"))
            return "\(name): \(Int(bounds.width))×\(Int(bounds.height)) points, \(png.count) bytes"
        } catch {
            return "\(name): \(error.localizedDescription)"
        }
    }
}
