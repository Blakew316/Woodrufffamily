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

    var body: some View {
        let s = section
        VStack(spacing: 0) {
            bar(s)
                .padding(.horizontal, 60)
                .padding(.top, 24)
                .padding(.bottom, 16)
                .focusSection()
            NavigationStack {
                page(s)
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

    private func bar(_ s: AppSection) -> some View {
        VStack(spacing: 18) {
            // Where to go, centred at the very top.
            MacSectionBar(current: s) { stored = $0.rawValue }
                .frame(maxWidth: .infinity)
            if s == .home {
                ZStack {
                    TVGreeting()
                    HStack {
                        Spacer()
                        ThermostatChip(compact: false, height: 44 * macScale)
                    }
                }
            } else if s == .watch {
                HStack(spacing: 24) {
                    Spacer()
                    Picker("Library", selection: $watchSection) {
                        Text("Movies").tag("movies")
                        Text("TV Shows").tag("shows")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    TVPicker()
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

/// The greeting centred, its one-liner centred beneath; the weather just left of the greeting, as on the Mac.
private struct TVGreeting: View {
    private let weather = HomeWeather.shared
    private let greeting = HomeGreeting.shared

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 18) {
                if let now = weather.now {
                    HStack(spacing: 10) {
                        Image(systemName: now.sky.symbol)
                            .symbolRenderingMode(.multicolor)
                            .font(.system(size: 40, weight: .semibold))
                        Text(now.tempText)
                            .font(.system(size: 42, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                    }
                    Rectangle().fill(IconPalette.cyan).frame(width: 2, height: 46)
                        .shadow(color: IconPalette.cyan.opacity(0.6), radius: 4)
                }
                Text(greeting.greeting)
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .foregroundStyle(IconPalette.white)
                    .lineLimit(1)
            }
            if !greeting.line.isEmpty {
                Text(greeting.line)
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(IconPalette.ice)
                    .lineLimit(1)
                    .multilineTextAlignment(.center)
                    .contentTransition(.opacity)
                    .id(greeting.line)
                    .transition(.opacity)
            }
        }
        .shadow(color: .black.opacity(0.4), radius: 10, y: 2)
        .frame(maxWidth: .infinity)
    }
}
