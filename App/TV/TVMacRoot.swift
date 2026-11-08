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
                .padding(.horizontal, 40)
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
                    Button { layout.arranging ? layout.stopArranging() : layout.startArranging() } label: {
                        Text(layout.arranging ? "Done" : "Edit Home")
                            .font(.system(size: 14 * macScale, weight: .semibold))
                            .foregroundStyle(layout.arranging ? Color.white : .primary)
                            .padding(.horizontal, 18 * macScale)
                            .frame(height: 44 * macScale)
                            .glass(Capsule(), tint: layout.arranging ? .accentColor : nil)
                    }
                    .buttonStyle(TVBarButtonStyle())
                    Spacer(minLength: 8)
                    ThermostatChip(compact: false, height: 44 * macScale)
                }
                .overlay { MacGreetingHero() }
            } else if s == .watch {
                HStack(spacing: 10 * macScale) {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search Movies and TV Shows", text: $query)
                    }
                    .padding(.horizontal, 16 * macScale)
                    .frame(width: 320 * macScale, height: 44 * macScale)
                    .glass(Capsule(), interactive: false)
                    Spacer(minLength: 8)
                    TVPicker()
                    ThermostatChip(compact: false, height: 44 * macScale)
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
        case .settings: MacSettingsView()
        default: HomeView()
        }
    }
}
