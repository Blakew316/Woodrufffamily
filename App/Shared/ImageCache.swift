import SwiftUI
import ImageIO
import CryptoKit
import WoodruffKit

/// Every picture the app shows from the network (posters, backdrops, thumbnails, speaker art, photos): fetched once,
/// decoded off the main thread at the size it's shown at, kept in memory and on disk, so a page opened again shows its
/// pictures at once instead of downloading and fading them in every time.
actor ImageStore {
    static let shared = ImageStore()

    /// The sizes pictures are decoded at (pixels on the longer side). A view asks for what it needs and gets the
    /// smallest of these that's at least that, so a poster tile never holds a backdrop-sized picture in memory.
    static let sizes = [128, 256, 512, 1024, 1800, 2400]

    /// Decoded pictures by "<key>#<size>", freed by the system under memory pressure.
    nonisolated let memory = ImageMemory()

    /// The pictures as they were downloaded (any size can be made from them), kept between launches.
    private static let folder: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// The app's own connection settings (so Sample mode's pretend TVs answer pictures too), without a cache of the
    /// answers: the pictures are kept here instead.
    private static let session: URLSession = {
        let c = URLSession.woodruff.configuration
        c.timeoutIntervalForRequest = 20
        c.httpMaximumConnectionsPerHost = 6
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.urlCache = nil
        return URLSession(configuration: c)
    }()

    /// Work shared by everyone asking for the same picture at once, stopped when the last of them stops waiting (the
    /// tiles that wanted it scrolled away), so pictures nobody will see don't hold up the ones they will.
    private struct Decode {
        let id: UInt64
        let task: Task<PlatformImage?, Never>
        var waiters: Int
    }
    private struct Download {
        let id: UInt64
        let task: Task<Data?, Never>
        var waiters: Int
    }
    /// Pictures being made, by "<key>#<size>".
    private var decoding: [String: Decode] = [:]
    /// Pictures being downloaded, by key: one download however many sizes of it are being made.
    private var downloading: [String: Download] = [:]
    private var flights: UInt64 = 0
    /// Pictures written to disk since the disk copies were last trimmed, and whether a trim is under way.
    private var writes = 0
    private var trimming = false

    /// A picture already in memory at [maxPixel] or bigger, for drawing it in the very first frame.
    nonisolated func cached(_ url: URL, maxPixel: Int = 1800) -> PlatformImage? {
        inMemory(Self.key(url), maxPixel)
    }

    /// The picture at [url], decoded for [maxPixel] pixels on its longer side. [storeOnDisk] false keeps it in memory
    /// only (a big photo looked at once, which would push the posters out of the disk cache).
    func image(_ url: URL, maxPixel: Int = 1800, storeOnDisk: Bool = true) async -> PlatformImage? {
        let key = Self.key(url)
        if let hit = inMemory(key, maxPixel) { return hit }
        let size = Self.size(for: maxPixel)
        let name = "\(key)#\(size)"
        let flight: Decode
        if var running = decoding[name] {
            running.waiters += 1
            decoding[name] = running
            flight = running
        } else {
            flights &+= 1
            let task = Task<PlatformImage?, Never>.detached(priority: .userInitiated) {
                await self.make(url, key: key, size: size, storeOnDisk: storeOnDisk)
            }
            flight = Decode(id: flights, task: task, waiters: 1)
            decoding[name] = flight
        }
        let id = flight.id
        let task = flight.task
        let img = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            Task { await self.leaveDecode(name, id: id) }
        }
        // The first back from it lets the next one asking start afresh; a picture made is kept, even if everyone who
        // wanted it has gone meanwhile (it was read from disk before the work could stop).
        if decoding[name]?.id == id { decoding[name] = nil }
        if let img, memory.object(name) !== img { memory.set(img, name, cost: Self.cost(img)) }
        return img
    }

    /// Downloads [url] to disk without making a picture of it yet (the page about to be scrolled to), so showing it
    /// then only has to read it. Nothing when it's in memory or on disk already.
    nonisolated func prefetch(_ url: URL) async {
        let key = Self.key(url)
        let file = Self.folder.appendingPathComponent(Self.fileName(key))
        if inMemory(key, Self.sizes[0]) != nil || FileManager.default.fileExists(atPath: file.path) { return }
        _ = await fetch(url, key: key, to: file)
    }

    /// Keeps the disk copies under ~300 MB (oldest first). Off the actor: listing and deleting files never holds up a
    /// picture being asked for.
    nonisolated func trim() async {
        Self.trimDisk()
    }

    // MARK: Making a picture

    private nonisolated func inMemory(_ key: String, _ maxPixel: Int) -> PlatformImage? {
        let wanted = Self.size(for: maxPixel)
        // A bigger one already made serves a smaller tile as well.
        for s in Self.sizes where s >= wanted {
            if let hit = memory.object("\(key)#\(s)") { return hit }
        }
        return nil
    }

    /// [url] at [size]: from its copy on disk when there is one, else downloaded (and kept on disk). Runs off the actor.
    private nonisolated func make(_ url: URL, key: String, size: Int, storeOnDisk: Bool) async -> PlatformImage? {
        let file = Self.folder.appendingPathComponent(Self.fileName(key))
        if let data = try? Data(contentsOf: file, options: .mappedIfSafe), let img = Self.decode(data, size: size) { return img }
        guard !Task.isCancelled else { return nil }
        guard let data = await fetch(url, key: key, to: storeOnDisk ? file : nil), !Task.isCancelled else { return nil }
        return Self.decode(data, size: size)
    }

    /// [url]'s bytes from the network, written to [file] when there's one.
    private func fetch(_ url: URL, key: String, to file: URL?) async -> Data? {
        let flight: Download
        if var running = downloading[key] {
            running.waiters += 1
            downloading[key] = running
            flight = running
        } else {
            flights &+= 1
            let session = Self.session
            let timeout = Self.timeout(for: url)
            let task = Task<Data?, Never>.detached(priority: .userInitiated) {
                let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
                guard let (data, response) = try? await session.data(for: request),
                      (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
                      Self.isPicture(data) else { return nil }
                if let file { try? data.write(to: file, options: .atomic) }
                return data
            }
            flight = Download(id: flights, task: task, waiters: 1)
            downloading[key] = flight
        }
        let id = flight.id
        let task = flight.task
        let data = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            Task { await self.leaveDownload(key, id: id) }
        }
        if downloading[key]?.id == id {
            downloading[key] = nil
            if data != nil && file != nil { wrote() }
        }
        return data
    }

    /// One who was waiting for [name] stopped (its tile went away): the last one to go stops the work.
    private func leaveDecode(_ name: String, id: UInt64) {
        guard var f = decoding[name], f.id == id else { return }
        f.waiters -= 1
        if f.waiters > 0 {
            decoding[name] = f
        } else {
            decoding[name] = nil
            f.task.cancel()
        }
    }

    private func leaveDownload(_ key: String, id: UInt64) {
        guard var f = downloading[key], f.id == id else { return }
        f.waiters -= 1
        if f.waiters > 0 {
            downloading[key] = f
        } else {
            downloading[key] = nil
            f.task.cancel()
        }
    }

    /// Every 50 pictures written, the disk copies are trimmed (in the background).
    private func wrote() {
        writes += 1
        guard writes >= 50, !trimming else { return }
        writes = 0
        trimming = true
        Task.detached(priority: .background) {
            Self.trimDisk()
            await self.trimmed()
        }
    }

    private func trimmed() { trimming = false }

    private static func trimDisk() {
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

    // MARK: Keys, sizes and decoding

    /// What a picture is kept by: for the library's pictures (`/api/poster`) only what's asked for, without the TV or
    /// its pairing key (`k`), since every TV has the same ones. Anything else a TV hands out (a Memories photo, a file)
    /// is that TV's own: its address, with a short stand-in for the pairing key instead of the key itself, so another
    /// TV given the same address later (or the same TV reset and paired again) never shows these at the same path.
    static func key(_ url: URL) -> String {
        guard url.query != nil || url.path == "/api/poster",
              let c = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return url.absoluteString }
        let items = c.percentEncodedQueryItems ?? []
        let query = items.filter { $0.name != "k" }
            .map { item in item.value.map { "\(item.name)=\($0)" } ?? item.name }
            .joined(separator: "&")
        let poster = c.percentEncodedPath == "/api/poster"
        // (Sample mode's pretend posters stay apart from the real ones.)
        let everyTV = poster && c.host != Demo.hub.connection.base.host
        let place = everyTV ? "" : "\(c.scheme ?? "")://\(c.host ?? "")" + (c.port.map { ":\($0)" } ?? "")
        let pairing: String? = poster ? nil : items.first(where: { $0.name == "k" })?.value.map { "#" + pairingTag($0) }
        return place + c.percentEncodedPath + (query.isEmpty ? "" : "?" + query) + (pairing ?? "")
    }

    /// A short, steady stand-in for a pairing key (the key itself isn't kept in what the cache keeps pictures by).
    private static func pairingTag(_ k: String) -> String {
        SHA256.hash(data: Data(k.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    /// The size a picture asked for at [maxPixel] is made at.
    static func size(for maxPixel: Int) -> Int {
        sizes.first { $0 >= maxPixel } ?? sizes[sizes.count - 1]
    }

    private static func fileName(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// A TV on the home network answers within a few seconds or not at all (it's off): it isn't waited for as long
    /// as one away from home, or a picture from the internet.
    private static func timeout(for url: URL) -> TimeInterval {
        isHomeAddress(url.host) ? 8 : 20
    }

    /// An address on the home network (private IPv4, link-local, or .local), as the TVs are told apart from an
    /// away-from-home link.
    static func isHomeAddress(_ host: String?) -> Bool {
        guard let host, !host.isEmpty else { return false }
        if host.hasSuffix(".local") { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        let p = parts.compactMap { Int($0) }
        guard parts.count == 4, p.count == 4, p.allSatisfy({ (0...255).contains($0) }) else { return false }
        return p[0] == 10 || (p[0] == 192 && p[1] == 168) || (p[0] == 172 && (16...31).contains(p[1])) || (p[0] == 169 && p[1] == 254)
    }

    /// Bytes that are a picture (an error page answered as a success isn't kept).
    private static func isPicture(_ data: Data) -> Bool {
        guard !data.isEmpty, let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return CGImageSourceGetType(source) != nil && CGImageSourceGetCount(source) > 0
    }

    /// Decoded no bigger than [size] pixels on its longer side, which keeps memory low.
    private static func decode(_ data: Data, size: Int) -> PlatformImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: size,
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

/// The store's decoded pictures. `NSCache` may be used from any thread; this says so, so a view can draw a picture
/// that's already in memory in its very first frame.
final class ImageMemory: @unchecked Sendable {
    private let cache: NSCache<NSString, PlatformImage> = {
        let c = NSCache<NSString, PlatformImage>()
        c.countLimit = 400
        c.totalCostLimit = 160 * 1024 * 1024
        return c
    }()

    func object(_ name: String) -> PlatformImage? { cache.object(forKey: name as NSString) }
    func set(_ image: PlatformImage, _ name: String, cost: Int) { cache.setObject(image, forKey: name as NSString, cost: cost) }
}

/// What a `CachedImage` asks for: a new address or size is a new picture.
private struct ImageRequest: Hashable {
    var url: URL?
    var maxPixel: Int
}

/// The picture a `CachedImage` got for [url] (nil when there was none to be had).
private struct LoadedImage {
    var url: URL
    var image: PlatformImage?
}

/// A network picture through ``ImageStore``: drawn at once when it's already been seen, otherwise fading in when it
/// arrives. [placeholder] shows meanwhile, [failure] when there's no picture to be had. [maxPixel] is the most pixels it
/// needs on its longer side (a poster tile 512, a backdrop 1800); [storeOnDisk] false keeps it in memory only.
struct CachedImage<Placeholder: View, Failure: View>: View {
    var url: URL?
    var contentMode: ContentMode = .fill
    var maxPixel: Int = 1800
    var storeOnDisk: Bool = true
    @ViewBuilder var placeholder: () -> Placeholder
    @ViewBuilder var failure: () -> Failure
    @State private var loaded: LoadedImage?

    var body: some View {
        // Only ever the picture of the address asked for now: another one's stays behind when the address changes.
        let mine = loaded?.url == url ? loaded : nil
        let shown = mine?.image ?? url.flatMap { ImageStore.shared.cached($0, maxPixel: maxPixel) }
        Group {
            if let shown {
                Image(platformImage: shown).resizable().aspectRatio(contentMode: contentMode)
            } else if url == nil || mine != nil {
                failure()
            } else {
                placeholder()
            }
        }
        .task(id: ImageRequest(url: url, maxPixel: maxPixel)) {
            guard let url else { if loaded != nil { loaded = nil }; return }
            if let hit = ImageStore.shared.cached(url, maxPixel: maxPixel) {
                if loaded?.url != url || loaded?.image !== hit { loaded = LoadedImage(url: url, image: hit) }
                return
            }
            let img = await ImageStore.shared.image(url, maxPixel: maxPixel, storeOnDisk: storeOnDisk)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { loaded = LoadedImage(url: url, image: img) }
        }
    }
}

extension CachedImage where Failure == Placeholder {
    init(url: URL?, contentMode: ContentMode = .fill, maxPixel: Int = 1800, storeOnDisk: Bool = true,
         @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.init(url: url, contentMode: contentMode, maxPixel: maxPixel, storeOnDisk: storeOnDisk, placeholder: placeholder, failure: placeholder)
    }
}
