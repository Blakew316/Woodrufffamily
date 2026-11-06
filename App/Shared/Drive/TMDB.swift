import Foundation
import WoodruffKit

/// TMDB, for the posters, stories, ratings and episode names, as the TV looks them up (Tmdb.kt): the same searches,
/// the same picks, and answers kept on this device for good (so a title is looked up once, and shows offline).
@MainActor
final class TMDB {
    static let shared = TMDB()

    static var key: String? { Keychain.get("tmdb.key").flatMap { $0.isEmpty ? nil : $0 } }
    private static let api = "https://api.themoviedb.org/3/"
    static let posterBase = "https://image.tmdb.org/t/p/w342"
    static let backdropBase = "https://image.tmdb.org/t/p/w1280"
    static let stillBase = "https://image.tmdb.org/t/p/w300"

    struct Hit: Codable, Hashable {
        var id: Int
        var poster: String?
        var backdrop: String?
        var overview: String?
        var year: Int?
        var genres: [String]
        var rating: Double?
    }

    struct Details: Codable, Hashable {
        var runtime: Double?
        var ageRating: String?
        var cast: [String]
    }

    struct EpisodeMeta: Codable, Hashable {
        var name: String?
        var overview: String?
        var still: String?
        var runtime: Double?
    }

    /// Answers as kept: "m:"/"t:" searches (nil = no match), "d:" details, "e:" a season's episodes.
    private struct Cache: Codable {
        var hits: [String: Hit?] = [:]
        var details: [String: Details] = [:]
        var seasons: [String: [String: EpisodeMeta]] = [:]
    }
    private var cache: Cache
    private var dirty = false
    private var saving: Task<Void, Never>?
    private let file: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Watch", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("tmdb.json")
    }()
    /// At most six questions to TMDB at a time (the TV's limit).
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    private init() {
        cache = (try? JSONDecoder().decode(Cache.self, from: Data(contentsOf: file))) ?? Cache()
    }

    private func save() {
        dirty = true
        guard saving == nil else { return }
        saving = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self else { return }
            self.saving = nil
            guard self.dirty else { return }
            self.dirty = false
            if let d = try? JSONEncoder().encode(self.cache) { try? d.write(to: self.file, options: .atomic) }
        }
    }

    private func slot() async {
        if running < 6 { running += 1; return }
        await withCheckedContinuation { waiting.append($0) }
    }
    private func release() {
        if waiting.isEmpty { running -= 1 } else { waiting.removeFirst().resume() }
    }

    private func get(_ path: String, _ query: [String: String] = [:]) async throws -> [String: Any] {
        guard let key = Self.key else { throw GoogleDrive.Failure("Add a TMDB key in Settings for posters and descriptions.") }
        await slot()
        defer { release() }
        var c = URLComponents(string: Self.api + path)!
        var items = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        let bearer = key.hasPrefix("eyJ")
        if !bearer { items.append(.init(name: "api_key", value: key)) }
        c.queryItems = items.isEmpty ? nil : items
        var r = URLRequest(url: c.url!)
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        if bearer { r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        r.timeoutInterval = 20
        let (d, resp) = try await URLSession.shared.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw GoogleDrive.Failure(code == 401 ? "TMDB didn’t accept the key." : "TMDB answered \(code).") }
        return (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
    }

    // MARK: Searches

    /// The film or show for [title] ([year] when the file name gave one), or nil when TMDB has none.
    func find(_ title: String, year: Int?, tv: Bool) async -> Hit? {
        let k = "\(tv ? "t" : "m"):\(title.lowercased()):\(year.map(String.init) ?? "")"
        if let kept = cache.hits[k] { return kept }
        guard Self.key != nil else { return nil }
        do {
            var hit = try await search(title, year: year, tv: tv)
            if hit == nil, year != nil { hit = try await search(title, year: nil, tv: tv) }
            cache.hits[k] = .some(hit)
            save()
            return hit
        } catch { return nil }   // asked again next time
    }

    private func search(_ title: String, year: Int?, tv: Bool) async throws -> Hit? {
        var q = ["query": title]
        if tv { if let year { q["first_air_date_year"] = String(year) } } else {
            q["include_adult"] = "false"
            if let year { q["year"] = String(year) }
        }
        let j = try await get(tv ? "search/tv" : "search/movie", q)
        let results = j["results"] as? [[String: Any]] ?? []
        // A film: the first of the top five with a poster, else the top one. A show: the top one.
        let pick = tv ? results.first : (results.prefix(5).first { ($0["poster_path"] as? String) != nil } ?? results.first)
        guard let r = pick, let id = (r["id"] as? NSNumber)?.intValue else { return nil }
        let date = (r["release_date"] as? String) ?? (r["first_air_date"] as? String) ?? ""
        let y = Int(date.prefix(4)).flatMap { (1870...2100).contains($0) ? $0 : nil }
        let votes = (r["vote_count"] as? NSNumber)?.intValue ?? 0
        let avg = (r["vote_average"] as? NSNumber)?.doubleValue ?? 0
        let ids = (r["genre_ids"] as? [NSNumber])?.map(\.intValue) ?? []
        return Hit(id: id,
                   poster: (r["poster_path"] as? String).map { Self.posterBase + $0 },
                   backdrop: (r["backdrop_path"] as? String).map { Self.backdropBase + $0 },
                   overview: (r["overview"] as? String).map { String($0.prefix(700)) }.flatMap { $0.isEmpty ? nil : $0 },
                   year: y, genres: Self.genres(ids, tv: tv), rating: avg > 0 && votes >= 20 ? avg : nil)
    }

    /// Runtime, US age rating and the first few of the cast.
    func details(_ id: Int, tv: Bool) async -> Details? {
        let k = "\(tv ? "t" : "m"):\(id)"
        if let kept = cache.details[k] { return kept }
        guard let j = try? await get(tv ? "tv/\(id)" : "movie/\(id)",
                                     ["append_to_response": tv ? "content_ratings,aggregate_credits" : "release_dates,credits"]) else { return nil }
        var rating: String?
        if tv {
            rating = ((j["content_ratings"] as? [String: Any])?["results"] as? [[String: Any]])?
                .first { $0["iso_3166_1"] as? String == "US" }?["rating"] as? String
        } else {
            let us = ((j["release_dates"] as? [String: Any])?["results"] as? [[String: Any]])?
                .first { $0["iso_3166_1"] as? String == "US" }?["release_dates"] as? [[String: Any]] ?? []
            let theatrical = us.first { ($0["type"] as? NSNumber)?.intValue == 3 && !(($0["certification"] as? String) ?? "").isEmpty }
            rating = (theatrical ?? us.first { !(($0["certification"] as? String) ?? "").isEmpty })?["certification"] as? String
        }
        if rating == "NR" || rating?.isEmpty == true { rating = nil }
        let credits = (j[tv ? "aggregate_credits" : "credits"] as? [String: Any])?["cast"] as? [[String: Any]] ?? []
        let runtime = (j["runtime"] as? NSNumber)?.doubleValue ?? (j["episode_run_time"] as? [NSNumber])?.first?.doubleValue
        let d = Details(runtime: runtime, ageRating: rating, cast: credits.prefix(6).compactMap { $0["name"] as? String })
        cache.details[k] = d
        save()
        return d
    }

    /// A season's episodes by number.
    func season(_ tvID: Int, _ n: Int) async -> [Int: EpisodeMeta] {
        let k = "\(tvID):\(n)"
        if let kept = cache.seasons[k] { return Dictionary(uniqueKeysWithValues: kept.compactMap { k, v in Int(k).map { ($0, v) } }) }
        guard let j = try? await get("tv/\(tvID)/season/\(n)") else { return [:] }
        var out: [String: EpisodeMeta] = [:]
        for e in j["episodes"] as? [[String: Any]] ?? [] {
            guard let num = (e["episode_number"] as? NSNumber)?.intValue else { continue }
            var name = e["name"] as? String
            if let n = name, n.range(of: #"^Episode #?\d+$"#, options: .regularExpression) != nil { name = nil }
            var overview = e["overview"] as? String
            if let o = overview, o.count > 300 {
                let cut = o.prefix(300)
                overview = (cut.range(of: " ", options: .backwards).map { String(cut[..<$0.lowerBound]) } ?? String(cut)) + "…"
            }
            out[String(num)] = EpisodeMeta(name: name, overview: overview?.isEmpty == true ? nil : overview,
                                           still: (e["still_path"] as? String).map { Self.stillBase + $0 },
                                           runtime: (e["runtime"] as? NSNumber)?.doubleValue)
        }
        cache.seasons[k] = out
        save()
        return Dictionary(uniqueKeysWithValues: out.compactMap { k, v in Int(k).map { ($0, v) } })
    }

    // MARK: Genres (TMDB's fixed lists; a show's combined ones split, as on the TV)

    private static func genres(_ ids: [Int], tv: Bool) -> [String] {
        let movie: [Int: [String]] = [28: ["Action"], 12: ["Adventure"], 16: ["Animation"], 35: ["Comedy"], 80: ["Crime"],
            99: ["Documentary"], 18: ["Drama"], 10751: ["Family"], 14: ["Fantasy"], 36: ["History"], 27: ["Horror"],
            10402: ["Music"], 9648: ["Mystery"], 10749: ["Romance"], 878: ["Sci-Fi"], 10770: ["TV Movie"], 53: ["Thriller"],
            10752: ["War"], 37: ["Western"]]
        let show: [Int: [String]] = [10759: ["Action", "Adventure"], 16: ["Animation"], 35: ["Comedy"], 80: ["Crime"],
            99: ["Documentary"], 18: ["Drama"], 10751: ["Family"], 10762: ["Kids"], 9648: ["Mystery"], 10763: ["News"],
            10764: ["Reality"], 10765: ["Sci-Fi", "Fantasy"], 10766: ["Soap"], 10767: ["Talk"], 10768: ["War", "Politics"], 37: ["Western"]]
        var out: [String] = []
        for id in ids { for g in (tv ? show : movie)[id] ?? [] where !out.contains(g) { out.append(g) } }
        return out
    }
}
