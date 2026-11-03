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

    /// Two copies of a dictionary setting made one, entry by entry: each entry as whichever side changed it
    /// last says (a negative stamp is a removal). Entries with no stamp count as old (1) if present.
    /// Returns the merged JSON (canonical) and stamps.
    public static func mergeEntries(local: String, localStamps: [String: Double],
                                    remote: String, remoteStamps: [String: Double]) -> (value: String, stamps: [String: Double]) {
        let l = object(local) as? [String: Any] ?? [:]
        let r = object(remote) as? [String: Any] ?? [:]
        var out: [String: Any] = [:]
        var st: [String: Double] = [:]
        for k in Set(l.keys).union(r.keys).union(localStamps.keys).union(remoteStamps.keys) {
            let ls = localStamps[k] ?? (l[k] != nil ? 1 : 0)
            let rs = remoteStamps[k] ?? (r[k] != nil ? 1 : 0)
            // The later change wins; on a tie, what's there beats what isn't, then the remote copy.
            let useRemote: Bool
            if abs(rs) != abs(ls) { useRemote = abs(rs) > abs(ls) }
            else if (r[k] != nil) != (l[k] != nil) { useRemote = r[k] != nil }
            else { useRemote = true }
            let s = useRemote ? rs : ls
            if s != 0 { st[k] = s }
            if let v = useRemote ? r[k] : l[k], s >= 0 { out[k] = v }
        }
        return (canonical(out) ?? "{}", st)
    }

    /// Two Home layouts made one: the newer one's sections and order, and every favourite as its own latest
    /// add or remove says. Canonical JSON out.
    public static func mergeLayout(local: String, remote: String, remoteNewer: Bool) -> String {
        guard let l = object(local) as? [String: Any], let r = object(remote) as? [String: Any] else { return remoteNewer ? remote : local }
        var base = remoteNewer ? r : l
        let other = remoteNewer ? l : r
        func state(_ o: [String: Any]) -> [String: Double] {
            var out: [String: Double] = [:]
            for f in o["favorites"] as? [String] ?? [] { out[f] = 0.5 }
            for (id, t) in o["favoriteStamps"] as? [String: Any] ?? [:] { if let d = (t as? NSNumber)?.doubleValue { out[id] = d } }
            return out
        }
        let a = state(base), b = state(other)
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
