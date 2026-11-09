import SwiftUI
import AVKit
import WoodruffKit

/// A film or episode from the TV's library played on this iPhone, iPad or Mac instead of a TV: the TV that holds
/// the library streams it (from its own storage, or from Drive with its sign-in), and Apple's player shows it, from
/// where it was left off.
struct PhonePlay: Identifiable {
    let id = UUID()
    /// Where it comes from: the TV's stream, or Google Drive itself (signed in here).
    enum Source { case url(URL), drive(String) }
    var source: Source
    var key: String
    var title: String
    var start: Double   // seconds
    /// The title's picture, shown while it starts.
    var art: URL? = nil
}

@Observable @MainActor
final class PhonePlayback {
    static let shared = PhonePlayback()

    /// Settings → Watch: the Play button plays on this device instead of the TV.
    static var playsHere: Bool { UserDefaults.standard.string(forKey: "watch.playOn") == "here" }

    /// "iPhone", "iPad", "Apple TV" or "This Mac", for the button (and the progress the TVs read).
    static var deviceName: String {
        #if os(tvOS)
        return "Apple TV"
        #elseif os(iOS)
        return UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        #else
        return "This Mac"
        #endif
    }

    /// Formats Apple's player can't open; the TV plays those.
    private static let unplayable: Set<String> = ["mkv", "avi", "wmv", "flv", "webm", "ts", "m2ts", "vob", "divx", "rmvb", "ogv"]

    /// How close to where it was left off it starts: the nearest keyframe within two seconds, which needs no extra
    /// fetching or decoding (an exact frame can take seconds longer over a stream).
    nonisolated static let nearEnough = CMTime(seconds: 2, preferredTimescale: 600)

    /// The player buffers as it judges best from the start: enough before the first frame that a big film (a 4K
    /// remux) doesn't stutter as it starts, which a two-second start buffer made it do.
    nonisolated static func quickStart(_ item: AVPlayerItem) {
        item.preferredForwardBufferDuration = 0
    }

    /// Once it's playing, the player buffers as far ahead as it likes again (two seconds ahead all film long would
    /// stop it at every hiccup of the connection).
    nonisolated static func playing(_ item: AVPlayerItem) {
        item.preferredForwardBufferDuration = 0
    }

    /// The resume point, asked for before the player has read the file, so the first parts it fetches are from
    /// there and not from the start.
    nonisolated static func seekAhead(_ p: AVPlayer, _ play: PhonePlay) {
        guard play.start > 5 else { return }
        p.seek(to: CMTime(seconds: play.start, preferredTimescale: 600), toleranceBefore: nearEnough, toleranceAfter: nearEnough)
    }

    /// Once the file is open: at the resume point (again, if the early ask didn't take) and playing.
    static func begin(_ p: AVPlayer, _ play: PhonePlay) async {
        await toResumePoint(p, play)
        startPlaying(p)
    }

    /// At the resume point once the file is open, if the early ask didn't take.
    static func toResumePoint(_ p: AVPlayer, _ play: PhonePlay) async {
        guard play.start > 5, abs(p.currentTime().seconds - play.start) > 3 else { return }
        // A seek that reports back is refused (an exception) until the item is open, and another may have just
        // taken over: then it's asked for the way that waits for it.
        guard p.currentItem?.status == .readyToPlay else { seekAhead(p, play); return }
        _ = await p.seek(to: CMTime(seconds: play.start, preferredTimescale: 600), toleranceBefore: nearEnough, toleranceAfter: nearEnough)
    }

    /// Plays, letting the player wait until it can keep up (playImmediately started big films with almost nothing
    /// buffered, so they stuttered for the first seconds).
    static func startPlaying(_ p: AVPlayer) {
        p.automaticallyWaitsToMinimizeStalling = true
        p.play()
    }

    /// How long it may take to start before it says so.
    static let startLimit = 30

    static let tooSlow = "It didn’t start within 30 seconds. Check the connection, then try again."

    /// Gets a Drive video ready to start the moment Play is pressed (a title's page asks when it opens): a token
    /// that will last, and the file's first part.
    static func warm(_ a: PlayAction) {
        guard playsHere, canPlay(a), a.key.hasPrefix("drive:"), GoogleDrive.signedIn,
              DriveDownloads.shared.local(a.key) == nil else { return }
        DriveStream.prefetch(fileID: String(a.key.dropFirst(6)))
    }

    /// Something that plays one particular file (not "the next episode", which the TV works out).
    static func canPlay(_ a: PlayAction) -> Bool { a.latest != true }

    /// What to play [a] here, or nil (and it says why) when it can't be.
    static func play(_ a: PlayAction, fleet: Fleet, fromStart: Bool = false) -> PhonePlay? {
        var start = fromStart ? 0 : max(0, (a.position ?? 0) / 1000)
        // Resume from the Drive library: where it was left off as kept now, not as the page last read it (a page
        // still showing, a title's card opening with what it showed last time, a TV's play merged in since).
        if !fromStart, (a.position ?? 0) > 0, a.key.hasPrefix("drive:"), WatchSources.usesDrive,
           let ms = DriveLibrary.shared.resumePosition(a.key) {
            start = ms / 1000
        }
        let art = a.key.hasPrefix("drive:") ? DriveLibrary.shared.art(for: a.key) : nil
        // Downloaded here: from the device, with or without a connection.
        if a.key.hasPrefix("drive:"), let file = DriveDownloads.shared.local(a.key) {
            return PhonePlay(source: .url(file), key: a.key, title: a.title, start: start, art: art)
        }
        // A Drive video with Drive signed in here: straight from Google, at home or away.
        if a.key.hasPrefix("drive:"), GoogleDrive.signedIn {
            return PhonePlay(source: .drive(String(a.key.dropFirst(6))), key: a.key, title: a.title, start: start, art: art)
        }
        guard let c = fleet.hubClient() else { fleet.show(TVError.notPaired); return nil }
        let ext = (a.key as NSString).pathExtension.lowercased()
        if unplayable.contains(ext) {
            fleet.say("Can’t Play on \(deviceName)", "It’s an \(ext.uppercased()) file, which Apple’s player can’t open. Play it on a TV instead.")
            return nil
        }
        return PhonePlay(source: .url(c.streamURL(a.key)), key: a.key, title: a.title, start: start)
    }

    /// Everything the player said about a failure, for the diagnostics: each error and the one under it, and its error
    /// log's last line (an HTTP status, say).
    nonisolated static func errorTrail(_ item: AVPlayerItem) -> String {
        var parts: [String] = []
        var e = item.error as NSError?
        for _ in 0..<4 {
            guard let x = e else { break }
            parts.append("\(x.domain) \(x.code)")
            e = x.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        if let ev = item.errorLog()?.events.last {
            parts.append("log \(ev.errorDomain) \(ev.errorStatusCode)" + (ev.errorComment.map { " \($0)" } ?? ""))
        }
        return parts.isEmpty ? "no error" : parts.joined(separator: " < ")
    }

    /// Why [play] stopped, in words someone can act on: Google Drive's own reason when it gave one (a sign-in that
    /// ended, its daily limit), else what's most likely for where it came from.
    nonisolated static func failure(_ error: Error?, _ play: PhonePlay) -> String {
        var e: Error? = error
        // AVFoundation wraps the reason the stream gave: the innermost one says it best.
        for _ in 0..<4 {
            if let d = e as? GoogleDrive.Failure { return d.message }
            guard let inner = (e as NSError?)?.userInfo[NSUnderlyingErrorKey] as? Error else { break }
            e = inner
        }
        let offline = [NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorTimedOut]
        // A Drive request that failed this way reaches here as an OSStatus of the same number (the player keeps only
        // the number): "OSStatus -1001" is a request that timed out.
        if let ns = e as NSError?, ns.domain == NSURLErrorDomain || ns.domain == NSOSStatusErrorDomain, offline.contains(ns.code) {
            return "No connection. Check the Wi‑Fi, or download it in Settings → Watch → Downloads to watch offline."
        }
        switch play.source {
        case .drive:
            // What Apple's player said (not a guess at the file's kind: an MP4 can fail too).
            let ns = (e ?? error) as NSError?
            let said = ns?.localizedFailureReason ?? ns?.localizedDescription
            return "Apple’s player couldn’t play it" + (said.map { " (\($0))" } ?? "") + ". Try again, or play it on a TV."
        case .url(let u) where u.isFileURL:
            return "The downloaded copy can’t be played. Remove it in Settings → Watch → Downloads and download it again."
        case .url:
            return error?.localizedDescription ?? "The TV couldn’t send it. Check the TV is on, or play it on a TV instead."
        }
    }
}

#if os(iOS) || os(tvOS)
/// Apple's player (AVPlayerViewController), presented full screen as the TV app's is: its controls come and go, its
/// close button with them; picture in picture (also by itself when leaving the app while it plays), AirPlay, speed,
/// and the Lock Screen's controls. Where it got to is kept for Continue Watching.
@MainActor
final class NativePlayer: NSObject, AVPlayerViewControllerDelegate {
    static let shared = NativePlayer()

    private var controller: PlayerController?
    private var player: AVPlayer?
    private var stream: DriveStream?
    private var ticker: Any?
    private var current: PhonePlay?
    private var inPictureInPicture = false
    private var statusWatch: NSKeyValueObservation?
    private var displayWatch: NSKeyValueObservation?
    /// Started playing (the resume point found, Play pressed on the player).
    private var begun = false
    /// The file is open, waiting for the player to be on screen.
    private var fileReady = false
    /// The player has finished coming on screen (on Apple TV, the TV has switched to the film's picture mode).
    private var onScreen = false
    /// Starts the film if the player hasn't reported being on screen soon after the file opened.
    private var startAnyway: Task<Void, Never>?
    /// Times the player has been put on screen for this film (tried again if one didn't take).
    private var presentAttempts = 0
    /// Why it can't play, found before the player was on screen (said once it is).
    private var pendingFailure: String?
    /// Says so when it hasn't started in time.
    private var watchdog: Task<Void, Never>?
    /// Playing Drive's address directly: its file, when the sign-in it was given runs out (seconds since 1970), and
    /// the task that renews it before then.
    private var directID: String?
    private var directExpires: Double = 0
    private var renew: Task<Void, Never>?
    /// The item playing now (it changes when Drive's address fails and the file is read request by request).
    private var item: AVPlayerItem?
    /// The player's title and picture for the film, given to every item that takes over.
    private var metadata: [AVMetadataItem] = []
    /// Where an item taking over mid-film (a renewed sign-in, the other way after Drive's address failed) goes on
    /// from, once it's open.
    private var resumeAt: CMTime?
    /// How long the start waited for the TV to change its picture mode (for the Macs' log).
    private var switchWait: Double?

    private static func titleItem(_ title: String) -> AVMetadataItem {
        let t = AVMutableMetadataItem()
        t.identifier = .commonIdentifierTitle
        t.value = title as NSString
        t.extendedLanguageTag = "und"
        return t
    }

    /// A sign-in lasts an hour, and the one Drive's address was given may have had much less left (a fixed 40 minutes
    /// let a film whose sign-in had 30 left stop, and go on the slower way). Five minutes before it runs out: the same
    /// place in a fresh item with a fresh one, opened before it takes over (so the picture only pauses a moment), with
    /// the audio and subtitles picked.
    private func renewSignIn(_ p: AVPlayer, _ play: PhonePlay) {
        renew?.cancel()
        renew = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let left = (self?.directExpires ?? 0) - Date().timeIntervalSince1970
                // A minute between tries at the least (Google out of reach near the end: asked again), an hour at most.
                try? await Task.sleep(nanoseconds: UInt64(min(3600, max(60, left - 300)) * 1_000_000_000))
                guard !Task.isCancelled, let self, self.player === p, let id = self.directID, let old = p.currentItem else { return }
                guard (try? await GoogleDrive.token(minLife: 2700)) != nil,
                      let fresh = DriveStream.directAsset(fileID: id, minLife: 2700),
                      (try? await fresh.asset.load(.isPlayable)) == true,
                      self.player === p, self.directID == id, p.currentItem === old else { continue }
                let next = AVPlayerItem(asset: fresh.asset)
                next.externalMetadata = self.metadata
                await Self.keepChoices(from: old, to: next)
                guard self.player === p, self.directID == id, p.currentItem === old else { continue }
                let at = p.currentTime()
                let wasPlaying = p.rate > 0
                self.resumeAt = at
                self.directExpires = fresh.expires
                self.watch(next, p, play)
                p.replaceCurrentItem(with: next)
                Self.place(p, at: at)
                if wasPlaying { p.play() }
            }
        }
    }

    /// [p] to [at] and never past it: from the keyframe up to two seconds before (quick to show). It may be asked
    /// before the item has opened (it goes there once it has), as the resume point is.
    private static func place(_ p: AVPlayer, at: CMTime) {
        p.seek(to: at, toleranceBefore: PhonePlayback.nearEnough, toleranceAfter: .zero)
    }

    /// The audio and subtitles picked on [old] (another language, subtitles on) picked again on [fresh], which would
    /// otherwise start with the film's own.
    private static func keepChoices(from old: AVPlayerItem, to fresh: AVPlayerItem) async {
        for kind in [AVMediaCharacteristic.audible, .legible] {
            guard let was = try? await old.asset.loadMediaSelectionGroup(for: kind),
                  let now = try? await fresh.asset.loadMediaSelectionGroup(for: kind),
                  let picked = old.currentMediaSelection.selectedMediaOption(in: was),
                  let i = was.options.firstIndex(of: picked), i < now.options.count else { continue }
            fresh.select(now.options[i], in: now)
        }
    }

    func present(_ play: PhonePlay) {
        // One still showing (another Play while it's up, or one in picture in picture): closed first, without it
        // telling this one it has gone when it finishes going (that would stop the new one).
        let old = controller
        old?.onGone = nil
        old?.delegate = nil
        finish()
        if let old, old.presentingViewController != nil { old.dismiss(animated: false) }
        inPictureInPicture = false
        begun = false
        fileReady = false
        onScreen = false
        presentAttempts = 0
        pendingFailure = nil
        let audio = AVAudioSession.sharedInstance()
        try? audio.setCategory(.playback, mode: .moviePlayback)
        // Activating can take a moment; not on the main thread, where the player is being shown.
        DispatchQueue.global(qos: .userInitiated).async { try? audio.setActive(true) }
        let item: AVPlayerItem
        switch play.source {
        case .url(let u):
            item = AVPlayerItem(url: u)
        case .drive(let id):
            // Drive's address straight to the player when the sign-in is fresh: the player's own fetching and
            // buffering, smooth on big films. Else (or a kind of file Apple's player can't open, said precisely by
            // the other way) answered request by request (DriveStream).
            let listed = DriveLibrary.shared.listedFile(id)
            if DriveStream.unplayable(listed?.mimeType) == nil, let direct = DriveStream.directAsset(fileID: id) {
                item = AVPlayerItem(asset: direct.asset)
                directID = id
                directExpires = direct.expires
            } else {
                let s = DriveStream(fileID: id)
                stream = s
                item = AVPlayerItem(asset: s.asset())
            }
        }
        metadata = [Self.titleItem(play.title)]
        item.externalMetadata = metadata

        PhonePlayback.quickStart(item)

        let p = AVPlayer(playerItem: item)
        player = p
        current = play
        // The file starts loading now, while the title's page closes and the player comes up.
        PhonePlayback.seekAhead(p, play)
        watch(item, p, play)
        let c = PlayerController()
        c.player = p
        c.delegate = self
        c.allowsPictureInPicturePlayback = true
        #if os(iOS)
        c.canStartPictureInPictureAutomaticallyFromInline = true
        c.updatesNowPlayingInfoCenter = true
        #endif
        #if os(tvOS)
        // The TV switches to the film's frame rate and dynamic range (Match Content), which the start waits for.
        c.appliesPreferredDisplayCriteriaAutomatically = true
        #endif
        c.modalPresentationStyle = .fullScreen
        c.onGone = { [weak self] in self?.closed() }
        controller = c
        ticker = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 10, preferredTimescale: 1), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.report() }
        }
        if let art = play.art { poster(art, on: c, play: play) }
        watchdog = Task { @MainActor [weak self] in
            // Until it's playing (its first frame), or said why not.
            for _ in 0..<(PhonePlayback.startLimit * 10) {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard let self, self.player === p else { return }
                if p.timeControlStatus == .playing { PhonePlayback.playing(self.item ?? item); return }
                // Said why (Drive's address failing isn't: the other way is tried, and waited for here).
                if (self.item ?? item).status == .failed, self.directID == nil { return }
            }
            guard let self, self.player === p else { return }
            self.failed(PhonePlayback.tooSlow)
        }
        show(c, tries: 0)
    }

    /// The file opening, or failing. Drive's address failing (a file Google labels with no video type, a sign-in it
    /// turned down, the connection to it lost) isn't said: the same file is read request by request instead, the
    /// way it always opened.
    private func watch(_ item: AVPlayerItem, _ p: AVPlayer, _ play: PhonePlay) {
        self.item = item
        statusWatch?.invalidate()
        let which = ObjectIdentifier(item)
        statusWatch = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            let status = item.status
            guard status != .unknown else { return }
            let words = status == .failed ? PhonePlayback.failure(item.error, play) : nil
            let code = PhonePlayback.errorTrail(item)
            Task { @MainActor in
                guard let self, self.player === p, let now = self.item, ObjectIdentifier(now) == which else { return }
                if let words {
                    if let id = self.directID { self.fallBack(p, play, id: id, why: code); return }
                    // Google's own reason when it refused the file, else what the stream heard from Google or the
                    // connection (the player passes on only a number).
                    let refusal = self.stream?.refusalNow()
                    let heard = self.stream?.recentFailure
                    let detail = (heard as NSError?).map { ", \($0.domain) \($0.code)" } ?? ""
                    Diagnostics.shared.notePlayback("\(play.title): couldn’t play (\(code)\(detail))" + (refusal.map { ": \($0)" } ?? ""))
                    self.failed(refusal ?? heard.map { PhonePlayback.failure($0, play) } ?? words)
                } else {
                    self.ready(p, play)
                }
            }
        }
    }

    /// Drive's address didn't open or stopped: the same file from DriveStream, from where it was.
    private func fallBack(_ p: AVPlayer, _ play: PhonePlay, id: String, why: String) {
        Diagnostics.shared.notePlayback("\(play.title): Drive’s address failed (\(why)), read request by request instead")
        directID = nil
        renew?.cancel()
        renew = nil
        // Where it was: an item that failed while taking over mid-film never got there itself.
        let at = resumeAt ?? p.currentTime()
        let old = p.currentItem
        let s = DriveStream(fileID: id)
        stream = s
        let fresh = AVPlayerItem(asset: s.asset())
        fresh.externalMetadata = metadata
        PhonePlayback.quickStart(fresh)
        // Not open until this one is (the player coming on screen meanwhile must wait for it), and not started
        // early for the item that failed.
        fileReady = false
        startAnyway?.cancel()
        startAnyway = nil
        watch(fresh, p, play)
        p.replaceCurrentItem(with: fresh)
        if begun {
            // It had been playing: on from the same place (looked at again once it's open), with the audio and
            // subtitles picked.
            if at.isValid, at.seconds > 1 {
                p.seek(to: at, toleranceBefore: PhonePlayback.nearEnough, toleranceAfter: PhonePlayback.nearEnough)
                resumeAt = at
            }
            if let old { Task { @MainActor in await Self.keepChoices(from: old, to: fresh) } }
            p.play()
        } else {
            PhonePlayback.seekAhead(p, play)
        }
    }

    /// How it went, for the Macs' diagnostics log: which way it was read, how long it took to start, stalls,
    /// dropped frames and how fast Drive sent it.
    private func notePlayback(_ p: AVPlayer, _ play: PhonePlay) {
        guard let events = p.currentItem?.accessLog()?.events, !events.isEmpty else { return }
        let stalls = events.reduce(0) { $0 + max(0, $1.numberOfStalls) }
        let dropped = events.reduce(0) { $0 + max(0, $1.numberOfDroppedVideoFrames) }
        let speed = events.last.map { max(0, $0.observedBitrate) / 1_000_000 } ?? 0
        let start = events.first.map { max(0, $0.startupTime) } ?? 0
        let via = directID != nil ? "Drive’s address" : stream != nil ? "request by request" : "a download or the TV"
        let mode = switchWait.map { String(format: ", %.1f s for the TV’s picture mode", $0) } ?? ""
        Diagnostics.shared.notePlayback("\(play.title) via \(via): started in \(String(format: "%.1f", start)) s\(mode), \(stalls) stalls, \(dropped) dropped frames, \(String(format: "%.0f", speed)) Mb/s")
    }

    /// The file is open: to the resume point and playing.
    /// Playing starts only once the player is on screen: started under the sliding-in player (and, on Apple TV,
    /// before the TV switches to the film's 4K or HDR mode) its first seconds stuttered.
    private func ready(_ p: AVPlayer, _ play: PhonePlay) {
        fileReady = true
        // An item that took over mid-film: at the same place, if the seek asked for before it opened didn't take.
        if let at = resumeAt {
            resumeAt = nil
            if at.isValid, abs(p.currentTime().seconds - at.seconds) > 3 { Self.place(p, at: at) }
        }
        guard !begun else { return }
        guard onScreen else {
            // The player not reported on screen yet: two seconds, then it plays anyway if it is up (a presentation
            // that never reports back must never keep the film from starting), else once it's up (one put up again
            // later: never a film playing with nothing on screen to stop it).
            startAnyway?.cancel()
            startAnyway = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                for _ in 0..<30 {
                    guard let self, !Task.isCancelled, self.player === p, !self.begun else { return }
                    if self.controller?.presentingViewController != nil {
                        self.onScreen = true
                        self.ready(p, play)
                        return
                    }
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
            return
        }
        startAnyway?.cancel()
        startAnyway = nil
        begun = true
        if directID != nil { renewSignIn(p, play) }
        #if os(tvOS)
        let c = controller
        #endif
        Task { @MainActor [weak self] in
            // The resume point first, so what's fetched from there comes in while the TV changes its picture mode.
            await PhonePlayback.toResumePoint(p, play)
            #if os(tvOS)
            var waited: Double?
            if let c { waited = await Self.displaySettled(c) }
            #endif
            guard let self, self.player === p else { return }
            #if os(tvOS)
            self.switchWait = waited
            #endif
            PhonePlayback.startPlaying(p)
        }
    }

    #if os(tvOS)
    /// Match Content: once the film is open with the player on screen, AVKit asks the TV for the film's frame rate and
    /// dynamic range, and the TV switches, its picture dark for a second or a few. A film already playing meanwhile
    /// lost or stuttered its first seconds (the Android TVs don't switch). So it waits for AVKit to ask, for a switch
    /// to begin (a moment: none does when the TV is in that mode already) and for it to end, ten seconds at most; twice
    /// at most (the TV still going back from the last film's mode, then this one's). The seconds the switching took,
    /// nil when there was none.
    private static func displaySettled(_ c: AVPlayerViewController) async -> Double? {
        guard let display = c.viewIfLoaded?.window?.avDisplayManager, display.isDisplayCriteriaMatchingEnabled else { return nil }
        var looks = 0
        while display.preferredDisplayCriteria == nil, !display.isDisplayModeSwitchInProgress, looks < 10 {
            try? await Task.sleep(nanoseconds: 50_000_000)
            looks += 1
        }
        var took: Double?
        for _ in 0..<2 {
            looks = 0
            while !display.isDisplayModeSwitchInProgress, looks < 10 {
                try? await Task.sleep(nanoseconds: 50_000_000)
                looks += 1
            }
            guard display.isDisplayModeSwitchInProgress else { break }
            let began = Date()
            looks = 0
            while display.isDisplayModeSwitchInProgress, looks < 200 {
                try? await Task.sleep(nanoseconds: 50_000_000)
                looks += 1
            }
            took = (took ?? 0) + Date().timeIntervalSince(began)
        }
        // A moment more for the TV to show a picture again.
        if took != nil { try? await Task.sleep(nanoseconds: 300_000_000) }
        return took
    }
    #endif

    /// Shows the player once the screen it goes over is still: the title's page that asked has closed (presenting
    /// while it's closing does nothing, and the film would never show).
    private func show(_ c: PlayerController, tries: Int) {
        guard controller === c, c.presentingViewController == nil else { return }
        let top = Self.top()
        let busy = top.map { $0.transitionCoordinator != nil || $0.presentedViewController != nil || $0.isBeingPresented || $0.isBeingDismissed } ?? true
        // The first look is a moment later, so a page closing after Play has begun to close.
        if tries == 0 || (busy && tries < 40) {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: tries == 0 ? 120_000_000 : 50_000_000)
                self?.show(c, tries: tries + 1)
            }
            return
        }
        guard let top else {
            // Nowhere to show it: play anyway, as before.
            onScreen = true
            if fileReady, let p = player, let play = current { ready(p, play) }
            return
        }
        presentAttempts += 1
        let attempt = presentAttempts
        // UIKit refuses a presentation silently (the screen under it still changing): looked at a second later, and
        // put up again over whatever is on top then (a few times at most).
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let self, self.controller === c, c.presentingViewController == nil, !self.inPictureInPicture,
                  self.presentAttempts == attempt, attempt < 4 else { return }
            self.show(c, tries: 40)
        }
        top.present(c, animated: true) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.controller === c else { return }
                self.onScreen = true
                if self.fileReady, let p = self.player, let play = self.current { self.ready(p, play) }
                guard let words = self.pendingFailure else { return }
                self.pendingFailure = nil
                self.failed(words)
            }
        }
    }

    /// The title's picture behind the player's spinner until the first frame shows, and beside its name in the
    /// player's info and in Now Playing.
    private func poster(_ url: URL, on c: PlayerController, play: PhonePlay) {
        c.loadViewIfNeeded()
        guard let overlay = c.contentOverlayView else { return }
        let v = UIImageView(frame: overlay.bounds)
        v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        v.contentMode = .scaleAspectFill
        v.clipsToBounds = true
        v.alpha = 0.6
        overlay.addSubview(v)
        if let img = ImageStore.shared.cached(url) {
            v.image = img
            artwork(img, for: play)
        } else {
            Task { @MainActor [weak v, weak self] in
                let img = await ImageStore.shared.image(url)
                v?.image = img
                if let img { self?.artwork(img, for: play) }
            }
        }
        displayWatch = c.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak v, weak c] _, _ in
            Task { @MainActor [weak v, weak c] in
                guard let v, let c, c.isReadyForDisplay else { return }
                UIView.animate(withDuration: 0.25, animations: { v.alpha = 0 }, completion: { _ in v.removeFromSuperview() })
            }
        }
    }

    /// The title's picture with its name in the player's metadata, on the item playing and any that takes over.
    private func artwork(_ image: UIImage, for play: PhonePlay) {
        Task { @MainActor [weak self] in
            let data = await Task.detached(priority: .utility) { image.jpegData(compressionQuality: 0.85) }.value
            guard let self, let data, self.current?.id == play.id else { return }
            let a = AVMutableMetadataItem()
            a.identifier = .commonIdentifierArtwork
            a.value = data as NSData
            a.dataType = kCMMetadataBaseDataType_JPEG as String
            a.extendedLanguageTag = "und"
            self.metadata = [Self.titleItem(play.title), a]
            self.item?.externalMetadata = self.metadata
        }
    }

    /// Says why it can't play, over the player; OK closes the player.
    private func failed(_ words: String) {
        guard let c = controller else { return }
        // Not on screen yet: said as soon as it is.
        guard c.presentingViewController != nil else { pendingFailure = words; return }
        guard c.presentedViewController == nil else { return }
        let alert = UIAlertController(title: "Can’t Play This Here", message: words, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak c] _ in c?.dismiss(animated: true) })
        c.present(alert, animated: true)
    }

    /// The screen to show it over: the topmost one.
    private static func top() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive } ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var vc = scene?.windows.first { $0.isKeyWindow }?.rootViewController ?? scene?.windows.first?.rootViewController
        while let next = vc?.presentedViewController, !next.isBeingDismissed { vc = next }
        return vc
    }

    /// Where it got to, once it has started (one that never started would only stamp its old place as the newest,
    /// over a TV's newer one).
    private func report() {
        // Only once it has played: a film that never started (it failed to open) leaves where it was left off alone.
        guard begun, let p = player, let play = current else { return }
        let pos = p.currentTime().seconds, dur = p.currentItem?.duration.seconds ?? 0
        guard pos.isFinite, pos > 0 else { return }
        DriveLibrary.shared.played(play.key, title: play.title, pos: pos * 1000, dur: dur.isFinite ? dur * 1000 : 0)
    }

    /// The player went away: closed, or (in picture in picture) its window closed.
    private func closed() {
        guard !inPictureInPicture else { return }
        finish()
    }

    private func finish() {
        guard player != nil else { return }
        report()
        if let p = player, let play = current, begun { notePlayback(p, play) }
        DriveLibrary.shared.flush()
        // Watch shows where it was left off at once.
        DriveLibrary.shared.playStopped()
        Task { await DriveLibrary.shared.sync() }
        if let t = ticker { player?.removeTimeObserver(t) }
        ticker = nil
        statusWatch?.invalidate()
        statusWatch = nil
        displayWatch?.invalidate()
        displayWatch = nil
        watchdog?.cancel()
        watchdog = nil
        startAnyway?.cancel()
        startAnyway = nil
        pendingFailure = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        stream = nil
        directID = nil
        directExpires = 0
        item = nil
        metadata = []
        resumeAt = nil
        switchWait = nil
        renew?.cancel()
        renew = nil
        current = nil
        controller = nil
    }

    // MARK: Picture in picture

    nonisolated func playerViewControllerWillStartPictureInPicture(_ c: AVPlayerViewController) {
        MainActor.assumeIsolated { if c === controller { inPictureInPicture = true } }
    }

    nonisolated func playerViewControllerDidStopPictureInPicture(_ c: AVPlayerViewController) {
        MainActor.assumeIsolated {
            guard c === controller else { return }
            inPictureInPicture = false
            // Closed from its small window (not brought back full screen): done.
            if controller?.presentingViewController == nil { finish() }
        }
    }

    /// Picture in picture leaves the full-screen player (so other apps can be used).
    nonisolated func playerViewControllerShouldAutomaticallyDismissAtPictureInPictureStart(_ c: AVPlayerViewController) -> Bool { true }

    /// Brought back from picture in picture: full screen again.
    nonisolated func playerViewController(_ c: AVPlayerViewController,
                                          restoreUserInterfaceForPictureInPictureStopWithCompletionHandler done: @escaping (Bool) -> Void) {
        MainActor.assumeIsolated {
            guard let controller, controller.presentingViewController == nil, let top = Self.top() else { done(true); return }
            top.present(controller, animated: true) { done(true) }
        }
    }
}

/// Apple's player, telling when it has gone (its close button, or a swipe down).
final class PlayerController: AVPlayerViewController {
    var onGone: (() -> Void)?
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || presentingViewController == nil { onGone?() }
    }
}
#endif

#if os(macOS)

/// Apple's Mac player (AVPlayerView, as in the TV app and QuickTime) in a window of its own: floating controls, full
/// screen, picture in picture. Where it's got to is saved every 10 seconds and when the window closes, for Continue
/// Watching.
@MainActor
final class MacPlayer: NSObject, NSWindowDelegate {
    static let shared = MacPlayer()
    private var window: NSWindow?
    private var player: AVPlayer?
    /// Kept while a Drive video plays (it fetches the parts the player asks for).
    private var stream: DriveStream?
    private var ticker: Any?
    private var current: PhonePlay?
    private var watch: Task<Void, Never>?

    func present(_ play: PhonePlay) {
        window?.close()
        current = play
        let item: AVPlayerItem
        switch play.source {
        case .url(let u):
            item = AVPlayerItem(url: u)
        case .drive(let id):
            let s = DriveStream(fileID: id)
            stream = s
            item = AVPlayerItem(asset: s.asset())
        }
        PhonePlayback.quickStart(item)
        let p = AVPlayer(playerItem: item)
        player = p
        PhonePlayback.seekAhead(p, play)

        let view = AVPlayerView()
        view.player = p
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true
        view.allowsPictureInPicturePlayback = true
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 630),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = play.title
        w.titlebarAppearsTransparent = true
        w.backgroundColor = .black
        w.isReleasedWhenClosed = false
        w.contentView = view
        w.contentAspectRatio = NSSize(width: 16, height: 9)
        w.delegate = self
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
        window = w

        ticker = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 10, preferredTimescale: 1), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.report() }
        }
        watch = Task { [weak self] in
            // Playing as soon as the file is open; a file Apple's player can't open, the source out of reach, or no
            // start in time: said over the player.
            var begun = false
            for _ in 0..<(PhonePlayback.startLimit * 20) {
                guard let self, self.player === p else { return }
                // What the stream heard from Google or the connection, when it did (the player passes on a number).
                if item.status == .failed { self.failed(PhonePlayback.failure(self.stream?.recentFailure ?? item.error, play)); return }
                if !begun, item.status == .readyToPlay {
                    begun = true
                    await PhonePlayback.begin(p, play)
                }
                if begun, p.timeControlStatus == .playing { PhonePlayback.playing(item); return }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            guard let self, self.player === p else { return }
            self.failed(PhonePlayback.tooSlow)
        }
    }

    private func failed(_ words: String) {
        guard let w = window else { return }
        let alert = NSAlert()
        alert.messageText = "Can’t Play This Here"
        alert.informativeText = words
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: w) { _ in w.close() }
    }

    private func report() {
        guard let play = current, let p = player else { return }
        let pos = p.currentTime().seconds, dur = p.currentItem?.duration.seconds ?? 0
        guard pos.isFinite, pos > 0 else { return }
        DriveLibrary.shared.played(play.key, title: play.title, pos: pos * 1000, dur: dur.isFinite ? dur * 1000 : 0)
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else { return }
        report()
        DriveLibrary.shared.flush()
        // Watch shows where it was left off at once.
        DriveLibrary.shared.playStopped()
        Task { await DriveLibrary.shared.sync() }
        watch?.cancel(); watch = nil
        if let t = ticker { player?.removeTimeObserver(t) }
        ticker = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        stream = nil
        current = nil
        window?.delegate = nil
        window = nil
    }
}
#endif
