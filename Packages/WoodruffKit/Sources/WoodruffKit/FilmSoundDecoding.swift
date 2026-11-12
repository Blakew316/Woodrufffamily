#if canImport(AVFoundation)
import AVFoundation
import CoreMedia

/// Plain samples a decoder made of one packet of a film's sound.
public struct FilmDecodedSound {
    /// 32-bit floats, one frame after another, [channels] to a frame, always in this order: front left, front right,
    /// centre, low, surround left, surround right, rear left, rear right, then the four overhead: top front left,
    /// top front right, top rear left, top rear right (two channels: left, right; one: by itself). Good until the
    /// decoder is next asked.
    public let samples: UnsafeBufferPointer<Float>
    public let frames: Int
    /// One, two, six, eight, or twelve (7.1 with four overhead: Atmos and DTS:X with their heights).
    public let channels: Int
    public let rate: Int
    /// The first frame given belongs this many frames before the packet's own time. A decoder that works on a
    /// stretch of sound at once (the one that places the overhead sounds does) hands each stretch over late.
    public let early: Int

    public init(samples: UnsafeBufferPointer<Float>, frames: Int, channels: Int, rate: Int, early: Int = 0) {
        self.samples = samples
        self.frames = frames
        self.channels = channels
        self.rate = rate
        self.early = early
    }
}

/// Decodes a film's sound that Apple has no decoder for to plain samples, a packet at a time. Used from one thread.
public protocol FilmSoundDecoder: AnyObject {
    /// One packet as the file holds it. Nil when nothing in it could be decoded; no frames when the decoder needs
    /// more before it gives any (after the film is moved, until the sound next starts afresh).
    func decode(_ packet: UnsafeRawBufferPointer) -> FilmDecodedSound?
    /// The film was moved to another place: what the decoder holds is forgotten.
    func flush()
}

/// Sound Apple has no decoder for, and the decoders an app gives the player for it.
///
/// The Apple TV app gives one for DTS and Dolby TrueHD (`TVFilmSound`: FFmpeg's decoders, in FilmSound.framework).
/// Where none is given such sound can't be played, as before there was one.
public enum FilmSoundDecoders {
    /// Makes a decoder for sound of [kind] ("dts", "truehd"), or nil when it has none. Set once, as the app starts.
    public static var make: ((String) -> FilmSoundDecoder?)?

    /// What a file's own four letters for a track's sound say it is.
    private static let named: [String: String] = [
        "dtsc": "dts", "dtsh": "dts", "dtsl": "dts", "dtse": "dts", "dts+": "dts", "dts-": "dts", "DTS": "dts",
        "mlpa": "truehd",
    ]

    /// The kind of sound [format] describes when it's one of these: "dts" (DTS and DTS-HD) or "truehd". Nil for
    /// every other sound.
    ///
    /// A file says so with its own four letters for the sound ("dtsc", "dtsh", "dtsl" or "dtse" for DTS, "mlpa" for
    /// TrueHD) or, as FFmpeg and HandBrake write DTS, as "mp4a" sound whose settings name the kind with a number
    /// (0xA9 to 0xAC: DTS, DTS-HD High Resolution, DTS-HD Master Audio, DTS Express).
    public static func kind(of format: CMFormatDescription) -> String? {
        guard CMFormatDescriptionGetMediaType(format) == kCMMediaType_Audio else { return nil }
        if let kind = named[FilmPlayer.letters(CMFormatDescriptionGetMediaSubType(format))] { return kind }
        if let number = objectType(of: format), (0xA9...0xAC).contains(number) { return "dts" }
        return nil
    }

    /// The number an "mp4a" track's settings give for its kind of sound (0x40 is AAC), read from the settings
    /// themselves: the file's "esds", which Apple's reader hands on as the format's cookie.
    static func objectType(of format: CMFormatDescription) -> UInt8? {
        var size = 0
        guard let cookie = CMAudioFormatDescriptionGetMagicCookie(format, sizeOut: &size), size > 0 else { return nil }
        return objectType(inSettings: UnsafeRawBufferPointer(start: cookie, count: size))
    }

    /// The same from the settings' bytes. They are descriptors one inside another, each a tag, its length (one to
    /// four bytes, seven bits in each) and what it holds: the stream's (tag 3) holds the decoder's (tag 4), whose
    /// first byte is the number. Some hand the settings on with four bytes of version before them.
    static func objectType(inSettings bytes: UnsafeRawBufferPointer) -> UInt8? {
        for lead in [0, 4] where bytes.count > lead {
            var at = lead
            // A descriptor's tag and length at [at]; nil when the bytes end first.
            func head() -> (tag: UInt8, length: Int)? {
                guard at < bytes.count else { return nil }
                let tag = bytes[at]
                at += 1
                var length = 0
                for _ in 0..<4 {
                    guard at < bytes.count else { return nil }
                    let byte = bytes[at]
                    at += 1
                    length = length << 7 | Int(byte & 0x7F)
                    if byte & 0x80 == 0 { break }
                }
                return (tag, length)
            }
            guard let first = head() else { continue }
            if first.tag == 0x04 {
                // (The decoder's descriptor by itself.)
                if at < bytes.count { return bytes[at] }
                continue
            }
            guard first.tag == 0x03, at + 3 <= bytes.count else { continue }
            // The stream's own fields: its number (two bytes), then flags that say which optional fields follow.
            let flags = bytes[at + 2]
            at += 3
            if flags & 0x80 != 0 { at += 2 }
            if flags & 0x40 != 0 {
                guard at < bytes.count else { continue }
                at += 1 + Int(bytes[at])
            }
            if flags & 0x20 != 0 { at += 2 }
            guard let second = head(), second.tag == 0x04, at < bytes.count else { continue }
            return bytes[at]
        }
        return nil
    }
}

/// Buffers of plain samples for the sound renderer.
enum FilmDecodedBuffers {
    enum Failure: Error, Equatable {
        /// Core Media wouldn't make the buffer.
        case refused(OSStatus)
    }

    /// The format of [channels] channels of 32-bit floats at [rate] a second, in the order `FilmDecodedSound` gives
    /// them. Nil for a number of channels a decoder never gives.
    static func format(channels: Int, rate: Int) -> CMAudioFormatDescription? {
        let tag: AudioChannelLayoutTag
        switch channels {
        case 1: tag = kAudioChannelLayoutTag_Mono
        case 2: tag = kAudioChannelLayoutTag_Stereo
        // Left, right, centre, low, left surround, right surround.
        case 6: tag = kAudioChannelLayoutTag_MPEG_5_1_A
        // The same, then rear left surround and rear right surround.
        case 8: tag = kAudioChannelLayoutTag_MPEG_7_1_C
        // Those eight, then four overhead: top front left and right, top rear left and right.
        case 12: tag = kAudioChannelLayoutTag_Atmos_7_1_4
        default: return nil
        }
        guard rate > 0 else { return nil }
        var basic = AudioStreamBasicDescription(mSampleRate: Double(rate), mFormatID: kAudioFormatLinearPCM,
                                                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                                mBytesPerPacket: UInt32(channels * 4), mFramesPerPacket: 1,
                                                mBytesPerFrame: UInt32(channels * 4), mChannelsPerFrame: UInt32(channels),
                                                mBitsPerChannel: 32, mReserved: 0)
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = tag
        var made: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &basic,
                                                    layoutSize: MemoryLayout<AudioChannelLayout>.size, layout: &layout,
                                                    magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                                    formatDescriptionOut: &made)
        return status == noErr ? made : nil
    }

    /// One buffer of [frames] frames of [format], starting at [time]: a copy of [samples].
    static func buffer(_ samples: UnsafeRawBufferPointer, frames: Int, format: CMAudioFormatDescription, at time: CMTime) throws -> CMSampleBuffer {
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: samples.count,
                                                        blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                        dataLength: samples.count, flags: kCMBlockBufferAssureMemoryNowFlag,
                                                        blockBufferOut: &block)
        guard status == noErr, let block, let base = samples.baseAddress else { throw Failure.refused(status) }
        status = CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: samples.count)
        guard status == noErr else { throw Failure.refused(status) }
        var made: CMSampleBuffer?
        status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault, dataBuffer: block,
                                                                      formatDescription: format, sampleCount: frames,
                                                                      presentationTimeStamp: time, packetDescriptions: nil,
                                                                      sampleBufferOut: &made)
        guard status == noErr, let made else { throw Failure.refused(status) }
        return made
    }
}

/// One of a film's sound tracks being decoded here: its decoder, and what its packets have come to.
///
/// Not safe to use from two threads at once (the player uses it on its own queue).
final class FilmSoundDecoding {
    /// "dts" or "truehd".
    let kind: String
    private let decoder: FilmSoundDecoder
    /// The shape of what last came out, and its format for the renderer.
    private(set) var channels = 0
    private(set) var rate = 0
    private var format: CMAudioFormatDescription?
    /// Packets given to the decoder, those nothing could be made of, and the frames that came out.
    private(set) var packets = 0
    private(set) var lost = 0
    private(set) var frames = 0
    /// Seconds of the film's sound that were decoded before any of it gave a frame.
    private(set) var silent = 0.0

    /// The least a buffer holds, in seconds, unless its run ends first. TrueHD comes forty frames to a packet, 1,200
    /// packets a second: handed over one by one, that many buffers make the renderer let multichannel sound drop.
    static let least = 0.1
    /// Packets whose times in the file are further apart than this are a real break in the sound: a buffer ends
    /// there and the next starts at the file's time. Closer, they are played end to end.
    static let apart = 0.05

    init(kind: String, decoder: FilmSoundDecoder) {
        self.kind = kind
        self.decoder = decoder
    }

    /// The film was moved to another place.
    func flush() {
        decoder.flush()
    }

    /// [run]'s sound as plain samples ([data] is the run's bytes): its packets decoded in turn and gathered into
    /// buffers of a tenth of a second or more, each stamped with the file's time for its first packet. Nothing from
    /// before [from] is given (after the film is moved, decoding starts a little before where it's wanted from).
    ///
    /// The shape of the sound (its channels and rate) can grow while a track plays: a DTS-HD track gives a few
    /// frames of its plainer core before the whole sound when decoding starts part-way through. When it does, what
    /// this run gave in the smaller shape is let go, a few hundredths of a second.
    func buffers(of run: FilmRun, bytes data: Data, from: CMTime) throws -> [CMSampleBuffer] {
        var out: [CMSampleBuffer] = []
        var gathered: [Float] = []
        var start = CMTime.invalid
        var came = 0

        // The samples gathered so far become a buffer.
        func close() throws {
            defer { gathered.removeAll(keepingCapacity: true) }
            guard !gathered.isEmpty, channels > 0, let format else { return }
            let count = gathered.count / channels
            out.append(try gathered.withUnsafeBytes { try FilmDecodedBuffers.buffer($0, frames: count, format: format, at: start) })
            came += count
        }

        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for s in run.samples {
                let at = Int(s.offset - run.offset)
                guard at >= 0, s.size > 0, at + s.size <= raw.count else { continue }
                packets += 1
                guard let sound = decoder.decode(UnsafeRawBufferPointer(rebasing: raw[at..<(at + s.size)])) else {
                    lost += 1
                    continue
                }
                guard sound.frames > 0, sound.channels > 0, sound.rate > 0, sound.samples.count >= sound.frames * sound.channels else { continue }
                if sound.channels != channels || sound.rate != rate {
                    out.removeAll()
                    gathered.removeAll(keepingCapacity: true)
                    came = 0
                    channels = sound.channels
                    rate = sound.rate
                    format = FilmDecodedBuffers.format(channels: channels, rate: rate)
                }
                // (A decoder that hands sound over late says by how much: its first frame is that much earlier.)
                var time = sound.early > 0 ? CMTimeSubtract(s.shown, CMTime(value: CMTimeValue(sound.early), timescale: CMTimeScale(rate))) : s.shown
                var skip = 0
                if from.isValid, time.isValid, CMTimeCompare(time, from) < 0 {
                    skip = Int((CMTimeSubtract(from, time).seconds * Double(rate)).rounded())
                    if skip >= sound.frames { continue }
                    time = CMTimeAdd(time, CMTime(value: CMTimeValue(skip), timescale: CMTimeScale(rate)))
                }
                if !gathered.isEmpty {
                    let end = CMTimeAdd(start, CMTime(value: CMTimeValue(gathered.count / channels), timescale: CMTimeScale(rate)))
                    if abs(CMTimeSubtract(time, end).seconds) > Self.apart { try close() }
                }
                if gathered.isEmpty { start = time }
                gathered.append(contentsOf: UnsafeBufferPointer(rebasing: sound.samples[(skip * channels)..<(sound.frames * channels)]))
                if Double(gathered.count / channels) >= Double(rate) * Self.least { try close() }
            }
        }
        try close()
        frames += came
        if frames == 0 {
            let length = CMTimeSubtract(run.ends, run.starts).seconds
            if length.isFinite, length > 0 { silent += length }
        }
        return out
    }
}
#endif
