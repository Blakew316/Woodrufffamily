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
            // Also when Home's own weather has no spot yet (it reads the place found here).
            let noSpot = UserDefaults.standard.object(forKey: "weatherLat") == nil
            if noSpot || Date().timeIntervalSince1970 - last > 12 * 3600 { manager.requestLocation() }
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
        // Home's greeting shows the weather here too.
        UserDefaults.standard.set(loc.coordinate.latitude, forKey: "weatherLat")
        UserDefaults.standard.set(loc.coordinate.longitude, forKey: "weatherLon")
        HomeWeather.shared.refresh(force: true)
        guard let mark = try? await CLGeocoder().reverseGeocodeLocation(loc).first,
              let city = mark.locality else { return }
        let place = [city, mark.administrativeArea].compactMap { $0 }.joined(separator: ", ")
        guard let fleet else { return }
        // The place each TV was given (by hub id). Only a change of town used to be sent, so a TV that was off at
        // the time (or paired since) never got it; now each one that hasn't is sent it.
        var given = UserDefaults.standard.dictionary(forKey: "weatherPlaces") as? [String: String] ?? [:]
        var missed = false
        for hub in fleet.hubs where given[hub.id] != place {
            if (try? await TVClient(hub: hub, routeID: "this").saveWeather(place)) != nil { given[hub.id] = place } else { missed = true }
        }
        UserDefaults.standard.set(given, forKey: "weatherPlaces")
        UserDefaults.standard.set(place, forKey: "weatherPlace")
        // Every TV has it: look again in twelve hours. One didn't answer: try again in about an hour.
        let now = Date().timeIntervalSince1970
        UserDefaults.standard.set(missed ? now - 11 * 3600 : now, forKey: "weatherCheckedAt")
    }
}
