import Foundation
import AVFoundation
import UniformTypeIdentifiers
import os
import WoodruffKit

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

    /// [name] is the film's title, for the Macs' log.
    init(fileID: String, name: String = "") {
        self.fileID = fileID
        loader = Loader(fileID: fileID, name: name)
        super.init()
    }

    deinit {
        let l = loader
        streamQueue.async { l.cancelAll() }
    }

    /// What Google said when it refused this file for good, if it did (its daily limit for the file, say).
    func refusalNow() -> String? { loader.notes.refusal }

    /// Whether what Google refused it with was its daily limit.
    func overLimitNow() -> Bool { loader.notes.overLimit }

    /// The file's size once Google has said, and the fastest the film has arrived here (megabits a second; 0 when
    /// not enough of it has been timed yet).
    func sizeNow() -> Int64? { loader.notes.size }
    func fastestNow() -> Double { loader.notes.fastest }

    /// An asset for the player (this object must be kept while it plays).
    func asset() -> AVURLAsset {
        // A scheme of its own, so the player asks this object instead of fetching it itself.
        let asset = AVURLAsset(url: URL(string: "gdrive-stream://file/\(fileID).mp4")!)
        asset.resourceLoader.setDelegate(loader, queue: streamQueue)
        return asset
    }

    /// What it has asked Google for so far, been sent and handed to the player ("3.2 GB in 61 requests, 3.2 GB sent,
    /// 3.1 GB to the player, 130 MB kept at most"), for the Macs' log.
    func askedNow() -> String { loader.notes.tally }

    /// The memory is short: less of the film is kept from here on.
    func shrink() {
        let l = loader
        streamQueue.async { l.shrink() }
    }

    /// Not used for playing any more: the player fetching from Drive's own address asks Google for everything from
    /// where it is to the end of the film each time it starts, seeks or reconnects, which the app can't change, and
    /// the day it was used Google refused the big films for the rest of the day
    /// (downloadQuotaExceeded). The asset above asks for a piece at a time instead.
    ///
    /// Drive's own address with the sign-in in the request's header, for the player to fetch and buffer itself. Nil
    /// without a kept token lasting at least [minLife] seconds. [expires] is when the sign-in it was given runs out
    /// (seconds since 1970): the player's requests are refused after that.
    nonisolated static func directAsset(fileID: String, minLife: Double = 900) -> (asset: AVURLAsset, expires: Double)? {
        guard let kept = GoogleDrive.cachedTokenUntil(minLife: minLife) else { return nil }
        let asset = AVURLAsset(url: GoogleDrive.mediaURL(fileID),
                               options: ["AVURLAssetHTTPHeaderFieldsKey": ["Authorization": "Bearer \(kept.token)"]])
        return (asset, kept.expires)
    }

    /// Why the last part couldn't be fetched, in the last few seconds: Google's reason or the connection's (the
    /// player passes on only a number, "OSStatus -1001").
    var recentFailure: Error? { loader.failure.recent(within: 20) }

    /// Gets a token that will last the film's start and fetches the file's first part (and its index when that's
    /// further on), kept for a while for the player. Asked again for the same file, it does nothing.
    static func prefetch(fileID: String) {
        Task {
            // One that lasts: the film's first minutes then never wait for a new sign-in.
            guard let token = try? await GoogleDrive.token(minLife: 2700) else { return }
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

/// Why a stream's last part couldn't be fetched, and when: set on the stream queue, read from the main thread.
private final class LastFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var error: Error?
    private var at = Date.distantPast

    func set(_ e: Error) {
        lock.lock(); error = e; at = Date(); lock.unlock()
    }

    /// The last one, if it was within [within] seconds.
    func recent(within: TimeInterval) -> Error? {
        lock.lock(); defer { lock.unlock() }
        return Date().timeIntervalSince(at) < within ? error : nil
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

/// What a stream has asked Google for, been sent and handed to the player, and what Google said if it refused the
/// file. Written on the stream queue and read from the main thread, which never waits for the stream queue: the
/// player's own calls run there, and the main thread waiting on it could leave the app not answering.
private final class StreamNotes: @unchecked Sendable {
    private let lock = NSLock()
    private var requests = 0
    private var asked: Int64 = 0
    private var sent: Int64 = 0
    private var handed: Int64 = 0
    private var most: Int64 = 0
    /// Every part asked of Google so far, and how much of what was asked had been asked for before.
    private var askedFor = ByteRanges()
    private var twice: Int64 = 0
    /// Pieces asked for at a place that didn't carry on from the last one, the player's requests and how many of
    /// them it dropped, and the most places it read from at once (and how far apart the furthest two were).
    private var starts = 0
    private var wanted = 0
    private var dropped = 0
    private var mostPlaces = 0
    private var widest: Int64 = 0
    /// The player's requests for a set length (not "to the end"), and those made while it read from two places.
    private var fixed = 0
    private var apart = 0
    /// Pieces put into files, and whether one couldn't be.
    private var files = 0
    private var filesFailed = false
    private var refused: String?
    private var limit = false
    /// The file's size, once Google has said.
    private var whole: Int64?
    /// What arrived in each of the last seconds, and the most that arrived in any three seconds running (bytes): how
    /// fast the connection brings the film when it's asked for all it can give.
    private var perSecond: [Int: Int64] = [:]
    private var second = 0
    private var bestThree: Int64 = 0

    /// Google is asked for the bytes from [lo] up to, not including, [hi].
    func asking(from lo: Int64, to hi: Int64) {
        lock.lock(); defer { lock.unlock() }
        requests += 1
        asked += hi - lo
        twice += askedFor.add(lo, hi)
    }
    /// A piece is asked for at a place that doesn't carry on from the last one.
    func freshStart() { lock.lock(); starts += 1; lock.unlock() }
    /// The player asked for something ([bounded]: a set length, not "to the end"); its requests are now at
    /// [positions].
    func playerAsked(at positions: [Int64], bounded: Bool) {
        let p = StreamKeep.places(positions, near: 16 << 20)
        lock.lock(); defer { lock.unlock() }
        wanted += 1
        if bounded { fixed += 1 }
        if p.count > 1 { apart += 1 }
        mostPlaces = max(mostPlaces, p.count)
        widest = max(widest, p.spread)
    }
    /// A piece went into a file ([ok]), or couldn't.
    func filed(_ ok: Bool) {
        lock.lock(); defer { lock.unlock() }
        if ok { files += 1 } else { filesFailed = true }
    }
    func playerDropped() { lock.lock(); dropped += 1; lock.unlock() }
    func got(_ bytes: Int64) {
        lock.lock(); defer { lock.unlock() }
        sent += bytes
        let now = Int(Date().timeIntervalSince1970)
        if now != second {
            // The three whole seconds before this one.
            bestThree = max(bestThree, (1...3).reduce(Int64(0)) { $0 + (perSecond[now - $1] ?? 0) })
            if perSecond.count > 30 { perSecond = perSecond.filter { $0.key >= now - 10 } }
            second = now
        }
        perSecond[now, default: 0] += bytes
    }
    func sized(_ bytes: Int64) { lock.lock(); whole = bytes; lock.unlock() }

    /// The file's size, and the fastest the film has arrived (megabits a second, over three seconds; 0 when no three
    /// seconds of it have been timed yet).
    var size: Int64? { lock.lock(); defer { lock.unlock() }; return whole }
    var fastest: Double { lock.lock(); defer { lock.unlock() }; return Double(bestThree) * 8 / 3 / 1_000_000 }
    func gave(_ bytes: Int64) { lock.lock(); handed += bytes; lock.unlock() }
    func keeping(_ bytes: Int64) { lock.lock(); most = max(most, bytes); lock.unlock() }
    func refuse(_ why: String, limit isLimit: Bool) { lock.lock(); refused = why; limit = isLimit; lock.unlock() }

    var refusal: String? { lock.lock(); defer { lock.unlock() }; return refused }
    /// Google refused the file with its daily limit.
    var overLimit: Bool { lock.lock(); defer { lock.unlock() }; return limit }

    var tally: String {
        lock.lock(); defer { lock.unlock() }
        // (Put together a part at a time: one long sum of strings takes the compiler too long to check.)
        var text = "\(Self.size(asked)) in \(requests == 1 ? "1 request" : "\(requests) requests")"
        text += ", \(Self.size(sent)) sent, \(Self.size(handed)) to the player"
        if bestThree > 0 { text += String(format: ", up to %.0f Mb/s", Double(bestThree) * 8 / 3 / 1_000_000) }
        text += ", \(Self.size(most)) kept at most"
        text += ", \(Self.size(twice)) of it asked twice, \(starts) fresh starts"
        text += ", the player asked \(wanted) times (\(fixed) for a set length, \(apart) while reading two places)"
        text += " and dropped \(dropped)"
        text += mostPlaces == 1 ? ", 1 place at once at most" : ", \(mostPlaces) places at once at most"
        if widest > 0 { text += " (\(Self.size(widest)) apart)" }
        text += ", \(files) pieces kept in files"
        if filesFailed { text += " until one couldn’t be written" }
        return text
    }

    private static func size(_ bytes: Int64) -> String {
        bytes >= 1_000_000_000 ? String(format: "%.1f GB", Double(bytes) / 1e9) : String(format: "%.0f MB", Double(bytes) / 1e6)
    }
}

/// Answers each part of the film the player asks for: from what has already been fetched where it can, else from
/// Google. Everything here runs on the stream queue.
///
/// Google counts what the family's TVs and apps download together over a day (they share one set of Google keys;
/// its documentation gives a terabyte a day for a set of keys) and, once that is used up, refuses every film to all
/// of them until it clears: a real part of any film is refused, though a byte or two is still answered. How it
/// counts isn't published, so nothing is asked for that isn't used. The player drops what it asked for all the
/// time: it looks at many places as it opens a film, and stops and asks again from nearly the same place every time
/// it has read far enough ahead. So:
///
/// - Google is asked for one piece at a time, never for "everything from here to the end".
/// - A piece asked for is fetched whole and kept for a while, whether or not the player's request it was fetched
///   for is still wanted: when the player asks again from nearly the same place, it's answered from what's kept,
///   and nothing asked of Google goes unused.
/// - The first piece at a new place in the film is small; each one that carries straight on from the last is
///   twice it, so a film playing is few requests and a place only looked at costs little.
/// - The player reads from more than one place at a time (its picture and its sound each at their own). When more
///   is held than may be, what the film has gone past goes first and what a place is about to come to goes last
///   (`StreamKeep`), so no place's fetched-ahead piece is thrown away for another's and asked of Google again.
private final class Loader: NSObject, AVAssetResourceLoaderDelegate, StreamTask {
    let fileID: String
    /// The film's title, for the Macs' log.
    let name: String
    let notes = StreamNotes()
    /// Why the last piece couldn't be fetched, for the player's message (it passes on only a number).
    let failure = LastFailure()

    /// How big a piece is asked for, by how far along a straight read it is.
    private static let sizes: [Int64] = [4 << 20, 8 << 20, 16 << 20, 32 << 20, 64 << 20]
    /// How much of the film is kept in memory at most: a quarter of the memory the app may still take as the film
    /// opens, never less than three of the biggest pieces nor more than ten (ten on a Mac). One place being read
    /// needs the piece it's in and the one fetched ahead of it; the player reads its picture and its sound each at a
    /// place of their own, and what lies between two of them is still to come for the slower one. Three pieces
    /// (192 MB, as it was) left no room for a second place: each one's fetched-ahead piece pushed the other's out,
    /// and Google was asked for it again.
    private static func room() -> Int64 {
        let piece = sizes.last ?? (64 << 20)
        #if os(macOS)
        return 10 * piece
        #else
        let free = Int64(os_proc_available_memory())
        return min(max(free / 4, 3 * piece), 10 * piece)
        #endif
    }
    /// How much a request of the player's is handed at once from what's kept, and how fast after that (bytes a
    /// second). The player asks for "everything from here on" and lets the request go a moment later, once it has
    /// the next part it needed. Handed all that's kept as fast as memory allows, one film (its sound and picture
    /// stored far apart, so the player hopped between them seven times a second) was given 367 GB in three minutes,
    /// for a film that plays at 36 megabits a second, and the Apple TV had that to carry. Paced, a request gets what
    /// it came for at once and the rest no faster than this: still several times faster than the heaviest film
    /// plays.
    private static let burst: Int64 = 8 << 20
    private static let pace: Double = 64 * 1_048_576
    /// How much of the film is kept in files at most, and the smallest piece worth a file of its own.
    private static let onDisk: Int64 = 3 << 30
    private static let worthFiling = 1 << 20
    /// Writing and removing the pieces' files, off the stream's own queue.
    private static let disk = DispatchQueue(label: "woodruff.drive-stream.files", qos: .utility)
    /// Where every film's pieces are kept, emptied once as the app starts (a film that ended with the app left its
    /// pieces behind); nil when the device's cache folder can't be used.
    private static let filmsFolder: URL? = {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let dir = caches.appendingPathComponent("FilmPieces", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) } catch { return nil }
        return dir
    }()
    /// A folder of its own for one film's pieces.
    private static func newFolder() -> URL? {
        guard let base = filmsFolder else { return nil }
        let dir = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) } catch { return nil }
        return dir
    }
    /// How long a place the player has let go of still counts as one it reads from (it asks again from nearly the
    /// same place a moment later), how far behind a place still counts as where it is, and how close together two
    /// places are one.
    private static let placeLife: TimeInterval = 30
    private static let behind: Int64 = 8 << 20
    private static let near: Int64 = 16 << 20
    /// How much of what's kept is handed to the player at a time.
    private static let slice: Int64 = 2 << 20
    /// From this far along a straight read, the next piece is asked for as soon as this one starts being read, so
    /// the film never waits for Google to start sending between pieces.
    private static let aheadFrom = 1
    /// Pieces being fetched at once, at most, before the one used longest ago that nobody is waiting for is let go.
    private static let fetchingAtMost = 4

    /// A piece of the film: asked of Google once, fetched whole and kept for a while.
    private final class Piece {
        let offset: Int64
        /// How many bytes were asked for (fewer once it's in, if the file ended first or Google stopped short).
        var asked: Int64
        /// How far along a straight read it is (an index into `sizes`).
        let step: Int
        var data = Data()
        /// The file its bytes are in once it's whole (`store`; they're then read from the file as they're needed),
        /// and whether it's being written there now.
        var file: URL?
        var storing = false
        /// Still being fetched: waiting for Google, for a sign-in or for another try.
        var fetching = true
        var task: URLSessionDataTask?
        var used = Date()
        /// Times it has been asked for again after a slow or dropped connection, and after Google was busy.
        var attempts = 0
        var busy = 0
        var signedInAgain = false
        /// Google's refusal (its status and the reason it sent), read whole before anything is decided.
        var status = 0
        var body = Data()

        init(offset: Int64, asked: Int64, step: Int) {
            self.offset = offset
            self.asked = asked
            self.step = step
        }

        /// One past the last byte that has arrived, and one past the last byte asked for.
        var end: Int64 { offset + Int64(data.count) }
        var limit: Int64 { offset + asked }
    }

    /// One of the player's requests, and how far it has been answered.
    private final class Want {
        let request: AVAssetResourceLoadingRequest
        /// The next byte it's owed.
        var at: Int64
        /// One past the last byte it asked for, or nil when it asked for everything to the end of the file.
        let end: Int64?
        /// Whether it has been told what the file is (when it asked).
        var told = false
        /// How much it has been handed, when it may next be handed more (`pace`), and whether a later turn is
        /// already set for that.
        var handed: Int64 = 0
        var notBefore = Date.distantPast
        var waiting = false

        init(request: AVAssetResourceLoadingRequest, at: Int64, end: Int64?) {
            self.request = request
            self.at = at
            self.end = end
        }
    }

    private var pieces: [Piece] = []
    private var byTask: [Int: Piece] = [:]
    private var wants: [Want] = []
    /// The file's size and type, once Google has said.
    private var total: Int64?
    private var mime: String?
    /// What was fetched ahead of Play has been taken in.
    private var adopted = false
    /// Google flagged the file: asked for with that acknowledged (allowed for its owner).
    private var acknowledge = false
    /// Why Apple's player can't open this file, once known.
    private var unplayable: String?
    /// The memory is short: less is kept (`shrink`).
    private var keepNow = Loader.room()
    /// The folder this film's whole pieces are kept in, each in a file of its own (nil when it couldn't be made), and
    /// whether pieces still go there: not once one couldn't be written (the storage full). Without it, pieces stay
    /// in memory, as they did.
    private let folder: URL? = Loader.newFolder()
    private var filing = true
    /// Where the player's requests had got to when it let go of them, lately.
    private var lately: [(at: Int64, seen: Date)] = []

    /// Failures worth asking again for (the connection, not the file).
    private static let transient: Set<URLError.Code> = [.timedOut, .networkConnectionLost, .cannotConnectToHost,
                                                         .dnsLookupFailed, .cannotFindHost, .secureConnectionFailed]

    init(fileID: String, name: String) {
        self.fileID = fileID
        self.name = name
    }

    func cancelAll() {
        for (id, piece) in byTask {
            StreamRouter.shared.handlers[id] = nil
            piece.task?.cancel()
        }
        byTask = [:]
        pieces = []
        wants = []
        lately = []
        // The film is over: its pieces' files go.
        filing = false
        if let gone = folder { Loader.disk.async { try? FileManager.default.removeItem(at: gone) } }
    }

    /// The memory is short: only the piece being read and the next are kept in memory from here on. (What's in
    /// files isn't memory: it stays.)
    func shrink() {
        keepNow = min(keepNow, 2 * (Loader.sizes.last ?? 0))
        trim()
    }

    // MARK: The player's requests

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        begin(loadingRequest)
        return true
    }

    /// The player has dropped a request. What Google is sending for it carries on and is kept: the player nearly
    /// always asks again from the same place, or a little before it, a moment later.
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        if let want = wants.first(where: { $0.request === loadingRequest }) {
            remember(want.at)
            notes.playerDropped()
        }
        wants.removeAll { $0.request === loadingRequest }
        rank()
    }

    /// A request of the player's is over (dropped, answered in full or failed): where it had got to stays a place
    /// the film is read from for a while.
    private func remember(_ at: Int64) {
        let now = Date()
        lately.removeAll { now.timeIntervalSince($0.seen) > Loader.placeLife || abs($0.at - at) <= Loader.near }
        lately.append((at: at, seen: now))
        if lately.count > 8 { lately.removeFirst(lately.count - 8) }
    }

    /// Every place the film is being read from: the player's requests, and where the ones it let go of lately had
    /// got to.
    private func readingAt() -> [Int64] {
        let now = Date()
        lately.removeAll { now.timeIntervalSince($0.seen) > Loader.placeLife }
        return wants.map { $0.at } + lately.map { $0.at }
    }

    /// What the player is waiting for comes first: a piece still arriving that none of its requests is waiting for
    /// any more (it has moved elsewhere in the film) gives way to the ones that are waited for.
    private func rank() {
        for piece in pieces where piece.fetching {
            let waitedFor = wants.contains { piece.offset <= $0.at && $0.at < piece.limit }
            piece.task?.priority = waitedFor ? URLSessionTask.highPriority : URLSessionTask.lowPriority
        }
    }

    private func begin(_ req: AVAssetResourceLoadingRequest) {
        guard !req.isCancelled, !req.isFinished else { return }
        // Its start is on the way already: that, rather than asking Google a second time.
        if Prefetch.wait(fileID, then: { [weak self] in self?.begin(req) }) { return }
        adopt()
        let d = req.dataRequest
        let want = Want(request: req, at: d?.requestedOffset ?? 0, end: d.flatMap(Loader.wantedEnd))
        wants.append(want)
        notes.playerAsked(at: wants.map { $0.at }, bounded: want.end != nil)
        pump(want)
    }

    /// One past the last byte the player asked for, or nil when it asked for everything to the end of the file.
    private static func wantedEnd(_ d: AVAssetResourceLoadingDataRequest) -> Int64? {
        if d.requestsAllDataToEndOfResource { return nil }
        let (end, overflow) = d.requestedOffset.addingReportingOverflow(Int64(d.requestedLength))
        return overflow ? nil : end
    }

    /// What was fetched ahead of Play (the file's start, and its index when that's further on) becomes pieces like
    /// any others.
    private func adopt() {
        guard !adopted, let e = Prefetch.cache[fileID] else { return }
        adopted = true
        if e.total > 0 { total = e.total; notes.sized(e.total) }
        mime = e.mime
        unplayable = DriveStream.unplayable(e.mime)
        for part in e.parts where !part.data.isEmpty && piece(holding: part.offset) == nil {
            let p = Piece(offset: part.offset, asked: Int64(part.data.count), step: 0)
            p.data = part.data
            p.fetching = false
            pieces.append(p)
        }
    }

    /// The piece that holds the byte at [at], and the one being fetched that will.
    private func piece(holding at: Int64) -> Piece? {
        pieces.first { $0.offset <= at && at < $0.end }
    }
    private func piece(bringing at: Int64) -> Piece? {
        pieces.first { $0.fetching && $0.offset <= at && at < $0.limit }
    }

    /// Answers every request of the player's as far as it can be.
    private func feed() {
        for want in wants { pump(want) }
    }

    /// Answers [want] as far as it can be: from a piece that's held, else it waits for the piece that's on its way,
    /// else Google is asked for the piece it needs next.
    private func pump(_ want: Want) {
        let req = want.request
        guard wants.contains(where: { $0 === want }) else { return }
        guard !req.isCancelled, !req.isFinished else { forget(want); return }
        if let why = unplayable { fail(want, GoogleDrive.Failure(why)); return }
        if let info = req.contentInformationRequest, !want.told {
            // What the file is isn't known yet: it comes with the first piece.
            guard let size = total else {
                if !pieces.contains(where: { $0.fetching }), !ask(from: want.at, for: want) {
                    fail(want, URLError(.resourceUnavailable))
                }
                return
            }
            DriveStream.fill(info, total: size, mime: mime)
            want.told = true
        }
        guard let d = req.dataRequest else { finish(want); return }
        let end = min(want.end ?? .max, total ?? .max)
        if want.at >= end { finish(want); return }
        if let piece = piece(holding: want.at) {
            // Paced once it has had its first part (`burst`): the next part at a later turn of the queue.
            if want.handed >= Loader.burst {
                let wait = want.notBefore.timeIntervalSinceNow
                if wait > 0 {
                    if !want.waiting {
                        want.waiting = true
                        streamQueue.asyncAfter(deadline: .now() + wait) { [weak self] in
                            want.waiting = false
                            self?.pump(want)
                        }
                    }
                    return
                }
            }
            let upTo = min(piece.end, end, want.at + Loader.slice)
            let lo = piece.data.startIndex + Int(want.at - piece.offset), hi = piece.data.startIndex + Int(upTo - piece.offset)
            let bytes = piece.data.subdata(in: lo..<hi)
            want.at = upTo
            want.handed += Int64(bytes.count)
            if want.handed >= Loader.burst { want.notBefore = Date().addingTimeInterval(Double(bytes.count) / Loader.pace) }
            piece.used = Date()
            notes.gave(Int64(bytes.count))
            d.respond(with: bytes)
            if want.at >= end { finish(want); return }
            ahead(of: want, reading: piece)
            // The rest at the queue's next turn, so the player dropping the request is heard in between.
            streamQueue.async { [weak self] in self?.pump(want) }
            return
        }
        // On its way: answered as it arrives.
        if let coming = piece(bringing: want.at) {
            coming.used = Date()
            return
        }
        // Nothing to ask for where it has got to (it shouldn't happen): said, rather than left waiting for ever.
        if !ask(from: want.at, for: want) { fail(want, URLError(.resourceUnavailable)) }
    }

    /// A film being read straight through: the piece after [piece] is asked for while this one is still being
    /// read, so the film never waits for Google to start sending between pieces.
    private func ahead(of want: Want, reading piece: Piece) {
        guard piece.step >= Loader.aheadFrom else { return }
        let next = piece.limit
        guard next < min(want.end ?? .max, total ?? .max) else { return }
        guard self.piece(holding: next) == nil, self.piece(bringing: next) == nil else { return }
        guard pieces.filter({ $0.fetching }).count < 2 else { return }
        ask(from: next, for: want)
    }

    /// Asks Google for the piece that starts at [at]: small at a new place in the film, twice the last one when it
    /// carries straight on from it, and never past what the player asked for, the end of the file, or a piece that's
    /// already held or on its way further on.
    @discardableResult
    private func ask(from at: Int64, for want: Want) -> Bool {
        let before = pieces.first { $0.limit == at }
        let step = before.map { min($0.step + 1, Loader.sizes.count - 1) } ?? 0
        var length = Loader.sizes[step]
        if let end = want.end { length = min(length, end - at) }
        if let size = total { length = min(length, size - at) }
        if let next = pieces.filter({ $0.offset > at }).map(\.offset).min() { length = min(length, next - at) }
        // Only what the file is was asked for: its first two bytes are enough.
        if want.request.dataRequest == nil { length = min(length, 2) }
        guard length > 0 else { return false }
        if before == nil, length > 2 { notes.freshStart() }
        let piece = Piece(offset: at, asked: length, step: step)
        piece.data.reserveCapacity(Int(length))
        pieces.append(piece)
        // Too many at once (the player has moved about): the one nobody is waiting for that was used longest ago goes.
        let fetching = pieces.filter { $0.fetching }
        if fetching.count > Loader.fetchingAtMost,
           let idle = fetching.filter({ p in p !== piece && !wants.contains { p.offset <= $0.at && $0.at < p.limit } })
            .min(by: { $0.used < $1.used }) {
            drop(idle)
        }
        fetch(piece)
        return true
    }

    /// The player's request has all it asked for.
    private func finish(_ want: Want) {
        forget(want)
        want.request.finishLoading()
    }

    /// Tells the player its request can't be had, keeping why.
    private func fail(_ want: Want, _ error: Error) {
        forget(want)
        failure.set(error)
        if !want.request.isCancelled && !want.request.isFinished { want.request.finishLoading(with: error) }
    }

    private func forget(_ want: Want) {
        if wants.contains(where: { $0 === want }) { remember(want.at) }
        wants.removeAll { $0 === want }
    }

    // MARK: Google

    /// A current token (a fresh one after Google refused the last), then what's left of [piece] is asked for.
    private func fetch(_ piece: Piece, fresh: Bool = false) {
        // Usually in memory: sent at once, without waiting for the main thread.
        if !fresh, let token = GoogleDrive.cachedToken() {
            send(piece, token: token)
            return
        }
        Task {
            do {
                if fresh { await GoogleDrive.dropToken() }
                let token = try await GoogleDrive.token()
                streamQueue.async { self.send(piece, token: token) }
            } catch {
                let ns = error as NSError
                await MainActor.run { Diagnostics.shared.notePlayback("Drive sign-in couldn’t be renewed (\(ns.domain) \(ns.code))") }
                streamQueue.async { self.gaveUp(piece, error) }
            }
        }
    }

    /// Asks Google for what's left of [piece]: from the last byte of it that has arrived to the last one asked for.
    private func send(_ piece: Piece, token: String) {
        guard pieces.contains(where: { $0 === piece }), piece.fetching else { return }   // let go meanwhile
        let start = piece.end, last = piece.limit - 1
        guard start <= last else { arrived(piece); return }
        var r = URLRequest(url: acknowledge ? GoogleDrive.mediaURL(fileID, acknowledgeAbuse: true) : GoogleDrive.mediaURL(fileID))
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("bytes=\(start)-\(last)", forHTTPHeaderField: "Range")
        r.timeoutInterval = 45
        let t = streamSession.dataTask(with: r)
        piece.task = t
        piece.status = 0
        piece.body = Data()
        byTask[t.taskIdentifier] = piece
        StreamRouter.shared.handlers[t.taskIdentifier] = self
        notes.asking(from: start, to: last + 1)
        t.resume()
        rank()
    }

    func received(_ dataTask: URLSessionDataTask, response: URLResponse, _ answer: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let piece = byTask[dataTask.taskIdentifier] else { answer(.cancel); return }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 || code == 206 else {
            if code == 401 && !piece.signedInAgain {
                byTask[dataTask.taskIdentifier] = nil
                piece.task = nil
                piece.signedInAgain = true
                answer(.cancel)
                Task { @MainActor in Diagnostics.shared.notePlayback("Drive answered 401 (sign-in refused)") }
                fetch(piece, fresh: true)
                return
            }
            if code == 416 {
                // Asked for from past the end of the file: its size is in the answer.
                if let size = DriveStream.total(response), size > 0 { total = size; notes.sized(size) }
                byTask[dataTask.taskIdentifier] = nil
                piece.task = nil
                answer(.cancel)
                if total != nil { drop(piece); feed() } else { gaveUp(piece, URLError(.badServerResponse)) }
                return
            }
            // Anything else: Google's reason is read in full first (its body), then acted on when it's done.
            piece.status = code
            answer(.allow)
            return
        }
        if code == 200 {
            // The whole file instead of the piece: that only fits a piece from the file's very start.
            guard piece.end == 0 else {
                byTask[dataTask.taskIdentifier] = nil
                piece.task = nil
                answer(.cancel)
                gaveUp(piece, URLError(.badServerResponse))
                return
            }
            if total == nil, response.expectedContentLength > 0 { total = response.expectedContentLength }
        }
        if let size = DriveStream.total(response), size > 0 { total = size }
        if let size = total { notes.sized(size) }
        if mime == nil { mime = DriveStream.mime(response) }
        // A file Apple's player can't open: said at once, instead of the player reading on before giving up.
        if unplayable == nil, let why = DriveStream.unplayable(mime) {
            unplayable = why
            answer(.cancel)
            let all = wants, f = GoogleDrive.Failure(why)
            cancelAll()
            failure.set(f)
            for want in all where !want.request.isCancelled && !want.request.isFinished { want.request.finishLoading(with: f) }
            return
        }
        answer(.allow)
        // What the file is can be said now.
        feed()
    }

    func received(_ dataTask: URLSessionDataTask, data: Data) {
        guard let piece = byTask[dataTask.taskIdentifier] else { return }
        if piece.status != 0 {
            if piece.body.count < 16_384 { piece.body.append(data) }
            return
        }
        let room = max(0, piece.limit - piece.end)
        if Int64(data.count) > room {
            // More than was asked for (Google sending the whole file instead of the piece): only what was asked for
            // is kept, and the rest isn't waited for.
            piece.data.append(data.prefix(Int(room)))
            notes.got(room)
            byTask[dataTask.taskIdentifier] = nil
            StreamRouter.shared.handlers[dataTask.taskIdentifier] = nil
            dataTask.cancel()
            arrived(piece)
            return
        }
        piece.data.append(data)
        notes.got(Int64(data.count))
        feed()
    }

    func completed(_ task: URLSessionTask, error: Error?) {
        guard let piece = byTask.removeValue(forKey: task.taskIdentifier) else { return }
        piece.task = nil
        if piece.status != 0 {
            refused(piece)
            return
        }
        // A slow or dropped connection (Google slow to start deep inside a big film, the Wi‑Fi hiccuping): what's
        // left of it is asked for again, instead of the film stopping with a timeout.
        if let e = error as? URLError, Loader.transient.contains(e.code), piece.attempts < 3 {
            piece.attempts += 1
            again(piece, after: 0.5 * Double(piece.attempts))
            return
        }
        if let error { gaveUp(piece, error); return }
        arrived(piece)
    }

    /// [piece] is in (all of it, or as much as Google sent before the file ended).
    private func arrived(_ piece: Piece) {
        piece.task = nil
        if piece.end < piece.limit {
            // Nothing at all, and not because the file ended there: said, rather than asked for again for ever.
            if piece.data.isEmpty, !(total.map { piece.offset >= $0 } ?? false) {
                gaveUp(piece, URLError(.zeroByteResource))
                return
            }
            // The file ended first (or Google stopped short): nothing more of it is expected.
            piece.asked = Int64(piece.data.count)
        }
        piece.fetching = false
        if piece.data.isEmpty { pieces.removeAll { $0 === piece } } else { store(piece) }
        trim()
        feed()
    }

    /// A whole piece goes into a file of its own and is read from there from then on. Kept that way it costs
    /// storage, not memory, so far more of the film can be kept (`onDisk`), and what the player reads a second
    /// time comes from here instead of being asked of Google again: on one film, 18 of the 21 GB asked of Google had
    /// been asked for before, with 600 MB the most that memory could keep. If a piece can't be written (the storage
    /// is full), it and the ones after it stay in memory, as they did.
    private func store(_ piece: Piece) {
        guard filing, let folder, piece.file == nil, !piece.storing, piece.data.count >= Loader.worthFiling else { return }
        piece.storing = true
        let bytes = piece.data
        let file = folder.appendingPathComponent(String(piece.offset))
        Loader.disk.async { [weak self] in
            var mapped: Data?
            do {
                try bytes.write(to: file)
                mapped = try Data(contentsOf: file, options: .alwaysMapped)
            } catch {
                try? FileManager.default.removeItem(at: file)
            }
            let read = mapped
            streamQueue.async {
                piece.storing = false
                guard let self, self.pieces.contains(where: { $0 === piece }) else {
                    // Let go of meanwhile, or the film is over.
                    try? FileManager.default.removeItem(at: file)
                    return
                }
                if let read, read.count == piece.data.count {
                    piece.data = read
                    piece.file = file
                    self.notes.filed(true)
                } else {
                    try? FileManager.default.removeItem(at: file)
                    self.filing = false
                    self.notes.filed(false)
                }
                self.trim()
            }
        }
    }

    /// [piece] is no longer kept: its file goes.
    private func unfile(_ piece: Piece) {
        guard let file = piece.file else { return }
        piece.file = nil
        Loader.disk.async { try? FileManager.default.removeItem(at: file) }
    }

    /// What's left of [piece] is asked for again after a moment.
    private func again(_ piece: Piece, after delay: Double) {
        streamQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.pieces.contains(where: { $0 === piece }), piece.fetching, piece.task == nil else { return }
            self.fetch(piece)
        }
    }

    /// [piece] can't be had: every request of the player's that was waiting for it is told why. What did arrive of
    /// it is kept.
    private func gaveUp(_ piece: Piece, _ error: Error) {
        guard pieces.contains(where: { $0 === piece }) else { return }   // let go meanwhile
        let from = piece.end, to = piece.limit
        piece.task = nil
        piece.fetching = false
        piece.asked = Int64(piece.data.count)
        if piece.data.isEmpty { pieces.removeAll { $0 === piece } }
        for want in wants where want.at >= from && want.at < max(to, from + 1) { fail(want, error) }
        feed()
    }

    /// Lets go of [piece], whatever of it has arrived.
    private func drop(_ piece: Piece) {
        if let t = piece.task {
            byTask[t.taskIdentifier] = nil
            StreamRouter.shared.handlers[t.taskIdentifier] = nil
            t.cancel()
        }
        piece.task = nil
        piece.fetching = false
        pieces.removeAll { $0 === piece }
        unfile(piece)
    }

    /// Google refused a piece. Busy (its rate limits, a server error): asked again after a growing pause. A file it
    /// flagged: asked again with that acknowledged. Anything else (its daily limit for the file, say): the player is
    /// told Google's reason, which is what's shown.
    private func refused(_ piece: Piece) {
        let code = piece.status, reason = GoogleDrive.reason(piece.body)
        let what = "Drive answered \(code)" + (reason.isEmpty ? "" : " (\(reason))") + (name.isEmpty ? "" : " for \(name)")
            + ", asked for \(max(1, (piece.limit - piece.end) >> 20)) MB"
        Task { @MainActor in Diagnostics.shared.notePlayback(what) }
        let busy = code == 429 || code >= 500 || ["rateLimitExceeded", "userRateLimitExceeded", "backendError", "internalError"].contains(reason)
        if busy, piece.busy < 4 {
            piece.busy += 1
            again(piece, after: pow(2, Double(piece.busy - 1)))
            return
        }
        if reason == "cannotDownloadAbusiveFile", !acknowledge {
            acknowledge = true
            again(piece, after: 0)
            return
        }
        let f = GoogleDrive.failure(code, piece.body)
        notes.refuse(f.message, limit: reason == "downloadQuotaExceeded")
        gaveUp(piece, f)
    }

    /// Keeps what's held within what it may be: the pieces in files within `onDisk`, the whole ones still in memory
    /// (being written to their files, too small for one, or with no files to go to) within `keepNow`.
    private func trim() {
        var filed: Int64 = 0, loose: Int64 = 0, all: Int64 = 0
        for p in pieces {
            let n = Int64(p.data.count)
            all += n
            if p.file != nil { filed += n } else if !p.fetching { loose += n }
        }
        notes.keeping(all)
        if filed > Loader.onDisk { release(to: Loader.onDisk, filed: true) }
        if loose > keepNow { release(to: keepNow, filed: false) }
    }

    /// Lets go of what `StreamKeep` picks among the pieces in files ([filed]) or the whole ones in memory, so that
    /// they fit [budget]: what the film has gone past goes first, then what's furthest ahead of the place that will
    /// come to it; never a piece that one of the player's requests is reading or about to.
    private func release(to budget: Int64, filed: Bool) {
        var parts: [StreamKeep.Part] = []
        var which: [Int] = []
        for (i, p) in pieces.enumerated() {
            guard !p.fetching, (p.file != nil) == filed else { continue }
            let reading = wants.contains(where: { p.offset <= $0.at && $0.at <= p.limit })
            parts.append(StreamKeep.Part(offset: p.offset, length: Int64(p.data.count),
                                         used: p.used.timeIntervalSince1970, busy: reading))
            which.append(i)
        }
        let picked = StreamKeep.letGo(parts, places: readingAt(), budget: budget, back: Loader.behind)
        guard !picked.isEmpty else { return }
        let going = Set(picked.map { which[$0] })
        var kept: [Piece] = []
        kept.reserveCapacity(pieces.count)
        for (i, p) in pieces.enumerated() {
            if going.contains(i) { unfile(p) } else { kept.append(p) }
        }
        pieces = kept
    }
}
