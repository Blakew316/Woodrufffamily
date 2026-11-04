import Foundation
import WoodruffKit

/// Apple Home on the Mac. Apple lets only iPad-style (Mac Catalyst) apps use Apple Home on a Mac, so
/// "Woodruff Home Helper", an app of that kind, reads Apple Home and Woodruff Family for Mac asks it over a
/// private connection on this Mac (127.0.0.1, with a secret in a file only this user can read).
enum HomeBridge {
    /// The helper's bundle ID (project.yml, target WoodruffHomeHelper).
    static let helperBundleID = "com.blakew316.woodruff.homehelper"
    static let helperName = "Woodruff Home Helper"
    static let tokenHeader = "X-Woodruff-Token"

    /// Where the helper writes its port and secret.
    static var infoURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Woodruff Home Helper", isDirectory: true).appendingPathComponent("bridge.json")
    }

    struct Info: Codable, Equatable {
        var port: UInt16
        var token: String
        var pid: Int32
        func url(_ pathAndQuery: String) -> URL? { URL(string: "http://127.0.0.1:\(port)\(pathAndQuery)") }
    }

    static func readInfo() -> Info? {
        guard let d = try? Data(contentsOf: infoURL) else { return nil }
        return try? JSONDecoder().decode(Info.self, from: d)
    }

    /// Everything in Apple Home the helper can see, in Woodruff's own terms.
    struct State: Codable {
        /// Changes whenever anything in the state does (Woodruff asks with the last one and gets 204 if nothing did).
        var hash: String
        /// Plugs, locks, the thermostat, sensors, blinds…
        var devices: [HomeDevice]
        /// Apple Home lights (Cync and others).
        var lights: [GoveeLight]
        /// Why Apple Home can't be read (no permission, no home, signed out of iCloud), or nil.
        var problem: String?
    }

    struct DeviceRequest: Codable {
        var id: String
        var command: DeviceCommand
    }

    struct LightRequest: Codable {
        var id: String
        var command: Light
    }

    /// LightCommand (WoodruffKit) as it travels.
    enum Light: Codable {
        case power(Bool)
        case brightness(Int)
        case color(LightColor)
        case kelvin(Int)

        init(_ c: LightCommand) {
            switch c {
            case .power(let on): self = .power(on)
            case .brightness(let v): self = .brightness(v)
            case .color(let c): self = .color(c)
            case .kelvin(let k): self = .kelvin(k)
            }
        }

        var command: LightCommand {
            switch self {
            case .power(let on): return .power(on)
            case .brightness(let v): return .brightness(v)
            case .color(let c): return .color(c)
            case .kelvin(let k): return .kelvin(k)
            }
        }
    }
}
