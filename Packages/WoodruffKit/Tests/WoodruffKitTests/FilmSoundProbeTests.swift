import AVFoundation
import CoreMedia
import XCTest
@testable import WoodruffKit

/// What Apple's reader makes of a film whose sound it has no decoder for (the fixture's DTS and Dolby TrueHD tracks,
/// written as FFmpeg and HandBrake write them). It stops the tests on purpose, with what it found: gone with the
/// next commit.
final class FilmSoundProbeTests: XCTestCase {
    func testWhatAppleMakesOfDTSAndTrueHD() async throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "dts-truehd-aac", withExtension: "mp4", subdirectory: "Fixtures"))
        let data = try Data(contentsOf: url)
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.load(.tracks)
        var lines: [String] = ["tracks: \(tracks.count)"]
        for track in tracks {
            let formats = (try? await track.load(.formatDescriptions)) ?? []
            var line = "track \(track.trackID) \(track.mediaType.rawValue): \(formats.count) formats"
            if let format = formats.first {
                line += ", subtype '\(FilmPlayer.letters(CMFormatDescriptionGetMediaSubType(format)))'"
                if let b = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee {
                    line += ", asbd id '\(FilmPlayer.letters(b.mFormatID))' rate \(b.mSampleRate) channels \(b.mChannelsPerFrame)"
                    line += " frames/packet \(b.mFramesPerPacket) flags \(b.mFormatFlags)"
                }
                var size = 0
                if let cookie = CMAudioFormatDescriptionGetMagicCookie(format, sizeOut: &size), size > 0 {
                    let bytes = UnsafeRawBufferPointer(start: cookie, count: min(size, 64))
                    line += ", cookie \(size) bytes " + bytes.map { String(format: "%02x", $0) }.joined()
                } else {
                    line += ", no cookie"
                }
                if let ext = CMFormatDescriptionGetExtensions(format) as? [String: Any] {
                    line += ", extensions \(ext.keys.sorted())"
                }
            }
            let decodable = try? await track.load(.isDecodable)
            let enabled = try? await track.load(.isEnabled)
            let cursors = try? await track.load(.canProvideSampleCursors)
            line += ", decodable \(String(describing: decodable)), enabled \(String(describing: enabled)), cursors \(String(describing: cursors))"
            if cursors == true, let cursor = track.makeSampleCursorAtFirstSampleInDecodeOrder() {
                var count = 0
                var sizes: [Int] = []
                var syncs: [Bool] = []
                var first = ""
                var more = true
                while more, count < 100_000 {
                    let range = cursor.currentSampleStorageRange
                    if count < 3 {
                        sizes.append(Int(range.length))
                        syncs.append(cursor.currentSampleSyncInfo.sampleIsFullSync.boolValue)
                    }
                    if count == 0, range.offset >= 0, Int(range.offset) + 8 <= data.count {
                        let at = Int(range.offset)
                        first = data.subdata(in: at..<(at + 8)).map { String(format: "%02x", $0) }.joined()
                    }
                    count += 1
                    more = cursor.stepInDecodeOrder(byCount: 1) == 1
                }
                line += ", \(count) samples, first sizes \(sizes), full sync \(syncs), first bytes \(first)"
            }
            if track.mediaType == .audio, let reader = FilmTrackReader(track: track), let run = reader.next() {
                line += ", first run \(run.samples.count) samples of \(run.length) bytes from \(run.offset)"
            }
            lines.append(line)
        }
        XCTFail("PROBE\n" + lines.joined(separator: "\n"))
    }
}
