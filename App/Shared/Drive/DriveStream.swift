import Foundation
import AVFoundation
import UniformTypeIdentifiers

/// Plays a Drive video in Apple's player straight from Google: the player asks for the parts it needs (where it
/// starts, wherever it's moved to) and each part is fetched with a current Google token, so a film longer than the
/// token's hour keeps playing.
final class DriveStream: NSObject {
    let fileID: String
    private let queue: DispatchQueue
    private let loader: Loader
    private let session: URLSession

    init(fileID: String) {
        self.fileID = fileID
        let queue = DispatchQueue(label: "woodruff.drive-stream")
        let loader = Loader(fileID: fileID, queue: queue)
        self.queue = queue
        self.loader = loader
        // One session for the whole film, its answers on the player's own queue (so everything here is one at a time).
        let q = OperationQueue()
        q.underlyingQueue = queue
        q.maxConcurrentOperationCount = 1
        session = URLSession(configuration: .default, delegate: loader, delegateQueue: q)
        super.init()
        loader.session = session
    }

    deinit { session.invalidateAndCancel() }

    /// An asset for the player (this object must be kept while it plays).
    func asset() -> AVURLAsset {
        // A scheme of its own, so the player asks this object instead of fetching it itself.
        let asset = AVURLAsset(url: URL(string: "gdrive-stream://file/\(fileID).mp4")!)
        asset.resourceLoader.setDelegate(loader, queue: queue)
        return asset
    }
}

/// Fetches each part the player asks for and hands the bytes over as they arrive. Everything here runs on the
/// stream's queue.
private final class Loader: NSObject, AVAssetResourceLoaderDelegate, URLSessionDataDelegate {
    let fileID: String
    let queue: DispatchQueue
    weak var session: URLSession?

    /// A part being fetched, by its data task.
    private final class Load {
        let request: AVAssetResourceLoadingRequest
        let retried: Bool
        let task: URLSessionDataTask
        init(request: AVAssetResourceLoadingRequest, retried: Bool, task: URLSessionDataTask) {
            self.request = request; self.retried = retried; self.task = task
        }
    }
    private var loads: [Int: Load] = [:]

    init(fileID: String, queue: DispatchQueue) {
        self.fileID = fileID
        self.queue = queue
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        fetch(loadingRequest, retried: false)
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        for (id, load) in loads where load.request === loadingRequest {
            load.task.cancel()
            loads[id] = nil
        }
    }

    /// A current token (a fresh one after Google refused the last), then the part asked for.
    private func fetch(_ req: AVAssetResourceLoadingRequest, retried: Bool) {
        Task {
            do {
                if retried { await GoogleDrive.dropToken() }
                let token = try await GoogleDrive.token()
                self.queue.async { self.send(req, token: token, retried: retried) }
            } catch {
                self.queue.async {
                    if !req.isCancelled && !req.isFinished { req.finishLoading(with: error) }
                }
            }
        }
    }

    private func send(_ req: AVAssetResourceLoadingRequest, token: String, retried: Bool) {
        guard !req.isCancelled, !req.isFinished, let session else { return }
        var start: Int64 = 0
        var end: Int64?
        if let d = req.dataRequest {
            start = d.currentOffset != 0 ? d.currentOffset : d.requestedOffset
            if !d.requestsAllDataToEndOfResource { end = d.requestedOffset + Int64(d.requestedLength) - 1 }
        } else {
            // Only what the file is: its first two bytes are enough.
            end = 1
        }
        var r = URLRequest(url: GoogleDrive.mediaURL(fileID))
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("bytes=\(start)-\(end.map(String.init) ?? "")", forHTTPHeaderField: "Range")
        r.timeoutInterval = 30
        let t = session.dataTask(with: r)
        loads[t.taskIdentifier] = Load(request: req, retried: retried, task: t)
        t.resume()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let load = loads[dataTask.taskIdentifier] else { completionHandler(.cancel); return }
        let http = response as? HTTPURLResponse
        let code = http?.statusCode ?? 0
        guard code == 200 || code == 206 else {
            loads[dataTask.taskIdentifier] = nil
            completionHandler(.cancel)
            if code == 401 && !load.retried {
                fetch(load.request, retried: true)
            } else if !load.request.isCancelled && !load.request.isFinished {
                load.request.finishLoading(with: GoogleDrive.Failure(code == 401 ? "Google Drive refused the sign-in. Sign in again in Settings."
                                                                                  : "Google Drive answered \(code)."))
            }
            return
        }
        if let info = load.request.contentInformationRequest {
            // "bytes a-b/total": the whole file's size, for the player.
            var total: Int64 = 0
            if let range = http?.value(forHTTPHeaderField: "Content-Range"), let t = range.split(separator: "/").last.flatMap({ Int64($0) }) {
                total = t
            } else if code == 200 {
                total = max(0, response.expectedContentLength)
            }
            let mime = response.mimeType.flatMap { $0.hasPrefix("application/octet-stream") ? nil : $0 }
            info.contentType = UTType(mimeType: mime ?? "video/mp4")?.identifier ?? UTType.mpeg4Movie.identifier
            info.contentLength = total
            info.isByteRangeAccessSupported = true
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let load = loads[dataTask.taskIdentifier] else { return }
        if load.request.isCancelled {
            loads[dataTask.taskIdentifier] = nil
            dataTask.cancel()
            return
        }
        load.request.dataRequest?.respond(with: data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let load = loads.removeValue(forKey: task.taskIdentifier) else { return }
        let req = load.request
        guard !req.isCancelled, !req.isFinished else { return }
        if let error { req.finishLoading(with: error) } else { req.finishLoading() }
    }
}
