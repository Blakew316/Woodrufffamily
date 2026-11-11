import SwiftUI
import AVKit
import os
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
    /// Playing the app's own copy of the film's file in Drive: the file it's a copy of.
    var copyOf: String? = nil

    /// The same film, from [copy] of its file [original].
    func playing(copy: String, of original: String) -> PhonePlay {
        PhonePlay(source: .drive(copy), key: key, title: title, start: start, art: art, copyOf: original)
    }
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

    /// Once it's playing: about a minute ahead at most, as the Android TVs' player keeps. Left to itself the player read
    /// big films minutes ahead of what was watched, and Google Drive limits how much of one file it sends in a day: a
    /// few starts and stops of the same film used that up, and Google refused it for the rest of the day.
    nonisolated static func playing(_ item: AVPlayerItem) {
        item.preferredForwardBufferDuration = 60
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

    /// What a Drive film needs each second (its size over its length) and the fastest it has arrived here, in megabits
    /// a second. Nil until both are known.
    static func rates(_ stream: DriveStream?, _ item: AVPlayerItem?) -> (needs: Double, fastest: Double)? {
        guard let stream, let size = stream.sizeNow(), let length = item?.duration.seconds, length.isFinite, length > 60 else { return nil }
        let fastest = stream.fastestNow()
        guard fastest > 0 else { return nil }
        return (Double(size) * 8 / length / 1_000_000, fastest)
    }

    /// Said instead of "it didn't start" when the connection brings the film slower than it plays.
    static func slowerThanFilm(_ stream: DriveStream?, _ item: AVPlayerItem?) -> String? {
        guard let r = rates(stream, item), r.fastest < r.needs * 0.95 else { return nil }
        return String(format: "This film needs about %.0f megabits a second, and the connection here is giving about %.0f, so it can’t keep up. Move closer to the Wi‑Fi, or play it on a TV.", r.needs, r.fastest)
    }

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
            fleet.alert("Can’t Play on \(deviceName)", "It’s an \(ext.uppercased()) file, which Apple’s player can’t open. Play it on a TV instead.")
            return nil
        }
        return PhonePlay(source: .url(c.streamURL(a.key)), key: a.key, title: a.title, start: start)
    }

    // MARK: What the film is

    /// The film's picture and sound as the player has them, for the Macs' log ("picture hvc1 3840×2160 24 fps Dolby
    /// Vision profile 8; sound ec-3 6 channels; sound dtsh 8 channels, can’t be played here"). A film whose sound
    /// Apple's player can't play shows its picture in silence, and nothing else says why. [also]: more to say after
    /// them (how the Apple TV is set).
    static func noteFormats(of item: AVPlayerItem, title: String, also: String = "") {
        let tracks = item.tracks.compactMap { $0.assetTrack }
        guard !tracks.isEmpty else { return }
        let hdr = AVPlayer.eligibleForHDRPlayback ? "HDR can be shown here" : "HDR can’t be shown here"
        Task { @MainActor in
            var words: [String] = []
            for t in tracks {
                let picture = t.mediaType == .video
                guard picture || t.mediaType == .audio else { continue }
                let formats = (try? await t.load(.formatDescriptions)) ?? []
                let decodable = (try? await t.load(.isDecodable)) ?? true
                var line = picture ? "picture" : "sound"
                if let f = formats.first {
                    line += " " + PhonePlayback.fourLetters(CMFormatDescriptionGetMediaSubType(f))
                    if picture {
                        let size = CMVideoFormatDescriptionGetDimensions(f)
                        line += " \(size.width)×\(size.height)"
                        let rate = (try? await t.load(.nominalFrameRate)) ?? 0
                        if rate > 0 { line += String(format: " %.0f fps", rate) }
                        line += PhonePlayback.dynamicRange(f)
                    } else if let sound = CMAudioFormatDescriptionGetStreamBasicDescription(f)?.pointee {
                        line += " \(sound.mChannelsPerFrame) channels"
                    }
                } else {
                    line += " of a kind the player couldn’t read"
                }
                if !decodable { line += ", can’t be played here" }
                words.append(line)
            }
            guard !words.isEmpty else { return }
            Diagnostics.shared.notePlayback("\(title): " + words.joined(separator: "; ") + "; \(hdr)\(also)")
        }
    }

    /// A format's four-letter name ("hvc1", "ec-3"), or its number when it isn't letters.
    private static func fourLetters(_ code: FourCharCode) -> String {
        var text = ""
        for shift in [24, 16, 8, 0] {
            let byte = UInt8((code >> UInt32(shift)) & 0xFF)
            guard byte >= 0x20, byte < 0x7F else { return String(format: "0x%08X", code) }
            text.append(Character(UnicodeScalar(byte)))
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// " Dolby Vision profile 8", " HDR" or " HLG" when the picture's description says so.
    private static func dynamicRange(_ f: CMFormatDescription) -> String {
        if let atoms = CMFormatDescriptionGetExtension(f, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any],
           let box = (atoms["dvcC"] ?? atoms["dvvC"] ?? atoms["dvwC"]) as? Data {
            return box.count >= 3 ? " Dolby Vision profile \(box[box.startIndex + 2] >> 1)" : " Dolby Vision"
        }
        // (The picture's transfer function, under the name Core Video gives it.)
        let transfer = CMFormatDescriptionGetExtension(f, extensionKey: "CVImageBufferTransferFunction" as CFString) as? String ?? ""
        if transfer.contains("2084") { return " HDR" }
        if transfer.contains("HLG") { return " HLG" }
        return ""
    }

    // MARK: Google's daily limit

    static let limitTitle = "Google Drive’s Daily Limit"
    static let copyOffer = "Google Drive won’t send this film again today. The app can make a copy of it in your Google Drive and play that. The copy needs as much free space as the film, and is removed after two days."
    static let makingCopy = "Making a copy in Google Drive…"

    /// What to say about a film Google refused with its daily limit: that it refuses every film for now (the family's
    /// apps and TVs share one allowance at Google, and it's used up), or only this one. Nothing is offered: a copy of
    /// the film is refused like the film when it's the allowance, and that is what it has been each time it was looked
    /// into. (The copy cases are kept for the players; nothing gives them any more.)
    enum LimitAnswer { case said(String), copy(String), offerCopy(words: String?) }

    static func limitAnswer(for id: String) async -> LimitAnswer {
        // A few other films, asked for a real part of each: any that Google still sends means it's this film alone.
        var sent: String?, refused: [String] = []
        for other in DriveLibrary.shared.otherFiles(than: id) {
            guard let answer = await GoogleDrive.sends(other.id) else { continue }
            if answer { sent = other.title; break }
            refused.append(other.title)
        }
        if let sent {
            Diagnostics.shared.notePlayback("Google still sends \(sent): only this film is refused")
            return .said(GoogleDrive.thisFilmRefused)
        }
        if !refused.isEmpty {
            Diagnostics.shared.notePlayback("Google refuses \(refused.joined(separator: ", ")) too: it is refusing every film for now, not only this one")
            return .said(GoogleDrive.allowanceSpent)
        }
        Diagnostics.shared.notePlayback("Whether Google refuses other films too couldn’t be found out")
        return .said(GoogleDrive.thisFilmRefused)
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
            #if os(tvOS)
            // Apple TV keeps no downloads (Settings → Watch has no Downloads there), and may be on a cable.
            return "No connection. Check the network."
            #else
            return "No connection. Check the Wi‑Fi, or download it in Settings → Watch → Downloads to watch offline."
            #endif
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

/// What's playing, kept while it plays. The system ending the app in the middle of a film (for memory, or for not
/// answering) leaves no report anywhere on an Apple TV: so the next launch says what was playing, how far in and how
/// the memory stood, in the Macs' log.
@MainActor
enum PlayCrumb {
    private static let key = "playing.crumb"

    static func note(_ title: String, _ stage: String, detail: String = "") {
        let crumb: [String: Any] = ["title": title, "stage": stage, "detail": detail, "at": Date().timeIntervalSince1970,
                                    "build": AppBuild.label]
        UserDefaults.standard.set(crumb, forKey: key)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    /// At launch: what the app was playing when it last ended without the film being closed, if it was.
    static func reportLast() {
        guard let c = UserDefaults.standard.dictionary(forKey: key) else { return }
        clear()
        let title = c["title"] as? String ?? "a film", stage = c["stage"] as? String ?? "playing"
        let detail = c["detail"] as? String ?? "", build = c["build"] as? String ?? ""
        let when = (c["at"] as? Double).map { " at " + ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: $0)) } ?? ""
        Diagnostics.shared.notePlayback("The app ended while \(stage) \(title)\(when)" + (build.isEmpty ? "" : " (\(build))")
                                        + (detail.isEmpty ? "" : ": \(detail)"))
    }

    /// How much more memory the app may take before the system ends it (an iPhone, iPad or Apple TV says).
    static var memoryLeft: String {
        #if os(iOS) || os(tvOS)
        return "\(os_proc_available_memory() >> 20) MB of memory left"
        #else
        return ""
        #endif
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
    #if os(tvOS)
    /// A film's player is on screen, over everything (what's under it can't be seen meanwhile). Not one that never got
    /// on screen, nor one put away into picture in picture.
    var isOpen: Bool { controller?.presentingViewController != nil }
    #endif
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
    /// A copy to offer (Google's daily limit for the file), found before the player was on screen.
    private var pendingOffer: (play: PhonePlay, id: String, words: String?)?
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
    /// The film whose picture and sound formats have been written down.
    private var formatsNotedFor: UUID?
    /// Times the system has said memory is short during this film, and what listens for it.
    private var memoryWarnings = 0
    private var memoryWatch: NSObjectProtocol?
    #if os(tvOS)
    /// Apple TV: what the player's title and info panel say about the film in words (`describe`), and its picture once
    /// that has come (`artwork`). Together they are `metadata`, whichever comes first.
    private var infoItems: [AVMetadataItem] = []
    private var artItem: AVMetadataItem?
    /// The episode after the one playing, when the library knows it.
    private var nextUp: PlayAction?
    /// Next Episode is showing over the picture.
    private var offeringNext = false
    /// Hears a film play to its end (kept from the first film on, as `memoryWatch` is).
    private var endWatch: NSObjectProtocol?
    #endif

    private static func titleItem(_ title: String) -> AVMetadataItem {
        let t = AVMutableMetadataItem()
        t.identifier = .commonIdentifierTitle
        t.value = title as NSString
        t.extendedLanguageTag = "und"
        return t
    }

    #if os(tvOS)
    /// One line of the Apple TV player's info panel.
    private static func infoItem(_ identifier: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
        let t = AVMutableMetadataItem()
        t.identifier = identifier
        t.value = value as NSString
        t.extendedLanguageTag = "und"
        return t
    }

    /// What the player says about [info] in words: its name over the bar with a line under it (a film's year; an
    /// episode's season, number and name under its show's), and in the info panel [story], the genre and, for an
    /// episode, its show's year.
    private static func infoItems(_ info: DriveLibrary.PlayerInfo, story: String?) -> [AVMetadataItem] {
        var out = [titleItem(info.title)]
        // A film's line is just its year. The player shows a year beside that line by itself (from the film's date),
        // so the year sent as the line too showed twice: "2019 · 2019". A film's year goes as its date only.
        let filmYear = info.year == nil ? info.subtitle.flatMap { Int($0) } : nil
        if filmYear == nil, let line = info.subtitle, !line.isEmpty { out.append(infoItem(.iTunesMetadataTrackSubTitle, line)) }
        if let story, !story.isEmpty { out.append(infoItem(.commonIdentifierDescription, story)) }
        if !info.genres.isEmpty { out.append(infoItem(.quickTimeMetadataGenre, info.genres.prefix(2).joined(separator: ", "))) }
        // A date in the middle of the year, so no time zone shows the year before or after.
        if let year = info.year ?? filmYear { out.append(infoItem(.commonIdentifierCreationDate, "\(year)-07-01T12:00:00Z")) }
        return out
    }

    /// Apple TV: what the library knows about the film goes into the player's title and info panel: its story, year
    /// and genre, and for an episode its show, season and number. At once from what's kept here; an episode's own
    /// story, and the episode after it (for Next Episode), once they've been looked up.
    private func describe(_ play: PhonePlay) {
        nextUp = nil
        offeringNext = false
        artItem = nil
        guard let info = DriveLibrary.shared.playerInfo(play.key) else {
            // The library can't say what it is (a film from a TV, one in a collection): its name, as before.
            infoItems = [Self.titleItem(play.title)]
            metadata = infoItems
            return
        }
        infoItems = Self.infoItems(info, story: info.story)
        metadata = infoItems
        Task { @MainActor [weak self] in
            let more = await DriveLibrary.shared.playerDetails(play.key)
            guard let self, self.current?.id == play.id else { return }
            if let story = more.story, !story.isEmpty {
                self.infoItems = Self.infoItems(info, story: story)
                self.metadata = self.infoItems + (self.artItem.map { [$0] } ?? [])
                self.item?.externalMetadata = self.metadata
            }
            self.nextUp = more.next
            self.offerNext()
        }
    }

    /// Apple TV: Next Episode over the picture for the last part of an episode, when the library knows the one after
    /// it: its last twentieth, three minutes at most. By then the episode counts as watched (`DriveLibrary.played`),
    /// so going on to the next leaves this one done. Looked at as it plays (with where it has got to) and whenever
    /// it's moved to another place.
    private func offerNext() {
        guard let c = controller, let p = player else { return }
        var near = false
        if nextUp != nil, begun, let length = p.currentItem?.duration.seconds, length.isFinite, length > 0 {
            let left = length - p.currentTime().seconds
            near = left.isFinite && left > 0 && left <= min(length * 0.05, 180)
        }
        guard near != offeringNext else { return }
        offeringNext = near
        if near {
            c.contextualActions = [UIAction(title: "Next Episode") { [weak self] _ in self?.playNext() }]
        } else {
            c.contextualActions = []
        }
    }

    /// Next Episode was chosen: the episode after this one, started as Play starts any other (this one closes first,
    /// with where it got to kept). Once the button's own press is over: it belongs to the player being closed.
    private func playNext() {
        guard let next = nextUp, let play = PhonePlayback.play(next, fleet: Fleet.shared) else { return }
        // Asked once (a second press while it closes starts nothing more).
        nextUp = nil
        Task { @MainActor [weak self] in self?.present(play) }
    }

    /// Start Over, in the player's bar: from the beginning, playing.
    private func startOver() {
        guard begun, let p = player else { return }
        resumeAt = nil
        p.seek(to: .zero)
        p.play()
    }

    /// Apple TV: the film played to its end. The player closes, back to the page it was started from. Nothing is
    /// marked here: closing keeps where it got to (`finish`), and a film that got to its end is marked watched by that.
    private func playedToEnd(_ ended: AVPlayerItem?) {
        guard let ended, ended === item, let c = controller, !c.isBeingDismissed,
              let under = c.presentingViewController else { return }
        under.dismiss(animated: true)
    }
    #endif

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
        #if os(tvOS)
        // Camera tiles no page shows any more (Home left for Watch) let go now, not two minutes on: their pictures
        // came down the same connection as the film's first minutes.
        CameraStreams.shared.filmStarting()
        #endif
        let audio = AVAudioSession.sharedInstance()
        try? audio.setCategory(.playback, mode: .moviePlayback)
        // Activating can take a moment; not on the main thread, where the player is being shown.
        DispatchQueue.global(qos: .userInitiated).async { try? audio.setActive(true) }
        let item: AVPlayerItem
        switch play.source {
        case .url(let u):
            item = AVPlayerItem(url: u)
        case .drive(let id):
            // Always answered request by request (DriveStream), which asks Google for a piece of the film at a
            // time. Drive's own address is no longer handed to the player: fetching by itself it asks Google for
            // the whole rest of the film again and again, and Google then refused the big films for the day.
            let s = DriveStream(fileID: id, name: play.title)
            stream = s
            item = AVPlayerItem(asset: s.asset())
        }
        metadata = [Self.titleItem(play.title)]
        #if os(tvOS)
        // Apple TV: with what the library knows about it, for the player's info panel.
        describe(play)
        #endif
        item.externalMetadata = metadata
        memoryWarnings = 0
        PlayCrumb.note(play.title, "opening", detail: PlayCrumb.memoryLeft)
        if memoryWatch == nil {
            memoryWatch = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
                                                                 object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.memoryShort() }
            }
        }
        #if os(tvOS)
        // Apple TV: a film that plays to its end closes the player (it stayed on its last frame). Heard for every
        // item, since the one playing can change mid-film; `playedToEnd` acts only on the one playing now.
        if endWatch == nil {
            endWatch = NotificationCenter.default.addObserver(forName: Notification.Name.AVPlayerItemDidPlayToEndTime,
                                                              object: nil, queue: .main) { [weak self] note in
                let ended = note.object as? AVPlayerItem
                MainActor.assumeIsolated { self?.playedToEnd(ended) }
            }
        }
        #endif

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
        // Start Over, in the player's bar beside its own controls (a bar of pictures, so it has one).
        c.transportBarCustomMenuItems = [UIAction(title: "Start Over", image: UIImage(systemName: "arrow.counterclockwise")) { [weak self] _ in
            self?.startOver()
        }]
        #endif
        c.modalPresentationStyle = .fullScreen
        c.onGone = { [weak self] in self?.closed() }
        controller = c
        ticker = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 10, preferredTimescale: 1), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.report()
                self?.crumb()
                #if os(tvOS)
                self?.offerNext()
                #endif
            }
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
            self.failed(PhonePlayback.slowerThanFilm(self.stream, self.item ?? item) ?? PhonePlayback.tooSlow)
        }
        show(c, tries: 0)
    }

    /// The file opening, or failing. Drive's address failing (a file Google labels with no video type, a sign-in it
    /// turned down, the connection to it lost) isn't said: the same file is read request by request instead, the
    /// way it always opened.
    private func watch(_ item: AVPlayerItem, _ p: AVPlayer, _ play: PhonePlay) {
        self.item = item
        // One taking over mid-film (a renewed sign-in, the other way): the same minute ahead at most.
        if begun { PhonePlayback.playing(item) }
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
                    // Google's daily limit for the file: a copy of it may play (not asked of a copy that was refused too).
                    if self.stream?.overLimitNow() == true, case .drive(let id) = play.source, play.copyOf == nil {
                        self.overLimit(play, id: id, words: refusal ?? words)
                        return
                    }
                    self.failed(refusal ?? heard.map { PhonePlayback.failure($0, play) } ?? words)
                } else {
                    // What the film's picture and sound are, once for each film played.
                    if self.formatsNotedFor != play.id {
                        self.formatsNotedFor = play.id
                        #if os(tvOS)
                        let matches = self.controller?.viewIfLoaded?.window?.avDisplayManager.isDisplayCriteriaMatchingEnabled
                        let also = matches == nil ? "" : matches == true
                            ? "; the Apple TV matches the film’s picture mode"
                            : "; the Apple TV keeps its own picture mode (Match Content is off)"
                        #else
                        let also = ""
                        #endif
                        PhonePlayback.noteFormats(of: now, title: play.title, also: also)
                    }
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
        let s = DriveStream(fileID: id, name: play.title)
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

    /// Where the film has got to and how the memory stands, kept in case the app is ended in the middle (`PlayCrumb`).
    private func crumb() {
        guard let p = player, let play = current else { return }
        let pos = p.currentTime().seconds
        var bits = [String(format: "%.0f s in", pos.isFinite ? pos : 0), PlayCrumb.memoryLeft]
        if memoryWarnings > 0 { bits.append(memoryWarnings == 1 ? "1 memory warning" : "\(memoryWarnings) memory warnings") }
        if let s = stream { bits.append("asked Google for \(s.askedNow())") }
        PlayCrumb.note(play.title, begun ? "playing" : "opening", detail: bits.filter { !$0.isEmpty }.joined(separator: ", "))
    }

    /// The system says memory is short while a film plays: less of the film is kept, by the stream and by the player
    /// (a quarter of a minute ahead instead of a whole one), rather than the app being ended in the middle of it.
    private func memoryShort() {
        guard player != nil else { return }
        memoryWarnings += 1
        stream?.shrink()
        item?.preferredForwardBufferDuration = 15
        crumb()
    }

    /// How it went, for the Macs' diagnostics log: which way it was read, how long it took to start, stalls,
    /// dropped frames and how fast Drive sent it; and for a film read from Drive, how much Google was asked for
    /// (what its daily limit for a file counts).
    private func notePlayback(_ p: AVPlayer, _ play: PhonePlay) {
        // What the film needs each second, beside how fast it arrived (in what was asked of Google).
        let needs = PhonePlayback.rates(stream, p.currentItem).map { String(format: ", the film needs %.0f Mb/s", $0.needs) } ?? ""
        let asked = stream.map { "asked Google for \($0.askedNow())\(needs)" }
        guard let events = p.currentItem?.accessLog()?.events, !events.isEmpty else {
            // The player keeps no figures of its own for a film it was handed piece by piece.
            if let asked { Diagnostics.shared.notePlayback("\(play.title) via request by request: \(asked)") }
            return
        }
        let stalls = events.reduce(0) { $0 + max(0, $1.numberOfStalls) }
        let dropped = events.reduce(0) { $0 + max(0, $1.numberOfDroppedVideoFrames) }
        let speed = events.last.map { max(0, $0.observedBitrate) / 1_000_000 } ?? 0
        let start = events.first.map { max(0, $0.startupTime) } ?? 0
        let via = directID != nil ? "Drive’s address" : stream != nil ? "request by request" : "a download or the TV"
        let mode = switchWait.map { String(format: ", %.1f s for the TV’s picture mode", $0) } ?? ""
        Diagnostics.shared.notePlayback("\(play.title) via \(via): started in \(String(format: "%.1f", start)) s\(mode), \(stalls) stalls, \(dropped) dropped frames, \(String(format: "%.0f", speed)) Mb/s" + (asked.map { ", \($0)" } ?? ""))
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
                if let offer = self.pendingOffer {
                    self.pendingOffer = nil
                    self.offerCopy(offer.play, id: offer.id, words: offer.words)
                }
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
            #if os(tvOS)
            // Apple TV: beside what the info panel says about the film in words (`describe`).
            self.artItem = a
            self.metadata = self.infoItems + [a]
            #else
            self.metadata = [Self.titleItem(play.title), a]
            #endif
            self.item?.externalMetadata = self.metadata
        }
    }

    /// Google refused the film with its daily limit: the copy made earlier is played, or one is offered, unless
    /// Google is refusing the other films too (then a copy wouldn't play either, and that is what's said).
    private func overLimit(_ play: PhonePlay, id: String, words: String) {
        Task { @MainActor [weak self] in
            let answer = await PhonePlayback.limitAnswer(for: id)
            guard let self, self.current?.id == play.id else { return }
            switch answer {
            case .said(let said): self.failed(said)
            case .copy(let copy): self.present(play.playing(copy: copy, of: id))
            case .offerCopy(let words): self.offerCopy(play, id: id, words: words)
            }
        }
    }

    /// Offers to make a copy of the film in Google Drive and play that.
    private func offerCopy(_ play: PhonePlay, id: String, words: String?) {
        guard let c = controller, current?.id == play.id else { return }
        // Not on screen yet: offered as soon as it is.
        guard c.presentingViewController != nil else { pendingOffer = (play, id, words); return }
        guard c.presentedViewController == nil else { return }
        let alert = UIAlertController(title: PhonePlayback.limitTitle, message: words ?? PhonePlayback.copyOffer, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Play a Copy", style: .default) { [weak self] _ in self?.makeCopy(play, id: id) })
        alert.addAction(UIAlertAction(title: "Not Now", style: .cancel) { [weak c] _ in c?.dismiss(animated: true) })
        c.present(alert, animated: true)
    }

    /// Has Google make the copy (it can take a minute for a big film), then plays it.
    private func makeCopy(_ play: PhonePlay, id: String) {
        guard let c = controller, current?.id == play.id else { return }
        let wait = UIAlertController(title: PhonePlayback.makingCopy, message: nil, preferredStyle: .alert)
        c.present(wait, animated: true)
        let shown = Date()
        Task { @MainActor [weak self] in
            let made: Result<String, Error>
            do { made = .success(try await GoogleDrive.makeCopy(of: id)) } catch { made = .failure(error) }
            // The note comes down first, whatever follows: not before it has finished coming up (taking it down
            // mid-way doesn't take), and a moment is given for it to go.
            let up = Date().timeIntervalSince(shown)
            if up < 0.8 { try? await Task.sleep(nanoseconds: UInt64((0.8 - up) * 1_000_000_000)) }
            wait.dismiss(animated: false)
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard let self, self.current?.id == play.id else { return }
            switch made {
            case .success(let copy):
                Diagnostics.shared.notePlayback("\(play.title): a copy made in Google Drive, played instead")
                self.present(play.playing(copy: copy, of: id))
            case .failure(let error):
                self.failed((error as? GoogleDrive.Failure)?.message ?? error.localizedDescription)
            }
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

    /// The screen to show it over: the topmost one. (A camera asked for by a tapped alert goes over it too:
    /// `CameraRequest`.)
    static func top() -> UIViewController? {
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
        // Queued, not waited for: the page the player closes back to froze while the whole library was written (the
        // app leaving still waits for it).
        DriveLibrary.shared.flush(wait: false)
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
        pendingOffer = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        stream = nil
        directID = nil
        directExpires = 0
        item = nil
        metadata = []
        #if os(tvOS)
        infoItems = []
        artItem = nil
        nextUp = nil
        offeringNext = false
        #endif
        resumeAt = nil
        switchWait = nil
        renew?.cancel()
        renew = nil
        current = nil
        controller = nil
        PlayCrumb.clear()
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
/// screen, picture in picture. The window is dark whatever the Mac's appearance, opens where it was last left, and
/// its title bar goes while the film plays with the pointer at rest. Where the film's got to is saved every 10
/// seconds and when the window closes, for Continue Watching.
@MainActor
final class MacPlayer: NSObject, NSWindowDelegate {
    static let shared = MacPlayer()
    /// The name the window's place and size are kept under, from one film to the next.
    private static let frameName = "WoodruffFilmWindow"
    private var window: NSWindow?
    private var player: AVPlayer?
    /// Kept while a Drive video plays (it fetches the parts the player asks for).
    private var stream: DriveStream?
    private var ticker: Any?
    /// Asks, each second the film plays, whether the title bar can go (`rest`).
    private var resting: Any?
    /// When the pointer last moved over the film's window (or the film opened).
    private var pointerAt = Date()
    private var current: PhonePlay?
    private var watch: Task<Void, Never>?

    /// A film is open in its window (Space is its own there, not the TV's: see `SpaceKey`).
    var isOpen: Bool { player != nil }

    func present(_ play: PhonePlay) {
        window?.close()
        current = play
        let item: AVPlayerItem
        switch play.source {
        case .url(let u):
            item = AVPlayerItem(url: u)
        case .drive(let id):
            let s = DriveStream(fileID: id, name: play.title)
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
        // The player fills a view of the window's own, which hears the pointer move over the window (also while
        // another app is in front): the title bar comes back with it (`rest`).
        let film = FilmView(frame: NSRect(x: 0, y: 0, width: 1120, height: 630))
        view.frame = film.bounds
        view.autoresizingMask = [.width, .height]
        film.addSubview(view)
        film.onPointer = { [weak self] in self?.pointerMoved() }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 630),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = play.title
        w.titlebarAppearsTransparent = true
        // Dark whatever the Mac's appearance: the title and the buttons sit over the film (in Light Mode the title
        // was dark on it).
        w.appearance = NSAppearance(named: .darkAqua)
        w.backgroundColor = .black
        w.isReleasedWhenClosed = false
        w.contentView = film
        // The player has the keyboard from the start (Space pauses, the arrows step), without a click on it first.
        w.initialFirstResponder = view
        w.contentAspectRatio = NSSize(width: 16, height: 9)
        w.delegate = self
        w.center()
        // Where it was last left, and as big (the middle of the screen the first time). The name is one window's at
        // a time: if the last film's window still has it, its place is read without it.
        if !w.setFrameAutosaveName(Self.frameName) { _ = w.setFrameUsingName(Self.frameName) }
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
        window = w

        ticker = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 10, preferredTimescale: 1), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.report() }
        }
        pointerAt = Date()
        resting = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 1), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rest() }
        }
        watch = Task { [weak self] in
            // Playing as soon as the file is open; a file Apple's player can't open, the source out of reach, or no
            // start in time: said over the player.
            var begun = false
            for _ in 0..<(PhonePlayback.startLimit * 20) {
                guard let self, self.player === p else { return }
                // What the stream heard from Google or the connection, when it did (the player passes on a number).
                if item.status == .failed {
                    let words = self.stream?.refusalNow() ?? PhonePlayback.failure(self.stream?.recentFailure ?? item.error, play)
                    Diagnostics.shared.notePlayback("\(play.title): couldn’t play (\(PhonePlayback.errorTrail(item))): \(words)")
                    // Google's daily limit for the file: a copy of it may play (not asked of a copy that was refused too).
                    if self.stream?.overLimitNow() == true, case .drive(let id) = play.source, play.copyOf == nil {
                        await self.overLimit(play, id: id)
                        return
                    }
                    self.failed(words)
                    return
                }
                if !begun, item.status == .readyToPlay {
                    begun = true
                    PhonePlayback.noteFormats(of: item, title: play.title)
                    await PhonePlayback.begin(p, play)
                }
                if begun, p.timeControlStatus == .playing { PhonePlayback.playing(item); return }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            guard let self, self.player === p else { return }
            self.failed(PhonePlayback.slowerThanFilm(self.stream, item) ?? PhonePlayback.tooSlow)
        }
    }

    /// Google refused the film with its daily limit: the copy made earlier is played, or one is offered, unless
    /// Google is refusing the other films too (then a copy wouldn't play either, and that is what's said).
    private func overLimit(_ play: PhonePlay, id: String) async {
        let answer = await PhonePlayback.limitAnswer(for: id)
        guard current?.id == play.id, let w = window else { return }
        switch answer {
        case .said(let said):
            failed(said)
        case .copy(let copy):
            present(play.playing(copy: copy, of: id))
        case .offerCopy(let words):
            let offer = NSAlert()
            offer.messageText = PhonePlayback.limitTitle
            offer.informativeText = words ?? PhonePlayback.copyOffer
            offer.addButton(withTitle: "Play a Copy")
            offer.addButton(withTitle: "Not Now")
            guard await offer.beginSheetModal(for: w) == .alertFirstButtonReturn else { w.close(); return }
            guard current?.id == play.id else { return }
            // Google makes the copy (it can take a minute for a big film).
            w.title = PhonePlayback.makingCopy
            do {
                let copy = try await GoogleDrive.makeCopy(of: id)
                guard current?.id == play.id else { return }
                Diagnostics.shared.notePlayback("\(play.title): a copy made in Google Drive, played instead")
                present(play.playing(copy: copy, of: id))
            } catch {
                guard current?.id == play.id else { return }
                w.title = play.title
                failed((error as? GoogleDrive.Failure)?.message ?? error.localizedDescription)
            }
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

    // MARK: The title bar

    /// The pointer moved over the film's window: its title bar is back.
    private func pointerMoved() {
        pointerAt = Date()
        titleBar(shown: true)
    }

    /// Each second the film plays: once the pointer has rested three seconds, the title bar (the window's buttons and
    /// the film's name) fades away and the film has the whole window, as in QuickTime. Not while the pointer rests on
    /// the title bar itself, and not in full screen, where the Mac shows and hides the title bar by itself.
    private func rest() {
        guard let w = window, let p = player, p.timeControlStatus == .playing,
              Date().timeIntervalSince(pointerAt) >= 3, !w.styleMask.contains(.fullScreen) else { return }
        let at = w.mouseLocationOutsideOfEventStream
        if at.x >= 0, at.x <= w.frame.width, at.y >= w.contentLayoutRect.maxY, at.y <= w.frame.height { return }
        titleBar(shown: false)
    }

    /// Fades the title bar in or out: the window's three buttons and its title. (Out of sight, it's still there:
    /// the window is moved by it, and the pointer brings it back before anything is clicked.)
    private func titleBar(shown: Bool) {
        // The whole bar: the highest view over the close button that the film's own view isn't inside as well
        // (however the Mac nests the buttons and the title in it).
        guard let w = window, let film = w.contentView, var bar = w.standardWindowButton(.closeButton)?.superview else { return }
        while let above = bar.superview, !film.isDescendant(of: above) { bar = above }
        guard (bar.alphaValue > 0.5) != shown else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            bar.animator().alphaValue = shown ? 1 : 0
        }
    }

    /// Going full screen: the title bar is the Mac's to show there (at the top of the screen), never left faded.
    func windowWillEnterFullScreen(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else { return }
        pointerMoved()
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else { return }
        report()
        // What Google was asked for (what its daily limit for a file counts), for the Macs' log.
        if let s = stream, let play = current {
            let needs = PhonePlayback.rates(s, player?.currentItem).map { String(format: ", the film needs %.0f Mb/s", $0.needs) } ?? ""
            Diagnostics.shared.notePlayback("\(play.title) via request by request: asked Google for \(s.askedNow())\(needs)")
        }
        DriveLibrary.shared.flush()
        // Watch shows where it was left off at once.
        DriveLibrary.shared.playStopped()
        Task { await DriveLibrary.shared.sync() }
        watch?.cancel(); watch = nil
        if let t = ticker { player?.removeTimeObserver(t) }
        ticker = nil
        if let t = resting { player?.removeTimeObserver(t) }
        resting = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        stream = nil
        current = nil
        // Its place is kept already (written each time the window moved): the name is free for the next film's window.
        _ = window?.setFrameAutosaveName("")
        window?.delegate = nil
        window = nil
    }
}

/// What fills the film's window: Apple's player, in a view that says when the pointer moves over it. Its tracking
/// area covers the whole view whatever is on top of it (the player), in front or not, and is made again whenever the
/// view changes size.
private final class FilmView: NSView {
    var onPointer: (() -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways], owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) { onPointer?() }
}
#endif
