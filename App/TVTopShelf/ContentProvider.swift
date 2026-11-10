import TVServices
import os

/// Woodruff's Top Shelf: with the app's icon highlighted on the Apple TV's Home Screen, the iCloud Photos album
/// picked in Woodruff → Settings → Top Shelf, as a slideshow across the top of the screen. The app keeps the
/// pictures ready in the shared folder; this only lists them.
@objc(ContentProvider)
final class ContentProvider: TVTopShelfContentProvider {
    static let group = "group.com.blakew316.woodruff.tv"

    // The completion-handler form, as Apple's own template has it (the system calls this one directly).
    private static let log = Logger(subsystem: "com.blakew316.woodruff.tv.topshelf", category: "TopShelf")

    override func loadTopShelfContent(completionHandler: @escaping ((any TVTopShelfContent)?) -> Void) {
        Self.log.notice("Woodruff Top Shelf asked for its content")
        let c = content()
        Self.log.notice("Woodruff Top Shelf answered: \(c == nil ? "nothing" : "a slideshow", privacy: .public)")
        completionHandler(c)
    }

    private func content() -> (any TVTopShelfContent)? {
        UserDefaults(suiteName: Self.group)?.set(Date().timeIntervalSince1970, forKey: "topShelf.asked")
        // The album's photos the app kept in the shared folder; until there are some, the nature photographs that come
        // with the app, so the Top Shelf is never empty.
        let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.group)?
            .appendingPathComponent("Library/Caches/TopShelf", isDirectory: true)
        // When the Apple TV last asked (Woodruff → Settings → Top Shelf shows it), and how many photos it was given.
        if let base = dir?.deletingLastPathComponent() {
            try? "\(Date().timeIntervalSince1970)".write(to: base.appendingPathComponent("topshelf-asked.txt"), atomically: true, encoding: .utf8)
        }
        let kept = dir.flatMap { try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil) } ?? []
        // Beside a photo (1920 × 1080), the app keeps its 3840 × 2160 copy for a 4K screen ("…@2x.jpg"): not a photo
        // of its own.
        let large = Set(kept.map(\.lastPathComponent).filter { $0.hasSuffix("@2x.jpg") })
        // The album's photos; the nature photographs that come with it only until there are some.
        var pictures = kept.filter { $0.pathExtension == "jpg" && !large.contains($0.lastPathComponent) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        if pictures.isEmpty { pictures = Bundle.main.urls(forResourcesWithExtension: "jpg", subdirectory: nil) ?? [] }
        guard !pictures.isEmpty else { return nil }
        Self.log.notice("Woodruff Top Shelf has \(pictures.count, privacy: .public) photos, shared folder \(dir?.path ?? "none", privacy: .public)")
        // Carousel: the photos full width across the top, one moving on to the next by itself (a slideshow).
        let items: [TVTopShelfCarouselItem] = pictures.map { url in
            let item = TVTopShelfCarouselItem(identifier: url.lastPathComponent)
            item.setImageURL(url, for: .screenScale1x)
            // On a 4K screen: its 3840 × 2160 copy, when the app has made one (else the same picture, as before).
            let name = url.deletingPathExtension().lastPathComponent + "@2x.jpg"
            let sharp = large.contains(name) ? url.deletingLastPathComponent().appendingPathComponent(name) : url
            item.setImageURL(sharp, for: .screenScale2x)
            // Choosing a photo opens Woodruff on Home (`TVMacRoot` takes the link).
            if let open = URL(string: "woodruff://home") { item.displayAction = TVTopShelfAction(url: open) }
            return item
        }
        return TVTopShelfCarouselContent(style: .details, items: items)
    }
}
