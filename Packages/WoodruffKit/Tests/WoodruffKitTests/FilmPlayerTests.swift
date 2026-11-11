#if canImport(AVFoundation) && os(macOS)
import XCTest
import AVFoundation
import CoreMedia
import UniformTypeIdentifiers
@testable import WoodruffKit

/// Hands a film's bytes to Apple's reader the way the app's Drive stream does: through a resource loader, a slice
/// at a time.
private final class TestLoader: NSObject, AVAssetResourceLoaderDelegate {
    let data: Data
    let queue = DispatchQueue(label: "test.loader")
    private let slice: Int64 = 16 << 10

    init(data: Data) { self.data = data }

    func resourceLoader(_ loader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        if let info = request.contentInformationRequest {
            info.contentType = UTType.mpeg4Movie.identifier
            info.contentLength = Int64(data.count)
            info.isByteRangeAccessSupported = true
        }
        guard let d = request.dataRequest else {
            request.finishLoading()
            return true
        }
        let from = d.requestedOffset
        let end = d.requestsAllDataToEndOfResource ? Int64(data.count) : min(Int64(data.count), from + Int64(d.requestedLength))
        step(request, at: from, end: end)
        return true
    }

    private func step(_ request: AVAssetResourceLoadingRequest, at: Int64, end: Int64) {
        guard !request.isCancelled, !request.isFinished else { return }
        guard at < end, let d = request.dataRequest else {
            request.finishLoading()
            return
        }
        let upTo = min(end, at + slice)
        d.respond(with: data.subdata(in: Int(at)..<Int(upTo)))
        queue.async { [weak self] in self?.step(request, at: upTo, end: end) }
    }
}

/// The film's bytes as the app's stream would bring them to the player: after a moment, noting what was asked.
private final class TestBytes: FilmBytes {
    struct Asked { let lane: Int; let offset: Int64; let count: Int }

    let data: Data
    /// How long every read takes, and one read to hold back: the [holdAt]th on [holdLane], for [holdFor] seconds.
    var delay = 0.01
    var holdLane = -1
    var holdAt = 0
    var holdFor = 0.0
    /// Reads to refuse first, on any lane, and with what.
    var failures: [Error] = []

    private let lock = NSLock()
    private var log: [Asked] = []
    private var forgot = 0

    init(data: Data) { self.data = data }

    func read(from offset: Int64, count: Int, lane: Int, then: @escaping (Result<Data, Error>) -> Void) {
        lock.lock()
        log.append(Asked(lane: lane, offset: offset, count: count))
        let nth = log.filter { $0.lane == lane }.count
        let failure = failures.isEmpty ? nil : failures.removeFirst()
        lock.unlock()
        let wait = delay + (lane == holdLane && nth == holdAt ? holdFor : 0)
        let data = self.data
        DispatchQueue.global().asyncAfter(deadline: .now() + wait) {
            if let failure {
                then(.failure(failure))
                return
            }
            let lo = Int(min(max(0, offset), Int64(data.count))), hi = min(data.count, lo + count)
            then(.success(data.subdata(in: lo..<hi)))
        }
    }

    func forgetReads() {
        lock.lock(); forgot += 1; lock.unlock()
    }

    func asked(lane: Int) -> [Asked] {
        lock.lock(); defer { lock.unlock() }
        return log.filter { $0.lane == lane }
    }
}

/// One sample as Apple's own reader hands it on.
private struct Flat {
    var shown: CMTime
    var lasts: CMTime
    var bytes: Data
}

/// The app's own film player, played on a Mac with nothing to show it on: Apple's index reader, decoders and clock
/// are the real ones; only the screen and the network are missing.
final class FilmPlayerTests: XCTestCase {
    private func fixture(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "mp4", subdirectory: "Fixtures"), "no fixture \(name)")
    }

    /// What a test needs kept alive while it plays.
    private struct Rig {
        let player: FilmPlayer
        let bytes: TestBytes
        let loader: TestLoader
        let layer: AVSampleBufferDisplayLayer
        let data: Data
    }

    /// A player for the fixture [name], its index read through a loader as the app's is.
    private func rig(_ name: String) throws -> Rig {
        let data = try Data(contentsOf: fixture(name))
        let loader = TestLoader(data: data)
        let asset = AVURLAsset(url: URL(string: "test-stream://film/\(name).mp4")!)
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)
        let bytes = TestBytes(data: data)
        return Rig(player: FilmPlayer(asset: asset, bytes: bytes), bytes: bytes, loader: loader,
                   layer: AVSampleBufferDisplayLayer(), data: data)
    }

    /// Waits up to [seconds] for [condition].
    private func wait(_ seconds: Double, for condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    private func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private func say(_ what: String, _ player: FilmPlayer) {
        let n = player.notes
        print(String(format: "FILM %@: opened in %.3f s, started in %.3f s, %ld waits (%.2f s), %ld moves, reads %@, %lld bytes, slowest %.3f s, asked again %ld, mended %ld",
                     what, n.opened, n.started ?? -1, n.waits, n.waited, n.jumps, "\(n.reads)", n.bytes, n.slowest, n.again, n.mended))
    }

    // MARK: The index

    /// Every sample of [track] as Apple's reader hands it on untouched.
    private func appleSamples(_ asset: AVAsset, _ track: AVAssetTrack) throws -> [Flat] {
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        out.alwaysCopiesSampleData = false
        guard reader.canAdd(out) else { return [] }
        reader.add(out)
        guard reader.startReading() else { return [] }
        var flat: [Flat] = []
        while let sb = out.copyNextSampleBuffer() {
            let n = CMSampleBufferGetNumSamples(sb)
            guard n > 0, let block = CMSampleBufferGetDataBuffer(sb) else { continue }
            let total = CMBlockBufferGetDataLength(block)
            var all = Data(count: total)
            all.withUnsafeMutableBytes { raw in
                if let base = raw.baseAddress { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: total, destination: base) }
            }
            var at = 0
            for i in 0..<n {
                var timing = CMSampleTimingInfo()
                _ = CMSampleBufferGetSampleTimingInfo(sb, at: i, timingInfoOut: &timing)
                let size = CMSampleBufferGetSampleSize(sb, at: i)
                guard at + size <= total else { break }
                flat.append(Flat(shown: timing.presentationTimeStamp, lasts: timing.duration, bytes: all.subdata(in: at..<(at + size))))
                at += size
            }
        }
        return flat
    }

    /// What the whole player stands on: read through a loader (as the app's Drive stream is), the app's reader of
    /// Apple's index gives every picture frame and sound packet exactly as Apple's own reader gives them from the
    /// file on disk: as many, the same bytes, the same times.
    func testEveryPictureAndSoundSampleIsAsApplesOwnReaderGivesIt() async throws {
        for name in ["h264-aac", "hevc-hdr-aac51", "multi"] {
            let url = try fixture(name)
            let data = try Data(contentsOf: url)
            let onDisk = AVURLAsset(url: url)
            var theirs: [CMPersistentTrackID: [Flat]] = [:]
            for track in try await onDisk.load(.tracks) { theirs[track.trackID] = try appleSamples(onDisk, track) }

            let loader = TestLoader(data: data)
            let asset = AVURLAsset(url: URL(string: "test-stream://film/\(name).mp4")!)
            asset.resourceLoader.setDelegate(loader, queue: loader.queue)
            var checked = 0
            for track in try await asset.load(.tracks) where track.mediaType == .video || track.mediaType == .audio {
                let walks = try await track.load(.canProvideSampleCursors)
                XCTAssertTrue(walks, "\(name) track \(track.trackID)")
                let reader = try XCTUnwrap(FilmTrackReader(track: track), "\(name) track \(track.trackID)")
                var mine: [FilmSample] = []
                var runs = 0
                while let run = reader.next() {
                    runs += 1
                    mine += run.samples
                    // A run is one stretch of the file, its samples in it in order.
                    XCTAssertEqual(run.samples.first?.offset, run.offset)
                    XCTAssertLessThanOrEqual(run.length, 4 << 20)
                }
                let apple = theirs[track.trackID] ?? []
                XCTAssertEqual(mine.count, apple.count, "\(name) track \(track.trackID)")
                XCTAssertGreaterThan(mine.count, 90)
                for (m, a) in zip(mine, apple) {
                    XCTAssertEqual(data.subdata(in: Int(m.offset)..<Int(m.offset) + m.size), a.bytes)
                    XCTAssertEqual(CMTimeCompare(m.shown, a.shown), 0)
                    XCTAssertEqual(CMTimeCompare(m.lasts, a.lasts), 0)
                }
                checked += 1
                print("FILM \(name) track \(track.trackID) \(track.mediaType.rawValue): \(mine.count) samples in \(runs) runs, as Apple's reader gives them")
            }
            XCTAssertGreaterThanOrEqual(checked, 2)
            withExtendedLifetime(loader) {}
        }
    }

    /// A film's picture and sound each start a little after zero in the file's own times, by different amounts;
    /// on the film's clock both start at zero, so the two stay together.
    func testPictureAndSoundStartTogetherOnTheFilmsClock() async throws {
        let asset = AVURLAsset(url: try fixture("h264-aac"))
        for track in try await asset.load(.tracks) {
            let shift = FilmPlayer.shift(try await track.load(.segments))
            let reader = try XCTUnwrap(FilmTrackReader(track: track, shift: shift))
            let first = try XCTUnwrap(reader.next()?.samples.first)
            if track.mediaType == .video {
                // The first frame decoded is the first shown.
                XCTAssertEqual(first.shown.seconds, 0, accuracy: 0.0005)
            } else {
                // The sound's first packet is its codec's lead-in: it sits just before zero, and is cut.
                XCTAssertEqual(first.shown.seconds, -1024.0 / 48000, accuracy: 0.0005)
            }
        }
    }

    // MARK: Playing

    func testItPlaysPausesMovesAndPlaysToItsEnd() async throws {
        let r = try rig("h264-aac")
        try await r.player.open()
        let film = r.player.film
        XCTAssertEqual(film.length, 4, accuracy: 0.1)
        XCTAssertEqual(film.picture?.codec, "avc1")
        XCTAssertEqual(film.picture?.width, 320)
        XCTAssertEqual(film.sounds.map(\.codec), ["aac"])
        XCTAssertEqual(film.sound, film.sounds.first?.id)
        XCTAssertEqual(r.player.state, .paused)

        r.player.show(on: r.layer.sampleBufferRenderer)
        r.player.start(at: 0)
        let playing = await wait(6) { r.player.state == .playing }
        XCTAssertTrue(playing, "state \(r.player.state), failure \(String(describing: r.player.failure))")
        await pause(1)
        let after = r.player.time
        XCTAssertGreaterThan(after, 0.4)
        XCTAssertLessThan(after, 2)

        r.player.pause()
        let paused = await wait(2) { r.player.state == .paused }
        XCTAssertTrue(paused)
        let held = r.player.time
        await pause(0.4)
        XCTAssertEqual(r.player.time, held, accuracy: 0.05)

        // Moved while paused: it stands at the new place, still paused.
        r.player.seek(to: 3)
        await pause(0.4)
        XCTAssertEqual(r.player.time, 3, accuracy: 0.05)
        XCTAssertEqual(r.player.state, .paused)

        r.player.play()
        let ended = await wait(8) { r.player.state == .ended }
        XCTAssertTrue(ended, "state \(r.player.state) at \(r.player.time), failure \(String(describing: r.player.failure))")
        XCTAssertNil(r.player.failure)
        XCTAssertEqual(r.player.notes.waits, 0)
        say("plays, pauses, moves, ends", r.player)
        r.player.close()
        withExtendedLifetime(r) {}
    }

    /// The reason for this player: each track is read straight on from its own place, never back and forth between
    /// the two. (Apple's player asks for whichever sample comes next in time, wherever in the file it is.)
    func testEachTrackIsReadStraightOnFromItsOwnPlace() async throws {
        let r = try rig("hevc-hdr-aac51")
        try await r.player.open()
        XCTAssertEqual(r.player.film.picture?.codec, "hvc1")
        XCTAssertEqual(r.player.film.sounds.first?.channels, 6)
        r.player.show(on: r.layer.sampleBufferRenderer)
        r.player.start(at: 0)
        let ended = await wait(12) { r.player.state == .ended }
        XCTAssertTrue(ended, "state \(r.player.state) at \(r.player.time), failure \(String(describing: r.player.failure))")
        for lane in [0, 1] {
            let asked = r.bytes.asked(lane: lane)
            XCTAssertFalse(asked.isEmpty, "lane \(lane)")
            var end: Int64 = 0
            for a in asked {
                XCTAssertGreaterThanOrEqual(a.offset, end, "lane \(lane) went back")
                end = a.offset + Int64(a.count)
            }
        }
        // Few reads: a run is up to two seconds of the film, not a sample.
        XCTAssertLessThan(r.bytes.asked(lane: 0).count + r.bytes.asked(lane: 1).count, 40)
        say("each track straight on", r.player)
        r.player.close()
        withExtendedLifetime(r) {}
    }

    /// A film left off part-way starts there: from the frame decoding can start with before that place, not from
    /// the film's beginning.
    func testItStartsWhereItWasLeftOff() async throws {
        let r = try rig("h264-aac")
        try await r.player.open()
        r.player.show(on: r.layer.sampleBufferRenderer)
        r.player.start(at: 2.5)
        let playing = await wait(6) { r.player.state == .playing }
        XCTAssertTrue(playing, "state \(r.player.state), failure \(String(describing: r.player.failure))")
        XCTAssertGreaterThanOrEqual(r.player.time, 2.45)
        let first = try XCTUnwrap(r.bytes.asked(lane: 0).first)
        // Half the film's bytes are before the frame at two seconds.
        XCTAssertGreaterThan(first.offset, Int64(r.data.count) / 3)
        let ended = await wait(8) { r.player.state == .ended }
        XCTAssertTrue(ended)
        say("starts where it was left off", r.player)
        r.player.close()
        withExtendedLifetime(r) {}
    }

    /// The film arriving slower than it plays: the clock stops (once, not a stutter), and goes on when there's
    /// enough again.
    func testItWaitsWhenTheFilmHasntArrivedAndGoesOn() async throws {
        let r = try rig("h264-aac")
        // Only a second read ahead, and the picture's second run held back a second and a half.
        r.player.keep = 1
        r.player.enough = 0.5
        r.player.enoughAfterWaiting = 0.5
        r.bytes.holdLane = 0
        r.bytes.holdAt = 2
        r.bytes.holdFor = 1.5
        try await r.player.open()
        r.player.show(on: r.layer.sampleBufferRenderer)
        r.player.start(at: 0)
        let playing = await wait(6) { r.player.state == .playing }
        XCTAssertTrue(playing)
        let waited = await wait(6) { r.player.state == .waiting }
        XCTAssertTrue(waited, "it never waited: state \(r.player.state) at \(r.player.time)")
        // The clock stands still while it waits, just short of where the picture ran out.
        let stoodAt = r.player.time
        await pause(0.3)
        if r.player.state == .waiting { XCTAssertEqual(r.player.time, stoodAt, accuracy: 0.05) }
        XCTAssertLessThan(stoodAt, 2.05)
        let ended = await wait(10) { r.player.state == .ended }
        XCTAssertTrue(ended, "state \(r.player.state) at \(r.player.time), failure \(String(describing: r.player.failure))")
        XCTAssertEqual(r.player.notes.waits, 1)
        XCTAssertGreaterThan(r.player.notes.waited, 0.2)
        say("waits and goes on", r.player)
        r.player.close()
        withExtendedLifetime(r) {}
    }

    /// The connection failing is asked again; a film that can't be had says so.
    func testAFailedReadIsAskedAgainAndARefusalStopsIt() async throws {
        let r = try rig("h264-aac")
        r.bytes.failures = [URLError(.timedOut)]
        try await r.player.open()
        r.player.show(on: r.layer.sampleBufferRenderer)
        r.player.start(at: 0)
        let playing = await wait(8) { r.player.state == .playing }
        XCTAssertTrue(playing, "state \(r.player.state), failure \(String(describing: r.player.failure))")
        XCTAssertEqual(r.player.notes.again, 1)
        r.player.close()

        struct Refused: Error {}
        let other = try rig("h264-aac")
        other.bytes.failures = [Refused()]
        try await other.player.open()
        other.player.show(on: other.layer.sampleBufferRenderer)
        other.player.start(at: 0)
        let failed = await wait(4) { other.player.state == .failed }
        XCTAssertTrue(failed)
        XCTAssertTrue(other.player.failure is Refused)
        other.player.close()
        withExtendedLifetime(r) {}
        withExtendedLifetime(other) {}
    }

    func testSoundTracksSubtitlesAndChapters() async throws {
        let r = try rig("multi")
        try await r.player.open()
        let film = r.player.film
        XCTAssertEqual(film.sounds.map(\.codec), ["aac", "ac-3", "ec-3"])
        XCTAssertEqual(film.sounds.map(\.language), ["eng", "spa", "fra"])
        XCTAssertEqual(film.sounds.map(\.channels), [2, 6, 6])
        print("FILM multi sounds: \(film.sounds)")
        // The one the file puts first.
        XCTAssertEqual(film.sound, film.sounds.first?.id)
        XCTAssertEqual(film.words.map(\.language), ["eng"])
        XCTAssertNil(film.showing)

        r.player.show(on: r.layer.sampleBufferRenderer)
        r.player.choose(words: film.words.first?.id)
        r.player.start(at: 0)
        let playing = await wait(6) { r.player.state == .playing }
        XCTAssertTrue(playing, "state \(r.player.state), failure \(String(describing: r.player.failure))")
        let said = await wait(3) { r.player.line == "First line" }
        XCTAssertTrue(said, "line \(String(describing: r.player.line)) at \(r.player.time)")
        XCTAssertEqual(r.player.film.showing, film.words.first?.id)

        // Another sound track, mid-film: it goes on from where it is.
        let spanish = try XCTUnwrap(film.sounds.first { $0.language == "spa" })
        if spanish.playable {
            let before = r.player.time
            r.player.choose(sound: spanish.id)
            let chosen = await wait(2) { r.player.film.sound == spanish.id }
            XCTAssertTrue(chosen)
            let onAgain = await wait(6) { r.player.state == .playing && r.player.time > before + 0.3 }
            XCTAssertTrue(onAgain, "state \(r.player.state) at \(r.player.time), failure \(String(describing: r.player.failure))")
        }

        // Subtitles off: the line goes.
        r.player.choose(words: nil)
        let gone = await wait(2) { r.player.line == nil && r.player.film.showing == nil }
        XCTAssertTrue(gone)

        let chapters = await wait(4) { r.player.film.chapters.count == 2 }
        XCTAssertTrue(chapters, "chapters \(r.player.film.chapters)")
        XCTAssertEqual(r.player.film.chapters.map(\.title), ["Opening", "The Rest"])
        XCTAssertEqual(r.player.film.chapters.map(\.start), [0, 2])
        XCTAssertNil(r.player.failure)
        say("sound tracks, subtitles, chapters", r.player)
        r.player.close()
        withExtendedLifetime(r) {}
    }
}
#endif
