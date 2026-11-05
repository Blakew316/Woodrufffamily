import Foundation
import ActivityKit

/// The Live Activity for a washer, dryer, dishwasher or oven that is running: a countdown on the Lock Screen and in
/// the Dynamic Island, then "Done" for a while when it finishes. Shared by the app and the widgets extension.
struct ApplianceAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// What it is doing ("Rinse", "Drying"), or "Paused" / "Done".
        var phase: String
        /// When the cycle started, as far as the app knows (for the bar).
        var startedAt: Date
        /// When it will finish, if the appliance says.
        var endsAt: Date?
        var paused: Bool
        var done: Bool
    }
    var deviceID: String
    var name: String
    /// washer, dryer, dishwasher or oven.
    var kind: String
}

extension ApplianceAttributes {
    var symbol: String {
        switch kind {
        case "washer": return "washer.fill"
        case "dryer": return "dryer.fill"
        case "dishwasher": return "dishwasher.fill"
        default: return "oven.fill"
        }
    }
}
