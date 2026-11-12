import Foundation
import FilmHeights
import WoodruffKit
#if canImport(FilmSound)
import FilmSound
#endif

/// The Apple TV's decoder for sound Apple has none for: DTS, DTS-HD and Dolby TrueHD, decoded to plain samples by
/// FFmpeg's decoders (FilmSound.framework: Packages/FilmSound, built by scripts/build_filmsound.sh; LGPL 2.1).
///
/// TrueHD with Atmos keeps its overhead sounds: LibTrueHD reads the Atmos part and AetherEngine's regression turns
/// the film's own 7.1 into 7.1 with four overhead channels (Packages/FilmHeights), which the Apple TV sends on as
/// Dolby Atmos. Where that can't be done (not Atmos, another rate, nothing comes of it) the film's 7.1 plays.
///
/// The app's own player asks for one through `FilmSoundDecoders` when a film's sound is one of those. The framework
/// is linked weakly: a build without it still starts, and such sound then can't be played, as before there was a
/// decoder. `said` tells the Macs' log which it is.
final class TVFilmSound: FilmSoundDecoder {
    /// Settings, Watch: overhead sound for Atmos and DTS:X. On unless switched off.
    static let heightsKey = "watch.heights"
    static var heightsWanted: Bool { UserDefaults.standard.object(forKey: heightsKey) as? Bool ?? true }

    #if canImport(FilmSound)
    private let sound: OpaquePointer
    private let kind: String

    /// (TrueHD) what turns the film's Atmos into overhead channels, from the first packet that says the sound has
    /// Atmos; nil for sound without it, and once it has been given up on.
    private var atmos: TrueHDHeights?
    private var atmosAsked = false
    /// Packets it has been given since it last handed any sound back.
    private var atmosQuiet = 0
    /// This many packets with nothing back (half a second of sound) and the film's 7.1 plays instead. After the
    /// film is moved it gives nothing until the sound next starts afresh and its first positions arrive: a
    /// quarter of a second at most.
    private static let atmosPatience = 600

    private init?(kind: String) {
        let number: Int32
        switch kind {
        case "dts": number = Int32(WFSOUND_DTS)
        case "truehd": number = Int32(WFSOUND_TRUEHD)
        default: return nil
        }
        guard Self.ready, let made = wfsound_open(number) else { return nil }
        sound = made
        self.kind = kind
    }

    deinit {
        wfsound_close(sound)
    }

    func decode(_ packet: UnsafeRawBufferPointer, at seconds: Double) -> FilmDecodedSound? {
        guard packet.count > 0, let base = packet.bindMemory(to: UInt8.self).baseAddress else { return nil }
        if kind == "truehd", let heard = overhead(packet, at: seconds) { return heard }
        var samples: UnsafePointer<Float>?
        var channels: Int32 = 0
        var rate: Int32 = 0
        let frames = wfsound_decode(sound, base, Int32(packet.count), &samples, &channels, &rate)
        guard frames >= 0 else { return nil }
        guard frames > 0, channels > 0, let samples else { return Self.nothingYet }
        return FilmDecodedSound(samples: UnsafeBufferPointer(start: samples, count: Int(frames) * Int(channels)),
                                frames: Int(frames), channels: Int(channels), rate: Int(rate))
    }

    /// Nothing yet: the decoder wants more first.
    private static let nothingYet = FilmDecodedSound(samples: UnsafeBufferPointer(start: nil, count: 0), frames: 0, channels: 0, rate: 0)

    /// A TrueHD packet through the Atmos path, when the film's sound has Atmos: twelve channels, or nothing yet.
    /// Nil when this packet is the plain decoder's (no Atmos, or the Atmos path was given up on just now).
    private func overhead(_ packet: UnsafeRawBufferPointer, at seconds: Double) -> FilmDecodedSound? {
        if !atmosAsked, let has = TrueHDHeights.isAtmos(packet) {
            atmosAsked = true
            if has, Self.heightsWanted {
                atmos = TrueHDHeights()
                Self.note(atmos == nil ? "TrueHD Atmos: the decoder for its overhead sounds couldn’t be made, so its 7.1 plays"
                                       : "TrueHD Atmos: played with its overhead sounds, as 7.1 with four overhead channels")
            } else if has {
                Self.note("TrueHD Atmos: overhead sound is switched off in Settings, so its 7.1 plays")
            }
        }
        guard let atmos else { return nil }
        if let ready = atmos.render(packet, at: seconds) {
            atmosQuiet = 0
            return FilmDecodedSound(samples: ready.samples, frames: ready.frames, channels: 12, rate: 48_000, starts: ready.starts)
        }
        atmosQuiet += 1
        guard atmos.unsupported || atmosQuiet > Self.atmosPatience else { return Self.nothingYet }
        // It can't be done for this film after all: its 7.1 plays from here, from the plain decoder.
        Self.note(atmos.unsupported ? "TrueHD Atmos: its sound isn’t at 48,000 a second, so its 7.1 plays"
                                    : "TrueHD Atmos: nothing came of \(atmosQuiet) packets (\(atmos.failures) refused), so its 7.1 plays")
        self.atmos = nil
        wfsound_flush(sound)
        return nil
    }

    func flush() {
        wfsound_flush(sound)
        atmos?.reset()
        atmosQuiet = 0
    }

    /// The framework loaded with the app (it's linked weakly, so the app starts without it too).
    static let ready: Bool = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "wfsound_open") != nil

    /// What the decoder was built from ("FFmpeg Lavc61.19.101, configured: …"), up to its first comma.
    private static var builtFrom: String {
        guard ready, let text = wfsound_about() else { return "" }
        return String(cString: text).split(separator: ",").first.map { String($0) } ?? ""
    }
    #else
    private init?(kind: String) {
        return nil
    }

    func decode(_ packet: UnsafeRawBufferPointer, at seconds: Double) -> FilmDecodedSound? {
        nil
    }

    func flush() {}

    static let ready = false
    private static var builtFrom: String { "" }
    #endif

    /// Gives the app's own player its decoders. Asked before every film; done once.
    static func install() {
        guard ready, FilmSoundDecoders.make == nil else { return }
        FilmSoundDecoders.make = { TVFilmSound(kind: $0) }
        FilmHeightsLog.note = { note($0) }
    }

    /// A line for the Macs' log, from whichever thread the decoder runs on.
    private static func note(_ line: String) {
        Task { @MainActor in Diagnostics.shared.notePlayback("The app’s own player: " + line) }
    }

    /// For the Macs' log, with the first film played after the app starts: whether DTS and TrueHD are decoded here.
    static var said: String {
        ready ? "DTS and Dolby TrueHD sound is decoded by the app’s own decoder (\(builtFrom)); overhead sound for Atmos and DTS:X is \(heightsWanted ? "on" : "off")"
              : "this build has no decoder for DTS or Dolby TrueHD sound"
    }
}
