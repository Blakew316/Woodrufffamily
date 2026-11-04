import SwiftUI
import WoodruffKit

/// Woodruff Home Helper: Apple Home for Woodruff on the Mac. Apple lets only iPad-style apps like this one use
/// Apple Home on a Mac, so it reads Apple Home (with the same code as the iPhone app) and hands it to Woodruff
/// over a private connection on this Mac. Woodruff starts it by itself, hidden, with no Dock icon.
@main
struct WoodruffHomeHelperApp: App {
    init() {
        HomeKitLights.shared.start()
        HelperServer.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            HelperStatusView()
        }
    }
}

/// The helper's window (shown only when it's opened by hand): what it can see in Apple Home.
struct HelperStatusView: View {
    private let store = AccessoryStore.shared
    private let home = SmartHome.shared
    private let server = HelperServer.shared

    var body: some View {
        let lights = home.lights.filter { $0.isHome }.count
        VStack(alignment: .leading, spacing: 14) {
            Text("Woodruff Home Helper").font(.title2.bold())
            Text("Woodruff on this Mac reaches Apple Home through this helper. It runs quietly in the background, and you can close this window.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            if let problem = store.homeProblem {
                Text(problem)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Apple Home: \(store.fromHome.count) accessories and \(lights) lights")
            }
            Text(server.port == nil ? "Starting…" : (server.lastAsked == nil ? "Waiting for Woodruff" : "Connected to Woodruff"))
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Look Again") { HomeKitLights.shared.reload() }
            }
        }
        .padding(24)
        .frame(minWidth: 440, minHeight: 240)
    }
}
