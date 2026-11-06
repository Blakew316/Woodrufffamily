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
}

@Observable @MainActor
final class PhonePlayback {
    static let shared = PhonePlayback()
    /// A play for the Mac's window to show in the player.
    var request: PhonePlay?

    /// Settings → Watch: the Play button plays on this device instead of the TV.
    static var playsHere: Bool { UserDefaults.standard.string(forKey: "watch.playOn") == "here" }

    /// "iPhone", "iPad" or "This Mac", for the button.
    static var deviceName: String {
        #if os(iOS)
        return UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        #else
        return "This Mac"
        #endif
    }

    /// Formats Apple's player can't open; the TV plays those.
    private static let unplayable: Set<String> = ["mkv", "avi", "wmv", "flv", "webm", "ts", "m2ts", "vob", "divx", "rmvb", "ogv"]

    /// Something that plays one particular file (not "the next episode", which the TV works out).
    static func canPlay(_ a: PlayAction) -> Bool { a.latest != true }

    /// What to play [a] here, or nil (and it says why) when it can't be.
    static func play(_ a: PlayAction, fleet: Fleet, fromStart: Bool = false) -> PhonePlay? {
        let start = fromStart ? 0 : max(0, (a.position ?? 0) / 1000)
        // Downloaded here: from the device, with or without a connection.
        if a.key.hasPrefix("drive:"), let file = DriveDownloads.shared.local(a.key) {
            return PhonePlay(source: .url(file), key: a.key, title: a.title, start: start)
        }
        // A Drive video with Drive signed in here: straight from Google, at home or away.
        if a.key.hasPrefix("drive:"), GoogleDrive.signedIn {
            return PhonePlay(source: .drive(String(a.key.dropFirst(6))), key: a.key, title: a.title, start: start)
        }
        guard let c = fleet.hubClient() else { fleet.show(TVError.notPaired); return nil }
        let ext = (a.key as NSString).pathExtension.lowercased()
        if unplayable.contains(ext) {
            fleet.say("Can’t Play on \(deviceName)", "It’s an \(ext.uppercased()) file, which Apple’s player can’t open. Play it on a TV instead.")
            return nil
        }
        return PhonePlay(source: .url(c.streamURL(a.key)), key: a.key, title: a.title, start: start)
    }
}

/// Apple's player, full screen on iPhone and iPad, in a window-sized sheet on the Mac.
struct PhonePlayerView: View {
    let play: PhonePlay
    @Environment(\.dismiss) private var dismiss
    @State private var player = AVPlayer()
    @State private var failed: String?
    /// Kept while a Drive video plays (it fetches the parts the player asks for).
    @State private var stream: DriveStream?
    @State private var ticker: Any?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            VideoPlayer(player: player).ignoresSafeArea()
            if let failed {
                VStack(spacing: 10) {
                    Text("Can’t Play This Here").font(.headline)
                    Text(failed).font(.subheadline).multilineTextAlignment(.center).foregroundStyle(.secondary)
                }
                .foregroundStyle(.white)
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.headline).foregroundStyle(.white)
                    .frame(width: 40, height: 40).glass(Circle()).environment(\.colorScheme, .dark)
            }
            .buttonStyle(.plain)
            .padding(16)
            .accessibilityLabel("Close")
        }
        #if os(macOS)
        .frame(minWidth: 900, minHeight: 540)
        #endif
        .task { await begin() }
        .onDisappear {
            report()
            DriveLibrary.shared.flush()
            Task { await DriveLibrary.shared.sync() }
            if let t = ticker { player.removeTimeObserver(t) }
            player.pause()
            player.replaceCurrentItem(with: nil)
        }
    }

    private func begin() async {
        #if os(iOS)
        // Sound even with the ring switch on silent, like any video app.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        let item: AVPlayerItem
        switch play.source {
        case .url(let u):
            item = AVPlayerItem(url: u)
        case .drive(let id):
            let s = DriveStream(fileID: id)
            stream = s
            item = AVPlayerItem(asset: s.asset())
        }
        player.replaceCurrentItem(with: item)
        // Where it's got to, every 10 seconds (and when it closes), for Continue Watching.
        ticker = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 10, preferredTimescale: 1), queue: .main) { _ in
            Task { @MainActor in report() }
        }
        if play.start > 5 {
            await player.seek(to: CMTime(seconds: play.start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        player.play()
        // A file Apple's player can't open, or the TV out of reach: said over the player.
        for _ in 0..<40 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if item.status == .failed {
                failed = item.error?.localizedDescription ?? "The TV couldn’t send it. Check the TV is on, or play it on a TV instead."
                return
            }
            if item.status == .readyToPlay { return }
        }
    }
}

extension PhonePlayerView {
    @MainActor fileprivate func report() {
        let pos = player.currentTime().seconds, dur = player.currentItem?.duration.seconds ?? 0
        guard pos.isFinite, pos > 0 else { return }
        DriveLibrary.shared.played(play.key, title: play.title, pos: pos * 1000, dur: dur.isFinite ? dur * 1000 : 0)
    }
}

#if os(iOS)
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

    func present(_ play: PhonePlay) {
        finish()
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        let item: AVPlayerItem
        switch play.source {
        case .url(let u):
            item = AVPlayerItem(url: u)
        case .drive(let id):
            let s = DriveStream(fileID: id)
            stream = s
            item = AVPlayerItem(asset: s.asset())
        }
        // The title on the player and the Lock Screen.
        let title = AVMutableMetadataItem()
        title.identifier = .commonIdentifierTitle
        title.value = play.title as NSString
        title.extendedLanguageTag = "und"
        item.externalMetadata = [title]

        let p = AVPlayer(playerItem: item)
        player = p
        current = play
        let c = PlayerController()
        c.player = p
        c.delegate = self
        c.allowsPictureInPicturePlayback = true
        c.canStartPictureInPictureAutomaticallyFromInline = true
        c.updatesNowPlayingInfoCenter = true
        c.modalPresentationStyle = .fullScreen
        c.onGone = { [weak self] in self?.closed() }
        controller = c
        ticker = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 10, preferredTimescale: 1), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.report() }
        }
        Self.top()?.present(c, animated: true) {
            Task { @MainActor in
                if play.start > 5 {
                    await p.seek(to: CMTime(seconds: play.start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                }
                p.play()
            }
        }
    }

    /// The screen to show it over: the topmost one.
    private static func top() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive } ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var vc = scene?.windows.first { $0.isKeyWindow }?.rootViewController ?? scene?.windows.first?.rootViewController
        while let next = vc?.presentedViewController, !next.isBeingDismissed { vc = next }
        return vc
    }

    private func report() {
        guard let p = player, let play = current else { return }
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
        DriveLibrary.shared.flush()
        Task { await DriveLibrary.shared.sync() }
        if let t = ticker { player?.removeTimeObserver(t) }
        ticker = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        stream = nil
        current = nil
        controller = nil
    }

    // MARK: Picture in picture

    nonisolated func playerViewControllerWillStartPictureInPicture(_ c: AVPlayerViewController) {
        MainActor.assumeIsolated { inPictureInPicture = true }
    }

    nonisolated func playerViewControllerDidStopPictureInPicture(_ c: AVPlayerViewController) {
        MainActor.assumeIsolated {
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
