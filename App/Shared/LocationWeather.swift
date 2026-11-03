import Foundation
import CoreLocation
import WoodruffKit

/// Weather on every TV's Home, from where you are: asks once for location while using the app (Apple's prompt),
/// finds the city, and sets it on each paired TV. Rechecked at most twice a day; nothing to type in Settings.
@MainActor
final class LocationWeather: NSObject, CLLocationManagerDelegate {
    static let shared = LocationWeather()
    private let manager = CLLocationManager()
    private weak var fleet: Fleet?

    func start(_ fleet: Fleet) {
        self.fleet = fleet
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        check()
    }

    private func check() {
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            let last = UserDefaults.standard.double(forKey: "weatherCheckedAt")
            if Date().timeIntervalSince1970 - last > 12 * 3600 { manager.requestLocation() }
        default: break
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in self.check() }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor in await self.apply(loc) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}

    private func apply(_ loc: CLLocation) async {
        guard let mark = try? await CLGeocoder().reverseGeocodeLocation(loc).first,
              let city = mark.locality else { return }
        let place = [city, mark.administrativeArea].compactMap { $0 }.joined(separator: ", ")
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "weatherCheckedAt")
        guard let fleet, place != UserDefaults.standard.string(forKey: "weatherPlace") else { return }
        var ok = false
        for hub in fleet.hubs {
            if (try? await TVClient(hub: hub, routeID: "this").saveWeather(place)) != nil { ok = true }
        }
        if ok { UserDefaults.standard.set(place, forKey: "weatherPlace") }
    }
}
