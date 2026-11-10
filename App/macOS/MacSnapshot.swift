import AppKit
import SwiftUI
import WoodruffKit

/// Pictures of the Mac app's own windows, taken by the app itself, to check its screens from Terminal without anyone
/// looking at the display:
///
///     open -n -a "Woodruff Family" --args -demo YES -macSnapshot /path/to/a/folder
///
/// Home, Watch and Settings are opened in turn, then the remote's panel, a title's page and this Mac's Settings
/// window (⌘,), and every window the app is showing is written as a PNG in that folder each time (home.png,
/// watch.png, settings.png, remote.png, title.png, mac-settings.png; a second window is home-2.png, and so on);
/// "done.txt" is written last, with a line for each picture saying how it was made and lines for what a picture
/// drawn by the app can't show. Nothing happens unless the app was opened with -macSnapshot (this launch's own
/// argument, never a saved setting).
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
                lines += facts(section.rawValue)
            }
            // The remote's panel, open beside Home. (Opened without its slide: with the screen locked nothing
            // animates, and the panel stayed where its slide starts, just outside the window.)
            UserDefaults.standard.set(AppSection.home.rawValue, forKey: "section")
            still { Fleet.shared.remotePanel = true }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            lines += shoot("remote", into: folder)
            lines += facts("remote")
            still { Fleet.shared.remotePanel = false }
            // A title's page on Watch (the sample show), pushed without its slide for the same reason. Its title is
            // read first, as it is when a title is opened a second time, so the page shows it at once: what a page
            // reads after it opens fades in, and with the screen locked nothing fades.
            UserDefaults.standard.set(AppSection.watch.rawValue, forKey: "section")
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            let sample = "t_backyard_science"
            if let source = WatchSources.current(Fleet.shared), let details = try? await source.title(sample) {
                TitleCache.shared.keep(details, hub: source.sourceID, id: sample)
                lines.append("title read: \(details.title)")
            } else {
                lines.append("title read: failed")
            }
            still { MacNav.shared.push("Backyard Science", backTo: "Watch", TitleSheet(id: sample)) }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            lines += shoot("title", into: folder)
            lines += facts("title")
            still { MacNav.shared.reset() }
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

    /// A change made without animation: with the screen locked nothing animates, and what slides in (a page, the
    /// remote's panel) stays where its slide starts.
    private static func still(_ change: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, change)
    }

    /// Every window the app is showing, written as [name].png, [name]-2.png…: a line for each, saying what was
    /// written and how, or why it couldn't be. The main window is first.
    private static func shoot(_ name: String, into folder: URL) -> [String] {
        var windows = NSApp.windows.filter { $0.isVisible && $0.contentView != nil && $0.frame.width > 200 && $0.frame.height > 150 }
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

    /// What a picture drawn by the app can't show (its glass and some controls come out blank): the main window's
    /// toolbar items, the search fields in it, and every window the app is showing.
    private static func facts(_ name: String) -> [String] {
        var lines: [String] = []
        if let window = MainWindow.current {
            let items = window.toolbar?.items.map { $0.itemIdentifier.rawValue.components(separatedBy: ".").last ?? "?" } ?? []
            lines.append("\(name) toolbar: \(items.isEmpty ? "none" : items.joined(separator: ", "))")
            let fields = searchFields(in: window.contentView?.superview)
            lines.append("\(name) search fields: \(fields.isEmpty ? "none" : fields.joined(separator: "; "))")
            let panels = sidePanels(in: window.contentView, window: window)
            lines.append("\(name) side panels: \(panels.isEmpty ? "none" : panels.joined(separator: "; "))")
            lines += scrollFacts(name, in: window)
        }
        let windows = NSApp.windows.filter(\.isVisible).map { "\(type(of: $0)) “\($0.title)” \(Int($0.frame.width))×\(Int($0.frame.height))" }
        lines.append("\(name) windows: \(windows.joined(separator: "; ")); remote panel \(Fleet.shared.remotePanel ? "on" : "off")")
        return lines
    }

    /// Views in the main window shaped like a panel down one side (250 to 420 points wide, most of the window's
    /// height): the remote's panel when it's open. Each one's kind, size and where it starts.
    private static func sidePanels(in view: NSView?, window: NSWindow, depth: Int = 0) -> [String] {
        guard let view, depth < 14, !view.isHidden else { return [] }
        let frame = view.convert(view.bounds, to: nil)
        if frame.width >= 250, frame.width <= 420, frame.height >= window.frame.height * 0.6 {
            return ["\(type(of: view)) \(Int(frame.width))×\(Int(frame.height)) from x \(Int(frame.minX))"]
        }
        var found: [String] = []
        for sub in view.subviews { found += sidePanels(in: sub, window: window, depth: depth + 1) }
        return found
    }

    /// The page's scrolling parts, measured (a picture drawn by the app leaves some of them out): each one's size, the
    /// size of what's in it, how many layers that is and how many of them have something drawn, how many are cut to
    /// a shape, and whether anything above it is hidden, see-through or cut to a shape.
    private static func scrollFacts(_ name: String, in window: NSWindow) -> [String] {
        var lines: [String] = []
        for scroll in scrollViews(in: window.contentView) where scroll.frame.width > 400 && scroll.frame.height > 300 && !scroll.isHiddenOrHasHiddenAncestor {
            let document = scroll.documentView
            var total = 0, drawn = 0, shaped = 0
            if let layer = document?.layer { census(layer, &total, &drawn, &shaped) }
            var above: [String] = []
            var layer = document?.layer
            while let l = layer {
                if l.isHidden { above.append("hidden") } else if l.opacity < 0.05 { above.append("see-through") } else if l.mask != nil { above.append("cut to a shape") }
                layer = l.superlayer
            }
            lines.append("\(name) scrolling part \(Int(scroll.frame.width))×\(Int(scroll.frame.height)): holds \(Int(document?.frame.width ?? 0))×\(Int(document?.frame.height ?? 0)), \(total) layers, \(drawn) drawn, \(shaped) cut to a shape; above it: \(above.isEmpty ? "all showing" : above.joined(separator: ", "))")
        }
        if lines.isEmpty { lines.append("\(name) scrolling parts: none") }
        return lines
    }

    private static func scrollViews(in view: NSView?) -> [NSScrollView] {
        guard let view else { return [] }
        var found: [NSScrollView] = []
        if let scroll = view as? NSScrollView { found.append(scroll) }
        for sub in view.subviews { found += scrollViews(in: sub) }
        return found
    }

    /// Counts the layers under [layer]: all of them, those with something drawn, and those cut to a shape.
    private static func census(_ layer: CALayer, _ total: inout Int, _ drawn: inout Int, _ shaped: inout Int) {
        total += 1
        if layer.contents != nil { drawn += 1 }
        if layer.mask != nil { shaped += 1 }
        for sub in layer.sublayers ?? [] { census(sub, &total, &drawn, &shaped) }
    }

    /// The search fields under [view]: each one's size, whether it's hidden, and its prompt.
    private static func searchFields(in view: NSView?) -> [String] {
        guard let view else { return [] }
        var found: [String] = []
        if let field = view as? NSSearchField {
            found.append("\(Int(field.frame.width))×\(Int(field.frame.height))\(field.isHiddenOrHasHiddenAncestor ? " hidden" : "") “\(field.placeholderString ?? "")”")
        }
        for sub in view.subviews { found += searchFields(in: sub) }
        return found
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
