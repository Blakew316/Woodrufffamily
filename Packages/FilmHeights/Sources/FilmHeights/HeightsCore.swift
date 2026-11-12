import Foundation

/// Speaker sound with four overhead channels, as the renderers here give it.
public struct HeightsOutput {
    /// Twelve channels to a frame, 32-bit floats: left, right, centre, low, surround left, surround right, rear
    /// left, rear right, top front left, top front right, top rear left, top rear right. Good until the renderer
    /// is next asked.
    public let samples: UnsafeBufferPointer<Float>
    public let frames: Int
    /// When the first frame plays, in seconds on the film's clock.
    public let starts: Double
}

/// Builds 7.1.4 from decoded blocks, as AetherEngine's SpatialAudioBridge does, without its encoder: the blocks'
/// placement, the regression that makes every output out of the stream's own 7.1 (or 5.1), and the limiter.
///
/// What comes out lines up with what went in frame for frame: output frame n is the n-th frame since the first
/// block (the regression holds 2,048 frames back and hands them over late, which `position` accounts for).
final class HeightsCore {
    static let layout = SpatialSpeakerLayout.l714
    static let rate = 48_000
    /// Frames the decoder skipped (damaged packets) are filled with silence up to this many; past that the sound
    /// starts again where the next block is.
    static let longestFilledGap: Int64 = 5 * 48_000

    private var placement: ObjectAudioPlacement?
    private var placementGeneration = Int.min
    private var splitter: BedRegression?
    private var limiter = PeakLimiter(sampleRate: HeightsCore.rate)
    private var gains = ObjectAudioGainSnapshot()
    /// One plane for each speaker of the layout, `capacity` frames each; the first `pending` are waiting.
    private var planes: [UnsafeMutablePointer<Float>] = []
    private var capacity = 0
    private var pending = 0
    /// Where the first frame since the last reset is (the first block's own place), the frames handed out since,
    /// and where the next block is expected.
    private var anchor: Int64?
    private var produced: Int64 = 0
    private var expected: Int64?
    /// What `take` hands out, frame by frame.
    private var interleaved: UnsafeMutablePointer<Float>?
    private var interleavedCapacity = 0

    deinit {
        for plane in planes { plane.deallocate() }
        interleaved?.deallocate()
    }

    /// The film was moved, or the decoder started over: nothing held is kept.
    func reset() {
        placement?.reset()
        splitter?.reset()
        limiter.reset()
        pending = 0
        anchor = nil
        produced = 0
        expected = nil
    }

    private func room(for frames: Int) {
        guard frames > capacity else { return }
        let wanted = max(frames, capacity * 2, 8_192)
        let count = Self.layout.channelCount
        var grown: [UnsafeMutablePointer<Float>] = []
        for index in 0..<count {
            let plane = UnsafeMutablePointer<Float>.allocate(capacity: wanted)
            plane.initialize(repeating: 0, count: wanted)
            if index < planes.count, pending > 0 { plane.update(from: planes[index], count: pending) }
            grown.append(plane)
        }
        for plane in planes { plane.deallocate() }
        planes = grown
        capacity = wanted
    }

    private func silence(_ frames: Int) {
        guard frames > 0 else { return }
        room(for: pending + frames)
        if let splitter {
            pending += splitter.process(elements: nil, bed: nil, frameCount: frames, output: planes.map { $0 + pending })
        } else {
            for plane in planes { (plane + pending).update(repeating: 0, count: frames) }
            pending += frames
        }
    }

    /// One decoded block in. What it comes to is handed out by `take`.
    func add(_ block: ObjectAudioDecodedBlock) {
        guard block.sampleRate == Self.rate, block.frameCount > 0 else { return }
        if placement == nil || block.configurationGeneration != placementGeneration {
            placement = ObjectAudioPlacement(layout: Self.layout, roles: block.roles)
            placementGeneration = block.configurationGeneration
        }
        if anchor == nil {
            anchor = block.inputFrameOffset
        } else if let expected, block.inputFrameOffset > expected {
            let gap = block.inputFrameOffset - expected
            if gap <= Self.longestFilledGap {
                silence(Int(gap))
            } else {
                // Too far on to fill: what waits is let go, and the sound starts again at this block.
                splitter?.reset()
                limiter.reset()
                pending = 0
                produced = 0
                anchor = block.inputFrameOffset
            }
        }
        expected = block.inputFrameOffset + Int64(block.frameCount)
        guard let placement else { return }

        if let bed = block.bed {
            if splitter?.bedRoles != bed.roles || splitter?.folds != bed.folds {
                // Another kind of bed: what the regression still holds comes out first, so nothing is lost.
                if let old = splitter, old.backlog > 0 {
                    room(for: pending + old.backlog)
                    pending += old.drain(output: planes.map { $0 + pending })
                }
                splitter = BedRegression(layout: Self.layout, bedRoles: bed.roles, folds: bed.folds)
            }
            room(for: pending + block.frameCount)
            placement.apply(block.updates)
            placement.snapshot(into: &gains)
            if let splitter {
                splitter.setGains(gains)
                pending += splitter.process(elements: block.planes, bed: bed.planes, frameCount: block.frameCount,
                                            output: planes.map { $0 + pending })
            }
        } else {
            // A block without the stream's own 7.1 or 5.1: silence in its place, never the element signals.
            placement.apply(block.updates)
            silence(block.frameCount)
        }
    }

    /// The frames that are ready, limited and laid frame by frame, with the place of the first (in frames from
    /// where the decoder's own count starts). Nil when none are.
    func take() -> (samples: UnsafeBufferPointer<Float>, frames: Int, position: Int64)? {
        guard pending > 0, let anchor else { return nil }
        let frames = pending
        let count = planes.count
        limiter.process(planes, frameCount: frames)
        if frames * count > interleavedCapacity {
            interleaved?.deallocate()
            interleavedCapacity = max(frames * count, interleavedCapacity * 2)
            interleaved = UnsafeMutablePointer<Float>.allocate(capacity: interleavedCapacity)
        }
        guard let interleaved else { return nil }
        for channel in 0..<count {
            let plane = planes[channel]
            var at = channel
            for frame in 0..<frames {
                interleaved[at] = plane[frame]
                at += count
            }
        }
        let position = anchor + produced
        produced += Int64(frames)
        pending = 0
        return (UnsafeBufferPointer(start: interleaved, count: frames * count), frames, position)
    }
}
