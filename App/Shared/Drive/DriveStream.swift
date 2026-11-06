import Foundation
import AVFoundation
import UniformTypeIdentifiers

/// Plays a Drive video in Apple's player straight from Google: the player asks for the parts it needs (where it
/// starts, wherever it's moved to) and each part is fetched with a current Google token, so a film longer than the
/// token's hour keeps playing.
final class DriveStream: NSObject, AVAssetResourceLoaderDelegate {
    let fileID: String
    private let queue = DispatchQueue(label: "woodruff.drive-stream")
    private var total: Int64?
    private var type: String?

    init(fileID: String) { self.fileID = fileID }

    /// An asset for the player (this object must be kept while it plays).
    func asset() -> AVURLAsset {
        // A scheme of its own, so the player asks this object instead of fetching it itself.
        let asset = AVURLAsset(url: URL(string: "gdrive-stream://file/\(fileID).mp4")!)
        asset.resourceLoader.setDelegate(self, queue: queue)
        return asset
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        Task { await self.load(loadingRequest) }
        return true
    }

    private func load(_ req: AVAssetResourceLoadingRequest) async {
        let data = req.dataRequest
        let start = data.map { $0.currentOffset != 0 ? $0.currentOffset : $0.requestedOffset } ?? 0
        var end: Int64?
        if let d = data, !d.requestsAllDataToEndOfResource { end = d.requestedOffset + Int64(d.requestedLength) - 1 }
        do {
            for attempt in 0..<2 {
                let token = try await GoogleDrive.token()
                var r = URLRequest(url: GoogleDrive.mediaURL(fileID))
                r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                r.setValue("bytes=\(start)-\(end.map(String.init) ?? "")", forHTTPHeaderField: "Range")
                r.timeoutInterval = 30
                let (bytes, resp) = try await URLSession.shared.bytes(for: r)
                let http = resp as? HTTPURLResponse
                let code = http?.statusCode ?? 0
                if code == 401 && attempt == 0 { await GoogleDrive.dropToken(); continue }
                guard code == 200 || code == 206 else { throw GoogleDrive.Failure("Google Drive answered \(code).") }
                // "bytes a-b/total": the whole file's size, for the player.
                if let range = http?.value(forHTTPHeaderField: "Content-Range"), let t = range.split(separator: "/").last.flatMap({ Int64($0) }) {
                    total = t
                } else if code == 200 {
                    total = http?.expectedContentLength
                }
                if let mime = http?.mimeType, !mime.hasPrefix("application/octet-stream") { type = mime }
                if let info = req.contentInformationRequest {
                    info.contentType = UTType(mimeType: type ?? "video/mp4")?.identifier ?? UTType.mpeg4Movie.identifier
                    info.contentLength = total ?? 0
                    info.isByteRangeAccessSupported = true
                }
                guard let d = data else { req.finishLoading(); return }
                var chunk = Data()
                chunk.reserveCapacity(256 * 1024)
                for try await b in bytes {
                    chunk.append(b)
                    if chunk.count >= 256 * 1024 {
                        if req.isCancelled { return }
                        d.respond(with: chunk)
                        chunk.removeAll(keepingCapacity: true)
                    }
                }
                if !chunk.isEmpty, !req.isCancelled { d.respond(with: chunk) }
                if !req.isCancelled { req.finishLoading() }
                return
            }
            throw GoogleDrive.Failure("Google Drive refused the sign-in. Sign in again in Settings.")
        } catch {
            if !req.isCancelled { req.finishLoading(with: error) }
        }
    }
}
