import SwiftUI
import Photos
import TVServices
import UIKit
import ImageIO
import CoreImage
import CoreImage.CIFilterBuiltins

/// The Top Shelf slideshow: an iCloud Photos album picked here, its pictures kept ready (1920 × 1080, the Top Shelf's own size) in the folder
/// the Top Shelf reads, and refreshed when the app opens.
@Observable @MainActor
final class TopShelfAlbum {
    static let shared = TopShelfAlbum()
    static let group = "group.com.blakew316.woodruff.tv"
    private let saved = UserDefaults(suiteName: TopShelfAlbum.group) ?? .standard

    var albums: [(id: String, name: String)] = []
    /// The album picked (kept in the shared settings), watched so the list's Showing moves the moment one is picked.
    private(set) var picked: String?
    var note: String?
    /// Goes up each time the pictures are written again.
    var version = 0
    /// How many pictures the Top Shelf has ready (Settings → Top Shelf), counted when they're written, not at every redraw.
    private(set) var ready = 0
    /// A refresh is under way; one asked for meanwhile runs once it's done (two at once mixed and deleted each other's pictures).
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var again = false

    private init() {
        picked = saved.string(forKey: "topShelf.album")
        ready = Self.files().count
    }

    /// When the Top Shelf last asked for its pictures (it notes the time in the shared folder), or Never.
    nonisolated static func lastAsked() -> String {
        var t = UserDefaults(suiteName: group)?.double(forKey: "topShelf.asked") ?? 0
        if t == 0, let f = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?
                .appendingPathComponent("Library/Caches/topshelf-asked.txt"),
           let s = try? String(contentsOf: f, encoding: .utf8), let v = Double(s) { t = v }
        guard t > 0 else { return "Never" }
        return Date(timeIntervalSince1970: t).formatted(date: .omitted, time: .shortened)
    }

    /// The pictures kept for the Top Shelf.
    nonisolated static func files() -> [URL] {
        guard let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?
            .appendingPathComponent("Library/Caches/TopShelf", isDirectory: true) else { return [] }
        return ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "jpg" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// The albums on this Apple TV's iCloud Photos (asking once for permission).
    func load() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else { note = "Allow Photos for Woodruff in Settings → Apps → Woodruff."; return }
        var list: [(String, String)] = []
        for type in [PHAssetCollectionType.album, .smartAlbum] {
            let r = PHAssetCollection.fetchAssetCollections(with: type, subtype: .any, options: nil)
            r.enumerateObjects { c, _, _ in
                guard PHAsset.fetchAssets(in: c, options: nil).count > 0 else { return }
                list.append((c.localIdentifier, c.localizedTitle ?? "Album"))
            }
        }
        albums = list.map { (id: $0.0, name: $0.1) }
    }

    func pick(_ id: String) {
        picked = id
        saved.set(id, forKey: "topShelf.album")
        Task { await refresh() }
    }

    /// The album's newest pictures (up to 15) written for the Top Shelf, and the Top Shelf told. One at a time.
    func refresh() async {
        if refreshing { again = true; return }
        refreshing = true
        repeat {
            again = false
            await write()
        } while again
        refreshing = false
    }

    /// A photo's original, sized down off the main thread without decoding it whole (a 48-megapixel one is hundreds of MB).
    nonisolated private static func downsample(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceShouldCacheImmediately: true,
                                        kCGImageSourceThumbnailMaxPixelSize: 1920]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// The whole photo on the Top Shelf's 1920 × 1080, fitted rather than cropped (filled to the Top Shelf, a portrait
    /// photo showed less than half of itself and a landscape one lost a quarter), over a soft, darkened copy of itself
    /// filling the rest of the screen.
    nonisolated private static func shelfPicture(_ photo: UIImage) -> UIImage? {
        let screen = CGSize(width: 1920, height: 1080)
        let w = photo.size.width, h = photo.size.height
        guard w > 0, h > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        // Behind it: a small copy (drawn the right way up), blurred, stretched over the whole screen.
        let small = CGSize(width: 192, height: max(1, (192 * h / w).rounded()))
        let thumb = UIGraphicsImageRenderer(size: small, format: format).image { _ in photo.draw(in: CGRect(origin: .zero, size: small)) }
        let soft = blurred(thumb) ?? thumb
        func centered(_ scale: CGFloat) -> CGRect {
            let size = CGSize(width: w * scale, height: h * scale)
            return CGRect(x: (screen.width - size.width) / 2, y: (screen.height - size.height) / 2, width: size.width, height: size.height)
        }
        let fill = max(screen.width / w, screen.height / h)
        let fit = min(screen.width / w, screen.height / h)
        return UIGraphicsImageRenderer(size: screen, format: format).image { ctx in
            UIColor.black.setFill()
            ctx.fill(CGRect(origin: .zero, size: screen))
            soft.draw(in: centered(fill))
            UIColor(white: 0, alpha: 0.35).setFill()
            ctx.fill(CGRect(origin: .zero, size: screen))
            photo.draw(in: centered(fit))
        }
    }

    /// A strong blur of a small picture, nil if it can't be made.
    nonisolated private static func blurred(_ image: UIImage) -> UIImage? {
        guard let cg = image.cgImage else { return nil }
        let input = CIImage(cgImage: cg)
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = input.clampedToExtent()
        blur.radius = 8
        guard let out = blur.outputImage?.cropped(to: input.extent),
              let made = CIContext().createCGImage(out, from: input.extent) else { return nil }
        return UIImage(cgImage: made)
    }

    private func write() async {
        guard let id = picked,
              let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject,
              let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.group)?
                .appendingPathComponent("Library/Caches/TopShelf", isDirectory: true) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        opts.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        let assets = PHAsset.fetchAssets(in: album, options: opts)
        // 15 of the album's photos, a different mix each time (the newest few always among them).
        var all: [PHAsset] = []
        assets.enumerateObjects { a, _, _ in all.append(a) }
        let newest = Array(all.prefix(5))
        let chosen = newest + Array(all.dropFirst(5).shuffled().prefix(10))
        let old = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let stamp = String(Int(Date().timeIntervalSince1970))
        let req = PHImageRequestOptions()
        req.deliveryMode = .opportunistic
        req.resizeMode = .fast
        req.isNetworkAccessAllowed = true
        req.isSynchronous = false
        var saved = 0
        var lastError: String?
        for (i, a) in chosen.enumerated() {
            let img: UIImage? = await withCheckedContinuation { c in
                var done = false
                var rough: UIImage?
                PHImageManager.default().requestImage(for: a, targetSize: CGSize(width: 1920, height: 1080), contentMode: .aspectFill, options: req) { im, info in
                    if done { return }
                    // The quick, smaller copy first: kept in case the full one can't come.
                    if (info?[PHImageResultIsDegradedKey] as? Bool) == true { rough = im; return }
                    done = true
                    if im == nil, let e = info?[PHImageErrorKey] as? Error { lastError = e.localizedDescription }
                    c.resume(returning: im ?? rough)
                }
            }
            var picture = img
            if picture == nil {
                // Some iCloud photos only come as their original: read that and size it down here.
                let data: Data? = await withCheckedContinuation { c in
                    let o = PHImageRequestOptions()
                    o.isNetworkAccessAllowed = true
                    o.deliveryMode = .highQualityFormat
                    PHImageManager.default().requestImageDataAndOrientation(for: a, options: o) { d, _, _, _ in c.resume(returning: d) }
                }
                if let data { picture = await Task.detached(priority: .utility) { Self.downsample(data) }.value }
            }
            // Apple TV only lets apps write in Caches (the shared folder's too), which is where the Top Shelf reads.
            // A new name each time (the Apple TV keeps pictures by their address: the same name would keep showing
            // the old photo). Fitted to the Top Shelf and made into a JPEG off the main thread, so the remote stays
            // smooth meanwhile.
            let file = dir.appendingPathComponent(String(format: "%@-%02d.jpg", stamp, i))
            var written: Result<Void, Error>?
            if let image = picture {
                written = await Task.detached(priority: .utility) { () -> Result<Void, Error>? in
                    guard let data = (Self.shelfPicture(image) ?? image).jpegData(compressionQuality: 0.8) else { return nil }
                    do { try data.write(to: file, options: .atomic); return .success(()) } catch { return .failure(error) }
                }.value
            }
            switch written {
            case .success?: saved += 1
            case .failure(let e)?: lastError = e.localizedDescription
            case nil: if lastError == nil { lastError = "iCloud sent no picture" }
            }
        }
        if saved > 0 { for f in old { try? FileManager.default.removeItem(at: f) } }
        TVTopShelfContentProvider.topShelfContentDidChange()
        ready = Self.files().count
        version += 1
        note = chosen.isEmpty ? "That album has no photos." : saved == 0 ? "Couldn’t get the photos from iCloud" + (lastError.map { ": \($0)" } ?? ".") + " Check that iCloud Photos is on in this Apple TV’s Settings → Users and Accounts." : "\(saved) photos are on the Top Shelf and Home."
    }
}

/// Settings → Top Shelf: the album the slideshow shows.
struct TopShelfSettings: View {
    private let shelf = TopShelfAlbum.shared

    var body: some View {
        List {
            Section {
                ForEach(shelf.albums, id: \.id) { a in
                    Button { shelf.pick(a.id) } label: {
                        HStack {
                            Text(a.name)
                            Spacer()
                            if shelf.picked == a.id { Text("Showing").foregroundStyle(.secondary) }
                        }
                    }
                }
            } footer: {
                Text(shelf.note ?? "With Woodruff's icon highlighted on the Home Screen, this album plays across the top as a slideshow.")
            }
            Section {
                LabeledContent("Photos Ready", value: "\(shelf.ready)")
                LabeledContent("Apple TV Last Asked", value: TopShelfAlbum.lastAsked())
                Button("Update the Top Shelf Now") { Task { await shelf.refresh() } }
                    .disabled(shelf.picked == nil)
            } footer: {
                Text("Woodruff has to be in the top row of the Home Screen for its Top Shelf to show.")
            }
        }
        .task { await shelf.load() }
    }
}

/// Home's background: nature photographs, one fading into the next with a slow drift, as the Apple TV
/// screensaver does, dimmed (most at the top) so the greeting, weather and thermostat stay easy to read. The Top
/// Shelf album stays on the Top Shelf.
struct TVPhotoBackdrop: View {
    private let show = HomeSlideshow.shared

    var body: some View {
        ZStack {
            HomeBackdrop()
            if let image = show.image {
                // The new photo fades in over the old one, which stays whole underneath until it's covered: no dip
                // to the background between them.
                KenBurns(image: image)
                    .id(show.shown)
                    .zIndex(Double(show.shown))
                    .transition(.asymmetric(insertion: .opacity,
                                            removal: .opacity.animation(.linear(duration: 0.2).delay(7))))
                LinearGradient(stops: [.init(color: .black.opacity(0.72), location: 0),
                                       .init(color: .black.opacity(0.45), location: 0.45),
                                       .init(color: .black.opacity(0.6), location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }
        }
        .ignoresSafeArea()
    }
}

/// The slideshow itself, running from launch: the first photo (one kept on disk) is decoded off the main thread the
/// moment the app starts, so it's there when Home opens without holding up the launch, and the rest are fetched behind it.
@Observable @MainActor
final class HomeSlideshow {
    static let shared = HomeSlideshow()
    private(set) var image: UIImage?
    private(set) var shown = 0
    @ObservationIgnored private var task: Task<Void, Never>?
    /// The file showing now, so the next photo is a different one.
    @ObservationIgnored private var current: String?

    private init() {}

    func start() {
        guard task == nil else { return }
        task = Task { await run() }
        // Every nature photograph on disk ahead of time, so none has to wait for the network later.
        Task.detached(priority: .background) {
            for n in 0..<TVPhotoBackdrop.nature.count { _ = await TVPhotoBackdrop.stock(n, decode: false) }
        }
    }

    private func run() async {
        while !Task.isCancelled {
            if image != nil { try? await Task.sleep(nanoseconds: 30_000_000_000) }
            if Task.isCancelled { return }
            // Nature photographs only (the album is the Top Shelf's): a kept one if there are a few (no waiting), or
            // any kept one for the first, else the next to come from the network.
            let first = image == nil
            var found: (image: UIImage, file: String)?
            let kept = TVPhotoBackdrop.keptStock().filter { $0.lastPathComponent != current }
            if let f = kept.randomElement(), first || kept.count > 2 {
                let decoded = await Task.detached(priority: first ? .userInitiated : .utility) {
                    UIImage(contentsOfFile: f.path)?.preparingForDisplay()
                }.value
                found = decoded.map { (image: $0, file: f.lastPathComponent) }
            } else {
                let n = Int.random(in: 0..<TVPhotoBackdrop.nature.count)
                found = await TVPhotoBackdrop.stock(n).map { (image: $0, file: "n\(TVPhotoBackdrop.nature[n]).jpg") }
            }
            guard let next = found else { try? await Task.sleep(nanoseconds: 5_000_000_000); continue }
            current = next.file
            if first {
                // The first is simply there (nothing to fade from).
                image = next.image
                shown += 1
            } else {
                withAnimation(.easeInOut(duration: 6)) { image = next.image; shown += 1 }
            }
        }
    }
}

extension TVPhotoBackdrop {
    /// Twelve nature photographs, each taken at well over 4K (4,200 to 5,000 pixels across) so they stay sharp at 3840 ×
    /// 2160: a sunset field, sea cliffs, snowy peaks, a mountain sunrise, a coast, misty mountains, foggy hills, a
    /// forest, a beach, desert dunes, a fjord and a sea of clouds.
    nonisolated static let nature = [110, 218, 377, 432, 381, 368, 353, 28, 421, 184, 461, 386]

    nonisolated static var stockDir: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Backdrops", isDirectory: true)
    }

    /// The nature photographs already on disk.
    nonisolated static func keptStock() -> [URL] {
        // Only the twelve (older picks kept from before are left out, and cleared away).
        let keep = Set(nature.map { "n\($0).jpg" })
        let files = (try? FileManager.default.contentsOfDirectory(at: stockDir, includingPropertiesForKeys: nil)) ?? []
        for f in files where f.pathExtension == "jpg" && !keep.contains(f.lastPathComponent) { try? FileManager.default.removeItem(at: f) }
        return files.filter { keep.contains($0.lastPathComponent) }
    }

    /// One of the stock photographs, kept on disk after the first time.
    nonisolated static func stock(_ n: Int, decode: Bool = true) async -> UIImage? {
        let dir = stockDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("n\(nature[n % nature.count]).jpg")
        if FileManager.default.fileExists(atPath: file.path) {
            return decode ? UIImage(contentsOfFile: file.path)?.preparingForDisplay() : nil
        }
        guard let url = URL(string: "https://picsum.photos/id/\(nature[n % nature.count])/3840/2160"),
              let (d, r) = try? await URLSession.shared.data(from: url),
              (r as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        try? d.write(to: file, options: .atomic)
        return decode ? UIImage(data: d)?.preparingForDisplay() : nil
    }
}

/// One photo filling the screen, drifting slowly larger while it shows.
private struct KenBurns: View {
    var image: UIImage
    @State private var grow = false

    var body: some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .scaleEffect(grow ? 1.06 : 1)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .onAppear { withAnimation(.easeInOut(duration: 40)) { grow = true } }
    }
}
