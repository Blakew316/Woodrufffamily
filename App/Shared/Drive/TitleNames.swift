import Foundation
import WoodruffKit

/// The TV's rules for reading a file or folder name (Tmdb.parse, EpisodeMeta, ShowPrefs): the title and year to look
/// up, a season's number, an episode's number and its name. Kept the same, so the app and the TVs agree on every title.
enum TitleNames {
    private static func re(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p) }
    private static let brackets = re(#"[\[{].*?[\]}]"#)
    private static let year = re(#"(?<![0-9])(19[2-9][0-9]|20[0-9]{2})(?![0-9])"#)
    private static let junk = re(#"(?i)\b(2160p|1080p|720p|576p|480p|4k|uhd|hdr10?|dv|bluray|blu ray|bdrip|brrip|webrip|web dl|webdl|web|hdtv|dvdrip|x264|x265|h 264|h 265|hevc|avc|aac|ac3|dts|atmos|remux|proper|repack|extended|unrated|imax|criterion|s\d{1,2}(e\d{1,3})?|season \d+|complete)\b"#)
    private static let bracketedYear = re(#"[\[{]\s*(19[2-9][0-9]|20[0-9]{2})\s*[\]}]"#)
    /// No film comes out more than a year or two ahead.
    private static let latestYear = Calendar(identifier: .gregorian).component(.year, from: Date()) + 2
    private static let tail = re(#"[(\-–:,\s]+$"#)
    private static let copyOf = re(#"(?i)^copy of\s+"#)
    private static let copyNumber = re(#"\s*\(\d{1,2}\)(?=\.[A-Za-z0-9]{2,4}$|$)"#)
    private static let copySuffix = re(#"(?i)\s+-\s+copy(?=\.[A-Za-z0-9]{2,4}$|$)"#)
    private static let edition = re(#"(?i)\b(director'?s cut|(extended|theatrical|ultimate) (cut|edition|version)|(special|collector'?s|anniversary) edition|final cut|remastered|redux|open matte|uncut|blu-ray)\b"#)
    static let epCode = re(#"(?i)s(\d{1,2})\s*e(\d{1,3})"#)
    static let epX = re(#"(?i)(?<!\d)(\d{1,2})x(\d{2,3})(?!\d)"#)
    static let epWord = re(#"(?i)\b(?:episode|ep)\s*(\d{1,3})\b"#)
    private static let seasonWord = re(#"(?i)(?:season|series|staffel|saison|temporada)\s*(\d{1,3})"#)
    private static let seasonShort = re(#"^s(\d{1,3})$"#)
    private static let afterCode = re(#"(?i)(?:s\d{1,2}\s*e\d{1,3}|(?<!\d)\d{1,2}x\d{2,3}(?!\d)|\b(?:episode|ep)\s*\d{1,3}\b)[\s._\-–·:]*(.*)"#)

    private static func replace(_ r: NSRegularExpression, in s: String, with t: String = "") -> String {
        r.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: t)
    }
    private static func first(_ r: NSRegularExpression, in s: String) -> NSTextCheckingResult? {
        r.firstMatch(in: s, range: NSRange(s.startIndex..., in: s))
    }
    private static func group(_ m: NSTextCheckingResult, _ i: Int, in s: String) -> String? {
        Range(m.range(at: i), in: s).map { String(s[$0]) }
    }

    /// The title and year in a name (Tmdb.parse): the extension, bracketed tags, release words and anything after the
    /// year taken off.
    static func parse(_ name: String, stripExtension: Bool) -> (title: String, year: Int?) {
        var s = cleanCopy(name)
        if stripExtension { s = (s as NSString).deletingPathExtension }
        // A year in square brackets ("Dune Part Two [2024]") is still the year to look up, though the brackets go.
        var bracketYear: Int?
        if let m = first(bracketedYear, in: s), let g = group(m, 1, in: s), let v = Int(g), v <= latestYear { bracketYear = v }
        s = replace(brackets, in: s)
        s = s.replacingOccurrences(of: ".", with: " ").replacingOccurrences(of: "_", with: " ")
        s = s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        var y: Int?
        let ns = s as NSString
        for m in year.matches(in: s, range: NSRange(location: 0, length: ns.length)) where m.range.location > 0 {
            // A "year" still to come is part of the name ("Blade Runner 2049").
            guard let v = Int(ns.substring(with: m.range)), v <= latestYear else { continue }
            y = v
            s = ns.substring(to: m.range.location)
            break
        }
        let ns2 = s as NSString
        if let m = junk.matches(in: s, range: NSRange(location: 0, length: ns2.length)).first(where: { $0.range.location > 0 }) {
            s = ns2.substring(to: m.range.location)
        }
        s = replace(tail, in: s).replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ")", with: "")
        s = s.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { s = stripExtension ? (name as NSString).deletingPathExtension : name }
        // Shown without a year however it was written (the TV's names are cleaned the same way as they're read).
        return (TitleText.withoutYear(s), y ?? bracketYear)
    }

    private static func cleanCopy(_ name: String) -> String {
        replace(copySuffix, in: replace(copyNumber, in: replace(copyOf, in: name)))
    }

    /// The words to search TMDB for: edition words ("Director's Cut") taken off.
    static func searchTitle(_ title: String) -> String {
        let s = replace(edition, in: title).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return s.isEmpty ? title : s
    }

    /// A season folder's number: 0 for specials or extras, else the number in it (nil when none).
    static func seasonNumber(_ name: String) -> Int? {
        let n = name.lowercased().trimmingCharacters(in: .whitespaces)
        if n.contains("specials") || n.contains("extras") { return 0 }
        if let m = first(seasonWord, in: n), let g = group(m, 1, in: n) { return Int(g) }
        if let m = first(seasonShort, in: n), let g = group(m, 1, in: n) { return Int(g) }
        return nil
    }

    /// An episode's season and number from its file name ([season] from its folder for "Episode 5").
    static func episodeNumber(_ name: String, season: Int?) -> (season: Int?, number: Int)? {
        if let m = first(epCode, in: name), let s = group(m, 1, in: name), let e = group(m, 2, in: name), let en = Int(e) { return (Int(s), en) }
        if let m = first(epX, in: name), let s = group(m, 1, in: name), let e = group(m, 2, in: name), let en = Int(e) { return (Int(s), en) }
        if let m = first(epWord, in: name), let e = group(m, 1, in: name), let en = Int(e) { return (season, en) }
        return nil
    }

    /// An episode's own name from its file ("Show S01E02 The Pilot.mp4" gives "The Pilot"), or nil.
    static func nameAfterCode(_ fileName: String) -> String? {
        let stem = (fileName as NSString).deletingPathExtension
        guard let m = first(afterCode, in: stem), var rest = group(m, 1, in: stem) else { return nil }
        rest = rest.replacingOccurrences(of: ".", with: " ").replacingOccurrences(of: "_", with: " ")
        if let j = first(junk, in: rest) { rest = (rest as NSString).substring(to: j.range.location) }
        rest = replace(brackets, in: rest)
        rest = replace(tail, in: rest).trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? nil : rest
    }

    /// For sorting and searching: accents and punctuation gone, lower case.
    static func normalize(_ s: String) -> String {
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        return folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : " " }.joined()
            .split(separator: " ").joined(separator: " ")
    }

    /// The title as sorted: "The", "A" or "An" at the front left out.
    static func sortKey(_ s: String) -> String {
        let n = normalize(s)
        for a in ["the ", "a ", "an "] where n.hasPrefix(a) { return String(n.dropFirst(a.count)) }
        return n
    }
}
