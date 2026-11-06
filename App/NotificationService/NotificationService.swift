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
        Task {
            if let file = await CameraEventMedia.fetch(camera: camera, eventID: event, clipURL: clip, key: key, timeout: 20),
               let a = CameraEventMedia.attachment(file) {
                c.attachments = [a]
            }
            self.finish()
        }
    }

    /// Out of time: shown as it is.
    override func serviceExtensionTimeWillExpire() { finish() }

    private func finish() {
        lock.lock()
        let h = handler, c = content
        handler = nil
        lock.unlock()
        if let h, let c { h(c) }
    }
}
