#if canImport(AVFoundation) && os(macOS)
import XCTest
import AVFoundation
import CoreMedia
import VideoToolbox
import UniformTypeIdentifiers
@testable import WoodruffKit

/// Hands a film's bytes to Apple's reader the way the app's Drive stream does: through a resource loader, a slice
/// at a time, noting what was asked for.
private final class ProbeLoader: NSObject, AVAssetResourceLoaderDelegate {
    struct Asked { var from: Int64; var handed: Int64; var wanted: Int64; var toEnd: Bool }

    let data: Data
    let queue = DispatchQueue(label: "probe.loader")
    private var asked: [Asked] = []
    private var cancelled = 0
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
        asked.append(Asked(from: from, handed: 0, wanted: Int64(d.requestedLength), toEnd: d.requestsAllDataToEndOfResource))
        step(request, at: from, end: end, index: asked.count - 1)
        return true
    }

    func resourceLoader(_ loader: AVAssetResourceLoader, didCancel request: AVAssetResourceLoadingRequest) {
        cancelled += 1
    }

    private func step(_ request: AVAssetResourceLoadingRequest, at: Int64, end: Int64, index: Int) {
        guard !request.isCancelled, !request.isFinished else { return }
        guard at < end, let d = request.dataRequest else {
            request.finishLoading()
            return
        }
        let upTo = min(end, at + slice)
        d.respond(with: data.subdata(in: Int(at)..<Int(upTo)))
        asked[index].handed += upTo - at
        queue.async { [weak self] in self?.step(request, at: upTo, end: end, index: index) }
    }

    /// How many requests so far.
    func count() -> Int { queue.sync { asked.count } }

    /// The requests from [from] on: "offset+handed" each ("/wanted" when less was handed, "…" for "to the end").
    func summary(from: Int = 0) -> String {
        queue.sync {
            let part = asked.dropFirst(from)
            let total = part.reduce(Int64(0)) { $0 + $1.handed }
            let list = part.prefix(24).map { a in
                "\(a.from)+\(a.handed)" + (a.toEnd ? "…" : (a.handed < a.wanted ? "/\(a.wanted)" : ""))
            }
            return "\(part.count) requests, \(total) bytes handed, \(cancelled) dropped so far: " + list.joined(separator: " ")
        }
    }
}

/// One sample as Apple's own reader (or the app's) hands it on.
private struct Flat {
    var shown: CMTime
    var decoded: CMTime
    var lasts: CMTime
    var bytes: Data
}

/// What has to be known before the app's own player is built on Apple's index reader. It prints what it finds
/// ("PROBE" lines) and then fails on purpose, so GitHub's Mac stops there and the log can be read at once.
final class FilmEngineProbeTests: XCTestCase {
    private func fixture(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "mp4", subdirectory: "Fixtures"), "no fixture \(name)")
    }

    private func t(_ time: CMTime) -> String {
        time.isValid ? String(format: "%.5f", time.seconds) : "invalid"
    }

    private func fourCC(_ code: FourCharCode) -> String {
        let bytes = [UInt8((code >> 24) & 255), UInt8((code >> 16) & 255), UInt8((code >> 8) & 255), UInt8(code & 255)]
        return String(bytes: bytes, encoding: .ascii) ?? "\(code)"
    }

    /// Every sample of [track] as Apple's reader hands it on untouched.
    private func appleSamples(_ asset: AVAsset, _ track: AVAssetTrack) throws -> (samples: [Flat], buffers: Int, notes: [String]) {
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        out.alwaysCopiesSampleData = false
        guard reader.canAdd(out) else { return ([], 0, ["can't add output"]) }
        reader.add(out)
        guard reader.startReading() else { return ([], 0, ["can't start: \(String(describing: reader.error))"]) }
        var flat: [Flat] = []
        var buffers = 0
        var notes: [String] = []
        while let sb = out.copyNextSampleBuffer() {
            buffers += 1
            let n = CMSampleBufferGetNumSamples(sb)
            if buffers <= 2 {
                let whole = CMCopyDictionaryOfAttachments(allocator: kCFAllocatorDefault, target: sb, attachmentMode: kCMAttachmentMode_ShouldPropagate)
                let each = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false)
                notes.append("buffer \(buffers): \(n) samples, pts \(t(CMSampleBufferGetPresentationTimeStamp(sb))), buffer attachments \(String(describing: whole)), sample attachments \(String(describing: each))")
            }
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
                flat.append(Flat(shown: timing.presentationTimeStamp, decoded: timing.decodeTimeStamp, lasts: timing.duration,
                                 bytes: all.subdata(in: at..<(at + size))))
                at += size
            }
        }
        if reader.status != .completed { notes.append("reader ended as \(reader.status.rawValue): \(String(describing: reader.error))") }
        return (flat, buffers, notes)
    }

    /// Every run of [track] through the app's reader of Apple's index.
    private func runs(_ track: AVAssetTrack, most: Int = 4 << 20, gap: Int64 = 256 << 10) -> [FilmRun]? {
        guard let reader = FilmTrackReader(track: track) else { return nil }
        var all: [FilmRun] = []
        while let run = reader.next(most: most, gap: gap) { all.append(run) }
        return all
    }

    private func probe(_ name: String) async throws {
        let url = try fixture(name)
        let bytes = try Data(contentsOf: url)
        print("PROBE ===== \(name): \(bytes.count) bytes")

        // 1. As a file on disk, read by Apple's own reader: what the app's reader must match.
        let local = AVURLAsset(url: url)
        let localTracks = try await local.load(.tracks)
        var apple: [CMPersistentTrackID: [Flat]] = [:]
        for track in localTracks {
            let got = try appleSamples(local, track)
            apple[track.trackID] = got.samples
            print("PROBE file track \(track.trackID) \(track.mediaType.rawValue): cursors \(track.canProvideSampleCursors), Apple's reader gave \(got.samples.count) samples in \(got.buffers) buffers")
            for note in got.notes { print("PROBE   \(note)") }
        }

        // 2. Through a resource loader, as the app's Drive stream is.
        let loader = ProbeLoader(data: bytes)
        let remote = AVURLAsset(url: URL(string: "probe-stream://film/\(name).mp4")!)
        remote.resourceLoader.setDelegate(loader, queue: loader.queue)
        let remoteTracks = try await remote.load(.tracks)
        print("PROBE loader: opening asked for \(loader.summary())")
        var every: [(offset: Int64, size: Int)] = []
        var pictureBuffers: [CMSampleBuffer] = []
        var soundBuffers: [CMSampleBuffer] = []
        var pictureFormat: CMFormatDescription?
        var soundDone = false
        for track in remoteTracks {
            let kind = track.mediaType.rawValue
            let before = loader.count()
            let formats = try await track.load(.formatDescriptions)
            let segments = try await track.load(.segments)
            let range = try await track.load(.timeRange)
            let language = try await track.load(.languageCode)
            let enabled = try await track.load(.isEnabled)
            let subtypes = formats.map { fourCC(CMFormatDescriptionGetMediaSubType($0)) }.joined(separator: ",")
            print("PROBE loader track \(track.trackID) \(kind) [\(subtypes)] lang \(language ?? "-") enabled \(enabled): cursors \(track.canProvideSampleCursors), time \(t(range.start))+\(t(range.duration))")
            for s in segments {
                let m = s.timeMapping
                print("PROBE   segment: file \(t(m.source.start))+\(t(m.source.duration)) -> film \(t(m.target.start))+\(t(m.target.duration)) empty \(s.isEmpty)")
            }
            if let asbd = formats.first.flatMap({ CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }), track.mediaType == .audio {
                print("PROBE   sound: \(asbd.mSampleRate) Hz, \(asbd.mChannelsPerFrame) channels, \(asbd.mFramesPerPacket) frames a packet")
            }
            let started = Date()
            guard let all = runs(track) else {
                print("PROBE   the index can't be walked for this track")
                continue
            }
            let took = Date().timeIntervalSince(started)
            let samples = all.flatMap { $0.samples }
            every += samples.map { (offset: $0.offset, size: $0.size) }
            print(String(format: "PROBE   %ld samples in %ld runs, walked in %.1f ms (%.1f µs a sample); walking asked for %@",
                         samples.count, all.count, took * 1000, samples.isEmpty ? 0 : took * 1e6 / Double(samples.count),
                         loader.summary(from: before)))
            for s in samples.prefix(4) {
                print("PROBE   mine: at \(s.offset)+\(s.size) shown \(t(s.shown)) decoded \(t(s.decoded)) lasts \(t(s.lasts)) sync \(s.sync) attachments \(String(describing: s.attachments))")
            }
            let theirs = apple[track.trackID] ?? []
            for s in theirs.prefix(4) {
                print("PROBE   Apple's: \(s.bytes.count) bytes shown \(t(s.shown)) decoded \(t(s.decoded)) lasts \(t(s.lasts))")
            }
            var sameBytes = 0, sameLength = 0, sameGap = 0
            let lead = samples.first.flatMap { m in theirs.first.map { CMTimeSubtract($0.shown, m.shown) } } ?? .zero
            for (m, a) in zip(samples, theirs) {
                let mine = bytes.subdata(in: Int(m.offset)..<Int(m.offset) + m.size)
                if mine == a.bytes { sameBytes += 1 }
                if CMTimeCompare(m.lasts, a.lasts) == 0 { sameLength += 1 }
                if CMTimeCompare(CMTimeAdd(m.shown, lead), a.shown) == 0 { sameGap += 1 }
            }
            print("PROBE   against Apple's reader: \(samples.count) vs \(theirs.count) samples, same bytes \(sameBytes), same length \(sameLength), same time once moved by \(t(lead)): \(sameGap)")

            // The buffers Apple's decoders take, made from the app's own reading.
            do {
                var made: [CMSampleBuffer] = []
                for run in all {
                    let part = bytes.subdata(in: Int(run.offset)..<Int(run.offset) + run.length)
                    if track.mediaType == .video {
                        made += try FilmSampleBuffers.each(of: run, bytes: part, format: formats.first)
                    } else if track.mediaType == .audio {
                        made += try FilmSampleBuffers.together(run, bytes: part, format: formats.first)
                    }
                }
                print("PROBE   made \(made.count) buffers")
                if track.mediaType == .video, pictureBuffers.isEmpty {
                    pictureBuffers = made
                    pictureFormat = formats.first
                } else if track.mediaType == .audio, !soundDone {
                    soundBuffers = made
                    soundDone = true
                }
            } catch {
                print("PROBE   buffers couldn't be made: \(error)")
            }
        }

        // 3. A file holding the index alone (every sample's bytes blanked): does the index still walk the same?
        var blank = bytes
        for s in every where s.size > 0 {
            blank.replaceSubrange(Int(s.offset)..<Int(s.offset) + s.size, with: Data(count: s.size))
        }
        let blankURL = FileManager.default.temporaryDirectory.appendingPathComponent("probe-\(name)-index-only.mp4")
        try blank.write(to: blankURL)
        let indexOnly = AVURLAsset(url: blankURL)
        let indexTracks = try await indexOnly.load(.tracks)
        var same = true
        for track in indexTracks {
            guard let mine = runs(track)?.flatMap({ $0.samples }),
                  let other = remoteTracks.first(where: { $0.trackID == track.trackID }),
                  let theirs = runs(other)?.flatMap({ $0.samples }) else { same = false; continue }
            if mine.count != theirs.count { same = false }
            for (a, b) in zip(mine, theirs) where a.offset != b.offset || a.size != b.size || CMTimeCompare(a.shown, b.shown) != 0 {
                same = false
            }
        }
        print("PROBE index-only file: \(indexTracks.count) tracks, walks the same as the whole film: \(same)")
        try? FileManager.default.removeItem(at: blankURL)

        // 4. The picture's buffers decode?
        if let format = pictureFormat, !pictureBuffers.isEmpty {
            var session: VTDecompressionSession?
            let made = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: format, decoderSpecification: nil,
                                                    imageBufferAttributes: nil, outputCallback: nil, decompressionSessionOut: &session)
            if made == noErr, let session {
                var good = 0, bad = 0, refused = 0
                for buffer in pictureBuffers {
                    var info = VTDecodeInfoFlags()
                    let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: buffer, flags: [], infoFlagsOut: &info) { status, _, image, _, _ in
                        if status == noErr, image != nil { good += 1 } else { bad += 1 }
                    }
                    if status != noErr { refused += 1 }
                }
                VTDecompressionSessionWaitForAsynchronousFrames(session)
                VTDecompressionSessionInvalidate(session)
                print("PROBE decoding the picture: \(good) frames decoded, \(bad) failed, \(refused) refused, of \(pictureBuffers.count)")
            } else {
                print("PROBE decoding the picture: no decoder (\(made))")
            }
        }

        // 5. Played with nothing to show it on: the clock runs, and neither renderer fails?
        let clock = AVSampleBufferRenderSynchronizer()
        let sound = AVSampleBufferAudioRenderer()
        let layer = AVSampleBufferDisplayLayer()
        let picture = layer.sampleBufferRenderer
        clock.addRenderer(sound)
        clock.addRenderer(picture)
        for buffer in pictureBuffers { picture.enqueue(buffer) }
        for buffer in soundBuffers { sound.enqueue(buffer) }
        clock.setRate(1, time: .zero)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let now = clock.currentTime()
        print("PROBE played 1.5 s: clock at \(t(now)), rate \(clock.rate), picture status \(picture.status.rawValue) \(String(describing: picture.error)), sound status \(sound.status.rawValue) \(String(describing: sound.error)), picture ready for more \(picture.isReadyForMoreMediaData), sound ready for more \(sound.isReadyForMoreMediaData)")
        clock.setRate(0, time: now)
        picture.flush()
        sound.flush()

        // 6. Chapters through the loader.
        do {
            let locales = try await remote.load(.availableChapterLocales)
            let groups = try await remote.loadChapterMetadataGroups(bestMatchingPreferredLanguages: ["en"])
            var titles: [String] = []
            for group in groups {
                var title = "?"
                for item in group.items where item.commonKey == .commonKeyTitle {
                    title = (try? await item.load(.stringValue)) ?? "?"
                }
                titles.append("\(title) @\(t(group.timeRange.start))+\(t(group.timeRange.duration))")
            }
            print("PROBE chapters: locales \(locales.map { $0.identifier }), \(titles)")
        } catch {
            print("PROBE chapters: \(error.localizedDescription)")
        }

        // 7. A subtitle track's first samples, as bytes.
        for track in remoteTracks where track.mediaType == .subtitle || track.mediaType == .text || track.mediaType == .closedCaption {
            guard let all = runs(track) else { continue }
            for s in all.flatMap({ $0.samples }).prefix(3) {
                let raw = bytes.subdata(in: Int(s.offset)..<Int(s.offset) + min(s.size, 48))
                print("PROBE \(track.mediaType.rawValue) track \(track.trackID) sample at \(t(s.shown)) lasts \(t(s.lasts)), \(s.size) bytes: \(raw.map { String(format: "%02x", $0) }.joined())")
            }
        }
        withExtendedLifetime(loader) {}
    }

    func testProbe() async throws {
        // Never left hanging on GitHub's Mac.
        DispatchQueue.global().asyncAfter(deadline: .now() + 120) {
            print("PROBE: gave up after two minutes")
            exit(2)
        }
        for name in ["h264-aac", "hevc-hdr-aac51", "multi"] {
            do {
                try await probe(name)
            } catch {
                print("PROBE \(name): stopped by \(error)")
            }
        }
        XCTFail("PROBE finished: failing on purpose so the log above can be read at once")
    }
}
#endif
