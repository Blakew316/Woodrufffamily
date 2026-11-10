import AppKit
import WoodruffKit

/// Pictures of the Mac app's own windows, taken by the app itself, to check its screens from Terminal without anyone
/// looking at the display:
///
///     open -n -a "Woodruff Family" --args -demo YES -macSnapshot /path/to/a/folder
///
/// Home, Watch and Settings are opened in turn, then the remote's panel and this Mac's Settings window (⌘,), and
/// every window the app is showing is written as a PNG in that folder each time (home.png, watch.png, settings.png,
/// remote.png, mac-settings.png; a second window is home-2.png, and so on); "done.txt" is written last, a line for
/// each picture saying how it was made. With -route title as well, Watch opens on a title's page. Nothing happens
/// unless the app was opened with -macSnapshot (this launch's own argument, never a saved setting).
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
                lines += shoot(section.rawValue, into: folder)
            }
            // The remote's panel, open beside Home.
            UserDefaults.standard.set(AppSection.home.rawValue, forKey: "section")
            Fleet.shared.remotePanel = true
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            lines += shoot("remote", into: folder)
            Fleet.shared.remotePanel = false
            // This Mac's Settings window: opened as ⌘, opens it, by the app menu's own item.
            if let menu = NSApp.mainMenu?.items.first?.submenu,
               let i = menu.items.firstIndex(where: { $0.keyEquivalent == "," }) {
                menu.performActionForItem(at: i)
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                lines += shoot("mac-settings", into: folder)
            } else {
                lines.append("mac-settings: no Settings… item in the app menu")
            }
            try? (lines.joined(separator: "\n") + "\n").write(to: folder.appendingPathComponent("done.txt"), atomically: true, encoding: .utf8)
        }
    }

    /// Every window the app is showing, written as [name].png, [name]-2.png…: a line for each, saying what was
    /// written and how, or why it couldn't be. The main window is first.
    private static func shoot(_ name: String, into folder: URL) -> [String] {
        var windows = NSApp.windows.filter { $0.isVisible && $0.contentView != nil && $0.frame.width > 300 && $0.frame.height > 200 }
        if let main = MainWindow.current, let i = windows.firstIndex(of: main) {
            windows.remove(at: i)
            windows.insert(main, at: 0)
        }
        guard !windows.isEmpty else { return ["\(name): no window (\(NSApp.windows.count) in the app)"] }
        return windows.enumerated().map { (i, window) -> String in
            let file = i == 0 ? name : "\(name)-\(i + 1)"
            let title = window.title.isEmpty ? "untitled" : window.title
            let how: String
            let picture: CGImage
            if let served = serverPicture(window), !blank(served) {
                picture = served
                how = "as the system draws it"
            } else if let drawn = layerPicture(window) {
                picture = drawn
                how = "drawn in the app: no glass or materials"
            } else {
                return "\(file) (\(title)): nothing to draw"
            }
            let rep = NSBitmapImageRep(cgImage: picture)
            guard let png = rep.representation(using: .png, properties: [:]) else { return "\(file) (\(title)): no PNG" }
            do {
                try png.write(to: folder.appendingPathComponent("\(file).png"))
                return "\(file) (\(title)): \(picture.width)×\(picture.height) pixels, \(how)"
            } catch {
                return "\(file) (\(title)): \(error.localizedDescription)"
            }
        }
    }

    /// The window as the system draws it (glass, materials and scrolling lists included), asked of the window server
    /// by the window's number. An app may always read its own windows. The call left the SDK in macOS 15, and what
    /// replaced it asks for Screen Recording permission, which nobody is there to give, so it's looked up by name:
    /// nil when it isn't there or gives nothing.
    private static func serverPicture(_ window: NSWindow) -> CGImage? {
        typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard window.windowNumber > 0,
              let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        let capture = unsafeBitCast(symbol, to: Capture.self)
        // Only this window (1 << 3), without its shadow (1 << 0), at the display's own resolution (1 << 3).
        return capture(.null, 1 << 3, UInt32(window.windowNumber), (1 << 0) | (1 << 3))?.takeRetainedValue()
    }

    /// The window's layers drawn by the app itself: text, pictures and shapes, without what the system composites
    /// (glass, materials, blurs).
    private static func layerPicture(_ window: NSWindow) -> CGImage? {
        guard let view = window.contentView?.superview ?? window.contentView, let layer = view.layer else { return nil }
        let scale = max(1, window.backingScaleFactor)
        let width = Int(view.bounds.width * scale), height = Int(view.bounds.height * scale)
        guard width > 0, height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor((window.backgroundColor.usingColorSpace(.sRGB) ?? .black).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        if layer.contentsAreFlipped() {
            context.translateBy(x: 0, y: view.bounds.height)
            context.scaleBy(x: 1, y: -1)
        }
        layer.render(in: context)
        return context.makeImage()
    }

    /// Whether a picture is one flat colour (a window the system had nothing drawn for).
    private static func blank(_ image: CGImage) -> Bool {
        let side = 24
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = context.data else { return false }
        let count = side * side * 4
        let pixels = data.bindMemory(to: UInt8.self, capacity: count)
        var low = [UInt8](repeating: 255, count: 3), high = [UInt8](repeating: 0, count: 3)
        for p in stride(from: 0, to: count, by: 4) {
            for c in 0..<3 {
                low[c] = min(low[c], pixels[p + c])
                high[c] = max(high[c], pixels[p + c])
            }
        }
        return (0..<3).allSatisfy { Int(high[$0]) - Int(low[$0]) < 6 }
    }
}
