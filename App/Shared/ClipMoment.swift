#if os(macOS)
import Foundation
import AVFoundation
import CoreGraphics
import Vision
import WoodruffKit

/// The Mac that sends the family's alerts: of Google's clip of an event, the frame that shows what the alert is about.
/// Google Home's own alert shows the event's moment, close on who or what was seen. That moment is in the clip, but
/// at no fixed place in it: a clip starts as something first moves, often before anyone is in view, and the frame a
/// second in (where a clip was always looked at) showed an empty drive as often as the visitor. So the clip is looked
/// through, a frame every few tenths of a second, each against how the scene looks through the whole clip
/// (`EventFocus.scene`): for a person, the frame where a figure that moved shows largest and surest; otherwise, or
/// with nobody found, the frame where the most of the picture differs from the scene (`EventFocus.moment`).
enum ClipMoment {
    struct Pick: @unchecked Sendable {
        /// The frame, at most the size asked for.
        var image: CGImage
        /// How far into the clip it is, in seconds: an iPhone that attaches the clip itself takes its small picture
        /// from there.
        var time: Double
        /// Where the picture differs from the scene in that frame, for the framing (`SubjectCrop`); nil when nothing
        /// clearly does.
        var moved: SubjectCrop.Moved?
        /// Why that frame, for the log.
        var why: String
    }

    /// A frame is looked at every this many seconds, and at most this many in all (a long clip: evenly spread).
    private static let every = 0.4
    private static let most = 24
    /// The grid the picture's changes are counted on (as the stream's frames are: `FrameGrabber`).
    private static let gridWidth = 64, gridHeight = 36

    /// The frame of the clip at [file] to alert with ([person]: the alert is about a person), at most [maxSide]
    /// pixels across; nil when the clip can't be read (the caller falls back to the frame a second in).
    static func best(_ file: URL, person: Bool, maxSide: Int) async -> Pick? {
        let asset = AVURLAsset(url: file)
        guard let length = try? await asset.load(.duration).seconds, length.isFinite, length > 0.2 else { return nil }
        var times = Array(stride(from: 0.0, to: length, by: every))
        if times.count > most { times = (0..<most).map { Double($0) * length / Double(most) } }

        // Small frames for the looking: quick to make, and all Vision needs to find a figure.
        let small = AVAssetImageGenerator(asset: asset)
        small.appliesPreferredTrackTransform = true
        small.maximumSize = CGSize(width: 640, height: 640)
        small.requestedTimeToleranceBefore = CMTime(seconds: 0.15, preferredTimescale: 600)
        small.requestedTimeToleranceAfter = CMTime(seconds: 0.15, preferredTimescale: 600)
        var frames: [(time: Double, grey: [UInt8], figures: [(box: CGRect, score: Double)])] = []
        for t in times {
            guard let made = try? await small.image(at: CMTime(seconds: t, preferredTimescale: 600)),
                  let grey = grey(made.image) else { continue }
            let at = made.actualTime.seconds
            frames.append((at.isFinite ? at : t, grey, person ? figures(made.image) : []))
        }
        guard !frames.isEmpty else { return nil }

        // Each frame against the scene: how much differs, and how well a figure standing there shows.
        let scene = EventFocus.scene(frames.map { $0.grey })
        var grids: [[Bool]] = []
        var looks: [EventFocus.Look] = []
        for f in frames {
            let grid = EventFocus.changed(f.grey, since: scene)
            let share = EventFocus.share(grid)
            // (Most of the picture differing is the light, not somebody: no figure counts as moving by it.)
            let moving = share > 0.34 ? [] : f.figures.filter {
                EventFocus.share(of: grid, in: $0.box, width: gridWidth, height: gridHeight) >= 0.1
            }
            grids.append(grid)
            looks.append(EventFocus.Look(time: f.time, changed: share, moving: moving.map { $0.score }.max() ?? 0,
                                         figure: f.figures.map { $0.score }.max() ?? 0))
        }
        guard let chosen = EventFocus.moment(looks, person: person) else { return nil }
        let look = looks[chosen.index]

        // That frame again, full size and exactly there.
        let full = AVAssetImageGenerator(asset: asset)
        full.appliesPreferredTrackTransform = true
        full.maximumSize = CGSize(width: maxSide, height: maxSide)
        full.requestedTimeToleranceBefore = .zero
        full.requestedTimeToleranceAfter = .zero
        guard let image = try? await full.image(at: CMTime(seconds: look.time, preferredTimescale: 600)).image else { return nil }
        let grid = grids[chosen.index]
        let clear = look.changed >= 0.01 && look.changed <= 0.34 && grid.count == gridWidth * gridHeight
        return Pick(image: image, time: look.time,
                    moved: clear ? SubjectCrop.Moved(cells: grid, width: gridWidth, height: gridHeight) : nil,
                    why: chosen.why)
    }

    /// The figures Vision finds in [image], each as a box in shares of the picture, across from its left and down
    /// from its top (as `EventFocus` counts), with how well it shows: the share of the picture it fills times how
    /// sure the finder is, less for one cut off by the picture's side (still walking in, or already leaving).
    private static func figures(_ image: CGImage) -> [(box: CGRect, score: Double)] {
        SubjectCrop.people(VNImageRequestHandler(cgImage: image, options: [:])).map { found in
            let b = found.box
            let fromTop: CGFloat = 1 - b.maxY
            let box = CGRect(x: b.minX, y: fromTop, width: b.width, height: b.height)
            let cut = b.minX < 0.01 || b.maxX > 0.99
            return (box, Double(b.width * b.height) * Double(found.confidence) * (cut ? 0.6 : 1))
        }
    }

    /// [image] as a small grid of brightness values (0 to 255), row by row from the top.
    private static func grey(_ image: CGImage) -> [UInt8]? {
        var px = [UInt8](repeating: 0, count: gridWidth * gridHeight)
        let drawn = px.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: gridWidth, height: gridHeight, bitsPerComponent: 8,
                                      bytesPerRow: gridWidth, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: gridWidth, height: gridHeight))
            return true
        }
        return drawn ? px : nil
    }
}
#endif
