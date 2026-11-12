import Foundation

/// The LG TVs take a new build with the rest of the family, with no button: a Mac that can reach the TV over SSH
/// (the Mac Studio, whose updater reopens this app with every release) installs it by itself, as it installs the
/// iPhones' and the Apple TVs' apps. Each look at the releases (half a minute after the app opens, then every ten
/// minutes) ends with this.
///
/// What it did, and why it couldn't, is written to ~/Library/Logs/Woodruff Family/lg-updates.log on that Mac.
public enum WebOSAutoUpdate {
    /// What this Mac remembers of installing on one TV.
    public struct Tried: Codable, Equatable, Sendable {
        public var tag: String
        public var tries: Int
        public var at: Date
        /// The TV said this build was installed: it isn't put on again, whatever version the TV goes on reporting.
        public var done: Bool?
        public init(tag: String, tries: Int, at: Date, done: Bool? = nil) { self.tag = tag; self.tries = tries; self.at = at; self.done = done }
    }

    /// A build that didn't go on is tried again after an hour, and after four tries twice a day: it never gives up,
    /// so a TV whose way in is put right gets the build without anyone pressing anything. A newer build starts afresh.
    static let again: TimeInterval = 3600
    static let later: TimeInterval = 12 * 3600
    static let most = 4

    /// Whether to try the build [tag] on a TV now, given what was tried there before.
    public static func due(_ tried: Tried?, tag: String, now: Date) -> Bool {
        guard let tried, tried.tag == tag else { return true }
        if tried.done == true { return false }
        return now.timeIntervalSince(tried.at) >= (tried.tries < most ? again : later)
    }

    /// The ways in to try, in order: the one saved for the TV, then each address it's known at, as a rooted TV and as
    /// one in Developer Mode, with the keys this Mac has (the saved key, or ~/.ssh/tv_webos, webos_tv, lgtv_webos).
    public static func ways(saved: WebOSSSH?, hosts: [String?]) -> [WebOSSSH] {
        var out: [WebOSSSH] = []
        if let saved, !saved.host.isEmpty { out.append(saved) }
        for host in hosts {
            guard let host = host?.trimmingCharacters(in: .whitespacesAndNewlines), !host.isEmpty else { continue }
            for mode in [WebOSSSH.Mode.root, .developerMode] {
                let way = WebOSSSH(host: host, mode: mode, keyPath: saved?.keyPath ?? "")
                if !out.contains(where: { $0.host == way.host && $0.mode == way.mode }) { out.append(way) }
            }
        }
        return out
    }
}

#if os(macOS)
extension WebOSAutoUpdate {
    static let key = "webos.autoUpdate.2"
    @MainActor static var running = false
    @MainActor static var saidNoReleases = false
    /// What was said once already since the app opened (a TV that's off, or whose address isn't known).
    @MainActor static var saidOnce: Set<String> = []

    /// A line for this Mac's log of LG updates.
    static func say(_ line: String) {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Woodruff Family", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("lg-updates.log")
        guard let data = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n".data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            // Kept short: started again once it's past a megabyte.
            if let size = try? handle.seekToEnd(), size > 1 << 20 { try? handle.truncate(atOffset: 0) }
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: file)
        }
    }
}

extension Fleet {
    /// Installs the newest LG build on each LG TV that's behind, on, and not in the middle of a film.
    public func updateWebOSTVs() async {
        guard !Demo.isOn, !WebOSAutoUpdate.running else { return }
        let lg = tvs.filter { platform(of: $0) == .webOS && !$0.isUnpaired }
        guard !lg.isEmpty else { return }
        guard let release = latest[.webOS] else {
            // The LG app's releases are private: without a token here this Mac can't see them.
            if !WebOSAutoUpdate.saidNoReleases {
                WebOSAutoUpdate.saidNoReleases = true
                WebOSAutoUpdate.say("The LG app's releases can't be read from this Mac: \(releaseErrors[.webOS] ?? "no answer yet").")
            }
            return
        }
        let tag = release.tag_name
        for tv in lg where !tv.online && isBehind(tv) && WebOSAutoUpdate.saidOnce.insert("off " + tv.id + tag).inserted {
            WebOSAutoUpdate.say("\(tv.name): \(tag) is waiting for it. It's off or out of reach now, and gets it within ten minutes of being on.")
        }
        let waiting = lg.filter { $0.online && $0.playing == nil && isBehind($0) }
        guard !waiting.isEmpty,
              let asset = release.assets.first(where: { $0.name == "woodruff-family.ipk" }) ?? release.assets.first(where: { $0.name.hasSuffix(".ipk") }) else { return }
        WebOSAutoUpdate.running = true
        defer { WebOSAutoUpdate.running = false }
        var tried: [String: WebOSAutoUpdate.Tried] = Saved.load(WebOSAutoUpdate.key) ?? [:]
        var ipk: URL?
        var installed = false
        for tv in waiting {
            guard WebOSAutoUpdate.due(tried[tv.id], tag: tag, now: Date()) else { continue }
            let name = tv.name
            let known = extras[tv.id]
            var ways = waysIn(to: tv)
            if ways.isEmpty {
                // Its address isn't known here yet (a TV another TV passes on): the home network is asked for it now.
                await scanNetwork()
                ways = waysIn(to: tv)
            }
            guard !ways.isEmpty else {
                // Not counted as a try: it's looked for again at the next look, ten minutes on.
                if WebOSAutoUpdate.saidOnce.insert("address " + tv.id + tag).inserted {
                    WebOSAutoUpdate.say("\(name): \(tag) is waiting, but this Mac can't find the TV's address. Save it on the TV's page here (Install Updates from This Mac).")
                }
                continue
            }
            let now = Date()
            let before = tried[tv.id].flatMap { $0.tag == tag ? $0.tries : nil } ?? 0
            tried[tv.id] = WebOSAutoUpdate.Tried(tag: tag, tries: before + 1, at: now)
            Saved.save(WebOSAutoUpdate.key, tried)
            var way: WebOSSSH?
            var refused: [String] = []
            for w in ways {
                if let why = await WebOSInstaller.test(w) { refused.append("\(w.user)@\(w.host):\(w.port): \(why)") } else { way = w; break }
            }
            guard let way else {
                WebOSAutoUpdate.say("\(name): \(tag) is waiting, but the TV let this Mac in no way. " + refused.joined(separator: " | "))
                continue
            }
            // Another Mac may have put it on meanwhile, or a film may have started.
            await refresh()
            guard let fresh = tvs.first(where: { $0.id == tv.id }), fresh.online, fresh.playing == nil, isBehind(fresh) else { continue }
            do {
                if ipk == nil { ipk = try await ReleaseFeed(token: githubToken).download(asset) }
                guard let ipk else { continue }
                // Woodruff is opened again only where it was in front: nobody is taken off another app or input.
                try await WebOSInstaller.install(ipk, on: way, launch: fresh.onScreen) { line in WebOSAutoUpdate.say("\(name): \(line)") }
                if known?.ssh != way { extras[tv.id, default: TVExtras()].ssh = way }
                tried[tv.id]?.done = true
                Saved.save(WebOSAutoUpdate.key, tried)
                WebOSAutoUpdate.say("\(name): \(tag) went on by itself (\(way.user)@\(way.host)).")
                installed = true
            } catch {
                WebOSAutoUpdate.say("\(name): \(tag) didn't go on: \(error.localizedDescription)")
            }
        }
        if installed {
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            await refresh()
        }
    }

    /// The ways in to [tv] from here: the one saved for it, then every address it's known at (its remote's, its own
    /// where it's paired here, where it last answered, and where the search of the home network found it).
    private func waysIn(to tv: FleetTV) -> [WebOSSSH] {
        let known = extras[tv.id]
        let found = lanFound.first(where: { $0.id == tv.id }) ?? lanFound.first(where: { $0.name == tv.name })
        let hosts: [String?] = [known?.ssh?.host, known?.lgHost, hub(tv.id)?.connection.base.host, known?.lastHost, tv.foundAt?.host, found?.host]
        return WebOSAutoUpdate.ways(saved: known?.ssh, hosts: hosts)
    }
}
#endif
