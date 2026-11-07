#if os(iOS)
import Foundation
import AVFoundation
import AudioToolbox
import WebRTC

/// The cameras' sound on the iPhone, played by the app itself for Google's WebRTC library: output only (Apple's plain
/// RemoteIO speaker unit, its input left off), so the microphone is never opened and no permission is asked for.
/// WebRTC mixes every camera whose sound is on; the speaker runs only while at least one is.
final class CameraSound: NSObject, RTCAudioDevice {
    static let shared = CameraSound()

    private let lock = NSLock()
    private var unit: AudioUnit?
    private var getPlayout: RTCAudioDeviceGetPlayoutDataBlock?
    private var delegateRef: RTCAudioDeviceDelegate?
    private var initialized = false
    private var playoutReady = false
    private var playing = false          // WebRTC asked for playout
    private var recordingReady = false
    private var recordingOn = false      // never opens the microphone; only answers WebRTC
    private var speakerOn = false
    /// Cameras whose sound is on (see `want`).
    private var wanted = 0
    private var observing = false

    private static let rate: Double = 48_000

    // MARK: Asked for by the cameras (main thread)

    /// One more (or one fewer) camera with its sound on.
    func want(_ on: Bool) {
        lock.lock()
        wanted = max(0, wanted + (on ? 1 : -1))
        lock.unlock()
        update()
    }

    // MARK: RTCAudioDevice

    var deviceInputSampleRate: Double { Self.rate }
    var inputIOBufferDuration: TimeInterval { 0.01 }
    var inputNumberOfChannels: Int { 1 }
    var inputLatency: TimeInterval { 0 }
    var deviceOutputSampleRate: Double { Self.rate }
    var outputIOBufferDuration: TimeInterval { AVAudioSession.sharedInstance().ioBufferDuration }
    var outputNumberOfChannels: Int { 1 }
    var outputLatency: TimeInterval { AVAudioSession.sharedInstance().outputLatency }

    var isInitialized: Bool { lock.lock(); defer { lock.unlock() }; return initialized }
    var isPlayoutInitialized: Bool { lock.lock(); defer { lock.unlock() }; return playoutReady }
    var isPlaying: Bool { lock.lock(); defer { lock.unlock() }; return playing }
    var isRecordingInitialized: Bool { lock.lock(); defer { lock.unlock() }; return recordingReady }
    var isRecording: Bool { lock.lock(); defer { lock.unlock() }; return recordingOn }

    func initialize(with delegate: RTCAudioDeviceDelegate) -> Bool {
        lock.lock()
        delegateRef = delegate
        getPlayout = delegate.getPlayoutData
        initialized = true
        lock.unlock()
        observeInterruptions()
        return true
    }

    func terminateDevice() -> Bool {
        lock.lock()
        playing = false; playoutReady = false; recordingOn = false; recordingReady = false
        initialized = false
        lock.unlock()
        update()
        lock.lock()
        getPlayout = nil
        delegateRef = nil
        lock.unlock()
        return true
    }

    func initializePlayout() -> Bool {
        lock.lock(); playoutReady = true; lock.unlock()
        return true
    }

    func startPlayout() -> Bool {
        lock.lock(); playing = true; lock.unlock()
        update()
        return true
    }

    func stopPlayout() -> Bool {
        lock.lock(); playing = false; lock.unlock()
        update()
        return true
    }

    // Recording: the cameras only receive. These keep WebRTC content without ever touching the microphone.
    func initializeRecording() -> Bool { lock.lock(); recordingReady = true; lock.unlock(); return true }
    func startRecording() -> Bool { lock.lock(); recordingOn = true; lock.unlock(); return true }
    func stopRecording() -> Bool { lock.lock(); recordingOn = false; lock.unlock(); return true }

    // MARK: The speaker

    /// Runs the speaker while WebRTC is playing and a camera's sound is on; stops it (and lets other audio back) otherwise.
    private func update() {
        lock.lock()
        let should = playing && wanted > 0 && getPlayout != nil
        let isOn = speakerOn
        lock.unlock()
        if should && !isOn { startSpeaker() } else if !should && isOn { stopSpeaker() }
    }

    private func startSpeaker() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setActive(true)
        guard let u = unit ?? makeUnit() else { return }
        unit = u
        if AudioOutputUnitStart(u) == noErr {
            lock.lock(); speakerOn = true; lock.unlock()
        }
    }

    private func stopSpeaker() {
        if let u = unit { AudioOutputUnitStop(u) }
        lock.lock(); speakerOn = false; lock.unlock()
    }

    /// Apple's RemoteIO unit, output only: 16-bit mono at 48 kHz in (WebRTC's playout format); the unit converts.
    private func makeUnit() -> AudioUnit? {
        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_RemoteIO,
                                             componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else { return nil }
        var made: AudioUnit?
        guard AudioComponentInstanceNew(comp, &made) == noErr, let u = made else { return nil }
        var off: UInt32 = 0
        AudioUnitSetProperty(u, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &off, UInt32(MemoryLayout<UInt32>.size))
        var format = AudioStreamBasicDescription(mSampleRate: Self.rate, mFormatID: kAudioFormatLinearPCM,
                                                 mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
                                                 mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1,
                                                 mBitsPerChannel: 16, mReserved: 0)
        AudioUnitSetProperty(u, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format,
                             UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        var callback = AURenderCallbackStruct(inputProc: cameraSoundRender, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        AudioUnitSetProperty(u, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback,
                             UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        guard AudioUnitInitialize(u) == noErr else { AudioComponentInstanceDispose(u); return nil }
        return u
    }

    /// The speaker's request for the next samples: WebRTC fills them, or silence.
    fileprivate func render(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, _ time: UnsafePointer<AudioTimeStamp>,
                            _ bus: UInt32, _ frames: UInt32, _ data: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        lock.lock(); let get = getPlayout; lock.unlock()
        if let get, get(flags, time, Int(bus), frames, data) == noErr { return noErr }
        for b in UnsafeMutableAudioBufferListPointer(data) { if let p = b.mData { memset(p, 0, Int(b.mDataByteSize)) } }
        flags.pointee.insert(.unitRenderAction_OutputIsSilence)
        return noErr
    }

    /// A phone call or Siri stops the speaker; it comes back when they're done.
    private func observeInterruptions() {
        DispatchQueue.main.async { [self] in
            guard !observing else { return }
            observing = true
            NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
                guard let self, let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      let kind = AVAudioSession.InterruptionType(rawValue: raw) else { return }
                if kind == .began {
                    self.lock.lock(); self.speakerOn = false; self.lock.unlock()
                } else {
                    self.update()
                }
            }
        }
    }
}

private func cameraSoundRender(_ ref: UnsafeMutableRawPointer, _ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                               _ time: UnsafePointer<AudioTimeStamp>, _ bus: UInt32, _ frames: UInt32,
                               _ data: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    guard let data else { return noErr }
    return Unmanaged<CameraSound>.fromOpaque(ref).takeUnretainedValue().render(flags, time, bus, frames, data)
}
#endif
