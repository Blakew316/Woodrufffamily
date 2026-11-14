import SwiftUI
import Photos
import TVServices
import UIKit
import ImageIO
import CoreImage
import CoreImage.CIFilterBuiltins

/// The Top Shelf slideshow: an iCloud Photos album picked here, its pictures kept ready (1920 × 1080, the Top Shelf's own size, and on a 4K
/// screen 3840 × 2160 beside each, "…@2x.jpg") in the folder the Top Shelf reads, and refreshed when the app opens.
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

    /// The pictures kept for the Top Shelf (each once: not its 4K copy beside it).
    nonisolated static func files() -> [URL] {
        guard let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?
            .appendingPathComponent("Library/Caches/TopShelf", isDirectory: true) else { return [] }
        return ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "jpg" && !$0.lastPathComponent.hasSuffix("@2x.jpg") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// The screen draws two pixels to the point (4K): the Top Shelf shows a 3840 × 2160 picture there, and the
    /// 1920 × 1080 one on an HD screen (or an Apple TV HD), where a 4K copy would only be work and space.
    private static var screenIs4K: Bool {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        return (scene?.screen.scale ?? 2) > 1
    }

    /// The albums on this Apple TV's iCloud Photos (asking once for permission).
    func load() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else { note = "Allow Photos for Woodruff in Settings → Apps → Woodruff."; return }
        // Listed off the main thread: counting every album's photos (Recents has thousands) held the remote up.
        albums = await Task.detached(priority: .userInitiated) { Self.listAlbums() }.value
    }

    /// Every album with a photo in it, by id and name.
    nonisolated private static func listAlbums() -> [(id: String, name: String)] {
        var list: [(id: String, name: String)] = []
        for type in [PHAssetCollectionType.album, .smartAlbum] {
            let r = PHAssetCollection.fetchAssetCollections(with: type, subtype: .any, options: nil)
            r.enumerateObjects { c, _, _ in
                guard PHAsset.fetchAssets(in: c, options: nil).count > 0 else { return }
                list.append((id: c.localIdentifier, name: c.localizedTitle ?? "Album"))
            }
        }
        return list
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

    /// A photo's original, sized down off the main thread without decoding it whole (a 48-megapixel one is hundreds of MB):
    /// decoded by ImageIO straight at the size it's drawn, fitted whole on [screen] (a portrait photo at the 2160 pixels
    /// it's drawn tall, not 3840).
    nonisolated private static func downsample(_ data: Data, fitting screen: CGSize) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        var maxPixel = Int(max(screen.width, screen.height))
        if let p = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           var w = (p[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
           var h = (p[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue, w > 0, h > 0 {
            // On its side in the file (EXIF orientations 5 to 8): its width and height swap once it's the right way up.
            if let o = (p[kCGImagePropertyOrientation] as? NSNumber)?.intValue, o >= 5 { swap(&w, &h) }
            let fit = min(1, Double(screen.width) / w, Double(screen.height) / h)
            maxPixel = max(1, Int((max(w, h) * fit).rounded(.up)))
        }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceShouldCacheImmediately: true,
                                        kCGImageSourceThumbnailMaxPixelSize: maxPixel]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// The whole photo on the Top Shelf's 1920 × 1080 (or, for a 4K screen, 3840 × 2160), fitted rather than cropped
    /// (filled to the Top Shelf, a portrait photo showed less than half of itself and a landscape one lost a quarter),
    /// over a soft, darkened copy of itself filling the rest of the screen.
    nonisolated private static func shelfPicture(_ photo: UIImage, screen: CGSize = CGSize(width: 1920, height: 1080)) -> UIImage? {
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
              let made = blurContext.createCGImage(out, from: input.extent) else { return nil }
        return UIImage(cgImage: made)
    }

    /// Made once: a Core Image context is costly to set up, and one was made for each of the 15 photos every refresh.
    nonisolated(unsafe) private static let blurContext = CIContext(options: [.cacheIntermediates: false])

    private func write() async {
        guard let id = picked,
              let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.group)?
                .appendingPathComponent("Library/Caches/TopShelf", isDirectory: true) else { return }
        // The album read and its photos picked off the main thread: Photos can take seconds to answer (a big album,
        // or iCloud Photos catching up as the Apple TV wakes), and this runs as the app opens and each time it comes
        // back, with Home on screen (the remote stalled meanwhile).
        guard let chosen = await Task.detached(priority: .utility, operation: { Self.choose(fromAlbum: id) }).value?.assets else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let old = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        // In milliseconds: two refreshes in the same second (an album picked while one runs) gave the same names, so
        // the second wrote over the first's photos and then deleted them as old, leaving the Top Shelf without them.
        let stamp = String(Int(Date().timeIntervalSince1970 * 1000))
        let req = PHImageRequestOptions()
        req.deliveryMode = .opportunistic
        req.resizeMode = .exact
        req.isNetworkAccessAllowed = true
        req.isSynchronous = false
        // A 4K screen: each photo is asked for at 3840 × 2160 and kept at both sizes. The Top Shelf was given the
        // 1920 × 1080 picture for 4K too, where it was drawn at half the screen's sharpness.
        let big = Self.screenIs4K
        let asked = big ? CGSize(width: 3840, height: 2160) : CGSize(width: 1920, height: 1080)
        // The photos made last time, by what each was made from (`madeKey`): one picked again and unchanged since keeps
        // its pictures (every photo was downloaded, decoded and drawn at both sizes each time the app came back).
        let before = self.saved.dictionary(forKey: "topShelf.made") as? [String: String] ?? [:]
        var made: [String: String] = [:]
        var saved = 0
        var lastError: String?
        for (i, a) in chosen.enumerated() {
            // Not while a film is on screen: iCloud's photos came down the same connection as its first minutes (the
            // rest follow once it closes; the Top Shelf can't be seen meanwhile anyway).
            while NativePlayer.shared.isOpen && !Task.isCancelled { try? await Task.sleep(nanoseconds: 2_000_000_000) }
            // Apple TV only lets apps write in Caches (the shared folder's too), which is where the Top Shelf reads.
            // A new name each time (the Apple TV keeps pictures by their address: the same name would keep showing
            // the old photo). Its 3840 × 2160 copy for a 4K screen has the same name with "@2x", which is how the Top
            // Shelf pairs them.
            let name = String(format: "%@-%02d", stamp, i)
            let file = dir.appendingPathComponent(name + ".jpg")
            let large = dir.appendingPathComponent(name + "@2x.jpg")
            let key = Self.madeKey(a, big: big)
            // Made last time and unchanged since: its pictures renamed for this refresh (in its order), not made again.
            if let was = before[key], Self.rename(was, to: name, big: big, in: dir) {
                made[key] = name
                saved += 1
                continue
            }
            // The photo's own file, decoded by ImageIO straight at the size it's drawn: never whole first (asked of
            // Photos at a size, it could hand back the whole original decoded, only to be drawn smaller).
            let data: Data? = await withCheckedContinuation { c in
                let o = PHImageRequestOptions()
                o.isNetworkAccessAllowed = true
                o.deliveryMode = .highQualityFormat
                PHImageManager.default().requestImageDataAndOrientation(for: a, options: o) { d, _, _, _ in c.resume(returning: d) }
            }
            var picture: UIImage?
            if let data { picture = await Task.detached(priority: .utility) { Self.downsample(data, fitting: asked) }.value }
            // Made from the photo itself (not the quick copy, which is tried again next time).
            var whole = picture != nil
            if picture == nil {
                let got: (full: UIImage?, rough: UIImage?) = await withCheckedContinuation { c in
                    var done = false
                    var rough: UIImage?
                    // Fitted whole, so asked for at the size it's drawn, and no larger (asked to fill 1920 × 1080, a
                    // portrait photo came back with more than twice the pixels it's shown with, all of it downloaded
                    // and decoded).
                    PHImageManager.default().requestImage(for: a, targetSize: asked, contentMode: .aspectFit, options: req) { im, info in
                        if done { return }
                        // The quick, smaller copy first: kept in case nothing better comes.
                        if (info?[PHImageResultIsDegradedKey] as? Bool) == true { rough = im; return }
                        done = true
                        if im == nil, let e = info?[PHImageErrorKey] as? Error { lastError = e.localizedDescription }
                        c.resume(returning: (full: im, rough: rough))
                    }
                }
                // Only when neither came: the quick copy (a few hundred pixels across, soft on the TV, but better than a
                // gap).
                picture = got.full ?? got.rough
                whole = got.full != nil
            }
            // Fitted to the Top Shelf and made into a JPEG off the main thread, so the remote stays smooth meanwhile.
            var written: Result<Void, Error>?
            if let image = picture {
                written = await Task.detached(priority: .utility) { () -> Result<Void, Error>? in
                    // One size at a time, each let go before the next is drawn (both were held at once, with the photo).
                    // The 4K copy first, so it's there whenever the photo is (the Top Shelf can ask at any moment). If
                    // it can't be made or kept, the Top Shelf shows the photo itself on a 4K screen, as it did.
                    if big {
                        autoreleasepool {
                            if let sharp = Self.shelfPicture(image, screen: CGSize(width: 3840, height: 2160))?.jpegData(compressionQuality: 0.8) {
                                try? sharp.write(to: large, options: .atomic)
                            }
                        }
                    }
                    return autoreleasepool { () -> Result<Void, Error>? in
                        guard let data = (Self.shelfPicture(image) ?? image).jpegData(compressionQuality: 0.8) else { return nil }
                        do { try data.write(to: file, options: .atomic); return .success(()) } catch { return .failure(error) }
                    }
                }.value
            }
            switch written {
            case .success?:
                saved += 1
                if whole { made[key] = name }
            case .failure(let e)?: lastError = e.localizedDescription
            case nil: if lastError == nil { lastError = "iCloud sent no picture" }
            }
        }
        if saved > 0 {
            for f in old { try? FileManager.default.removeItem(at: f) }
            self.saved.set(made, forKey: "topShelf.made")
        }
        TVTopShelfContentProvider.topShelfContentDidChange()
        ready = Self.files().count
        version += 1
        note = chosen.isEmpty ? "That album has no photos." : saved == 0 ? "Couldn’t get the photos from iCloud" + (lastError.map { ": \($0)" } ?? ".") + " Check that iCloud Photos is on in this Apple TV’s Settings → Users and Accounts." : "\(saved) photos are on the Top Shelf."
    }

    /// What a photo's pictures were made from: the photo as it is now (an edit changes its date), at this screen's sizes.
    nonisolated private static func madeKey(_ a: PHAsset, big: Bool) -> String {
        "\(a.localIdentifier) \(a.modificationDate?.timeIntervalSince1970 ?? 0) \(big ? "4K" : "HD")"
    }

    /// A photo's pictures from the last refresh ([from]) renamed [to]; false when they aren't all there (one kept without
    /// its 4K copy is made again).
    nonisolated private static func rename(_ from: String, to name: String, big: Bool, in dir: URL) -> Bool {
        let fm = FileManager.default
        let moves = (big ? ["@2x.jpg"] : []) + [".jpg"]
        guard moves.allSatisfy({ fm.fileExists(atPath: dir.appendingPathComponent(from + $0).path) }) else { return false }
        // The 4K copy first, so it's there whenever the photo is.
        for end in moves {
            do { try fm.moveItem(at: dir.appendingPathComponent(from + end), to: dir.appendingPathComponent(name + end)) } catch { return false }
        }
        return true
    }

    /// 15 of [id]'s photos, a different mix each time (the newest few always among them); nil when there's no such album.
    nonisolated private static func choose(fromAlbum id: String) -> TopShelfChoice? {
        guard let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject else { return nil }
        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        opts.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        let assets = PHAsset.fetchAssets(in: album, options: opts)
        // Only the 15 picked are read (every photo of a big iCloud album was listed before).
        let count = assets.count, newest = min(5, count)
        let picks = Array(0..<newest) + Array((newest..<count).shuffled().prefix(10))
        return TopShelfChoice(assets: picks.map { assets.object(at: $0) })
    }
}

/// The photos picked for the Top Shelf, handed back from the thread that read the album (Photos' assets are read-only,
/// so they can be used from any thread).
private struct TopShelfChoice: @unchecked Sendable {
    let assets: [PHAsset]
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
/// screensaver does, shown as they are (nothing dims them: the greeting and weather have their own shadows, the
/// thermostat its glass). The Top Shelf album stays on the Top Shelf.
struct TVPhotoBackdrop: View {
    private let show = HomeSlideshow.shared

    var body: some View {
        ZStack {
            if let image = show.image {
                // The new photo fades in over the old one, which stays whole underneath until it's covered: no dip
                // to the background between them.
                KenBurns(image: image, shown: show.shown)
            } else {
                // Until the first photo is there. Once it is, it covers this whole, so its drift isn't drawn (twice a
                // second, all the time Home was open) where nobody can see it.
                HomeBackdrop()
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

    /// Home is the page on screen, with nothing over it (a film, a camera, the screen saver).
    private static var homeInView: Bool {
        UIApplication.shared.applicationState == .active
            && (UserDefaults.standard.string(forKey: "tv.tab") ?? "home") == "home"
            && !NativePlayer.shared.isOpen && CameraStreams.shared.expanded == nil
    }

    private func run() async {
        while !Task.isCancelled {
            if image != nil { try? await Task.sleep(nanoseconds: 30_000_000_000) }
            if Task.isCancelled { return }
            // Home out of sight: the next photo waits until it's back, instead of a 4K photo being decoded and faded in
            // every 30 seconds where nobody sees it (all through a film, say).
            if image != nil && !Self.homeInView { continue }
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
            // The first is simply there (nothing to fade from); each one after fades in over six seconds, which the
            // backdrop does itself (`KenBurns`).
            image = next.image
            shown += 1
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

/// The photos filling the screen: each new one ([shown] goes up) fades in over six seconds over the one before, which
/// stays whole beneath it until it's covered, and each drifts slowly larger while it shows (6% over 40 seconds). Core
/// Animation runs the fade and the drift by itself: as SwiftUI animations they were worked out on the main thread every
/// frame, all the time Home was open, beside its scrolling and the remote's moves.
private struct KenBurns: UIViewRepresentable {
    var image: UIImage
    var shown: Int

    func makeUIView(context: Context) -> Slides { Slides(frame: .zero) }

    func updateUIView(_ slides: Slides, context: Context) { slides.show(image, number: shown) }

    final class Slides: UIView {
        /// The photo put up last.
        private var number: Int?

        override init(frame: CGRect) {
            super.init(frame: frame)
            clipsToBounds = true
            isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) { fatalError() }

        /// Photo [n] put up, fading in over the one before. The fade and the drift are layer animations of their own, so
        /// nothing SwiftUI does as it updates the page (UIKit's own animations can be off meanwhile) cuts them short.
        func show(_ image: UIImage, number n: Int) {
            guard n != number else { return }
            // The first is simply there (nothing to fade from), and so is one put up while Home isn't in the window
            // (another tab showing, say): Core Animation can hold a fade until its layer is on screen, by when the
            // timer below would have taken away the photo under it, so it would come up out of black.
            let fades = number != nil && window != nil
            number = n
            let photo = UIImageView(image: image)
            photo.contentMode = .scaleAspectFill
            photo.bounds = bounds
            photo.center = CGPoint(x: bounds.midX, y: bounds.midY)
            addSubview(photo)
            if window != nil { drift(photo) }
            guard fades else {
                // Nothing fading in, so nothing has to stay under it.
                for old in subviews where old !== photo { old.removeFromSuperview() }
                return
            }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.0
            fade.toValue = 1.0
            fade.duration = 6
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            fade.fillMode = .backwards
            photo.layer.add(fade, forKey: "fade")
            // Once it's whole, the ones under it go.
            Task { @MainActor [weak self, weak photo] in
                try? await Task.sleep(nanoseconds: 6_200_000_000)
                guard let self, let photo, let i = self.subviews.firstIndex(of: photo) else { return }
                for old in self.subviews.prefix(i) { old.removeFromSuperview() }
            }
        }

        /// Slowly larger, from the moment it's on screen.
        private func drift(_ photo: UIView) {
            let grow = CABasicAnimation(keyPath: "transform.scale")
            grow.fromValue = 1.0
            grow.toValue = 1.06
            grow.duration = 40
            grow.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            grow.fillMode = .forwards
            // Kept when it ends, and through a trip to the background (which would otherwise take it away, and the
            // photo would jump back to its first size).
            grow.isRemovedOnCompletion = false
            photo.layer.add(grow, forKey: "drift")
        }

        /// On screen (Home opened, or back from another tab): a photo put up meanwhile starts its drift now.
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil, let top = subviews.last, top.layer.animation(forKey: "drift") == nil { drift(top) }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            for v in subviews {
                v.bounds = bounds
                v.center = CGPoint(x: bounds.midX, y: bounds.midY)
            }
        }
    }
}
