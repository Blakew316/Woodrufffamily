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
    /// Settings' open pages: closed whenever another part of the app is picked, so coming back starts at its list.
    @State private var settingsPath = NavigationPath()

    var body: some View {
        TabView(selection: $tab) {
            Tab(value: "search", role: .search) {
                NavigationStack {
                    ScrollView { WatchSearchResults(query: query).padding(.horizontal, 60) }
                        .searchable(text: $query, prompt: "Movies and TV Shows")
                }
            }
            Tab("Home", systemImage: "house", value: "home") {
                NavigationStack {
                    HomeView()
                        .toolbar(.hidden, for: .navigationBar)
                }
                .background { TVPhotoBackdrop() }
            }
            Tab("Watch", systemImage: "play.tv", value: "watch") {
                NavigationStack {
                    WatchView()
                        .toolbar(.hidden, for: .navigationBar)
                        .ignoresSafeArea(edges: .top)
                }
                .background { HomeBackdrop() }
            }
            // Set apart lower in the sidebar, as Apple TV keeps Library.
            TabSection("") {
                Tab("Settings", systemImage: "gearshape", value: "settings") {
                    NavigationStack(path: $settingsPath) { TVSettingsView() }
                        .background { IconBackdrop() }
                }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .onChange(of: tab) { _, now in if now != "settings" { settingsPath = NavigationPath() } }
        .onAppear {
            // The screenshot run (-tvTab watch) opens a given page.
            if let t = UserDefaults.standard.string(forKey: "tvTab") { tab = t == "tvs" ? "home" : t }
        }
        .task {
            HomeWeather.shared.refresh()
            HomeGreeting.shared.refresh()
        }
    }
}

/// Home's banner on Apple TV, across the whole top of the screen as the TV app's own: the greeting floating in the
/// middle with its one-liner beneath, the weather floating at its left and the thermostat at its right (no pills).
struct TVHomeHeader: View {
    var body: some View {
        // As high as it goes: the greeting with its one-liner in the middle and the thermostat at the right, level with
        // the sidebar's Home; the weather at the left, just under it.
        ZStack(alignment: .top) {
            MacGreetingHero().scaleEffect(1.25, anchor: .top)
                .frame(maxWidth: .infinity)
            HStack(alignment: .top, spacing: 20) {
                TVWeatherFloat().padding(.top, 96)
                Spacer(minLength: 8)
                ThermostatChip(compact: false, height: 44)
                    .scaleEffect(macScale, anchor: .topTrailing)
            }
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, minHeight: 250, alignment: .top)
        .padding(.top, -50)
        .focusSection()
    }
}

/// The weather floating on its own: the sky and the temperature.
private struct TVWeatherFloat: View {
    private let weather = HomeWeather.shared
    @AppStorage("weatherPlace") private var place = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 16) {
                if let now = weather.now {
                    Image(systemName: now.sky.symbol)
                        .symbolRenderingMode(.multicolor)
                        .font(.system(size: 54, weight: .semibold))
                    Text(now.tempText)
                        .font(.system(size: 60, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(IconPalette.white)
                } else {
                    Image(systemName: "cloud.sun").font(.system(size: 48, weight: .semibold)).foregroundStyle(IconPalette.ice)
                    Text("--").font(.system(size: 54, weight: .semibold, design: .rounded)).foregroundStyle(IconPalette.ice)
                }
            }
            // "Lindale, TX": the town and the state's two letters.
            if !place.isEmpty {
                Text(WeatherPlace.short(place))
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(IconPalette.ice)
            }
        }
        .shadow(color: .black.opacity(0.4), radius: 10, y: 2)
    }
}

/// How many pages are open inside the current page (Settings' rows open pages).
@Observable @MainActor
final class TVNav {
    static let shared = TVNav()
    var depth = 0
}
