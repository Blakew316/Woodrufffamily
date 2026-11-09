import WidgetKit

/// The camera widgets' push address, from WidgetKit, kept in the app group: the app hands it to the Macs with its own
/// alert address. A moment after an alert from a camera these widgets show the Mac Studio sends a push to it, and iOS
/// reloads TVs & Cameras and the Lock Screen's doorbell then (the alert's add-on has saved the event and its picture for
/// them by that time), even with Woodruff closed. Called with each new address, and whenever these widgets are added or
/// removed.
struct CameraWidgetsPushHandler: WidgetPushHandler {
    func pushTokenDidChange(_ pushInfo: WidgetPushInfo, widgets: [WidgetInfo]) {
        // None of them on the Home Screen or Lock Screen: no address, so the Macs push nothing for them.
        PhoneWidgetShare.saveWidgetPushToken(widgets.isEmpty ? nil : pushInfo.token)
    }
}
