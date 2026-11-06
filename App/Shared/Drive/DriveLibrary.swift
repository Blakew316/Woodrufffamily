import Foundation
import SwiftUI
import WoodruffKit

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
        if choice == "drive", GoogleDrive.signedIn { return DriveLibrary.shared }
        return fleet.hubClient()
    }

    static var usesDrive: Bool { choice == "drive" && GoogleDrive.signedIn }
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
        var minutes: Double?
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
    }

    private struct Saved: Codable {
        var movies: [Entry] = []
        var shows: [Entry] = []
        var updated: Double?
        var folders: [String: [GoogleDrive.File]] = [:]
        var spots: [String: Spot] = [:]
        var watched: [String: Double] = [:]
    }

    private var saved: Saved
    private(set) var busy = false
    private(set) var error: String?
    private var refreshing: Task<Void, Never>?
    private let file: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Watch", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("library.json")
    }()

    var titleCount: Int { saved.movies.count + saved.shows.count }
    var updated: Date? { saved.updated.map { Date(timeIntervalSince1970: $0 / 1000) } }

    private init() {
        saved = (try? JSONDecoder().decode(Saved.self, from: Data(contentsOf: file))) ?? Saved()
    }

    private func store() {
        if let d = try? JSONEncoder().encode(saved) { try? d.write(to: file, options: .atomic) }
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
                throw GoogleDrive.Failure("There’s no “Movies” or “TV Shows” folder in this Google Drive.")
            }
            var movies: [Entry] = [], shows: [Entry] = []
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
            store()
            await fill()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// What TMDB already said about [e], kept from the last read.
    private func keep(_ e: Entry) -> Entry {
        guard let old = (saved.movies + saved.shows).first(where: { $0.id == e.id && $0.name == e.name }) else { return e }
        var n = e
        n.poster = old.poster; n.backdrop = old.backdrop; n.genres = old.genres; n.rating = old.rating
        n.overview = old.overview; n.tmdb = old.tmdb; n.year = e.year ?? old.year; n.minutes = old.minutes
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
        for f in list where f.isFolder {
            let inside = try await GoogleDrive.children(f.id)
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
    private func fill() async {
        for list in [\Saved.movies, \Saved.shows] {
            for i in saved[keyPath: list].indices where saved[keyPath: list][i].tmdb == nil {
                let e = saved[keyPath: list][i]
                guard let hit = await TMDB.shared.find(TitleNames.searchTitle(e.title), year: e.year, tv: e.kind == "show") else { continue }
                guard i < saved[keyPath: list].count, saved[keyPath: list][i].id == e.id else { continue }
                saved[keyPath: list][i].tmdb = hit.id
                saved[keyPath: list][i].poster = hit.poster
                saved[keyPath: list][i].backdrop = hit.backdrop
                saved[keyPath: list][i].genres = hit.genres
                saved[keyPath: list][i].rating = hit.rating
                saved[keyPath: list][i].overview = hit.overview
                if saved[keyPath: list][i].year == nil { saved[keyPath: list][i].year = hit.year }
            }
        }
        store()
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

    private func entry(_ id: String) -> Entry? { (saved.movies + saved.shows).first { $0.id == id } }

    // MARK: Where things were left off

    private var nowMS: Double { Date().timeIntervalSince1970 * 1000 }

    /// The player's report while something plays here, and when it stops.
    func played(_ key: String, title: String, pos: Double, dur: Double) {
        guard key.hasPrefix("drive:") else { return }
        var s = saved.spots[key] ?? context[key] ?? Spot(title: title, pos: 0, dur: 0, at: 0)
        s.pos = pos; s.dur = dur; s.at = nowMS; s.next = false
        if dur > 0 && (dur - pos < 5_000 || pos >= 0.95 * dur) {
            saved.spots[key] = nil
            saved.watched[key] = nowMS
            upNext(after: key)
        } else if pos > 0 {
            saved.spots[key] = s
        }
        store()
    }

    /// What a play started here is part of (its show, its episode), for Continue Watching.
    private var context: [String: Spot] = [:]

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
    private var seasonLists: [String: [String]] = [:]

    private func progress(_ key: String) -> (pos: Double, dur: Double) {
        let s = saved.spots[key]
        return (s?.pos ?? 0, s?.dur ?? 0)
    }

    func markWatched(_ keys: [String], _ on: Bool) async throws {
        for k in keys {
            if on { saved.watched[k] = nowMS; saved.spots[k] = nil } else { saved.watched[k] = nil }
        }
        store()
    }

    func removeContinue(key: String, title: String) async throws {
        let show = saved.spots[key]?.titleId
        for (k, s) in saved.spots where k == key || (show != nil && s.titleId == show) { saved.spots[k] = nil }
        store()
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
    private func filmPlay(_ e: Entry) -> [String: Any]? {
        guard let f = e.file else { return nil }
        let key = "drive:\(f)"
        context[key] = Spot(title: e.title, pos: 0, dur: 0, at: 0, titleId: e.id, kind: "movie", name: e.title, poster: e.poster)
        let (pos, dur) = progress(key)
        let resume = dur > 0 && pos > 60_000 && pos / dur < 0.95
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
            p["label"] = s.pos > 60_000 ? "Resume from \(duration(s.pos))" : "Play"
        }
        return p
    }

    private func continueItems() -> [[String: Any]] {
        var seen = Set<String>()
        var out: [[String: Any]] = []
        let live = saved.spots.filter { $0.value.next || ($0.value.pos > 10_000 && ($0.value.dur <= 0 || $0.value.pos / $0.value.dur < 0.95)) }
        for (key, s) in live.sorted(by: { $0.value.at > $1.value.at }) {
            let group = s.titleId ?? key
            guard seen.insert(group).inserted, let play = continuePlay(key, s) else { continue }
            var c: [String: Any] = ["key": key, "playTitle": s.title, "kind": s.kind ?? "movie", "name": s.name ?? s.title,
                                    "position": s.next ? 0 : s.pos, "duration": s.dur, "upNext": s.next, "drive": true, "play": play]
            if let t = s.titleId { c["titleId"] = t }
            if let v = s.code { c["code"] = v }
            if let v = s.episode { c["episode"] = v }
            if let v = s.poster ?? s.titleId.flatMap({ entry($0)?.poster }) { c["poster"] = v }
            if s.kind != "show", s.pos > 60_000 {
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
        if saved.movies.isEmpty && saved.shows.isEmpty {
            if let e = error { throw GoogleDrive.Failure(e) }
            return try decode(["state": busy ? "loading" : "empty"])
        }
        let all = saved.movies + saved.shows
        // Featured: titles with a backdrop (the well rated ones when there are five), the day's five.
        var pool = all.filter { $0.backdrop != nil }
        let good = pool.filter { ($0.rating ?? 0) >= 6.5 }
        if good.count >= 5 { pool = good }
        let day = Calendar.current.ordinality(of: .day, in: .year, for: Date()) ?? 1
        var rng = SeededRandom(seed: UInt64(Calendar.current.component(.year, from: Date()) * 1000 + day))
        let featured = Array(pool.shuffled(using: &rng).prefix(5))
        let az = { (l: [Entry]) in l.sorted { TitleNames.sortKey($0.title) < TitleNames.sortKey($1.title) } }
        let home: [String: Any] = [
            "state": "ready", "tv": "Google Drive", "updated": saved.updated ?? 0,
            "featured": featured.map(titleJSON),
            "continue": continueItems(),
            "recent": all.sorted { $0.added > $1.added }.prefix(20).map(titleJSON),
            "movies": ["count": saved.movies.count, "items": az(saved.movies).prefix(20).map(titleJSON)] as [String: Any],
            "shows": ["count": saved.shows.count, "items": az(saved.shows).prefix(20).map(titleJSON)] as [String: Any],
        ]
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
        switch sort {
        case "recent", "newest": list.sort { $0.added != $1.added ? $0.added > $1.added : TitleNames.sortKey($0.title) < TitleNames.sortKey($1.title) }
        case "year": list.sort { ($0.year ?? 0) != ($1.year ?? 0) ? ($0.year ?? 0) > ($1.year ?? 0) : TitleNames.sortKey($0.title) < TitleNames.sortKey($1.title) }
        case "rated": list.sort { ($0.rating ?? -1) != ($1.rating ?? -1) ? ($0.rating ?? -1) > ($1.rating ?? -1) : TitleNames.sortKey($0.title) < TitleNames.sortKey($1.title) }
        default: list.sort { TitleNames.sortKey($0.title) < TitleNames.sortKey($1.title) }
        }
        var counts: [String: Int] = [:]
        for e in (place == "shows" ? saved.shows : saved.movies) { for g in e.genres { counts[g, default: 0] += 1 } }
        let genres = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
        let page = list.dropFirst(offset).prefix(max(1, min(120, limit)))
        return try decode(["state": "ready", "count": list.count, "offset": offset, "items": page.map(titleJSON),
                           "genres": genres, "rated": (saved.movies + saved.shows).contains { $0.rating != nil }] as [String: Any])
    }

    private func matches(_ e: Entry, _ q: String) -> Bool {
        let t = TitleNames.normalize(e.title)
        return TitleNames.normalize(q).split(separator: " ").allSatisfy { w in
            t.contains(w) || (w.count == 4 && Int(w) == e.year)
        }
    }

    func search(_ q: String) async throws -> SearchResults {
        let words = TitleNames.normalize(String(q.prefix(60)))
        func rank(_ e: Entry) -> Int {
            let t = TitleNames.normalize(e.title)
            if t.hasPrefix(words) || TitleNames.sortKey(e.title).hasPrefix(words) { return 1 }
            if t.split(separator: " ").contains(where: { $0.hasPrefix(words) }) { return 2 }
            return 3
        }
        func found(_ l: [Entry]) -> [Entry] {
            l.filter { matches($0, q) }.sorted {
                let a = rank($0), b = rank($1)
                if a != b { return a < b }
                if ($0.rating ?? 0) != ($1.rating ?? 0) { return ($0.rating ?? 0) > ($1.rating ?? 0) }
                return TitleNames.sortKey($0.title) < TitleNames.sortKey($1.title)
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

    nonisolated func artURL(_ s: String?, small: Bool) -> URL? {
        guard var s, s.hasPrefix("http") else { return nil }
        if small { s = s.replacingOccurrences(of: "/t/p/w1280/", with: "/t/p/w300/") }
        return URL(string: s)
    }

    // MARK: Settings

    func signedOut() {
        saved = Saved(spots: saved.spots, watched: saved.watched)
        store()
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
