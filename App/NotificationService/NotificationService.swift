import UserNotifications

/// Runs the moment a camera or doorbell push arrives (Woodruff can be closed): fetches the event's clip or snapshot
/// from Google and puts it in the notification, so it plays when the notification is expanded. Anything else, or
/// nothing from Google in time, shows as it came.
final class NotificationService: UNNotificationServiceExtension, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((UNNotificationContent) -> Void)?
    private var content: UNMutableNotificationContent?

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        let c = (request.content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        lock.lock(); handler = contentHandler; content = c; lock.unlock()
        let info = request.content.userInfo
        guard let camera = info["camera"] as? String, !camera.isEmpty else { finish(); return }
        let event = (info["event"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let clip = (info["clip"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let key = (info["key"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? request.identifier
        let thumb = (info["thumb"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        Task {
            // The full clip or snapshot when Google gives it quickly; else the small picture the Mac sent in the push.
            // Kept short: the alert waits for this, and the Mac's quiet update brings the picture if it's late.
            if let file = await CameraEventMedia.fetch(camera: camera, eventID: event, clipURL: clip, key: key, timeout: thumb == nil ? 5 : 4),
               let a = CameraEventMedia.attachment(file) {
                c.attachments = [a]
                CameraEventMedia.noteLastPush(file.pathExtension == "mp4" ? "Clip attached" : "Snapshot attached")
            } else if let thumb, let file = CameraEventMedia.thumbnailFile(thumb), let a = CameraEventMedia.attachment(file) {
                c.attachments = [a]
                CameraEventMedia.noteLastPush("The Mac’s picture attached")
            } else {
                CameraEventMedia.noteLastPush(thumb == nil
                    ? (clip == nil ? "No picture yet: Google sends the clip a few seconds later" : "No picture: the clip didn’t come in time")
                    : "No picture: the Mac’s picture couldn’t be read")
            }
            self.finish()
        }
    }

    /// Out of time: shown as it is.
    override func serviceExtensionTimeWillExpire() {
        CameraEventMedia.noteLastPush("No picture: ran out of time")
        finish()
    }

    private func finish() {
        lock.lock()
        let h = handler, c = content
        handler = nil
        lock.unlock()
        if let h, let c { h(c) }
    }
}
