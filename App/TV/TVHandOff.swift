import Foundation
import WoodruffKit

/// Films Apple's player can't play smoothly, played by the TV this Apple TV is plugged into instead.
///
/// Some films keep their sound and their picture far apart in the file. The Android TVs' own player plays those as
/// they are. Apple's player hops between the two some hundreds of times a second and stops every twenty seconds or
/// so, however the film is handed to it. So when the app sees a film doing that, the film goes on from where it is
/// on the TV's own player (the same screen: the TV switches to its own app), and is started there straight away
/// from then on.
@MainActor
enum TVHandOff {
    /// The TV this Apple TV is plugged into (its id), chosen in Settings → Watch. Each Apple TV keeps its own.
    static let screenKey = "watch.screenTV"
    /// The films to start on the TV (their library keys).
    private static let filmsKey = "watch.handedOff"

    /// Whether a TV has been chosen (on just now or not).
    static var chosen: Bool { !(UserDefaults.standard.string(forKey: screenKey) ?? "").isEmpty }

    /// The TV to hand a film to: the one chosen, when it's paired, linked and on.
    static func screen(_ fleet: Fleet) -> FleetTV? {
        guard let id = UserDefaults.standard.string(forKey: screenKey), !id.isEmpty else { return nil }
        return fleet.tvs.first { $0.id == id && !$0.isUnpaired && $0.online && $0.link != "refused" }
    }

    /// Whether [key] is a film that's been seen to stutter in Apple's player.
    static func knows(_ key: String) -> Bool {
        (UserDefaults.standard.stringArray(forKey: filmsKey) ?? []).contains(key)
    }

    static func remember(_ key: String) {
        var all = UserDefaults.standard.stringArray(forKey: filmsKey) ?? []
        guard !all.contains(key) else { return }
        all.append(key)
        if all.count > 500 { all.removeFirst(all.count - 500) }
        UserDefaults.standard.set(all, forKey: filmsKey)
    }

    /// How many films are started on the TV, for Settings.
    static var count: Int { (UserDefaults.standard.stringArray(forKey: filmsKey) ?? []).count }

    /// Every film is tried in Apple's player again.
    static func forgetAll() {
        UserDefaults.standard.removeObject(forKey: filmsKey)
    }
}
