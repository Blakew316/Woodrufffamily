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
        Task { @MainActor in self.publishSoon() }
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
                            c.enableNotification(true) { _ in }
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
                    c.enableNotification(true) { _ in }
                }
                read(s)
            }
        }
        publish()
    }

    private func read(_ s: HMService) {
        for c in s.characteristics where c.properties.contains(HMCharacteristicPropertyReadable) {
            c.readValue { [weak self] _ in Task { @MainActor in self?.publishSoon() } }
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
            l.brightness = (value(s, HMCharacteristicTypeBrightness) as? NSNumber)?.intValue ?? (l.on ? 100 : 0)
            let sat = (value(s, HMCharacteristicTypeSaturation) as? NSNumber)?.doubleValue
            let hue = (value(s, HMCharacteristicTypeHue) as? NSNumber)?.doubleValue
            if let mired = (value(s, HMCharacteristicTypeColorTemperature) as? NSNumber)?.doubleValue, mired > 0, (sat ?? 0) < 10 {
                l.kelvin = Int(1_000_000 / mired)
            } else if let hue, let sat, sat > 0 {
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
                UIColor(hue: hue / 360, saturation: sat / 100, brightness: 1, alpha: 1).getRed(&r, green: &g, blue: &b, alpha: nil)
                l.color = LightColor(r: Int(r * 255), g: Int(g * 255), b: Int(b * 255))
            }
            // Off the network (bulb switched off at the wall): show it as off.
            if !a.isReachable { l.on = false }
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
            let st = Int(num(a, HMCharacteristicTypeCurrentLockMechanismState) ?? 3)
            d.locked = st == 1 ? true : st == 0 ? false : nil
            d.status = ["Unlocked", "Locked", "Jammed", "Unknown"][min(st, 3)]
            d.alert = st == 2
        case HMServiceTypeGarageDoorOpener:
            d.kind = .garage
            let st = Int(num(a, HMCharacteristicTypeCurrentDoorState) ?? 1)
            d.doorOpen = st != 1
            d.status = ["Open", "Closed", "Opening", "Closing", "Stopped"][min(st, 4)]
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
            d.status = d.isOn == true ? (speed.map { "On · \(Int($0))%" } ?? "On") : "Off"
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
        return d
    }

    private func send(_ d: HomeDevice, _ command: DeviceCommand) {
        guard let a = others[d.id] else { return }
        func write(_ type: String, _ v: Any) {
            for s in a.services {
                if let c = s.characteristics.first(where: { $0.characteristicType == type && $0.properties.contains(HMCharacteristicPropertyWritable) }) {
                    c.writeValue(v) { [weak self] _ in Task { @MainActor in self?.publishSoon() } }
                    return
                }
            }
        }
        switch command {
        case .power(let on):
            if a.services.contains(where: { $0.characteristics.contains { $0.characteristicType == HMCharacteristicTypePowerState } }) {
                write(HMCharacteristicTypePowerState, on)
            } else {
                write(HMCharacteristicTypeActive, on ? 1 : 0)
            }
        case .lock(let lock): write(HMCharacteristicTypeTargetLockMechanismState, lock ? 1 : 0)
        case .door(let open): write(HMCharacteristicTypeTargetDoorState, open ? 0 : 1)
        case .position(let p): write(HMCharacteristicTypeTargetPosition, max(0, min(100, p)))
        case .target(let t): write(HMCharacteristicTypeTargetTemperature, t)
        case .machine: break
        }
    }

    // MARK: Control

    private func send(_ light: GoveeLight, _ command: LightCommand) {
        guard let a = accessories[light.id], let s = bulb(a) else { return }
        switch command {
        case .power(let on):
            write(s, HMCharacteristicTypePowerState, on)
        case .brightness(let v):
            write(s, HMCharacteristicTypePowerState, true)
            write(s, HMCharacteristicTypeBrightness, max(1, min(100, v)))
        case .color(let c):
            var h: CGFloat = 0, sat: CGFloat = 0, b: CGFloat = 0
            UIColor(red: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: 1)
                .getHue(&h, saturation: &sat, brightness: &b, alpha: nil)
            write(s, HMCharacteristicTypePowerState, true)
            write(s, HMCharacteristicTypeHue, Double(h * 360))
            write(s, HMCharacteristicTypeSaturation, Double(sat * 100))
        case .kelvin(let k):
            write(s, HMCharacteristicTypePowerState, true)
            if let c = s.characteristics.first(where: { $0.characteristicType == HMCharacteristicTypeColorTemperature }) {
                var mired = 1_000_000 / Double(max(1000, k))
                if let lo = c.metadata?.minimumValue?.doubleValue, let hi = c.metadata?.maximumValue?.doubleValue { mired = max(lo, min(hi, mired)) }
                c.writeValue(Int(mired)) { _ in }
            } else {
                write(s, HMCharacteristicTypeSaturation, 0.0)
            }
        }
    }

    private func write(_ s: HMService, _ type: String, _ v: Any) {
        guard let c = s.characteristics.first(where: { $0.characteristicType == type }) else { return }
        c.writeValue(v) { [weak self] _ in Task { @MainActor in self?.publishSoon() } }
    }

    // MARK: Helpers

    private func bulb(_ a: HMAccessory) -> HMService? { a.services.first { $0.serviceType == HMServiceTypeLightbulb } }
    private func id(_ a: HMAccessory) -> String { "home:" + a.uniqueIdentifier.uuidString }
    private func value(_ s: HMService, _ type: String) -> Any? {
        s.characteristics.first { $0.characteristicType == type }?.value
    }
}
