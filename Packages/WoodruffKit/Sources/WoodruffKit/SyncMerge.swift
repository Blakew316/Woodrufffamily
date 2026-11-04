import Foundation

/// How two devices' copies of a setting become one. Pure functions, so they're tested on every build.
public enum SyncMerge {
    /// Canonical JSON (sorted keys), so equal values compare equal as text.
    public static func canonical(_ o: Any) -> String? {
        guard let d = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys, .fragmentsAllowed]) else { return nil }
        return String(decoding: d, as: UTF8.self)
    }

    public static func object(_ s: String) -> Any? {
        guard !s.isEmpty else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(s.utf8), options: [.fragmentsAllowed])
    }

    /// The stamp for a change made at [date]: seconds, to the millisecond, so it reads back from JSON exactly as it
    /// was written on every device (a stamp that came back a hair different would look like a change, and the
    /// devices would hand it back and forth for ever).
    public static func stampNow(_ date: Date = Date()) -> Double {
        (date.timeIntervalSince1970 * 1000).rounded() / 1000
    }

    /// Per-entry stamps for a dictionary setting after a change here: entries that changed or appeared get
    /// [now]; entries that went away get -[now] (so the removal wins over an older copy elsewhere).
    public static func stampEntries(old: String, new: String, stamps: [String: Double], now: Double) -> [String: Double] {
        let o = object(old) as? [String: Any] ?? [:]
        let n = object(new) as? [String: Any] ?? [:]
        var out = stamps
        for (k, v) in n where canonical(v) != o[k].flatMap(canonical) { out[k] = now }
        for k in o.keys where n[k] == nil { out[k] = -now }
        return out
    }

    /// Every part of the dictionary setting [value] stamped [stamp]: for a setting that was kept whole until now,
    /// so each of its parts counts as old as the whole did.
    public static func uniformStamps(_ value: String, _ stamp: Double) -> [String: Double] {
        guard stamp != 0, let o = object(value) as? [String: Any] else { return [:] }
        var out: [String: Double] = [:]
        for k in o.keys { out[k] = stamp }
        return out
    }

    /// Two copies of a dictionary setting made one, entry by entry: each entry as whichever side changed it
    /// last says (a negative stamp is a removal). Entries with no stamp count as old (1) if present.
    /// The same on both devices whichever way round they merge. Returns the merged JSON (canonical) and stamps.
    public static func mergeEntries(local: String, localStamps: [String: Double],
                                    remote: String, remoteStamps: [String: Double]) -> (value: String, stamps: [String: Double]) {
        let l = object(local) as? [String: Any] ?? [:]
        let r = object(remote) as? [String: Any] ?? [:]
        var out: [String: Any] = [:]
        var st: [String: Double] = [:]
        for k in Set(l.keys).union(r.keys).union(localStamps.keys).union(remoteStamps.keys) {
            let lv = l[k], rv = r[k]
            let ls = localStamps[k] ?? (lv != nil ? 1 : 0)
            let rs = remoteStamps[k] ?? (rv != nil ? 1 : 0)
            // The later change wins. On a tie, what's there beats what isn't; between two different values, the
            // same one on every device (never each taking the other's, which would swap them back and forth).
            let useRemote: Bool
            if abs(rs) != abs(ls) {
                useRemote = abs(rs) > abs(ls)
            } else if (rv != nil) != (lv != nil) {
                useRemote = rv != nil
            } else if let a = lv, let b = rv {
                let ca = canonical(a) ?? "", cb = canonical(b) ?? ""
                useRemote = ca != cb ? cb > ca : rs >= ls
            } else {
                useRemote = rs <= ls   // both gone: the removal stands
            }
            let s = useRemote ? rs : ls
            if s != 0 { st[k] = s }
            if let v = useRemote ? rv : lv, s >= 0 { out[k] = v }
        }
        return (canonical(out) ?? "{}", st)
    }

    /// Two Home layouts made one, part by part: each part (sections and their order, what's hidden, the order of
    /// the tiles, pinned rooms, grouping) as whichever device changed it last says, and every favourite as its own
    /// latest add or remove says. Two devices changing different things both keep their change, and both end up
    /// with the same layout whichever way round they merge. Canonical JSON out, with each part's stamp.
    public static func mergeLayout(local: String, localStamps: [String: Double],
                                   remote: String, remoteStamps: [String: Double]) -> (value: String, stamps: [String: Double]) {
        let m = mergeEntries(local: local, localStamps: localStamps, remote: remote, remoteStamps: remoteStamps)
        guard var out = object(m.value) as? [String: Any] else { return m }
        let l = object(local) as? [String: Any] ?? [:]
        let r = object(remote) as? [String: Any] ?? [:]
        let a = favoriteStates(l), b = favoriteStates(r)
        var each: [String: Double] = [:]
        for id in Set(a.keys).union(b.keys) {
            let x = a[id] ?? 0, y = b[id] ?? 0
            each[id] = abs(x) != abs(y) ? (abs(x) > abs(y) ? x : y) : max(x, y)
        }
        let lf = l["favorites"] as? [String] ?? [], rf = r["favorites"] as? [String] ?? []
        // In the order of the list changed last, then any the other device added.
        let kept = out["favorites"] as? [String] ?? []
        var favs: [String] = []
        for id in kept + (kept == lf ? rf : lf) where (each[id] ?? 0) > 0 && !favs.contains(id) { favs.append(id) }
        if out["favorites"] != nil || !favs.isEmpty { out["favorites"] = favs }
        let stamped = each.filter { $0.value != 0.5 && $0.value != 0 }
        if out["favoriteStamps"] != nil || !stamped.isEmpty { out["favoriteStamps"] = stamped }
        return (canonical(out) ?? m.value, m.stamps)
    }

    /// Each favourite's latest add (positive) or remove (negative); one listed with no stamp counts as old (0.5).
    static func favoriteStates(_ o: [String: Any]) -> [String: Double] {
        var out: [String: Double] = [:]
        for f in o["favorites"] as? [String] ?? [] { out[f] = 0.5 }
        for (id, t) in o["favoriteStamps"] as? [String: Any] ?? [:] { if let d = (t as? NSNumber)?.doubleValue { out[id] = d } }
        return out
    }

    /// Two Home layouts made one the way versions before part-by-part merging did: the newer one's sections and
    /// order, and every favourite as its own latest add or remove says. Canonical JSON out.
    public static func mergeLayout(local: String, remote: String, remoteNewer: Bool) -> String {
        guard let l = object(local) as? [String: Any], let r = object(remote) as? [String: Any] else { return remoteNewer ? remote : local }
        var base = remoteNewer ? r : l
        let other = remoteNewer ? l : r
        let a = favoriteStates(base), b = favoriteStates(other)
        var stampsOut: [String: Double] = [:]
        for id in Set(a.keys).union(b.keys) {
            stampsOut[id] = [a[id], b[id]].compactMap { $0 }.max { abs($0) < abs($1) }
        }
        var favs = (base["favorites"] as? [String] ?? []).filter { (stampsOut[$0] ?? 0) > 0 }
        for id in (other["favorites"] as? [String] ?? []) where (stampsOut[id] ?? 0) > 0 && !favs.contains(id) { favs.append(id) }
        base["favorites"] = favs
        base["favoriteStamps"] = stampsOut.filter { $0.value != 0.5 }
        return canonical(base) ?? (remoteNewer ? remote : local)
    }

    /// Just the favourites part of a layout (to tell whether a merge changed anything that matters).
    public static func favoritesPart(_ layout: String) -> String {
        guard let o = object(layout) as? [String: Any] else { return "" }
        return canonical(["f": o["favorites"] ?? [], "s": o["favoriteStamps"] ?? [:]]) ?? ""
    }
}
