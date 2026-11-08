import TVServices

/// Woodruff's Top Shelf: with the app's icon highlighted on the Apple TV's Home Screen, the iCloud Photos album
/// picked in Woodruff → Settings → Top Shelf, as a slideshow across the top of the screen. The app keeps the
/// pictures ready in the shared folder; this only lists them.
final class ContentProvider: TVTopShelfContentProvider {
    static let group = "group.com.blakew316.woodruff.tv"

    override func loadTopShelfContent() async -> (any TVTopShelfContent)? {
        guard let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.group)?
            .appendingPathComponent("Library/Caches/TopShelf", isDirectory: true),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return nil }
        let pictures = files.filter { $0.pathExtension == "jpg" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !pictures.isEmpty else { return nil }
        let items: [TVTopShelfCarouselItem] = pictures.map { url in
            let item = TVTopShelfCarouselItem(identifier: url.lastPathComponent)
            item.setImageURL(url, for: .screenScale1x)
            item.setImageURL(url, for: .screenScale2x)
            if let open = URL(string: "woodruff://home") { item.displayAction = TVTopShelfAction(url: open) }
            return item
        }
        return TVTopShelfCarouselContent(style: .actions, items: items)
    }
}
