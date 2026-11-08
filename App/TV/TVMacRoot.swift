import SwiftUI
import WoodruffKit

/// Woodruff on Apple TV, laid out as Apple's own TV app: the Liquid Glass sidebar on the left (Home, Movies, TV
/// Shows, Search, Settings), which tucks away to its icons and opens when the remote moves left onto it; each page
/// fills the screen behind it. Movies and TV Shows open with the full-screen banner and rows of posters that lift
/// when the remote is on them.
struct TVMacRoot: View {
    @Environment(Fleet.self) private var fleet
    @AppStorage("tv.tab") private var tab = "home"
    @AppStorage("watch.section") private var watchSection = "movies"
    @State private var query = ""

    var body: some View {
        TabView(selection: $tab) {
            Tab("Home", systemImage: "house", value: "home") {
                NavigationStack { HomeView() }
                    .background { HomeBackdrop() }
            }
            Tab("Movies", systemImage: "film", value: "movies") {
                NavigationStack { WatchView() }
                    .background { HomeBackdrop() }
                    .onAppear { watchSection = "movies" }
            }
            Tab("TV Shows", systemImage: "tv", value: "shows") {
                NavigationStack { WatchView() }
                    .background { HomeBackdrop() }
                    .onAppear { watchSection = "shows" }
            }
            Tab(value: "search", role: .search) {
                NavigationStack {
                    ScrollView { WatchSearchResults(query: query).padding(.horizontal, 60) }
                        .searchable(text: $query, prompt: "Movies and TV Shows")
                }
            }
            Tab("Settings", systemImage: "gearshape", value: "settings") {
                NavigationStack { TVSettingsView() }
                    .background { IconBackdrop() }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .onAppear {
            // The screenshot run (-tvTab watch) opens a given page.
            if let t = UserDefaults.standard.string(forKey: "tvTab") { tab = t == "watch" ? "movies" : t }
        }
        .task {
            HomeWeather.shared.refresh()
            HomeGreeting.shared.refresh()
        }
    }
}

/// The top of Home on Apple TV: the weather at the left, the greeting centred with its one-liner beneath, and the
/// thermostat at the right.
struct TVHomeHeader: View {
    var body: some View {
        HStack(spacing: 20) {
            TVWeatherPill()
            Spacer(minLength: 8)
            ThermostatChip(compact: false, height: 44)
                .scaleEffect(macScale, anchor: .trailing)
        }
        .overlay { MacGreetingHero() }
        .frame(height: 44 * macScale)
        .focusSection()
    }
}

/// The weather, as a pill: the sky and the temperature, as on the Mac.
private struct TVWeatherPill: View {
    private let weather = HomeWeather.shared

    var body: some View {
        HStack(spacing: 14) {
            if let now = weather.now {
                Image(systemName: now.sky.symbol)
                    .symbolRenderingMode(.multicolor)
                    .font(.system(size: 34, weight: .semibold))
                Text(now.tempText)
                    .font(.system(size: 38, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(IconPalette.white)
            } else {
                Image(systemName: "cloud.sun").font(.system(size: 30, weight: .semibold)).foregroundStyle(IconPalette.ice)
                Text("--").font(.system(size: 34, weight: .semibold, design: .rounded)).foregroundStyle(IconPalette.ice)
            }
        }
        .padding(.horizontal, 30)
        .frame(height: 44 * macScale)
        .glass(Capsule(), interactive: false)
    }
}

/// How many pages are open inside the current page (Settings' rows open pages).
@Observable @MainActor
final class TVNav {
    static let shared = TVNav()
    var depth = 0
}
