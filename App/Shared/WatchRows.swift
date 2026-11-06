import Foundation
import WoodruffKit

/// Movies and TV Shows as the TV's streaming screen shows them (Library.kt there): the day's five featured titles,
/// then Recently Added, Top Rated and the biggest genres, each title in one row only, no row shorter than six.
enum WatchRows {
    static let minRow = 6
    static let genreRows = 8

    /// The day's five for the banner: titles with wide art, the well rated ones when there are five of them; the
    /// same five all day (on every device), new ones tomorrow.
    static func featured(_ titles: [Title], section: String, now: Date = Date()) -> [Title] {
        var pool = titles.filter { $0.backdrop != nil }
        let good = pool.filter { ($0.rating ?? 0) >= 6.5 }
        if good.count >= 5 { pool = good }
        let cal = Calendar.current
        let day = (cal.component(.year, from: now) * 1000) + (cal.ordinality(of: .day, in: .year, for: now) ?? 1)
        var rng = SeededRandom(seed: UInt64(day) &* 31 &+ (section == "shows" ? 7 : 3))
        return Array(pool.shuffled(using: &rng).prefix(5))
    }

    /// The rows under Continue Watching, by name: [shown] are the titles already in it.
    static func rows(_ titles: [Title], shown: Set<String> = []) -> [(name: String, genre: String?, titles: [Title])] {
        let size = min(20, max(minRow + 2, titles.count / 6))
        var used = shown
        func claim(_ candidates: [Title]) -> [Title] {
            var out: [Title] = []
            for t in candidates where out.count < size && !used.contains(t.id) {
                used.insert(t.id); out.append(t)
            }
            return out
        }
        let recent = claim(titles.sorted { ($0.added ?? 0) > ($1.added ?? 0) })
        let top = claim(titles.filter { $0.rating != nil }.sorted { ($0.rating ?? 0) > ($1.rating ?? 0) })
        if top.count < minRow { for t in top { used.remove(t.id) } }
        var out: [(name: String, genre: String?, titles: [Title])] = []
        if !recent.isEmpty { out.append(("Recently Added", nil, recent)) }
        if top.count >= minRow { out.append(("Top Rated", nil, top)) }
        out += genres(titles.filter { !used.contains($0.id) }, size: size).map { ($0.0, $0.0, $0.1) }
        return out
    }

    /// The genres, most titles first.
    private static func genreList(_ titles: [Title]) -> [String] {
        var count: [String: Int] = [:]
        for t in titles { for g in t.genres ?? [] { count[g, default: 0] += 1 } }
        return count.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
    }

    /// Up to eight genre rows, none sharing a title and none under six: a genre too small gives its titles back.
    private static func genres(_ titles: [Title], size: Int) -> [(String, [Title])] {
        var list = Array(genreList(titles).prefix(genreRows))
        while !list.isEmpty {
            let rows = draft(titles, list, size: size)
            let short = Set(rows.filter { $0.1.count < minRow }.map(\.0))
            if short.isEmpty { return rows }
            list.removeAll { short.contains($0) }
        }
        return []
    }

    /// The genres take turns picking their next title: their own first (the genre listed first), then the rest, best
    /// rated first. Each row is then shown best first.
    private static func draft(_ titles: [Title], _ genres: [String], size: Int) -> [(String, [Title])] {
        let pools = genres.map { g in
            titles.filter { ($0.genres ?? []).contains(g) }.sorted { a, b in
                let ao = a.genres?.first == g ? 0 : 1, bo = b.genres?.first == g ? 0 : 1
                return ao != bo ? ao < bo : (a.rating ?? 0) > (b.rating ?? 0)
            }
        }
        var rows = genres.map { _ in [Title]() }
        var next = Array(repeating: 0, count: genres.count)
        var taken = Set<String>()
        var picked = true
        while picked {
            picked = false
            for r in genres.indices where rows[r].count < size {
                while next[r] < pools[r].count, taken.contains(pools[r][next[r]].id) { next[r] += 1 }
                guard next[r] < pools[r].count else { continue }
                let t = pools[r][next[r]]
                taken.insert(t.id); rows[r].append(t); next[r] += 1
                picked = true
            }
        }
        return genres.indices.map { (genres[$0], rows[$0].sorted { ($0.rating ?? 0) > ($1.rating ?? 0) }) }
    }
}
