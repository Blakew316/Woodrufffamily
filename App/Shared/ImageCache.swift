import SwiftUI
import ImageIO
import CryptoKit

/// Every picture the app shows from the network (posters, backdrops, thumbnails, speaker art, photos): fetched once,
/// decoded at a sensible size off the main thread, kept in memory and on disk, so a page opened again shows its
/// pictures at once instead of downloading and fading them in every time.
actor ImageStore {
    static let shared = ImageStore()

    /// Decoded pictures, freed by the system under memory pressure.
    nonisolated let memory: NSCache<NSURL, PlatformImage> = {
        let c = NSCache<NSURL, PlatformImage>()
        c.countLimit = 400
        c.totalCostLimit = 160 * 1024 * 1024
        return c
    }()

    private let folder: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 20
        c.httpMaximumConnectionsPerHost = 6
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.urlCache = nil
        return URLSession(configuration: c)
    }()

    /// One download per picture at a time, however many tiles ask for it.
    private var inFlight: [URL: Task<PlatformImage?, Never>] = [:]

    /// A picture already in memory, for drawing it in the very first frame.
    nonisolated func cached(_ url: URL) -> PlatformImage? { memory.object(forKey: url as NSURL) }

    func image(_ url: URL) async -> PlatformImage? {
        if let hit = memory.object(forKey: url as NSURL) { return hit }
        if let running = inFlight[url] { return await running.value }
        let file = folder.appendingPathComponent(Self.key(url))
        let session = self.session
        let task = Task<PlatformImage?, Never>.detached(priority: .userInitiated) {
            if let data = try? Data(contentsOf: file), let img = Self.decode(data) { return img }
            guard let (data, response) = try? await session.data(from: url),
                  (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
                  let img = Self.decode(data) else { return nil }
            try? data.write(to: file, options: .atomic)
            return img
        }
        inFlight[url] = task
        let img = await task.value
        inFlight[url] = nil
        if let img { memory.setObject(img, forKey: url as NSURL, cost: Self.cost(img)) }
        return img
    }

    /// Clears the disk copies when they grow past ~300 MB (oldest first).
    func trim() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { return }
        let info = files.compactMap { f -> (URL, Date, Int)? in
            guard let v = try? f.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else { return nil }
            return (f, v.contentModificationDate ?? .distantPast, v.fileSize ?? 0)
        }.sorted { $0.1 < $1.1 }
        var total = info.reduce(0) { $0 + $1.2 }
        for (f, _, size) in info where total > 300 * 1024 * 1024 {
            try? fm.removeItem(at: f)
            total -= size
        }
    }

    private static func key(_ url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Decoded no bigger than needed on screen (a backdrop across a big window at most), which keeps memory low.
    private static func decode(_ data: Data) -> PlatformImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 1800,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        #if os(macOS)
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        #else
        return UIImage(cgImage: cg)
        #endif
    }

    private static func cost(_ img: PlatformImage) -> Int {
        #if os(macOS)
        let s = img.size
        return Int(s.width * s.height * 4)
        #else
        guard let cg = img.cgImage else { return 1 }
        return cg.bytesPerRow * cg.height
        #endif
    }
}

/// A network picture through ``ImageStore``: drawn at once when it's already been seen, otherwise fading in when it
/// arrives. [placeholder] shows meanwhile, [failure] when there's no picture to be had.
struct CachedImage<Placeholder: View, Failure: View>: View {
    var url: URL?
    var contentMode: ContentMode = .fill
    @ViewBuilder var placeholder: () -> Placeholder
    @ViewBuilder var failure: () -> Failure
    @State private var loaded: PlatformImage?
    @State private var failed = false

    var body: some View {
        let shown = loaded ?? url.flatMap { ImageStore.shared.cached($0) }
        Group {
            if let shown {
                Image(platformImage: shown).resizable().aspectRatio(contentMode: contentMode)
            } else if failed {
                failure()
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            guard let url else { loaded = nil; failed = true; return }
            if let hit = ImageStore.shared.cached(url) { loaded = hit; failed = false; return }
            failed = false
            let img = await ImageStore.shared.image(url)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) {
                loaded = img
                failed = img == nil
            }
        }
    }
}

extension CachedImage where Failure == Placeholder {
    init(url: URL?, contentMode: ContentMode = .fill, @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.init(url: url, contentMode: contentMode, placeholder: placeholder, failure: placeholder)
    }
}
