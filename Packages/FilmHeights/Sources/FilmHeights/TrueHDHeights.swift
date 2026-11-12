import Foundation

/// Dolby TrueHD with Atmos, as 7.1 with four overhead channels.
///
/// LibTrueHD decodes each packet's own lossless 7.1 (or 5.1) and its Atmos presentation: where every sound sits,
/// overhead ones included. AetherEngine's regression then builds each of the twelve speakers out of that 7.1,
/// taking for the overhead ones the part of it that belongs up there. (FFmpeg's TrueHD decoder, which plays
/// TrueHD without Atmos here, reads only the 7.1.)
public final class TrueHDHeights {
    private let decoder: TrueHDObjectAudioDecoder
    private let core = HeightsCore()
    /// When the first packet the decoder took since the last reset plays: its own count of frames starts there.
    private var origin: Double?
    private var resets: Int
    /// Packets the decoder wouldn't take or couldn't decode, since it was made.
    public private(set) var failures = 0
    /// The sound isn't at 48,000 a second: it can't be rendered here, and plays as its 7.1.
    public private(set) var unsupported = false

    /// Nil when the decoder can't be made.
    public init?() {
        guard let decoder = try? TrueHDObjectAudioDecoder() else { return nil }
        self.decoder = decoder
        resets = decoder.selfResetCount
    }

    /// Whether a TrueHD packet says its sound has Atmos. Nil for a packet that doesn't say (only those that start
    /// the sound afresh do).
    public static func isAtmos(_ packet: UnsafeRawBufferPointer) -> Bool? {
        TrueHDMajorSync.isAtmos(packet)
    }

    /// The film was moved to another place.
    public func reset() {
        decoder.reset()
        core.reset()
        origin = nil
        resets = decoder.selfResetCount
    }

    /// One packet as the file holds it, and when it plays. What is ready by now, or nil.
    public func render(_ packet: UnsafeRawBufferPointer, at seconds: Double) -> HeightsOutput? {
        do {
            try decoder.push(packet)
        } catch {
            failures += 1
            startedOver()
            return ready()
        }
        if origin == nil { origin = seconds }
        do {
            while let block = try decoder.nextBlock() {
                guard block.sampleRate == HeightsCore.rate else {
                    unsupported = true
                    break
                }
                core.add(block)
            }
        } catch {
            failures += 1
        }
        let out = ready()
        startedOver()
        return out
    }

    /// After the decoder reset itself its count of frames starts again with the next packet it takes: so does
    /// everything built on it.
    private func startedOver() {
        guard decoder.selfResetCount != resets else { return }
        resets = decoder.selfResetCount
        core.reset()
        origin = nil
    }

    private func ready() -> HeightsOutput? {
        guard let origin, let out = core.take() else { return nil }
        return HeightsOutput(samples: out.samples, frames: out.frames, starts: origin + Double(out.position) / Double(HeightsCore.rate))
    }
}
