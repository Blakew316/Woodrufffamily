#if os(macOS)
import Foundation
import CoreGraphics
import ImageIO
import Vision
import WoodruffKit

/// The Mac that sends the family's alerts: an alert's picture as the moment it happened, the way Google Home's shows
/// what happened. Google's message comes seconds after the event, and by then the camera's live picture often shows
/// nobody (whoever it was has walked on), so the picture is picked from the last few seconds of the stream this Mac
/// keeps (`FrameGrabber.keepsMoments`), from a second before the event (Google's time) to now.
///
/// For a person (and the doorbell): of the frames that show somebody, the one that shows them largest, surest and
/// sharpest (somebody walking is smeared in one frame and crisp in the next). They're looked for where the picture
/// changed first, closer in: a figure across the drive is too small in the whole picture for the finders, which is
/// why "Person seen" so often went out with nobody found. For motion, or with nobody found: of the frames where the
/// most changed, the sharpest there.
enum StreamMoment {
    /// The frame picked, written out for the alert.
    struct Pick: Sendable {
        var file: URL
        /// Why that frame, for the log ("person found").
        var why: String
        /// Where the person is in it, when one was found (shares of the picture, from its top left): the alert's
        /// close-up is framed on that, with no second look for them.
        var subject: CGRect?
        /// Where that frame differs from how the scene looks with nobody passing, when something clearly does: with
        /// nobody found, the close-up is framed there.
        var moved: SubjectCrop.Moved?
    }

    /// The frames looked at start this long before the event.
    private static let lead: TimeInterval = 1
    /// About how far the stream's picture runs behind the camera.
    private static let lag: TimeInterval = 1
    /// Motion: the frames up to this long after the event.
    private static let motionAfter: TimeInterval = 4
    /// At most this many frames are looked at for a person at a time, spread evenly over the stretch.
    private static let looks = 16
    private static let gridWidth = FrameGrabber.greyWidth, gridHeight = FrameGrabber.greyHeight

    /// One frame that shows somebody.
    private struct Seen: Sendable {
        var moment: FrameGrabber.Moment
        /// Where the frame differs from the scene; nil when nothing does, or most of it does (the light).
        var grid: [Bool]?
        /// Where they are (shares of the picture, from its top left).
        var box: CGRect
        /// How well they show: the share of the picture they fill times how sure the finder is, less when the
        /// picture's side cuts them off.
        var shows: Double
        /// How sharp the picture is where they are.
        var sharp: Double
        /// The picture's side cuts them off (still walking in, or already leaving).
        var cut: Bool
        /// They stand where the picture changed (somebody passing, not a coat on a hook taken for a figure).
        var moving: Bool
        /// The frame says where the picture changed at all.
        var known: Bool
        /// They fill a good part of the picture (a visitor at the door): somebody, whether they moved or not.
        var near: Bool { box.width * box.height >= 0.05 }
        /// Who the alert is about, as far as one frame can tell: somebody passing, somebody close, or somebody in a
        /// frame that can't say what changed. A small figure standing where nothing changed, while the picture
        /// changed elsewhere, may be a coat on a hook.
        var likely: Bool { moving || near || !known }
    }

    /// The picture of [camera]'s event that happened at [happened] (Google's time), for its alert titled [title],
    /// written out under [key]; nil when this Mac kept no frames of the camera from then (its stream wasn't live, this
    /// isn't the Mac that sends, or the event is older than what's kept). The looking is done off the main thread.
    @MainActor
    static func pick(camera: String, key: String, happened: Date, title: String) async -> Pick? {
        guard FrameGrabber.keepsMoments, !CameraStreams.shared.moments(camera, since: .distantPast).isEmpty else { return nil }
        let began = Date()
        // Google's clock and this Mac's agree to well within a second; never later than now.
        let at = min(happened, began)
        guard began.timeIntervalSince(at) < FrameGrabber.momentSpan else { return nil }
        let from = at.addingTimeInterval(-lead)
        // The message came before the stream could have shown the moment: that's waited for, two seconds at most.
        let due = at.addingTimeInterval(lag + 1).timeIntervalSinceNow
        if due > 0 { try? await Task.sleep(nanoseconds: UInt64(min(due, 2) * 1_000_000_000)) }
        let kind = SubjectCrop.kind(title)
        let name = NestCameras.shared.cameras.first { $0.id == camera }?.name ?? "camera"
        // All that's kept (the last twelve seconds): what a frame shows is told against how the scene looks through
        // them all.
        var frames = CameraStreams.shared.moments(camera, since: .distantPast)
        if kind == .person {
            // Nobody found while it's only just happened (they may still be coming into view, the stream a little
            // behind): the frames that come next are looked at too, until three seconds after the message at most.
            let until = min(at.addingTimeInterval(6), began.addingTimeInterval(3))
            var looked = Date.distantPast
            var seen: [Seen] = []
            var waited = false
            while true {
                let all = frames
                let new = spread(all.filter { $0.at >= from && $0.at > looked }, looks)
                if !new.isEmpty {
                    let found = await Task.detached(priority: .userInitiated, operation: { people(new, among: all, before: from) }).value
                    seen += found
                    looked = new.last?.at ?? looked
                }
                let more = Date().addingTimeInterval(0.7) < until
                // Somebody passing or close is who the alert is about. Only a small figure standing where nothing
                // changed has the next frames looked at too.
                let good = seen.filter { $0.likely }
                if !good.isEmpty {
                    // Every frame so far cuts them off at the picture's side: the next ones may show them whole
                    // (waited for once).
                    if waited || !more || !good.allSatisfy({ $0.cut }) { break }
                    waited = true
                } else if !more {
                    break
                }
                try? await Task.sleep(nanoseconds: 700_000_000)
                frames = CameraStreams.shared.moments(camera, since: .distantPast)
            }
            let passing = seen.filter { $0.moving }, likely = seen.filter { $0.likely }
            let pool = !passing.isEmpty ? passing : !likely.isEmpty ? likely : seen
            if let i = EventFocus.clearest(pool.map { (shows: $0.shows, sharp: $0.sharp) }), let file = write(pool[i].moment, key: key) {
                let s = pool[i], m = s.moment
                let why = passing.isEmpty ? "person found, standing still" : "person found"
                let size = "\(Int((s.box.width * CGFloat(m.width)).rounded()))x\(Int((s.box.height * CGFloat(m.height)).rounded()))"
                note(name, "\(why), the clearest of \(pool.count) that show them, \(m.width)x\(m.height), the person \(size)", frame: m.at, event: at)
                return Pick(file: file, why: why, subject: s.box, moved: moved(s.grid))
            }
        }
        // Motion, or a person nobody found: of the frames near the event's time where the most changed, the sharpest.
        let all = frames
        guard let chosen = await Task.detached(priority: .userInitiated, operation: { mostChanged(all, from: from, at: at, key: key) }).value
        else { return nil }
        let why = kind == .person ? "no person found" : chosen.changed ? "the most changed" : "nearest its time"
        note(name, "\(why), \(chosen.moment.width)x\(chosen.moment.height)", frame: chosen.moment.at, event: at)
        return Pick(file: chosen.file, why: why, subject: nil, moved: chosen.changed ? moved(chosen.grid) : nil)
    }

    /// Where [camera]'s picture changed around its event at [happened] (Google's time): each frame from a second
    /// before it to a few seconds after, against how the picture looked just before that. nil when this Mac kept no
    /// frames from then, or nothing changed. For the alert's small picture, which zooms in there (`SubjectCrop`),
    /// when its picture isn't one of these frames (a frame that is says where it changed itself: `Pick.moved`).
    @MainActor
    static func moved(camera: String, happened: Date) -> SubjectCrop.Moved? {
        guard FrameGrabber.keepsMoments else { return nil }
        let at = min(happened, Date())
        let from = at.addingTimeInterval(-lead)
        let frames = CameraStreams.shared.moments(camera, since: from.addingTimeInterval(-3))
        guard let earlier = frames.last(where: { $0.at < from }) ?? frames.first else { return nil }
        let near = frames.filter { $0.at >= from && $0.at <= at.addingTimeInterval(motionAfter) }
        // A frame where most of the picture differs is the light changing (night vision coming on), not somebody.
        let grids = near.map { EventFocus.changed($0.grey, since: earlier.grey) }.filter { EventFocus.share($0) <= 0.34 }
        return moved(EventFocus.any(grids))
    }

    private static func moved(_ cells: [Bool]?) -> SubjectCrop.Moved? {
        guard let cells, cells.count == gridWidth * gridHeight, cells.contains(true) else { return nil }
        return SubjectCrop.Moved(cells: cells, width: gridWidth, height: gridHeight)
    }

    // MARK: Looking at the frames (off the main thread)

    /// How the scene looks with nobody passing: each part's middle value through all that's kept (whoever passes is
    /// in any one place for less than half of it). With only a few frames kept (the stream had only just started),
    /// the last frame from before the event, else the first.
    private static func usual(_ frames: [FrameGrabber.Moment], before from: Date) -> [UInt8] {
        if frames.count >= 8 { return EventFocus.scene(frames.map { $0.grey }) }
        return (frames.last { $0.at < from } ?? frames.first)?.grey ?? []
    }

    /// Each of [frames] that shows somebody: where they are, how well they show and how sharp the picture is there.
    /// [all]: everything kept of the camera, for how its scene looks.
    private static func people(_ frames: [FrameGrabber.Moment], among all: [FrameGrabber.Moment], before from: Date) -> [Seen] {
        let scene = usual(all, before: from)
        var out: [Seen] = []
        for m in frames {
            guard let image = decoded(m) else { continue }
            let grid = EventFocus.changed(m.grey, since: scene)
            let share = EventFocus.share(grid)
            // (Most of the picture differing is the light, not somebody: it says nothing of where they are.)
            let cells: [Bool]? = share > 0 && share <= 0.34 ? grid : nil
            let patch = cells.flatMap { EventFocus.patch($0, width: gridWidth, height: gridHeight) }
            guard let who = person(in: image, changed: cells, patch: patch) else { continue }
            let cut = who.box.minX < 0.01 || who.box.maxX > 0.99
            let shows = Double(who.box.width * who.box.height) * who.confidence * (cut ? 0.6 : 1) * fullness(m)
            let moving = cells.map { EventFocus.share(of: $0, in: who.box, width: gridWidth, height: gridHeight) >= 0.1 } ?? false
            out.append(Seen(moment: m, grid: cells, box: who.box, shows: shows, sharp: sharpness(image, in: who.box),
                            cut: cut, moving: moving, known: patch != nil))
        }
        return out
    }

    /// Who the alert is about in [image], with how sure the finder is (a box in shares of the picture, from its top
    /// left); nil with nobody. Looked for closer in first, in the part of the picture round [patch] (where it
    /// changed), then in the whole picture. Of several, the ones standing where the picture changed, as one box.
    private static func person(in image: CGImage, changed cells: [Bool]?, patch: CGRect?) -> (box: CGRect, confidence: Double)? {
        var found: [(box: CGRect, confidence: Double)] = []
        var lookedCloser = false
        if let patch, image.height > 0,
           let part = EventFocus.closer(patch, aspect: Double(image.width) / Double(image.height)),
           let piece = SubjectCrop.crop(image, unit: part) {
            found = figures(piece).map { (box: EventFocus.placed($0.box, in: part), confidence: $0.confidence) }
            lookedCloser = true
        }
        // (Whatever moved was looked at closely and is nobody: the whole picture is only looked over for somebody
        // standing elsewhere, by Vision's figure finder alone. A dozen frames are looked at for one alert.)
        if found.isEmpty { found = figures(image, quickly: lookedCloser) }
        guard let who = EventFocus.subject(found, changed: cells, width: gridWidth, height: gridHeight) else { return nil }
        // As sure as the surest of the figures in that box.
        let sure = found.filter { $0.box.intersects(who) }.map { $0.confidence }.max() ?? 0.3
        return (who, sure)
    }

    /// The people in [image], each with how sure the finder is, as boxes in shares of [image] from its top left:
    /// Vision's figures; with none, Apple's object detector where this Mac has it (it makes out somebody half hidden
    /// by a counter, whom Vision's figure finder wants whole); with none still, faces, with head and shoulders.
    /// [quickly]: Vision's figures only.
    private static func figures(_ image: CGImage, quickly: Bool = false) -> [(box: CGRect, confidence: Double)] {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        var found = SubjectCrop.bodies(handler)
        if found.isEmpty, !quickly { found = VehicleDetector.people(in: image, depth: 0) ?? [] }
        if found.isEmpty, !quickly { found = SubjectCrop.faces(handler) }
        // (Vision measures a box up from the bottom of the picture.)
        return found.map { f in
            let fromTop: CGFloat = 1 - f.box.maxY
            return (box: CGRect(x: f.box.minX, y: fromTop, width: f.box.width, height: f.box.height), confidence: Double(f.confidence))
        }
    }

    /// How sharp [image] is inside [box] (shares of it, from its top left): measured on a grey copy of that part at
    /// its own size, or 240 pixels across when it's larger.
    private static func sharpness(_ image: CGImage, in box: CGRect) -> Double {
        guard let piece = SubjectCrop.crop(image, unit: box) else { return 0 }
        let k = min(1, 240 / Double(max(piece.width, piece.height, 1)))
        let w = max(3, Int(Double(piece.width) * k)), h = max(3, Int(Double(piece.height) * k))
        var px = [UInt8](repeating: 0, count: w * h)
        let drawn = px.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(piece, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return drawn ? EventFocus.sharpness(px, width: w, height: h, in: CGRect(x: 0, y: 0, width: 1, height: 1)) : 0
    }

    /// Of [frames], from a second before the event to a few seconds after: of those where about as much of the
    /// picture differs from the scene as in the one where the most does, the sharpest there (whatever moved is
    /// smeared in one frame and crisp in the next). With nothing clearly changed, the one nearest the event's time as
    /// the stream shows it (a second late). Written out under [key]; nil with no frame from then.
    private static func mostChanged(_ frames: [FrameGrabber.Moment], from: Date, at: Date, key: String)
        -> (file: URL, moment: FrameGrabber.Moment, grid: [Bool]?, changed: Bool)? {
        let near = frames.filter { $0.at >= from && $0.at <= at.addingTimeInterval(motionAfter) }
        guard let first = near.first else { return nil }
        let scene = usual(frames, before: from)
        // What clearly changed in each: under a hundredth of the picture is noise, over a third of it the light
        // (night vision coming on).
        var clear: [(moment: FrameGrabber.Moment, grid: [Bool], share: Double)] = []
        for m in near {
            let grid = EventFocus.changed(m.grey, since: scene)
            let share = EventFocus.share(grid)
            if share >= 0.01, share <= 0.34 { clear.append((moment: m, grid: grid, share: share)) }
        }
        if let most = clear.map({ $0.share }).max() {
            let close = clear.filter { $0.share >= most * 0.6 }
            let scores = close.map { c -> (shows: Double, sharp: Double) in
                let shows = c.share * fullness(c.moment)
                guard let patch = EventFocus.patch(c.grid, width: gridWidth, height: gridHeight), let image = decoded(c.moment) else {
                    return (shows: shows, sharp: 0)
                }
                return (shows: shows, sharp: sharpness(image, in: patch))
            }
            if let i = EventFocus.clearest(scores), let file = write(close[i].moment, key: key) {
                return (file: file, moment: close[i].moment, grid: close[i].grid, changed: true)
            }
        }
        let shown = at.addingTimeInterval(lag)
        func off(_ m: FrameGrabber.Moment) -> TimeInterval { abs(m.at.timeIntervalSince(shown)) }
        let nearest = near.min { off($0) < off($1) } ?? first
        guard let file = write(nearest, key: key) else { return nil }
        return (file: file, moment: nearest, grid: nil, changed: false)
    }

    /// How much of a full-size picture [m] is (1 for 1920 by 1080, a ninth for 640 by 360). A stream sends a small
    /// picture for a while after it starts, and at times when its connection is poor: of two frames that show the
    /// same thing, the one sent at full size has that many times the pixels of it, and is the one to alert with.
    private static func fullness(_ m: FrameGrabber.Moment) -> Double {
        min(1, Double(m.width * m.height) / (1920 * 1080))
    }

    /// [m]'s picture, decoded once and kept (it's looked at several times: closer in, whole, and for its sharpness).
    private static func decoded(_ m: FrameGrabber.Moment) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(m.jpeg as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: true,
                                                           kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    /// At most [n] of [frames], evenly spread from the first to the last.
    private static func spread(_ frames: [FrameGrabber.Moment], _ n: Int) -> [FrameGrabber.Moment] {
        guard frames.count > n, n > 1 else { return frames }
        return (0..<n).map { frames[$0 * (frames.count - 1) / (n - 1)] }
    }

    /// [m]'s picture as the alert's file, beside the event's other pictures (let go with them): the frame's own
    /// bytes, as the stream gave it.
    private static func write(_ m: FrameGrabber.Moment, key: String) -> URL? {
        CameraEventMedia.jpegFile(m.jpeg, name: "frame-moment-\(key)")
    }

    /// In the log: why that frame, and when it came beside the event.
    private static func note(_ camera: String, _ why: String, frame: Date, event: Date) {
        let d = frame.timeIntervalSince(event)
        let when = "\(String(format: "%.1f", abs(d))) s \(d < 0 ? "before" : "after")"
        PushRelay.log.notice("moment for \(camera, privacy: .public): \(why, privacy: .public), the frame that came \(when, privacy: .public) it happened")
    }
}
#endif
