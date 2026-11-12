import AVFoundation

/// Keeps the Apple TV's HDMI output in Dolby Atmos while a film's sound is played with its overhead channels.
///
/// The Apple TV carries sound with overhead channels over HDMI only as Dolby Atmos, and some sound systems only
/// switch to it for a stream marked as Atmos. AetherEngine's `AtmosOutputActivator` plays such a stream beside the
/// film: a few seconds of digital silence, looped. This is the app's handle on it.
@MainActor
public final class HeightsOutputKeeper {
    private let activator = AtmosOutputActivator()
    private var playing: (@MainActor () -> Bool?)?

    public init() {}

    /// Starts following a film: [isPlaying] says true while it plays or waits to, false while it's paused, and nil
    /// once it's closed.
    public func follow(isPlaying: @escaping @MainActor () -> Bool?) {
        playing = isPlaying
        activator.attachRenderer(isPlaying: isPlaying)
    }

    /// The film was started, paused or moved: looked at again.
    public func refresh() {
        guard playing != nil else { return }
        activator.refresh()
    }

    /// The film is closed.
    public func stop() {
        playing = nil
        activator.detach()
    }

    /// The silent stream is playing now.
    public var isOn: Bool { activator.isPlayingStream }
}
