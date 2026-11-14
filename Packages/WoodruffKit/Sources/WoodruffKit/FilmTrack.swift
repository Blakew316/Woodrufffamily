#if canImport(AVFoundation)
import AVFoundation
import CoreMedia

/// One picture frame or sound packet of a film: where its bytes are in the file, and when it plays.
public struct FilmSample {
    /// Where its bytes start in the file, and how many there are.
    public let offset: Int64
    public let size: Int
    /// When it's shown or heard, when it's decoded (the two differ for pictures stored out of order) and how long it
    /// lasts, on the film's own clock.
    public let shown: CMTime
    public let decoded: CMTime
    public let lasts: CMTime
    /// Decoding can start here: nothing before it is needed.
    public let sync: Bool
    /// What the file says about how it depends on other samples, as the decoder wants it told.
    public let attachments: [AnyHashable: Any]?
    /// What kind of sample it is (its codec and settings), when the file says so sample by sample.
    public let format: CMFormatDescription?
}

/// Samples to fetch together: they follow one another in the file (`FilmRuns`).
public struct FilmRun {
    /// The first byte to fetch, and how many.
    public let offset: Int64
    public let length: Int
    public let samples: [FilmSample]

    /// When its first sample plays, and when its last one is over.
    public var starts: CMTime { samples.first?.shown ?? .invalid }
    public var ends: CMTime {
        var latest = CMTime.invalid
        for s in samples {
            let end = CMTimeAdd(s.shown, s.lasts)
            if !latest.isValid || CMTimeCompare(end, latest) > 0 { latest = end }
        }
        return latest
    }
}

/// One track of a film (its picture, or one of its sound or subtitle tracks), read a run of samples at a time in
/// the order they're decoded.
///
/// Apple's reader of the file's index says where each sample is and when it plays; nothing of the film itself is
/// read here. The bytes are fetched by whoever asks for the run.
///
/// Not safe to use from two threads at once.
public final class FilmTrackReader {
    public let track: AVAssetTrack
    /// Added to the file's own times to get the film's clock (a track's times usually start a little after zero, to
    /// make room for pictures stored out of order or for a sound codec's lead-in).
    public let shift: CMTime
    private var cursor: AVSampleCursor
    /// Every sample has been handed out.
    public private(set) var ended = false

    /// Nil when the file's index can't be walked for this track.
    public init?(track: AVAssetTrack, shift: CMTime = .zero) {
        guard let first = track.makeSampleCursorAtFirstSampleInDecodeOrder() else { return nil }
        self.track = track
        self.shift = shift
        cursor = first
    }

    /// The next run: samples that follow one another in the file (a gap of up to [gap] bytes is read through), no
    /// more than [most] bytes, [limit] samples or [seconds] of the film. Nil at the end of the track.
    public func next(most: Int = 4 << 20, gap: Int64 = 256 << 10, limit: Int = 480, seconds: Double = 2) -> FilmRun? {
        guard !ended else { return nil }
        var samples: [FilmSample] = []
        var start: Int64 = 0, end: Int64 = 0
        var began = CMTime.invalid
        while samples.count < limit {
            let range = cursor.currentSampleStorageRange
            let offset = range.offset, size = Int(range.length)
            let decoded = cursor.decodeTimeStamp
            if samples.isEmpty {
                start = offset
                end = offset + Int64(size)
                began = decoded
            } else {
                guard FilmRuns.joins(start: start, end: end, offset: offset, size: size, gap: gap, most: most),
                      CMTimeSubtract(decoded, began).seconds < seconds else { break }
                end = offset + Int64(size)
            }
            samples.append(FilmSample(offset: offset, size: size,
                                      shown: CMTimeAdd(cursor.presentationTimeStamp, shift),
                                      decoded: CMTimeAdd(decoded, shift),
                                      lasts: cursor.currentSampleDuration,
                                      sync: cursor.currentSampleSyncInfo.sampleIsFullSync.boolValue,
                                      attachments: cursor.currentSampleDependencyAttachments,
                                      format: cursor.copyCurrentSampleFormatDescription()))
            if cursor.stepInDecodeOrder(byCount: 1) != 1 {
                ended = true
                break
            }
        }
        guard !samples.isEmpty else { return nil }
        return FilmRun(offset: start, length: Int(end - start), samples: samples)
    }

    /// Moves to where decoding can start for the film's time [time]: the last sample at or before it that needs
    /// nothing before it, and [back] samples more before that (a sound decoder wants a packet or two to get going).
    /// Returns when the sample it now stands on plays (the next run starts with it), or nil when the index couldn't
    /// be walked there (it stands where it stood).
    @discardableResult
    public func seek(to time: CMTime, back: Int = 0) -> CMTime? {
        guard let at = track.makeSampleCursor(presentationTimeStamp: CMTimeSubtract(time, shift)) else { return nil }
        var steps = 0
        while !at.currentSampleSyncInfo.sampleIsFullSync.boolValue, steps < 5000 {
            guard at.stepInDecodeOrder(byCount: -1) != 0 else { break }
            steps += 1
        }
        if back > 0 { _ = at.stepInDecodeOrder(byCount: Int64(-back)) }
        cursor = at
        ended = false
        return CMTimeAdd(at.presentationTimeStamp, shift)
    }

    /// Back to the first sample.
    public func rewind() {
        if let first = track.makeSampleCursorAtFirstSampleInDecodeOrder() {
            cursor = first
            ended = false
        }
    }
}

/// Makes the sample buffers Apple's decoders take from a run's bytes.
public enum FilmSampleBuffers {
    public enum Failure: Error, Equatable {
        /// Fewer bytes than the run covers.
        case short
        /// The run has no samples with a known format.
        case noFormat
        /// Core Media refused (its status).
        case refused(Int32)
    }

    /// One buffer for each sample of [run] (picture frames are handed to the decoder one at a time). [bytes]: the
    /// run's bytes, from its first. [format]: the track's format, for samples that don't carry one of their own.
    /// [remake]: each sample's format as the decoder is to have it (a name it takes: `FilmPictureFormat`). [lean]: a
    /// sample's bytes without what the decoder has already (`FilmNALUnits`), or nil to hand them over as they are.
    /// [plain]: each frame told only whether it's a keyframe, not the rest of what Apple's reader made of the file's
    /// tables (for a picture handed over under another name than the file gives it).
    public static func each(of run: FilmRun, bytes: Data, format: CMFormatDescription?,
                            remake: ((CMFormatDescription) -> CMFormatDescription)? = nil,
                            lean: ((Data) -> Data?)? = nil, plain: Bool = false) throws -> [CMSampleBuffer] {
        guard bytes.count >= run.length else { throw Failure.short }
        let whole = try block(run.length)
        try bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress, run.length > 0 else { return }
            try check(CMBlockBufferReplaceDataBytes(with: base, blockBuffer: whole, offsetIntoDestination: 0, dataLength: run.length))
        }
        var out: [CMSampleBuffer] = []
        out.reserveCapacity(run.samples.count)
        for s in run.samples {
            guard let given = s.format ?? format else { throw Failure.noFormat }
            let fd = remake?(given) ?? given
            var part: CMBlockBuffer?
            var size = s.size
            let from = bytes.startIndex + Int(s.offset - run.offset)
            if let lean, s.size > 0, let slim = lean(bytes[from..<(from + s.size)]) {
                // The frame without what the decoder has already: a block of its own.
                let own = try block(slim.count)
                try slim.withUnsafeBytes { raw in
                    guard let base = raw.baseAddress else { return }
                    try check(CMBlockBufferReplaceDataBytes(with: base, blockBuffer: own, offsetIntoDestination: 0, dataLength: slim.count))
                }
                part = own
                size = slim.count
            } else {
                try check(CMBlockBufferCreateWithBufferReference(allocator: kCFAllocatorDefault, referenceBuffer: whole,
                                                                 offsetToData: Int(s.offset - run.offset), dataLength: s.size,
                                                                 flags: 0, blockBufferOut: &part))
            }
            var timing = CMSampleTimingInfo(duration: s.lasts, presentationTimeStamp: s.shown, decodeTimeStamp: s.decoded)
            var made: CMSampleBuffer?
            try check(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: part, formatDescription: fd,
                                                sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                                sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &made))
            guard let buffer = made else { throw Failure.refused(-1) }
            attach(s, to: buffer, plain: plain)
            out.append(buffer)
        }
        return out
    }

    /// [run]'s samples as sound: packets that follow one another with the same format and length go into one buffer
    /// together, as Apple's own reader hands sound on. [from]: the film's time the sound is wanted from. What a
    /// buffer holds before that is decoded and cut, not heard: a sound codec's lead-in at the film's start, or the
    /// packets before the place the film was moved to.
    public static func together(_ run: FilmRun, bytes: Data, format: CMFormatDescription?, from: CMTime = .invalid) throws -> [CMSampleBuffer] {
        guard bytes.count >= run.length else { throw Failure.short }
        var out: [CMSampleBuffer] = []
        var first = 0
        while first < run.samples.count {
            let lead = run.samples[first]
            guard let fd = lead.format ?? format else { throw Failure.noFormat }
            var to = first + 1
            while to < run.samples.count, same(run.samples[to].format ?? format, fd),
                  CMTimeCompare(run.samples[to].lasts, lead.lasts) == 0 {
                to += 1
            }
            let group = run.samples[first..<to]
            let total = group.reduce(0) { $0 + $1.size }
            let packed = try block(total)
            var packets: [AudioStreamPacketDescription] = []
            packets.reserveCapacity(group.count)
            var at = 0
            try bytes.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                for s in group {
                    if s.size > 0 {
                        try check(CMBlockBufferReplaceDataBytes(with: base + Int(s.offset - run.offset), blockBuffer: packed,
                                                                offsetIntoDestination: at, dataLength: s.size))
                    }
                    packets.append(AudioStreamPacketDescription(mStartOffset: Int64(at), mVariableFramesInPacket: 0,
                                                                mDataByteSize: UInt32(s.size)))
                    at += s.size
                }
            }
            var made: CMSampleBuffer?
            try check(CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault, dataBuffer: packed,
                                                                           formatDescription: fd, sampleCount: group.count,
                                                                           presentationTimeStamp: lead.shown,
                                                                           packetDescriptions: &packets, sampleBufferOut: &made))
            guard let buffer = made else { throw Failure.refused(-1) }
            if from.isValid, CMTimeCompare(lead.shown, from) < 0 {
                let whole = CMTimeMultiply(lead.lasts, multiplier: Int32(group.count))
                let cut = CMTimeMinimum(CMTimeSubtract(from, lead.shown), whole)
                CMSetAttachment(buffer, key: kCMSampleBufferAttachmentKey_TrimDurationAtStart,
                                value: CMTimeCopyAsDictionary(cut, allocator: kCFAllocatorDefault),
                                attachmentMode: kCMAttachmentMode_ShouldPropagate)
            }
            out.append(buffer)
            first = to
        }
        return out
    }

    /// Marks [buffer] as one to decode but not show (a frame between where decoding starts and where the film is
    /// wanted from).
    public static func hide(_ buffer: CMSampleBuffer) {
        set(kCMSampleAttachmentKey_DoNotDisplay, kCFBooleanTrue, on: buffer)
    }

    private static func block(_ length: Int) throws -> CMBlockBuffer {
        var made: CMBlockBuffer?
        // (A block of no bytes can't be made: a byte that nothing points at.)
        try check(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: max(length, 1),
                                                     blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                     dataLength: max(length, 1), flags: kCMBlockBufferAssureMemoryNowFlag,
                                                     blockBufferOut: &made))
        guard let block = made else { throw Failure.refused(-1) }
        return block
    }

    private static func check(_ status: OSStatus) throws {
        if status != noErr { throw Failure.refused(status) }
    }

    private static func same(_ a: CMFormatDescription?, _ b: CMFormatDescription) -> Bool {
        guard let a else { return false }
        return a === b || CMFormatDescriptionEqual(a, otherFormatDescription: b)
    }

    /// What the file says about how [s] depends on other samples goes with its buffer: the decoder and the display
    /// use it (which frames a film can start from, which can be skipped when it's behind).
    private static func attach(_ s: FilmSample, to buffer: CMSampleBuffer, plain: Bool = false) {
        if !plain, let extra = s.attachments, !extra.isEmpty {
            for (key, value) in extra {
                guard let name = key.base as? String else { continue }
                set(name as CFString, value as AnyObject, on: buffer)
            }
        } else if !s.sync {
            set(kCMSampleAttachmentKey_NotSync, kCFBooleanTrue, on: buffer)
        }
    }

    private static func set(_ key: CFString, _ value: AnyObject, on buffer: CMSampleBuffer) {
        guard let all = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: true), CFArrayGetCount(all) > 0 else { return }
        let first = unsafeBitCast(CFArrayGetValueAtIndex(all, 0), to: CFMutableDictionary.self)
        CFDictionarySetValue(first, Unmanaged.passUnretained(key).toOpaque(), Unmanaged.passUnretained(value).toOpaque())
    }
}
#endif
