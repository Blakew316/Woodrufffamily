import Foundation
import Observation
import WoodruffKit

// The family's settings sync (App/Shared/SettingsSync.swift, the same file the iPhone and Mac run) also restarts the
// services those apps run when a sign-in arrives or ends. The Apple TV doesn't run them, so here they're stand-ins
// that do nothing: the sign-ins still arrive and are kept with the family's keys, ready for when the Apple TV uses
// them.

@Observable @MainActor final class Dreo {
    static let shared = Dreo()
    var busy = false
    func signOut() {}
    func start() {}
    func refresh(full: Bool = false) async {}
}

@Observable @MainActor final class DecoWifi {
    static let shared = DecoWifi()
    var busy = false
    func signOut() {}
    func start() {}
    func refresh() async {}
}

@MainActor final class NestCameras {
    static let shared = NestCameras()
    func reloadSaved() {}
    func signOut() {}
    func start() {}
}

@MainActor final class Cync {
    static let shared = Cync()
    func signOut() {}
    func start() {}
}

@MainActor final class SmartThings {
    static let shared = SmartThings()
    func signOut() {}
    func refresh(full: Bool = false) async {}
}

@MainActor final class PushRelay {
    static let shared = PushRelay()
    func reloadTokens() {}
    func keysChanged() {}
}

@MainActor enum GoogleGrants {
    static func handOut(_ fleet: Fleet) async {}
}

@MainActor final class SceneStore {
    static let shared = SceneStore()
    func reload() {}
}

@MainActor final class HomeLayout {
    static let shared = HomeLayout()
    func reload() {}
}
