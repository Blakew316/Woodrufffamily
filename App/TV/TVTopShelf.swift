import SwiftUI
import Photos
import TVServices
import UIKit

/// The Top Shelf slideshow: an iCloud Photos album picked here, its pictures kept ready (4K) in the folder
/// the Top Shelf reads, and refreshed when the app opens.
@Observable @MainActor
final class TopShelfAlbum {
    static let shared = TopShelfAlbum()
    static let group = "group.com.blakew316.woodruff.tv"
    private let saved = UserDefaults(suiteName: TopShelfAlbum.group) ?? .standard

    var albums: [(id: String, name: String)] = []
    var picked: String? { saved.string(forKey: "topShelf.album") }
    var note: String?
    /// Goes up each time the pictures are written again (Home's background follows).
    var version = 0

    /// The pictures kept for the Top Shelf (and Home's background).
    nonisolated static func files() -> [URL] {
        guard let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?
            .appendingPathComponent("TopShelf", isDirectory: true) else { return [] }
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
        saved.set(id, forKey: "topShelf.album")
        Task { await refresh() }
    }

    /// The album's newest pictures (up to 15) written for the Top Shelf, and the Top Shelf told.
    func refresh() async {
        guard let id = picked,
              let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject,
              let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.group)?
                .appendingPathComponent("TopShelf", isDirectory: true) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        opts.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        let assets = PHAsset.fetchAssets(in: album, options: opts)
        var chosen: [PHAsset] = []
        assets.enumerateObjects { a, i, stop in chosen.append(a); if i >= 14 { stop.pointee = true } }
        for f in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] { try? FileManager.default.removeItem(at: f) }
        let req = PHImageRequestOptions()
        req.deliveryMode = .highQualityFormat
        req.isNetworkAccessAllowed = true
        req.isSynchronous = false
        var saved = 0
        for (i, a) in chosen.enumerated() {
            let img: UIImage? = await withCheckedContinuation { c in
                var done = false
                PHImageManager.default().requestImage(for: a, targetSize: CGSize(width: 3840, height: 2160), contentMode: .aspectFill, options: req) { im, info in
                    if done { return }
                    if (info?[PHImageResultIsDegradedKey] as? Bool) == true { return }
                    done = true
                    c.resume(returning: im)
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
                picture = data.flatMap { UIImage(data: $0)?.preparingThumbnail(of: CGSize(width: 3840, height: 2160)) }
            }
            if let data = picture?.jpegData(compressionQuality: 0.8),
               (try? data.write(to: dir.appendingPathComponent(String(format: "%02d.jpg", i)), options: .atomic)) != nil {
                saved += 1
            }
        }
        TVTopShelfContentProvider.topShelfContentDidChange()
        version += 1
        note = chosen.isEmpty ? "That album has no photos." : saved == 0 ? "Couldn’t get the photos from iCloud. Try another album." : "\(saved) photos are on the Top Shelf and Home."
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
        }
        .task { await shelf.load() }
    }
}

/// Home's background: the Top Shelf album's photos, one fading into the next with a slow drift, as the Apple TV
/// screensaver does, dimmed (most at the top) so the greeting, weather and thermostat stay easy to read. Landscape
/// photographs until an album is picked.
struct TVPhotoBackdrop: View {
    private let shelf = TopShelfAlbum.shared
    @State private var image: UIImage?
    @State private var shown = 0

    var body: some View {
        ZStack {
            HomeBackdrop()
            if let image {
                KenBurns(image: image)
                    .id(shown)
                    .transition(.opacity)
                LinearGradient(stops: [.init(color: .black.opacity(0.72), location: 0),
                                       .init(color: .black.opacity(0.45), location: 0.45),
                                       .init(color: .black.opacity(0.6), location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }
        }
        .ignoresSafeArea()
        .task(id: shelf.version) { await run() }
    }

    private func run() async {
        let files = TopShelfAlbum.files()
        // The album's photos, else a set of landscape photographs (4K) until an album is picked.
        let count = files.isEmpty ? 30 : files.count
        var i = Int.random(in: 0..<count)
        while !Task.isCancelled {
            let next: UIImage?
            if files.isEmpty {
                next = await Self.stock(i % count)
            } else {
                let url = files[i % count]
                next = await Task.detached(priority: .utility) { UIImage(contentsOfFile: url.path)?.preparingForDisplay() }.value
            }
            if let next {
                withAnimation(.easeInOut(duration: 2.5)) { image = next; shown += 1 }
            }
            try? await Task.sleep(nanoseconds: 14_000_000_000)
            i += 1
        }
    }
}

extension TVPhotoBackdrop {
    /// One of the stock photographs, kept on disk after the first time.
    static func stock(_ n: Int) async -> UIImage? {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Backdrops", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(n).jpg")
        if let d = try? Data(contentsOf: file), let img = UIImage(data: d) { return img.preparingForDisplay() }
        guard let url = URL(string: "https://picsum.photos/seed/woodruff\(n)/3840/2160"),
              let (d, r) = try? await URLSession.shared.data(from: url),
              (r as? HTTPURLResponse)?.statusCode == 200, let img = UIImage(data: d) else { return nil }
        try? d.write(to: file, options: .atomic)
        return img.preparingForDisplay()
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
            .scaleEffect(grow ? 1.08 : 1)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .onAppear { withAnimation(.linear(duration: 18)) { grow = true } }
    }
}
