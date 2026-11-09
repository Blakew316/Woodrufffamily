import UserNotifications
import CoreGraphics
import WidgetKit

/// Runs the moment a camera or doorbell push arrives (Woodruff can be closed): puts the picture of the event in the
/// notification, as Google Home does. The small picture the Mac sent in the push goes in at once, so the alert always
/// has one; then, at the same time, Google's clip or snapshot and the Mac Studio's full-size picture of the event are
/// asked for, and the first to come replaces it. Twenty seconds at most: the alert never waits longer than that.
final class NotificationService: UNNotificationServiceExtension, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((UNNotificationContent) -> Void)?
    private var content: UNMutableNotificationContent?
    /// What the alert's picture is now (for Camera Alerts' "Last alert from the Mac").
    private var what = "No picture came in time"

    /// How long the full picture is waited for (iOS allows about 30 seconds in all).
    private static let budget: TimeInterval = 20

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        let c = (request.content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        lock.lock(); handler = contentHandler; content = c; lock.unlock()
        let info = request.content.userInfo
        guard let camera = info["camera"] as? String, !camera.isEmpty else { finish(noting: false); return }
        func text(_ k: String) -> String? { (info[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        let event = text("event"), clip = text("clip"), thumb = text("thumb")
        let key = text("key") ?? request.identifier
        let macFocus = CameraEventMedia.focus(text("f"))
        let title = request.content.title
        let deadline = Date().addingTimeInterval(Self.budget)

        // The Mac's small picture first: whatever happens next, the alert has it.
        var thumbStill: Data?
        if let thumb, let file = CameraEventMedia.thumbnailFile(thumb) {
            if let a = CameraEventMedia.attachment(file) {
                set([a], "The Mac’s small picture attached")
                thumbStill = try? Data(contentsOf: file)
            }
            // The attachment is a copy of it: this one isn't needed after.
            try? FileManager.default.removeItem(at: file)
        } else if thumb != nil {
            what = "No picture: the Mac’s small picture couldn’t be read"
        }
        // The hard stop: the alert goes with what it has.
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.budget + 1) { [weak self] in self?.finish() }

        Task {
            // Google's clip or snapshot, or the Mac Studio's full picture of the event: the first to come.
            let got = await CameraEventMedia.firstPicture(camera: camera, eventID: event, clipURL: clip, key: key, deadline: deadline)
            var still = thumbStill
            if let got {
                let file = got.file
                // Where who or what was seen is (the Mac says for its own picture; Vision finds it in Google's), and the
                // widget's still, from one decode. Motion: the whole picture.
                var look: (still: Data?, focus: CGRect?) = (nil, nil)
                if got.fromMac {
                    look = (await CameraEventMedia.still(file), macFocus)
                } else {
                    look = await CameraEventMedia.stillAndFocus(file, title: title)
                }
                if let a = CameraEventMedia.attachment(file, focus: look.focus) {
                    var all = [a]
                    // A clip also carries a still of it: Apple Watch shows a picture with the alert, never a video.
                    if file.pathExtension == "mp4", let jpeg = look.still {
                        let stillFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
                        if (try? jpeg.write(to: stillFile)) != nil, let s = CameraEventMedia.attachment(stillFile, focus: look.focus, identifier: "still") {
                            all.append(s)
                        }
                        try? FileManager.default.removeItem(at: stillFile)
                    }
                    self.set(all, got.fromMac ? "The Mac’s full picture attached" : file.pathExtension == "mp4" ? "Clip attached" : "Snapshot attached")
                    if let s = look.still { still = s }
                }
            }
            // Before handing the alert back: the extension can be stopped right after.
            Self.updateWidget(camera: camera, name: request.content.body, title: title, jpeg: still)
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

    /// The TVs & Cameras widget, even with Woodruff closed: the camera's red tag for the event, and the alert's
    /// picture as its latest still.
    private static func updateWidget(camera: String, name: String, title: String, jpeg: Data?) {
        let doorbell = name.localizedCaseInsensitiveContains("door")
        let plain = title.replacingOccurrences(of: "Test: ", with: "")
        let tag = plain.localizedCaseInsensitiveContains("person") ? "Person"
            : plain.localizedCaseInsensitiveContains("motion") ? "Motion"
            : plain.localizedCaseInsensitiveContains("door") ? "Ring" : "Event"
        PhoneWidgetShare.saveCamera(id: camera, name: name.isEmpty ? "Camera" : name, doorbell: doorbell, jpeg: jpeg, event: tag)
        WidgetCenter.shared.reloadTimelines(ofKind: PhoneWidgetShare.tvsCamerasKind); WidgetCenter.shared.reloadTimelines(ofKind: PhoneWidgetShare.doorbellKind)
    }

    /// Out of time: shown with the picture it has (the Mac's small one at least, when the push had it).
    override func serviceExtensionTimeWillExpire() {
        finish()
    }

    /// [noting]: a camera's alert (Camera Alerts says what picture it had).
    private func finish(noting: Bool = true) {
        lock.lock()
        let h = handler, c = content, note = what
        handler = nil
        lock.unlock()
        guard let h, let c else { return }
        if noting { CameraEventMedia.noteLastPush(note) }
        h(c)
    }
}
