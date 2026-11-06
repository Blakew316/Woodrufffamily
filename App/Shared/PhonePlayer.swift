import SwiftUI
import AVKit
import WoodruffKit

/// A film or episode from the TV's library played on this iPhone, iPad or Mac instead of a TV: the TV that holds
/// the library streams it (from its own storage, or from Drive with its sign-in), and Apple's player shows it, from
/// where it was left off.
struct PhonePlay: Identifiable {
    let id = UUID()
    var url: URL
    var title: String
    var start: Double   // seconds
}

@MainActor
enum PhonePlayback {
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
        guard let c = fleet.hubClient() else { fleet.show(TVError.notPaired); return nil }
        let ext = (a.key as NSString).pathExtension.lowercased()
        if unplayable.contains(ext) {
            fleet.say("Can’t Play on \(deviceName)", "It’s an \(ext.uppercased()) file, which Apple’s player can’t open. Play it on a TV instead.")
            return nil
        }
        let start = fromStart ? 0 : max(0, (a.position ?? 0) / 1000)
        return PhonePlay(url: c.streamURL(a.key), title: a.title, start: start)
    }
}

/// Apple's player, full screen on iPhone and iPad, in a window-sized sheet on the Mac.
struct PhonePlayerView: View {
    let play: PhonePlay
    @Environment(\.dismiss) private var dismiss
    @State private var player = AVPlayer()
    @State private var failed: String?

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
        .onDisappear { player.pause(); player.replaceCurrentItem(with: nil) }
    }

    private func begin() async {
        #if os(iOS)
        // Sound even with the ring switch on silent, like any video app.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        let item = AVPlayerItem(url: play.url)
        player.replaceCurrentItem(with: item)
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

extension View {
    /// Shows [play] in the player while it's set.
    func phonePlayer(_ play: Binding<PhonePlay?>) -> some View {
        #if os(iOS)
        fullScreenCover(item: play) { PhonePlayerView(play: $0) }
        #else
        sheet(item: play) { PhonePlayerView(play: $0) }
        #endif
    }
}
