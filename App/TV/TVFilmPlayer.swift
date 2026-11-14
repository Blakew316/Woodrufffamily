import UIKit
import AVFoundation
import FilmHeights
import MediaPlayer
import WoodruffKit

/// A Drive film played on this Apple TV by the app's own player (`FilmPlayer`) on its own screen (`FilmScreen`),
/// in place of Apple's player (`NativePlayer`).
///
/// Apple's player can't play a film whose sound and picture are stored far apart: it hops between the two some
/// hundreds of times a second and stops every twenty seconds or so. The app's own player reads each track straight
/// on, as the Android TVs' player does. It has the films Apple's player has been seen hopping on (`TVHandOff`
/// remembers them), and every Drive film when Settings → Watch says so. A film it can't open goes to Apple's
/// player, which says why if it can't either.
///
/// Around the film it does what `NativePlayer` does: where it was left off, the TV's picture mode waited for,
/// where it got to kept every ten seconds, Next Episode, closing at the end, and how it went for the Macs' log.
@MainActor
final class OwnPlayer {
    static let shared = OwnPlayer()

    /// Settings → Watch on Apple TV: every Drive film plays in the app's own player, not only the ones Apple's
    /// player stutters on.
    static let everyKey = "watch.ownPlayerEvery"
    /// On unless it's been switched off in Settings (the owner's choice, build 635): with it off, only the films
    /// Apple's player stutters on play here.
    static var forEvery: Bool { UserDefaults.standard.object(forKey: everyKey) as? Bool ?? true }

    /// Films the app's own player couldn't open since the app started: Apple's player has them.
    private static var gaveUp: Set<String> = []
    /// When each film was last opened again by itself after the device ran out of room (`failed`).
    private static var openedAgain: [String: Date] = [:]
    static func hasGivenUp(on key: String) -> Bool { gaveUp.contains(key) }

    /// Whether [play] is one for the app's own player.
    static func plays(_ play: PhonePlay) -> Bool {
        guard case .drive = play.source, !gaveUp.contains(play.key) else { return false }
        return forEvery || TVHandOff.knows(play.key)
    }

    /// Plays [play] on this Apple TV: in the app's own player when it's one of its films, else in Apple's. Whichever
    /// was showing a film closes first.
    static func start(_ play: PhonePlay) {
        if plays(play) {
            NativePlayer.shared.closeForAnother()
            shared.present(play)
        } else {
            shared.closeForAnother()
            NativePlayer.shared.present(play)
        }
    }

    /// A film's screen is up.
    var isOpen: Bool { screen?.presentingViewController != nil }

    private var screen: FilmScreen?
    private var player: FilmPlayer?
    private var stream: DriveStream?
    private var index: FilmIndex.Opened?
    private var current: PhonePlay?
    private var ticker: Timer?
    private var opening: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    /// The film has been told to play; it has played (its first frame moved).
    private var begun = false
    private var started = false
    private var ticks = 0
    /// A film whose sound comes out with overhead channels (TrueHD Atmos, DTS:X): the Apple TV's HDMI output is
    /// kept in Dolby Atmos while it plays, which is the only way overhead channels travel to the sound system.
    private lazy var heightsKeeper = HeightsOutputKeeper()
    private var heightsFollowed = false
    /// The sound session was told this film's sound is multichannel (sound the app decodes itself).
    private var saidMultichannel = false
    private var checkedIndex = false
    /// Why it can't go on has been said.
    private var said = false
    private var nextUp: PlayAction?
    private var switchWait: Double?
    private var indexTook = 0.0
    private var presentAttempts = 0
    private var memoryWarnings = 0
    private var watches: [NSObjectProtocol] = []
    private var commands: [(command: MPRemoteCommand, target: Any)] = []
    private var artwork: MPMediaItemArtwork?
    /// The tick the film began playing at, and whether its sound's pieces have been reported yet (`tick`).
    private var startedTick = 0
    private var soundSaid = false
    /// What Apple's renderer said of the picture's frames at the last look, and whether the two-minute line is out.
    private var frames: String?
    private var framesSaid = false
    /// The picture's frames as Apple's renderer last counted them, and how often its decoder has been emptied and
    /// given the film again because it kept dropping them.
    private var lastCounts: (frames: Int, dropped: Int)?
    private var renewals = 0
    /// The sound session's work, one thing after another and never on the main thread (activating can take a moment).
    private static let soundQueue = DispatchQueue(label: "woodruff.film-sound", qos: .userInitiated)

    // MARK: Starting

    func present(_ play: PhonePlay) {
        guard case .drive(let id) = play.source else {
            NativePlayer.shared.present(play)
            return
        }
        closeForAnother()
        // Camera tiles no page shows any more let go now: their pictures came down the same connection.
        CameraStreams.shared.filmStarting()
        let audio = AVAudioSession.sharedInstance()
        try? audio.setCategory(.playback, mode: .moviePlayback)
        // Nothing else is asked of the sound session. How many channels go out, and how a film mixed for six
        // speakers is fitted to what's connected, is the Apple TV's to decide: Apple's player, where such a film
        // sounds right, sets only the line above, and the Android TVs' player likewise hands the TV the film's
        // sound and leaves the output to it. This player used to say its sound was multichannel, and build 626
        // also asked for the film's six channels: the Apple TV's output went to 32 channels and the film sounded
        // wrong.
        // Activating can take a moment; not on the main thread, where the screen is being shown.
        Self.soundQueue.async { try? audio.setActive(true) }

        let stream = DriveStream(fileID: id, name: play.title)
        let screen = FilmScreen()
        screen.modalPresentationStyle = .fullScreen
        screen.card = Self.card(play)
        screen.onGone = { [weak self, weak screen] in
            guard let self, let screen, self.screen === screen else { return }
            self.finish()
        }
        screen.onNext = { [weak self] in self?.playNext() }
        self.screen = screen
        self.stream = stream
        current = play
        begun = false
        started = false
        ticks = 0
        startedTick = 0
        soundSaid = false
        frames = nil
        framesSaid = false
        lastCounts = nil
        renewals = 0
        checkedIndex = false
        said = false
        nextUp = nil
        switchWait = nil
        indexTook = 0
        presentAttempts = 0
        memoryWarnings = 0
        artwork = nil
        PlayCrumb.note(play.title, "opening", detail: PlayCrumb.memoryLeft)
        if let art = play.art { poster(art, on: screen, play: play) }
        details(play, on: screen)
        watch()
        show(screen, tries: 0)
        opening = Task { @MainActor [weak self] in
            await self?.open(play, id: id, stream: stream, screen: screen)
        }
        watchdog = Task { @MainActor [weak self] in
            // Until it's playing, or said why not.
            try? await Task.sleep(nanoseconds: UInt64(PhonePlayback.startLimit) * 1_000_000_000)
            guard let self, !Task.isCancelled, self.current?.id == play.id, !self.started, !self.said else { return }
            self.failed(self.slowerThanFilm() ?? PhonePlayback.tooSlow)
        }
    }

    /// The film's index (kept on this Apple TV, or read from Google and kept), then the film from where it was
    /// left off: fetched while the TV changes its picture mode, playing once it has.
    private func open(_ play: PhonePlay, id: String, stream: DriveStream, screen: FilmScreen) async {
        let began = Date()
        do {
            // DTS and Dolby TrueHD sound: the app's own decoder, for the index and the player to ask for.
            TVFilmSound.install()
            let index = try await FilmIndex.open(stream, id: id)
            guard current?.id == play.id, self.screen === screen else { return }
            let player = FilmPlayer(asset: index.asset, bytes: stream)
            try await player.open()
            guard current?.id == play.id, self.screen === screen else {
                player.close()
                return
            }
            self.index = index
            self.player = player
            indexTook = Date().timeIntervalSince(began)
            // Sound the app decodes itself (DTS, TrueHD) reaches the Apple TV as plain samples of six, eight or
            // twelve channels: the sound session is told so before the film starts, as AetherEngine tells it.
            // Films whose sound Apple decodes are left as they were.
            let film = player.film
            if film.sounds.first(where: { $0.id == film.sound })?.decodedHere == true {
                saidMultichannel = true
                Self.soundQueue.async { try? AVAudioSession.sharedInstance().setSupportsMultichannelContent(true) }
            }
            screen.attach(player)
            player.seek(to: play.start > 5 ? play.start : 0)
            let waited = await screen.matchDisplay(to: player.film.picture)
            guard current?.id == play.id, self.screen === screen else { return }
            switchWait = waited
            // The TV changed its picture mode after the picture's decoder had its first frames: it's emptied and
            // given them again now, or it drops one frame in ten all through the film.
            if waited != nil { player.renewPicture() }
            noteFormats(player.film, play, matches: screen.matchesContent, screenRate: screen.screenRate)
            player.play()
            begun = true
            commandsOn()
            ticker?.invalidate()
            ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
        } catch {
            guard current?.id == play.id, self.screen === screen else { return }
            // A picture this Apple TV can't show: said, rather than handed to Apple's player, which can't show it either
            // (it played the sound over a black screen).
            if case FilmPlayer.Failure.cantShow(let kind)? = error as? FilmPlayer.Failure {
                let words = "This Apple TV can’t show this film’s picture (\(FilmPictureFormat.name(kind))). Play it on a TV instead."
                Task { @MainActor [weak self, weak screen] in
                    // Said once the screen is up: an alert put up while it's still coming is refused without a word.
                    for _ in 0..<50 {
                        guard let screen, screen.presentingViewController == nil || screen.isBeingPresented else { break }
                        try? await Task.sleep(nanoseconds: 100_000_000)
                    }
                    guard let self, let screen, self.current?.id == play.id, self.screen === screen else { return }
                    self.failed(words)
                }
                return
            }
            giveToApple(play, error)
        }
    }

    /// The app's own player can't open this film (it isn't a kind Apple's reader knows, or none of its picture or
    /// sound can be played here, or Google wouldn't send it): Apple's player has it from now on, and says why if it
    /// can't play it either.
    private func giveToApple(_ play: PhonePlay, _ error: Error) {
        Self.gaveUp.insert(play.key)
        let ns = error as NSError
        Diagnostics.shared.notePlayback("\(play.title): the app’s own player couldn’t open it (\(ns.domain) \(ns.code)); Apple’s player has it")
        closeForAnother()
        NativePlayer.shared.present(play)
    }

    /// Closes the film showing here, without a word (another player, or another film, takes over).
    func closeForAnother() {
        let old = screen
        old?.onGone = nil
        finish()
        old?.closeQuietly()
    }

    /// Shows the screen once what it goes over is still: the title's page that asked has closed (presenting while
    /// it's closing does nothing, and the film would never show).
    private func show(_ c: FilmScreen, tries: Int) {
        guard screen === c, c.presentingViewController == nil else { return }
        let top = NativePlayer.top()
        let busy = top.map { $0.transitionCoordinator != nil || $0.presentedViewController != nil || $0.isBeingPresented || $0.isBeingDismissed } ?? true
        if tries == 0 || (busy && tries < 40) {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: tries == 0 ? 120_000_000 : 50_000_000)
                self?.show(c, tries: tries + 1)
            }
            return
        }
        guard let top else { return }
        presentAttempts += 1
        let attempt = presentAttempts
        // UIKit refuses a presentation silently (the screen under it still changing): looked at a second later, and
        // put up again over whatever is on top then (a few times at most).
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let self, self.screen === c, c.presentingViewController == nil, self.presentAttempts == attempt, attempt < 4 else { return }
            self.show(c, tries: 40)
        }
        top.present(c, animated: true)
    }

    // MARK: What the film is

    /// What the screen says about [play] in words, from what's kept here.
    private static func card(_ play: PhonePlay) -> FilmCard {
        guard let info = DriveLibrary.shared.playerInfo(play.key) else { return FilmCard(title: play.title) }
        var facts: [String] = []
        if let year = info.year { facts.append(String(year)) }
        if !info.genres.isEmpty { facts.append(info.genres.prefix(2).joined(separator: ", ")) }
        return FilmCard(title: info.title, line: info.subtitle, facts: facts.isEmpty ? nil : facts.joined(separator: " · "), story: info.story)
    }

    /// An episode's own story, and the episode after it (for Next Episode), once they've been looked up.
    private func details(_ play: PhonePlay, on screen: FilmScreen) {
        Task { @MainActor [weak self, weak screen] in
            let more = await DriveLibrary.shared.playerDetails(play.key)
            guard let self, let screen, self.current?.id == play.id, self.screen === screen else { return }
            if let story = more.story, !story.isEmpty { screen.card.story = story }
            self.nextUp = more.next
        }
    }

    /// The title's picture behind the spinner until the first frame shows, in Info, and in Now Playing.
    private func poster(_ url: URL, on screen: FilmScreen, play: PhonePlay) {
        if let image = ImageStore.shared.cached(url) {
            screen.setPoster(image)
            artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            return
        }
        Task { @MainActor [weak self, weak screen] in
            guard let image = await ImageStore.shared.image(url), let self, self.current?.id == play.id else { return }
            screen?.setPoster(image)
            self.artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
    }

    /// What the sound is going out through and in how many channels, for the Macs' log. Read only: nothing is asked
    /// of the sound session (see `present`). Said once the film is playing, when the output has settled on it.
    private func noteOutput(_ play: PhonePlay) {
        let title = play.title
        Self.soundQueue.async {
            let audio = AVAudioSession.sharedInstance()
            let outputs = audio.currentRoute.outputs.map { "\($0.portType.rawValue) (\($0.channels?.count ?? 0) channels)" }
            let through = outputs.isEmpty ? "no output" : outputs.joined(separator: ", ")
            let line = "\(title): its sound goes out through \(through); the output has \(audio.outputNumberOfChannels) channels of up to \(audio.maximumOutputNumberOfChannels)"
            Task { @MainActor in Diagnostics.shared.notePlayback(line) }
        }
    }

    /// The film's picture and sound, for the Macs' log.
    private func noteFormats(_ film: FilmPlayer.Film, _ play: PhonePlay, matches: Bool?, screenRate: Int? = nil) {
        var words: [String] = []
        if let p = film.picture {
            var line = "picture \(p.codec) \(p.width)×\(p.height)"
            if let marked = p.markedAs { line += " (marked \(marked) in the file)" }
            if let hardware = p.hardware {
                line += hardware ? ", Apple’s hardware decoder takes it" : ", Apple’s hardware decoder doesn’t take it (decoded in software)"
            }
            if p.framesASecond > 0 { line += String(format: " %.3f fps", p.framesASecond) }
            line += PhonePlayback.dynamicRange(p.format)
            words.append(line)
        }
        for s in film.sounds {
            words.append("sound \(s.codec) \(s.channels) channels" + (s.playable ? (s.decodedHere ? ", decoded here" : "") : ", can’t be played here")
                + (s.id == film.sound ? ", playing" : ""))
        }
        if !film.words.isEmpty { words.append(film.words.count == 1 ? "1 subtitle track" : "\(film.words.count) subtitle tracks") }
        let hdr = AVPlayer.eligibleForHDRPlayback ? "HDR can be shown here" : "HDR can’t be shown here"
        let also = matches == nil ? "" : matches == true ? "; the Apple TV matches the film’s picture mode"
            : "; the Apple TV keeps its own picture mode (Match Content is off)"
        // How often the TV shows a new picture now, once its mode has changed for the film: a 24-frame film on a TV at
        // 60 shows some pictures three times and some twice, which looks like a small stutter when the camera moves.
        let shown = screenRate.map { "; the TV shows \($0) pictures a second" } ?? ""
        Diagnostics.shared.notePlayback("\(play.title), the app’s own player: " + words.joined(separator: "; ") + "; \(hdr)\(also)\(shown)")
        // Once after the app starts: whether this build decodes DTS and Dolby TrueHD (`TVFilmSound`).
        if !Self.saidDecoder {
            Self.saidDecoder = true
            Diagnostics.shared.notePlayback("The app’s own player: " + TVFilmSound.said)
        }
    }

    private static var saidDecoder = false

    /// How the film's sound is being decoded by the app's own decoder, for the log; nil when Apple's decodes it.
    private static func decodedWords(_ n: FilmPlayer.Notes) -> String? {
        guard let kind = n.decodedKind else { return nil }
        var words = "its \(kind) sound is decoded here: \(n.decodedPackets) packets"
        words += n.decodedLost > 0 ? " (\(n.decodedLost) gave nothing)" : ""
        words += n.decodedFrames == 0 ? ", no sound has come of them"
            : n.decodedChannels == 12 ? ", 7.1 with four overhead channels at \(n.decodedRate)"
            : ", \(n.decodedChannels) channels at \(n.decodedRate)"
        if n.decodingGaveUp { words += "; a track nothing came of was given up on" }
        return words
    }

    // MARK: While it plays

    private func tick() {
        guard let player, let play = current, let screen else { return }
        ticks += 1
        let state = player.state
        if state == .playing, !started {
            started = true
            startedTick = ticks
            noteOutput(play)
        }
        // Its sound has overhead channels: the output is kept in Atmos from here on.
        if !heightsFollowed, player.notes.decodedChannels == 12 {
            heightsFollowed = true
            heightsKeeper.follow { [weak self] in
                guard let state = self?.player?.state, self?.current != nil else { return nil }
                return state == .playing || state == .waiting
            }
            Diagnostics.shared.notePlayback("\(play.title): its sound is played with overhead channels; the output is kept in Dolby Atmos while it plays")
        } else if heightsFollowed {
            heightsKeeper.refresh()
        }
        // Twenty seconds in: how the film's sound is coming (said once, so it's in the Macs' log while it still plays).
        if started, !soundSaid, ticks - startedTick >= 20 {
            soundSaid = true
            let n = player.notes
            let decoded = Self.decodedWords(n).map { "; " + $0 } ?? (n.decodingGaveUp ? "; a sound track the app’s decoder could make nothing of was given up on" : "")
            Diagnostics.shared.notePlayback((n.joined > 0
                ? String(format: "%@: 20 s in, %ld pieces of its sound were set end to end (up to %.2f ms out)", play.title, n.joined, n.joinedBy * 1000)
                : "\(play.title): 20 s in, every piece of its sound met the one before") + decoded)
        }
        // How the picture is coming: what Apple's renderer says of its frames every half minute (for the summary), and
        // two minutes in, a line of its own (so it's in the Macs' log while the film still plays).
        if started, player.film.picture != nil, (ticks - startedTick) % 30 == 0 {
            let title = play.title, say = !framesSaid && ticks - startedTick >= 120
            if say { framesSaid = true }
            player.pictureFrames { [weak self] words in
                Task { @MainActor in
                    guard let self, self.current?.id == play.id else { return }
                    if let words { self.frames = words }
                    if say, let player = self.player {
                        Diagnostics.shared.notePlayback("\(title): 2 minutes in, " + self.pictureWords(player.notes))
                    }
                }
            }
        }
        // A picture whose frames Apple's renderer keeps dropping (more than one in twenty over ten seconds of the film
        // playing) has its decoder emptied and given the film again, up to three times a film.
        if started, player.film.picture != nil, renewals < 3, (ticks - startedTick) % 10 == 5 {
            let title = play.title, at = ticks - startedTick
            player.pictureCounts { [weak self] counts in
                Task { @MainActor in
                    guard let self, self.current?.id == play.id, let counts else { return }
                    let last = self.lastCounts
                    self.lastCounts = counts
                    guard let last, counts.frames >= last.frames + 120, counts.dropped >= last.dropped, self.renewals < 3 else { return }
                    let shown = counts.frames - last.frames, lost = counts.dropped - last.dropped
                    guard lost * 20 > shown else { return }
                    self.renewals += 1
                    self.lastCounts = nil
                    self.player?.renewPicture()
                    Diagnostics.shared.notePlayback("\(title): \(at) s in, \(lost) of \(shown) frames dropped in ten seconds; the picture’s decoder was emptied and given the film again")
                }
            }
        }
        if state == .ended {
            // Played to its end: the screen closes, back to the page it was started from.
            screen.close()
            return
        }
        if state == .failed, !said {
            failed(why(player.failure))
            return
        }
        // The film Google sends must be the one the kept index was read from.
        if !checkedIndex, let index, let stream, stream.sizeNow() != nil {
            checkedIndex = true
            if !FilmIndex.stillRight(index, stream), case .drive(let id) = play.source {
                Diagnostics.shared.notePlayback("\(play.title): the film has changed since its index was kept; read again")
                FilmIndex.forget(id)
                var again = play
                again.start = player.time
                present(again)
                return
            }
        }
        offerNext()
        if ticks % 10 == 0 {
            report()
            crumb()
        }
        if ticks % 5 == 0 { nowPlaying() }
    }

    /// Next Episode over the picture for the last part of an episode, when the library knows the one after it: its
    /// last twentieth, three minutes at most.
    private func offerNext() {
        guard let player, let screen else { return }
        var near = false
        let length = player.length
        if nextUp != nil, started, length > 0 {
            let left = length - player.time
            near = left > 0 && left <= min(length * 0.05, 180)
        }
        screen.offerNext(near)
    }

    private func playNext() {
        guard let next = nextUp, let play = PhonePlayback.play(next, fleet: Fleet.shared) else { return }
        // Asked once (a second press while it closes starts nothing more).
        nextUp = nil
        Task { @MainActor in OwnPlayer.start(play) }
    }

    /// Where it got to, once it has played (one that never started would only stamp its old place as the newest).
    private func report() {
        guard started, let player, let play = current else { return }
        let pos = player.time, length = player.length
        guard pos > 0 else { return }
        DriveLibrary.shared.played(play.key, title: play.title, pos: pos * 1000, dur: length * 1000)
    }

    /// Where the film has got to and how the memory stands, kept in case the app is ended in the middle (`PlayCrumb`).
    private func crumb() {
        guard let player, let play = current else { return }
        var bits = [String(format: "%.0f s in (the app’s own player)", player.time), PlayCrumb.memoryLeft]
        if memoryWarnings > 0 { bits.append(memoryWarnings == 1 ? "1 memory warning" : "\(memoryWarnings) memory warnings") }
        if let s = stream { bits.append("asked Google for \(s.askedNow())") }
        PlayCrumb.note(play.title, started ? "playing" : "opening", detail: bits.filter { !$0.isEmpty }.joined(separator: ", "))
    }

    /// Memory warnings (less of the film is kept), and the app put away: the film stops once the app is off screen
    /// (not as Home is pressed, which froze the picture for the second the Apple TV takes to leave), and is there,
    /// stopped, when the app comes back.
    private func watch() {
        guard watches.isEmpty else { return }
        let center = NotificationCenter.default
        watches.append(center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.current != nil else { return }
                self.memoryWarnings += 1
                self.stream?.shrink()
                self.crumb()
            }
        })
        watches.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screen?.left() }
        })
        watches.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screen?.cameBack() }
        })
    }

    // MARK: Saying why not

    private func why(_ error: Error?) -> String {
        guard let play = current else { return PhonePlayback.tooSlow }
        return stream?.refusalNow() ?? PhonePlayback.failure(stream?.recentFailure ?? error, play)
    }

    /// Said instead of "it didn't start" when the connection brings the film slower than it plays.
    private func slowerThanFilm() -> String? {
        guard let stream, let size = stream.sizeNow(), let length = player?.length, length > 60 else { return nil }
        let fastest = stream.fastestNow(), needs = Double(size) * 8 / length / 1_000_000
        guard fastest > 0, fastest < needs * 0.95 else { return nil }
        return String(format: "This film needs about %.0f megabits a second, and the connection here is giving about %.0f, so it can’t keep up.", needs, fastest)
    }

    private func failed(_ words: String) {
        guard let screen, let play = current, !said else { return }
        said = true
        player?.pause()
        // With where each error is from and what the app holds of the device, so the Macs' log says what ran out.
        let playerError = player?.failure, streamError = stream?.recentFailure
        Diagnostics.shared.notePlayback("\(play.title), the app’s own player: couldn’t go on: \(words) [the player: \(PlayCrumb.trail(playerError)); the stream: \(PlayCrumb.trail(streamError)); \(PlayCrumb.resources)]")
        // The device had no room for something ("Cannot allocate memory"), which isn't the film's doing: everything the
        // film held is let go and it's opened again from where it stopped, by itself, instead of stopping with words
        // on the screen. Not more than once in five minutes for a film: a second time so soon is said.
        if PlayCrumb.outOfRoom(playerError) || PlayCrumb.outOfRoom(streamError),
           Self.openedAgain[play.key].map({ Date().timeIntervalSince($0) > 300 }) ?? true {
            Self.openedAgain[play.key] = Date()
            var again = play
            again.start = max(0, (player?.time ?? play.start) - 3)
            Diagnostics.shared.notePlayback("\(play.title), the app’s own player: out of room, so it’s let go of and opened again from \(Int(again.start)) s in")
            report()
            closeForAnother()
            ImageStore.shared.memory.empty()
            BlurStore.empty()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                OwnPlayer.start(again)
            }
            return
        }
        // Google's daily limit: whether it's this film alone or every film is found out first, and said.
        if stream?.overLimitNow() == true, case .drive(let id) = play.source {
            Task { @MainActor [weak self, weak screen] in
                let answer = await PhonePlayback.limitAnswer(for: id)
                guard let self, let screen, self.current?.id == play.id else { return }
                if case .said(let text) = answer {
                    screen.fail(PhonePlayback.limitTitle, text)
                } else {
                    screen.fail("Can’t Play This Here", words)
                }
            }
            return
        }
        screen.fail("Can’t Play This Here", words)
    }

    // MARK: The Lock Screen's and Siri's controls

    private func nowPlaying() {
        guard let player, let play = current else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: screen?.card.title ?? play.title,
            MPMediaItemPropertyPlaybackDuration: player.length,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: player.time,
            MPNowPlayingInfoPropertyPlaybackRate: player.state == .playing ? 1.0 : 0.0,
        ]
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Play, Pause and a place in the film asked for from outside the remote (Siri, the iPhone's remote).
    private func commandsOn() {
        commandsOff()
        let center = MPRemoteCommandCenter.shared()
        func add(_ command: MPRemoteCommand, _ act: @escaping @MainActor (OwnPlayer, MPRemoteCommandEvent) -> Void) {
            command.isEnabled = true
            let target = command.addTarget { [weak self] event in
                Task { @MainActor in
                    if let self { act(self, event) }
                }
                return .success
            }
            commands.append((command, target))
        }
        add(center.playCommand) { me, _ in me.screen?.remote(play: true) }
        add(center.pauseCommand) { me, _ in me.screen?.remote(play: false) }
        add(center.changePlaybackPositionCommand) { me, event in
            if let to = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime { me.screen?.go(to) }
        }
        nowPlaying()
    }

    private func commandsOff() {
        for entry in commands { entry.command.removeTarget(entry.target) }
        commands = []
    }

    // MARK: Ending

    /// How it went, for the Macs' log: how long the index and the start took, how often it stopped to wait, what it
    /// read, and what Google was asked for (what its daily limit counts).
    private func notePlayback() {
        guard let player, let play = current, let stream else { return }
        let n = player.notes
        var words = "\(play.title) via the app’s own player: index "
        words += index?.file == nil ? "read through the stream" : index?.fresh == true ? "read from Google and kept" : "kept on this Apple TV"
        words += String(format: " in %.1f s", indexTook)
        if let s = n.started { words += String(format: ", started in %.1f s", s) }
        if let w = switchWait { words += String(format: ", %.1f s for the TV’s picture mode", w) }
        words += String(format: ", %ld stops to wait (%.1f s), %ld moves", n.waits, n.waited, max(0, n.jumps - 1))
        words += String(format: ", read %ld runs of picture and %ld of sound, the slowest in %.2f s", n.reads[0], n.reads[1], n.slowest)
        if n.again > 0 { words += ", \(n.again) asked again" }
        if n.mended > 0 {
            words += ", decoders started afresh \(n.mended) times (the picture’s \(n.mendedPicture), the sound’s \(n.mendedSound)"
                + (n.mendWhy.map { ": \($0)" } ?? "") + ")"
        }
        // The film's sound comes in pieces; how many didn't start exactly where the one before ended and were set end
        // to end (`FilmPlayer.joined`): a film whose sound came out broken up shows a large number here.
        words += n.joined > 0
            ? String(format: ", %ld pieces of sound set end to end (up to %.2f ms out)", n.joined, n.joinedBy * 1000)
            : ", every piece of sound met the one before"
        if let decoded = Self.decodedWords(n) {
            words += ", " + decoded
        } else if n.decodingGaveUp {
            words += ", a sound track the app’s decoder could make nothing of was given up on"
        }
        if player.film.picture != nil { words += ", " + pictureWords(n, waits: false) }
        words += ", asked Google for \(stream.askedNow())"
        if let size = stream.sizeNow(), player.length > 60 {
            words += String(format: ", the film needs %.0f Mb/s", Double(size) * 8 / player.length / 1_000_000)
        }
        Diagnostics.shared.notePlayback(words)
    }

    /// How the picture came, for the Macs' log: its frames as Apple's renderer counts them (dropped ones are the
    /// stutter), how little of it was in hand at worst, how often it waited, and the repeated settings taken out.
    private func pictureWords(_ n: FilmPlayer.Notes, waits: Bool = true) -> String {
        var words = "the picture: " + (frames ?? "its frames not counted yet")
        if let least = n.pictureLeast {
            words += String(format: ", at least %.1f s of it in hand (under a second %ld times)", least, n.pictureThin)
        }
        if waits { words += String(format: ", %ld stops to wait (%.1f s)", n.waits, n.waited) }
        // Dropped each half minute: all at the start, or all the way through.
        if n.droppedSoFar.count > 1 {
            var each: [String] = []
            for (before, now) in zip(n.droppedSoFar, n.droppedSoFar.dropFirst()) { each.append(String(now >= before ? now - before : now)) }
            words += ", dropped each half minute: " + each.joined(separator: ", ")
        }
        if let beat = n.beat {
            words += n.beatMoved > 0
                ? String(format: ", its times put on the film’s beat of %@ (%ld of %ld frames moved, by up to %.2f ms)",
                         beat, n.beatMoved, n.beatFrames, n.beatMost * 1000)
                : ", its times on the film’s beat of \(beat) already (\(n.beatFrames) frames)"
            if n.beatRestarted > 0 { words += ", the beat begun again \(n.beatRestarted) times" }
        }
        if n.renewed > 0 { words += ", its decoder emptied and given the film again \(n.renewed) times" }
        if n.setsTakenOut > 0 { words += ", the settings repeated inside \(n.setsTakenOut) frames taken out" }
        // What the frames are made of (keyframes of each kind, frames that look back past one, end-of-sequence
        // markers, Dolby Vision's own data) and what Apple's reader marked them with: why frames drop, if they do.
        if n.framesCounted > 0 {
            let names: [Int: String] = [0: "TRAIL_N", 1: "TRAIL_R", 2: "TSA_N", 3: "TSA_R", 4: "STSA_N", 5: "STSA_R", 6: "RADL_N",
                                        7: "RADL_R", 8: "RASL_N", 9: "RASL_R", 16: "BLA_W_LP", 17: "BLA_W_RADL", 18: "BLA_N_LP",
                                        19: "IDR_W_RADL", 20: "IDR_N_LP", 21: "CRA", 32: "VPS", 33: "SPS", 34: "PPS", 35: "AUD",
                                        36: "EOS", 37: "EOB", 38: "FD", 39: "SEI", 40: "SEI_SUFFIX", 62: "RPU", 63: "EL"]
            let kinds = n.pieceKinds.sorted { $0.key < $1.key }.map { "\(names[$0.key] ?? String($0.key)) ×\($0.value)" }
            words += "; its first \(n.framesCounted) frames hold " + kinds.joined(separator: ", ")
            let hints = n.hints.sorted { $0.value > $1.value }.prefix(8).map { "\($0.key) ×\($0.value)" }
            if !hints.isEmpty { words += "; the file’s marks on them: " + hints.joined(separator: ", ") + " (handed on: keyframes only)" }
        }
        return words
    }

    private func finish() {
        guard current != nil else { return }
        report()
        if begun { notePlayback() }
        // Queued, not waited for: the page the film closes back to froze while the whole library was written.
        DriveLibrary.shared.flush(wait: false)
        // Watch shows where it was left off at once.
        DriveLibrary.shared.playStopped()
        Task { await DriveLibrary.shared.sync() }
        ticker?.invalidate()
        ticker = nil
        if heightsFollowed {
            heightsFollowed = false
            heightsKeeper.stop()
        }
        if saidMultichannel {
            saidMultichannel = false
            Self.soundQueue.async { try? AVAudioSession.sharedInstance().setSupportsMultichannelContent(false) }
        }
        opening?.cancel()
        opening = nil
        watchdog?.cancel()
        watchdog = nil
        commandsOff()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        player?.close()
        player = nil
        stream = nil
        index = nil
        current = nil
        screen = nil
        nextUp = nil
        artwork = nil
        PlayCrumb.clear()
    }
}
