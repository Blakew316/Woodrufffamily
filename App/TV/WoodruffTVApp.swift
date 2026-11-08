import SwiftUI
import WoodruffKit

/// Woodruff Family on Apple TV: Home, Watch, the family's TVs and Settings, in the iPhone app's look (the icon's blues
/// drifting behind, frosted cards, the pictures large) and made for the Siri Remote: everything is a tile that lifts
/// when the remote is on it. The TVs, speakers and lights come from WoodruffKit like everywhere else.
@main
struct WoodruffTVApp: App {
    @State private var fleet = Fleet.shared

    var body: some Scene {
        WindowGroup {
            TVRoot()
                .environment(fleet)
                .preferredColorScheme(.dark)
                .task {
                    // Announced on the Wi‑Fi from the start, so the iPhone app can find and connect it.
                    TVJoin.shared.start()
                    // The family's settings first (the TVs, keys and sign-ins kept with the family's code), then the
                    // TVs and Home as everywhere else.
                    SettingsSync.shared.prepare(fleet)
                    await fleet.start()
                    SettingsSync.shared.start(fleet)
                    SmartHome.shared.start()
                    // The washer, dryer, thermostat, fans and the rest, with the family's sign-ins.
                    SmartThings.shared.start()
                    Dreo.shared.start()
                }
        }
    }
}

struct TVRoot: View {
    private let join = TVJoin.shared

    var body: some View {
        TabView {
            HomeTab().tabItem { Text("Home") }
            WatchTab().tabItem { Text("Watch") }
            TVsTab().tabItem { Text("TVs") }
            SettingsTab().tabItem { Text("Settings") }
        }
        .alert("Connect to the Family?", isPresented: Binding(get: { join.asking != nil }, set: { if !$0 { join.answer(false) } })) {
            Button("Allow") { join.answer(true) }
            Button("Don’t Allow", role: .cancel) { join.answer(false) }
        } message: {
            Text("\(join.asking ?? "A device") wants to give this Apple TV the family’s TVs, keys and settings.")
        }
    }
}

// MARK: - Home

/// Home as on the iPhone: the greeting, what's on the TVs, the speakers with their album art, and the lights.
struct HomeTab: View {
    @Environment(Fleet.self) private var fleet
    private let home = SmartHome.shared

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 56) {
                    TVGreeting().padding(.horizontal, 80).padding(.top, 20)
                    let tvs = fleet.tvs.filter { !$0.isUnpaired }
                    if tvs.isEmpty {
                        ConnectPhoneCard().padding(.horizontal, 80)
                    } else {
                        VStack(alignment: .leading, spacing: 24) {
                            TVSectionTitle(text: "TVs")
                            ScrollView(.horizontal) {
                                LazyHStack(spacing: 48) {
                                    ForEach(tvs.sorted { ($0.nowPlaying != nil ? 0 : 1, $0.name) < ($1.nowPlaying != nil ? 0 : 1, $1.name) }) { tv in
                                        NavigationLink { TVRemoteView(tvID: tv.id) } label: { TVPlayingCard(tv: tv, width: 620) }
                                            .buttonStyle(TVTileStyle())
                                    }
                                }
                                .padding(.horizontal, 80).padding(.vertical, 36)
                            }
                            .scrollClipDisabled()
                        }
                    }
                    if !home.speakers.isEmpty {
                        VStack(alignment: .leading, spacing: 24) {
                            TVSectionTitle(text: "Speakers")
                            ScrollView(.horizontal) {
                                LazyHStack(spacing: 40) {
                                    ForEach(home.speakers) { room in
                                        Button { Task { await home.playPause(room) } } label: { SpeakerCard(room: room) }
                                            .buttonStyle(TVTileStyle())
                                    }
                                }
                                .padding(.horizontal, 80).padding(.vertical, 36)
                            }
                            .scrollClipDisabled()
                        }
                    }
                    if !home.lights.isEmpty {
                        VStack(alignment: .leading, spacing: 24) {
                            HStack(spacing: 30) {
                                TVSectionTitle(text: "Lights")
                                Spacer()
                                Button("All On") { home.allLights(true) }
                                Button("All Off") { home.allLights(false) }
                            }
                            .padding(.trailing, 80)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 40)], spacing: 40) {
                                ForEach(home.lights) { light in
                                    Button { home.setOn(light, !light.on) } label: {
                                        LightCard(light: light, name: home.names[light.id] ?? light.name)
                                    }
                                    .buttonStyle(TVTileStyle())
                                }
                            }
                            .padding(.horizontal, 80)
                        }
                    }
                    let devices = AccessoryStore.shared.all
                    if !devices.isEmpty {
                        VStack(alignment: .leading, spacing: 24) {
                            TVSectionTitle(text: "Devices")
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 40)], spacing: 40) {
                                ForEach(devices) { d in
                                    Button { toggle(d) } label: { DeviceCard(device: d) }
                                        .buttonStyle(TVTileStyle())
                                }
                            }
                            .padding(.horizontal, 80)
                        }
                    }
                    if home.speakers.isEmpty && home.lights.isEmpty && devices.isEmpty && !tvs.isEmpty {
                        Text("Speakers and lights show here once this Apple TV finds them on the Wi‑Fi.")
                            .font(.headline.weight(.regular)).foregroundStyle(.white.opacity(0.6))
                            .padding(.horizontal, 80)
                    }
                }
                .padding(.bottom, 80)
            }
            .background { TVBackdrop() }
        }
    }
}

/// A device on Home: on, off, lock or unlock with a click; the rest show how they are.
private func toggle(_ d: HomeDevice) {
    guard d.reachable else { return }
    if d.kind == .lock, let locked = d.locked {
        AccessoryStore.shared.send(d, .lock(!locked))
    } else if let on = d.isOn, d.kind != .washer, d.kind != .dryer, d.kind != .dishwasher, d.kind != .oven {
        AccessoryStore.shared.send(d, .power(!on))
    }
}

/// A device as on the iPhone's Home: the Samsung appliances drawn as themselves, the rest with how they are, ice-white
/// while on.
private struct DeviceCard: View {
    let device: HomeDevice

    var body: some View {
        let d = device
        let on = d.reachable && (d.isOn == true || d.machineState == "run" || d.locked == false)
        HStack(alignment: .center, spacing: 20) {
            if let look = d.bespokeLook {
                BespokeAppliance(model: look, running: d.machineState == "run", alert: d.alert)
                    .frame(width: 110, height: 150)
            }
            VStack(alignment: .leading, spacing: 8) {
                Spacer(minLength: 0)
                Text(d.name).font(.headline.bold()).lineLimit(2)
                Text(d.reachable ? d.status : AccessoryStore.shared.notResponding(d))
                    .font(.subheadline)
                    .lineLimit(2)
                    .opacity(0.75)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(on && d.bespokeLook == nil ? TVPalette.onInk : .white)
        .padding(28)
        .frame(width: 340, height: 210, alignment: .topLeading)
        .background {
            if on && d.bespokeLook == nil {
                RoundedRectangle(cornerRadius: 28, style: .continuous).fill(TVPalette.onTile)
            } else {
                RoundedRectangle(cornerRadius: 28, style: .continuous).fill(.white.opacity(0.06))
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            }
        }
        .overlay {
            if d.alert {
                RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(Color.orange, lineWidth: 3)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
    }
}

/// A TV as a wide picture: what it's playing filling the card (the library's picture, blurred behind), its name and
/// what's on over the bottom.
struct TVPlayingCard: View {
    @Environment(Fleet.self) private var fleet
    let tv: FleetTV
    var width: CGFloat

    var body: some View {
        let p = tv.nowPlaying
        let art = fleet.artwork(for: p)
        let url = fleet.hubClient(for: tv)?.art(art?.backdrop ?? art?.poster)
        ZStack(alignment: .bottomLeading) {
            if tv.online, url != nil {
                TVArt(url: url)
            } else {
                LinearGradient(colors: tv.online ? [TVPalette.steel, TVPalette.mid] : [TVPalette.mid.opacity(0.7), TVPalette.deep],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            LinearGradient(stops: [.init(color: .clear, location: 0.35), .init(color: .black.opacity(0.85), location: 1)],
                           startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 6) {
                Text(tv.name).font(.title3.bold()).foregroundStyle(.white).lineLimit(1)
                Text(status(p)).font(.headline.weight(.regular)).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                if let progress = p?.progress {
                    Capsule().fill(.white.opacity(0.25)).frame(height: 6)
                        .overlay(alignment: .leading) {
                            GeometryReader { g in Capsule().fill(.white).frame(width: g.size.width * progress) }
                        }
                        .padding(.top, 6)
                }
            }
            .padding(28)
        }
        .frame(width: width, height: width * 9 / 16)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .opacity(tv.online ? 1 : 0.7)
    }

    private func status(_ p: NowPlaying?) -> String {
        if !tv.online { return "Off" }
        guard let p else { return "On" }
        let app = p.app.map { " · \($0)" } ?? ""
        return p.title + app
    }
}

private struct SpeakerCard: View {
    let room: SonosRoom

    var body: some View {
        HStack(spacing: 26) {
            TVArt(url: room.art)
                .frame(width: 170, height: 170)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            VStack(alignment: .leading, spacing: 6) {
                Text(room.name).font(.title3.bold()).foregroundStyle(.white).lineLimit(1)
                Text(room.title ?? "Nothing playing").font(.headline.weight(.regular)).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                if let a = room.artist, !a.isEmpty {
                    Text(a).font(.headline.weight(.regular)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                }
                Text(room.isOffline ? "Not responding" : room.isPlaying ? "Playing" : "Paused")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(room.isPlaying ? TVPalette.ice : .white.opacity(0.5))
                    .padding(.top, 4)
            }
            .frame(width: 330, alignment: .leading)
        }
        .padding(24)
        .background {
            ZStack {
                if let art = room.art { TVArt(url: art).blur(radius: 40).opacity(0.55) }
                Color.black.opacity(0.25)
            }
        }
        .tvGlass(28)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
    }
}

private struct LightCard: View {
    let light: GoveeLight
    let name: String

    var body: some View {
        let on = light.on && light.offline != true
        VStack(alignment: .leading, spacing: 10) {
            Circle()
                .fill(dot)
                .frame(width: 34, height: 34)
                .overlay(Circle().strokeBorder(.black.opacity(on ? 0.15 : 0), lineWidth: 1))
            Spacer(minLength: 0)
            Text(name).font(.headline.bold()).lineLimit(2)
            Text(light.offline == true ? "Not responding" : on ? "On · \(light.brightness)%" : "Off")
                .font(.subheadline)
                .opacity(0.7)
        }
        .foregroundStyle(on ? TVPalette.onInk : .white)
        .padding(28)
        .frame(width: 340, height: 210, alignment: .topLeading)
        .background {
            if on {
                RoundedRectangle(cornerRadius: 28, style: .continuous).fill(TVPalette.onTile)
            } else {
                RoundedRectangle(cornerRadius: 28, style: .continuous).fill(.white.opacity(0.06))
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private var dot: Color {
        guard light.on, light.offline != true else { return .white.opacity(0.25) }
        if let c = light.color { return Color(red: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255) }
        return Color(red: 1, green: 0.8, blue: 0.5)
    }
}

// MARK: - TVs

/// Every TV, big and focusable: select one for its remote.
struct TVsTab: View {
    @Environment(Fleet.self) private var fleet

    var body: some View {
        NavigationStack {
            let tvs = fleet.tvs.filter { !$0.isUnpaired }
            ScrollView {
                if tvs.isEmpty {
                    ConnectPhoneCard().padding(80)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 520), spacing: 56)], spacing: 56) {
                        ForEach(tvs) { tv in
                            NavigationLink { TVRemoteView(tvID: tv.id) } label: { TVPlayingCard(tv: tv, width: 520) }
                                .buttonStyle(TVTileStyle())
                        }
                    }
                    .padding(80)
                }
            }
            .background { TVBackdrop() }
        }
    }
}

/// One TV's remote, as on the iPhone: what it's playing large behind, the round pad (arrows around OK), then Back,
/// Home and Play/Pause, and the volume and power.
struct TVRemoteView: View {
    @Environment(Fleet.self) private var fleet
    let tvID: String
    @State private var problem: String?

    var body: some View {
        let tv = fleet.tv(tvID)
        let art = fleet.artwork(for: tv?.nowPlaying)
        let url = tv.flatMap { fleet.hubClient(for: $0)?.art(art?.backdrop ?? art?.poster) }
        ZStack {
            TVBackdrop()
            if let url { TVArt(url: url).blur(radius: 60).opacity(0.45).ignoresSafeArea() }
            HStack(alignment: .center, spacing: 120) {
                VStack(alignment: .leading, spacing: 14) {
                    Text(tv?.name ?? "TV").font(.system(size: 56, weight: .bold)).foregroundStyle(.white)
                    if let p = tv?.nowPlaying {
                        Text(p.title).font(.title3).foregroundStyle(.white.opacity(0.85)).lineLimit(2)
                        if let app = p.app { Text(app).font(.headline.weight(.regular)).foregroundStyle(.white.opacity(0.6)) }
                    } else {
                        Text(tv?.online == true ? "On" : "Off").font(.title3).foregroundStyle(.white.opacity(0.7))
                    }
                    if let problem { Text(problem).font(.headline.weight(.regular)).foregroundStyle(TVPalette.ice).padding(.top, 10) }
                }
                .frame(width: 620, alignment: .leading)
                VStack(spacing: 50) {
                    // The round pad.
                    ZStack {
                        Circle().fill(.white.opacity(0.04)).frame(width: 470, height: 470)
                            .glassEffect(.regular, in: Circle())
                        VStack(spacing: 18) {
                            key("chevron.up", "Up", "up")
                            HStack(spacing: 18) {
                                key("chevron.left", "Left", "left")
                                key(nil, "OK", "ok", big: true)
                                key("chevron.right", "Right", "right")
                            }
                            key("chevron.down", "Down", "down")
                        }
                    }
                    HStack(spacing: 30) {
                        key("chevron.backward", "Back", "back")
                        key("house", "Home", "home")
                        key("playpause", "Play/Pause", "playpause")
                    }
                    HStack(spacing: 30) {
                        key("speaker.minus", "Volume Down", "voldown")
                        key("speaker.slash", "Mute", "mute")
                        key("speaker.plus", "Volume Up", "volup")
                        key("power", "Power", "power")
                    }
                }
            }
            .padding(80)
        }
    }

    private func key(_ symbol: String?, _ title: String, _ name: String, big: Bool = false) -> some View {
        Button { send(name) } label: {
            Group {
                if let symbol { Image(systemName: symbol).font(.system(size: 34, weight: .semibold)) }
                else { Text(title).font(.title3.bold()) }
            }
            .frame(width: big ? 150 : 110, height: big ? 150 : 110)
        }
        .buttonStyle(TVKeyStyle())
        .accessibilityLabel(title)
    }

    private func send(_ name: String) {
        guard let tv = fleet.tv(tvID), let c = fleet.client(for: tv) else { problem = "This TV can’t be reached."; return }
        Task {
            do { try await c.key(name); problem = nil } catch { problem = error.localizedDescription }
        }
    }
}

/// A round remote key: frosted, white with dark ink when the remote is on it.
struct TVKeyStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { TVKeyBody(configuration: configuration) }
}

private struct TVKeyBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isFocused) private var focused

    var body: some View {
        configuration.label
            .foregroundStyle(focused ? TVPalette.onInk : .white)
            .background {
                if focused { Circle().fill(TVPalette.onTile) } else { Circle().fill(.white.opacity(0.12)) }
            }
            .scaleEffect(configuration.isPressed ? 0.92 : (focused ? 1.1 : 1))
            .shadow(color: .black.opacity(focused ? 0.4 : 0), radius: 18, y: 8)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: focused)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
