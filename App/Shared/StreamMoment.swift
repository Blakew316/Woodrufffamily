#if os(macOS)
import Foundation
import CoreGraphics
import ImageIO
import Vision
import WoodruffKit

/// The Mac that sends the family's alerts: an alert's picture as the moment it happened, the way Google Home's shows
/// what happened. Google's message comes seconds after the event, and by then the camera's live picture often shows
/// nobody (whoever it was has walked on), so the picture is picked from the last few seconds of the stream this Mac
/// keeps (`FrameGrabber.keepsMoments`), from a second before the event (Google's time) to now: for a person (and the
/// doorbell), the frame where Vision finds the person largest and surest; for motion, the frame near the event's time
/// where the most changed, else the one nearest its time.
enum StreamMoment {
    /// The frame picked, written out for the alert, and why it was (for the log: "person found").
    struct Pick: Sendable {
        var file: URL
        var why: String
    }

    /// The frames looked at start this long before the event.
    private static let lead: TimeInterval = 1
    /// About how far the stream's picture runs behind the camera.
    private static let lag: TimeInterval = 1
    /// Motion: the frames up to this long after the event.
    private static let motionAfter: TimeInterval = 4
    /// At most this many frames are looked at by Vision at a time, spread evenly over the stretch.
    private static let looks = 16

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
        // From a few seconds earlier too: what changed is measured against how it looked just before.
        var frames = CameraStreams.shared.moments(camera, since: from.addingTimeInterval(-3))
        if kind == .person {
            // Nobody found while it's only just happened (they may still be coming into view, the stream a little
            // behind): the frames that come next are looked at too, until three seconds after the message at most.
            let until = min(at.addingTimeInterval(6), began.addingTimeInterval(3))
            var looked = Date.distantPast
            while true {
                let new = frames.filter { $0.at >= from && $0.at > looked }
                if !new.isEmpty, let found = await Task.detached(priority: .userInitiated, operation: { largestPerson(new, key: key) }).value {
                    note(name, "person found", frame: found.at, event: at)
                    return Pick(file: found.file, why: "person found")
                }
                looked = new.last?.at ?? looked
                guard Date().addingTimeInterval(0.7) < until else { break }
                try? await Task.sleep(nanoseconds: 700_000_000)
                frames = CameraStreams.shared.moments(camera, since: from.addingTimeInterval(-3))
            }
        }
        // Motion, or a person Vision didn't find: the frame near the event's time where the most changed.
        let all = frames
        guard let chosen = await Task.detached(priority: .userInitiated, operation: { mostChanged(all, from: from, at: at, key: key) }).value
        else { return nil }
        let why = kind == .person ? "no person found" : chosen.changed ? "the most changed" : "nearest its time"
        note(name, why, frame: chosen.at, event: at)
        return Pick(file: chosen.file, why: why)
    }

    /// Where [camera]'s picture changed around its event at [happened] (Google's time): each frame from a second
    /// before it to a few seconds after, against how the picture looked just before that. nil when this Mac kept no
    /// frames from then, or nothing changed. For the alert's small picture, which zooms in there (`SubjectCrop`).
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
        let cells = EventFocus.any(grids)
        guard cells.count == FrameGrabber.greyWidth * FrameGrabber.greyHeight, cells.contains(true) else { return nil }
        return SubjectCrop.Moved(cells: cells, width: FrameGrabber.greyWidth, height: FrameGrabber.greyHeight)
    }

    /// Of [frames], the one where Vision finds the largest, surest person (the share of the picture they fill, times
    /// how sure it is), written out under [key].
    private static func largestPerson(_ frames: [FrameGrabber.Moment], key: String) -> (file: URL, at: Date)? {
        var best: (moment: FrameGrabber.Moment, score: Double)?
        for m in spread(frames, looks) {
            guard let source = CGImageSourceCreateWithData(m.jpeg as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
            let people = SubjectCrop.people(VNImageRequestHandler(cgImage: image, options: [:]))
            let score = people.map { Double($0.box.width * $0.box.height) * Double($0.confidence) }.max() ?? 0
            if score > (best?.score ?? 0) { best = (m, score) }
        }
        guard let best, let file = write(best.moment, key: key) else { return nil }
        return (file, best.moment.at)
    }

    /// Of [frames], the one from a second before the event to a few seconds after where the most of the picture
    /// differs from how it looked just before; with nothing clearly changed, the one nearest the event's time as the
    /// stream shows it (a second late). Written out under [key]; nil with no frame from then.
    private static func mostChanged(_ frames: [FrameGrabber.Moment], from: Date, at: Date, key: String) -> (file: URL, at: Date, changed: Bool)? {
        let near = frames.filter { $0.at >= from && $0.at <= at.addingTimeInterval(motionAfter) }
        guard let first = near.first else { return nil }
        let earlier = frames.last { $0.at < from } ?? first
        let shown = at.addingTimeInterval(lag)
        func off(_ m: FrameGrabber.Moment) -> TimeInterval { abs(m.at.timeIntervalSince(shown)) }
        var best: (moment: FrameGrabber.Moment, share: Double)?
        for m in near {
            let share = changed(m.grey, since: earlier.grey)
            // As much changed (the whole picture, when a light comes on): the one nearer the event's time.
            if let b = best, share < b.share || (share == b.share && off(m) >= off(b.moment)) { continue }
            best = (m, share)
        }
        // Under one percent of the picture is noise, not something moving.
        let moved = best.flatMap { $0.share >= 0.01 ? $0.moment : nil }
        let nearest = near.min { off($0) < off($1) } ?? first
        let chosen = moved ?? nearest
        guard let file = write(chosen, key: key) else { return nil }
        return (file, chosen.at, moved != nil)
    }

    /// The share of the picture that changed between two grey copies: cells more than about a tenth brighter or darker.
    private static func changed(_ a: [UInt8], since b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var n = 0
        for i in a.indices where abs(Int(a[i]) - Int(b[i])) > 24 { n += 1 }
        return Double(n) / Double(a.count)
    }

    /// At most [n] of [frames], evenly spread from the first to the last.
    private static func spread(_ frames: [FrameGrabber.Moment], _ n: Int) -> [FrameGrabber.Moment] {
        guard frames.count > n, n > 1 else { return frames }
        return (0..<n).map { frames[$0 * (frames.count - 1) / (n - 1)] }
    }

    /// [m]'s picture as the alert's file, beside the event's other pictures (let go with them).
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
