import SwiftUI
import Photos
import TVServices
import UIKit

/// The Top Shelf slideshow: an iCloud Photos album picked here, its pictures kept ready (1920 × 1080) in the folder
/// the Top Shelf reads, and refreshed when the app opens.
@Observable @MainActor
final class TopShelfAlbum {
    static let shared = TopShelfAlbum()
    static let group = "group.com.blakew316.woodruff.tv"
    private let saved = UserDefaults(suiteName: TopShelfAlbum.group) ?? .standard

    var albums: [(id: String, name: String)] = []
    var picked: String? { saved.string(forKey: "topShelf.album") }
    var note: String?

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
        for (i, a) in chosen.enumerated() {
            let img: UIImage? = await withCheckedContinuation { c in
                var done = false
                PHImageManager.default().requestImage(for: a, targetSize: CGSize(width: 1920, height: 1080), contentMode: .aspectFill, options: req) { im, info in
                    if done { return }
                    if (info?[PHImageResultIsDegradedKey] as? Bool) == true { return }
                    done = true
                    c.resume(returning: im)
                }
            }
            if let data = img?.jpegData(compressionQuality: 0.85) {
                try? data.write(to: dir.appendingPathComponent(String(format: "%02d.jpg", i)), options: .atomic)
            }
        }
        TVTopShelfContentProvider.topShelfContentDidChange()
        note = chosen.isEmpty ? "That album has no photos." : "\(chosen.count) photos are on the Top Shelf."
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
