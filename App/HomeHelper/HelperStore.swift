import Foundation
import Observation

/// Woodruff Home Helper's side of the devices store. HomeKitLights (the same code the iPhone app uses) fills it,
/// and HelperServer hands it to Woodruff on this Mac.
@Observable @MainActor
final class AccessoryStore {
    static let shared = AccessoryStore()
    /// Plugs, locks, the thermostat, sensors, blinds… in Apple Home.
    var fromHome: [HomeDevice] = []
    /// Why Apple Home can't be read, or nil.
    var homeProblem: String?
    /// Carries out a change (set by HomeKitLights).
    @ObservationIgnored var homeControl: ((HomeDevice, DeviceCommand) -> Void)?
}
