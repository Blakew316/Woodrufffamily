import Foundation
import HomeKit
import UIKit
import WoodruffKit

/// The lights in Apple Home (Cync bulbs over Matter, and any other), shown and controlled with the Govee ones.
/// HomeKit is iPhone-only for an app like this, so the Mac doesn't list them.
@MainActor
final class HomeKitLights: NSObject, HMHomeManagerDelegate, HMAccessoryDelegate {
    static let shared = HomeKitLights()

    /// Built with the HomeKit capability (WOODRUFF_HOMEKIT=YES); without it, HomeKit isn't touched at all.
    static var enabled: Bool { (Bundle.main.object(forInfoDictionaryKey: "WoodruffHomeKit") as? String) == "YES" }

    private var manager: HMHomeManager?
    private var accessories: [String: HMAccessory] = [:]
    private var others: [String: HMAccessory] = [:]
    private var pending: Task<Void, Never>?
    /// Whether each light was last set to a white temperature (true) or a colour (false). HomeKit keeps both
    /// hue/saturation and colour temperature, so which one the light shows is what was set last.
    private var whiteMode: [String: Bool] = [:]
    /// A change to an accessory that didn't go through (accessory id → what to say, until when).
    private var failed: [String: (message: String, until: Date)] = [:]

    func start() {
        guard Self.enabled, manager == nil, !Demo.isOn else { return }
        let m = HMHomeManager()
        m.delegate = self
        manager = m
        SmartHome.shared.homeControl = { [weak self] light, command in self?.send(light, command) }
        AccessoryStore.shared.homeControl = { [weak self] device, command in self?.send(device, command) }
    }

    /// Reads everything again (when the app comes back to the front).
    func refresh() {
        guard let manager else { return }
        for home in manager.homes {
            for a in home.accessories { for s in a.services where s.serviceType != HMServiceTypeAccessoryInformation { read(s) } }
        }
    }

    // MARK: HomeKit

    nonisolated func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        Task { @MainActor in self.load() }
    }

    nonisolated func accessory(_ accessory: HMAccessory, service: HMService, didUpdateValueFor characteristic: HMCharacteristic) {
        // Changed elsewhere (the Home app, Siri, the Cync app): note whether it went to a colour or a white.
        let type = characteristic.characteristicType
        let key = "home:" + accessory.uniqueIdentifier.uuidString
        Task { @MainActor in
            if type == HMCharacteristicTypeColorTemperature { self.whiteMode[key] = true }
            else if type == HMCharacteristicTypeHue || type == HMCharacteristicTypeSaturation { self.whiteMode[key] = false }
            self.publishSoon()
        }
    }

    nonisolated func accessoryDidUpdateReachability(_ accessory: HMAccessory) {
        Task { @MainActor in self.publishSoon() }
    }

    private func load() {
        guard let manager else { return }
        accessories = [:]
        others = [:]
        for home in manager.homes {
            for a in home.accessories {
                guard let s = bulb(a) else {
                    // Everything else: plugs, locks, thermostats, sensors, blinds, HomePod temperature…
                    guard primary(a) != nil else { continue }
                    a.delegate = self
                    others[id(a)] = a
                    for sv in a.services where sv.serviceType != HMServiceTypeAccessoryInformation {
                        for c in sv.characteristics where c.properties.contains(HMCharacteristicPropertySupportsEventNotification) {
                            c.enableNotification(true) { @Sendable _ in }
                        }
                        read(sv)
                    }
                    continue
                }
                // Govee lights are already handled directly over the Wi‑Fi.
                if a.manufacturer?.localizedCaseInsensitiveContains("govee") == true { continue }
                a.delegate = self
                accessories[id(a)] = a
                for c in s.characteristics where c.properties.contains(HMCharacteristicPropertySupportsEventNotification) {
                    c.enableNotification(true) { @Sendable _ in }
                }
                read(s)
            }
        }
        publish()
    }

    private func read(_ s: HMService) {
        for c in s.characteristics where c.properties.contains(HMCharacteristicPropertyReadable) {
            c.readValue { @Sendable _ in Task { @MainActor in HomeKitLights.shared.publishSoon() } }
        }
    }

    /// Several values arrive at once; show them together.
    private func publishSoon() {
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            publish()
        }
    }

    private func publish() {
        let list = accessories.values.compactMap { a -> GoveeLight? in
            guard let s = bulb(a) else { return nil }
            var l = GoveeLight(id: id(a), sku: a.manufacturer ?? "Apple Home", name: a.name, source: "home", zone: a.room?.name)
            l.on = (value(s, HMCharacteristicTypePowerState) as? NSNumber)?.boolValue ?? false
            // A light without dimming is at full when on; one that says 0 % while on shows 1 %.
            l.brightness = max(1, min(100, (value(s, HMCharacteristicTypeBrightness) as? NSNumber)?.intValue ?? 100))
            let sat = (value(s, HMCharacteristicTypeSaturation) as? NSNumber)?.doubleValue
            let hue = (value(s, HMCharacteristicTypeHue) as? NSNumber)?.doubleValue
            let mired = (value(s, HMCharacteristicTypeColorTemperature) as? NSNumber)?.doubleValue ?? 0
            let white = whiteMode[l.id] ?? ((sat ?? 0) < 10)
            if mired > 0, white || hue == nil {
                l.kelvin = Int((1_000_000 / mired).rounded())
            } else if let hue, let sat, sat > 0 {
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
                UIColor(hue: max(0, min(1, hue / 360)), saturation: max(0, min(1, sat / 100)), brightness: 1, alpha: 1)
                    .getRed(&r, green: &g, blue: &b, alpha: nil)
                l.color = LightColor(r: Int((r * 255).rounded()), g: Int((g * 255).rounded()), b: Int((b * 255).rounded()))
            } else if mired > 0 {
                l.kelvin = Int((1_000_000 / mired).rounded())
            }
            // Off the network (bulb switched off at the wall): shown as Offline, controls off, until it's back.
            l.offline = a.isReachable ? nil : true
            return l
        }
        SmartHome.shared.setHomeLights(list)
        AccessoryStore.shared.fromHome = others.values.compactMap(device)
    }

    // MARK: Other accessories

    private static let order: [String] = [
        HMServiceTypeLockMechanism, HMServiceTypeGarageDoorOpener, HMServiceTypeThermostat, HMServiceTypeWindowCovering,
        HMServiceTypeFan, HMServiceTypeAirPurifier, HMServiceTypeOutlet, HMServiceTypeSwitch,
        HMServiceTypeLeakSensor, HMServiceTypeSmokeSensor, HMServiceTypeCarbonMonoxideSensor, HMServiceTypeContactSensor,
        HMServiceTypeMotionSensor, HMServiceTypeOccupancySensor, HMServiceTypeTemperatureSensor, HMServiceTypeHumiditySensor,
    ]

    /// The service that says what the accessory is.
    private func primary(_ a: HMAccessory) -> HMService? {
        for t in Self.order { if let s = a.services.first(where: { $0.serviceType == t }) { return s } }
        return nil
    }

    private func num(_ a: HMAccessory, _ type: String) -> Double? {
        for s in a.services {
            if let c = s.characteristics.first(where: { $0.characteristicType == type }), let v = c.value as? NSNumber { return v.doubleValue }
        }
        return nil
    }

    private func device(_ a: HMAccessory) -> HomeDevice? {
        guard let p = primary(a) else { return nil }
        var d = HomeDevice(id: id(a), name: a.name, source: "home", kind: .sensor, zone: a.room?.name, status: "")
        d.reachable = a.isReachable
        let power = num(a, HMCharacteristicTypePowerState).map { $0 != 0 } ?? num(a, HMCharacteristicTypeActive).map { $0 != 0 }
        switch p.serviceType {
        case HMServiceTypeLockMechanism:
            d.kind = .lock
            let st = max(0, min(3, Int(num(a, HMCharacteristicTypeCurrentLockMechanismState) ?? 3)))
            let target = num(a, HMCharacteristicTypeTargetLockMechanismState).map { Int($0) }
            d.locked = st == 1 ? true : st == 0 ? false : nil
            d.status = ["Unlocked", "Locked", "Jammed", "Unknown"][st]
            // Asked to lock or unlock and still on its way there.
            if st < 2, let target, target != st, target == 0 || target == 1 { d.status = target == 1 ? "Locking…" : "Unlocking…" }
            d.alert = st == 2
        case HMServiceTypeGarageDoorOpener:
            d.kind = .garage
            let st = max(0, min(4, Int(num(a, HMCharacteristicTypeCurrentDoorState) ?? 1)))
            d.doorOpen = st != 1
            d.status = ["Open", "Closed", "Opening", "Closing", "Stopped"][st]
        case HMServiceTypeThermostat:
            d.kind = .thermostat
            d.temperature = num(a, HMCharacteristicTypeCurrentTemperature)
            d.target = num(a, HMCharacteristicTypeTargetTemperature)
            let mode = Int(num(a, HMCharacteristicTypeCurrentHeatingCooling) ?? 0)
            var s = d.temperature.map { "\(temperatureText($0)) now" } ?? ""
            if let t = d.target, mode != 0 { s = "\(mode == 1 ? "Heating" : "Cooling") to \(temperatureText(t))" + (s.isEmpty ? "" : " · " + s) }
            d.status = s.isEmpty ? "Thermostat" : s
        case HMServiceTypeWindowCovering:
            d.kind = .blinds
            let pos = Int(num(a, HMCharacteristicTypeCurrentPosition) ?? 0)
            d.position = pos
            d.status = pos == 0 ? "Closed" : pos >= 100 ? "Open" : "\(pos)% Open"
        case HMServiceTypeFan, HMServiceTypeAirPurifier:
            d.kind = .fan
            d.isOn = power ?? false
            let speed = num(a, HMCharacteristicTypeRotationSpeed)
            d.speed = speed.map { Int($0) }
            d.swing = num(a, HMCharacteristicTypeSwingMode).map { $0 != 0 }
            d.status = d.isOn == true ? (speed.map { "On · \(Int($0))%" } ?? "On") + (d.swing == true ? " · Oscillating" : "") : "Off"
        case HMServiceTypeOutlet:
            d.kind = .outlet
            d.isOn = power ?? false
            d.status = d.isOn == true ? "On" : "Off"
        case HMServiceTypeSwitch:
            d.kind = .toggle
            d.isOn = power ?? false
            d.status = d.isOn == true ? "On" : "Off"
        default:
            d.kind = .sensor
            var bits: [String] = []
            if num(a, HMCharacteristicTypeLeakDetected) == 1 { bits.append("Leak Detected"); d.alert = true }
            if num(a, HMCharacteristicTypeSmokeDetected) == 1 { bits.append("Smoke Detected"); d.alert = true }
            if num(a, HMCharacteristicTypeCarbonMonoxideDetected) == 1 { bits.append("Carbon Monoxide"); d.alert = true }
            if let c = num(a, HMCharacteristicTypeContactState) { bits.append(c == 0 ? "Closed" : "Open") }
            if let m = num(a, HMCharacteristicTypeMotionDetected) { bits.append(m != 0 ? "Motion" : "No Motion") }
            if let o = num(a, HMCharacteristicTypeOccupancyDetected) { bits.append(o != 0 ? "Occupied" : "Empty") }
            if let t = num(a, HMCharacteristicTypeCurrentTemperature) { d.temperature = t; bits.append(temperatureText(t)) }
            if let h = num(a, HMCharacteristicTypeCurrentRelativeHumidity) { bits.append("\(Int(h))% Humidity") }
            d.status = bits.isEmpty ? "Sensor" : bits.joined(separator: " · ")
        }
        // A change that didn't go through, said for a few seconds where the accessory is.
        if let f = failed[d.id] {
            if f.until > Date() { d.status = f.message; d.alert = true } else { failed[d.id] = nil }
        }
        return d
    }

    private func send(_ d: HomeDevice, _ command: DeviceCommand) {
        guard let a = others[d.id] else { return }
        let id = d.id
        var steps: [(String, Any)] = []
        switch command {
        case .power(let on):
            if a.services.contains(where: { $0.characteristics.contains { $0.characteristicType == HMCharacteristicTypePowerState } }) {
                steps = [(HMCharacteristicTypePowerState, on)]
            } else {
                steps = [(HMCharacteristicTypeActive, on ? 1 : 0)]
            }
        case .lock(let lock): steps = [(HMCharacteristicTypeTargetLockMechanismState, lock ? 1 : 0)]
        case .door(let open): steps = [(HMCharacteristicTypeTargetDoorState, open ? 0 : 1)]
        case .position(let p): steps = [(HMCharacteristicTypeTargetPosition, max(0, min(100, p)))]
        case .target(let t): steps = [(HMCharacteristicTypeTargetTemperature, t)]
        case .speed(let v):
            if v > 0 {
                if a.services.contains(where: { $0.characteristics.contains { $0.characteristicType == HMCharacteristicTypePowerState } }) {
                    steps.append((HMCharacteristicTypePowerState, true))
                } else {
                    steps.append((HMCharacteristicTypeActive, 1))
                }
            }
            steps.append((HMCharacteristicTypeRotationSpeed, Double(max(0, min(100, v)))))
        case .swing(let on): steps = [(HMCharacteristicTypeSwingMode, on ? 1 : 0)]
        case .machine: return
        }
        guard a.isReachable else {
            failed[id] = (message: "Not Responding", until: Date().addingTimeInterval(8))
            publishSoon()
            return
        }
        let plan = steps
        Task {
            // One after another, each one awaited, so a failure (a jammed lock, no answer) is said.
            var failure: Error?
            for step in plan {
                guard let acc = self.others[id], let c = self.characteristic(acc, step.0) else { continue }
                if let e = await self.write(c, step.1) { failure = e; break }
            }
            if let failure {
                let verb: String
                switch command {
                case .lock(let lock): verb = lock ? "Couldn’t Lock" : "Couldn’t Unlock"
                default: verb = "Didn’t Respond"
                }
                self.failed[id] = (message: verb, until: Date().addingTimeInterval(8))
            } else {
                self.failed[id] = nil
            }
            self.publishSoon()
            // The message clears itself once its time is up.
            if failure != nil {
                try? await Task.sleep(nanoseconds: 8_500_000_000)
                self.publishSoon()
            }
        }
    }

    /// A writable characteristic of that type, in any of the accessory's services.
    private func characteristic(_ a: HMAccessory, _ type: String) -> HMCharacteristic? {
        for s in a.services {
            if let c = s.characteristics.first(where: { $0.characteristicType == type && $0.properties.contains(HMCharacteristicPropertyWritable) }) {
                return c
            }
        }
        return nil
    }

    // MARK: Control

    private func send(_ light: GoveeLight, _ command: LightCommand) {
        let id = light.id, name = light.name
        Task {
            guard let a = self.accessories[id], let s = self.bulb(a) else {
                SmartHome.shared.homeControlFailed(id, "\(name) isn’t in Apple Home any more.")
                self.publish()
                return
            }
            guard a.isReachable else {
                SmartHome.shared.homeControlFailed(id, "\(name) isn’t responding. Check it’s switched on at the wall.")
                self.publish()
                return
            }
            let isOn = (self.value(s, HMCharacteristicTypePowerState) as? NSNumber)?.boolValue == true
            var steps: [(String, Any)] = []
            func powerOn() { if !isOn { steps.append((HMCharacteristicTypePowerState, true)) } }
            switch command {
            case .power(let on):
                steps.append((HMCharacteristicTypePowerState, on))
            case .brightness(let v):
                powerOn()
                steps.append((HMCharacteristicTypeBrightness, max(1, min(100, v))))
            case .color(let c):
                var h: CGFloat = 0, sat: CGFloat = 0, b: CGFloat = 0
                UIColor(red: CGFloat(max(0, min(255, c.r))) / 255, green: CGFloat(max(0, min(255, c.g))) / 255,
                        blue: CGFloat(max(0, min(255, c.b))) / 255, alpha: 1)
                    .getHue(&h, saturation: &sat, brightness: &b, alpha: nil)
                powerOn()
                steps.append((HMCharacteristicTypeHue, Double(h * 360)))
                steps.append((HMCharacteristicTypeSaturation, Double(sat * 100)))
            case .kelvin(let k):
                powerOn()
                if let c = s.characteristics.first(where: { $0.characteristicType == HMCharacteristicTypeColorTemperature }) {
                    var mired = 1_000_000 / Double(max(1000, k))
                    if let lo = c.metadata?.minimumValue?.doubleValue, let hi = c.metadata?.maximumValue?.doubleValue, hi >= lo {
                        mired = max(lo, min(hi, mired))
                    }
                    steps.append((HMCharacteristicTypeColorTemperature, Int(mired.rounded())))
                } else {
                    // No white temperatures: plain white.
                    steps.append((HMCharacteristicTypeSaturation, 0.0))
                }
            }
            // One after another, each awaited, so a write that fails is said rather than lost.
            var failure: Error?
            for step in steps {
                guard let acc = self.accessories[id], let svc = self.bulb(acc),
                      let c = svc.characteristics.first(where: { $0.characteristicType == step.0 }) else { continue }
                if let e = await self.write(c, step.1) { failure = e; break }
            }
            if let failure {
                SmartHome.shared.homeControlFailed(id, "\(name) didn’t change: \(failure.localizedDescription)")
            } else {
                SmartHome.shared.homeControlSucceeded()
                if case .kelvin = command { self.whiteMode[id] = true }
                if case .color = command { self.whiteMode[id] = false }
            }
            self.publishSoon()
        }
    }

    /// Writes one value and waits for the accessory's answer: nil when it took it, else what went wrong.
    private func write(_ c: HMCharacteristic, _ v: Any) async -> Error? {
        await withCheckedContinuation { (cont: CheckedContinuation<Error?, Never>) in
            c.writeValue(v) { @Sendable error in cont.resume(returning: error) }
        }
    }

    // MARK: Helpers

    private func bulb(_ a: HMAccessory) -> HMService? { a.services.first { $0.serviceType == HMServiceTypeLightbulb } }
    private func id(_ a: HMAccessory) -> String { "home:" + a.uniqueIdentifier.uuidString }
    private func value(_ s: HMService, _ type: String) -> Any? {
        s.characteristics.first { $0.characteristicType == type }?.value
    }
}
