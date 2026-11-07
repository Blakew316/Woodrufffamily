import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Accelerate
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

    /// The picture now as a JPEG at most [maxSide] pixels across (for stills, alerts and Vehicle Alerts).
    func frameJPEG(maxSide: Int = 480) -> Data? { grabber.jpeg(maxSide: maxSide) }

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

/// Keeps the latest frame of the picture, so a still can be made of it at any moment.
final class FrameGrabber: NSObject, RTCVideoRenderer {
    private let lock = NSLock()
    private var latest: RTCVideoFrame?

    func setSize(_ size: CGSize) {}
    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame else { return }
        lock.lock(); latest = frame; lock.unlock()
    }

    func clear() { lock.lock(); latest = nil; lock.unlock() }

    var hasFrame: Bool { lock.lock(); defer { lock.unlock() }; return latest != nil }

    /// The latest frame, scaled to fit [maxSide] pixels, as a JPEG (via a plain I420 → RGB conversion).
    func jpeg(maxSide: Int) -> Data? {
        lock.lock(); let frame = latest; lock.unlock()
        guard let frame else { return nil }
        let i420 = frame.buffer.toI420()
        let w = Int(i420.width), h = Int(i420.height)
        guard w > 0, h > 0, let full = Self.rgb(i420, width: w, height: h) else { return nil }
        let scale = min(1, Double(maxSide) / Double(max(w, h)))
        let tw = max(1, Int(Double(w) * scale)), th = max(1, Int(Double(h) * scale))
        guard let ctx = CGContext(data: nil, width: tw, height: th, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(full, in: CGRect(x: 0, y: 0, width: tw, height: th))
        guard let small = ctx.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, small, [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

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
