import TVServices

/// Woodruff's Top Shelf: with the app's icon highlighted on the Apple TV's Home Screen, the iCloud Photos album
/// picked in Woodruff → Settings → Top Shelf, as a slideshow across the top of the screen. The app keeps the
/// pictures ready in the shared folder; this only lists them.
final class ContentProvider: TVTopShelfContentProvider {
    static let group = "group.com.blakew316.woodruff.tv"

    override func loadTopShelfContent() async -> (any TVTopShelfContent)? {
        // The album's photos the app kept in the shared folder; until there are some, the nature photographs that come
        // with the app, so the Top Shelf is never empty.
        let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.group)?
            .appendingPathComponent("Library/Caches/TopShelf", isDirectory: true)
        // When the Apple TV last asked (Woodruff → Settings → Top Shelf shows it), and how many photos it was given.
        if let base = dir?.deletingLastPathComponent() {
            try? "\(Date().timeIntervalSince1970)".write(to: base.appendingPathComponent("topshelf-asked.txt"), atomically: true, encoding: .utf8)
        }
        let kept = dir.flatMap { try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil) } ?? []
        // The album's photos, then the nature photographs that come with it.
        let pictures = kept.filter { $0.pathExtension == "jpg" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            + (Bundle.main.urls(forResourcesWithExtension: "jpg", subdirectory: nil) ?? [])
        guard !pictures.isEmpty else { return nil }
        let items: [TVTopShelfCarouselItem] = pictures.map { url in
            let item = TVTopShelfCarouselItem(identifier: url.lastPathComponent)
            item.title = "Woodruff Family"
            item.setImageURL(url, for: .screenScale1x)
            item.setImageURL(url, for: .screenScale2x)
            if let open = URL(string: "woodruff://home") { item.displayAction = TVTopShelfAction(url: open) }
            return item
        }
        return TVTopShelfCarouselContent(style: .actions, items: items)
    }
}
