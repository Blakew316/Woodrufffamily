#if canImport(AVFoundation)
import AVFoundation
import CoreMedia

/// Where the app's own player gets a film's bytes from.
public protocol FilmBytes: AnyObject {
    /// [count] bytes from [offset]. [lane]: which of the player's readers asks (its picture 0, its sound 1, its
    /// subtitles 2): each reads straight on from its own place, so what's fetched ahead for one must not be thrown
    /// away for another. Answers on any thread; with fewer bytes than asked only where the file ends.
    func read(from offset: Int64, count: Int, lane: Int, then: @escaping (Result<Data, Error>) -> Void)
    /// Nothing asked for so far is wanted any more (the film was moved to another place, or closed).
    func forgetReads()
}

/// The app's own film player.
///
/// Apple's player reads a film by asking for whichever sample comes next in time. For a film whose sound and picture
/// are stored far apart that means hopping between the two some hundreds of times a second, and it stops every
/// twenty seconds or so. This one reads each track straight on from its own place, as the Android TVs' player does,
/// and hands each sample to Apple's own decoders: the picture to a display layer, the sound to a sound renderer,
/// both on one clock.
///
/// - Apple's reader of the file's index says where each sample is and when it plays (`FilmTrackReader`).
/// - The bytes come from `FilmBytes` (the app's Drive stream), a run at a time.
/// - A few seconds of each track are kept ready. The film starts once enough is ready, waits when it has run out
///   (`FilmBuffering`), and goes on when there's enough again.
///
/// Everything inside runs on one queue of its own; what it says to the app (`onChange`, `onWords`) is said on the
/// main thread.
public final class FilmPlayer: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        /// Not opened yet.
        case idle
        /// It should be playing, and is waiting for enough of the film.
        case waiting
        case playing
        case paused
        /// Played to its end.
        case ended
        /// It can't go on (`failure` says why).
        case failed
    }

    public enum Failure: Error, Equatable {
        /// Neither a picture nor a sound track that can be played.
        case nothingToPlay
        /// The file's index can't be walked.
        case noIndex
        /// Fewer bytes arrived than the film has there.
        case short
        /// Apple's decoder gave up, more than once.
        case decoder
    }

    public struct Picture {
        public let format: CMFormatDescription
        /// The codec's four letters ("hvc1").
        public let codec: String
        public let width: Int
        public let height: Int
        public let framesASecond: Float
    }

    public struct Sound: Equatable, Sendable {
        public let id: CMPersistentTrackID
        /// The track's language as the file gives it ("eng"), if it does.
        public let language: String?
        public let codec: String
        public let channels: Int
        /// It can be played here: by Apple's decoders, or by one the app has given (`FilmSoundDecoders`).
        public let playable: Bool
        /// Apple has no decoder for it: the app's own decodes it (DTS, Dolby TrueHD).
        public let decodedHere: Bool
    }

    /// A subtitle track of the film's own.
    public struct Words: Equatable, Sendable {
        public let id: CMPersistentTrackID
        public let language: String?
    }

    public struct Chapter: Equatable, Sendable {
        public let title: String
        /// Where it starts, in seconds.
        public let start: Double
    }

    /// How it went, for the Macs' log.
    public struct Notes: Sendable {
        /// Seconds the file took to open, and from being asked to start to playing.
        public var opened = 0.0
        public var started: Double?
        /// Times it stopped for want of data once it had started (not counting being moved), and the seconds that took.
        public var waits = 0
        public var waited = 0.0
        /// Times it was moved to another place.
        public var jumps = 0
        /// Runs read for the picture, the sound and the subtitles, their bytes, and the longest one took to arrive.
        public var reads = [0, 0, 0]
        public var bytes: Int64 = 0
        public var slowest = 0.0
        /// Reads asked for again after the connection failed, and times a decoder was started afresh.
        public var again = 0
        public var mended = 0
        /// Of those, the picture's decoder and the sound's, and what the last one to give up said (its error, or that
        /// it had let go of what it held).
        public var mendedPicture = 0
        public var mendedSound = 0
        public var mendWhy: String?
        /// Pieces of sound whose time in the file wasn't exactly where the piece before them ended, set end to end
        /// (`joined`), and the furthest any was out, in seconds.
        public var joined = 0
        public var joinedBy = 0.0
        /// Sound decoded by the app's own decoder (`FilmSoundDecoders`): its kind ("dts", "truehd"), the packets
        /// given to the decoder and those nothing could be made of, the frames that came out and their shape; and
        /// whether a track was given up on because nothing came of it at all.
        public var decodedKind: String?
        public var decodedPackets = 0
        public var decodedLost = 0
        public var decodedFrames = 0
        public var decodedChannels = 0
        public var decodedRate = 0
        public var decodingGaveUp = false
    }

    /// What the film is, once it's open.
    public struct Film {
        public var picture: Picture?
        public var sounds: [Sound] = []
        public var words: [Words] = []
        public var chapters: [Chapter] = []
        /// The sound track playing, and the subtitle track showing (nil: none).
        public var sound: CMPersistentTrackID?
        public var showing: CMPersistentTrackID?
        /// The film's length in seconds.
        public var length = 0.0
    }

    // MARK: Settings

    /// Seconds of each track a film starts with, and with after it has had to wait.
    public var enough = 2.5
    public var enoughAfterWaiting = 5.0
    /// With this little of either track left, it waits.
    public var low = 0.25
    /// Seconds of each track kept ready past where the film is.
    public var keep = 8.0

    /// Said on the main thread when its state, its tracks or its chapters change.
    public var onChange: (() -> Void)?
    /// Said on the main thread with the subtitle line to show now (nil: none).
    public var onWords: ((String?) -> Void)?

    // MARK: Inside

    private struct Loaded {
        let track: AVAssetTrack
        let shift: CMTime
        let format: CMFormatDescription?
        let playable: Bool
        /// (Sound) the kind the app's own decoder is asked for ("dts", "truehd"); nil for sound Apple decodes.
        var ours: String? = nil
    }

    /// One track being played: its reader, and what has been read of it and not yet handed to its decoder.
    private final class Pipe {
        let lane: Int
        let sound: Bool
        let reader: FilmTrackReader
        let format: CMFormatDescription?
        var ready: [CMSampleBuffer] = []
        /// A run is being fetched; the decoder has been told to ask when it wants more.
        var reading = false
        var requesting = false
        /// The film's time everything read so far reaches.
        var madeUpTo = CMTime.invalid
        /// After the film was moved: nothing before this is shown or heard, and (the picture) samples that show
        /// before this are left out: frames ahead of the one decoding starts from.
        var showFrom = CMTime.zero
        var dropBefore = CMTime.invalid
        /// Times the run being fetched has been asked for again.
        var tries = 0
        /// (Sound) where the sound handed over so far ends, counted from the sound itself: the next piece starts here.
        var soundEnd = CMTime.invalid
        /// (Sound Apple has no decoder for) the app's own decoder for this track, and what it has made of it.
        var decoding: FilmSoundDecoding?

        init(lane: Int, sound: Bool, reader: FilmTrackReader, format: CMFormatDescription?) {
            self.lane = lane
            self.sound = sound
            self.reader = reader
            self.format = format
        }

        var allRead: Bool { reader.ended && !reading }
        var allHanded: Bool { allRead && ready.isEmpty }
    }

    private let asset: AVAsset
    private let bytes: FilmBytes
    private let queue = DispatchQueue(label: "woodruff.film-player", qos: .userInitiated)
    private let clock = AVSampleBufferRenderSynchronizer()
    private let soundRenderer = AVSampleBufferAudioRenderer()
    private var pictureRenderer: AVSampleBufferVideoRenderer?
    private var timer: DispatchSourceTimer?
    private var flushWatch: NSObjectProtocol?

    private var picturePipe: Pipe?
    private var soundPipe: Pipe?
    private var soundTracks: [CMPersistentTrackID: Loaded] = [:]
    private var wordTracks: [CMPersistentTrackID: Loaded] = [:]

    private var opened = false
    private var closed = false
    private var ended = false
    /// It has been told where to start: nothing of the film is fetched before that (a film left off part-way must
    /// not fetch its beginning first).
    private var placed = false
    /// It should be playing; the clock is stopped for want of data.
    private var wanted = false
    private var waiting = false
    /// Goes up each time the film is moved or closed: what was asked for before then is no longer wanted.
    private var generation = 0
    private var why: Error?
    private var startAsked: Date?
    private var waitBegan: Date?
    private var hasWaited = false
    private var lastMend = Date.distantPast

    /// The track the film's chapters are in (their names, each at the time it starts), until they've been read; and
    /// which try at reading them is the current one (a move to another place drops what was asked for).
    private var chapterTrack: Loaded?
    private var chapterTurn = 0

    private var wordsReader: FilmTrackReader?
    private var wordsReading = false
    private var wordsUpTo = CMTime.invalid
    private var lines: [(start: Double, end: Double, text: String)] = []
    private var saying: String?

    /// What other threads may read.
    private let lock = NSLock()
    private var sharedState = State.idle
    private var sharedFilm = Film()
    private var sharedNotes = Notes()
    private var sharedFailure: Error?
    private var sharedLine: String?

    private static let subtitleKind: FourCharCode = 0x74783367   // "tx3g"

    public init(asset: AVAsset, bytes: FilmBytes) {
        self.asset = asset
        self.bytes = bytes
        clock.addRenderer(soundRenderer)
        // The sound output changed (another speaker, another format): the renderer let go of what it had, and wants
        // the sound again from where it says.
        flushWatch = NotificationCenter.default.addObserver(forName: .AVSampleBufferAudioRendererWasFlushedAutomatically,
                                                            object: soundRenderer, queue: nil) { [weak self] note in
            let at = (note.userInfo?[AVSampleBufferAudioRendererFlushTimeKey] as? NSValue)?.timeValue
            self?.queue.async { self?.soundLetGo(at) }
        }
    }

    deinit {
        if let flushWatch { NotificationCenter.default.removeObserver(flushWatch) }
        timer?.cancel()
    }

    // MARK: What the app reads

    public var state: State { lock.lock(); defer { lock.unlock() }; return sharedState }
    public var film: Film { lock.lock(); defer { lock.unlock() }; return sharedFilm }
    public var notes: Notes { lock.lock(); defer { lock.unlock() }; return sharedNotes }
    /// Why it can't go on, when its state is `failed`.
    public var failure: Error? { lock.lock(); defer { lock.unlock() }; return sharedFailure }
    /// The subtitle line showing now, if one is.
    public var line: String? { lock.lock(); defer { lock.unlock() }; return sharedLine }
    /// Where the film is, in seconds.
    public var time: Double {
        let now = clock.currentTime().seconds
        return now.isFinite ? max(0, now) : 0
    }
    /// The film's length in seconds (0 until it's open).
    public var length: Double { film.length }

    // MARK: Opening

    /// Reads what the film is: its picture, its sound and subtitle tracks, its length. Nothing of the film itself is
    /// fetched yet.
    public func open() async throws {
        let began = Date()
        let tracks = try await asset.load(.tracks)
        let duration = try await asset.load(.duration)
        var film = Film()
        film.length = duration.isValid && duration.seconds.isFinite ? duration.seconds : 0
        var picture: Loaded?
        var sounds: [CMPersistentTrackID: Loaded] = [:]
        var words: [CMPersistentTrackID: Loaded] = [:]
        var firstEnabled: CMPersistentTrackID?
        for track in tracks {
            let formats = (try? await track.load(.formatDescriptions)) ?? []
            let segments = (try? await track.load(.segments)) ?? []
            let shift = Self.shift(segments)
            guard let format = formats.first, (try? await track.load(.canProvideSampleCursors)) ?? false else { continue }
            let kind = Self.letters(CMFormatDescriptionGetMediaSubType(format))
            if track.mediaType == .video {
                guard picture == nil, (try? await track.load(.isDecodable)) ?? true else { continue }
                let size = CMVideoFormatDescriptionGetDimensions(format)
                let rate = (try? await track.load(.nominalFrameRate)) ?? 0
                film.picture = Picture(format: format, codec: kind, width: Int(size.width), height: Int(size.height), framesASecond: rate)
                picture = Loaded(track: track, shift: shift, format: format, playable: true)
            } else if track.mediaType == .audio {
                // DTS and Dolby TrueHD: Apple has no decoder for them (whatever it says of an "mp4a" track that
                // holds DTS), so they play when the app has given one, and not otherwise.
                let ours = FilmSoundDecoders.kind(of: format)
                let playable: Bool
                if let ours {
                    playable = FilmSoundDecoders.make?(ours) != nil
                } else {
                    playable = (try? await track.load(.isDecodable)) ?? true
                }
                let channels = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee.mChannelsPerFrame ?? 0
                let language = try? await track.load(.languageCode)
                // (A track that names its kind with a number is told by the kind: "dts", not "mp4a".)
                let named = ours.map { kind.hasPrefix("dts") || kind == "mlpa" ? kind : $0 } ?? kind
                film.sounds.append(Sound(id: track.trackID, language: language, codec: named, channels: Int(channels),
                                         playable: playable, decodedHere: playable && ours != nil))
                sounds[track.trackID] = Loaded(track: track, shift: shift, format: format, playable: playable, ours: playable ? ours : nil)
                if firstEnabled == nil, playable, (try? await track.load(.isEnabled)) ?? true { firstEnabled = track.trackID }
            } else if track.mediaType == .subtitle, CMFormatDescriptionGetMediaSubType(format) == Self.subtitleKind {
                let language = try? await track.load(.languageCode)
                film.words.append(Words(id: track.trackID, language: language))
                words[track.trackID] = Loaded(track: track, shift: shift, format: format, playable: true)
            }
        }
        // The sound the file itself puts first, else the first that can be played.
        film.sound = firstEnabled ?? film.sounds.first(where: { $0.playable })?.id
        guard picture != nil || film.sound != nil else { throw Failure.nothingToPlay }
        // The film's chapters: a track of their names that one of the others points at.
        var chapters: Loaded?
        for track in tracks where chapters == nil {
            guard let lists = try? await track.loadAssociatedTracks(ofType: .chapterList) else { continue }
            for list in lists where list.mediaType == .text || list.mediaType == .subtitle {
                let segments = (try? await list.load(.segments)) ?? []
                chapters = Loaded(track: list, shift: Self.shift(segments), format: nil, playable: true)
                break
            }
        }

        let took = Date().timeIntervalSince(began)
        let chosen = film.sound.flatMap { sounds[$0] }
        try queue.sync {
            if let picture {
                guard let reader = FilmTrackReader(track: picture.track, shift: picture.shift) else { throw Failure.noIndex }
                picturePipe = Pipe(lane: 0, sound: false, reader: reader, format: picture.format)
            }
            if let chosen {
                guard let reader = FilmTrackReader(track: chosen.track, shift: chosen.shift) else { throw Failure.noIndex }
                let pipe = Pipe(lane: 1, sound: true, reader: reader, format: chosen.format)
                pipe.decoding = decoding(for: chosen)
                soundPipe = pipe
            }
            soundTracks = sounds
            wordTracks = words
            chapterTrack = chapters
            opened = true
            lock.lock()
            sharedFilm = film
            sharedNotes.opened = took
            lock.unlock()
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + 0.1, repeating: 0.1)
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            timer = t
            publish()
        }
    }

    /// Reads the film's chapters (their names are in the film itself, a few hundred bytes of it): asked for a
    /// moment after the film has been placed, so they never hold up its start.
    private func chaptersSoon() {
        guard chapterTrack != nil else { return }
        chapterTurn += 1
        let turn = chapterTurn
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, turn == self.chapterTurn, !self.closed, let from = self.chapterTrack,
                  let reader = FilmTrackReader(track: from.track, shift: from.shift) else { return }
            var runs: [FilmRun] = []
            while runs.count < 64, let run = reader.next(most: 1 << 20, gap: 64 << 10, limit: 480, seconds: .infinity) {
                runs.append(run)
            }
            self.readChapters(runs, at: 0, found: [], turn: turn)
        }
    }

    private func readChapters(_ runs: [FilmRun], at i: Int, found: [Chapter], turn: Int) {
        guard turn == chapterTurn, !closed else { return }
        guard i < runs.count else {
            // All read: they're known from now on.
            chapterTrack = nil
            guard !found.isEmpty else { return }
            lock.lock()
            sharedFilm.chapters = found.sorted { $0.start < $1.start }
            lock.unlock()
            publish()
            return
        }
        let run = runs[i]
        guard run.length > 0 else {
            readChapters(runs, at: i + 1, found: found, turn: turn)
            return
        }
        bytes.read(from: run.offset, count: run.length, lane: 2) { [weak self] result in
            self?.queue.async {
                guard let self else { return }
                var found = found
                if case .success(let data) = result, data.count >= run.length {
                    for sample in run.samples where sample.size > 0 {
                        let from = Int(sample.offset - run.offset)
                        let part = data.subdata(in: (data.startIndex + from)..<(data.startIndex + from + sample.size))
                        let start = sample.shown.seconds
                        found.append(Chapter(title: FilmText.subtitle(part) ?? "", start: start.isFinite ? max(0, start) : 0))
                    }
                }
                self.readChapters(runs, at: i + 1, found: found, turn: turn)
            }
        }
    }

    /// What's added to a track's own times to get the film's clock: where the file says the track's first stretch
    /// goes in the film, less where that stretch starts in the track.
    static func shift(_ segments: [AVAssetTrackSegment]) -> CMTime {
        guard let first = segments.first(where: { !$0.isEmpty }) else { return .zero }
        return CMTimeSubtract(first.timeMapping.target.start, first.timeMapping.source.start)
    }

    /// A format's four letters ("hvc1", "ec-3").
    static func letters(_ code: FourCharCode) -> String {
        var text = ""
        for shift in [24, 16, 8, 0] {
            let byte = UInt8((code >> UInt32(shift)) & 0xFF)
            guard byte >= 0x20, byte < 0x7F else { return String(format: "0x%08X", code) }
            text.append(Character(UnicodeScalar(byte)))
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    // MARK: What the app asks

    /// The picture goes to [renderer] (a display layer's). Asked once, before the film starts.
    public func show(on renderer: AVSampleBufferVideoRenderer) {
        queue.async {
            guard self.pictureRenderer == nil else { return }
            self.pictureRenderer = renderer
            self.clock.addRenderer(renderer)
        }
    }

    /// The sound off, or on again (the Mac's film check plays in silence).
    public func mute(_ off: Bool) {
        soundRenderer.isMuted = off
    }

    /// Starts the film from [seconds] in: it plays as soon as enough of it is ready.
    public func start(at seconds: Double) {
        queue.async {
            self.wanted = true
            self.startAsked = Date()
            self.jump(to: seconds)
        }
    }

    public func play() {
        queue.async {
            guard self.opened, !self.closed, self.why == nil else { return }
            if self.ended {
                // Played out: Play starts it over.
                self.wanted = true
                self.jump(to: 0)
                return
            }
            guard !self.wanted else { return }
            self.wanted = true
            self.waiting = true
            self.publish()
            self.judge()
        }
    }

    public func pause() {
        queue.async {
            guard self.opened, !self.closed, self.wanted else { return }
            self.wanted = false
            self.settleWait()
            self.waiting = false
            self.clock.rate = 0
            self.publish()
        }
    }

    /// Moves the film to [seconds] in. It goes on playing (or stays paused) from there.
    public func seek(to seconds: Double) {
        queue.async { self.jump(to: seconds) }
    }

    /// Plays the sound track [id].
    public func choose(sound id: CMPersistentTrackID) {
        queue.async {
            guard self.opened, !self.closed else { return }
            self.take(sound: id)
        }
    }

    /// The sound track [id] plays from where the film is. False when it can't be played.
    @discardableResult
    private func take(sound id: CMPersistentTrackID) -> Bool {
        guard let loaded = soundTracks[id], loaded.playable,
              let reader = FilmTrackReader(track: loaded.track, shift: loaded.shift) else { return false }
        let pipe = Pipe(lane: 1, sound: true, reader: reader, format: loaded.format)
        pipe.decoding = decoding(for: loaded)
        // (Sound Apple can't decode never goes to its decoder: with no decoder of the app's, it isn't taken.)
        guard loaded.ours == nil || pipe.decoding != nil else { return false }
        if let old = soundPipe, old.requesting { soundRenderer.stopRequestingMediaData() }
        soundPipe = pipe
        reset(pipe, to: clock.currentTime())
        lock.lock()
        sharedFilm.sound = id
        lock.unlock()
        fill(pipe)
        publish()
        return true
    }

    /// The app's own decoder for [loaded]'s sound, when it's sound Apple has none for.
    private func decoding(for loaded: Loaded) -> FilmSoundDecoding? {
        guard let kind = loaded.ours, let decoder = FilmSoundDecoders.make?(kind) else { return nil }
        return FilmSoundDecoding(kind: kind, decoder: decoder)
    }

    /// This many seconds of the film's sound have been through the app's own decoder and nothing came of any of it.
    /// (After a film is moved a decoder may give nothing until the sound next starts afresh: a fraction of a second.)
    private static let giveUpDecodingAfter = 1.5

    /// The sound track being decoded here can't be decoded after all (nothing came of `giveUpDecodingAfter` seconds
    /// of it). It's marked as sound that can't be played, and the film's first sound that can takes over, as it did
    /// before there was a decoder for this one; with none, the film goes on without sound.
    private func giveUpDecoding(_ pipe: Pipe) {
        guard pipe === soundPipe else { return }
        lock.lock()
        let id = sharedFilm.sound
        lock.unlock()
        guard let id, let loaded = soundTracks[id] else { return }
        soundTracks[id] = Loaded(track: loaded.track, shift: loaded.shift, format: loaded.format, playable: false, ours: nil)
        lock.lock()
        sharedFilm.sounds = sharedFilm.sounds.map {
            $0.id == id ? Sound(id: $0.id, language: $0.language, codec: $0.codec, channels: $0.channels, playable: false, decodedHere: false) : $0
        }
        let others = sharedFilm.sounds.filter { $0.playable }.map(\.id)
        sharedNotes.decodingGaveUp = true
        lock.unlock()
        for other in others where take(sound: other) { return }
        if pipe.requesting { soundRenderer.stopRequestingMediaData() }
        soundRenderer.flush()
        soundPipe = nil
        lock.lock()
        sharedFilm.sound = nil
        lock.unlock()
        publish()
    }

    /// Shows the subtitle track [id], or none.
    public func choose(words id: CMPersistentTrackID?) {
        queue.async {
            guard self.opened, !self.closed else { return }
            self.wordsReader = id.flatMap { self.wordTracks[$0] }.flatMap { FilmTrackReader(track: $0.track, shift: $0.shift) }
            self.resetWords(to: self.clock.currentTime())
            self.lock.lock()
            self.sharedFilm.showing = self.wordsReader == nil ? nil : id
            self.lock.unlock()
            self.publish()
        }
    }

    /// The film is over for this player: everything stops and is let go.
    public func close() {
        queue.async {
            guard !self.closed else { return }
            self.settleWait()
            self.closed = true
            self.generation += 1
            self.timer?.cancel()
            self.timer = nil
            self.bytes.forgetReads()
            self.clock.rate = 0
            for pipe in [self.picturePipe, self.soundPipe].compactMap({ $0 }) {
                if pipe.requesting { self.renderer(for: pipe)?.stopRequestingMediaData() }
                pipe.requesting = false
                pipe.ready.removeAll()
            }
            self.soundRenderer.flush()
            self.pictureRenderer?.flush()
        }
    }

    // MARK: Moving

    private func jump(to seconds: Double) {
        guard opened, !closed, why == nil else { return }
        settleWait()
        generation += 1
        bytes.forgetReads()
        let length = film.length
        // Never the very end: the last half second, so there's a frame to show.
        let most = length > 1 ? length - 0.5 : max(0, length)
        let target = CMTime(seconds: max(0, min(seconds.isFinite ? seconds : 0, most)), preferredTimescale: 600)
        ended = false
        placed = true
        hasWaited = false
        lock.lock()
        sharedNotes.jumps += 1
        lock.unlock()
        let pipes = [picturePipe, soundPipe].compactMap { $0 }
        for pipe in pipes { reset(pipe, to: target) }
        clock.setRate(0, time: target)
        waiting = wanted
        resetWords(to: target)
        for pipe in pipes { fill(pipe) }
        // (What was asked for before this move was dropped, the chapters with it if they were being read.)
        chaptersSoon()
        publish()
    }

    /// [pipe] starts again from [target]: its decoder is emptied, and its reader goes to where decoding can start.
    private func reset(_ pipe: Pipe, to target: CMTime) {
        if let renderer = renderer(for: pipe) {
            if pipe.requesting { renderer.stopRequestingMediaData() }
            renderer.flush()
        }
        pipe.requesting = false
        pipe.ready.removeAll()
        pipe.reading = false
        pipe.madeUpTo = .invalid
        pipe.tries = 0
        pipe.soundEnd = .invalid
        pipe.decoding?.flush()
        pipe.showFrom = target
        pipe.dropBefore = .invalid
        if target.seconds <= 0.05 {
            pipe.reader.rewind()
        } else if let from = pipe.reader.seek(to: target, back: pipe.sound ? 2 : 0) {
            if !pipe.sound { pipe.dropBefore = from }
        } else {
            pipe.reader.rewind()
        }
    }

    private func renderer(for pipe: Pipe) -> AVQueuedSampleBufferRendering? {
        pipe.sound ? soundRenderer : pictureRenderer
    }

    /// The picture's pipe when there's somewhere to show it.
    private var showing: Pipe? { pictureRenderer == nil ? nil : picturePipe }

    // MARK: Reading

    /// Reads [pipe]'s next run when less than `keep` seconds of it are ready (or less than it takes to start).
    private func fill(_ pipe: Pipe) {
        guard opened, placed, !closed, why == nil, !pipe.reading, !pipe.reader.ended else { return }
        guard pipe.sound || pictureRenderer != nil else { return }
        let want = max(keep, waiting ? (hasWaited ? enoughAfterWaiting : enough) : 0)
        if pipe.madeUpTo.isValid, CMTimeSubtract(pipe.madeUpTo, clock.currentTime()).seconds >= want { return }
        // (TrueHD comes 1,200 packets to the second: a run of sound decoded here may hold more packets, not more time.)
        guard let run = pipe.reader.next(most: pipe.sound ? 1 << 20 : 4 << 20, gap: 256 << 10,
                                         limit: pipe.decoding == nil ? 480 : 4096, seconds: 2) else { return }
        pipe.reading = true
        ask(run, for: pipe)
    }

    private func ask(_ run: FilmRun, for pipe: Pipe) {
        let turn = generation, asked = Date()
        guard run.length > 0 else {
            queue.async { [weak self] in self?.arrived(run, .success(Data()), for: pipe, turn: turn, asked: asked) }
            return
        }
        bytes.read(from: run.offset, count: run.length, lane: pipe.lane) { [weak self] result in
            self?.queue.async { self?.arrived(run, result, for: pipe, turn: turn, asked: asked) }
        }
    }

    private func arrived(_ run: FilmRun, _ result: Result<Data, Error>, for pipe: Pipe, turn: Int, asked: Date) {
        // Asked for before the film was moved, or for a sound track no longer playing: not wanted.
        guard turn == generation, !closed, pipe === picturePipe || pipe === soundPipe else { return }
        switch result {
        case .failure(let error):
            // The connection, not the film: asked for again a few times, a little later each time.
            if (error as NSError).domain == NSURLErrorDomain, pipe.tries < 6 {
                pipe.tries += 1
                lock.lock()
                sharedNotes.again += 1
                lock.unlock()
                queue.asyncAfter(deadline: .now() + Double(pipe.tries)) { [weak self] in
                    guard let self, turn == self.generation, !self.closed, pipe === self.picturePipe || pipe === self.soundPipe else { return }
                    self.ask(run, for: pipe)
                }
                return
            }
            pipe.reading = false
            fail(error)
        case .success(let data):
            pipe.reading = false
            guard data.count >= run.length else { fail(Failure.short); return }
            pipe.tries = 0
            let took = Date().timeIntervalSince(asked)
            lock.lock()
            sharedNotes.reads[min(pipe.lane, 2)] += 1
            sharedNotes.bytes += Int64(run.length)
            sharedNotes.slowest = max(sharedNotes.slowest, took)
            lock.unlock()
            do {
                if let decoding = pipe.decoding {
                    pipe.ready.append(contentsOf: joined(try decoding.buffers(of: run, bytes: data, from: pipe.showFrom), on: pipe))
                    lock.lock()
                    sharedNotes.decodedKind = decoding.kind
                    sharedNotes.decodedPackets = decoding.packets
                    sharedNotes.decodedLost = decoding.lost
                    sharedNotes.decodedFrames = decoding.frames
                    sharedNotes.decodedChannels = decoding.channels
                    sharedNotes.decodedRate = decoding.rate
                    lock.unlock()
                    if decoding.frames == 0, decoding.silent >= Self.giveUpDecodingAfter {
                        giveUpDecoding(pipe)
                        return
                    }
                } else if pipe.sound {
                    pipe.ready.append(contentsOf: joined(try FilmSampleBuffers.together(run, bytes: data, format: pipe.format, from: pipe.showFrom), on: pipe))
                } else {
                    let all = try FilmSampleBuffers.each(of: run, bytes: data, format: pipe.format)
                    for (sample, buffer) in zip(run.samples, all) {
                        // Frames that show before the one decoding started from can't be decoded: left out.
                        if pipe.dropBefore.isValid, CMTimeCompare(sample.shown, pipe.dropBefore) < 0 { continue }
                        // Between there and where the film is wanted from: decoded, not shown.
                        if CMTimeCompare(sample.shown, pipe.showFrom) < 0 { FilmSampleBuffers.hide(buffer) }
                        pipe.ready.append(buffer)
                    }
                }
            } catch {
                fail(error)
                return
            }
            let end = run.ends
            if end.isValid, !pipe.madeUpTo.isValid || CMTimeCompare(end, pipe.madeUpTo) > 0 { pipe.madeUpTo = end }
            hand(pipe)
            fill(pipe)
            judge()
        }
    }

    /// A piece of sound whose time in the file is within this of where the piece before it ended is set to start
    /// exactly there; further out than this is a real break in the sound, and is left as the file has it.
    private static let joinWithin = 0.05

    /// [pieces] of sound, each starting exactly where the one before it ended.
    ///
    /// A film can keep its sound in many small pieces (The Odyssey: twelve a second, four packets each). Each piece is
    /// handed over with the time the file gives it. Where that time is a hair off where the piece before really ends
    /// (the file's times are rounded), the sound is taken up afresh at every piece, and comes out broken up: on, off,
    /// on, off. The Android TVs' player plays such pieces end to end and only heeds the file's times when they jump;
    /// so does this. How long a piece lasts is counted from the sound itself (its packets, the frames in each, its
    /// rate). The pieces set this way are counted for the log.
    private func joined(_ pieces: [CMSampleBuffer], on pipe: Pipe) -> [CMSampleBuffer] {
        var out: [CMSampleBuffer] = []
        out.reserveCapacity(pieces.count)
        for piece in pieces {
            let count = CMSampleBufferGetNumSamples(piece)
            let stamped = CMSampleBufferGetPresentationTimeStamp(piece)
            guard count > 0, stamped.isValid, let format = CMSampleBufferGetFormatDescription(piece),
                  let basic = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
                  basic.mSampleRate >= 1, basic.mFramesPerPacket > 0 else {
                // Its length can't be counted: left as it is, and the next piece starts the count again.
                pipe.soundEnd = .invalid
                out.append(piece)
                continue
            }
            let each = CMTime(value: CMTimeValue(basic.mFramesPerPacket), timescale: CMTimeScale(basic.mSampleRate.rounded()))
            let length = CMTimeMultiply(each, multiplier: Int32(count))
            // (One cut at its start, the first after the film was moved, keeps the time it was cut for.)
            let cut = CMGetAttachment(piece, key: kCMSampleBufferAttachmentKey_TrimDurationAtStart, attachmentModeOut: nil) != nil
            var start = stamped
            var kept = piece
            if pipe.soundEnd.isValid, !cut {
                let off = CMTimeSubtract(stamped, pipe.soundEnd).seconds
                if off != 0, off.isFinite, abs(off) < Self.joinWithin {
                    var timing = CMSampleTimingInfo(duration: each, presentationTimeStamp: pipe.soundEnd, decodeTimeStamp: .invalid)
                    var copy: CMSampleBuffer?
                    if CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: piece,
                                                             sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                                             sampleBufferOut: &copy) == noErr, let copy {
                        kept = copy
                        start = pipe.soundEnd
                        lock.lock()
                        sharedNotes.joined += 1
                        sharedNotes.joinedBy = max(sharedNotes.joinedBy, abs(off))
                        lock.unlock()
                    }
                }
            }
            pipe.soundEnd = CMTimeAdd(start, length)
            out.append(kept)
        }
        return out
    }

    /// Has [pipe]'s decoder ask for what's ready whenever it wants more.
    private func hand(_ pipe: Pipe) {
        guard let renderer = renderer(for: pipe), !pipe.requesting, !pipe.ready.isEmpty else { return }
        pipe.requesting = true
        renderer.requestMediaDataWhenReady(on: queue) { [weak self, weak pipe] in
            guard let self, let pipe else { return }
            self.pour(pipe, into: renderer)
        }
    }

    private func pour(_ pipe: Pipe, into renderer: AVQueuedSampleBufferRendering) {
        guard !closed, pipe === picturePipe || pipe === soundPipe else {
            renderer.stopRequestingMediaData()
            pipe.requesting = false
            return
        }
        while renderer.isReadyForMoreMediaData, !pipe.ready.isEmpty {
            renderer.enqueue(pipe.ready.removeFirst())
        }
        if pipe.ready.isEmpty {
            // Nothing to give just now: it's told to ask again once more is ready (`hand`).
            renderer.stopRequestingMediaData()
            pipe.requesting = false
        }
        fill(pipe)
    }

    // MARK: Starting, waiting, ending

    private func tick() {
        guard opened, !closed else { return }
        for pipe in [picturePipe, soundPipe].compactMap({ $0 }) {
            hand(pipe)
            fill(pipe)
        }
        judge()
        words()
    }

    private func ahead(_ pipe: Pipe?, _ now: CMTime) -> Double? {
        guard let pipe else { return nil }
        guard pipe.madeUpTo.isValid else { return 0 }
        let seconds = CMTimeSubtract(pipe.madeUpTo, now).seconds
        return seconds.isFinite ? seconds : 0
    }

    /// Starts the clock once enough is ready, stops it when what's ready has run out, and ends the film when all of
    /// it has played.
    private func judge() {
        guard opened, !closed, why == nil, !ended else { return }
        let now = clock.currentTime()
        mend(now)
        let pipes = [showing, soundPipe].compactMap { $0 }
        // Played out: everything has been read and the clock is past the last of it.
        if placed, !pipes.isEmpty, pipes.allSatisfy({ $0.allRead }) {
            var last = CMTime.invalid
            for pipe in pipes where pipe.madeUpTo.isValid {
                if !last.isValid || CMTimeCompare(pipe.madeUpTo, last) > 0 { last = pipe.madeUpTo }
            }
            if !last.isValid || CMTimeCompare(now, last) >= 0 {
                settleWait()
                ended = true
                wanted = false
                waiting = false
                clock.rate = 0
                publish()
                return
            }
        }
        guard wanted else { return }
        let move = FilmBuffering.move(waiting: waiting, picture: ahead(showing, now), sound: ahead(soundPipe, now),
                                      pictureDone: showing?.allRead ?? true, soundDone: soundPipe?.allRead ?? true,
                                      enough: hasWaited ? enoughAfterWaiting : enough, low: low)
        switch move {
        case .stay:
            break
        case .go:
            settleWait()
            waiting = false
            clock.rate = 1
            if let asked = startAsked {
                startAsked = nil
                lock.lock()
                if sharedNotes.started == nil { sharedNotes.started = Date().timeIntervalSince(asked) }
                lock.unlock()
            }
            publish()
        case .wait:
            waiting = true
            hasWaited = true
            waitBegan = Date()
            clock.rate = 0
            lock.lock()
            sharedNotes.waits += 1
            lock.unlock()
            publish()
        }
    }

    /// A wait for data is over (or cut short): its seconds are counted.
    private func settleWait() {
        guard let began = waitBegan else { return }
        waitBegan = nil
        lock.lock()
        sharedNotes.waited += Date().timeIntervalSince(began)
        lock.unlock()
    }

    /// A decoder that has given up, or lost what it held (the app was put away and brought back): it's emptied and
    /// started again from where the film is. Not more often than every two seconds; after five times, the film stops.
    private func mend(_ now: CMTime) {
        guard Date().timeIntervalSince(lastMend) > 2 else { return }
        var broken: [Pipe] = []
        var picture = 0, sound = 0
        var said: String?
        if let renderer = pictureRenderer, let pipe = picturePipe,
           renderer.requiresFlushToResumeDecoding || renderer.status == .failed {
            broken.append(pipe)
            picture = 1
            said = "the picture’s " + (renderer.status == .failed ? Self.words(renderer.error) : "let go of what it held")
        }
        if let pipe = soundPipe, soundRenderer.status == .failed {
            broken.append(pipe)
            sound = 1
            said = "the sound’s " + Self.words(soundRenderer.error)
        }
        guard !broken.isEmpty else { return }
        lastMend = Date()
        lock.lock()
        sharedNotes.mended += 1
        sharedNotes.mendedPicture += picture
        sharedNotes.mendedSound += sound
        if let said { sharedNotes.mendWhy = said }
        let times = sharedNotes.mended
        lock.unlock()
        guard times <= 5 else {
            fail(pictureRenderer?.error ?? soundRenderer.error ?? Failure.decoder)
            return
        }
        for pipe in broken {
            reset(pipe, to: now)
            fill(pipe)
        }
    }

    /// An error in a few words for the log: where it's from and its number ("AVFoundationErrorDomain -11821").
    private static func words(_ error: Error?) -> String {
        guard let error else { return "gave up without saying why" }
        let ns = error as NSError
        return "gave up (\(ns.domain) \(ns.code))"
    }

    /// The sound renderer let go of what it held from [at] on (the output changed): the sound is read again from there.
    private func soundLetGo(_ at: CMTime?) {
        guard opened, !closed, let pipe = soundPipe else { return }
        let from = at.flatMap { $0.isValid ? $0 : nil } ?? clock.currentTime()
        reset(pipe, to: from)
        fill(pipe)
    }

    private func fail(_ error: Error) {
        guard why == nil else { return }
        settleWait()
        why = error
        wanted = false
        waiting = false
        clock.rate = 0
        publish()
    }

    private func publish() {
        let state: State
        if why != nil {
            state = .failed
        } else if ended {
            state = .ended
        } else if !opened {
            state = .idle
        } else if wanted {
            state = waiting ? .waiting : .playing
        } else {
            state = .paused
        }
        lock.lock()
        sharedState = state
        sharedFailure = why
        lock.unlock()
        let tell = onChange
        DispatchQueue.main.async { tell?() }
    }

    // MARK: Subtitles

    private func resetWords(to target: CMTime) {
        lines = []
        wordsReading = false
        wordsUpTo = .invalid
        if let reader = wordsReader {
            if target.seconds <= 0.05 { reader.rewind() } else if reader.seek(to: target) == nil { reader.rewind() }
        }
        say(nil)
    }

    /// Reads the subtitle track a little ahead of the film (ten seconds: where the picture's bytes have been
    /// fetched already), and says which line shows now.
    private func words() {
        guard let reader = wordsReader, why == nil else { return }
        let now = clock.currentTime().seconds
        if !wordsReading, !reader.ended, !(wordsUpTo.isValid && wordsUpTo.seconds > now + 10),
           let run = reader.next(most: 256 << 10, gap: 0, limit: 16, seconds: 30) {
            wordsReading = true
            let turn = generation
            let take: (Result<Data, Error>) -> Void = { [weak self] result in
                self?.queue.async {
                    guard let self, turn == self.generation, !self.closed, reader === self.wordsReader else { return }
                    self.wordsReading = false
                    let end = run.ends
                    if end.isValid { self.wordsUpTo = end }
                    guard case .success(let data) = result, data.count >= run.length else { return }
                    self.lock.lock()
                    self.sharedNotes.reads[2] += 1
                    self.lock.unlock()
                    for sample in run.samples where sample.size > 0 {
                        let from = Int(sample.offset - run.offset)
                        let part = data.subdata(in: (data.startIndex + from)..<(data.startIndex + from + sample.size))
                        guard let text = FilmText.subtitle(part) else { continue }
                        let start = sample.shown.seconds
                        self.lines.append((start: start, end: start + sample.lasts.seconds, text: text))
                    }
                }
            }
            if run.length > 0 {
                bytes.read(from: run.offset, count: run.length, lane: 2, then: take)
            } else {
                take(.success(Data()))
            }
        }
        lines.removeAll { $0.end < now - 1 }
        say(lines.first { $0.start <= now && now < $0.end }?.text)
    }

    private func say(_ line: String?) {
        guard line != saying else { return }
        saying = line
        lock.lock()
        sharedLine = line
        lock.unlock()
        let tell = onWords
        DispatchQueue.main.async { tell?(line) }
    }
}
#endif
