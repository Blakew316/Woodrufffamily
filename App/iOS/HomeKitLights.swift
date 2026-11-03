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
    private var pending: Task<Void, Never>?

    func start() {
        guard Self.enabled, manager == nil, !Demo.isOn else { return }
        let m = HMHomeManager()
        m.delegate = self
        manager = m
        SmartHome.shared.homeControl = { [weak self] light, command in self?.send(light, command) }
    }

    /// Reads everything again (when the app comes back to the front).
    func refresh() {
        guard let manager else { return }
        for home in manager.homes {
            for a in home.accessories { for s in a.services where s.serviceType == HMServiceTypeLightbulb { read(s) } }
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
        for home in manager.homes {
            for a in home.accessories {
                guard let s = bulb(a) else { continue }
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
