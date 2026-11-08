import SwiftUI
import WoodruffKit

/// Woodruff Family on Apple TV: the family's TVs and Home, made for the Siri Remote (focus and the click pad).
/// Its own screens, not the iPhone's; the TVs, speakers and lights come from WoodruffKit like everywhere else.
@main
struct WoodruffTVApp: App {
    @State private var fleet = Fleet.shared

    var body: some Scene {
        WindowGroup {
            TVRoot()
                .environment(fleet)
                .task {
                    await fleet.start()
                    SmartHome.shared.start()
                }
        }
    }
}

struct TVRoot: View {
    var body: some View {
        TabView {
            TVsTab().tabItem { Text("TVs") }
            HomeTab().tabItem { Text("Home") }
        }
    }
}

// MARK: - TVs

/// Every TV, big and focusable: select one for its remote.
struct TVsTab: View {
    @Environment(Fleet.self) private var fleet

    var body: some View {
        NavigationStack {
            let tvs = fleet.tvs.filter { !$0.isUnpaired }
            if tvs.isEmpty {
                VStack(spacing: 16) {
                    Text("No TVs Yet").font(.title2.bold())
                    Text("The family’s TVs appear here once this Apple TV has the family’s settings.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 900)
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 380), spacing: 48)], spacing: 48) {
                        ForEach(tvs) { tv in
                            NavigationLink { TVRemoteView(tvID: tv.id) } label: { TVCard(tv: tv) }
                                .buttonStyle(.card)
                        }
                    }
                    .padding(60)
                }
            }
        }
    }
}

private struct TVCard: View {
    let tv: FleetTV

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(tv.name).font(.title3.bold()).lineLimit(1)
            Text(status).foregroundStyle(.secondary).lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 160, alignment: .topLeading)
        .padding(28)
    }

    private var status: String {
        if !tv.online { return "Off" }
        if let p = tv.nowPlaying { return p.title }
        return "On"
    }
}

/// One TV's remote, laid out for the click pad: arrows around OK, then Back, Home, Play/Pause, volume and power.
struct TVRemoteView: View {
    @Environment(Fleet.self) private var fleet
    let tvID: String
    @State private var problem: String?

    var body: some View {
        let tv = fleet.tv(tvID)
        VStack(spacing: 40) {
            Text(tv?.name ?? "TV").font(.title.bold())
            VStack(spacing: 24) {
                key("Up", "up")
                HStack(spacing: 24) {
                    key("Left", "left")
                    key("OK", "ok")
                    key("Right", "right")
                }
                key("Down", "down")
            }
            HStack(spacing: 24) {
                key("Back", "back")
                key("Home", "home")
                key("Play/Pause", "playpause")
            }
            HStack(spacing: 24) {
                key("Volume Down", "voldown")
                key("Mute", "mute")
                key("Volume Up", "volup")
                key("Power", "power")
            }
            if let problem { Text(problem).foregroundStyle(.secondary) }
        }
        .padding(60)
    }

    private func key(_ title: String, _ name: String) -> some View {
        Button(title) { send(name) }
            .frame(minWidth: 220)
    }

    private func send(_ name: String) {
        guard let tv = fleet.tv(tvID), let c = fleet.client(for: tv) else { problem = "This TV can’t be reached."; return }
        Task {
            do { try await c.key(name); problem = nil } catch { problem = error.localizedDescription }
        }
    }
}

// MARK: - Home

/// The speakers and lights: play or pause a speaker, turn a light (or all of them) on or off.
struct HomeTab: View {
    private let home = SmartHome.shared

    var body: some View {
        NavigationStack {
            List {
                if !home.speakers.isEmpty {
                    Section("Speakers") {
                        ForEach(home.speakers) { room in
                            Button {
                                Task { await home.playPause(room) }
                            } label: {
                                HStack {
                                    Text(room.name)
                                    Spacer()
                                    Text(room.isPlaying ? (room.title ?? "Playing") : "Paused").foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                if !home.lights.isEmpty {
                    Section("Lights") {
                        Button("All Lights On") { home.allLights(true) }
                        Button("All Lights Off") { home.allLights(false) }
                        ForEach(home.lights) { light in
                            Button {
                                home.setOn(light, !light.on)
                            } label: {
                                HStack {
                                    Text(home.names[light.id] ?? light.name)
                                    Spacer()
                                    Text(light.on ? "On" : "Off").foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                if home.speakers.isEmpty && home.lights.isEmpty {
                    Text("Speakers and lights appear here once this Apple TV finds them on the Wi‑Fi.")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Home")
        }
    }
}
