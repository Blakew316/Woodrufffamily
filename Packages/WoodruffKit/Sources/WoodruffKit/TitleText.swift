import Foundation

/// A film's or show's name as it's shown: never with its year. "Vice (2018)", "Vice 2018", "Vice.2018.1080p",
/// "Dune Part Two [2024]" and "Everest - 2015" all show as the name alone. A number that is part of the name stays:
/// "2001: A Space Odyssey", "1917", "Blade Runner 2049" (a year still to come), "Space: 1999", "Zootopia 2".
public enum TitleText {
    private static func re(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p) }

    /// A year standing on its own (groups: the bracket before it, the year, the bracket after it).
    private static let year = re(#"([(\[{]\s*)?(?<![0-9A-Za-z])((?:19|20)[0-9]{2})(?![0-9A-Za-z])(\s*[)\]}])?"#)
    /// Words a release name carries after its year.
    private static let junkWords = #"2160p|1440p|1080p|1080i|720p|576p|480p|4k|8k|uhd|hdr10\+?|hdr|dv|dovi|sdr|10bit|8bit|blu-?ray|blu ray|bdrip|brrip|bdremux|remux|webrip|web-?dl|web dl|web|hdtv|hdrip|dvdrip|dvdscr|dvd|x264|x265|h[ .]?264|h[ .]?265|hevc|avc|xvid|aac|ac3|eac3|ddp?5[ .]1|dts|atmos|truehd|proper|repack|extended|unrated|imax|yts|yify|rarbg|multi|subbed|dubbed"#
    private static let junkFirst = re("(?i)^(?:" + junkWords + ")(?![A-Za-z0-9])")
    private static let junkAnywhere = re("(?i)(?<![A-Za-z0-9])(?:" + junkWords + ")(?![A-Za-z0-9])")
    /// No film has come out more than a year or two ahead: a later "year" is part of the name ("Blade Runner 2049").
    private static let latestYear = Calendar(identifier: .gregorian).component(.year, from: Date()) + 2

    /// What may stand right before a year that's not in brackets.
    private static let separators = CharacterSet(charactersIn: " ._-–—(\t")
    /// What's left off the end of the name before the year.
    private static let before = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "._-–—:,;([{"))
    /// What's left off the start of what follows the year.
    private static let after = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "._-–—:,;()[]{}"))

    /// [name] without its year (and the release words after it). Unchanged when it has none.
    public static func withoutYear(_ name: String) -> String {
        guard name.rangeOfCharacter(from: .decimalDigits) != nil else { return name }
        var s = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // A release name ("Vice.2018.1080p"): its dots and underscores read as spaces.
        if !s.contains(" "), s.filter({ $0 == "." || $0 == "_" }).count >= 2 {
            s = s.replacingOccurrences(of: ".", with: " ").replacingOccurrences(of: "_", with: " ")
        }
        let ns = s as NSString
        for m in year.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            let yr = m.range(at: 2)
            guard yr.location != NSNotFound, let y = Int(ns.substring(with: yr)), y >= 1900, y <= latestYear else { continue }
            let open = m.range(at: 1), close = m.range(at: 3)
            let bracketed = open.location != NSNotFound && close.location != NSNotFound
            let whole = bracketed ? m.range : yr
            let head = ns.substring(to: whole.location)
            let prefix = trimEnd(head, before)
            // At the start, it's the name itself ("1917", "2001: A Space Odyssey").
            guard !prefix.isEmpty else { continue }
            if !bracketed {
                guard let last = head.unicodeScalars.last, separators.contains(last) else { continue }
                // "Space: 1999": the number is the name's own.
                if trimEnd(head, .whitespaces).hasSuffix(":") { continue }
            }
            let rest = trimStart(ns.substring(from: whole.location + whole.length), after)
            var tail = ""
            if !rest.isEmpty && !starts(junkFirst, rest) {
                // Words after a year that isn't in brackets: the year is part of the name.
                guard bracketed else { continue }
                tail = cutAtJunk(rest)
            }
            let out = trimEnd(tail.isEmpty ? prefix : prefix + " " + tail, before)
            return out.isEmpty ? name : out
        }
        return name
    }

    private static func starts(_ r: NSRegularExpression, _ s: String) -> Bool {
        r.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
    }

    private static func cutAtJunk(_ s: String) -> String {
        let ns = s as NSString
        guard let m = junkAnywhere.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return s }
        return trimEnd(ns.substring(to: m.range.location), before)
    }

    private static func trimEnd(_ s: String, _ set: CharacterSet) -> String {
        var scalars = Array(s.unicodeScalars)
        while let last = scalars.last, set.contains(last) { scalars.removeLast() }
        var out = String.UnicodeScalarView()
        out.append(contentsOf: scalars)
        return String(out)
    }

    private static func trimStart(_ s: String, _ set: CharacterSet) -> String {
        let scalars = s.unicodeScalars
        guard let i = scalars.firstIndex(where: { !set.contains($0) }) else { return "" }
        return String(scalars[i...])
    }
}
