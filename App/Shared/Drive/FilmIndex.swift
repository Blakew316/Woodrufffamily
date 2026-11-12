import AVFoundation
import WoodruffKit

/// A Drive film's index for the app's own player (`FilmPlayer`): from the file kept on this device when there is
/// one, else read by Apple's reader through the film's stream and kept (`FilmIndexFile`).
enum FilmIndex {
    struct Opened {
        let asset: AVAsset
        /// The kept file the index is read from; nil when it couldn't be kept, and is read through the stream.
        let file: URL?
        /// It was read from Google just now (there was none on the device).
        let fresh: Bool
    }

    private static let folder: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
        .appendingPathComponent("FilmIndex", isDirectory: true)

    /// Where Drive file [id]'s index is kept.
    private static func file(_ id: String) -> URL? {
        let safe = id.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        guard !safe.isEmpty else { return nil }
        return folder?.appendingPathComponent("\(safe).mp4")
    }

    /// The index of Drive file [id], whose stream is [stream]. [fresh]: read from Google again whatever is kept.
    static func open(_ stream: DriveStream, id: String, fresh: Bool = false) async throws -> Opened {
        let url = file(id)
        if let url, !fresh, FileManager.default.fileExists(atPath: url.path) {
            // (An index kept before the app had a decoder for DTS: its hidden DTS sound is named now, as below.)
            if FilmSoundDecoders.make != nil { FilmHiddenSound.name(inIndexAt: url) }
            if let asset = try? await FilmIndexFile.open(url) {
                FilmIndexFile.used(url)
                return Opened(asset: asset, file: url, fresh: false)
            }
        }
        if let url { try? FileManager.default.removeItem(at: url) }
        // Apple's reader reads it through the stream, which then holds every part of the file the index is in.
        let remote = stream.asset()
        let marks = try await FilmIndexFile.marks(of: remote)
        guard !marks.isEmpty else { throw FilmPlayer.Failure.noIndex }
        guard let url else { return Opened(asset: remote, file: nil, fresh: true) }
        let held = await stream.heldNow()
        do {
            try FilmIndexFile.write(total: held.total, parts: held.parts, to: url)
            // DTS sound as FFmpeg and HandBrake write it, which Apple's reader leaves out of the film's tracks
            // altogether: named in the kept index, so that it's a track there. Only where the app has a decoder to
            // play it with (the Apple TV: `TVFilmSound`); elsewhere nothing changes.
            let named = FilmSoundDecoders.make != nil ? FilmHiddenSound.name(inIndexAt: url) : []
            let asset = try await FilmIndexFile.open(url, matching: marks, besides: named)
            // Apple's reader has done what it was for.
            stream.indexRead()
            if let folder { FilmIndexFile.prune(folder) }
            return Opened(asset: asset, file: url, fresh: true)
        } catch {
            // It couldn't be kept (the storage full, a part missing): read through the stream, as Apple's player does.
            try? FileManager.default.removeItem(at: url)
            return Opened(asset: remote, file: nil, fresh: true)
        }
    }

    /// False when the film Google sends now isn't the one the kept index was read from: its size is another.
    /// (True until Google has said the size.)
    static func stillRight(_ opened: Opened, _ stream: DriveStream) -> Bool {
        guard let url = opened.file, let size = stream.sizeNow(), let kept = FilmIndexFile.length(url) else { return true }
        return size == kept
    }

    /// Drive file [id]'s kept index is let go (the film has changed, or wouldn't play from it).
    static func forget(_ id: String) {
        if let url = file(id) { try? FileManager.default.removeItem(at: url) }
    }
}
