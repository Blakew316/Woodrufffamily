import Foundation

/// A note in the app's settings while Woodruff is the app on screen on this Apple TV: when it was last there, written
/// again every ten seconds, and removed as the app is put away. The Mac Studio's updater reads it before it installs
/// an update, as it reads `PlayCrumb` to leave a film alone: installing closes the app, and where this note is fresh
/// the updater opens Woodruff again afterwards (the phones only see an Apple TV while Woodruff runs on it). With
/// Woodruff put away, or the Apple TV asleep, there's no note and nothing is opened. Keep it written that way.
@MainActor
enum OpenCrumb {
    private static let key = "open.crumb"
    private static var keeper: Timer?

    /// Woodruff is on screen ([on]), or has been put away.
    static func set(_ on: Bool) {
        keeper?.invalidate()
        keeper = nil
        guard on else {
            UserDefaults.standard.removeObject(forKey: key)
            return
        }
        write()
        keeper = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
            MainActor.assumeIsolated { write() }
        }
    }

    private static func write() {
        UserDefaults.standard.set(["at": Date().timeIntervalSince1970, "build": AppBuild.label], forKey: key)
    }
}
