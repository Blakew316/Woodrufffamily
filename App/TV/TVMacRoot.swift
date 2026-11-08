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
                .background { HomeBackdrop() }
            }
            Tab("Watch", systemImage: "play.tv", value: "watch") {
                NavigationStack {
                    WatchView()
                        // Movies | TV Shows, floating at the top of the banner.
                        .overlay(alignment: .top) {
                            Picker("Library", selection: $watchSection) {
                                Text("Movies").tag("movies")
                                Text("TV Shows").tag("shows")
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .fixedSize()
                            .padding(.top, 30)
                            // A section across the whole width: Up from anywhere on the banner lands here first.
                            .frame(maxWidth: .infinity)
                            .focusSection()
                        }
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
        HStack(alignment: .center, spacing: 20) {
            TVWeatherFloat()
            Spacer(minLength: 8)
            ThermostatChip(compact: false, height: 44)
                .scaleEffect(macScale, anchor: .trailing)
        }
        .overlay { MacGreetingHero().scaleEffect(1.25) }
        .padding(.horizontal, 20)
        .frame(height: 380)
        .frame(maxWidth: .infinity)
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
                Text(Self.short(place))
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(IconPalette.ice)
            }
        }
        .shadow(color: .black.opacity(0.4), radius: 10, y: 2)
    }

    private static let states: [String: String] = [
        "Alabama": "AL", "Alaska": "AK", "Arizona": "AZ", "Arkansas": "AR", "California": "CA", "Colorado": "CO",
        "Connecticut": "CT", "Delaware": "DE", "Florida": "FL", "Georgia": "GA", "Hawaii": "HI", "Idaho": "ID",
        "Illinois": "IL", "Indiana": "IN", "Iowa": "IA", "Kansas": "KS", "Kentucky": "KY", "Louisiana": "LA",
        "Maine": "ME", "Maryland": "MD", "Massachusetts": "MA", "Michigan": "MI", "Minnesota": "MN",
        "Mississippi": "MS", "Missouri": "MO", "Montana": "MT", "Nebraska": "NE", "Nevada": "NV",
        "New Hampshire": "NH", "New Jersey": "NJ", "New Mexico": "NM", "New York": "NY", "North Carolina": "NC",
        "North Dakota": "ND", "Ohio": "OH", "Oklahoma": "OK", "Oregon": "OR", "Pennsylvania": "PA",
        "Rhode Island": "RI", "South Carolina": "SC", "South Dakota": "SD", "Tennessee": "TN", "Texas": "TX",
        "Utah": "UT", "Vermont": "VT", "Virginia": "VA", "Washington": "WA", "West Virginia": "WV",
        "Wisconsin": "WI", "Wyoming": "WY",
    ]

    static func short(_ place: String) -> String {
        let parts = place.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 2 else { return place }
        return parts[0] + ", " + (states[parts[1]] ?? parts[1])
    }
}

/// How many pages are open inside the current page (Settings' rows open pages).
@Observable @MainActor
final class TVNav {
    static let shared = TVNav()
    var depth = 0
}
