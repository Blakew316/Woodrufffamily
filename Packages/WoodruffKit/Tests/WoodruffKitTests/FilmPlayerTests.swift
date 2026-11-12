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

        // (They're read a moment after the film starts, so they never hold up its start.)
        let chapters = await wait(8) { r.player.film.chapters.count == 2 }
        XCTAssertTrue(chapters, "chapters \(r.player.film.chapters)")
        XCTAssertEqual(r.player.film.chapters.map(\.title), ["Opening", "The Rest"])
        XCTAssertEqual(r.player.film.chapters.map(\.start), [0, 2])
        XCTAssertNil(r.player.failure)
        say("sound tracks, subtitles, chapters", r.player)
        r.player.close()
        withExtendedLifetime(r) {}
    }

    // MARK: The index kept on the device

    /// A film's index kept in a file of its own: a file as long as the film that holds everything but the samples
    /// walks exactly as the film does, and the film plays from it with its bytes coming from elsewhere.
    func testAFilmPlaysFromItsKeptIndex() async throws {
        let name = "hevc-hdr-aac51"
        let data = try Data(contentsOf: fixture(name))
        let whole = AVURLAsset(url: try fixture(name))
        let marks = try await FilmIndexFile.marks(of: whole)
        XCTAssertEqual(marks.count, 2)

        // Every byte that isn't a sample: the index, and the little that goes with it.
        var sample = [Bool](repeating: false, count: data.count)
        for track in try await whole.load(.tracks) {
            let reader = try XCTUnwrap(FilmTrackReader(track: track))
            while let run = reader.next() {
                for s in run.samples where s.size > 0 {
                    for i in Int(s.offset)..<(Int(s.offset) + s.size) { sample[i] = true }
                }
            }
        }
        var parts: [(offset: Int64, data: Data)] = []
        var i = 0
        while i < data.count {
            if sample[i] {
                i += 1
                continue
            }
            var j = i
            while j < data.count, !sample[j] { j += 1 }
            parts.append((offset: Int64(i), data: data.subdata(in: i..<j)))
            i = j
        }
        let kept = parts.reduce(0) { $0 + $1.data.count }
        XCTAssertLessThan(kept, data.count / 4)
        print("FILM kept index: \(kept) of \(data.count) bytes in \(parts.count) parts")

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("film-index-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("\(name).mp4")
        try FilmIndexFile.write(total: Int64(data.count), parts: parts, to: url)
        XCTAssertEqual(FilmIndexFile.length(url), Int64(data.count))
        let index = try await FilmIndexFile.open(url, matching: marks)

        // A file that's missing a part of the index is refused, not played from.
        let broken = folder.appendingPathComponent("broken.mp4")
        try FilmIndexFile.write(total: Int64(data.count), parts: Array(parts.dropLast()), to: broken)
        do {
            _ = try await FilmIndexFile.open(broken, matching: marks)
            XCTFail("opened without its index")
        } catch {}
        XCTAssertThrowsError(try FilmIndexFile.write(total: 0, parts: parts, to: broken))

        // Played from it: the index from the file, the film's bytes from elsewhere.
        let bytes = TestBytes(data: data)
        let player = FilmPlayer(asset: index, bytes: bytes)
        let layer = AVSampleBufferDisplayLayer()
        try await player.open()
        XCTAssertEqual(player.film.picture?.codec, "hvc1")
        player.mute(true)
        player.show(on: layer.sampleBufferRenderer)
        player.start(at: 0)
        let ended = await wait(12) { player.state == .ended }
        XCTAssertTrue(ended, "state \(player.state) at \(player.time), failure \(String(describing: player.failure))")
        XCTAssertNil(player.failure)
        XCTAssertFalse(bytes.asked(lane: 0).isEmpty)
        say("from its kept index", player)
        player.close()
        withExtendedLifetime(layer) {}
    }

    func testKeptIndexesUsedLongestAgoGoFirst() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("film-index-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        var urls: [URL] = []
        for n in 0..<4 {
            let url = folder.appendingPathComponent("film\(n).mp4")
            try FilmIndexFile.write(total: 4096, parts: [(offset: 0, data: Data(repeating: UInt8(n), count: 1024))], to: url)
            // Used a day apart: film0 longest ago.
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(Double(n - 10) * 86_400)], ofItemAtPath: url.path)
            urls.append(url)
        }
        FilmIndexFile.used(urls[1])
        FilmIndexFile.prune(folder, count: 2)
        let left = urls.filter { FileManager.default.fileExists(atPath: $0.path) }.map { $0.lastPathComponent }
        XCTAssertEqual(left.sorted(), ["film1.mp4", "film3.mp4"])
    }
}
#endif

// MARK: Sound Apple has no decoder for

/// A decoder for the tests: for every packet it's given it hands back [frames] frames of a quiet tone, or nothing
/// at all, and keeps the start of the first packets it saw.
private final class FakeSound: FilmSoundDecoder {
    private let frames: Int
    private let channels: Int
    private let gives: Bool
    /// After this many packets the sound has [growTo] channels (a track that starts with its plainer core).
    private let growAfter: Int?
    private let growTo: Int
    private let rate: Int
    /// The sound it gives belongs this many frames before the packet (a decoder that hands sound over late).
    private let early: Int
    private let samples: UnsafeMutableBufferPointer<Float>
    private let lock = NSLock()
    private var packets = 0
    private var starts: [Data] = []
    private var flushes = 0

    init(frames: Int, channels: Int = 6, rate: Int = 48000, early: Int = 0, gives: Bool = true, growAfter: Int? = nil, growTo: Int = 6) {
        self.frames = frames
        self.channels = channels
        self.rate = rate
        self.early = early
        self.gives = gives
        self.growAfter = growAfter
        self.growTo = growTo
        samples = UnsafeMutableBufferPointer<Float>.allocate(capacity: frames * 12)
        for i in 0..<(frames * 12) { samples[i] = Float(i % 17) * 0.0001 }
    }

    deinit {
        samples.deallocate()
    }

    func decode(_ packet: UnsafeRawBufferPointer, at seconds: Double) -> FilmDecodedSound? {
        lock.lock()
        packets += 1
        let nth = packets
        if starts.count < 4 { starts.append(Data(packet.prefix(8))) }
        lock.unlock()
        guard gives else { return nil }
        let now = growAfter.map { nth > $0 ? growTo : channels } ?? channels
        return FilmDecodedSound(samples: UnsafeBufferPointer(rebasing: samples[0..<(frames * now)]), frames: frames, channels: now, rate: rate,
                                starts: early > 0 ? seconds - Double(early) / Double(rate) : nil)
    }

    func flush() {
        lock.lock(); flushes += 1; lock.unlock()
    }

    var seen: (packets: Int, starts: [Data], flushes: Int) {
        lock.lock(); defer { lock.unlock() }
        return (packets, starts, flushes)
    }
}

/// The decoders a test handed the player.
private final class FakeSounds {
    private let lock = NSLock()
    private var all: [(kind: String, sound: FakeSound)] = []

    func make(_ kind: String, _ sound: FakeSound) -> FakeSound {
        lock.lock(); all.append((kind, sound)); lock.unlock()
        return sound
    }

    var kinds: [String] { lock.lock(); defer { lock.unlock() }; return all.map(\.kind) }
    var packets: Int { lock.lock(); defer { lock.unlock() }; return all.reduce(0) { $0 + $1.sound.seen.packets } }
    var starts: [Data] { lock.lock(); defer { lock.unlock() }; return all.flatMap { $0.sound.seen.starts } }
    var flushes: Int { lock.lock(); defer { lock.unlock() }; return all.reduce(0) { $0 + $1.sound.seen.flushes } }
}

extension FilmPlayerTests {
    private func fourLetters(_ letters: String) -> UInt32 {
        letters.utf8.reduce(0) { $0 << 8 | UInt32($1) }
    }

    /// A sound format a file would name with [letters].
    private func soundFormat(_ letters: String) -> CMAudioFormatDescription? {
        var basic = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: fourLetters(letters), mFormatFlags: 0, mBytesPerPacket: 0,
                                                mFramesPerPacket: 0, mBytesPerFrame: 0, mChannelsPerFrame: 6, mBitsPerChannel: 0, mReserved: 0)
        var made: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &basic, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                                    magicCookie: nil, extensions: nil, formatDescriptionOut: &made)
        return status == noErr ? made : nil
    }

    /// Which sound the app's decoders are for: told by a track's four letters, or by the number in the settings of
    /// an "mp4a" track (as FFmpeg and HandBrake write DTS).
    func testTheKindsOfSoundAnAppsDecoderIsFor() throws {
        for (letters, kind) in [("dtsc", "dts"), ("dtsh", "dts"), ("dtsl", "dts"), ("dtse", "dts"), ("mlpa", "truehd")] {
            let format = try XCTUnwrap(soundFormat(letters), letters)
            XCTAssertEqual(FilmSoundDecoders.kind(of: format), kind, letters)
        }
        for letters in ["ac-3", "ec-3", "alac", "fLaC"] {
            let format = try XCTUnwrap(soundFormat(letters), letters)
            XCTAssertNil(FilmSoundDecoders.kind(of: format), letters)
        }
        // The settings FFmpeg writes for DTS, and for AAC (the fixture's own).
        let dts: [UInt8] = [0x03, 0x80, 0x80, 0x80, 0x1b, 0x00, 0x02, 0x00, 0x04, 0x80, 0x80, 0x80, 0x0d, 0xa9, 0x15, 0x00, 0x00, 0x00,
                            0x00, 0x0b, 0xc0, 0x00, 0x00, 0x0b, 0xc0, 0x00, 0x06, 0x80, 0x80, 0x80, 0x01, 0x02]
        let aac: [UInt8] = [0x03, 0x80, 0x80, 0x80, 0x25, 0x00, 0x04, 0x00, 0x04, 0x80, 0x80, 0x80, 0x17, 0x40, 0x15, 0x00, 0x00, 0x00,
                            0x00, 0x00, 0xa6, 0x93, 0x00, 0x00, 0xa6, 0x93, 0x05, 0x80, 0x80, 0x80, 0x05, 0x11, 0x90, 0x56, 0xe5, 0x00,
                            0x06, 0x80, 0x80, 0x80, 0x01, 0x02]
        XCTAssertEqual(dts.withUnsafeBytes { FilmSoundDecoders.objectType(inSettings: $0) }, 0xA9)
        XCTAssertEqual(aac.withUnsafeBytes { FilmSoundDecoders.objectType(inSettings: $0) }, 0x40)
        // With four bytes of version before them, with lengths of one byte, and the decoder's settings alone.
        XCTAssertEqual(([0, 0, 0, 0] + dts).withUnsafeBytes { FilmSoundDecoders.objectType(inSettings: $0) }, 0xA9)
        let short: [UInt8] = [0x03, 0x19, 0x00, 0x01, 0x00, 0x04, 0x11, 0xab, 0x15, 0x00, 0x00, 0x00]
        XCTAssertEqual(short.withUnsafeBytes { FilmSoundDecoders.objectType(inSettings: $0) }, 0xAB)
        let alone: [UInt8] = [0x04, 0x11, 0xac, 0x15]
        XCTAssertEqual(alone.withUnsafeBytes { FilmSoundDecoders.objectType(inSettings: $0) }, 0xAC)
        // A stream that says it depends on another, has an address and a clock of its own: the fields before the decoder's.
        let long: [UInt8] = [0x03, 0x20, 0x00, 0x01, 0xe0, 0x00, 0x07, 0x02, 0x41, 0x42, 0x00, 0x09, 0x04, 0x11, 0xa9, 0x15]
        XCTAssertEqual(long.withUnsafeBytes { FilmSoundDecoders.objectType(inSettings: $0) }, 0xA9)
        for nothing in [[UInt8](), [0x03], [0x03, 0x80], [0x05, 0x02, 0x11, 0x90], [0x03, 0x04, 0x00, 0x01, 0x00, 0x05]] {
            XCTAssertNil(nothing.withUnsafeBytes { FilmSoundDecoders.objectType(inSettings: $0) }, "\(nothing)")
        }
    }

    /// What a decoder gives for a run's packets becomes buffers of a tenth of a second or more, nothing from before
    /// where the film is wanted from, a new buffer at a real gap in the file's times, and only the larger shape when
    /// the sound's shape grows.
    func testDecodedSoundIsGatheredTrimmedAndSplitAtRealGaps() throws {
        func packet(_ i: Int, at seconds: Double) -> FilmSample {
            let time = CMTime(seconds: seconds, preferredTimescale: 48000)
            return FilmSample(offset: 1000 + Int64(i) * 4, size: 4, shown: time, decoded: time, lasts: CMTime(value: 480, timescale: 48000),
                              sync: true, attachments: nil, format: nil)
        }
        // A hundred packets of a hundredth of a second each, two channels.
        let decoding = FilmSoundDecoding(kind: "dts", decoder: FakeSound(frames: 480, channels: 2))
        let run = FilmRun(offset: 1000, length: 400, samples: (0..<100).map { packet($0, at: Double($0) * 0.01) })
        let buffers = try decoding.buffers(of: run, bytes: Data(count: 400), from: CMTime(seconds: 0.255, preferredTimescale: 48000))
        // Packets 0 to 24 end before 0.255 s; half of packet 25 is before it.
        XCTAssertEqual(buffers.reduce(0) { $0 + CMSampleBufferGetNumSamples($1) }, 240 + 74 * 480)
        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(try XCTUnwrap(buffers.first)).seconds, 0.255, accuracy: 0.0001)
        XCTAssertGreaterThan(buffers.count, 1)
        var end = CMTime.invalid
        for (i, buffer) in buffers.enumerated() {
            let count = CMSampleBufferGetNumSamples(buffer)
            if i < buffers.count - 1 { XCTAssertGreaterThanOrEqual(count, 4800, "buffer \(i)") }
            let starts = CMSampleBufferGetPresentationTimeStamp(buffer)
            if end.isValid { XCTAssertEqual(starts.seconds, end.seconds, accuracy: 0.0001, "buffer \(i) starts where the one before ended") }
            end = CMTimeAdd(starts, CMTime(value: CMTimeValue(count), timescale: 48000))
            XCTAssertEqual(CMSampleBufferGetDuration(buffer).seconds, Double(count) / 48000, accuracy: 0.0001)
            let basic = try XCTUnwrap(CMSampleBufferGetFormatDescription(buffer).flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee })
            XCTAssertEqual(basic.mFormatID, kAudioFormatLinearPCM)
            XCTAssertEqual(basic.mChannelsPerFrame, 2)
            XCTAssertEqual(basic.mSampleRate, 48000)
            XCTAssertEqual(basic.mBytesPerFrame, 8)
            XCTAssertEqual(CMSampleBufferGetTotalSampleSize(buffer), count * 8)
        }
        XCTAssertEqual(end.seconds, 1.0, accuracy: 0.0001)
        XCTAssertEqual(decoding.packets, 100)
        XCTAssertEqual(decoding.frames, 240 + 74 * 480)

        // Half a second missing in the file's times: the sound after it starts at the file's time, in a buffer of its own.
        let gapped = FilmRun(offset: 1000, length: 400, samples: (0..<15).map { packet($0, at: 2 + Double($0) * 0.01 + ($0 >= 7 ? 0.5 : 0)) })
        let after = try decoding.buffers(of: gapped, bytes: Data(count: 400), from: .invalid)
        XCTAssertEqual(after.map { CMSampleBufferGetNumSamples($0) }, [7 * 480, 8 * 480])
        XCTAssertEqual(after.map { CMSampleBufferGetPresentationTimeStamp($0).seconds }.last ?? 0, 2.57, accuracy: 0.0001)

        // Six channels after three packets of two (a track's plainer core first): the run gives only the six.
        let growing = FilmSoundDecoding(kind: "dts", decoder: FakeSound(frames: 480, channels: 2, growAfter: 3, growTo: 6))
        let grown = try growing.buffers(of: run, bytes: Data(count: 400), from: .invalid)
        XCTAssertEqual(grown.reduce(0) { $0 + CMSampleBufferGetNumSamples($1) }, 97 * 480)
        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(try XCTUnwrap(grown.first)).seconds, 0.03, accuracy: 0.0001)
        for buffer in grown {
            let basic = try XCTUnwrap(CMSampleBufferGetFormatDescription(buffer).flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee })
            XCTAssertEqual(basic.mChannelsPerFrame, 6)
        }
        XCTAssertEqual(growing.channels, 6)

        // A decoder that hands its sound over late (by half a packet here): each buffer is stamped that much earlier,
        // and what then falls before where the film is wanted from is left out.
        let late = FilmSoundDecoding(kind: "truehd", decoder: FakeSound(frames: 480, channels: 12, early: 240))
        let held = try late.buffers(of: run, bytes: Data(count: 400), from: .invalid)
        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(try XCTUnwrap(held.first)).seconds, -0.005, accuracy: 0.0001)
        XCTAssertEqual(held.reduce(0) { $0 + CMSampleBufferGetNumSamples($1) }, 100 * 480)
        let wanted = FilmSoundDecoding(kind: "truehd", decoder: FakeSound(frames: 480, channels: 12, early: 240))
        let kept = try wanted.buffers(of: run, bytes: Data(count: 400), from: .zero)
        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(try XCTUnwrap(kept.first)).seconds, 0, accuracy: 0.0001)
        XCTAssertEqual(kept.reduce(0) { $0 + CMSampleBufferGetNumSamples($1) }, 100 * 480 - 240)
        let twelve = try XCTUnwrap(kept.first.flatMap { CMSampleBufferGetFormatDescription($0) }.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee })
        XCTAssertEqual(twelve.mChannelsPerFrame, 12)

        // Packets nothing comes of: counted, and the seconds of the film they were.
        let deaf = FilmSoundDecoding(kind: "truehd", decoder: FakeSound(frames: 480, gives: false))
        XCTAssertTrue(try deaf.buffers(of: run, bytes: Data(count: 400), from: .invalid).isEmpty)
        XCTAssertEqual(deaf.lost, 100)
        XCTAssertEqual(deaf.frames, 0)
        XCTAssertEqual(deaf.silent, 1.0, accuracy: 0.001)
    }

    /// The formats plain samples are handed to the renderer in: one for each shape a decoder gives.
    func testTheFormatsOfDecodedSound() throws {
        for (channels, tag) in [(1, kAudioChannelLayoutTag_Mono), (2, kAudioChannelLayoutTag_Stereo), (6, kAudioChannelLayoutTag_MPEG_5_1_A),
                                (8, kAudioChannelLayoutTag_MPEG_7_1_C), (12, kAudioChannelLayoutTag_Atmos_7_1_4)] {
            let format = try XCTUnwrap(FilmDecodedBuffers.format(channels: channels, rate: 96000), "\(channels) channels")
            let basic = try XCTUnwrap(CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee)
            XCTAssertEqual(basic.mSampleRate, 96000)
            XCTAssertEqual(Int(basic.mChannelsPerFrame), channels)
            XCTAssertEqual(basic.mFormatFlags & kAudioFormatFlagIsFloat, kAudioFormatFlagIsFloat)
            var size = 0
            let layout = try XCTUnwrap(CMAudioFormatDescriptionGetChannelLayout(format, sizeOut: &size))
            XCTAssertEqual(layout.pointee.mChannelLayoutTag, tag)
        }
        XCTAssertNil(FilmDecodedBuffers.format(channels: 5, rate: 48000))
        XCTAssertNil(FilmDecodedBuffers.format(channels: 6, rate: 0))
    }

    /// A film whose sound Apple has no decoder for (the fixture's Dolby TrueHD track) plays it through the decoder
    /// the app gives: the track counts as playable, the decoder is handed the file's packets whole and in order,
    /// and what it gives goes to the sound renderer, which plays it without being started afresh.
    func testSoundAppleHasNoDecoderForIsDecodedByTheApps() async throws {
        let fakes = FakeSounds()
        FilmSoundDecoders.make = { kind in fakes.make(kind, FakeSound(frames: 40)) }
        defer { FilmSoundDecoders.make = nil }
        let r = try rig("dts-truehd-aac")
        try await r.player.open()
        let film = r.player.film
        print("FILM dts-truehd-aac sounds: \(film.sounds)")
        let truehd = try XCTUnwrap(film.sounds.first { $0.codec == "mlpa" }, "\(film.sounds)")
        let aac = try XCTUnwrap(film.sounds.first { $0.codec == "aac" }, "\(film.sounds)")
        XCTAssertEqual(truehd.channels, 6)
        XCTAssertTrue(truehd.playable)
        XCTAssertTrue(truehd.decodedHere)
        XCTAssertTrue(aac.playable)
        XCTAssertFalse(aac.decodedHere)
        XCTAssertEqual(film.sound, truehd.id)

        r.player.show(on: r.layer.sampleBufferRenderer)
        r.player.start(at: 0)
        let playing = await wait(6) { r.player.state == .playing }
        XCTAssertTrue(playing, "state \(r.player.state), failure \(String(describing: r.player.failure))")
        await pause(1)
        XCTAssertGreaterThan(r.player.time, 0.4)
        let n = r.player.notes
        print("FILM decoded: \(n.decodedKind ?? "-") \(n.decodedPackets) packets, \(n.decodedLost) lost, \(n.decodedFrames) frames, \(n.decodedChannels) channels at \(n.decodedRate); joined \(n.joined) by \(n.joinedBy); mended \(n.mended) (sound \(n.mendedSound)) \(n.mendWhy ?? "")")
        XCTAssertEqual(n.decodedKind, "truehd")
        XCTAssertGreaterThanOrEqual(n.decodedPackets, 1200)
        XCTAssertEqual(n.decodedLost, 0)
        XCTAssertEqual(n.decodedFrames, n.decodedPackets * 40)
        XCTAssertEqual(n.decodedChannels, 6)
        XCTAssertEqual(n.decodedRate, 48000)
        XCTAssertFalse(n.decodingGaveUp)
        XCTAssertEqual(n.mended, 0)
        XCTAssertNil(r.player.failure)
        XCTAssertEqual(Set(fakes.kinds), ["truehd"])
        XCTAssertGreaterThanOrEqual(fakes.packets, n.decodedPackets)
        // The first packet is the file's first: a TrueHD access unit that starts the sound afresh (its sync word).
        let first = try XCTUnwrap(fakes.starts.first { $0.count == 8 })
        XCTAssertEqual(Array(first[4..<8]), [0xF8, 0x72, 0x6F, 0xBA])
        say("sound decoded by the app", r.player)

        // Moved back: the decoder is told to forget what it holds, and the sound goes on from there.
        let flushed = fakes.flushes
        r.player.seek(to: 0.5)
        let forgot = await wait(6) { fakes.flushes > flushed }
        XCTAssertTrue(forgot, "the decoder wasn't told the film was moved")
        let again = await wait(6) { r.player.state == .playing }
        XCTAssertTrue(again, "state \(r.player.state) at \(r.player.time), failure \(String(describing: r.player.failure))")
        await pause(0.3)
        XCTAssertNil(r.player.failure)
        XCTAssertEqual(r.player.notes.mended, 0)

        // The AAC track mid-film, and back: each goes on from where the film is.
        r.player.choose(sound: aac.id)
        let other = await wait(2) { r.player.film.sound == aac.id }
        XCTAssertTrue(other)
        await pause(0.4)
        r.player.choose(sound: truehd.id)
        let back = await wait(2) { r.player.film.sound == truehd.id }
        XCTAssertTrue(back)
        await pause(0.4)
        XCTAssertNil(r.player.failure)
        r.player.close()
    }

    /// With no decoder given (the iPhone and Mac apps), such sound isn't played, and the film's first sound that can
    /// be is the one that plays.
    func testWithNoDecoderGivenSuchSoundIsntPlayed() async throws {
        FilmSoundDecoders.make = nil
        let r = try rig("dts-truehd-aac")
        try await r.player.open()
        let film = r.player.film
        let truehd = try XCTUnwrap(film.sounds.first { $0.codec == "mlpa" }, "\(film.sounds)")
        let aac = try XCTUnwrap(film.sounds.first { $0.codec == "aac" }, "\(film.sounds)")
        XCTAssertFalse(truehd.playable)
        XCTAssertFalse(truehd.decodedHere)
        XCTAssertEqual(film.sound, aac.id)
        r.player.close()
    }

    /// A track the app's decoder can make nothing of gives way to the film's first sound that plays, as before
    /// there was a decoder, and is marked as sound that can't be played.
    func testSoundTheAppsDecoderMakesNothingOfGivesWay() async throws {
        FilmSoundDecoders.make = { _ in FakeSound(frames: 40, gives: false) }
        defer { FilmSoundDecoders.make = nil }
        let r = try rig("dts-truehd-aac")
        try await r.player.open()
        let film = r.player.film
        let truehd = try XCTUnwrap(film.sounds.first { $0.codec == "mlpa" }, "\(film.sounds)")
        let aac = try XCTUnwrap(film.sounds.first { $0.codec == "aac" }, "\(film.sounds)")
        XCTAssertEqual(film.sound, truehd.id)
        r.player.show(on: r.layer.sampleBufferRenderer)
        r.player.start(at: 0)
        let gaveWay = await wait(6) { r.player.film.sound == aac.id }
        XCTAssertTrue(gaveWay, "sound \(String(describing: r.player.film.sound)), notes \(r.player.notes)")
        XCTAssertTrue(r.player.notes.decodingGaveUp)
        XCTAssertEqual(r.player.film.sounds.first { $0.id == truehd.id }?.playable, false)
        let playing = await wait(6) { r.player.state == .playing }
        XCTAssertTrue(playing, "state \(r.player.state), failure \(String(describing: r.player.failure))")
        await pause(0.5)
        XCTAssertNil(r.player.failure)
        XCTAssertGreaterThan(r.player.time, 0.2)
        r.player.close()
    }

    /// Eight channels at twice the rate (as a TrueHD or DTS-HD track with rear surrounds gives) go to the sound
    /// renderer too, and play.
    func testEightChannelsAtTwiceTheRatePlay() async throws {
        FilmSoundDecoders.make = { _ in FakeSound(frames: 80, channels: 8, rate: 96000) }
        defer { FilmSoundDecoders.make = nil }
        let r = try rig("dts-truehd-aac")
        try await r.player.open()
        r.player.show(on: r.layer.sampleBufferRenderer)
        r.player.start(at: 0)
        let playing = await wait(6) { r.player.state == .playing }
        XCTAssertTrue(playing, "state \(r.player.state), failure \(String(describing: r.player.failure))")
        await pause(1)
        let n = r.player.notes
        print("FILM eight channels: \(n.decodedPackets) packets, \(n.decodedFrames) frames, \(n.decodedChannels) channels at \(n.decodedRate); mended \(n.mended) \(n.mendWhy ?? "")")
        XCTAssertEqual(n.decodedChannels, 8)
        XCTAssertEqual(n.decodedRate, 96000)
        XCTAssertEqual(n.mended, 0)
        XCTAssertGreaterThan(r.player.time, 0.4)
        XCTAssertNil(r.player.failure)
        r.player.close()
    }

    /// Twelve channels (7.1 with four overhead, as Atmos and DTS:X give with their heights) go to the sound renderer
    /// too, and play.
    func testTwelveChannelsWithHeightsPlay() async throws {
        FilmSoundDecoders.make = { _ in FakeSound(frames: 40, channels: 12) }
        defer { FilmSoundDecoders.make = nil }
        let r = try rig("dts-truehd-aac")
        try await r.player.open()
        r.player.show(on: r.layer.sampleBufferRenderer)
        r.player.start(at: 0)
        let playing = await wait(6) { r.player.state == .playing }
        XCTAssertTrue(playing, "state \(r.player.state), failure \(String(describing: r.player.failure))")
        await pause(1)
        let n = r.player.notes
        print("FILM twelve channels: \(n.decodedPackets) packets, \(n.decodedFrames) frames, \(n.decodedChannels) channels at \(n.decodedRate); mended \(n.mended) \(n.mendWhy ?? "")")
        XCTAssertEqual(n.decodedChannels, 12)
        XCTAssertEqual(n.mended, 0)
        XCTAssertGreaterThan(r.player.time, 0.4)
        XCTAssertNil(r.player.failure)
        r.player.close()
    }

    /// Where the fixture's index box is in the file, and what it holds.
    private func indexOf(_ data: Data) throws -> (start: Int, bytes: [UInt8]) {
        // The fixture starts with a box of 36 bytes ("ftyp"); its index box ("moov") follows.
        XCTAssertEqual(String(decoding: data[40..<44], as: UTF8.self), "moov")
        let size = Int(data[36]) << 24 | Int(data[37]) << 16 | Int(data[38]) << 8 | Int(data[39])
        return (44, [UInt8](data[44..<(36 + size)]))
    }

    /// DTS as FFmpeg and HandBrake write it ("mp4a" sound whose settings give its kind as a number), which Apple's
    /// reader leaves out of the film's tracks, is found in a film's index: the fixture's second track, and no other.
    func testHiddenDTSIsFoundInAFilmsIndex() throws {
        let data = try Data(contentsOf: fixture("dts-truehd-aac"))
        let index = try indexOf(data)
        let start = Int64(index.start)
        XCTAssertEqual(FilmHiddenSound.find(inIndex: index.bytes, at: start), [FilmHiddenSound.Found(track: 2, at: 2145, letters: "dtsc")])
        // The number in the track's settings (2,202 bytes into the file) says which DTS it is.
        for (number, letters) in [(UInt8(0xAA), "dtsh"), (0xAB, "dtsl"), (0xAC, "dtse")] {
            var other = index.bytes
            other[2202 - index.start] = number
            XCTAssertEqual(FilmHiddenSound.find(inIndex: other, at: start).map(\.letters), [letters])
        }
        // AAC's own number, or any other, leaves the track be.
        for number in [UInt8(0x40), 0xA5, 0xAD, 0x00] {
            var other = index.bytes
            other[2202 - index.start] = number
            XCTAssertTrue(FilmHiddenSound.find(inIndex: other, at: start).isEmpty, "\(number)")
        }
        // A track whose tables aren't all there (a hole in the kept index where they are) stays hidden.
        var holed = index.bytes
        for i in 2617..<3613 { holed[i - index.start] = 0 }
        XCTAssertTrue(FilmHiddenSound.find(inIndex: holed, at: start).isEmpty)
        // An index cut short, or none at all.
        XCTAssertTrue(FilmHiddenSound.find(inIndex: Array(index.bytes.prefix(1000)), at: start).isEmpty)
        XCTAssertTrue(FilmHiddenSound.find(inIndex: [], at: 0).isEmpty)
    }

    /// In a kept index the hidden DTS track is named with the letters a file gives DTS outright: four bytes, once,
    /// wherever in the file the index is. Apple's reader then lists the track, and the app's decoder plays it: it's
    /// the sound the file puts first.
    func testAFilmsHiddenDTSIsNamedAndPlaysThroughTheAppsDecoder() async throws {
        let fakes = FakeSounds()
        FilmSoundDecoders.make = { kind in fakes.make(kind, FakeSound(frames: 512)) }
        defer { FilmSoundDecoders.make = nil }
        let data = try Data(contentsOf: fixture("dts-truehd-aac"))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hidden-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // The film's index as the app keeps it: a file as long as the film (here the film itself).
        let url = folder.appendingPathComponent("kept.mp4")
        try data.write(to: url)
        let before = try await FilmIndexFile.marks(of: AVURLAsset(url: url))
        XCTAssertEqual(before.map(\.track), [1, 3, 4], "Apple's reader leaves the DTS track out")
        XCTAssertEqual(FilmHiddenSound.name(inIndexAt: url), [2])
        XCTAssertEqual(FilmHiddenSound.name(inIndexAt: url), [], "named already")
        var kept = try Data(contentsOf: url)
        XCTAssertEqual(String(decoding: kept[2145..<2149], as: UTF8.self), "dtsc")
        kept.replaceSubrange(2145..<2149, with: Array("mp4a".utf8))
        XCTAssertEqual(kept, data, "nothing else of the file changed")

        // The index after the film's pictures and sound, as many files have it: found there too.
        let moved = folder.appendingPathComponent("moved.mp4")
        try (data[0..<36] + data[19447...] + data[36..<19447]).write(to: moved)
        XCTAssertEqual(FilmHiddenSound.name(inIndexAt: moved), [2])
        let at = 2145 + (data.count - 19447)
        XCTAssertEqual(String(decoding: try Data(contentsOf: moved)[at..<(at + 4)], as: UTF8.self), "dtsc")
        // A file with no index in it (nothing but a hole), and no file at all.
        let empty = folder.appendingPathComponent("empty.mp4")
        try Data(count: 4096).write(to: empty)
        XCTAssertEqual(FilmHiddenSound.name(inIndexAt: empty), [])
        XCTAssertEqual(FilmHiddenSound.name(inIndexAt: folder.appendingPathComponent("none.mp4")), [])

        // The kept index walks as the film does, the named track aside; without saying which track was named it
        // wouldn't count as the same.
        let asset = try await FilmIndexFile.open(url, matching: before, besides: [2])
        do {
            _ = try await FilmIndexFile.open(url, matching: before)
            XCTFail("a kept index with one track more passed for the film's own")
        } catch {
            XCTAssertEqual(error as? FilmIndexFile.Failure, .incomplete)
        }

        let player = FilmPlayer(asset: asset, bytes: TestBytes(data: data))
        try await player.open()
        let film = player.film
        print("FILM hidden dts sounds: \(film.sounds)")
        let dts = try XCTUnwrap(film.sounds.first { $0.codec == "dtsc" }, "\(film.sounds)")
        XCTAssertEqual(dts.channels, 6)
        XCTAssertTrue(dts.playable)
        XCTAssertTrue(dts.decodedHere)
        XCTAssertEqual(film.sound, dts.id)
        let layer = AVSampleBufferDisplayLayer()
        player.show(on: layer.sampleBufferRenderer)
        player.start(at: 0)
        let playing = await wait(6) { player.state == .playing }
        XCTAssertTrue(playing, "state \(player.state), failure \(String(describing: player.failure))")
        await pause(1)
        let n = player.notes
        print("FILM hidden dts: \(n.decodedKind ?? "-") \(n.decodedPackets) packets, \(n.decodedLost) lost, \(n.decodedFrames) frames, \(n.decodedChannels) channels at \(n.decodedRate); joined \(n.joined) by \(n.joinedBy); mended \(n.mended) \(n.mendWhy ?? "")")
        XCTAssertEqual(n.decodedKind, "dts")
        XCTAssertGreaterThanOrEqual(n.decodedPackets, 94)
        XCTAssertEqual(n.decodedLost, 0)
        XCTAssertEqual(n.decodedFrames, n.decodedPackets * 512)
        XCTAssertEqual(n.decodedChannels, 6)
        XCTAssertEqual(n.mended, 0)
        XCTAssertGreaterThan(player.time, 0.4)
        XCTAssertNil(player.failure)
        // Each packet the decoder was handed is a whole DTS frame: it starts with DTS's sync word.
        XCTAssertFalse(fakes.starts.isEmpty)
        for start in fakes.starts { XCTAssertEqual(Array(start.prefix(4)), [0x7F, 0xFE, 0x80, 0x01]) }
        player.close()
    }
}
