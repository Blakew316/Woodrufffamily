import Foundation
import SwiftUI
import WoodruffKit

/// A file saved by the app, read and decoded off the main thread as the app opens, so the first page that needs it
/// doesn't wait for it. Whoever needs it first takes it if it's ready, else reads it then as before.
final class EarlyRead<T: Decodable>: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private var taken = false
    private var value: T?

    init(_ url: URL) {
        Task.detached(priority: .utility) { [self] in
            let v = try? JSONDecoder().decode(T.self, from: Data(contentsOf: url, options: .mappedIfSafe))
            lock.lock()
            if !taken { value = v; done = true }
            lock.unlock()
        }
    }

    /// The decoded file (nil inside: no file, or not readable) once it's ready; nil when it isn't yet.
    func take() -> T?? {
        lock.lock()
        defer { lock.unlock() }
        taken = true
        guard done else { return nil }
        let v = value
        value = nil
        return .some(v)
    }
}

/// Saved files written off the main thread, one after another in the order asked (so an older copy never lands
/// after a newer one). `waitForWrites` holds until they're all on disk (the app going to the background).
enum DiskWriter {
    private static let queue = DispatchQueue(label: "com.woodruff.family.disk", qos: .utility)

    static func write<T: Encodable>(_ value: T, to url: URL) {
        queue.async {
            if let d = try? JSONEncoder().encode(value) { try? d.write(to: url, options: .atomic) }
        }
    }

    static func waitForWrites() { queue.sync {} }
}

/// The Watch folder in Application Support, where the library and TMDB's answers are kept.
func watchFile(_ name: String) -> URL {
    #if os(tvOS)
    // Apple TV keeps an app's files only in Caches (writing elsewhere fails): the library was never kept, so every
    // launch read the whole Drive library again.
    let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Watch", isDirectory: true)
    #else
    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Watch", isDirectory: true)
    #endif
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent(name)
}

/// Where Watch's titles come from: the TV (as it always has) or the app's own Google Drive library. Watch asks the
/// same questions of either and gets the same answers, so it looks and works the same; Settings → Watch picks one.
@MainActor
protocol WatchSource {
    var sourceID: String { get }
    func watchHome() async throws -> WatchHome
    func library(place: String, sort: String, unwatched: Bool, genre: String?, q: String?, offset: Int, limit: Int) async throws -> LibraryPage
    func search(_ q: String) async throws -> SearchResults
    func title(_ id: String) async throws -> TitleDetails
    func episodes(show: String, season: String) async throws -> EpisodeList
    func markWatched(_ keys: [String], _ on: Bool) async throws
    func removeContinue(key: String, title: String) async throws
    func artURL(_ s: String?, small: Bool) -> URL?
}

extension WatchSource {
    func artURL(_ s: String?) -> URL? { artURL(s, small: false) }
    func library(place: String, sort: String, unwatched: Bool, genre: String?, q: String?, offset: Int) async throws -> LibraryPage {
        try await library(place: place, sort: sort, unwatched: unwatched, genre: genre, q: q, offset: offset, limit: 60)
    }
}

extension TVClient: WatchSource {
    var sourceID: String { hub.id }
    func artURL(_ s: String?, small: Bool) -> URL? { art(s, small: small) }
}

@MainActor
enum WatchSources {
    /// "tv" (the default) or "drive", from Settings → Watch.
    static var choice: String { UserDefaults.standard.string(forKey: "watch.source") ?? "tv" }

    /// The one Watch uses now: the Drive library when it's chosen and signed in, else the TV.
    static func current(_ fleet: Fleet) -> (any WatchSource)? {
        #if os(tvOS)
        // Apple TV plays everything itself: the Drive library (kept here, so Watch opens at once) whenever it's
        // signed in, not a TV that may be asleep.
        if GoogleDrive.signedIn { return DriveLibrary.shared }
        #endif
        if choice == "drive", GoogleDrive.signedIn { return DriveLibrary.shared }
        return fleet.hubClient()
    }

    static var usesDrive: Bool {
        #if os(tvOS)
        return GoogleDrive.signedIn
        #else
        return choice == "drive" && GoogleDrive.signedIn
        #endif
    }
}

/// The family's films and shows read straight from Google Drive (the "Movies" and "TV Shows" folders, as the TVs
/// read them), filled in from TMDB, and kept on this device so Watch opens at once and works with no connection.
/// Where each one was left off is kept here too.
@Observable @MainActor
final class DriveLibrary: WatchSource {
    static let shared = DriveLibrary()
    nonisolated var sourceID: String { "drive" }

    /// One film, collection or show.
    struct Entry: Codable, Hashable {
        var id: String          // its Drive file or folder
        var kind: String        // "movie", "collection" or "show"
        var name: String        // as named in Drive
        var title: String
        var year: Int?
        var poster: String?
        var backdrop: String?
        var genres: [String] = []
        var rating: Double?
        var overview: String?
        var tmdb: Int?
        var added: Double       // ms
        var file: String?       // a film's video

        enum CodingKeys: String, CodingKey { case id, kind, name, title, year, poster, backdrop, genres, rating, overview, tmdb, added, file }
    }

    /// Where a title was left off ("drive:<file>" → it).
    struct Spot: Codable, Hashable {
        var title: String       // what the player showed
        var pos: Double         // ms
        var dur: Double         // ms
        var at: Double          // ms
        var next: Bool = false  // the next episode, not started
        var titleId: String?
        var kind: String?       // "movie" or "show"
        var name: String?       // the film's or show's name
        var code: String?       // "S2 E4"
        var episode: String?
        var poster: String?

        enum CodingKeys: String, CodingKey { case title, pos, dur, at, next, titleId, kind, name, code, episode, poster }
    }

    fileprivate struct Saved: Codable {
        var movies: [Entry] = []
        var shows: [Entry] = []
        var updated: Double?
        var folders: [String: [GoogleDrive.File]] = [:]
        var spots: [String: Spot] = [:]
        var watched: [String: Double] = [:]
        /// Taken off Continue Watching (ms), and ✓ taken off: shared with the TVs like the rest.
        var gone: [String: Double] = [:]
        var unwatched: [String: Double] = [:]
        /// This device's progress file in Drive's hidden app folder.
        var syncFile: String?
        var synced: Double?

        enum CodingKeys: String, CodingKey { case movies, shows, updated, folders, spots, watched, gone, unwatched, syncFile, synced }
    }

    private var saved: Saved
    private(set) var busy = false
    private(set) var error: String?
    @ObservationIgnored private var refreshing: Task<Void, Never>?
    @ObservationIgnored private var storing: Task<Void, Never>?
    @ObservationIgnored private var filling = false
    /// This device's progress changed since it was last uploaded for the TVs.
    @ObservationIgnored private var unsynced = true
    /// Progress keys from a TV that no film or show here owns (not asked about again until the library is read).
    @ObservationIgnored private var unresolved: Set<String> = []
    /// Each title's names for searching and sorting, worked out once per title.
    @ObservationIgnored private var named: [String: Names] = [:]
    private struct Names { var title: String; var norm: String; var sort: String }
    private let file = watchFile("library.json")
    /// The library as read off the main thread at launch (`prewarm`).
    nonisolated private static let early = EarlyRead<Saved>(watchFile("library.json"))
    /// Starts reading the saved library in the background, ahead of Watch.
    nonisolated static func prewarm() {
        _ = early
        // Watch's rows as last shown (either library's), so Watch opens with them.
        ShelfStore.prewarm()
    }

    var titleCount: Int { saved.movies.count + saved.shows.count }
    var updated: Date? { saved.updated.map { Date(timeIntervalSince1970: $0 / 1000) } }

    private init() {
        if let ready = Self.early.take() {
            saved = ready ?? Saved()
        } else {
            saved = (try? JSONDecoder().decode(Saved.self, from: Data(contentsOf: file))) ?? Saved()
        }
    }

    /// Written a couple of seconds after the last change (the player reports every 10 seconds).
    private func store() {
        guard storing == nil else { return }
        storing = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self else { return }
            self.storing = nil
            DiskWriter.write(self.saved, to: self.file)
        }
    }

    /// Written now (the player closing, the app going to the background). [wait] false only queues it (still written in
    /// order, straight away): the Apple TV's player closing, so the page it goes back to isn't held up meanwhile.
    func flush(wait: Bool = true) {
        storing?.cancel()
        storing = nil
        DiskWriter.write(saved, to: file)
        // The app leaving (and a film stopping on iPhone and Mac): on disk before this returns, as before.
        if wait { DiskWriter.waitForWrites() }
    }

    // MARK: Reading Drive

    /// Reads the folders again (at most every 10 minutes unless asked), then fills in from TMDB.
    func refresh(force: Bool = false) async {
        if let r = refreshing { await r.value; return }
        if !force, let u = saved.updated, Date().timeIntervalSince1970 * 1000 - u < 600_000, !saved.movies.isEmpty || !saved.shows.isEmpty { return }
        let t = Task { await self.read() }
        refreshing = t
        await t.value
        refreshing = nil
    }

    private func read() async {
        guard GoogleDrive.signedIn else { return }
        busy = true
        defer { busy = false }
        do {
            let moviesID = try await GoogleDrive.findFolder(["Movies", "Movie", "Films"])
            let showsID = try await GoogleDrive.findFolder(["TV Shows", "TV shows", "TV", "Shows", "Series"])
            guard moviesID != nil || showsID != nil else {
                if GoogleDrive.email == nil { await GoogleDrive.loadEmail() }
                let who = GoogleDrive.email.map { "\($0)’s Drive" } ?? "this Google Drive"
                if !GoogleDrive.canReadFiles {
                    throw GoogleDrive.Failure("Google didn’t give the app access to your Drive files. Sign Out, sign in again, and on Google’s screen tick “See and download all your Google Drive files”.")
                }
                let seen = await GoogleDrive.topFolders()
                throw GoogleDrive.Failure("No “Movies” or “TV Shows” folder in \(who)." + (seen.isEmpty
                    ? " The app can’t see any folders there: sign out and sign in again, ticking the Drive box on Google’s screen, or use the account the TVs use."
                    : " Folders it can see: \(seen.joined(separator: ", ")). If that’s the wrong account, sign out and sign in with the one the TVs use."))
            }
            var movies: [Entry] = [], shows: [Entry] = []
            previous = Dictionary((saved.movies + saved.shows).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            defer { previous = [:] }
            if let m = moviesID { movies = try await films(in: m) }
            if let s = showsID {
                let list = try await GoogleDrive.children(s)
                shows = list.filter(\.isFolder).map { f in
                    let p = TitleNames.parse(f.name, stripExtension: false)
                    return keep(Entry(id: f.id, kind: "show", name: f.name, title: p.title, year: p.year, added: f.added))
                }
            }
            saved.movies = movies
            saved.shows = shows
            saved.updated = Date().timeIntervalSince1970 * 1000
            error = nil
            unresolved = []
            store()
            // The posters and stories come in behind: the library shows now.
            Task { await self.fill() }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// The titles as before this read, by id (each title read is matched to its old self in one step, not by looking
    /// through the whole library for every one).
    @ObservationIgnored private var previous: [String: Entry] = [:]

    /// What TMDB already said about [e], kept from the last read.
    private func keep(_ e: Entry) -> Entry {
        // Looked up again when the title read from its name changed (a "Blade Runner 2049" once read as "Blade Runner").
        guard let old = previous[e.id], old.name == e.name, old.title == e.title else { return e }
        var n = e
        n.poster = old.poster; n.backdrop = old.backdrop; n.genres = old.genres; n.rating = old.rating
        n.overview = old.overview; n.tmdb = old.tmdb; n.year = e.year ?? old.year
        return n
    }

    /// The Movies folder: each video a film; each folder a film (its one video, or its biggest when that's at least
    /// twice the next) or a collection.
    private func films(in folder: String) async throws -> [Entry] {
        let list = try await GoogleDrive.children(folder)
        var out: [Entry] = []
        for f in list where f.isVideo {
            let p = TitleNames.parse(f.name, stripExtension: true)
            out.append(keep(Entry(id: f.id, kind: "movie", name: f.name, title: p.title, year: p.year, added: f.added, file: f.id)))
        }
        // Each film's folder listed eight at a time (one after another, a library of a few hundred took minutes on a
        // fresh install, with Watch empty until it was done).
        let folders = list.filter(\.isFolder)
        var listed: [String: [GoogleDrive.File]] = [:]
        try await withThrowingTaskGroup(of: (String, [GoogleDrive.File]).self) { group in
            for (i, f) in folders.enumerated() {
                if i >= 8, let done = try await group.next() { listed[done.0] = done.1 }
                let id = f.id
                group.addTask {
                    let inside = try await GoogleDrive.children(id)
                    return (id, inside)
                }
            }
            for try await done in group { listed[done.0] = done.1 }
        }
        for f in folders {
            guard let inside = listed[f.id] else { continue }
            saved.folders[f.id] = inside
            let videos = inside.filter(\.isVideo).sorted { $0.bytes > $1.bytes }
            guard !videos.isEmpty else { continue }
            let p = TitleNames.parse(f.name, stripExtension: false)
            let one = videos.count == 1 || videos[0].bytes >= 2 * videos[1].bytes
            out.append(keep(Entry(id: f.id, kind: one ? "movie" : "collection", name: f.name, title: p.title, year: p.year,
                                  added: f.added, file: one ? videos[0].id : nil)))
        }
        return out
    }

    /// TMDB's poster, story, year, genres and rating for each title not looked up yet.
    /// Asked all at once (TMDB takes six at a time).
    private func fill() async {
        guard !filling else { return }
        filling = true
        defer { filling = false }
        // The newest first: they're the banner and the first rows.
        let todo = (saved.movies + saved.shows).filter { $0.tmdb == nil }.sorted { $0.added > $1.added }
        guard !todo.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            for e in todo { group.addTask { await self.lookUp(e) } }
            // Watch reads its rows again as the posters come in (every 24 answers), not ten minutes later.
            var answered = 0
            for await _ in group {
                answered += 1
                if answered % 24 == 0 { filledAt = nowMS }
            }
        }
        filledAt = nowMS
        store()
    }

    /// When TMDB's answers last came in (part of Watch home's `updated`, so Watch reads its rows again).
    @ObservationIgnored private var filledAt: Double?
    /// TMDB's answers are coming in (Watch asks again sooner meanwhile).
    var isFilling: Bool { filling }

    /// One title's answer from TMDB, kept by its id (the list may have been read again meanwhile).
    private func lookUp(_ e: Entry) async {
        guard let hit = await TMDB.shared.find(TitleNames.searchTitle(e.title), year: e.year, tv: e.kind == "show") else { return }
        func apply(_ x: inout Entry) {
            x.tmdb = hit.id; x.poster = hit.poster; x.backdrop = hit.backdrop
            x.genres = hit.genres; x.rating = hit.rating; x.overview = hit.overview
            if x.year == nil { x.year = hit.year }
        }
        if let i = saved.movies.firstIndex(where: { $0.id == e.id }) {
            apply(&saved.movies[i])
        } else if let i = saved.shows.firstIndex(where: { $0.id == e.id }) {
            apply(&saved.shows[i])
        }
    }

    /// A folder's contents: as kept when Drive can't be reached (offline), else read again and kept.
    private func folder(_ id: String) async -> [GoogleDrive.File] {
        if let fresh = try? await GoogleDrive.children(id) {
            saved.folders[id] = fresh
            store()
            return fresh
        }
        return saved.folders[id] ?? []
    }

    /// Drive's file [id] as it was last listed (its name and type), when it was.
    func listedFile(_ id: String) -> GoogleDrive.File? {
        for files in saved.folders.values {
            if let f = files.first(where: { $0.id == id }) { return f }
        }
        return nil
    }

    private func entry(_ id: String) -> Entry? { saved.movies.first(where: { $0.id == id }) ?? saved.shows.first(where: { $0.id == id }) }

    /// A title's story as TMDB told it (nil until it's been looked up).
    func overview(_ id: String) -> String? { entry(id)?.overview }

    /// The picture to show while [key] starts playing: its title's backdrop, else its poster.
    func art(for key: String) -> URL? {
        let s = saved.spots[key] ?? context[key]
        let e = s?.titleId.flatMap { entry($0) }
        return artURL(e?.backdrop ?? s?.poster ?? e?.poster, small: false)
    }

    // MARK: Where things were left off

    private var nowMS: Double { Date().timeIntervalSince1970 * 1000 }

    /// The player's report while something plays here, and when it stops.
    func played(_ key: String, title: String, pos: Double, dur: Double) {
        guard key.hasPrefix("drive:") else { return }
        var s = saved.spots[key] ?? context[key] ?? Spot(title: title, pos: 0, dur: 0, at: 0)
        // A length not known this time (the player hadn't read it) keeps the one known before.
        s.pos = pos; s.at = nowMS; s.next = false
        if dur > 0 { s.dur = dur }
        let done = s.dur > 0 && (s.dur - pos < 5_000 || pos >= 0.95 * s.dur)
        if done {
            saved.spots[key] = nil
            saved.gone[key] = nowMS
            saved.watched[key] = nowMS
            saved.unwatched[key] = nil
            upNext(after: key)
        } else if pos > 0 {
            saved.spots[key] = s
        }
        unsynced = true
        // The whole library is written each time, and the player reports every 10 seconds: once a minute while it
        // plays (its stop writes it at once, as the app leaving does).
        if done || Date().timeIntervalSince(playWritten) >= 60 {
            playWritten = Date()
            store()
        }
    }
    /// When a play's place was last written to disk.
    @ObservationIgnored private var playWritten = Date.distantPast

    /// Plays on this device that have stopped, counted: Watch shows where each was left off as soon as one stops
    /// (Continue Watching), not on its next look a minute later.
    private(set) var stoppedHere = 0
    func playStopped() { stoppedHere += 1 }

    /// Where [key] was left off as kept now (ms), when it's part way through: the newest of this device's plays and
    /// the TVs'. A page's Resume can carry an older place (read before the last play here, or the TVs' last word).
    func resumePosition(_ key: String) -> Double? {
        guard let s = saved.spots[key], !s.next, s.pos > 0, s.dur <= 0 || s.pos / s.dur < 0.95 else { return nil }
        return s.pos
    }

    /// What a play started here is part of (its show, its episode), for Continue Watching.
    @ObservationIgnored private var context: [String: Spot] = [:]

    /// The episode after [key] in its season, as the next one to watch.
    private func upNext(after key: String) {
        guard let s = context[key] ?? saved.spots[key], s.kind == "show",
              let list = seasonLists.first(where: { $0.value.contains(key) })?.value,
              let i = list.firstIndex(of: key), i + 1 < list.count else { return }
        let next = list[i + 1]
        guard saved.spots[next] == nil, var c = context[next] else { return }
        c.pos = 0; c.dur = 0; c.at = nowMS; c.next = true
        saved.spots[next] = c
    }
    /// Each season's episodes in order, as last listed.
    @ObservationIgnored private var seasonLists: [String: [String]] = [:]

    private func progress(_ key: String) -> (pos: Double, dur: Double) {
        let s = saved.spots[key]
        return (s?.pos ?? 0, s?.dur ?? 0)
    }

    func markWatched(_ keys: [String], _ on: Bool) async throws {
        for k in keys {
            if on {
                saved.watched[k] = nowMS; saved.unwatched[k] = nil
                if saved.spots[k] != nil { saved.spots[k] = nil; saved.gone[k] = nowMS }
            } else {
                saved.watched[k] = nil; saved.unwatched[k] = nowMS
            }
        }
        unsynced = true
        store()
        Task { await sync() }
    }

    func removeContinue(key: String, title: String) async throws {
        let show = saved.spots[key]?.titleId
        for (k, s) in saved.spots where k == key || (show != nil && s.titleId == show) { saved.spots[k] = nil; saved.gone[k] = nowMS }
        unsynced = true
        store()
        Task { await sync() }
    }

    // MARK: Answers in Watch's shapes (the TV's JSON)

    private func decode<T: Decodable>(_ v: Any) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: v))
    }

    private func duration(_ ms: Double) -> String {
        let m = Int(ms / 60_000)
        return m >= 60 ? "\(m / 60)h \(String(format: "%02d", m % 60))m" : "\(max(1, m))m"
    }

    /// A film's Play: from where it was left off (unless nearly done).
    /// Part watched: in Continue Watching, and Resume with Start Over on its title's page. One rule for both (a spot
    /// whose length isn't known yet counts: Continue Watching showed it while its page offered only Play).
    private func resumable(_ pos: Double, _ dur: Double) -> Bool { pos > 10_000 && (dur <= 0 || pos / dur < 0.95) }

    private func filmPlay(_ e: Entry) -> [String: Any]? {
        guard let f = e.file else { return nil }
        let key = "drive:\(f)"
        context[key] = Spot(title: e.title, pos: 0, dur: 0, at: 0, titleId: e.id, kind: "movie", name: e.title, poster: e.poster)
        let (pos, dur) = progress(key)
        let resume = resumable(pos, dur)
        var p: [String: Any] = ["key": key, "title": e.title, "position": resume ? pos : 0,
                                "label": resume ? "Resume from \(duration(pos))" : "Play", "resume": true]
        if dur > 0 { p["duration"] = dur }
        return p
    }

    private func titleJSON(_ e: Entry) -> [String: Any] {
        var t: [String: Any] = ["id": e.id, "kind": e.kind == "show" ? "show" : "movie", "title": e.title, "genres": e.genres, "added": e.added]
        if let y = e.year { t["year"] = y }
        if let p = e.poster { t["poster"] = p }
        if let b = e.backdrop { t["backdrop"] = b }
        if let r = e.rating { t["rating"] = r }
        if e.kind != "show" {
            t["watched"] = e.file.map { saved.watched["drive:\($0)"] != nil } ?? false
            if let p = filmPlay(e) { t["play"] = p }
        } else if let go = showResume(e.id), let p = continuePlay(go.key, go.spot) {
            t["play"] = p
        }
        return t
    }

    /// The newest spot in [show] to go on with.
    private func showResume(_ show: String) -> (key: String, spot: Spot)? {
        saved.spots.filter { $0.value.titleId == show && ($0.value.next || ($0.value.dur > 0 && $0.value.pos / $0.value.dur >= 0.02 && $0.value.pos / $0.value.dur < 0.97)) }
            .max { $0.value.at < $1.value.at }.map { ($0.key, $0.value) }
    }

    private func continuePlay(_ key: String, _ s: Spot) -> [String: Any]? {
        var p: [String: Any] = ["key": key, "title": s.title, "position": s.next ? 0 : s.pos, "resume": true]
        if s.dur > 0 { p["duration"] = s.dur }
        if s.kind == "show" {
            p["label"] = s.next ? (s.code.map { "Play \($0)" } ?? "Play Next Episode") : (s.code.map { "Resume \($0)" } ?? "Resume")
        } else {
            p["label"] = s.pos > 10_000 ? "Resume from \(duration(s.pos))" : "Play"
        }
        return p
    }

    private func continueItems() -> [[String: Any]] {
        var seen = Set<String>()
        var out: [[String: Any]] = []
        let live = saved.spots.filter { $0.value.next || resumable($0.value.pos, $0.value.dur) }
        for (key, s) in live.sorted(by: { $0.value.at > $1.value.at }) {
            let group = s.titleId ?? key
            guard seen.insert(group).inserted, let play = continuePlay(key, s) else { continue }
            var c: [String: Any] = ["key": key, "playTitle": s.title, "kind": s.kind ?? "movie", "name": s.name ?? s.title,
                                    "position": s.next ? 0 : s.pos, "duration": s.dur, "upNext": s.next, "drive": true, "play": play]
            if let t = s.titleId { c["titleId"] = t }
            if let v = s.code { c["code"] = v }
            if let v = s.episode { c["episode"] = v }
            if let v = s.poster ?? s.titleId.flatMap({ entry($0)?.poster }) { c["poster"] = v }
            if s.kind != "show", s.pos > 10_000 {
                var r = play; r["position"] = 0; r["label"] = "Start Over"; r["resume"] = nil
                c["restart"] = r
            }
            out.append(c)
            if out.count == 20 { break }
        }
        return out
    }

    // MARK: WatchSource

    func watchHome() async throws -> WatchHome {
        guard GoogleDrive.signedIn else { return try decode(["state": "notSignedIn"]) }
        if saved.movies.isEmpty && saved.shows.isEmpty {
            await refresh(force: true)
        } else {
            Task { await refresh() }
        }
        // The TVs' progress (and this device's to them), every couple of minutes while Watch is open.
        if nowMS - (saved.synced ?? 0) > 120_000 { Task { await sync() } }
        if saved.movies.isEmpty && saved.shows.isEmpty {
            if let e = error { throw GoogleDrive.Failure(e) }
            return try decode(["state": busy ? "loading" : "empty"])
        }
        // Only Continue Watching: Watch reads the banner and rows from the library a section at a time.
        let home: [String: Any] = ["state": "ready", "tv": "Google Drive", "updated": max(saved.updated ?? 0, filledAt ?? 0),
                                   "continue": continueItems()]
        return try decode(home)
    }

    func library(place: String, sort: String, unwatched: Bool, genre: String?, q: String?, offset: Int, limit: Int) async throws -> LibraryPage {
        var list = place == "shows" ? saved.shows : saved.movies
        if unwatched {
            let started = Set(saved.spots.values.compactMap(\.titleId))
            list = list.filter { e in
                if e.kind == "show" { return !started.contains(e.id) }
                guard let f = e.file else { return true }
                return saved.watched["drive:\(f)"] == nil
            }
        }
        if let g = genre, !g.isEmpty { list = list.filter { $0.genres.contains(g) } }
        if let q, !q.trimmingCharacters(in: .whitespaces).isEmpty { list = list.filter { matches($0, q) } }
        let key = sortKeys(list)
        func az(_ a: Entry, _ b: Entry) -> Bool { key[a.id, default: ""] < key[b.id, default: ""] }
        switch sort {
        case "recent", "newest": list.sort { $0.added != $1.added ? $0.added > $1.added : az($0, $1) }
        case "year": list.sort { ($0.year ?? 0) != ($1.year ?? 0) ? ($0.year ?? 0) > ($1.year ?? 0) : az($0, $1) }
        case "rated": list.sort { ($0.rating ?? -1) != ($1.rating ?? -1) ? ($0.rating ?? -1) > ($1.rating ?? -1) : az($0, $1) }
        default: list.sort(by: az)
        }
        var counts: [String: Int] = [:]
        for e in (place == "shows" ? saved.shows : saved.movies) { for g in e.genres { counts[g, default: 0] += 1 } }
        let genres = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
        let page = list.dropFirst(offset).prefix(max(1, min(120, limit)))
        return try decode(["state": "ready", "count": list.count, "offset": offset, "items": page.map(titleJSON),
                           "genres": genres, "rated": saved.movies.contains { $0.rating != nil } || saved.shows.contains { $0.rating != nil }] as [String: Any])
    }

    /// A title's names for searching and sorting, worked out again only when its title changes.
    private func names(_ e: Entry) -> Names {
        if let n = named[e.id], n.title == e.title { return n }
        let n = Names(title: e.title, norm: TitleNames.normalize(e.title), sort: TitleNames.sortKey(e.title))
        named[e.id] = n
        return n
    }

    /// Each title's sort key, by id, for sorting [list].
    private func sortKeys(_ list: [Entry]) -> [String: String] {
        var out: [String: String] = [:]
        out.reserveCapacity(list.count)
        for e in list { out[e.id] = names(e).sort }
        return out
    }

    private func matches(_ e: Entry, _ q: String) -> Bool {
        matches(e, words: TitleNames.normalize(q).split(separator: " "))
    }

    private func matches(_ e: Entry, words: [Substring]) -> Bool {
        let t = names(e).norm
        return words.allSatisfy { w in t.contains(w) || (w.count == 4 && Int(w) == e.year) }
    }

    func search(_ q: String) async throws -> SearchResults {
        let words = TitleNames.normalize(String(q.prefix(60)))
        let each = TitleNames.normalize(q).split(separator: " ")
        func rank(_ e: Entry) -> Int {
            let n = names(e)
            if n.norm.hasPrefix(words) || n.sort.hasPrefix(words) { return 1 }
            if n.norm.split(separator: " ").contains(where: { $0.hasPrefix(words) }) { return 2 }
            return 3
        }
        func found(_ l: [Entry]) -> [Entry] {
            let hits = l.filter { matches($0, words: each) }
            var ranks: [String: Int] = [:]
            for e in hits { ranks[e.id] = rank(e) }
            let key = sortKeys(hits)
            return hits.sorted {
                let a = ranks[$0.id, default: 3], b = ranks[$1.id, default: 3]
                if a != b { return a < b }
                if ($0.rating ?? 0) != ($1.rating ?? 0) { return ($0.rating ?? 0) > ($1.rating ?? 0) }
                return key[$0.id, default: ""] < key[$1.id, default: ""]
            }.prefix(100).map { $0 }
        }
        let m = found(saved.movies), s = found(saved.shows)
        let first = (s.first.map(rank) ?? 9) < (m.first.map(rank) ?? 9) ? "shows" : "movies"
        return try decode(["state": "ready", "q": q, "first": first, "movies": m.map(titleJSON), "shows": s.map(titleJSON)] as [String: Any])
    }

    func title(_ id: String) async throws -> TitleDetails {
        guard let e = entry(id) else { throw GoogleDrive.Failure("That title isn’t in the Drive library any more.") }
        var t = titleJSON(e)
        t["kind"] = e.kind
        t.removeValue(forKey: "play")
        if let o = e.overview { t["overview"] = o }
        if let tm = e.tmdb, let d = await TMDB.shared.details(tm, tv: e.kind == "show") {
            if e.kind != "show", let r = d.runtime { t["runtime"] = r }
            if let a = d.ageRating { t["ageRating"] = a }
            t["cast"] = Array(d.cast.prefix(4))
        }
        switch e.kind {
        case "movie":
            if let p = filmPlay(e) {
                t["play"] = p
                if let pos = p["position"] as? Double, pos > 0 {
                    var r = p; r["position"] = 0; r["label"] = "Start Over"; r["resume"] = nil
                    t["restart"] = r
                }
                t["watchKey"] = p["key"]
            }
            t["watched"] = e.file.map { saved.watched["drive:\($0)"] != nil } ?? false
        case "collection":
            let videos = (await folder(e.id)).filter(\.isVideo).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            t["films"] = videos.map { v -> [String: Any] in
                let key = "drive:\(v.id)", p = TitleNames.parse(v.name, stripExtension: true)
                context[key] = Spot(title: p.title, pos: 0, dur: 0, at: 0, titleId: e.id, kind: "movie", name: p.title, poster: e.poster)
                let (pos, dur) = progress(key)
                return ["key": key, "playTitle": p.title, "name": p.title, "special": false, "position": pos, "duration": dur,
                        "watched": saved.watched[key] != nil, "upNext": false, "new": false]
            }
        default:
            let seasons = await seasons(of: e)
            t["seasons"] = seasons.map { ["id": $0.id, "name": $0.name] }
            let go = showResume(e.id)
            // The season to open: the one being watched, else the first numbered one.
            var index = seasons.firstIndex { s in go.map { g in seasonLists[s.id]?.contains(g.key) == true } ?? false }
            if index == nil { index = seasons.firstIndex { ($0.number ?? 1) >= 1 } }
            t["season"] = index ?? 0
            if let go, let p = continuePlay(go.key, go.spot) {
                t["play"] = p
                t["playName"] = [go.spot.code, go.spot.episode].compactMap { $0 }.joined(separator: " · ")
            } else if let s = seasons[safe: index ?? 0] {
                let eps = try await episodeList(e, season: s)
                if let first = eps.first, let key = first["key"] as? String {
                    let code = first["code"] as? String
                    let title: Any = first["playTitle"] ?? e.title
                    t["play"] = ["key": key, "title": title, "position": 0,
                                 "label": code.map { "Play \($0)" } ?? "Play First Episode", "resume": true] as [String: Any]
                }
            }
        }
        return try decode(t)
    }

    private struct SeasonFolder { var id: String; var name: String; var number: Int? }

    private func seasons(of show: Entry) async -> [SeasonFolder] {
        let inside = await folder(show.id)
        let folders = inside.filter(\.isFolder)
        if folders.isEmpty { return inside.contains(where: \.isVideo) ? [SeasonFolder(id: "inside", name: "Episodes", number: nil)] : [] }
        return folders.map { SeasonFolder(id: $0.id, name: $0.name, number: TitleNames.seasonNumber($0.name)) }
    }

    func episodes(show: String, season: String) async throws -> EpisodeList {
        guard let e = entry(show) else { throw GoogleDrive.Failure("That show isn’t in the Drive library any more.") }
        let s = (await seasons(of: e)).first { $0.id == season } ?? SeasonFolder(id: season, name: "", number: nil)
        return try decode(["state": "ready", "episodes": try await episodeList(e, season: s)] as [String: Any])
    }

    private func episodeList(_ show: Entry, season: SeasonFolder) async throws -> [[String: Any]] {
        let files = (await folder(season.id == "inside" ? show.id : season.id)).filter(\.isVideo)
        struct Ep { var file: GoogleDrive.File; var season: Int?; var number: Int? }
        var eps = files.map { f -> Ep in
            let n = TitleNames.episodeNumber(f.name, season: season.number)
            return Ep(file: f, season: n?.season ?? season.number, number: n?.number)
        }
        eps.sort { a, b in
            switch (a.number, b.number) {
            case let (x?, y?): return x != y ? x < y : a.file.name.localizedStandardCompare(b.file.name) == .orderedAscending
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.file.name.localizedStandardCompare(b.file.name) == .orderedAscending
            }
        }
        var meta: [Int: TMDB.EpisodeMeta] = [:]
        if let tm = show.tmdb, let n = eps.first(where: { $0.season != nil })?.season ?? season.number {
            meta = await TMDB.shared.season(tm, n)
        }
        let listKey = season.id == "inside" ? show.id : season.id
        seasonLists[listKey] = eps.map { "drive:\($0.file.id)" }
        let now = nowMS
        return eps.map { ep in
            let key = "drive:\(ep.file.id)"
            let m = ep.number.flatMap { meta[$0] }
            let code = ep.number.map { n in ep.season.map { "S\($0) E\(n)" } ?? "E\(n)" }
            let name = m?.name ?? TitleNames.nameAfterCode(ep.file.name) ?? ep.number.map { "Episode \($0)" } ?? (ep.file.name as NSString).deletingPathExtension
            let playTitle: String = {
                guard let s = ep.season, let n = ep.number else { return (ep.file.name as NSString).deletingPathExtension }
                return String(format: "%@ S%02dE%02d %@", show.title, s, n, m?.name ?? "").trimmingCharacters(in: .whitespaces)
            }()
            context[key] = Spot(title: playTitle, pos: 0, dur: 0, at: 0, titleId: show.id, kind: "show", name: show.title,
                                code: code, episode: name, poster: show.poster)
            let spot = saved.spots[key]
            let watched = saved.watched[key] != nil
            var d: [String: Any] = ["key": key, "playTitle": playTitle, "name": name, "special": ep.season == 0,
                                    "position": spot?.next == true ? 0 : (spot?.pos ?? 0), "duration": spot?.dur ?? 0,
                                    "watched": watched, "upNext": spot?.next ?? false,
                                    "new": !watched && ep.file.added > 0 && now - ep.file.added < 30 * 86_400_000 && (spot?.pos ?? 0) == 0]
            if let c = code { d["code"] = c }
            if let n = ep.number { d["number"] = n }
            if let o = m?.overview { d["overview"] = o }
            if let s = m?.still { d["still"] = s }
            if let r = m?.runtime { d["runtime"] = r }
            return d
        }
    }

    /// A few other films' files than [id], from across the library (to see whether Google refuses only one file or
    /// all of them).
    func otherFiles(than id: String) -> [(id: String, title: String)] {
        var all: [(id: String, title: String)] = []
        for e in saved.movies {
            if let file = e.file, file != id { all.append((file, e.title)) }
        }
        guard all.count > 3 else { return all }
        return [all[0], all[all.count / 2], all[all.count - 1]]
    }

    /// The app's own copies of films are looked through once each launch (`GoogleDrive.removeOldCopies`).
    @ObservationIgnored private var copiesLookedAt = false

    /// Once each launch, for the Macs' log: which Google account this app reads Drive as, and whether the films are
    /// that account's own. Google only sends an account so much of someone else's file in a day; the account that
    /// owns it meets no such limit.
    private func noteAccount() async {
        if GoogleDrive.email == nil { await GoogleDrive.loadEmail() }
        guard let file = saved.movies.first(where: { $0.file != nil })?.file,
              let whose = await GoogleDrive.ownership(of: file) else { return }
        let me = GoogleDrive.email ?? "an account Google didn’t name"
        let films = whose.mine ? "the films are its own" : "the films are in \(whose.owner.map { "\($0)’s" } ?? "another account’s") Drive"
        Diagnostics.shared.notePlayback("Google Drive is read as \(me); \(films)")
    }

    nonisolated func artURL(_ s: String?, small: Bool) -> URL? {
        guard var s, s.hasPrefix("http") else { return nil }
        if small { s = s.replacingOccurrences(of: "/t/p/w1280/", with: "/t/p/w300/") }
        return URL(string: s)
    }

    // MARK: Sharing progress with the TVs (their FamilySync files in Drive's hidden app folder)

    @ObservationIgnored private var syncing = false

    /// Reads every TV's progress file, merges them in (per title the newest wins; a removal at least as new as the
    /// progress takes it away), then writes this device's file for the TVs to read.
    func sync() async {
        guard GoogleDrive.signedIn, !syncing else { return }
        syncing = true
        defer { syncing = false }
        do {
            let list = try await GoogleDrive.get(appDataList())
            let files = (list["files"] as? [[String: Any]] ?? []).compactMap { f -> (id: String, name: String)? in
                guard let id = f["id"] as? String, let name = f["name"] as? String else { return nil }
                return (id, name)
            }
            let mine = "woodruff-app-\(deviceID).json"
            if saved.syncFile == nil { saved.syncFile = files.first { $0.name == mine }?.id }
            var others: [[String: Any]] = []
            for f in files where f.name != mine && f.name.hasPrefix("woodruff-") && f.name.hasSuffix(".json") {
                if let j = try? await download(f.id) { others.append(j) }
            }
            merge(others)
            // Uploaded only when something here changed (or there's no file yet).
            if unsynced || saved.syncFile == nil {
                unsynced = false
                do { saved.syncFile = try await upload(mine) } catch { unsynced = true; throw error }
            }
            saved.synced = nowMS
            if !copiesLookedAt {
                copiesLookedAt = true
                Task {
                    await GoogleDrive.removeOldCopies()
                    await self.noteAccount()
                }
            }
            store()
            await resolveContexts()
        } catch {
            // Tried again next time Watch opens or something stops playing.
        }
    }

    private var deviceID: String {
        if let d = UserDefaults.standard.string(forKey: "watch.deviceID") { return d }
        let d = UUID().uuidString.lowercased()
        UserDefaults.standard.set(d, forKey: "watch.deviceID")
        return d
    }

    private func appDataList() -> URL {
        var c = URLComponents(string: GoogleDrive.filesBase)!
        c.queryItems = [.init(name: "spaces", value: "appDataFolder"), .init(name: "pageSize", value: "100"),
                        .init(name: "fields", value: "files(id,name,modifiedTime)")]
        return c.url!
    }

    private func download(_ id: String) async throws -> [String: Any] {
        var c = URLComponents(string: "\(GoogleDrive.filesBase)/\(id)")!
        c.queryItems = [.init(name: "alt", value: "media")]
        return try await GoogleDrive.get(c.url!)
    }

    private func merge(_ others: [[String: Any]]) {
        func num(_ v: Any?) -> Double { (v as? NSNumber)?.doubleValue ?? 0 }
        func times(_ v: Any?) -> [String: Double] {
            var out: [String: Double] = [:]
            for (k, t) in v as? [String: Any] ?? [:] where k.hasPrefix("drive:") { out[k] = num(t) }
            return out
        }
        let before = (saved.spots, saved.gone, saved.watched, saved.unwatched)
        var latest = saved.spots
        var removed = saved.gone
        for o in others {
            for r in o["recent"] as? [[String: Any]] ?? [] {
                guard let key = r["key"] as? String, key.hasPrefix("drive:") else { continue }
                let at = num(r["at"])
                if let had = latest[key], had.at >= at { continue }
                var s = latest[key] ?? context[key] ?? Spot(title: r["title"] as? String ?? "", pos: 0, dur: 0, at: 0)
                s.title = (r["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? s.title
                s.pos = max(0, num(r["pos"])); s.dur = max(0, num(r["dur"])); s.at = at
                s.next = (r["nx"] as? Bool) ?? false
                latest[key] = s
            }
            for (k, at) in times(o["gone"]) where at > (removed[k] ?? -1) { removed[k] = at }
        }
        // A removal as new as the progress takes it away; progress newer than a removal brings it back.
        let kept = latest.filter { $0.value.at > (removed[$0.key] ?? -1) }
        for k in kept.keys { removed[k] = nil }
        saved.spots = Dictionary(uniqueKeysWithValues: kept.sorted { $0.value.at > $1.value.at }.prefix(30).map { ($0.key, $0.value) })
        saved.gone = Dictionary(uniqueKeysWithValues: removed.sorted { $0.value > $1.value }.prefix(200).map { ($0.key, $0.value) })
        var marks = saved.watched, unmarks = saved.unwatched
        for o in others {
            for (k, at) in times(o["watched"]) where at > (marks[k] ?? -1) { marks[k] = at }
            for (k, at) in times(o["unwatched"]) where at > (unmarks[k] ?? -1) { unmarks[k] = at }
        }
        saved.watched = marks.filter { $0.value > (unmarks[$0.key] ?? -1) }
        saved.unwatched = unmarks.filter { saved.watched[$0.key] == nil }
        if before != (saved.spots, saved.gone, saved.watched, saved.unwatched) { unsynced = true }
    }

    /// This device's file, in the TVs' format.
    private func upload(_ name: String) async throws -> String {
        let recent: [[String: Any]] = saved.spots.sorted { $0.value.at > $1.value.at }.prefix(30).map { k, s in
            var r: [String: Any] = ["key": k, "title": s.title, "pos": Int64(s.pos), "dur": Int64(s.dur), "at": Int64(s.at)]
            if s.next { r["nx"] = true }
            return r
        }
        let body: [String: Any] = ["v": 1, "tv": "app-\(deviceID)", "name": PhonePlayback.deviceName, "at": Int64(nowMS),
                                   "recent": recent, "gone": saved.gone.mapValues { Int64($0) },
                                   "watched": saved.watched.mapValues { Int64($0) }, "unwatched": saved.unwatched.mapValues { Int64($0) },
                                   "shows": [String: Any]()]
        let data = try JSONSerialization.data(withJSONObject: body)
        let upload = "https://www.googleapis.com/upload/drive/v3/files"
        if let id = saved.syncFile {
            var r = URLRequest(url: URL(string: "\(upload)/\(id)?uploadType=media&fields=id")!)
            r.httpMethod = "PATCH"
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.setValue("Bearer \(try await GoogleDrive.token())", forHTTPHeaderField: "Authorization")
            r.httpBody = data
            let (_, resp) = try await URLSession.shared.data(for: r)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200 { return id }
            if code != 404 { throw GoogleDrive.Failure("Drive answered \(code).") }
        }
        let boundary = "woodruff\(Int(nowMS))"
        let meta = try JSONSerialization.data(withJSONObject: ["name": name, "parents": ["appDataFolder"]] as [String: Any])
        var multipart = Data("--\(boundary)\r\nContent-Type: application/json\r\n\r\n".utf8)
        multipart += meta
        multipart += Data("\r\n--\(boundary)\r\nContent-Type: application/json\r\n\r\n".utf8)
        multipart += data
        multipart += Data("\r\n--\(boundary)--\r\n".utf8)
        var r = URLRequest(url: URL(string: "\(upload)?uploadType=multipart&fields=id")!)
        r.httpMethod = "POST"
        r.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        r.setValue("Bearer \(try await GoogleDrive.token())", forHTTPHeaderField: "Authorization")
        r.httpBody = multipart
        let (d, resp) = try await URLSession.shared.data(for: r)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let id = (try? JSONSerialization.jsonObject(with: d) as? [String: Any])?["id"] as? String else {
            throw GoogleDrive.Failure("Drive didn’t keep the progress file.")
        }
        return id
    }

    /// Progress from a TV names only the file: which film or show it belongs to, from the library (a film's video)
    /// or its folders in Drive (an episode's season and show).
    private func resolveContexts() async {
        // Not before the library has been read: nothing would be found.
        guard !saved.movies.isEmpty || !saved.shows.isEmpty else { return }
        var changed = false
        for (key, s) in saved.spots where s.titleId == nil && !unresolved.contains(key) {
            let file = String(key.dropFirst(6))
            if let e = saved.movies.first(where: { $0.file == file }) {
                saved.spots[key]?.titleId = e.id; saved.spots[key]?.kind = "movie"; saved.spots[key]?.name = e.title
                saved.spots[key]?.poster = e.poster
                changed = true
                continue
            }
            var at = file
            var found = false, reached = true
            for _ in 0..<3 {
                let j: [String: Any]
                do { j = try await GoogleDrive.get(URL(string: "\(GoogleDrive.filesBase)/\(at)?fields=parents,name&supportsAllDrives=true")!) } catch {
                    // Drive out of reach (or the file gone): asked again next time.
                    reached = false
                    break
                }
                guard let parent = (j["parents"] as? [String])?.first else { break }
                if let show = saved.shows.first(where: { $0.id == parent }) {
                    let n = TitleNames.episodeNumber(s.title, season: nil)
                    saved.spots[key]?.titleId = show.id; saved.spots[key]?.kind = "show"; saved.spots[key]?.name = show.title
                    saved.spots[key]?.poster = show.poster
                    if let n { saved.spots[key]?.code = n.season.map { "S\($0) E\(n.number)" } ?? "E\(n.number)" }
                    changed = true
                    found = true
                    break
                }
                at = parent
            }
            if !found && reached { unresolved.insert(key) }
        }
        if changed { store() }
    }

    // MARK: Settings

    func signedOut() {
        saved = Saved(spots: saved.spots, watched: saved.watched)
        store()
    }
}

// Read field by field, so a field added later (or one missing) never loses the library, the progress or the rest.

extension DriveLibrary.Entry {
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "movie"
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? name
        year = try c.decodeIfPresent(Int.self, forKey: .year)
        poster = try c.decodeIfPresent(String.self, forKey: .poster)
        backdrop = try c.decodeIfPresent(String.self, forKey: .backdrop)
        genres = try c.decodeIfPresent([String].self, forKey: .genres) ?? []
        rating = try c.decodeIfPresent(Double.self, forKey: .rating)
        overview = try c.decodeIfPresent(String.self, forKey: .overview)
        tmdb = try c.decodeIfPresent(Int.self, forKey: .tmdb)
        added = try c.decodeIfPresent(Double.self, forKey: .added) ?? 0
        file = try c.decodeIfPresent(String.self, forKey: .file)
    }
}

extension DriveLibrary.Spot {
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        pos = try c.decodeIfPresent(Double.self, forKey: .pos) ?? 0
        dur = try c.decodeIfPresent(Double.self, forKey: .dur) ?? 0
        at = try c.decodeIfPresent(Double.self, forKey: .at) ?? 0
        next = try c.decodeIfPresent(Bool.self, forKey: .next) ?? false
        titleId = try c.decodeIfPresent(String.self, forKey: .titleId)
        kind = try c.decodeIfPresent(String.self, forKey: .kind)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        code = try c.decodeIfPresent(String.self, forKey: .code)
        episode = try c.decodeIfPresent(String.self, forKey: .episode)
        poster = try c.decodeIfPresent(String.self, forKey: .poster)
    }
}

extension DriveLibrary.Saved {
    /// Each part on its own: one that can't be read is left empty, the others kept.
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        movies = (try? c.decodeIfPresent([DriveLibrary.Entry].self, forKey: .movies)) ?? []
        shows = (try? c.decodeIfPresent([DriveLibrary.Entry].self, forKey: .shows)) ?? []
        updated = try? c.decodeIfPresent(Double.self, forKey: .updated)
        folders = (try? c.decodeIfPresent([String: [GoogleDrive.File]].self, forKey: .folders)) ?? [:]
        spots = (try? c.decodeIfPresent([String: DriveLibrary.Spot].self, forKey: .spots)) ?? [:]
        watched = (try? c.decodeIfPresent([String: Double].self, forKey: .watched)) ?? [:]
        gone = (try? c.decodeIfPresent([String: Double].self, forKey: .gone)) ?? [:]
        unwatched = (try? c.decodeIfPresent([String: Double].self, forKey: .unwatched)) ?? [:]
        syncFile = try? c.decodeIfPresent(String.self, forKey: .syncFile)
        synced = try? c.decodeIfPresent(Double.self, forKey: .synced)
    }
}

/// The same five featured titles all day on every device (a day's seed).
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
