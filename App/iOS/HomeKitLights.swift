import Foundation
import HomeKit
import UIKit
import WoodruffKit

/// The lights in Apple Home (Cync bulbs over Matter, and any other), shown and controlled with the Govee ones.
/// HomeKit is iPhone-only for an app like this, so the Mac doesn't list them.
@MainActor
final class HomeKitLights: NSObject, HMHomeManagerDelegate, HMHomeDelegate, HMAccessoryDelegate {
    static let shared = HomeKitLights()

    /// Built with the HomeKit capability (WOODRUFF_HOMEKIT=YES); without it, HomeKit isn't touched at all.
    static var enabled: Bool { (Bundle.main.object(forInfoDictionaryKey: "WoodruffHomeKit") as? String) == "YES" }

    private var manager: HMHomeManager?
    private var accessories: [String: HMAccessory] = [:]
    private var others: [String: HMAccessory] = [:]
    private var pending: Task<Void, Never>?
    private var reloading: Task<Void, Never>?
    /// Whether each light was last set to a white temperature (true) or a colour (false). HomeKit keeps both
    /// hue/saturation and colour temperature, so which one the light shows is what was set last.
    private var whiteMode: [String: Bool] = [:]
    /// A change to an accessory that didn't go through (accessory id → what to say, until when).
    private var failed: [String: (message: String, until: Date)] = [:]
    /// Values just written, shown at once while the accessory takes them (accessory id → characteristic type →
    /// the value, and which write it came from). The accessory's answer replaces them.
    private var showing: [String: [String: (value: Double, stamp: Int)]] = [:]
    private var writes = 0

    func start() {
        guard manager == nil, !Demo.isOn else { return }
        guard Self.enabled else {
            AccessoryStore.shared.homeProblem = "This copy of Woodruff was built without Apple Home, so the ecobee can only come in through SmartThings (Settings → Devices)."
            return
        }
        let m = HMHomeManager()
        m.delegate = self
        manager = m
        SmartHome.shared.homeControl = { [weak self] light, command in self?.send(light, command) }
        AccessoryStore.shared.homeControl = { [weak self] device, command in self?.send(device, command) }
    }

    /// Reads everything again (when the app comes back to the front).
    func refresh() {
        guard let manager else { return }
        // Nothing found yet (the homes weren't ready the first time): look through them again.
        if accessories.isEmpty && others.isEmpty { loadSoon() }
        for home in manager.homes {
            for a in home.accessories { for s in a.services where s.serviceType != HMServiceTypeAccessoryInformation { read(s) } }
        }
    }

    /// Reads one accessory again (its page or the thermostat controls just opened).
    func refresh(device id: String) {
        guard let a = others[id] ?? accessories[id] else { refresh(); return }
        for s in a.services where s.serviceType != HMServiceTypeAccessoryInformation { read(s) }
    }

    /// Looks through Apple Home again from the start (a new accessory, a thermostat that hasn't shown up).
    func reload() {
        if manager == nil { start() } else { load() }
    }

    // MARK: HomeKit

    nonisolated func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        Task { @MainActor in self.load() }
    }

    /// Permission given (or taken away) for Apple Home.
    nonisolated func homeManager(_ manager: HMHomeManager, didUpdate status: HMHomeManagerAuthorizationStatus) {
        Task { @MainActor in self.loadSoon() }
    }

    nonisolated func homeManager(_ manager: HMHomeManager, didAdd home: HMHome) {
        Task { @MainActor in self.loadSoon() }
    }

    nonisolated func homeManager(_ manager: HMHomeManager, didRemove home: HMHome) {
        Task { @MainActor in self.loadSoon() }
    }

    // An accessory added in the Home app (the ecobee, a new plug) shows up without restarting Woodruff.
    nonisolated func home(_ home: HMHome, didAdd accessory: HMAccessory) {
        Task { @MainActor in self.loadSoon() }
    }

    nonisolated func home(_ home: HMHome, didRemove accessory: HMAccessory) {
        Task { @MainActor in self.loadSoon() }
    }

    nonisolated func home(_ home: HMHome, didUpdate room: HMRoom, for accessory: HMAccessory) {
        Task { @MainActor in self.publishSoon() }
    }

    nonisolated func accessoryDidUpdateName(_ accessory: HMAccessory) {
        Task { @MainActor in self.publishSoon() }
    }

    nonisolated func accessoryDidUpdateServices(_ accessory: HMAccessory) {
        Task { @MainActor in self.loadSoon() }
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

    /// Several changes arrive together (permission, then the homes): look through them once.
    private func loadSoon() {
        reloading?.cancel()
        reloading = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            load()
        }
    }

    /// Why there's nothing from Apple Home (no permission, no home yet), for the thermostat pill and Settings.
    private func noteAccess(_ m: HMHomeManager) {
        let s = m.authorizationStatus
        let problem: String?
        if s.contains(.restricted) {
            problem = "Apple Home is restricted on this iPhone (Screen Time → Content & Privacy Restrictions). Allow it and the ecobee shows up here."
        } else if s.contains(.determined) && !s.contains(.authorized) {
            problem = "Woodruff isn’t allowed to use Apple Home. Open Settings and allow it (also under Privacy & Security → HomeKit), and the ecobee shows up here."
        } else if s.contains(.authorized) && m.homes.isEmpty {
            problem = "There’s no home in the Home app on this iPhone yet. Set one up there and add the ecobee to it."
        } else {
            problem = nil
        }
        if AccessoryStore.shared.homeProblem != problem { AccessoryStore.shared.homeProblem = problem }
    }

    private func load() {
        guard let manager else { return }
        noteAccess(manager)
        accessories = [:]
        others = [:]
        for home in manager.homes {
            home.delegate = self
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
        AccessoryStore.shared.fromHome = others.values.compactMap { self.device($0) }
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

    /// A value of the accessory: one just written (until the accessory answers), else what it last said, from
    /// [preferred] first (an ecobee also has temperature and occupancy sensors; its thermostat's reading counts).
    private func num(_ a: HMAccessory, _ type: String, in preferred: HMService? = nil) -> Double? {
        if let shown = showing[id(a)]?[type] { return shown.value }
        if let preferred, let c = preferred.characteristics.first(where: { $0.characteristicType == type }), let v = c.value as? NSNumber {
            return v.doubleValue
        }
        for s in a.services {
            if let c = s.characteristics.first(where: { $0.characteristicType == type }), let v = c.value as? NSNumber { return v.doubleValue }
        }
        return nil
    }

    /// A value to write, as a number (for showing it before the accessory answers).
    private static func number(_ v: Any) -> Double? {
        if let b = v as? Bool { return b ? 1 : 0 }
        if let i = v as? Int { return Double(i) }
        if let d = v as? Double { return d }
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
            let st = max(0, min(4, Int(num(a, HMCharacteristicTypeCurrentDoorState, in: p) ?? 1)))
            d.doorOpen = st != 1
            d.status = ["Open", "Closed", "Opening", "Closing", "Stopped"][st]
            // Asked to open or close and not moving yet: say so (and the button already offers the other way).
            let asked = num(a, HMCharacteristicTypeTargetDoorState, in: p).map { Int($0) }
            if st == 0 || st == 1, let asked, asked == 0 || asked == 1, asked != st {
                d.status = asked == 0 ? "Opening…" : "Closing…"
                d.doorOpen = asked == 0
            }
            if num(a, HMCharacteristicTypeObstructionDetected, in: p) == 1 { d.status = "Obstructed"; d.alert = true }
        case HMServiceTypeThermostat:
            d.kind = .thermostat
            d.temperature = num(a, HMCharacteristicTypeCurrentTemperature, in: p)
            d.target = num(a, HMCharacteristicTypeTargetTemperature, in: p)
            let names = ["off", "heat", "cool", "auto"]
            let target = max(0, min(3, Int(num(a, HMCharacteristicTypeTargetHeatingCooling, in: p) ?? 0)))
            d.thermostatMode = names[target]
            // The modes this one offers (a system without cooling has no Cool).
            let valid = (p.characteristics.first { $0.characteristicType == HMCharacteristicTypeTargetHeatingCooling }?.metadata?.validValues ?? [])
                .map { $0.intValue }.filter { $0 >= 0 && $0 <= 3 }
            d.modes = valid.isEmpty ? names : Array(Set(valid)).sorted().map { names[$0] }
            let current = Int(num(a, HMCharacteristicTypeCurrentHeatingCooling, in: p) ?? 0)
            d.action = current == 1 ? "heating" : current == 2 ? "cooling" : "idle"
            // In heat or cool the target is the one temperature; in auto it holds between two.
            d.heatTo = target == 3 ? num(a, HMCharacteristicTypeHeatingThreshold, in: p) ?? d.target : d.target
            d.coolTo = target == 3 ? num(a, HMCharacteristicTypeCoolingThreshold, in: p) ?? d.target : d.target
            d.humidity = num(a, HMCharacteristicTypeCurrentRelativeHumidity, in: p).map { Int($0.rounded()) }
            d.status = thermostatStatus(d)
        case HMServiceTypeWindowCovering:
            d.kind = .blinds
            let pos = max(0, min(100, Int(num(a, HMCharacteristicTypeCurrentPosition, in: p) ?? 0)))
            let target = num(a, HMCharacteristicTypeTargetPosition, in: p).map { max(0, min(100, Int($0))) }
            // Moving (or just asked to): where it's going, so a second tap goes the other way.
            let moving = num(a, HMCharacteristicTypePositionState, in: p).map { Int($0) != 2 } ?? false
            let asked = showing[d.id]?[HMCharacteristicTypeTargetPosition] != nil
            if let target, target != pos, moving || asked {
                d.position = target
                d.status = target > pos ? "Opening…" : "Closing…"
            } else {
                d.position = pos
                d.status = pos == 0 ? "Closed" : pos >= 100 ? "Open" : "\(pos)% Open"
            }
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
        let id = d.id
        guard let a = others[id] else {
            // Gone from Apple Home since the list was made: look again.
            loadSoon()
            return
        }
        // On or off: the switch's own power, else "Active" (fans, purifiers).
        let usesPower = characteristic(a, HMCharacteristicTypePowerState) != nil
        let power = usesPower ? HMCharacteristicTypePowerState : HMCharacteristicTypeActive
        // Auto holds between two temperatures; heat and cool hold one.
        let auto = Int(num(a, HMCharacteristicTypeTargetHeatingCooling) ?? 0) == 3
        var steps: [(String, Any)] = []
        switch command {
        case .power(let on):
            if usesPower { steps = [(power, on)] } else { steps = [(power, on ? 1 : 0)] }
        case .lock(let lock): steps = [(HMCharacteristicTypeTargetLockMechanismState, lock ? 1 : 0)]
        case .door(let open): steps = [(HMCharacteristicTypeTargetDoorState, open ? 0 : 1)]
        case .position(let p): steps = [(HMCharacteristicTypeTargetPosition, max(0, min(100, p)))]
        case .target(let t): steps = [(HMCharacteristicTypeTargetTemperature, t)]
        case .speed(let v):
            if v <= 0 {
                // Speed 0 is off (some fans refuse a speed of 0 while on).
                if usesPower { steps = [(power, false)] } else { steps = [(power, 0)] }
            } else {
                if usesPower { steps.append((power, true)) } else { steps.append((power, 1)) }
                steps.append((HMCharacteristicTypeRotationSpeed, Double(min(100, v))))
            }
        case .swing(let on): steps = [(HMCharacteristicTypeSwingMode, on ? 1 : 0)]
        case .thermostatMode(let m):
            // Never a guess: an unknown mode isn't sent (it would otherwise turn the heating off).
            guard let v = ["off": 0, "heat": 1, "cool": 2, "auto": 3][m] else { return }
            steps = [(HMCharacteristicTypeTargetHeatingCooling, v)]
        case .heatTo(let t):
            let threshold = auto && characteristic(a, HMCharacteristicTypeHeatingThreshold) != nil
            steps = [(threshold ? HMCharacteristicTypeHeatingThreshold : HMCharacteristicTypeTargetTemperature, t)]
        case .coolTo(let t):
            let threshold = auto && characteristic(a, HMCharacteristicTypeCoolingThreshold) != nil
            steps = [(threshold ? HMCharacteristicTypeCoolingThreshold : HMCharacteristicTypeTargetTemperature, t)]
        case .machine: return
        }
        // Only what this accessory can take; anything else is said on its tile rather than quietly dropped.
        let plan = steps.filter { characteristic(a, $0.0) != nil }
        guard !plan.isEmpty else {
            failed[id] = (message: "Can’t Change That", until: Date().addingTimeInterval(8))
            publishSoon()
            return
        }
        guard a.isReachable else {
            failed[id] = (message: "Not Responding", until: Date().addingTimeInterval(8))
            publishSoon()
            return
        }
        // Shown straight away; the accessory's answer then confirms it (or puts back what it really is).
        writes += 1
        let stamp = writes
        var shown = showing[id] ?? [:]
        for step in plan {
            guard let c = characteristic(a, step.0), let v = Self.number(step.1) else { continue }
            shown[step.0] = (value: aligned(c, v), stamp: stamp)
        }
        showing[id] = shown
        failed[id] = nil
        publish()
        Task {
            // One after another, each one awaited, so a failure (a jammed lock, no answer) is said.
            var failure: Error?
            for step in plan {
                guard let acc = self.others[id], let c = self.characteristic(acc, step.0) else { continue }
                // Temperatures and levels go in within the accessory's range and steps (HomeKit refuses others).
                let v: Any = (step.1 as? Double).map { self.aligned(c, $0) } ?? step.1
                if let e = await self.write(c, v) { failure = e; break }
            }
            // The accessory has answered: from now on its own value shows (unless a newer change is on its way).
            for step in plan where self.showing[id]?[step.0]?.stamp == stamp {
                self.showing[id]?[step.0] = nil
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

    /// [v] clamped to the characteristic's range and rounded to its step.
    private func aligned(_ c: HMCharacteristic, _ v: Double) -> Double {
        var x = v
        if let lo = c.metadata?.minimumValue?.doubleValue { x = max(lo, x) }
        if let hi = c.metadata?.maximumValue?.doubleValue { x = min(hi, x) }
        if let step = c.metadata?.stepValue?.doubleValue, step > 0 {
            let base = c.metadata?.minimumValue?.doubleValue ?? 0
            x = base + ((x - base) / step).rounded() * step
        }
        return x
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
