import SwiftUI
import WoodruffKit

/// Woodruff on Apple TV, laid out as the Mac app: Home, Watch and Settings in the Mac's glass bar centred at the very
/// top; under it, on Home, the greeting centred with its one-liner centred beneath (the weather beside the greeting)
/// and the thermostat pill at the right; on Watch, Movies | TV Shows and the TV it plays on at the right. Then the
/// Mac's pages (Settings is the Mac's, its list on the left). No remote panel: the Siri Remote is the remote.
struct TVMacRoot: View {
    @Environment(Fleet.self) private var fleet
    @AppStorage("section") private var stored = AppSection.home.rawValue
    @AppStorage("watch.section") private var watchSection = "movies"

    private var section: AppSection {
        let s = AppSection(rawValue: stored) ?? .home
        return AppSection.mac.contains(s) ? s : .home
    }

    @State private var query = ""
    private let layout = HomeLayout.shared

    var body: some View {
        let s = section
        VStack(spacing: 0) {
            bar(s)
                .padding(.horizontal, 30)
                .padding(.top, 20)
                .padding(.bottom, 14)
                .focusSection()
            NavigationStack {
                Group {
                    if s == .watch && !query.isEmpty {
                        ScrollView { WatchSearchResults(query: query).padding(.horizontal, 40) }
                    } else {
                        page(s)
                    }
                }
                .environment(\.macPageStack, false)
                .toolbar(.hidden, for: .navigationBar)
            }
            .id(s)
            .focusSection()
        }
        // Inside the TV's title-safe area: many TVs crop the picture's edges.
        .padding(.horizontal, 50)
        .padding(.vertical, 10)
        .background {
            if s == .settings { IconBackdrop() } else { HomeBackdrop() }
        }
        .task(id: s) {
            guard s == .home else { return }
            HomeWeather.shared.refresh()
            HomeGreeting.shared.refresh()
        }
    }

    /// The Mac's bar, exactly: the sections centred at the very top; under them on Home Edit Home at the left, the
    /// weather and greeting in the middle and the thermostat at the right; on Watch search at the left, Movies | TV
    /// Shows in the middle, the TV it plays on and the thermostat at the right. Settings has no second row.
    private func bar(_ s: AppSection) -> some View {
        VStack(spacing: 10 * macScale) {
            HStack {
                Spacer(minLength: 0)
                MacSectionBar(current: s) { query = ""; stored = $0.rawValue }
                Spacer(minLength: 0)
            }
            if s == .home {
                HStack(spacing: 10 * macScale) {
                    // The weather where the Mac has Edit Home (Home is arranged with the remote here).
                    TVWeatherPill()
                    Spacer(minLength: 8)
                    ThermostatChip(compact: false, height: 44)
                        .scaleEffect(macScale, anchor: .trailing)
                }
                .overlay { MacGreetingHero() }
            } else if s == .watch {
                HStack(spacing: 10 * macScale) {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search Movies and TV Shows", text: $query)
                        .textFieldStyle(.plain)
                    }
                    .padding(.horizontal, 16 * macScale)
                    .frame(width: 320 * macScale, height: 44 * macScale)
                    .glass(Capsule(), interactive: false)
                    Spacer(minLength: 8)
                    // Room for the pill at the TV's size (it's drawn larger than its own space).
                    ThermostatChip(compact: false, height: 44)
                        .scaleEffect(macScale, anchor: .trailing)
                        .padding(.leading, 170)
                }
                .overlay {
                    Picker("Library", selection: $watchSection) {
                        Text("Movies").tag("movies")
                        Text("TV Shows").tag("shows")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            }
        }
    }

    @ViewBuilder private func page(_ s: AppSection) -> some View {
        switch s {
        case .watch: WatchView()
        case .settings: TVSettingsView()
        default: HomeView()
        }
    }
}

/// The weather, as a pill at the left of Home's bar: the sky and the temperature, as on the Mac.
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
