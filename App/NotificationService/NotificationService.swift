import UserNotifications
import CoreGraphics
import WidgetKit

/// Runs the moment a camera or doorbell push arrives (Woodruff can be closed): puts the picture of the event in the
/// notification, as Google Home does. The small picture the Mac sent in the push goes in at once, so the alert always
/// has one; then, at the same time, Google's clip or snapshot and the Mac Studio's full-size picture of the event are
/// asked for, and the first to come replaces it. Four seconds at most for that when the alert has the Mac's small
/// picture (twenty when it has none): the alert never waits longer than that.
final class NotificationService: UNNotificationServiceExtension, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((UNNotificationContent) -> Void)?
    private var content: UNMutableNotificationContent?
    /// What the alert's picture is now (for Camera Alerts' "Last alert from the Mac").
    private var what = "No picture came in time"
    /// The camera's line on the TVs & Cameras and doorbell widgets: they reload as the alert is shown.
    private var widget: WidgetLine?
    /// The alert's picture as a still for the widgets, once a better one than the push's has come.
    private var betterStill: Data?

    private struct WidgetLine {
        var camera: String
        var name: String
        var doorbell: Bool
    }

    /// How long the full picture is waited for (iOS allows about 30 seconds in all) when the alert has no picture yet.
    private static let budget: TimeInterval = 20
    /// And when it already has the Mac's small picture: the alert shows within a few seconds. (Away from home the Mac
    /// Studio's full picture can't be reached at all, and every alert was held the whole twenty seconds for it.)
    private static let quick: TimeInterval = 4

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        let c = (request.content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        lock.lock(); handler = contentHandler; content = c; lock.unlock()
        let info = request.content.userInfo
        guard let camera = info["camera"] as? String, !camera.isEmpty else { finish(noting: false); return }
        func text(_ k: String) -> String? { (info[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        let event = text("event"), clip = text("clip"), thumb = text("thumb")
        let key = text("key") ?? request.identifier
        // The app doesn't show its own copy of this alert now, whatever happens to this one.
        CameraEventMedia.notePushKey(key)
        let macFocus = CameraEventMedia.focus(text("f"))
        // How far into Google's clip the Mac's picture of the event is from, when it's a frame of the clip.
        let clipTime = text("t").flatMap { Double($0) }
        let title = request.content.title

        // The Mac's small picture first: whatever happens next, the alert has it.
        let thumbFile = thumb.flatMap { CameraEventMedia.thumbnailFile($0) }
        let thumbStill = thumbFile.flatMap { try? Data(contentsOf: $0) }
        if let thumbFile {
            if let a = CameraEventMedia.attachment(thumbFile) {
                set([a], "The Mac’s small picture attached")
            }
            // The attachment is a copy of it: this one isn't needed after.
            try? FileManager.default.removeItem(at: thumbFile)
        } else if thumb != nil {
            what = "No picture: the Mac’s small picture couldn’t be read"
        }
        // The hard stop: the alert goes with what it has. Set before anything is written to the shared container, so a
        // write held up there can't hold the alert back.
        let wait = hasPicture ? Self.quick : Self.budget
        let deadline = Date().addingTimeInterval(wait)
        DispatchQueue.global().asyncAfter(deadline: .now() + wait + 1) { [weak self] in self?.finish() }
        // The widgets' line has the event and the push's picture at once (they reload when the alert is shown): the
        // doorbell's Live Activity, which the Mac starts a moment after this push, shows this ring, not an older one.
        let line = Self.widgetLine(camera: camera, name: request.content.body, ring: text("ring") != nil)
        PhoneWidgetShare.saveCamera(id: line.camera, name: line.name, doorbell: line.doorbell, jpeg: thumbStill, event: Self.tag(title))
        lock.lock(); widget = line; lock.unlock()

        Task {
            // The Mac Studio's full picture of the event (the moment it picked, with where its subject is), else
            // Google's clip or snapshot. With no picture from the Mac in the push, whichever comes first.
            let got = await CameraEventMedia.firstPicture(camera: camera, eventID: event, clipURL: clip, key: key, deadline: deadline,
                                                          prefersMac: thumb != nil)
            if let got {
                let file = got.file
                let isClip = file.pathExtension == "mp4"
                // Where who or what was seen is (the Mac says for its own picture, and for the frame of Google's clip
                // it picked; otherwise Vision finds it here), and the widget's still, from one decode. Motion: the
                // whole picture.
                var look: (still: Data?, focus: CGRect?) = (nil, nil)
                var at: Double?
                if got.fromMac {
                    look = (await CameraEventMedia.still(file), macFocus)
                } else if isClip, let clipTime {
                    look = (await CameraEventMedia.still(file, at: clipTime), macFocus)
                    at = clipTime
                } else {
                    look = await CameraEventMedia.stillAndFocus(file, title: title)
                }
                // The alert's picture: close on who or what was seen, cut from the full picture (as Google Home's
                // is); with nothing to close in on, the picture or the clip as it is.
                var shown = file
                if let focus = look.focus, let close = await CameraEventMedia.closeUp(file, focus: focus, at: at) { shown = close }
                let showsClip = shown.pathExtension == "mp4"
                let source = got.fromMac ? "The Mac’s full picture" : isClip ? "Google’s clip" : "Google’s snapshot"
                if let a = CameraEventMedia.attachment(shown, at: at) {
                    var all = [a]
                    // A clip also carries a still: Apple Watch shows a picture with the alert, never a video. Its own
                    // frame, else the Mac's small picture of the moment (a clip never takes the alert's picture away).
                    if showsClip, let s = Self.stillAttachment(look.still ?? thumbStill) { all.append(s) }
                    self.set(all, shown == file ? "\(source) attached" : "\(source), close on its subject, attached")
                    if let still = look.still { self.keep(still: still) }
                } else if isClip, let still = look.still, let s = Self.stillAttachment(still) {
                    // The clip itself couldn't go in: its picture does.
                    self.set([s], "The clip’s picture attached")
                    self.keep(still: still)
                }
            }
            // Nothing of the moment came, and the push had no picture (the Mac had none): the camera's latest picture
            // on this iPhone, whatever its age, as the Mac itself does when nothing better comes.
            if !self.hasPicture, let latest = Self.latestPicture(camera: camera), let a = CameraEventMedia.attachment(latest) {
                self.set([a], "The camera’s latest picture attached")
            }
            self.finish()
        }
    }

    /// The alert's picture, unless it has already gone.
    private func set(_ attachments: [UNNotificationAttachment], _ note: String) {
        lock.lock()
        if handler != nil, let c = content {
            c.attachments = attachments
            what = note
        }
        lock.unlock()
    }

    /// Whether the alert has a picture yet.
    private var hasPicture: Bool {
        lock.lock(); defer { lock.unlock() }
        return !(content?.attachments.isEmpty ?? true)
    }

    /// A better still for the widgets than the push's, unless the alert has already gone.
    private func keep(still: Data) {
        lock.lock()
        if handler != nil { betterStill = still }
        lock.unlock()
    }

    /// [jpeg] as the alert's still, the picture Apple Watch shows (nil without one).
    private static func stillAttachment(_ jpeg: Data?) -> UNNotificationAttachment? {
        guard let jpeg else { return nil }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        guard (try? jpeg.write(to: file)) != nil else { return nil }
        defer { try? FileManager.default.removeItem(at: file) }
        return CameraEventMedia.attachment(file, identifier: "still")
    }

    /// The camera's latest picture the widgets have (kept by the app and by earlier alerts), if there is one.
    private static func latestPicture(camera: String) -> URL? {
        guard let name = PhoneWidgetShare.loadCameras().first(where: { $0.id == camera })?.file,
              let url = PhoneWidgetShare.artURL(name), FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// The camera as the widgets show it: a ring always means the doorbell; otherwise the app's own doorbell flag when
    /// it has written one (a camera named "Back Door" isn't taken for the doorbell, nor a doorbell without "door" in
    /// its name lost), else what the push's name says.
    private static func widgetLine(camera: String, name: String, ring: Bool) -> WidgetLine {
        let known = PhoneWidgetShare.loadCameras().first { $0.id == camera }
        return WidgetLine(camera: camera, name: name.isEmpty ? (known?.name ?? "Camera") : name,
                          doorbell: ring || (known?.doorbell ?? name.localizedCaseInsensitiveContains("door")))
    }

    /// The camera's red tag on the widgets.
    private static func tag(_ title: String) -> String {
        let plain = title.replacingOccurrences(of: "Test: ", with: "")
        return plain.localizedCaseInsensitiveContains("person") ? "Person"
            : plain.localizedCaseInsensitiveContains("motion") ? "Motion"
            : plain.localizedCaseInsensitiveContains("door") ? "Ring" : "Event"
    }

    /// The TVs & Cameras and doorbell widgets, even with Woodruff closed: the alert's picture as the camera's latest
    /// still when a better one than the push's came (the push's, and the red tag, went in when it arrived), and only
    /// the widgets showing this camera reload (the Mac Studio's push reloads them again shortly, in case iOS put this
    /// reload off).
    private static func updateWidgets(_ line: WidgetLine, still: Data?) {
        if let still { PhoneWidgetShare.saveCamera(id: line.camera, name: line.name, doorbell: line.doorbell, jpeg: still) }
        PhoneWidgetShare.reloadWidgets(showing: line.camera)
    }

    /// Out of time: shown with the picture it has (the Mac's small one at least, when the push had it).
    override func serviceExtensionTimeWillExpire() {
        finish()
    }

    /// [noting]: a camera's alert (Camera Alerts says what picture it had). The widgets are brought up to date first,
    /// however it ends (picture, hard stop or out of time): the extension can be stopped once the alert is handed back.
    private func finish(noting: Bool = true) {
        lock.lock()
        let h = handler, c = content, note = what, line = widget, still = betterStill
        handler = nil
        lock.unlock()
        guard let h, let c else { return }
        if let line { Self.updateWidgets(line, still: still) }
        if noting { CameraEventMedia.noteLastPush(note) }
        h(c)
    }
}
