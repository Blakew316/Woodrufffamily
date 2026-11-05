import Foundation

// The devices model shared by Woodruff on iPhone, Woodruff on the Mac and Woodruff Home Helper (the Mac's way into
// Apple Home): a device, a command to it, and how temperatures read. Codable so the helper can hand them over.

struct HomeDevice: Identifiable, Hashable, Codable {
    enum Kind: String, Codable { case outlet, toggle, lock, thermostat, sensor, fan, blinds, garage, washer, dryer, fridge, oven, dishwasher, aircon, vacuum, appliance }

    var id: String
    var name: String
    /// "home" (Apple Home) or "smartthings".
    var source: String
    var kind: Kind
    var zone: String?
    /// On or off, for things that switch.
    var isOn: Bool?
    /// What it's doing, in a few words: "Locked", "70° · 45%", "Washing · 23 min left".
    var status: String
    var reachable = true
    /// Something to look at (a door open, a leak, smoke).
    var alert = false
    // Kind-specific.
    var locked: Bool?
    var temperature: Double?      // °C
    var target: Double?           // °C
    var position: Int?            // blinds 0…100
    var doorOpen: Bool?           // garage
    var machineState: String?     // run / pause / stop
    var endsAt: Date?
    var remoteControl = false     // the appliance allows starting / pausing from the phone
    var mode: String?             // vacuum movement, AC mode…
    var speed: Int?               // fan 0…100
    var swing: Bool?              // fan oscillating
    // Thermostats (an ecobee through Apple Home or SmartThings).
    var thermostatMode: String?   // off / heat / cool / auto
    var modes: [String] = []      // the modes it offers
    var heatTo: Double?           // °C
    var coolTo: Double?           // °C
    var humidity: Int?
    var action: String?           // heating / cooling / idle
    /// What it is, when that says more than its kind: "HomePod", "HomePod mini".
    var product: String? = nil

    /// Busy right now (for the running animations).
    var isRunning: Bool {
        // Not reachable: whatever it last said ("running") no longer holds.
        guard reachable else { return false }
        switch kind {
        case .washer, .dryer, .dishwasher, .oven: return machineState == "run"
        case .vacuum: return mode == "cleaning"
        case .fridge: return reachable
        default: return isOn == true
        }
    }

    var sourceName: String { source == "home" ? "Apple Home" : source == "dreo" ? "Dreo" : "SmartThings" }
}

enum DeviceCommand: Codable, Hashable {
    case power(Bool)
    case lock(Bool)
    case target(Double)
    case position(Int)
    case door(open: Bool)
    case machine(String)
    case speed(Int)
    case swing(Bool)
    case thermostatMode(String)
    case heatTo(Double)
    case coolTo(Double)
}

/// "72°", always in Fahrenheit (the family's thermostat and weather are in °F, whatever a device's region says).
/// [c] is in Celsius, as HomeKit and SmartThings report it.
func temperatureText(_ c: Double) -> String {
    temperatureFormatter.string(from: Measurement(value: c, unit: UnitTemperature.celsius).converted(to: .fahrenheit))
}

private let temperatureFormatter: MeasurementFormatter = {
    let f = MeasurementFormatter()
    f.unitStyle = .short
    // Shown as given (Fahrenheit), not converted to the device's region, and as "72°" without the F.
    f.unitOptions = [.providedUnit, .temperatureWithoutUnit]
    f.numberFormatter.maximumFractionDigits = 0
    return f
}()

/// One whole degree Fahrenheit warmer (+1) or cooler (−1) than [c] °C, so every tap shows a new number. Kept
/// between 7 and 32 °C (45–90 °F).
func thermostatStep(_ c: Double, _ direction: Double) -> Double {
    let next = ((c * 9 / 5 + 32).rounded() + direction - 32) * 5 / 9
    return min(32, max(7, next))
}

/// "Heating to 70° · 68° now", "Auto 68–74° · 70° now", "Off · 68° now".
func thermostatStatus(_ d: HomeDevice) -> String {
    let now = d.temperature.map { "\(temperatureText($0)) now" }
    var lead: String
    switch d.thermostatMode {
    case "heat": lead = d.heatTo.map { "\(d.action == "heating" ? "Heating" : "Heat") to \(temperatureText($0))" } ?? "Heat"
    case "cool": lead = d.coolTo.map { "\(d.action == "cooling" ? "Cooling" : "Cool") to \(temperatureText($0))" } ?? "Cool"
    case "auto":
        if let h = d.heatTo, let c = d.coolTo { lead = "Auto \(temperatureText(h))–\(temperatureText(c))" } else { lead = "Auto" }
    case "off": lead = "Off"
    default: lead = "Thermostat"
    }
    return [lead, now].compactMap { $0 }.joined(separator: " · ")
}
