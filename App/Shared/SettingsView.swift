import SwiftUI
import WoodruffKit

/// The hub's settings, loaded once and shared by the Settings pages.
@Observable @MainActor final class HubSettings {
    var s: TVSettings?
    var loading = false
    /// Why the settings couldn't be read (the pages say so, with Try Again, instead of loading forever).
    var error: String?

    func load(_ c: TVClient?) async {
        guard let c else { error = TVError.notPaired.localizedDescription; return }
        loading = true
        defer { loading = false }
        do {
            s = try await c.settings()
            error = nil
        } catch {
            // What was read before stays (a TV that blinked off for a moment doesn't empty every page).
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }

    /// A save the TV answered with its new settings; nothing is changed when it didn't answer.
    func save(_ work: (TVClient) async throws -> TVSettings, on c: TVClient?) async throws {
        guard let c else { throw TVError.notPaired }
        s = try await work(c)
        error = nil
    }

    /// Reads them again every 20 seconds while a page shows them: another of the family's iPhones or Macs may have
    /// saved a key or signed a TV in meanwhile, and that shows here without leaving the page.
    func follow(_ fleet: Fleet) async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            if Task.isCancelled { return }
            if !loading { await load(fleet.hubClient()) }
        }
    }
}

/// Settings, as iOS Settings: this phone, TVs (status and health of every TV), Software Update, Connections,
/// Weather, Away From Home, Shortcuts.
struct SettingsView: View {
    @Environment(Fleet.self) private var fleet
    @State private var hub = HubSettings()
    @State private var route: String? = { let r = UserDefaults.standard.string(forKey: "route"); return r == "tvs" || r == "tv" ? r : nil }()

    var body: some View {
        Form {
            Section {
                NavigationLink { TVsView() } label: {
                    IconRow(symbol: "tv.fill", color: .blue, title: "TVs", value: tvsSummary, valueColor: fleet.tvs.contains(where: \.needsAttention) ? Palette.attention : .secondary)
                }
                NavigationLink { EveryTVView() } label: {
                    IconRow(symbol: "", color: .clear, title: "Every TV")
                }
                NavigationLink { SpeakersListView() } label: {
                    IconRow(symbol: "", color: .clear, title: "Speakers", value: SmartHome.shared.speakers.isEmpty ? "None" : "\(SmartHome.shared.speakers.count)")
                }
                NavigationLink { LightsListView() } label: {
                    IconRow(symbol: "", color: .clear, title: "Lights", value: SmartHome.shared.lights.isEmpty ? "None" : "\(SmartHome.shared.lights.count)")
                }
                NavigationLink { CamerasPhoneView() } label: {
                    IconRow(symbol: "", color: .clear, title: "Cameras", value: NestCameras.shared.connected ? "\(NestCameras.shared.cameras.count)" : "Not Connected")
                }
                NavigationLink { WifiView() } label: {
                    IconRow(symbol: "", color: .clear, title: "Wi‑Fi", value: DecoWifi.shared.connected ? (DecoWifi.shared.internetUp == false ? "Internet Down" : "\(DecoWifi.shared.nodes.count) Decos") : "Not Connected")
                }
                NavigationLink { DevicesListView() } label: {
                    IconRow(symbol: "", color: .clear, title: "Devices", value: AccessoryStore.shared.all.isEmpty ? "None" : "\(AccessoryStore.shared.all.count)")
                }
                NavigationLink { SoftwareUpdateView() } label: {
                    HStack {
                        IconRow(symbol: "", color: .clear, title: "Software Update")
                        if fleet.updatesWaiting > 0 {
                            Text("\(fleet.updatesWaiting)").font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                                .frame(minWidth: 22, minHeight: 22).background(Circle().fill(.red))
                        }
                    }
                }
            }

            Section {
                #if os(iOS)
                // Messages, links and files to the TVs and phones (the Mac has Send in its sidebar).
                NavigationLink { SendView() } label: { IconRow(symbol: "", color: .clear, title: "Send") }
                #endif
                // Alert choices, Now Playing on the Lock Screen, recent messages, and (on the Macs) Instant iPhone
                // Alerts' push key: the only way to reach them.
                NavigationLink { PhoneSettingsView() } label: {
                    IconRow(symbol: "", color: .clear, title: "Notifications", value: notificationsSummary)
                }
            }

            Section {
                NavigationLink { ConnectionsView(hub: hub) } label: {
                    IconRow(symbol: "cloud.fill", color: .blue, title: "Connections", value: connectionsSummary)
                }
            }

            Section {
                NavigationLink { AwayView(hub: hub) } label: {
                    IconRow(symbol: "globe", color: .green, title: "Away From Home", value: hub.s?.awayUrl?.isEmpty == false ? "On" : "Off")
                }
                NavigationLink { ShortcutsView(hub: hub) } label: {
                    IconRow(symbol: "square.2.layers.3d.fill", color: .purple, title: "Shortcuts")
                }
                if let crash = hub.s?.crash, !crash.isEmpty {
                    NavigationLink { CrashView(hub: hub) } label: { IconRow(symbol: "exclamationmark.triangle.fill", color: .red, title: "Last Crash on This TV") }
                }
            }

            SyncSection()

            Section {
                Text("Woodruff Family \(hub.s?.version ?? "")")
                    .frame(maxWidth: .infinity).font(.footnote).foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            }
        }
        .formStyle(.grouped)
        .screenTitle("Settings")
        .navigationDestination(item: $route) { r in
            switch r {
            case "tv": TVDetailView(tvID: "tv-den")
            default: TVsView()
            }
        }
        // Again when the remote moves to a TV with another hub (its keys and links are that hub's).
        .task(id: fleet.hubClient()?.hub.id) {
            SiriVocabulary.start()
            await hub.load(fleet.hubClient())
        }
        .refreshable { await hub.load(fleet.hubClient()); await fleet.refresh() }
        .task { await hub.follow(fleet) }
    }

    private var notificationsSummary: String {
        let alerts = UserDefaults.standard.object(forKey: "notifyFleet") as? Bool ?? true
        return fleet.phone.alerts || alerts ? "On" : "Off"
    }

    private var tvsSummary: String {
        let needing = fleet.tvs.filter(\.needsAttention)
        if needing.count == 1 { return "\(needing[0].name) needs attention" }
        if needing.count > 1 { return "\(needing.count) TVs need attention" }
        let playing = fleet.tvs.filter { $0.playing != nil }
        if playing.count == 1 { return "\(playing[0].name) · Playing" }
        if playing.count > 1 { return "\(playing.count) Playing" }
        return fleet.tvs.count == 1 ? fleet.tvs[0].name : "\(fleet.tvs.count) TVs"
    }

    private var connectionsSummary: String {
        guard let s = hub.s else { return "" }
        let on = [s.google?.connected == true, s.tmdb == true, s.nest?.connected == true, !(s.mail ?? []).isEmpty].filter { $0 }.count
        return "\(on) On"
    }
}

// MARK: - This phone

struct PhoneSettingsView: View {
    @Environment(Fleet.self) private var fleet
    @State private var topic: String?
    @State private var telling = false
    // Read and written through UserDefaults, so a change synced from another device shows here at once.
    @AppStorage("remoteClick") private var remoteClick = true
    @AppStorage("liveActivity") private var liveActivity = true
    @AppStorage("notifyFleet") private var notifyFleet = true

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { fleet.phone.alerts }, set: { setAlerts($0) })) {
                    HStack {
                        Text("Lock-Screen Alerts")
                        if telling { Spacer(); ProgressView().controlSize(.small) }
                    }
                }
                .disabled(telling)
                if fleet.phone.alerts, let topic {
                    LabeledContent("ntfy topic", value: topic)
                    Button("Copy Topic") { copyToClipboard(topic) }
                }
                #if os(macOS)
                Toggle("Click Sound on Remote Keys", isOn: $remoteClick)
                #endif
                #if os(iOS)
                Toggle("Now Playing on Lock Screen", isOn: $liveActivity)
                #endif
                Toggle("TV Alerts", isOn: $notifyFleet)
            } footer: {
                Text("Lock-screen alerts reach this device through the free ntfy app even when Woodruff is closed. TV alerts tell you when a TV goes off or needs attention.")
            }
            PushSettingsSection()
            Section("Recent Messages") {
                if fleet.recentMessages.isEmpty { Text("No messages in the last week.").foregroundStyle(.secondary) }
                ForEach(fleet.recentMessages) { m in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(m.title).font(.subheadline.weight(.semibold))
                        if let b = m.body, !b.isEmpty { Text(b).font(.subheadline) }
                        Text([m.from, m.at.map { Date(timeIntervalSince1970: $0 / 1000).formatted(date: .abbreviated, time: .shortened) }].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Notifications")
        .inlineTitle()
        #if os(iOS)
        // Takes effect at once: the Lock Screen's Now Playing ends (or starts) right away.
        .onChange(of: liveActivity) { _, _ in LiveActivitySync.shared.sync(fleet) }
        #endif
        .onChange(of: notifyFleet) { _, on in if on { Notifier.requestPermission() } }
        .task { await loadTopic() }
    }

    /// The ntfy topic the TVs use for this device (asked again each time the page opens).
    private func loadTopic() async {
        guard fleet.phone.alerts else { return }
        for h in fleet.hubs {
            if let r = try? await TVClient(hub: h, routeID: "this").hello(fleet.phone) {
                if let t = r.phone.topic { topic = t }
                return
            }
        }
    }

    /// Tells every paired TV; says so when none of them took it (the switch goes back to how it was).
    private func setAlerts(_ on: Bool) {
        let was = fleet.phone.alerts
        fleet.phone.alerts = on
        telling = true
        Task {
            var told = 0
            var problem: String?
            for h in fleet.hubs {
                do {
                    let r = try await TVClient(hub: h, routeID: "this").hello(fleet.phone, alerts: on)
                    told += 1
                    if let t = r.phone.topic { topic = t }
                } catch { problem = problem ?? "\(h.name): \(error.localizedDescription)" }
            }
            telling = false
            if told == 0 && !fleet.hubs.isEmpty {
                fleet.phone.alerts = was
                fleet.say("Couldn’t Change Lock-Screen Alerts", problem ?? "No TV answered.")
            }
        }
    }
}

// MARK: - TVs

/// Every TV: what's playing, off, needs attention, link again. Tap one for its screen, controls and health.
struct TVsView: View {
    @Environment(Fleet.self) private var fleet
    @State private var pairing = false

    var body: some View {
        Form {
            Section {
                ForEach(fleet.tvs) { tv in
                    NavigationLink { TVDetailView(tvID: tv.id) } label: { TVRow(tv: tv) }
                        .swipeActions {
                            if tv.needsAttention { Button("Hide Alerts") { withAnimation { fleet.hideAlerts(tv) } }.tint(.gray) }
                            else if tv.alertsHidden { Button("Show Alerts") { withAnimation { fleet.showAlerts(tv) } }.tint(.orange) }
                        }
                        .contextMenu {
                            if tv.needsAttention { Button("Hide Alerts") { fleet.hideAlerts(tv) } }
                            if tv.alertsHidden { Button("Show Hidden Alerts") { fleet.showAlerts(tv) } }
                        }
                }
            } footer: {
                Text("Tap a TV for its screen, controls and health. Swipe left on one to hide alerts you already know about.")
            }
            if fleet.attentionCount > 0 {
                Section {
                    Button("Hide All Alerts") { withAnimation { fleet.hideAllAlerts() } }
                } footer: {
                    Text("They come back if something new goes wrong.")
                }
            }
            Section {
                Button("Pair Another TV") { pairing = true }
            } footer: {
                Text("Pairing one TV brings every TV linked to it. Pair a second so the others stay reachable when one is off.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("TVs")
        .inlineTitle()
        .refreshable { await fleet.refresh(); await fleet.loadAllHealth() }
        .sheet(isPresented: $pairing) {
            NavigationStack {
                ScrollView { PairPanel().padding() }
                    .navigationTitle("Pair a TV")
                    .inlineTitle()
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button(role: .close) { pairing = false } } }
            }
            .sheetBanner()
            #if os(macOS)
            .frame(minWidth: 520, idealWidth: 520, maxWidth: .infinity, minHeight: 600, idealHeight: 600, maxHeight: .infinity)
            #endif
        }
    }
}

struct TVRow: View {
    @Environment(Fleet.self) private var fleet
    var tv: FleetTV

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(tv.name)
                    if tv.needsAttention { Circle().fill(Palette.attention).frame(width: 7, height: 7).accessibilityLabel("Needs attention") }
                }
                Text(line).font(.subheadline).foregroundStyle(tv.needsAttention && tv.link == "refused" ? Palette.attention : tv.isUnpaired ? Color.accentColor : .secondary).lineLimit(1)
                if let p = tv.playing, let d = p.duration, d > 0 {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        // From when the TV's answer arrived (as the player's bar does), so every screen agrees.
                        let pos = min(d, livePosition(p, at: ctx.date, since: fleet.refreshedAt))
                        GeometryReader { g in
                            Capsule().fill(.quaternary)
                                .overlay(alignment: .leading) { Capsule().fill(Color.accentColor).frame(width: g.size.width * pos / d) }
                        }
                        .frame(height: 3)
                    }
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
            if fleet.isBehind(tv) {
                Text("Update").font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var line: String {
        if tv.isUnpaired { return "Found on Wi‑Fi · Not paired" }
        if tv.link == "refused" { return tv.alertsHidden ? "Off · link stopped working" : "Link again" }
        if !tv.online { return "Off · seen \(relative(tv.seen))" }
        if let p = tv.playing { return (p.isPlaying ? "Playing " : "Paused · ") + p.title + (p.app.map { " · \($0)" } ?? "") }
        return tv.onScreen ? "Woodruff on screen" : "Nothing playing"
    }
}

// MARK: - Software Update

/// Like iOS Software Update: the newest Woodruff, every TV's version, and Update All.
struct SoftwareUpdateView: View {
    @Environment(Fleet.self) private var fleet
    @State private var log: [String] = []
    @State private var installing: Set<String> = []

    var body: some View {
        Form {
            Section {
                VStack(spacing: 12) {
                    Text(headline).font(.title3.weight(.semibold)).multilineTextAlignment(.center)
                    Text(subline).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    if fleet.updatesWaiting > 0 {
                        ActionButton(action: { await updateAll() }) {
                            Text("Update All TVs").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
                        }
                        .buttonStyle(.glassProminent)
                        .padding(.top, 4)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }

            Section {
                ForEach(fleet.tvs.filter { !$0.isUnpaired }) { tv in row(tv) }
            } header: { Text("TVs") } footer: {
                Text("Android TVs download the update and install it themselves as soon as nobody’s watching. LG TVs install from the Mac app over SSH.")
            }

            Section {
                ForEach(TVPlatform.allCases, id: \.self) { p in
                    LabeledContent(p.label) {
                        if let r = fleet.latest[p] { Text(r.version?.description ?? r.tag_name) }
                        else if let e = fleet.releaseErrors[p] { Text(e).font(.caption).foregroundStyle(Palette.attention).multilineTextAlignment(.trailing) }
                        else { ProgressView().controlSize(.small) }
                    }
                }
                ActionButton(action: { await fleet.checkReleases(); await fleet.loadAllHealth() }) { Text("Check Now") }
            } header: { Text("Newest Releases") }

            Section {
                GitHubTokenField()
            } footer: {
                Text("Only needed for LG TVs: the webOS releases are in a private repository. A fine-grained token with read access to Contents of Blakew316/woodrufffiles-webos.")
            }

            if !log.isEmpty {
                Section("Activity") { ForEach(Array(log.enumerated()), id: \.offset) { Text($0.element).font(.caption.monospaced()) } }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Software Update")
        .inlineTitle()
        .task { if fleet.latest.isEmpty { await fleet.checkReleases() }; await fleet.loadAllHealth() }
    }

    private var headline: String {
        if fleet.updatesWaiting == 0 { return "Every TV Is Up to Date" }
        return fleet.updatesWaiting == 1 ? "1 TV Has an Update" : "\(fleet.updatesWaiting) TVs Have an Update"
    }

    private var subline: String {
        guard let r = fleet.latest[.android] else { return "Checking GitHub…" }
        return "Woodruff Family \(r.version?.description ?? r.tag_name)" + (r.published_at.map { " · \($0.formatted(.relative(presentation: .named)))" } ?? "")
    }

    @ViewBuilder private func row(_ tv: FleetTV) -> some View {
        let p = fleet.platform(of: tv)
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(tv.name)
                Text([tv.version.map { "Version \($0)" } ?? "Version unknown", fleet.healthReports[tv.id]?.updates?.text].compactMap { $0 }.joined(separator: " · "))
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if installing.contains(tv.id) { ProgressView().controlSize(.small) }
            else if fleet.isBehind(tv) {
                if p == .webOS {
                    #if os(macOS)
                    Button("Install") { Task { await installWebOS(tv) } }.buttonStyle(.glass).disabled(fleet.extras[tv.id]?.ssh == nil)
                    #else
                    Text("On the Mac").font(.caption).foregroundStyle(.secondary)
                    #endif
                } else {
                    ActionButton(action: { try await fleet.pushUpdate(tv); log.insert("\(tv.name): checking for the update now.", at: 0) }) { Text("Update") }
                        .buttonStyle(.glass).disabled(!tv.online)
                }
            } else if tv.version != nil {
                Text("Up to Date").font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private func updateAll() async {
        let (n, failed) = await fleet.pushUpdateToAll()
        log.insert("Asked \(n) Android TV\(n == 1 ? "" : "s") to update." + (failed.isEmpty ? "" : " " + failed.joined(separator: "; ")), at: 0)
        #if os(macOS)
        for tv in fleet.tvs where fleet.platform(of: tv) == .webOS && fleet.isBehind(tv) && fleet.extras[tv.id]?.ssh != nil { await installWebOS(tv) }
        #endif
        try? await Task.sleep(nanoseconds: 10_000_000_000)
        await fleet.loadAllHealth()
    }

    #if os(macOS)
    private func installWebOS(_ tv: FleetTV) async {
        guard let ssh = fleet.extras[tv.id]?.ssh, let release = fleet.latest[.webOS] else { return }
        guard let asset = release.assets.first(where: { $0.name == "woodruff-family.ipk" }) ?? release.assets.first(where: { $0.name.hasSuffix(".ipk") }) else {
            log.insert("The release has no .ipk package.", at: 0); return
        }
        installing.insert(tv.id)
        defer { installing.remove(tv.id) }
        do {
            log.insert("Downloading \(asset.name)…", at: 0)
            let file = try await ReleaseFeed(token: fleet.githubToken).download(asset)
            try await WebOSInstaller.install(file, on: ssh) { line in Task { @MainActor in log.insert("\(tv.name): \(line)", at: 0) } }
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            await fleet.refresh()
        } catch { log.insert("\(tv.name): \(error.localizedDescription)", at: 0) }
    }
    #endif
}

// MARK: - Connections and the other pages

/// Saved when you press Return or leave it (not on every keystroke, which would check releases and sync each letter).
private struct GitHubTokenField: View {
    @Environment(Fleet.self) private var fleet
    @State private var text = ""
    @State private var loaded = false

    var body: some View {
        SecureField("GitHub token", text: $text)
            .onAppear { if !loaded { text = fleet.githubToken ?? ""; loaded = true } }
            .onSubmit { save() }
            .onDisappear { save() }
    }

    private func save() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t != (fleet.githubToken ?? "") else { return }
        fleet.githubToken = t.isEmpty ? nil : t
    }
}

struct ConnectionsView: View {
    @Environment(Fleet.self) private var fleet
    var hub: HubSettings

    var body: some View {
        Form {
            if let s = hub.s {
                Section {
                    NavigationLink { DriveView(hub: hub) } label: { IconRow(symbol: "externaldrive.fill.badge.icloud", color: .blue, title: "Google Drive", value: s.google?.statusText) }
                    NavigationLink { PostersView(hub: hub) } label: { IconRow(symbol: "film.fill", color: .orange, title: "Posters", value: s.tmdb == true ? "On" : "Off") }
                    NavigationLink { CamerasView(hub: hub) } label: { IconRow(symbol: "video.fill", color: .green, title: "Cameras", value: s.nest?.statusText) }
                    NavigationLink { MailView(hub: hub) } label: { IconRow(symbol: "envelope.fill", color: .blue, title: "Mail", value: mailSummary(s)) }
                } footer: {
                    Text("Keys entered here are copied to every TV linked to \(fleet.hubClient()?.hub.name ?? "this TV").")
                }
                if let e = hub.error {
                    Section { Text(e).font(.footnote).foregroundStyle(Palette.attention) }
                }
            } else if let e = hub.error {
                // Never a spinner that spins forever: say why, and let it be tried again.
                Section {
                    Text("Can’t Read the Settings").font(.headline)
                    Text(e).font(.subheadline).foregroundStyle(.secondary)
                    ActionButton(action: { await hub.load(fleet.hubClient()) }) { Text("Try Again") }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Connections")
        .inlineTitle()
        .task { if hub.s == nil && !hub.loading { await hub.load(fleet.hubClient()) } }
        .task { await hub.follow(fleet) }
    }

    private func mailSummary(_ s: TVSettings) -> String {
        let n = s.mail?.count ?? 0
        return n == 0 ? "Off" : "\(n)"
    }
}

/// The sign-in for [grant] on the TV that holds the settings (or why there's none).
private struct HubSignIn: View {
    @Environment(Fleet.self) private var fleet
    var grant: String

    var body: some View {
        if let tv = fleet.hubClient().flatMap({ fleet.tv($0.hub.id) }) {
            SignInSheet(grant: grant, tv: tv).macResizable()
        } else {
            EmptyState(symbol: "tv.slash", title: "No TV to Sign In", message: "Pair with a TV first, then sign it in from here.")
                .padding(30)
        }
    }
}

struct DriveView: View {
    @Environment(Fleet.self) private var fleet
    var hub: HubSettings
    @State private var clientID = ""
    @State private var secret = ""
    @State private var signIn = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Status", value: hub.s?.google?.statusText ?? "")
                if hub.s?.google?.connected != true { Button("Sign In…") { signIn = true } }
            }
            Section {
                TextField("Client ID", text: $clientID).autocorrectionDisabled()
                SecureField("Client secret", text: $secret)
                ActionButton(action: { try await save() }) { Text("Save") }
                    .disabled(clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } header: { Text("Keys") } footer: {
                Text("From Google Cloud → Credentials → OAuth client (Web application). Its redirect URI must be the one below.")
            }
            if let r = hub.s?.google?.redirectUri, !r.isEmpty {
                Section { Button("Copy Redirect URI") { copyToClipboard(r) } }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Google Drive").inlineTitle()
        .task { await hub.follow(fleet) }
        .onAppear { fill() }
        // The settings arrived after the page opened: fill in what was saved (never over what's being typed).
        .onChange(of: hub.s?.google?.clientId) { _, _ in fill() }
        // A finished sign-in shows here (and on Connections) as soon as the sheet closes.
        .sheet(isPresented: $signIn, onDismiss: { Task { await hub.load(fleet.hubClient()) } }) { HubSignIn(grant: "drive") }
    }

    private func fill() { if clientID.isEmpty { clientID = hub.s?.google?.clientId ?? "" } }

    private func save() async throws {
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let sec = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        try await hub.save({ try await $0.saveGoogle(clientID: id, secret: sec) }, on: fleet.hubClient())
        secret = ""
        fleet.say("Google Drive", hub.s?.google?.connected == true ? "Saved." : "Saved. Press Sign In… to connect the TV to Google Drive.")
    }
}

struct PostersView: View {
    @Environment(Fleet.self) private var fleet
    var hub: HubSettings
    @State private var key = ""
    var body: some View {
        Form {
            Section {
                LabeledContent("Status", value: hub.s?.tmdb == true ? "On" : "Off")
                SecureField("TMDB API key or read token", text: $key)
                ActionButton(action: {
                    let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
                    try await hub.save({ try await $0.saveTMDB(k) }, on: fleet.hubClient())
                    key = ""
                    fleet.say("Posters", hub.s?.note ?? "Saved. Posters appear as the library refreshes.")
                }) { Text("Save") }
            } footer: { Text("A free key from themoviedb.org adds official posters, genres and ratings. Your own poster.jpg files always win.") }
        }
        .formStyle(.grouped)
        .navigationTitle("Posters").inlineTitle()
        .task { await hub.follow(fleet) }
    }
}

struct CamerasView: View {
    @Environment(Fleet.self) private var fleet
    var hub: HubSettings
    @State private var project = ""
    @State private var doorbell = ""
    @State private var signIn = false
    var body: some View {
        Form {
            Section {
                LabeledContent("Status", value: hub.s?.nest?.statusText ?? "")
                if hub.s?.nest?.connected != true && !(hub.s?.nest?.project ?? "").isEmpty { Button("Connect Cameras…") { signIn = true } }
            }
            Section {
                TextField("Device Access project ID", text: $project).autocorrectionDisabled()
                TextField("Doorbell Pub/Sub subscription", text: $doorbell).autocorrectionDisabled()
                ActionButton(action: {
                    let p = project.trimmingCharacters(in: .whitespacesAndNewlines)
                    let d = doorbell.trimmingCharacters(in: .whitespacesAndNewlines)
                    try await hub.save({ try await $0.saveNest(["project": p, "doorbell": d]) }, on: fleet.hubClient())
                    fleet.say("Cameras", hub.s?.nest?.connected == true || p.isEmpty ? "Saved." : "Saved. Press Connect Cameras… to sign in.")
                }) { Text("Save") }
            }
            Section {
                Toggle("Person Alerts", isOn: Binding(get: { hub.s?.nest?.person ?? true }, set: { setAlert("person", $0) }))
                Toggle("Motion Alerts", isOn: Binding(get: { hub.s?.nest?.motion ?? false }, set: { setAlert("motion", $0) }))
            } footer: { Text(doorbellNote) }
        }
        .formStyle(.grouped)
        .navigationTitle("Cameras").inlineTitle()
        .task { await hub.follow(fleet) }
        .onAppear { fill() }
        .onChange(of: hub.s?.nest?.project) { _, _ in fill() }
        .sheet(isPresented: $signIn, onDismiss: { Task { await hub.load(fleet.hubClient()) } }) { HubSignIn(grant: "cameras") }
    }

    private var doorbellNote: String {
        if let s = hub.s?.nest?.doorbellStatus, !s.isEmpty { return s }
        return "Rings and people seen pop up on every TV."
    }

    private func fill() {
        if project.isEmpty { project = hub.s?.nest?.project ?? "" }
        if doorbell.isEmpty { doorbell = hub.s?.nest?.doorbell ?? "" }
    }

    /// Shows the switch's new place at once, and puts it back (saying why) if the TV doesn't take it.
    private func setAlert(_ field: String, _ on: Bool) {
        let before = hub.s
        if field == "person" { hub.s?.nest?.person = on } else { hub.s?.nest?.motion = on }
        Task {
            do { try await hub.save({ try await $0.saveNest([field: on]) }, on: fleet.hubClient()) }
            catch {
                hub.s = before
                fleet.show(error)
            }
        }
    }
}

struct MailView: View {
    @Environment(Fleet.self) private var fleet
    var hub: HubSettings
    @State private var adding = false
    var body: some View {
        Form {
            Section {
                ForEach(hub.s?.mail ?? []) { m in
                    LabeledContent(m.email, value: m.provider ?? "")
                        .swipeActions { Button("Remove", role: .destructive) { remove(m) } }
                        .contextMenu { Button("Remove", role: .destructive) { remove(m) } }
                }
                Button("Add Account") { adding = true }
            } footer: { Text("New mail shows up on the TVs. Use an app-specific password.") }
        }
        .formStyle(.grouped)
        .navigationTitle("Mail").inlineTitle()
        .task { await hub.follow(fleet) }
        .sheet(isPresented: $adding) { AddMailSheet(providers: hub.s?.providers ?? []) { if let s = $0 { hub.s = s } }.macResizable() }
    }

    private func remove(_ m: TVSettings.MailAccount) {
        Task {
            do { try await hub.save({ try await $0.deleteMail(m.id) }, on: fleet.hubClient()) }
            catch { fleet.show(error) }
        }
    }
}

struct WeatherView: View {
    @Environment(Fleet.self) private var fleet
    var hub: HubSettings
    @State private var place = ""
    var body: some View {
        Form {
            Section {
                TextField("City or ZIP", text: $place)
                ActionButton(action: {
                    let p = place.trimmingCharacters(in: .whitespacesAndNewlines)
                    try await hub.save({ try await $0.saveWeather(p) }, on: fleet.hubClient())
                }) { Text("Save") }
            } footer: { Text("Home’s greeting shows the morning’s weather and the date line the temperature. Leave it empty to turn it off.") }
        }
        .formStyle(.grouped)
        .navigationTitle("Weather on Home").inlineTitle()
        .onAppear { place = hub.s?.weather ?? "" }
    }
}

struct AwayView: View {
    @Environment(Fleet.self) private var fleet
    var hub: HubSettings
    var body: some View {
        Form {
            if let a = hub.s?.awayUrl, !a.isEmpty {
                Section {
                    Text(a).font(.footnote.monospaced()).textSelection(.enabled)
                    if let link = URL(string: a) { Button("Use This Link Here") { fleet.handle(url: link) } }
                    Button("Copy Link") { copyToClipboard(a) }
                } footer: { Text("Works anywhere through Tailscale, encrypted.") }
            } else {
                Section { Text("Install Tailscale on the TV and this device, signed in to the same account. The TV then offers a link that works from anywhere.") }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Away From Home").inlineTitle()
    }
}

struct ShortcutsView: View {
    var hub: HubSettings
    var body: some View {
        Form {
            Section {
                if let u = hub.s?.shareUrl { Button("Copy “Share to TV” Link") { copyToClipboard(u) } }
                if let u = hub.s?.notifyUrl { Button("Copy Announcement Link") { copyToClipboard(u) } }
            } footer: {
                Text("In the Shortcuts app, add “Get Contents of URL” with Method POST and one of these links: share what you send to the TV, or announce on every TV (great for “When I get home”).")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Shortcuts").inlineTitle()
    }
}

struct CrashView: View {
    @Environment(Fleet.self) private var fleet
    @Environment(\.dismiss) private var dismiss
    var hub: HubSettings
    var body: some View {
        Form {
            Section {
                Text((hub.s?.crash ?? "").split(separator: "\n").prefix(14).joined(separator: "\n")).font(.caption2.monospaced()).textSelection(.enabled)
            }
            Section {
                Button("Copy Report") { copyToClipboard(hub.s?.crash ?? "") }
                ActionButton(role: .destructive, action: {
                    try await hub.save({ try await $0.clearCrash() }, on: fleet.hubClient())
                    // Cleared: back to Settings, where its row has gone.
                    dismiss()
                }) { Text("Clear") }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Last Crash").inlineTitle()
    }
}

struct AddMailSheet: View {
    @Environment(Fleet.self) private var fleet
    @Environment(\.dismiss) private var dismiss
    var providers: [TVSettings.Provider]
    var done: (TVSettings?) -> Void
    @State private var provider = "ICLOUD"
    @State private var email = ""
    @State private var password = ""
    @State private var host = ""
    @State private var busy = false
    /// Why the TV didn't take the account (shown here, in the sheet, where it was typed).
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            Form {
                Picker("Provider", selection: $provider) { ForEach(providers) { Text($0.label).tag($0.id) } }
                TextField("Email", text: $email).autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never).keyboardType(.emailAddress)
                    #endif
                SecureField("App-specific password", text: $password)
                if providers.first(where: { $0.id == provider })?.custom == true { TextField("IMAP server", text: $host).autocorrectionDisabled() }
                if let help = providers.first(where: { $0.id == provider })?.help, !help.isEmpty { Text(help).font(.footnote).foregroundStyle(.secondary) }
                if let problem { Text(problem).font(.footnote).foregroundStyle(Palette.attention) }
            }
            .formStyle(.grouped)
            .navigationTitle("Add Account").inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(role: .close) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button { add() } label: { if busy { ProgressView() } else { Text("Add") } }
                        .buttonStyle(.glassProminent)
                        .disabled(email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty || busy)
                }
            }
        }
        .onAppear {
            // The TV's own list of providers: pick its first if the default isn't one of them.
            if !providers.contains(where: { $0.id == provider }), let first = providers.first { provider = first.id }
        }
        #if os(macOS)
        .frame(minWidth: 440, idealWidth: 440, maxWidth: .infinity, minHeight: 320, idealHeight: 320, maxHeight: .infinity)
        #endif
    }

    private func add() {
        busy = true
        problem = nil
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let server = host.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                guard let c = fleet.hubClient() else { throw TVError.notPaired }
                let s = try await c.addMail(provider: provider, email: address, password: password, host: server.isEmpty ? nil : server, port: nil)
                done(s)
                dismiss()
            } catch { problem = error.localizedDescription }
            busy = false
        }
    }
}

/// Settings → Every TV: one tap for all of them (it used to sit at the bottom of Home).
struct EveryTVView: View {
    @Environment(Fleet.self) private var fleet
    @State private var busy: String?

    var body: some View {
        Form {
            Section {
                row("Pause All", "Everything that’s playing") { await keyAll("playpause", onlyPlaying: true) }
                row("Mute All", "Every TV that’s on") { await keyAll("mute") }
                row("Woodruff Home on All", "Every TV that’s on") { await keyAll("home") }
            }
            Section {
                row("Update All", fleet.updatesWaiting == 0 ? "All up to date" : "\(fleet.updatesWaiting) waiting") {
                    let (n, failed) = await fleet.pushUpdateToAll()
                    if !failed.isEmpty { fleet.say("Update All", failed.joined(separator: "\n")) }
                    else if n == 0 { fleet.say("Update All", "No Android TV is on right now.") }
                    else { fleet.say("Update All", "Asked \(n) TV\(n == 1 ? "" : "s") to update. Each installs once nobody’s watching.") }
                }
            } footer: {
                Text("TVs install the update once nobody’s watching.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Every TV")
        .inlineTitle()
    }

    private func row(_ title: String, _ detail: String, _ run: @escaping () async -> Void) -> some View {
        Button {
            busy = title
            Task { await run(); busy = nil }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.primary)
                    Text(detail).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                if busy == title { ProgressView() }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(busy != nil)
    }

    /// [key] on every TV that's on (only those playing, for Pause All), as the remote sends it: LG direct control
    /// where it's connected (it reaches every app), otherwise Woodruff on the TV. Says which ones it didn't reach.
    private func keyAll(_ key: String, onlyPlaying: Bool = false) async {
        // What the TVs are doing now, not a while ago (Pause All must not start a paused one). The TVs are asked
        // every couple of seconds while the app is open, so this only waits after the app has been asleep.
        let fresh = fleet.refreshedAt.map { Date().timeIntervalSince($0) < 3 } ?? false
        if !fresh { await fleet.refresh() }
        let targets = fleet.tvs.filter { $0.online && !$0.isUnpaired && (!onlyPlaying || $0.playing?.isPlaying == true) }
        guard !targets.isEmpty else {
            fleet.say(onlyPlaying ? "Nothing Is Playing" : "No TV Is On", onlyPlaying ? "No TV is playing anything right now." : "Every TV is off or out of reach.")
            return
        }
        let f = fleet
        var failed: [String] = []
        // All at once: a TV that's slow to answer doesn't hold up the others.
        await withTaskGroup(of: String?.self) { g in
            for tv in targets { g.addTask { await EveryTVView.press(key, on: tv, fleet: f) } }
            for await problem in g { if let problem { failed.append(problem) } }
        }
        if !failed.isEmpty { fleet.say("Didn’t Reach Every TV", failed.sorted().joined(separator: "\n")) }
    }

    /// Presses [key] on [tv]: nil when it went through, else what went wrong.
    @MainActor private static func press(_ key: String, on tv: FleetTV, fleet: Fleet) async -> String? {
        do {
            if let lg = fleet.lg(for: tv), let action = LGKeyMap.action(for: key) {
                try await action(lg)
                // LG direct control doesn't pass through Woodruff: ask the TV what it's doing now.
                if key != "mute" { fleet.poke(tv.id) }
            } else if let c = fleet.client(for: tv) {
                // Woodruff tells the fleet itself, so every screen shows the change at once.
                try await c.key(key)
            } else {
                return "\(tv.name): can’t be reached from here."
            }
            return nil
        } catch {
            return "\(tv.name): \(error.localizedDescription)"
        }
    }
}

/// Settings → Sync Across Devices: where everything was last saved, and Sync Now.
struct SyncSection: View {
    private let sync = SettingsSync.shared
    @State private var busy = false

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 3) {
                Text(sync.status)
                if let t = sync.lastSynced {
                    Text(t, style: .relative).font(.footnote).foregroundStyle(.secondary) + Text(" ago").font(.footnote).foregroundStyle(.secondary)
                }
            }
            Button {
                busy = true
                Task { await sync.syncNow(); busy = false }
            } label: {
                HStack { Text("Sync Now"); if busy { Spacer(); ProgressView() } }
            }
            .disabled(busy)
        } header: { Text("Sync Across Devices") } footer: {
            Text("Keys, sign-ins, names, rooms, favourites, the Home layout and alert choices are kept on your TVs, so every iPhone and Mac paired with them has the same settings, even ones that were closed or away.")
        }
    }
}
