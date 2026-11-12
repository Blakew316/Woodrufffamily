import Foundation
import WoodruffKit
#if canImport(FilmSound)
import FilmSound
#endif

/// The Apple TV's decoder for sound Apple has none for: DTS, DTS-HD and Dolby TrueHD, decoded to plain samples by
/// FFmpeg's decoders (FilmSound.framework: Packages/FilmSound, built by scripts/build_filmsound.sh; LGPL 2.1).
///
/// The app's own player asks for one through `FilmSoundDecoders` when a film's sound is one of those. The framework
/// is linked weakly: a build without it still starts, and such sound then can't be played, as before there was a
/// decoder. `said` tells the Macs' log which it is.
final class TVFilmSound: FilmSoundDecoder {
    #if canImport(FilmSound)
    private let sound: OpaquePointer

    private init?(kind: String) {
        let number: Int32
        switch kind {
        case "dts": number = Int32(WFSOUND_DTS)
        case "truehd": number = Int32(WFSOUND_TRUEHD)
        default: return nil
        }
        guard Self.ready, let made = wfsound_open(number) else { return nil }
        sound = made
    }

    deinit {
        wfsound_close(sound)
    }

    func decode(_ packet: UnsafeRawBufferPointer) -> FilmDecodedSound? {
        guard packet.count > 0, let base = packet.bindMemory(to: UInt8.self).baseAddress else { return nil }
        var samples: UnsafePointer<Float>?
        var channels: Int32 = 0
        var rate: Int32 = 0
        let frames = wfsound_decode(sound, base, Int32(packet.count), &samples, &channels, &rate)
        guard frames >= 0 else { return nil }
        guard frames > 0, channels > 0, let samples else {
            // Nothing yet: the decoder wants more first.
            return FilmDecodedSound(samples: UnsafeBufferPointer(start: nil, count: 0), frames: 0, channels: 0, rate: 0)
        }
        return FilmDecodedSound(samples: UnsafeBufferPointer(start: samples, count: Int(frames) * Int(channels)),
                                frames: Int(frames), channels: Int(channels), rate: Int(rate))
    }

    func flush() {
        wfsound_flush(sound)
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

    func decode(_ packet: UnsafeRawBufferPointer) -> FilmDecodedSound? {
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
    }

    /// For the Macs' log, with the first film played after the app starts: whether DTS and TrueHD are decoded here.
    static var said: String {
        ready ? "DTS and Dolby TrueHD sound is decoded by the app’s own decoder (\(builtFrom))"
              : "this build has no decoder for DTS or Dolby TrueHD sound"
    }
}
