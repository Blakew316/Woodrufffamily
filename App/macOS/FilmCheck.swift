import AVKit
import WoodruffKit

/// A film played by the app itself, to check from Terminal that this Mac plays it from Google Drive:
///
///     open -a "Woodruff Family" --args -filmCheck "Dune"
///
/// (Several, one after another: "Dune|Avatar". "largest" is the film with the biggest file, "id:…" a Drive file.)
/// Each plays with the sound off for a minute, jumps to the middle and plays half a minute more, then closes. Nothing
/// is kept for Continue Watching. What happened is written as "Film check" lines to
/// ~/Library/Logs/Woodruff Family/film-check.log and to the diagnostics log: how long it took to start, whether it
/// kept playing, and what was asked of Google.
@MainActor
enum FilmCheck {
    private static var window: NSWindow?
    private static var asked = false

    /// How long each film plays from its start, and again from its middle.
    private static let fromStart: Double = 60
    private static let fromMiddle: Double = 30

    /// Once the app is up: nothing unless the app was opened with -filmCheck (this launch's own argument, never a
    /// saved setting).
    static func startIfAsked() {
        guard !asked,
              let names = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)["filmCheck"] as? String,
              !names.isEmpty else { return }
        asked = true
        Task {
            // The app's own start comes first (the TVs, the settings arriving from the family's other devices).
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            for part in names.split(separator: "|") {
                let name = part.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { await check(name) }
            }
            note("finished")
        }
    }

    private static func check(_ name: String) async {
        guard GoogleDrive.signedIn else { note("\(name): Google Drive isn’t signed in on this Mac"); return }
        var film: (id: String, title: String)?
        if name.hasPrefix("id:") {
            film = (id: String(name.dropFirst(3)), title: name)
        } else {
            film = DriveLibrary.shared.films(named: name).first
            if film == nil {
                await DriveLibrary.shared.refresh(force: true)
                film = DriveLibrary.shared.films(named: name).first
            }
        }
        guard let film else {
            note("\(name): no film of that name among \(DriveLibrary.shared.titleCount) titles")
            return
        }
        let play = PhonePlay(source: .drive(film.id), key: "drive:\(film.id)", title: film.title, start: 0)
        let stream = DriveStream(fileID: film.id, name: film.title)
        let item = AVPlayerItem(asset: stream.asset())
        PhonePlayback.quickStart(item)
        let p = AVPlayer(playerItem: item)
        p.isMuted = true
        show(p, film.title)
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
        guard item.status == .readyToPlay else { failed(play, "didn’t open", item, stream, began); return }
        PhonePlayback.startPlaying(p)
        guard await moving(p, item, near: 0, within: limit) != nil else { failed(play, "didn’t start", item, stream, began); return }
        let started = Date().timeIntervalSince(began)
        PhonePlayback.playing(item)
        let first = await watch(p, item, for: fromStart)
        guard first.ok else { failed(play, "stopped", item, stream, began); return }
        note("\(film.title) (\(about(item, stream))): started in \(String(format: "%.1f", started)) s; \(first.words); asked Google for \(stream.askedNow())")

        // From the middle, as after a jump along the bar.
        let length = item.duration.seconds
        guard length.isFinite, length > 600 else { return }
        let jumped = Date()
        jump(p, to: length / 2)
        guard let again = await moving(p, item, near: length / 2, within: 45) else { failed(play, "didn’t play from the middle", item, stream, jumped); return }
        let second = await watch(p, item, for: fromMiddle)
        guard second.ok else { failed(play, "stopped after the jump to the middle", item, stream, jumped); return }
        note("\(film.title), from the middle: playing again in \(String(format: "%.1f", again)) s; \(second.words); asked Google for \(stream.askedNow())")
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
        if let bytes = stream.sizeNow() { bits.append(String(format: "%.1f GB", Double(bytes) / 1_073_741_824)) }
        if let r = PhonePlayback.rates(stream, item) {
            bits.append(String(format: "needs %.0f Mb/s, arrived at up to %.0f Mb/s", r.needs, r.fastest))
        }
        return bits.isEmpty ? "nothing known of the file" : bits.joined(separator: ", ")
    }

    private static func failed(_ play: PhonePlay, _ what: String, _ item: AVPlayerItem, _ stream: DriveStream, _ began: Date) {
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

    private static func note(_ words: String) {
        let line = "Film check, \(words)"
        Diagnostics.shared.notePlayback(line)
        guard let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else { return }
        let file = lib.appendingPathComponent("Logs/Woodruff Family/film-check.log")
        let data = Data("\(ISO8601DateFormatter.plain.string(from: Date()))\tbuild \(AppBuild.label)\t\(line)\n".utf8)
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
