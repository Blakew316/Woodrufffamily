import XCTest
@testable import FilmHeights

/// The app's own glue around AetherEngine's regression: DTS:X's twelve decoded channels in, 7.1 with four overhead
/// channels out, each sound on its own speaker and on its own place in time.
final class HeightsTests: XCTestCase {
    private static let rate = 48_000.0
    /// The 7.1's tones, in the order the decoder gives the channels (left, right, centre, low, surround left,
    /// surround right, rear left, rear right), then the four overhead channels' (top front left and right, top
    /// rear left and right).
    private static let pitches: [Double] = [300, 500, 700, 50, 900, 1100, 1300, 1500, 2500, 3100, 3700, 4300]
    /// Where each overhead channel is mixed into the 7.1: under it.
    private static let under = [8: 0, 9: 1, 10: 6, 11: 7]

    /// How much of [pitch] is in channel [channel] of [frames] frames starting at [from].
    private func amount(_ samples: [Float], channel: Int, pitch: Double, from: Int, frames: Int) -> Double {
        var re = 0.0, im = 0.0
        for i in 0..<frames {
            let phase = 2 * Double.pi * pitch * Double(from + i) / Self.rate
            let v = Double(samples[(from + i) * 12 + channel])
            re += v * cos(phase)
            im += v * sin(phase)
        }
        return (re * re + im * im).squareRoot() / Double(frames)
    }

    func testDTSXOverheadChannelsMoveToTheirOwnSpeakers() throws {
        let heights = DTSXHeights()
        let gain = try XCTUnwrap(DTSXHeights.foldGain(presentation: 1))
        XCTAssertEqual(gain, 0.7071, accuracy: 0.001)
        XCTAssertEqual(DTSXHeights.foldGain(presentation: 0xd0), 1)
        XCTAssertNil(DTSXHeights.foldGain(presentation: 0xd4))

        // Three seconds in packets of 512 frames, starting ten seconds into a film. Every channel carries a tone
        // of its own; each overhead tone is also in the speaker under it, as a DTS:X encoder mixes it.
        let each = 512, packets = 282
        var out: [Float] = []
        var next: Double?
        var first: Double?
        var packet = [Float](repeating: 0, count: each * 12)
        for n in 0..<packets {
            for i in 0..<each {
                let t = Double(n * each + i) / Self.rate
                var frame = Self.pitches.map { Float(0.2 * sin(2 * Double.pi * $0 * t)) }
                for (height, speaker) in Self.under { frame[speaker] += gain * frame[height] }
                for c in 0..<12 { packet[i * 12 + c] = frame[c] }
            }
            let seconds = 10 + Double(n * each) / Self.rate
            guard let ready = packet.withUnsafeBufferPointer({ heights.render($0.baseAddress!, frames: each, foldGain: gain, at: seconds) }) else { continue }
            if first == nil { first = ready.starts }
            if let next { XCTAssertEqual(ready.starts, next, accuracy: 0.5 / Self.rate, "packet \(n) goes on where the last ended") }
            next = ready.starts + Double(ready.frames) / Self.rate
            XCTAssertEqual(ready.samples.count, ready.frames * 12)
            out.append(contentsOf: ready.samples)
        }
        // What comes out starts where the first packet plays, and all of it comes but what the regression still holds.
        XCTAssertEqual(try XCTUnwrap(first), 10, accuracy: 0.5 / Self.rate)
        let frames = out.count / 12
        XCTAssertEqual(frames, packets * each - 2_048)

        // From one second in: every channel holds its own tone at its own level, an overhead tone is gone from the
        // speaker it was mixed into, and nothing is out of place in time (the tones' phases are the input's).
        let from = 48_000, window = 72_000
        for channel in 0..<12 {
            let own = amount(out, channel: channel, pitch: Self.pitches[channel], from: from, frames: window)
            XCTAssertEqual(own, 0.1, accuracy: 0.02, "channel \(channel) holds its own tone")
            for other in 0..<12 where other != channel {
                let stray = amount(out, channel: channel, pitch: Self.pitches[other], from: from, frames: window)
                XCTAssertLessThan(stray, 0.02, "channel \(channel) holds channel \(other)'s tone")
            }
        }
        // (In step with the input: the left channel's tone, measured against the input's own phase.)
        var inPhase = 0.0
        for i in 0..<window {
            let t = Double(from + i) / Self.rate
            inPhase += Double(out[(from + i) * 12]) * 0.2 * sin(2 * Double.pi * 300 * t)
        }
        XCTAssertGreaterThan(inPhase / Double(window), 0.015, "the left channel is in step with what went in")

        // After the film is moved the sound starts again at the packet that follows, with the first packets'
        // frames counted though not played.
        heights.reset()
        heights.skip(frames: each, at: 60)
        heights.skip(frames: each, at: 60 + Double(each) / Self.rate)
        var restarted: Double?
        for n in 2..<12 {
            let seconds = 60 + Double(n * each) / Self.rate
            if let ready = packet.withUnsafeBufferPointer({ heights.render($0.baseAddress!, frames: each, foldGain: gain, at: seconds) }), restarted == nil {
                restarted = ready.starts
            }
        }
        XCTAssertEqual(try XCTUnwrap(restarted), 60 + Double(2 * each) / Self.rate, accuracy: 0.5 / Self.rate)
    }

    func testTrueHDHeightsTakesWhatItIsGiven() throws {
        // The decoder is there on this Mac (LibTrueHD links), and bytes that aren't TrueHD give nothing and break nothing.
        let heights = try XCTUnwrap(TrueHDHeights())
        let junk = [UInt8](repeating: 0x5A, count: 512)
        for n in 0..<40 {
            XCTAssertNil(junk.withUnsafeBytes { heights.render($0, at: Double(n) / 1200) })
        }
        heights.reset()
        XCTAssertNil(junk.withUnsafeBytes { heights.render($0, at: 0) })
        XCTAssertFalse(heights.unsupported)
        XCTAssertNil(junk.withUnsafeBytes { TrueHDHeights.isAtmos($0) })
    }
}
