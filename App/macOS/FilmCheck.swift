import AVKit
import WoodruffKit

/// Films played and asked after by the app itself, to check from Terminal how this Mac gets them from Google Drive:
///
///     open -a "Woodruff Family" --args -filmCheck "Dune"
///
/// Several things can be asked for, one after another, with | between them:
/// - a film's name (or "id:…", a Drive file): it plays with the sound off for a minute, jumps to the middle and plays
///   half a minute more, then closes. Nothing is kept for Continue Watching.
/// - "own:<film>": the same, played by the app's own player (`FilmPlayer`) instead of Apple's: how long its index
///   took (read from Google, or kept on this Mac from the last time), how long it took to start, how often it
///   stopped to wait, and what Google was asked for. "ownfresh:<film>" reads the index from Google again first.
/// - "probe": every film in the library is asked of Google for its first byte, to see which it sends right now and
///   which it refuses with its daily limit.
/// - "ask:<film>": Google is asked for more and more of the film (2 bytes, 64 KB … to the end of the file), by this
///   Mac and through each paired TV, and only its answer's first lines are read: how much it will send right now, and
///   whether it treats the TVs differently.
/// - "who": which Google account and client this Mac reads Drive with, and each TV's client.
/// - "copytest": whether Google lets the app make a copy in its own folder in Drive, tried with the smallest video
///   (the copy is removed again).
/// - "copy:<film>": a copy of the film is made in the app's own folder, played as above, then removed.
///   "keepcopy:<film>" leaves it there (the app plays it when Google refuses the film itself, and removes it two days
///   on).
///
/// A film Google refuses is also asked for through each paired TV, which asks Google with the TV's own sign-in.
/// What happened is written as "Film check" lines to ~/Library/Logs/Woodruff Family/film-check.log and, shortened,
/// to the diagnostics log.
@MainActor
enum FilmCheck {
    private static var window: NSWindow?
    private static var asked = false

    /// How long each film plays from its start (-filmCheckSeconds says otherwise), and again from its middle.
    private static var fromStart: Double = 60
    private static let fromMiddle: Double = 30

    private static let files = "https://www.googleapis.com/drive/v3/files"

    /// Once the app is up: nothing unless the app was opened with -filmCheck (this launch's own argument, never a
    /// saved setting).
    static func startIfAsked() {
        guard !asked,
              let names = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)["filmCheck"] as? String,
              !names.isEmpty else { return }
        asked = true
        let given = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)["filmCheckSeconds"]
        if let seconds = (given as? String).flatMap({ Double($0) }) ?? (given as? NSNumber)?.doubleValue, seconds >= 10 {
            fromStart = min(seconds, 4 * 3600)
        }
        Task {
            // The app's own start comes first (the TVs, the settings arriving from the family's other devices).
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            for part in names.split(separator: "|") {
                let name = part.trimmingCharacters(in: .whitespaces)
                if name.isEmpty { continue }
                guard GoogleDrive.signedIn else { note("\(name): Google Drive isn’t signed in on this Mac"); continue }
                if name == "probe" {
                    await probe()
                } else if name == "who" {
                    await who()
                } else if name.hasPrefix("own:") {
                    if let film = await find(String(name.dropFirst(4))) { await playOwn(film.id, film.title, fresh: false) }
                } else if name.hasPrefix("ownfresh:") {
                    if let film = await find(String(name.dropFirst(9))) { await playOwn(film.id, film.title, fresh: true) }
                } else if name.hasPrefix("ask:") {
                    await ask(String(name.dropFirst(4)))
                } else if name == "copytest" {
                    await copyTest()
                } else if name.hasPrefix("copy:") {
                    await copied(String(name.dropFirst(5)), keep: false)
                } else if name.hasPrefix("keepcopy:") {
                    await copied(String(name.dropFirst(9)), keep: true)
                } else if let film = await find(name) {
                    _ = await play(film.id, film.title)
                }
            }
            note("finished")
        }
    }

    /// The film asked for by name (or "id:…"), read from Drive again when the library kept here doesn't have it.
    private static func find(_ name: String) async -> (id: String, title: String)? {
        if name.hasPrefix("id:") { return (id: String(name.dropFirst(3)), title: name) }
        var film = DriveLibrary.shared.films(named: name).first
        if film == nil {
            await DriveLibrary.shared.refresh(force: true)
            film = DriveLibrary.shared.films(named: name).first
        }
        if film == nil { note("\(name): no film of that name among \(DriveLibrary.shared.titleCount) titles") }
        return film
    }

    // MARK: Playing

    /// Plays Drive file [id] from its start, then from its middle, and writes down how it went. True when both played.
    private static func play(_ id: String, _ title: String) async -> Bool {
        let play = PhonePlay(source: .drive(id), key: "drive:\(id)", title: title, start: 0)
        let stream = DriveStream(fileID: id, name: title)
        let item = AVPlayerItem(asset: stream.asset())
        PhonePlayback.quickStart(item)
        let p = AVPlayer(playerItem: item)
        p.isMuted = true
        show(p, title)
        defer {
            p.pause()
            p.replaceCurrentItem(with: nil)
            window?.close()
            window = nil
        }

        // From the start: the file opening, then the picture moving.
        let began = Date()
        let limit = Double(PhonePlayback.startLimit)
        while item.status == .unknown, Date().timeIntervalSince(began) < limit {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        guard item.status == .readyToPlay else { await failed(play, id, "didn’t open", item, stream, began); return false }
        PhonePlayback.startPlaying(p)
        guard await moving(p, item, near: 0, within: limit) != nil else { await failed(play, id, "didn’t start", item, stream, began); return false }
        let started = Date().timeIntervalSince(began)
        PhonePlayback.playing(item)
        let first = await watch(p, item, for: fromStart)
        guard first.ok else { await failed(play, id, "stopped", item, stream, began); return false }
        note("\(title) (\(about(item, stream))): started in \(String(format: "%.1f", started)) s; \(first.words); asked Google for \(stream.askedNow())")

        // From the middle, as after a jump along the bar.
        let length = item.duration.seconds
        guard length.isFinite, length > 600 else { return true }
        let jumped = Date()
        jump(p, to: length / 2)
        guard let again = await moving(p, item, near: length / 2, within: 45) else {
            await failed(play, id, "didn’t play from the middle", item, stream, jumped)
            return false
        }
        let second = await watch(p, item, for: fromMiddle)
        guard second.ok else { await failed(play, id, "stopped after the jump to the middle", item, stream, jumped); return false }
        note("\(title), from the middle: playing again in \(String(format: "%.1f", again)) s; \(second.words); asked Google for \(stream.askedNow())")
        return true
    }

    /// A jump asked for without waiting on it (the kind that reports back doesn't return until the picture is there).
    private static func jump(_ p: AVPlayer, to seconds: Double) {
        p.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: PhonePlayback.nearEnough, toleranceAfter: PhonePlayback.nearEnough)
    }

    /// Waits until the picture is moving at about [place] (seconds into the film): how long that took, or nil when
    /// it failed or took longer than [limit].
    private static func moving(_ p: AVPlayer, _ item: AVPlayerItem, near place: Double, within limit: Double) async -> Double? {
        let began = Date()
        var landed: Double?
        while Date().timeIntervalSince(began) < limit {
            if item.status == .failed { return nil }
            let t = p.currentTime().seconds
            if t.isFinite, abs(t - place) < 10 {
                if let l = landed {
                    if t > l + 0.3 { return Date().timeIntervalSince(began) }
                } else {
                    landed = t
                }
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return nil
    }

    /// Lets it play for [seconds]: how much of the film went by, how often it stopped to wait and for how long, and
    /// how far ahead it had read at the end.
    private static func watch(_ p: AVPlayer, _ item: AVPlayerItem, for seconds: Double) async -> (words: String, ok: Bool) {
        let from = p.currentTime().seconds, began = Date()
        var stalls = 0, waited = 0.0, wasPlaying = true, last = Date()
        while Date().timeIntervalSince(began) < seconds, item.status != .failed {
            try? await Task.sleep(nanoseconds: 250_000_000)
            let now = Date(), playing = p.timeControlStatus == .playing
            if !playing { waited += now.timeIntervalSince(last) }
            if wasPlaying && !playing { stalls += 1 }
            wasPlaying = playing
            last = now
        }
        let at = p.currentTime().seconds
        var ahead = 0.0
        for value in item.loadedTimeRanges {
            let r = value.timeRangeValue
            if r.start.seconds <= at + 1, r.end.seconds > at { ahead = max(ahead, r.end.seconds - at) }
        }
        let words = String(format: "in %.0f s it played %.0f s, stopped to wait %ld times (%.1f s), %.0f s read ahead",
                           Date().timeIntervalSince(began), max(0, at - from), stalls, waited, ahead)
        return (words, item.status != .failed)
    }

    private static func about(_ item: AVPlayerItem, _ stream: DriveStream) -> String {
        var bits: [String] = []
        let size = item.presentationSize
        if size.width > 0 { bits.append("\(Int(size.width))×\(Int(size.height))") }
        if let bytes = stream.sizeNow() { bits.append(gb(bytes)) }
        if let r = PhonePlayback.rates(stream, item) {
            bits.append(String(format: "needs %.0f Mb/s, arrived at up to %.0f Mb/s", r.needs, r.fastest))
        }
        return bits.isEmpty ? "nothing known of the file" : bits.joined(separator: ", ")
    }

    private static func gb(_ bytes: Int64) -> String { String(format: "%.1f GB", Double(bytes) / 1_073_741_824) }

    private static func failed(_ play: PhonePlay, _ id: String, _ what: String, _ item: AVPlayerItem, _ stream: DriveStream, _ began: Date) async {
        var words = "no reason was given"
        if let refused = stream.refusalNow() {
            words = refused
        } else if item.status == .failed {
            words = PhonePlayback.failure(stream.recentFailure ?? item.error, play)
        } else if let slow = PhonePlayback.slowerThanFilm(stream, item) {
            words = slow
        }
        let after = String(format: "%.0f", Date().timeIntervalSince(began))
        note("\(play.title): \(what) after \(after) s (\(PhonePlayback.errorTrail(item))): \(words); asked Google for \(stream.askedNow())")
        // Google's daily limit: whether the TVs, with their own sign-ins, are sent the same file right now.
        if stream.overLimitNow() {
            let tvs = await throughTVs(id)
            note("\(play.title), asked for through the TVs: \(tvs)")
        }
    }

    private static func show(_ p: AVPlayer, _ title: String) {
        let view = AVPlayerView()
        view.player = p
        view.controlsStyle = .none
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 540),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "Film check: \(title)"
        w.backgroundColor = .black
        w.isReleasedWhenClosed = false
        w.contentView = view
        w.center()
        w.orderFront(nil)
        window = w
    }

    // MARK: The app's own player

    /// Plays Drive file [id] with the app's own player, in silence: from its start, then from its middle, and writes
    /// down how it went. [fresh]: its index is read from Google again, whatever is kept on this Mac.
    private static func playOwn(_ id: String, _ title: String, fresh: Bool) async {
        let play = PhonePlay(source: .drive(id), key: "drive:\(id)", title: title, start: 0)
        let stream = DriveStream(fileID: id, name: title)
        func why(_ error: Error?) -> String {
            stream.refusalNow() ?? PhonePlayback.failure(stream.recentFailure ?? error, play)
        }
        let began = Date()
        let opened: FilmIndex.Opened
        do {
            opened = try await FilmIndex.open(stream, id: id, fresh: fresh)
        } catch {
            note("\(title), the app’s own player: its index couldn’t be read after \(String(format: "%.1f", Date().timeIntervalSince(began))) s: \(why(error)); asked Google for \(stream.askedNow())")
            return
        }
        let indexed = Date().timeIntervalSince(began)
        let player = FilmPlayer(asset: opened.asset, bytes: stream)
        player.mute(true)
        do {
            try await player.open()
        } catch {
            note("\(title), the app’s own player: nothing in it can be played (\(error)); asked Google for \(stream.askedNow())")
            return
        }
        let film = player.film
        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspect
        showOwn(layer, title)
        defer {
            player.close()
            window?.close()
            window = nil
        }
        player.show(on: layer.sampleBufferRenderer)

        // From the start.
        let asked = Date()
        player.start(at: 0)
        guard await moving(player, past: 0.3, within: Double(PhonePlayback.startLimit)) else {
            note("\(title), the app’s own player: didn’t start (\(player.state)): \(why(player.failure)); asked Google for \(stream.askedNow())")
            return
        }
        let started = Date().timeIntervalSince(asked)
        // The film Google sends must be the one the kept index was read from.
        if !FilmIndex.stillRight(opened, stream) {
            note("\(title), the app’s own player: the film has changed since its index was kept; read again")
            FilmIndex.forget(id)
            player.close()
            window?.close()
            window = nil
            if !fresh { await playOwn(id, title, fresh: true) }
            return
        }
        let first = await watchOwn(player, for: fromStart)
        let index = opened.file == nil ? "read through the stream (it couldn’t be kept)"
            : opened.fresh ? "read from Google and kept" : "kept on this Mac"
        note("\(title), the app’s own player (\(aboutOwn(film, stream))): index \(index) in \(String(format: "%.1f", indexed)) s, started in \(String(format: "%.1f", started)) s; \(first); asked Google for \(stream.askedNow())")
        guard player.state != .failed else {
            note("\(title), the app’s own player: stopped: \(why(player.failure))")
            return
        }

        // From the middle, as after a jump along the bar.
        guard film.length > 600 else { return }
        let jumped = Date()
        player.seek(to: film.length / 2)
        guard await moving(player, past: film.length / 2 + 0.3, within: 45) else {
            note("\(title), the app’s own player: didn’t play from the middle (\(player.state)): \(why(player.failure)); asked Google for \(stream.askedNow())")
            return
        }
        let again = Date().timeIntervalSince(jumped)
        let second = await watchOwn(player, for: fromMiddle)
        note("\(title), the app’s own player, from the middle: playing again in \(String(format: "%.1f", again)) s; \(second); asked Google for \(stream.askedNow())")
    }

    /// Waits until the app's own player is playing past [place] (seconds into the film): false when it failed or
    /// took longer than [limit].
    private static func moving(_ player: FilmPlayer, past place: Double, within limit: Double) async -> Bool {
        let began = Date()
        while Date().timeIntervalSince(began) < limit {
            if player.state == .failed { return false }
            if player.state == .playing, player.time >= place { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }

    /// Lets the app's own player play for [seconds]: how much of the film went by, how often it stopped to wait and
    /// for how long, and what it read.
    private static func watchOwn(_ player: FilmPlayer, for seconds: Double) async -> String {
        let from = player.time, began = Date(), before = player.notes
        while Date().timeIntervalSince(began) < seconds, player.state != .failed, player.state != .ended {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        let now = player.notes
        let picture = now.reads[0] - before.reads[0], sound = now.reads[1] - before.reads[1]
        return String(format: "in %.0f s it played %.1f s, stopped to wait %ld times (%.1f s), read %ld runs of picture and %ld of sound, the slowest in %.2f s, %ld asked again, decoders started afresh %ld times",
                      Date().timeIntervalSince(began), max(0, player.time - from), now.waits - before.waits,
                      now.waited - before.waited, picture, sound, now.slowest, now.again - before.again,
                      now.mended - before.mended)
    }

    private static func aboutOwn(_ film: FilmPlayer.Film, _ stream: DriveStream) -> String {
        var bits: [String] = []
        if let p = film.picture { bits.append(String(format: "picture %@ %ld×%ld %.0f fps", p.codec, p.width, p.height, p.framesASecond)) }
        for s in film.sounds {
            bits.append("sound \(s.codec) \(s.channels) channels" + (s.language.map { " \($0)" } ?? "") + (s.playable ? "" : ", can’t be played here")
                        + (s.id == film.sound ? ", playing" : ""))
        }
        if !film.words.isEmpty { bits.append("\(film.words.count) subtitle tracks") }
        if let bytes = stream.sizeNow() {
            bits.append(gb(bytes))
            if film.length > 60 { bits.append(String(format: "needs %.0f Mb/s", Double(bytes) * 8 / film.length / 1_000_000)) }
        }
        let fastest = stream.fastestNow()
        if fastest > 0 { bits.append(String(format: "arrived at up to %.0f Mb/s", fastest)) }
        return bits.joined(separator: ", ")
    }

    private static func showOwn(_ layer: AVSampleBufferDisplayLayer, _ title: String) {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 960, height: 540))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        layer.frame = view.bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer?.addSublayer(layer)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 540),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "Film check, the app’s own player: \(title)"
        w.backgroundColor = .black
        w.isReleasedWhenClosed = false
        w.contentView = view
        w.center()
        w.orderFront(nil)
        window = w
    }

    // MARK: Through the TVs

    /// Drive file [id]'s first byte asked of each paired TV's own stream (the TV asks Google with its sign-in): what
    /// each answered.
    private static func throughTVs(_ id: String) async -> String {
        let hubs = Fleet.shared.hubs
        guard !hubs.isEmpty else { return "no TV is paired with this Mac" }
        var said: [String] = []
        for hub in hubs {
            var r = URLRequest(url: TVClient(hub: hub, routeID: "this").streamURL("drive:\(id)"))
            r.setValue("bytes=0-0", forHTTPHeaderField: "Range")
            r.timeoutInterval = 25
            do {
                let (bytes, resp) = try await URLSession.woodruff.bytes(for: r)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if code == 200 || code == 206 {
                    bytes.task.cancel()
                    said.append("\(hub.name) was sent it (\(code))")
                    continue
                }
                var body = Data()
                for try await b in bytes {
                    body.append(b)
                    if body.count >= 200 { break }
                }
                bytes.task.cancel()
                said.append("\(hub.name) answered \(code) \(String(decoding: body, as: UTF8.self))")
            } catch {
                let ns = error as NSError
                said.append("\(hub.name) couldn’t be asked (\(ns.domain) \(ns.code))")
            }
        }
        return said.joined(separator: "; ")
    }

    // MARK: What Google answers

    /// Parts of a film to ask for, smallest first: Google's answer to each shows how much it will send right now.
    private static let direct: [(String, String)] = [
        ("2 bytes", "bytes=0-1"), ("64 KB", "bytes=0-65535"), ("1 MB", "bytes=0-1048575"), ("4 MB", "bytes=0-4194303"),
        ("8 MB", "bytes=0-8388607"), ("64 MB", "bytes=0-67108863"), ("1 GB", "bytes=0-1073741823"), ("to the end", "bytes=0-"),
    ]
    private static let relayed: [(String, String)] = [
        ("2 bytes", "bytes=0-1"), ("8 MB", "bytes=0-8388607"), ("64 MB", "bytes=0-67108863"), ("to the end", "bytes=0-"),
    ]

    /// Google asked for more and more of the film, by this Mac and through each paired TV (which asks with its own
    /// sign-in). Only each answer's first lines are read: nothing is downloaded.
    private static func ask(_ name: String) async {
        guard let film = await find(name) else { return }
        var mine: [String] = []
        for (what, range) in direct {
            let a = await answer(film.id, range: range)
            mine.append("\(what) \(a)")
        }
        note("\(film.title), asked of Google by this Mac: " + mine.joined(separator: "; "))
        for hub in Fleet.shared.hubs {
            var theirs: [String] = []
            for (what, range) in relayed {
                var r = URLRequest(url: TVClient(hub: hub, routeID: "this").streamURL("drive:\(film.id)"))
                r.setValue(range, forHTTPHeaderField: "Range")
                r.timeoutInterval = 25
                let a = await answer(to: r, on: URLSession.woodruff)
                theirs.append("\(what) \(a)")
                // A TV that's off isn't asked the rest.
                if a.hasPrefix("couldn’t be asked") { break }
            }
            note("\(film.title), asked of Google by \(hub.name): " + theirs.joined(separator: "; "))
        }
    }

    /// What Google answers this Mac when asked for [range] of Drive file [id].
    private static func answer(_ id: String, range: String) async -> String {
        guard let signIn = try? await GoogleDrive.token() else { return "couldn’t be asked (no sign-in)" }
        var r = URLRequest(url: GoogleDrive.mediaURL(id))
        r.setValue("Bearer \(signIn)", forHTTPHeaderField: "Authorization")
        r.setValue(range, forHTTPHeaderField: "Range")
        r.timeoutInterval = 25
        return await answer(to: r, on: URLSession.shared)
    }

    /// The answer to [r]: sent (and what it started to send is dropped), or refused with the reason given.
    private static func answer(to r: URLRequest, on session: URLSession) async -> String {
        do {
            let (bytes, resp) = try await session.bytes(for: r)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200 || code == 206 {
                bytes.task.cancel()
                return "sent (\(code))"
            }
            var body = Data()
            for try await b in bytes {
                body.append(b)
                if body.count >= 2048 { break }
            }
            bytes.task.cancel()
            var why = GoogleDrive.reason(body)
            if why.isEmpty {
                why = String(String(decoding: body, as: UTF8.self).replacingOccurrences(of: "\n", with: " ").prefix(120))
            }
            return "refused (\(code)\(why.isEmpty ? "" : " " + why))"
        } catch {
            let ns = error as NSError
            return "couldn’t be asked (\(ns.domain) \(ns.code))"
        }
    }

    /// Which Google account and client this Mac reads Drive with, and each TV's client: a client is told by the
    /// digits its id starts with (its project's number at Google).
    private static func who() async {
        if GoogleDrive.email == nil { await GoogleDrive.loadEmail() }
        var said = ["this Mac reads Drive as \(GoogleDrive.email ?? "an account Google didn’t name") with client \(project(GoogleDrive.clientID))"]
        for hub in Fleet.shared.hubs {
            let got = try? await TVClient(hub: hub, routeID: "this").sharedKey("google")
            if let key = got ?? nil, let id = key.split(separator: "\n").first {
                said.append("\(hub.name) has client \(project(String(id)))")
            } else {
                said.append("\(hub.name) didn’t say")
            }
        }
        note("who: " + said.joined(separator: "; "))
    }

    private static func project(_ client: String?) -> String {
        guard let first = client?.split(separator: "-").first, !first.isEmpty else { return "none" }
        return String(first)
    }

    // MARK: Which films Google sends

    /// Every film's first byte asked of Google, one after another.
    private static func probe() async {
        var all = DriveLibrary.shared.films()
        if all.isEmpty {
            await DriveLibrary.shared.refresh(force: true)
            all = DriveLibrary.shared.films()
        }
        var sent = 0
        var refused: [(id: String, title: String)] = [], unknown: [String] = []
        for film in all {
            let answer = await GoogleDrive.sends(film.id)
            if answer == true {
                sent += 1
            } else if answer == false {
                refused.append(film)
            } else {
                unknown.append(film.title)
            }
        }
        let sum = "probe: of \(all.count) films Google sends \(sent) right now, refuses \(refused.count) with its daily limit, and \(unknown.count) couldn’t be asked"
        var more = ""
        if !refused.isEmpty { more += "; refused: " + refused.map { $0.title }.joined(separator: " | ") }
        if !unknown.isEmpty { more += "; couldn’t be asked: " + unknown.prefix(30).joined(separator: " | ") }
        note(sum, more: more)
        // The first few refused films, asked for through the TVs.
        for film in refused.prefix(3) {
            let tvs = await throughTVs(film.id)
            note("\(film.title), asked for through the TVs: \(tvs)")
        }
    }

    // MARK: Copies

    /// A file's name and size as Drive has them now.
    private static func facts(_ id: String) async -> (name: String, size: Int64)? {
        var c = URLComponents(string: "\(files)/\(id)")!
        c.queryItems = [.init(name: "fields", value: "name,size"), .init(name: "supportsAllDrives", value: "true")]
        guard let j = try? await GoogleDrive.get(c.url!) else { return nil }
        return (name: j["name"] as? String ?? "", size: Int64(j["size"] as? String ?? "") ?? 0)
    }

    /// Free space in the signed-in account's Drive: nil when it couldn't be read, `Int64.max` when Google sets no limit.
    private static func room() async -> Int64? {
        guard let url = URL(string: "https://www.googleapis.com/drive/v3/about?fields=storageQuota"),
              let j = try? await GoogleDrive.get(url), let q = j["storageQuota"] as? [String: Any] else { return nil }
        guard let limit = Int64(q["limit"] as? String ?? "") else { return Int64.max }
        return limit - (Int64(q["usage"] as? String ?? "") ?? 0)
    }

    private static func roomWords(_ free: Int64?) -> String {
        guard let free else { return "Drive’s free space couldn’t be read" }
        return free == Int64.max ? "Drive has no limit on space" : "\(gb(free)) free in Drive"
    }

    private static func remove(_ id: String) async -> Bool {
        guard let signIn = try? await GoogleDrive.token(), let url = URL(string: "\(files)/\(id)") else { return false }
        var r = URLRequest(url: url)
        r.httpMethod = "DELETE"
        r.setValue("Bearer \(signIn)", forHTTPHeaderField: "Authorization")
        r.timeoutInterval = 30
        guard let (_, resp) = try? await URLSession.shared.data(for: r) else { return false }
        return ((resp as? HTTPURLResponse)?.statusCode ?? 0) / 100 == 2
    }

    /// Whether Google lets the app make a copy in its own folder at all: tried with the smallest video in Drive, read
    /// back, and removed.
    private static func copyTest() async {
        var c = URLComponents(string: files)!
        c.queryItems = [.init(name: "q", value: "mimeType contains 'video/' and trashed = false"),
                        .init(name: "orderBy", value: "quotaBytesUsed"), .init(name: "pageSize", value: "20"),
                        .init(name: "fields", value: "files(id,name,size)")]
        let listed = (try? await GoogleDrive.get(c.url!))?["files"] as? [[String: Any]] ?? []
        var small: (id: String, name: String, size: Int64)?
        for f in listed {
            guard let id = f["id"] as? String, let size = Int64(f["size"] as? String ?? ""), size > 0 else { continue }
            small = (id: id, name: f["name"] as? String ?? "", size: size)
            break
        }
        let free = await room()
        guard let small else { note("copytest: no small video was found to try a copy with (\(roomWords(free)))"); return }
        let mb = String(format: "%.1f", Double(small.size) / 1_048_576)
        let began = Date()
        do {
            let copy = try await GoogleDrive.makeCopy(of: small.id)
            let took = String(format: "%.1f", Date().timeIntervalSince(began))
            let reads = await GoogleDrive.sends(copy)
            let removed = await remove(copy)
            var read = "the copy couldn’t be read"
            if reads == true { read = "Google sends the copy" } else if reads == false { read = "Google refuses the copy too" }
            note("copytest: Google made a copy of a \(mb) MB video in \(took) s; \(read); \(removed ? "the copy was removed" : "the copy couldn’t be removed"); \(roomWords(free))")
        } catch {
            let why = (error as? GoogleDrive.Failure)?.message ?? error.localizedDescription
            note("copytest: Google wouldn’t make a copy of a \(mb) MB video: \(why) (\(roomWords(free)))")
        }
    }

    /// A copy of the film made in the app's own folder and played. Removed afterwards unless [keep].
    private static func copied(_ name: String, keep: Bool) async {
        guard let film = await find(name) else { return }
        let size = await facts(film.id)?.size ?? 0
        let free = await room()
        // Room for it with some to spare: Drive's space is the family's mail and photos too.
        let spare: Int64 = 30 << 30
        if let free, free != Int64.max, size > 0, free < size + spare {
            note("\(film.title): no copy made, it is \(gb(size)) and \(roomWords(free))")
            return
        }
        let began = Date()
        do {
            let copy = try await GoogleDrive.makeCopy(of: film.id)
            note("\(film.title): Google made a copy (\(gb(size))) in \(String(format: "%.0f", Date().timeIntervalSince(began))) s; \(roomWords(free))")
            let played = await play(copy, "\(film.title) (the copy)")
            if keep {
                note("\(film.title): the copy is kept for two days" + (played ? "" : ", though it didn’t play"))
            } else {
                let removed = await remove(copy)
                note("\(film.title): \(removed ? "the copy was removed" : "the copy couldn’t be removed")")
            }
        } catch {
            let why = (error as? GoogleDrive.Failure)?.message ?? error.localizedDescription
            note("\(film.title): no copy (\(gb(size))): \(why) (\(roomWords(free)))")
        }
    }

    // MARK: Writing it down

    /// [words] to both logs; [more] only to the film check's own (the diagnostics log travels with the family's settings).
    private static func note(_ words: String, more: String = "") {
        let line = "Film check, \(words)"
        Diagnostics.shared.notePlayback(String(line.prefix(700)))
        guard let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else { return }
        let file = lib.appendingPathComponent("Logs/Woodruff Family/film-check.log")
        let data = Data("\(ISO8601DateFormatter.plain.string(from: Date()))\tbuild \(AppBuild.label)\t\(line)\(more)\n".utf8)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: file) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data)
        } else {
            try? data.write(to: file)
        }
    }
}
