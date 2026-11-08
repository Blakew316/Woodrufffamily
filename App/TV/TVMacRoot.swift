import SwiftUI
import WoodruffKit

/// Woodruff on Apple TV, laid out as the Mac app: Home, Watch and Settings in the Mac's glass bar at the top; under it,
/// on Home the Mac's greeting with the weather in the middle and the thermostat on the right, on Watch Movies | TV
/// Shows and the TV it plays on; then the Mac's pages (Settings is the Mac's, its list on the left). No remote panel:
/// the Siri Remote is the remote.
struct TVMacRoot: View {
    @Environment(Fleet.self) private var fleet
    @AppStorage("section") private var stored = AppSection.home.rawValue
    @AppStorage("watch.section") private var watchSection = "movies"

    private var section: AppSection {
        let s = AppSection(rawValue: stored) ?? .home
        return AppSection.mac.contains(s) ? s : .home
    }

    var body: some View {
        let s = section
        VStack(spacing: 0) {
            bar(s)
                .padding(.horizontal, 60)
                .padding(.top, 30)
                .padding(.bottom, 18)
                .focusSection()
            NavigationStack {
                page(s)
                    .environment(\.macPageStack, false)
                    .toolbar(.hidden, for: .navigationBar)
            }
            .id(s)
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

    /// The Mac's top bar: the sections on the left, the greeting in the middle, the page's own controls on the right.
    private func bar(_ s: AppSection) -> some View {
        ZStack {
            HStack(alignment: .center, spacing: 24) {
                MacSectionBar(current: s) { stored = $0.rawValue }
                Spacer(minLength: 20)
                if s == .watch {
                    Picker("Library", selection: $watchSection) {
                        Text("Movies").tag("movies")
                        Text("TV Shows").tag("shows")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    TVPicker()
                }
                if s == .home {
                    ThermostatChip(compact: false, height: 44 * macScale)
                }
            }
            if s == .home {
                MacGreetingHero()
            }
        }
        .frame(height: 50 * macScale)
    }

    @ViewBuilder private func page(_ s: AppSection) -> some View {
        switch s {
        case .watch: WatchView()
        case .settings: MacSettingsView()
        default: HomeView()
        }
    }
}
