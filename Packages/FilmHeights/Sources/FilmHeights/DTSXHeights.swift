import Foundation

/// DTS:X, as 7.1 with four overhead channels.
///
/// A DTS:X track is DTS-HD Master Audio whose 7.1 has the four overhead channels mixed into it (each into the
/// speaker under it), with those four channels carried again beside it. The decoder (FFmpeg's, with FFmpegBuild's
/// patch for the overhead channels) gives all twelve. AetherEngine's regression then moves, for each overhead
/// channel, the part of the 7.1 that belongs to it up to its own speaker; nothing is played twice.
///
/// The tables and rules here are AetherEngine's (`DTSXObjectAudioDecoder`), fitted to a decoder that hands over
/// whole decoded packets.
public final class DTSXHeights {
    /// The 7.1 as the decoder gives it here: left, right, centre, low, surround left, surround right, rear left,
    /// rear right.
    static let bedRoles: [ObjectAudioRole] = [
        .bed(.left), .bed(.right), .bed(.center), .lfe, .bed(.sideLeft), .bed(.sideRight), .bed(.rearLeft), .bed(.rearRight),
    ]
    /// The four overhead channels, a block's elements: top front left and right, top rear left and right.
    static let roles: [ObjectAudioRole] = [.bed(.topFrontLeft), .bed(.topFrontRight), .bed(.topRearLeft), .bed(.topRearRight)]
    static let channels = 12

    /// How the encoder mixed each overhead channel into the 7.1: the front ones into left and right, the rear ones
    /// into the rear surrounds, at [gain].
    static func folds(gain: Float) -> [ObjectAudioBedFold] {
        [
            (SpatialSpeaker.topFrontLeft, SpatialSpeaker.left), (.topFrontRight, .right),
            (.topRearLeft, .rearLeft), (.topRearRight, .rearRight),
        ].map { height, speaker in
            ObjectAudioBedFold(element: roles.firstIndex(of: .bed(height))!, plane: bedRoles.firstIndex(of: .bed(speaker))!, gain: gain)
        }
    }

    /// The gain of that mix for the kind of DTS:X the decoder says the overhead channels came from (1 the usual
    /// one, else the last byte of another kind's own mark). It's the format's, measured by AetherEngine on many
    /// films, never read from the film: -3 dB for the usual kind and two others, none for one, and nil for a kind
    /// nobody has measured, which plays as its 7.1.
    public static func foldGain(presentation: Int) -> Float? {
        switch presentation {
        case 1, 0xd1, 0xd3: return 23170 / 32768
        case 0xd0: return 1
        default: return nil
        }
    }

    /// Packets decoded after the film is moved only to get the decoder going: the first comes out distorted and
    /// the second can still be a little off, so neither is played (they still count on the sound's own clock).
    public static let primingPackets = 2

    private let core = HeightsCore()
    private var origin: Double?
    /// Frames given since the last reset, played or not.
    private var fed: Int64 = 0
    private var discontinuity = true
    private var gain: Float?
    private var storage: UnsafeMutablePointer<Float>?
    private var storageFrames = 0

    public init() {}

    deinit {
        storage?.deallocate()
    }

    /// The film was moved to another place.
    public func reset() {
        core.reset()
        origin = nil
        fed = 0
        discontinuity = true
    }

    /// [frames] frames of the sound went by without being given here (a packet nothing came of, or one decoded
    /// only to get the decoder going): they count on the sound's own clock.
    public func skip(frames: Int, at seconds: Double) {
        if origin == nil { origin = seconds }
        fed += Int64(max(0, frames))
        discontinuity = true
    }

    /// One decoded packet: [frames] frames of twelve channels at 48,000 a second, frame by frame, in this order:
    /// the 7.1 as coded (left, right, centre, low, surround left, surround right, rear left, rear right), then
    /// top front left, top front right, top rear left, top rear right. [foldGain]: see `foldGain(presentation:)`.
    /// [seconds]: when the packet plays. What is ready by now, or nil.
    public func render(_ samples: UnsafePointer<Float>, frames: Int, foldGain: Float, at seconds: Double) -> HeightsOutput? {
        guard frames > 0 else { return nil }
        if origin == nil { origin = seconds }
        if frames > storageFrames {
            storage?.deallocate()
            storageFrames = max(frames, 4_096)
            storage = UnsafeMutablePointer<Float>.allocate(capacity: storageFrames * Self.channels)
        }
        guard let storage else { return nil }
        // Each channel into a plane of its own.
        for channel in 0..<Self.channels {
            let plane = storage + channel * frames
            var at = channel
            for frame in 0..<frames {
                plane[frame] = samples[at]
                at += Self.channels
            }
        }
        var bed: [UnsafePointer<Float>] = []
        var elements: [UnsafePointer<Float>] = []
        for channel in 0..<Self.channels {
            let plane = UnsafePointer(storage + channel * frames)
            if channel < Self.bedRoles.count { bed.append(plane) } else { elements.append(plane) }
        }
        // Every overhead channel sits on its own speaker at full level. It's said again wherever the sound starts
        // over, and when the kind of mix changes.
        var updates: [ObjectAudioMetadataUpdate] = []
        if discontinuity || gain != foldGain {
            updates.append(ObjectAudioMetadataUpdate(frameOffset: 0, states: Self.roles.map(Self.state(for:))))
        }
        gain = foldGain
        let block = ObjectAudioDecodedBlock(
            sampleRate: HeightsCore.rate, frameCount: frames, inputFrameOffset: fed, configurationGeneration: 1,
            isDiscontinuity: discontinuity, roles: Self.roles, planes: elements, updates: updates,
            bed: ObjectAudioBed(roles: Self.bedRoles, planes: bed, folds: Self.folds(gain: foldGain)))
        fed += Int64(frames)
        discontinuity = false
        core.add(block)
        guard let origin, let out = core.take() else { return nil }
        return HeightsOutput(samples: out.samples, frames: out.frames, starts: origin + Double(out.position) / Double(HeightsCore.rate))
    }

    static func state(for role: ObjectAudioRole) -> ObjectAudioElementState {
        if case .bed(let speaker) = role { return ObjectAudioElementState(position: speaker.position, gain: 1) }
        return ObjectAudioElementState(gain: 1)
    }
}
