import Foundation
import ActivityKit

/// The doorbell ringing, as a Live Activity on the Lock Screen and in the Dynamic Island for a minute: the door's
/// latest picture and Open. Started by the Mac's push (the iPhone app needn't be running), ended by the iPhone a
/// minute in. Shared by the app and the widgets extension.
struct DoorbellAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// When it rang.
        var at: Date
    }
    var camera: String
    var name: String
}
