#if os(macOS)
import AVFoundation
import CoreGraphics
import CoreVideo
import ImageIO

/// An event's own short film, made on the Mac Studio from the pictures of the camera's stream it keeps (Google sends
/// no clip for most of the family's cameras, so their events had a photo and nothing to play). It runs from a few
/// seconds before the event to a few after, each picture shown for as long as it was the newest, so things move at
/// the speed they happened: about five pictures every two seconds, enough to see who came and where they went.
enum EventClip {
    /// How far before the event it starts, and how far after it ends.
    static let before: TimeInterval = 3
    static let after: TimeInterval = 7
    /// The fewest pictures worth a film.
    static let fewest = 5
    /// No wider than this (the event's photo stays full size; the film is fetched by a phone).
    private static let maxWidth = 1280
    /// How long a picture stays up when no other follows it.
    private static let hold: Double = 0.4

    /// [frames] (oldest first) as an H.264 film at [file]: nil when there are too few, or it can't be written.
    static func write(_ frames: [FrameGrabber.Moment], to file: URL) async -> URL? {
        guard frames.count >= fewest, let first = frames.first,
              let big = frames.max(by: { $0.width * $0.height < $1.width * $1.height }), big.width >= 64, big.height >= 64 else { return nil }
        // The largest picture's shape (a stream starts small and grows), with even sides as H.264 wants.
        let scale = min(1, Double(maxWidth) / Double(big.width))
        let width = Int(Double(big.width) * scale) / 2 * 2, height = Int(Double(big.height) * scale) / 2 * 2
        try? FileManager.default.removeItem(at: file)
        guard let writer = try? AVAssetWriter(outputURL: file, fileType: .mp4) else { return nil }
        let compression: [String: Any] = [AVVideoAverageBitRateKey: 2_000_000]
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compression,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: attributes)
        guard writer.canAdd(input) else { return nil }
        writer.add(input)
        guard writer.startWriting() else { return nil }
        writer.startSession(atSourceTime: .zero)
        var written = 0
        var last = -1.0
        for frame in frames {
            let seconds = frame.at.timeIntervalSince(first.at)
            guard seconds > last, let buffer = pixels(frame.jpeg, width: width, height: height, pool: adaptor.pixelBufferPool) else { continue }
            // The encoder takes a few at a time.
            var waits = 0
            while !input.isReadyForMoreMediaData, waits < 300 {
                try? await Task.sleep(nanoseconds: 10_000_000)
                waits += 1
            }
            guard input.isReadyForMoreMediaData,
                  adaptor.append(buffer, withPresentationTime: CMTime(seconds: seconds, preferredTimescale: 600)) else { break }
            last = seconds
            written += 1
        }
        input.markAsFinished()
        // The last picture stays up as long as the others did.
        writer.endSession(atSourceTime: CMTime(seconds: max(last, 0) + hold, preferredTimescale: 600))
        await writer.finishWriting()
        guard writer.status == .completed, written >= fewest else {
            try? FileManager.default.removeItem(at: file)
            return nil
        }
        return file
    }

    /// [jpeg] drawn into a [width] by [height] picture for the encoder, whole (black beside it when its shape differs).
    private static func pixels(_ jpeg: Data, width: Int, height: Int, pool: CVPixelBufferPool?) -> CVPixelBuffer? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil), image.width > 0, image.height > 0 else { return nil }
        var made: CVPixelBuffer?
        if let pool { _ = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made) }
        if made == nil {
            let attributes = [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary
            _ = CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes, &made)
        }
        guard let buffer = made, CVPixelBufferGetWidth(buffer) == width, CVPixelBufferGetHeight(buffer) == height else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: info) else { return nil }
        context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let fit = min(Double(width) / Double(image.width), Double(height) / Double(image.height))
        let w = Double(image.width) * fit, h = Double(image.height) * fit
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: (Double(width) - w) / 2, y: (Double(height) - h) / 2, width: w, height: h))
        return buffer
    }
}
#endif
