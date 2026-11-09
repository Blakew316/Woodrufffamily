import Foundation
import AVFoundation
import UniformTypeIdentifiers

/// Every Drive stream's work, one thing at a time: the player's requests, Google's answers and what's fetched ahead.
private let streamQueue = DispatchQueue(label: "woodruff.drive-stream", qos: .userInitiated)

/// One session for every Drive stream, so the connection to Google opened when a title's page opens (or by the
/// last film) is the one the player uses. Nothing is kept in the URL cache: a film's parts would only fill the disk.
private let streamSession: URLSession = {
    let q = OperationQueue()
    q.underlyingQueue = streamQueue
    q.maxConcurrentOperationCount = 1
    let config = URLSessionConfiguration.default
    config.urlCache = nil
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    // Google can take a while to start sending from deep inside a big film: waited for, rather than given up on.
    config.timeoutIntervalForRequest = 45
    config.httpMaximumConnectionsPerHost = 6
    return URLSession(configuration: config, delegate: StreamRouter.shared, delegateQueue: q)
}()

/// Plays a Drive video in Apple's player straight from Google: the player asks for the parts it needs (where it
/// starts, wherever it's moved to) and each part is fetched with a current Google token, so a film longer than the
/// token's hour keeps playing. The start of the file (and its index, wherever it is) can be fetched ahead, when the
/// title's page opens, so the player has what it needs to begin as soon as Play is pressed.
final class DriveStream: NSObject {
    let fileID: String
    private let loader: Loader

    init(fileID: String) {
        self.fileID = fileID
        loader = Loader(fileID: fileID)
        super.init()
    }

    deinit {
        let l = loader
        streamQueue.async { l.cancelAll() }
    }

    /// An asset for the player (this object must be kept while it plays).
    func asset() -> AVURLAsset {
        // A scheme of its own, so the player asks this object instead of fetching it itself.
        let asset = AVURLAsset(url: URL(string: "gdrive-stream://file/\(fileID).mp4")!)
        asset.resourceLoader.setDelegate(loader, queue: streamQueue)
        return asset
    }

    /// Drive's own address with the sign-in in the request's header, for the player to fetch and buffer itself:
    /// far faster for big films than answering its requests one by one (as the Android TVs' player does). Nil
    /// without a kept token lasting at least [minLife] seconds (then the asset above is used).
    nonisolated static func directAsset(fileID: String, minLife: Double = 900) -> AVURLAsset? {
        guard let token = GoogleDrive.cachedToken(minLife: minLife) else { return nil }
        return AVURLAsset(url: GoogleDrive.mediaURL(fileID),
                          options: ["AVURLAssetHTTPHeaderFieldsKey": ["Authorization": "Bearer \(token)"]])
    }

    /// Gets a token that will last the film's start and fetches the file's first part (and its index when that's
    /// further on), kept for a while for the player. Asked again for the same file, it does nothing.
    static func prefetch(fileID: String) {
        Task {
            // Long enough for Play to use Drive's address directly (directAsset).
            guard let token = try? await GoogleDrive.token(minLife: 1800) else { return }
            streamQueue.async { Prefetch.start(fileID, token: token) }
        }
    }

    /// Why Apple's player can't open a file Drive says is of this type, or nil when it can.
    static func unplayable(_ mime: String?) -> String? {
        guard let m = mime?.lowercased() else { return nil }
        let bad = ["video/x-matroska", "video/webm", "video/x-msvideo", "video/avi", "video/msvideo", "video/x-ms-wmv",
                   "video/x-ms-asf", "video/x-flv", "video/mp2t", "video/ogg"]
        guard bad.contains(where: { m.hasPrefix($0) }) else { return nil }
        return "Apple’s player can’t open this kind of file (MKV, AVI or WebM). Play it on a TV instead."
    }

    /// The file's type as Google sent it (nil when it didn't say).
    fileprivate static func mime(_ response: URLResponse) -> String? {
        response.mimeType.flatMap { $0.hasPrefix("application/octet-stream") ? nil : $0 }
    }

    /// The whole file's size from "bytes a-b/total".
    fileprivate static func total(_ response: URLResponse) -> Int64? {
        guard let range = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range") else { return nil }
        return range.split(separator: "/").last.flatMap { Int64($0) }
    }

    fileprivate static func fill(_ info: AVAssetResourceLoadingContentInformationRequest, total: Int64, mime: String?) {
        info.contentType = UTType(mimeType: mime ?? "video/mp4")?.identifier ?? UTType.mpeg4Movie.identifier
        info.contentLength = total
        info.isByteRangeAccessSupported = true
    }
}

/// Something waiting on one of the session's tasks.
private protocol StreamTask: AnyObject {
    func received(_ task: URLSessionDataTask, response: URLResponse, _ answer: @escaping (URLSession.ResponseDisposition) -> Void)
    func received(_ task: URLSessionDataTask, data: Data)
    func completed(_ task: URLSessionTask, error: Error?)
}

/// Hands each of the session's answers to whoever asked (on the stream queue).
private final class StreamRouter: NSObject, URLSessionDataDelegate {
    static let shared = StreamRouter()
    /// By task; only touched on the stream queue.
    var handlers: [Int: StreamTask] = [:]

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let h = handlers[dataTask.taskIdentifier] else { completionHandler(.cancel); return }
        h.received(dataTask, response: response, completionHandler)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        handlers[dataTask.taskIdentifier]?.received(dataTask, data: data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        handlers.removeValue(forKey: task.taskIdentifier)?.completed(task, error: error)
    }
}

/// Parts of files fetched ahead of Play (the start, and the index when it's further on), kept for a while. Only
/// touched on the stream queue.
private enum Prefetch {
    struct Part { let offset: Int64; let data: Data }
    struct Entry { var total: Int64; var mime: String?; var parts: [Part]; var at: Date }

    static var cache: [String: Entry] = [:]
    /// Files being fetched ahead, and what's waiting for them (the player's first requests).
    static var waiting: [String: [() -> Void]] = [:]

    static let headBytes: Int64 = 1 << 20
    static let indexCap: Int64 = 8 << 20

    static func start(_ id: String, token: String) {
        if let e = cache[id], Date().timeIntervalSince(e.at) < 1800 { return }
        guard waiting[id] == nil else { return }
        waiting[id] = []
        // The player never waits longer than this for it.
        streamQueue.asyncAfter(deadline: .now() + 5) { Prefetch.release(id) }
        PartFetch.run(id, token: token, from: 0, count: headBytes) { head in
            guard let head, head.total > 0 else { Prefetch.release(id); return }
            Prefetch.cache[id] = Entry(total: head.total, mime: head.mime, parts: [Part(offset: 0, data: head.data)], at: Date())
            Prefetch.trim()
            guard DriveStream.unplayable(head.mime) == nil, let more = Prefetch.indexRange(head.data, total: head.total) else {
                Prefetch.release(id)
                return
            }
            PartFetch.run(id, token: token, from: more.lowerBound, count: more.upperBound - more.lowerBound) { index in
                if let index { Prefetch.cache[id]?.parts.append(Part(offset: more.lowerBound, data: index.data)) }
                Prefetch.release(id)
            }
        }
    }

    /// True when [id] is being fetched ahead: [then] runs once it has been (or it's given up).
    static func wait(_ id: String, then: @escaping () -> Void) -> Bool {
        guard waiting[id] != nil else { return false }
        waiting[id]?.append(then)
        return true
    }

    static func release(_ id: String) {
        guard let w = waiting.removeValue(forKey: id) else { return }
        w.forEach { $0() }
    }

    /// The three most recent files only.
    static func trim() {
        while cache.count > 3, let oldest = cache.min(by: { $0.value.at < $1.value.at })?.key { cache[oldest] = nil }
    }

    /// Where an MP4's index (its "moov" box) is when it isn't all in the first part: after the media data, or running
    /// past the first part. Nil when it's all there already, or the file isn't laid out as boxes.
    static func indexRange(_ d: Data, total: Int64) -> Range<Int64>? {
        let b = [UInt8](d)
        func u32(_ i: Int) -> UInt64 { UInt64(b[i]) << 24 | UInt64(b[i + 1]) << 16 | UInt64(b[i + 2]) << 8 | UInt64(b[i + 3]) }
        let have = Int64(b.count)
        var off = 0
        while off + 8 <= b.count {
            var size = Int64(u32(off))
            let type = String(bytes: b[(off + 4)..<(off + 8)], encoding: .ascii) ?? ""
            if size == 1 {
                guard off + 16 <= b.count else { return nil }
                size = Int64(bitPattern: u32(off + 8) << 32 | u32(off + 12))
            } else if size == 0 {
                size = total - Int64(off)
            }
            guard size >= 8 else { return nil }
            let end = Int64(off) + size
            if type == "moov" { return end > have ? have..<min(end, have + indexCap) : nil }
            if type == "mdat" { return end < total ? end..<min(total, end + indexCap) : nil }
            guard end < have else { return nil }
            off = Int(end)
        }
        return nil
    }
}

/// One part of a file fetched ahead.
private final class PartFetch: StreamTask {
    struct Got { let total: Int64; let mime: String?; let data: Data }
    private let count: Int64
    private let done: (Got?) -> Void
    private var data = Data()
    private var total: Int64 = 0
    private var mime: String?
    private var delivered = false

    private init(count: Int64, done: @escaping (Got?) -> Void) {
        self.count = count
        self.done = done
    }

    static func run(_ id: String, token: String, from: Int64, count: Int64, done: @escaping (Got?) -> Void) {
        var r = URLRequest(url: GoogleDrive.mediaURL(id))
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("bytes=\(from)-\(from + count - 1)", forHTTPHeaderField: "Range")
        r.timeoutInterval = 8
        let f = PartFetch(count: count, done: done)
        let t = streamSession.dataTask(with: r)
        StreamRouter.shared.handlers[t.taskIdentifier] = f
        t.resume()
    }

    func received(_ task: URLSessionDataTask, response: URLResponse, _ answer: @escaping (URLSession.ResponseDisposition) -> Void) {
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 || code == 206 else { answer(.cancel); return }
        total = DriveStream.total(response) ?? (code == 200 ? max(0, response.expectedContentLength) : 0)
        mime = DriveStream.mime(response)
        answer(.allow)
    }

    func received(_ task: URLSessionDataTask, data more: Data) {
        data.append(more)
        // Google sending more than asked for (the whole file): only what was asked for is kept.
        if Int64(data.count) >= count {
            data = Data(data.prefix(Int(count)))
            task.cancel()
            deliver(true)
        }
    }

    func completed(_ task: URLSessionTask, error: Error?) { deliver(error == nil) }

    private func deliver(_ ok: Bool) {
        guard !delivered else { return }
        delivered = true
        done(ok && total > 0 && !data.isEmpty ? Got(total: total, mime: mime, data: data) : nil)
    }
}

/// Answers each part the player asks for: from what was fetched ahead where it can, else from Google, handing the
/// bytes over as they arrive. Everything here runs on the stream queue.
private final class Loader: NSObject, AVAssetResourceLoaderDelegate, StreamTask {
    let fileID: String

    /// A part being fetched, by its data task.
    private final class Load {
        let request: AVAssetResourceLoadingRequest
        let retried: Bool
        let task: URLSessionDataTask
        /// Times it has been asked for again after a slow or dropped connection.
        let attempts: Int
        init(request: AVAssetResourceLoadingRequest, retried: Bool, task: URLSessionDataTask, attempts: Int) {
            self.request = request; self.retried = retried; self.task = task; self.attempts = attempts
        }
    }

    /// Failures worth asking again for (the connection, not the file).
    private static let transient: Set<URLError.Code> = [.timedOut, .networkConnectionLost, .cannotConnectToHost,
                                                         .dnsLookupFailed, .cannotFindHost, .secureConnectionFailed]

    /// A part that failed for the connection's sake (or Google was busy): asked for again from where it got to, after
    /// a moment, three times at most before the player is told.
    private func again(_ load: Load) {
        let req = load.request, next = load.attempts + 1, retried = load.retried
        streamQueue.asyncAfter(deadline: .now() + 0.5 * Double(next)) { [weak self] in
            guard let self, !req.isCancelled, !req.isFinished else { return }
            if let token = GoogleDrive.cachedToken() { self.send(req, token: token, retried: retried, attempts: next) }
            else { self.fetch(req, retried: false) }
        }
    }
    private var loads: [Int: Load] = [:]

    init(fileID: String) {
        self.fileID = fileID
    }

    func cancelAll() {
        for (id, load) in loads {
            StreamRouter.shared.handlers[id] = nil
            load.task.cancel()
        }
        loads = [:]
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        begin(loadingRequest)
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        for (id, load) in loads where load.request === loadingRequest {
            StreamRouter.shared.handlers[id] = nil
            load.task.cancel()
            loads[id] = nil
        }
    }

    private func begin(_ req: AVAssetResourceLoadingRequest) {
        guard !req.isCancelled, !req.isFinished else { return }
        // Its start is on the way already: that, rather than asking Google a second time.
        if Prefetch.wait(fileID, then: { [weak self] in self?.begin(req) }) { return }
        if fromCache(req) { return }
        fetch(req, retried: false)
    }

    /// Answers what it can of [req] from what was fetched ahead; true when that was all of it.
    private func fromCache(_ req: AVAssetResourceLoadingRequest) -> Bool {
        guard let e = Prefetch.cache[fileID] else { return false }
        if let info = req.contentInformationRequest {
            if let why = DriveStream.unplayable(e.mime) {
                req.finishLoading(with: GoogleDrive.Failure(why))
                return true
            }
            DriveStream.fill(info, total: e.total, mime: e.mime)
        }
        guard let d = req.dataRequest else { req.finishLoading(); return true }
        let end = d.requestsAllDataToEndOfResource ? e.total : d.requestedOffset + Int64(d.requestedLength)
        var off = d.currentOffset != 0 ? d.currentOffset : d.requestedOffset
        while off < end, let part = e.parts.first(where: { $0.offset <= off && off < $0.offset + Int64($0.data.count) }) {
            let partEnd = min(end, part.offset + Int64(part.data.count))
            let lo = part.data.startIndex + Int(off - part.offset), hi = part.data.startIndex + Int(partEnd - part.offset)
            d.respond(with: part.data.subdata(in: lo..<hi))
            off = partEnd
        }
        if off >= end { req.finishLoading(); return true }
        return false
    }

    /// A current token (a fresh one after Google refused the last), then the part asked for.
    private func fetch(_ req: AVAssetResourceLoadingRequest, retried: Bool) {
        // Usually in memory: sent at once, without waiting for the main thread.
        if !retried, let token = GoogleDrive.cachedToken() {
            send(req, token: token, retried: false)
            return
        }
        Task {
            do {
                if retried { await GoogleDrive.dropToken() }
                let token = try await GoogleDrive.token()
                streamQueue.async { self.send(req, token: token, retried: retried) }
            } catch {
                streamQueue.async {
                    if !req.isCancelled && !req.isFinished { req.finishLoading(with: error) }
                }
            }
        }
    }

    private func send(_ req: AVAssetResourceLoadingRequest, token: String, retried: Bool, attempts: Int = 0) {
        guard !req.isCancelled, !req.isFinished else { return }
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
        r.timeoutInterval = 45
        let t = streamSession.dataTask(with: r)
        loads[t.taskIdentifier] = Load(request: req, retried: retried, task: t, attempts: attempts)
        StreamRouter.shared.handlers[t.taskIdentifier] = self
        t.resume()
    }

    func received(_ dataTask: URLSessionDataTask, response: URLResponse, _ answer: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let load = loads[dataTask.taskIdentifier] else { answer(.cancel); return }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 || code == 206 else {
            loads[dataTask.taskIdentifier] = nil
            answer(.cancel)
            if code == 401 && !load.retried {
                fetch(load.request, retried: true)
            } else if [429, 500, 502, 503, 504].contains(code), load.attempts < 3 {
                again(load)
            } else if !load.request.isCancelled && !load.request.isFinished {
                load.request.finishLoading(with: GoogleDrive.failure(code, nil))
            }
            return
        }
        if let info = load.request.contentInformationRequest {
            let mime = DriveStream.mime(response)
            // A file Apple's player can't open: said at once, instead of the player reading on before giving up.
            if let why = DriveStream.unplayable(mime) {
                loads[dataTask.taskIdentifier] = nil
                answer(.cancel)
                if !load.request.isCancelled && !load.request.isFinished { load.request.finishLoading(with: GoogleDrive.Failure(why)) }
                return
            }
            let total = DriveStream.total(response) ?? (code == 200 ? max(0, response.expectedContentLength) : 0)
            DriveStream.fill(info, total: total, mime: mime)
        }
        answer(.allow)
    }

    func received(_ dataTask: URLSessionDataTask, data: Data) {
        guard let load = loads[dataTask.taskIdentifier] else { return }
        if load.request.isCancelled {
            loads[dataTask.taskIdentifier] = nil
            StreamRouter.shared.handlers[dataTask.taskIdentifier] = nil
            dataTask.cancel()
            return
        }
        load.request.dataRequest?.respond(with: data)
    }

    func completed(_ task: URLSessionTask, error: Error?) {
        guard let load = loads.removeValue(forKey: task.taskIdentifier) else { return }
        let req = load.request
        guard !req.isCancelled, !req.isFinished else { return }
        // A slow or dropped connection (Google slow to start deep inside a big film, the Wi‑Fi hiccuping): asked for
        // again from where it got to, instead of the film stopping with a timeout.
        if let e = error as? URLError, Self.transient.contains(e.code), load.attempts < 3 {
            again(load)
            return
        }
        if let error { req.finishLoading(with: error) } else { req.finishLoading() }
    }
}
