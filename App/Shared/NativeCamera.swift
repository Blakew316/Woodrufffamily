import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Accelerate
import CoreImage
import os
import WebRTC
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// A camera's live picture played natively (Google's WebRTC library, drawn with Metal) instead of in a web page:
/// quicker to start, smoother, lighter on battery. `LivePlayer` uses it first for each camera and falls back to its
/// web page by itself if the native one doesn't go live, so the worst
/// case is the player as it was.
final class NativeRTC: NSObject, RTCPeerConnectionDelegate, RTCVideoViewDelegate {
    /// One for the whole app (making one is costly).
    static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        #if os(iOS)
        // The iPhone's sound is the app's own speaker-only player: WebRTC's would open the microphone.
        return RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(),
                                        decoderFactory: RTCDefaultVideoDecoderFactory(),
                                        audioDevice: CameraSound.shared)
        #else
        return RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(),
                                        decoderFactory: RTCDefaultVideoDecoderFactory())
        #endif
    }()

    #if os(iOS)
    let view: RTCMTLVideoView = {
        let v = RTCMTLVideoView(frame: .zero)
        v.videoContentMode = .scaleAspectFill
        v.backgroundColor = .black
        v.clipsToBounds = true
        return v
    }()
    #else
    let view = RTCMTLNSVideoView(frame: .zero)
    #endif
    /// The picture's size when it changes (the Mac crops it to fill the tile itself), on the main thread.
    var onSize: ((CGSize) -> Void)?
    private let grabber = FrameGrabber()
    private var pc: RTCPeerConnection?
    private var videoTrack: RTCVideoTrack?
    private var audioTracks: [RTCAudioTrack] = []
    /// This camera's sound (off by default). On the iPhone it's played by `CameraSound`, speaker only.
    var sound = false {
        didSet {
            guard sound != oldValue else { return }
            for a in audioTracks { a.isEnabled = sound }
            #if os(iOS)
            CameraSound.shared.want(sound)
            #endif
        }
    }
    /// "Live", "Starting…", "Reconnecting…" or "failed", on the main thread.
    var onState: ((String) -> Void)?

    private static let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)

    /// Makes the factory (and the video decoders' setup) now, off the main thread, so the first camera opened
    /// doesn't pay for it.
    static func prewarm() {
        DispatchQueue.global(qos: .userInitiated).async { _ = factory }
    }

    override init() {
        super.init()
        view.delegate = self
    }

    func videoView(_ videoView: RTCVideoRenderer, didChangeVideoSize size: CGSize) {
        DispatchQueue.main.async { [weak self] in self?.onSize?(size) }
    }

    /// A fresh connection and its offer for Google (audio, then video, then a data channel, as Google wants).
    func offer() async throws -> String {
        stop()
        let config = RTCConfiguration()
        config.iceServers = [RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"])]
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherContinually
        // Audio, video and data on one connection: fewer to set up before the picture.
        config.bundlePolicy = .maxBundle
        config.rtcpMuxPolicy = .require
        guard let pc = Self.factory.peerConnection(with: config, constraints: Self.constraints, delegate: self) else {
            throw NSError(domain: "NativeRTC", code: 1, userInfo: [NSLocalizedDescriptionKey: "No connection"])
        }
        let rx = RTCRtpTransceiverInit()
        rx.direction = .recvOnly
        _ = pc.addTransceiver(of: .audio, init: rx)
        _ = pc.addTransceiver(of: .video, init: rx)
        _ = pc.dataChannel(forLabel: "data", configuration: RTCDataChannelConfiguration())
        self.pc = pc
        let sdp: RTCSessionDescription = try await withCheckedThrowingContinuation { c in
            pc.offer(for: Self.constraints) { d, e in
                if let d { c.resume(returning: d) } else { c.resume(throwing: e ?? NSError(domain: "NativeRTC", code: 2)) }
            }
        }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            pc.setLocalDescription(sdp) { e in if let e { c.resume(throwing: e) } else { c.resume() } }
        }
        return sdp.sdp
    }

    /// Google's answer.
    func answer(_ sdp: String) async throws {
        guard let pc else { return }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            pc.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: sdp)) { e in
                if let e { c.resume(throwing: e) } else { c.resume() }
            }
        }
    }

    func stop() {
        if let t = videoTrack {
            t.remove(view)
            t.remove(grabber)
        }
        videoTrack = nil
        for a in audioTracks { a.isEnabled = false }
        audioTracks = []
        let old = pc
        pc = nil
        old?.close()
        grabber.clear()
    }

    /// The picture now as a JPEG at most [maxSide] pixels across (for stills, alerts and Vehicle Alerts), made off the
    /// main thread (Vehicle Alerts and the Apple TVs ask about once a second).
    func frameJPEG(maxSide: Int = 480) async -> Data? {
        let g = grabber
        return await Task.detached(priority: .userInitiated) { g.jpeg(maxSide: maxSide) }.value
    }

    #if os(macOS)
    /// The picture's last few seconds, as the Mac that sends the family's alerts keeps them (`FrameGrabber.keepsMoments`).
    func moments(since: Date) -> [FrameGrabber.Moment] { grabber.moments(since: since) }
    #endif

    private func say(_ s: String) {
        DispatchQueue.main.async { [weak self] in self?.onState?(s) }
    }

    // MARK: RTCPeerConnectionDelegate (called on WebRTC's own thread)

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        guard peerConnection === pc else { return }
        for a in stream.audioTracks { DispatchQueue.main.async { [weak self] in self?.attachAudio(a, from: peerConnection) } }
        if let v = stream.videoTracks.first { DispatchQueue.main.async { [weak self] in self?.attach(v, from: peerConnection) } }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        guard peerConnection === pc else { return }
        switch newState {
        case .connected: say("Live")
        case .failed: say("failed")
        case .disconnected: say("Reconnecting…")
        case .closed: break
        default: say("Starting…")
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams mediaStreams: [RTCMediaStream]) {
        guard peerConnection === pc else { return }
        if let a = rtpReceiver.track as? RTCAudioTrack {
            a.isEnabled = false
            DispatchQueue.main.async { [weak self] in self?.attachAudio(a, from: peerConnection) }
        }
        if let v = rtpReceiver.track as? RTCVideoTrack { DispatchQueue.main.async { [weak self] in self?.attach(v, from: peerConnection) } }
    }

    private func attachAudio(_ track: RTCAudioTrack, from connection: RTCPeerConnection) {
        guard connection === pc else { return }
        track.isEnabled = sound
        if !audioTracks.contains(where: { $0 === track }) { audioTracks.append(track) }
    }

    /// On the main thread, and only for the connection still in use.
    private func attach(_ track: RTCVideoTrack, from connection: RTCPeerConnection) {
        guard connection === pc, track !== videoTrack else { return }
        videoTrack?.remove(view)
        videoTrack?.remove(grabber)
        videoTrack = track
        track.add(view)
        track.add(grabber)
    }
}

/// Where a camera's picture goes on screen. It crops the native picture to fill, as the web page's video does (the
/// iPhone's video view does that itself; the Mac's would stretch it).
final class PictureStage: StageView {
    /// The native picture's view, laid out by the stage.
    weak var picture: StageView?
    var videoSize: CGSize = .zero { didSet { if videoSize != oldValue { place() } } }

    #if os(iOS)
    override func layoutSubviews() { super.layoutSubviews(); place() }
    #else
    override func layout() { super.layout(); place() }
    override func resizeSubviews(withOldSize oldSize: NSSize) { super.resizeSubviews(withOldSize: oldSize); place() }
    #endif

    private func place() {
        guard let v = picture else { return }
        #if os(macOS)
        let b = bounds
        guard videoSize.width > 0, videoSize.height > 0, b.width > 0, b.height > 0 else { v.frame = b; return }
        let k = max(b.width / videoSize.width, b.height / videoSize.height)
        let w = videoSize.width * k, h = videoSize.height * k
        v.frame = CGRect(x: b.midX - w / 2, y: b.midY - h / 2, width: w, height: h)
        #else
        v.frame = bounds
        #endif
    }
}

/// Keeps the latest frame of the picture, so a still can be made of it at any moment. On the Mac that sends the
/// family's alerts it also keeps the last few seconds of the picture (`keepsMoments`).
final class FrameGrabber: NSObject, RTCVideoRenderer, @unchecked Sendable {
    private let lock = NSLock()
    private var latest: RTCVideoFrame?

    func setSize(_ size: CGSize) {}
    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame else { return }
        lock.lock(); latest = frame; lock.unlock()
        #if os(macOS)
        keepMoment(frame)
        #endif
    }

    func clear() {
        lock.lock(); latest = nil; lock.unlock()
        #if os(macOS)
        // The last few seconds stay a little (an alert about them can still come just after a reconnect), then go.
        Self.momentQueue.asyncAfter(deadline: .now() + (Self.momentSpan + 1)) { [weak self] in self?.trimMoments() }
        #endif
    }

    var hasFrame: Bool { lock.lock(); defer { lock.unlock() }; return latest != nil }

    /// The latest frame, scaled to fit [maxSide] pixels, as a JPEG (via a plain I420 → RGB conversion).
    private static let log = Logger(subsystem: "com.woodruff.family", category: "camera")
    private static let ci = CIContext(options: [.cacheIntermediates: false])

    func jpeg(maxSide: Int) -> Data? {
        lock.lock(); let frame = latest; lock.unlock()
        guard let frame else { Self.log.notice("native frame: none yet"); return nil }
        guard let full = Self.decoded(frame, maxSide: maxSide) else {
            Self.log.notice("native frame: couldn't convert a \(Int(frame.width))x\(Int(frame.height)) frame")
            return nil
        }
        guard let small = Self.fitted(full, maxSide: maxSide) else { return nil }
        return Self.encoded(small, quality: 0.75)
    }

    /// [frame] as a picture: the hardware decoder's own when it has one (the usual case), scaled down to [maxSide]
    /// before it's turned into a picture (not a full-size copy first, then scaled); otherwise a plain I420 conversion.
    private static func decoded(_ frame: RTCVideoFrame, maxSide: Int) -> CGImage? {
        var picture: CGImage?
        if let cv = frame.buffer as? RTCCVPixelBuffer {
            var image = CIImage(cvPixelBuffer: cv.pixelBuffer)
            let side = max(image.extent.width, image.extent.height)
            if side > CGFloat(maxSide), side > 0 {
                let k = CGFloat(maxSide) / side
                image = image.transformed(by: CGAffineTransform(scaleX: k, y: k))
            }
            let r = image.extent.integral
            if r.width >= 1, r.height >= 1 { picture = ci.createCGImage(image, from: r) }
        }
        if picture == nil {
            let i420 = frame.buffer.toI420()
            let iw = Int(i420.width), ih = Int(i420.height)
            if iw > 0, ih > 0 { picture = rgb(i420, width: iw, height: ih) }
        }
        return picture
    }

    /// [full] at most [maxSide] pixels across (the I420 conversion is full size).
    private static func fitted(_ full: CGImage, maxSide: Int) -> CGImage? {
        let w = full.width, h = full.height
        guard max(w, h) > maxSide else { return full }
        let scale = Double(maxSide) / Double(max(w, h))
        let tw = max(1, Int(Double(w) * scale)), th = max(1, Int(Double(h) * scale))
        guard let ctx = CGContext(data: nil, width: tw, height: th, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(full, in: CGRect(x: 0, y: 0, width: tw, height: th))
        return ctx.makeImage()
    }

    private static func encoded(_ image: CGImage, quality: Double) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    #if os(macOS)
    // MARK: The last few seconds (the Mac that sends the family's alerts)

    /// One picture of the stream as it came: a JPEG about 1280 pixels across, and a 64 × 36 grey copy of it to tell
    /// how much changed between two of them.
    struct Moment: Sendable {
        let at: Date
        let jpeg: Data
        let grey: [UInt8]
    }

    /// Whether the last few seconds are kept: on the Mac that sends the family's alerts, so an alert's picture can be
    /// the moment it happened (`StreamMoment`). `CameraStreams.keepWarm` sets it.
    static var keepsMoments: Bool {
        get { momentsLock.lock(); defer { momentsLock.unlock() }; return momentsOn }
        set { momentsLock.lock(); momentsOn = newValue; momentsLock.unlock() }
    }
    private static let momentsLock = NSLock()
    nonisolated(unsafe) private static var momentsOn = false

    /// How far back they go.
    static let momentSpan: TimeInterval = 12
    /// About two a second, at most about 8 MB per camera.
    private static let momentEvery: TimeInterval = 0.5
    private static let momentBytes = 8_000_000
    private static let momentSide = 1280
    static let greyWidth = 64, greyHeight = 36
    /// Made one at a time, in the background, for every camera.
    private static let momentQueue = DispatchQueue(label: "com.woodruff.family.camera-moments", qos: .utility)

    private var moments: [Moment] = []
    private var lastMoment = Date.distantPast
    private var makingMoment = false

    /// The pictures kept since [since], oldest first.
    func moments(since: Date) -> [Moment] {
        lock.lock(); defer { lock.unlock() }
        return moments.filter { $0.at >= since }
    }

    /// On the stream's own thread, for every frame: one every half second is made into a kept picture in the
    /// background. One waits at a time per camera, so a busy Mac keeps fewer rather than falling behind.
    private func keepMoment(_ frame: RTCVideoFrame) {
        let on = Self.keepsMoments, now = Date()
        lock.lock()
        guard on else {
            if !moments.isEmpty { moments = [] }
            lock.unlock()
            return
        }
        let due = !makingMoment && now.timeIntervalSince(lastMoment) >= Self.momentEvery
        if due { makingMoment = true; lastMoment = now }
        lock.unlock()
        guard due else { return }
        Self.momentQueue.async { [weak self] in
            let made = Self.moment(frame, at: now)
            guard let self else { return }
            self.lock.lock()
            self.makingMoment = false
            if let made { self.moments.append(made) }
            self.trim()
            self.lock.unlock()
        }
    }

    private static func moment(_ frame: RTCVideoFrame, at: Date) -> Moment? {
        guard let full = decoded(frame, maxSide: momentSide), let image = fitted(full, maxSide: momentSide),
              let jpeg = encoded(image, quality: 0.7), let grey = grey(image) else { return nil }
        return Moment(at: at, jpeg: jpeg, grey: grey)
    }

    /// [image] as 64 × 36 brightness values (0–255).
    private static func grey(_ image: CGImage) -> [UInt8]? {
        var px = [UInt8](repeating: 0, count: greyWidth * greyHeight)
        let drawn = px.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: greyWidth, height: greyHeight, bitsPerComponent: 8,
                                      bytesPerRow: greyWidth, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: greyWidth, height: greyHeight))
            return true
        }
        return drawn ? px : nil
    }

    /// Only the last twelve seconds, and at most about 8 MB of them (with the lock held).
    private func trim() {
        let oldest = Date().addingTimeInterval(-Self.momentSpan)
        var bytes = moments.reduce(0) { $0 + $1.jpeg.count }
        while let first = moments.first, first.at < oldest || bytes > Self.momentBytes {
            bytes -= first.jpeg.count
            moments.removeFirst()
        }
    }

    /// A while after the stream stopped: what's too old goes (all of it, once they aren't kept any more).
    private func trimMoments() {
        let on = Self.keepsMoments
        lock.lock()
        if on { trim() } else { moments = [] }
        lock.unlock()
    }
    #endif

    /// I420 (video range, BT.601) to an RGB picture.
    private static func rgb(_ b: RTCI420BufferProtocol, width w: Int, height h: Int) -> CGImage? {
        var info = vImage_YpCbCrToARGB()
        var pixelRange = vImage_YpCbCrPixelRange(Yp_bias: 16, CbCr_bias: 128, YpRangeMax: 235, CbCrRangeMax: 240,
                                                 YpMax: 235, YpMin: 16, CbCrMax: 240, CbCrMin: 16)
        guard vImageConvert_YpCbCrToARGB_GenerateConversion(kvImage_YpCbCrToARGBMatrix_ITU_R_601_4, &pixelRange, &info,
                                                            kvImage420Yp8_Cb8_Cr8, kvImageARGB8888, vImage_Flags(kvImageNoFlags)) == kvImageNoError
        else { return nil }
        var y = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: b.dataY), height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: Int(b.strideY))
        var u = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: b.dataU), height: vImagePixelCount(h / 2), width: vImagePixelCount(w / 2), rowBytes: Int(b.strideU))
        var v = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: b.dataV), height: vImagePixelCount(h / 2), width: vImagePixelCount(w / 2), rowBytes: Int(b.strideV))
        let rowBytes = w * 4
        guard let data = malloc(rowBytes * h) else { return nil }
        var out = vImage_Buffer(data: data, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: rowBytes)
        let map: [UInt8] = [0, 1, 2, 3]
        guard vImageConvert_420Yp8_Cb8_Cr8ToARGB8888(&y, &u, &v, &out, &info, map, 255, vImage_Flags(kvImageNoFlags)) == kvImageNoError else {
            free(data); return nil
        }
        guard let provider = CGDataProvider(dataInfo: nil, data: data, size: rowBytes * h, releaseData: { _, d, _ in free(UnsafeMutableRawPointer(mutating: d)) })
        else { free(data); return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
