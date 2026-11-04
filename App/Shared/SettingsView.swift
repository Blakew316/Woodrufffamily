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
            let read = try await c.settings()
            // Only what changed: they're read every 20 seconds, and every page showing them would redraw each time.
            if read != s { s = read }
            if error != nil { error = nil }
        } catch {
            // What was read before stays (a TV that blinked off for a moment doesn't empty every page).
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }

    /// For a page that shows them: reads them unless they're read already. A read the page it was opened from had
    /// under way stops as that page goes behind this one, so this waits for that read to end first, then reads them
    /// itself if it ended without them (instead of leaving the page empty until the next read, 20 seconds later).
    func loadIfNeeded(_ fleet: Fleet) async {
        while loading {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if Task.isCancelled { return }
        }
        if s == nil { await load(fleet.hubClient()) }
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

/// In place of a page's rows until the TVs' settings are read: a spinner while they're being read, or why they
/// couldn't be, with Try Again (never a spinner that spins forever).
struct HubSettingsPending: View {
    @Environment(Fleet.self) private var fleet
    var hub: HubSettings

    var body: some View {
        if let e = hub.error {
            Section {
                Text("Can’t Read the Settings").font(.headline)
                Text(e).font(.subheadline).foregroundStyle(.secondary)
                ActionButton(action: { await hub.load(fleet.hubClient()) }) { Text("Try Again") }
            }
        } else {
            ProgressView().frame(maxWidth: .infinity)
        }
    }
}

/// Settings in five rows, grouped as iOS Settings groups things: TVs (every TV, Software Update, and one tap for all
/// of them) and Smart Home (speakers, lights, cameras, devices, the Wi‑Fi), with Send beside them on iPhone (it has no
/// tab there); Notifications, and Accounts (what the TVs sign in to); and General (Away From Home, Shortcuts, Sync
/// Across Devices, the TV's last crash).
struct SettingsView: View {
    @Environment(Fleet.self) private var fleet
    @State private var hub = HubSettings()
    @State private var route: String? = { let r = UserDefaults.standard.string(forKey: "route"); return r == "tvs" || r == "tv" ? r : nil }()
    // Read through UserDefaults, so a switch turned on Notifications (or synced from another device) shows at once.
    @AppStorage("notifyFleet") private var notifyFleet = true

    var body: some View {
        Form {
            Section {
                // Every TV, Software Update and one tap for all of them.
                PageLink("TVs") { TVsView() } label: { TVsSummaryRow() }
                // Speakers, lights, cameras, devices and the Wi‑Fi.
                PageLink("Smart Home") { SmartHomeSettingsView(hub: hub) } label: { SmartHomeSummaryRow() }
                #if os(iOS)
                // Messages, links and files to the TVs and phones: Send has no tab on iPhone (the Mac has it in its
                // sidebar), so it's here, where it's easy to find.
                PageLink("Send") { SendView() } label: {
                    IconRow(symbol: "", color: .clear, title: "Send", subtitle: "A message, photos, files or a link")
                }
                #endif
            }

            Section {
                // Alert choices, Now Playing on the Lock Screen, the cameras' alerts, recent messages, and (on the
                // Macs) Instant iPhone Alerts' push key.
                PageLink("Notifications") { PhoneSettingsView() } label: {
                    IconRow(symbol: "", color: .clear, title: "Notifications", value: notificationsSummary)
                }
                // What the TVs sign in to: Google Drive, movie posters, the Nest cameras, mail.
                PageLink("Accounts") { ConnectionsView(hub: hub) } label: {
                    IconRow(symbol: "", color: .clear, title: "Accounts", value: connectionsSummary)
                }
            }

            Section {
                // Away From Home, Shortcuts, Sync Across Devices, and the TV's last crash. Only a crash report shows
                // beside it: Sync Across Devices, inside, says how syncing is really going (read here, it would redraw
                // Settings at every sync round, every 12 seconds).
                PageLink("General") { GeneralSettingsView(hub: hub) } label: {
                    IconRow(symbol: "", color: .clear, title: "General", value: hasCrash ? "Crash Report" : nil, valueColor: Palette.attention)
                }
            }

            Section {
                Text("Woodruff Family \(hub.s?.version ?? "")")
                    .frame(maxWidth: .infinity).font(.footnote).foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            }
        }
        .formStyle(.grouped)
        .screenTitle("Settings")
        #if os(iOS)
        .navigationDestination(item: $route) { r in
            switch r {
            case "tv": TVDetailView(tvID: "tv-den")
            default: TVsView()
            }
        }
        #else
        .onAppear {
            guard let r = route else { return }
            route = nil
            if r == "tv" { MacNav.shared.push(fleet.tv("tv-den")?.name ?? "TV", backTo: "Settings", TVDetailView(tvID: "tv-den")) } else { MacNav.shared.push("TVs", backTo: "Settings", TVsView()) }
        }
        #endif
        // Reads the TVs' settings, again when the remote moves to a TV with another hub, and every 20 seconds: from
        // behind the page, so the TVs' reports every couple of seconds don't redraw it.
        .background { HubSettingsLoader(hub: hub) }
        .refreshable { await hub.load(fleet.hubClient()); await fleet.refresh() }
    }

    private var notificationsSummary: String { fleet.phone.alerts || notifyFleet ? "On" : "Off" }

    /// How many of the TVs' accounts are connected: Google Drive, movie posters, the Nest cameras, mail.
    private var connectionsSummary: String? {
        guard let s = hub.s else { return nil }
        let on = [s.google?.connected == true, s.tmdb == true, s.nest?.connected == true, !(s.mail ?? []).isEmpty].filter { $0 }.count
        return on == 0 ? "Not Set Up" : "\(on) Connected"
    }

    /// The TV that holds the settings has a crash report waiting.
    private var hasCrash: Bool { !(hub.s?.crash ?? "").isEmpty }
}

/// Settings' TVs row: one that needs attention, what's playing, or how many there are; and the red count of TVs with
/// an update waiting. A view of its own: the TVs report every couple of seconds, and only this row redraws then.
struct TVsSummaryRow: View {
    @Environment(Fleet.self) private var fleet

    var body: some View {
        HStack {
            IconRow(symbol: "", color: .clear, title: "TVs", value: tvsSummary, valueColor: fleet.tvs.contains(where: \.needsAttention) ? Palette.attention : .secondary)
            if fleet.updatesWaiting > 0 { UpdateCountBadge(count: fleet.updatesWaiting) }
        }
    }

    private var tvsSummary: String {
        let needing = fleet.tvs.filter(\.needsAttention)
        if needing.count == 1 { return "\(needing[0].name) needs attention" }
        if needing.count > 1 { return "\(needing.count) TVs need attention" }
        // Only what's really playing now (not a TV that's off, paused, or left paused).
        let playing = fleet.tvs.filter { $0.nowPlaying?.isPlaying == true }
        if playing.count == 1 { return "\(playing[0].name) · Playing" }
        if playing.count > 1 { return "\(playing.count) Playing" }
        return fleet.tvs.count == 1 ? fleet.tvs[0].name : "\(fleet.tvs.count) TVs"
    }
}

// MARK: - This phone

struct PhoneSettingsView: View {
    @Environment(Fleet.self) private var fleet
    @State private var topic: String?
    @State private var telling = false
    // Read and written through UserDefaults, so a change synced from another device shows here at once. (The Mac's
    // click sound for the remote's keys is in General.)
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
                #if os(iOS)
                Toggle("Now Playing on Lock Screen", isOn: $liveActivity)
                #endif
                Toggle("TV Alerts", isOn: $notifyFleet)
            } footer: {
                Text("Lock-screen alerts reach this device through the free ntfy app even when Woodruff is closed. TV alerts tell you when a TV goes off or needs attention.")
            }
            // The cameras' alerts on this device, with the rest of its alerts (the same switches as Smart Home →
            // Cameras, which is where the cameras are connected).
            if NestCameras.shared.connected {
                AlertsSection(title: "Doorbell & Cameras", showsReconnect: false)
            }
            #if os(macOS)
            // The push key the Macs send the iPhones' alerts with: set up once, so it has a page of its own.
            Section {
                PageLink("Instant iPhone Alerts") {
                    Form { PushSettingsSection() }
                        .formStyle(.grouped)
                        .navigationTitle("Instant iPhone Alerts")
                        .inlineTitle()
                } label: {
                    IconRow(symbol: "", color: .clear, title: "Instant iPhone Alerts", value: PushRelay.shared.hasKey ? "On" : "Not Set Up")
                }
            }
            #else
            // Not on a copy built without push (it can never have them). On one built with push it shows even before
            // this iPhone has signed up, with why it couldn't when it fails: nowhere else says so.
            if PushRelay.builtWithPush || PushRelay.shared.registered || PushRelay.shared.tokens[DeviceID.value] != nil {
                PushSettingsSection()
            }
            #endif
            Section {
                PageLink("Recent Messages") { RecentMessagesView() } label: {
                    IconRow(symbol: "", color: .clear, title: "Recent Messages", value: fleet.recentMessages.isEmpty ? "None" : "\(fleet.recentMessages.count)")
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

/// Every TV: what's playing, off, needs attention, link again. Tap one for its screen, controls and health. Below
/// them, Software Update and one tap for all of them.
struct TVsView: View {
    @Environment(Fleet.self) private var fleet
    @State private var pairing = false

    var body: some View {
        Form {
            Section {
                ForEach(fleet.tvs) { tv in
                    PageLink(tv.name) { TVDetailView(tvID: tv.id) } label: { TVRow(tv: tv) }
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
                PageLink("Software Update") { SoftwareUpdateView() } label: { SoftwareUpdateRow() }
            }
            EveryTVSection()
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
                // What's playing now (a title left paused reads as nothing playing, as on its Home tile).
                if let p = tv.nowPlaying, let d = p.duration, d > 0 {
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
        if let p = tv.nowPlaying { return (p.isPlaying ? "Playing " : "Paused · ") + p.title + (p.app.map { " · \($0)" } ?? "") }
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
                    // Only with something to install. (Check Now, under Newest Releases, has every TV look for itself.)
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
                ActionButton(action: { await checkNow() }) { Text("Check Now") }
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

    /// The newest releases from GitHub; every Android TV that's on looks for an update itself too (it installs one
    /// once nobody's watching), so a TV still finds one when GitHub can't be read from here; then every TV's version.
    private func checkNow() async {
        // Both at once: a TV slow to answer doesn't hold up GitHub.
        async let asked: (Int, [String]) = fleet.pushUpdateToAll()
        await fleet.checkReleases()
        let (_, failed) = await asked
        if !failed.isEmpty { log.insert("Couldn’t ask every TV to look: " + failed.joined(separator: "; "), at: 0) }
        await fleet.loadAllHealth()
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

// MARK: - Accounts and the other pages

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

/// Settings → Accounts: what the TVs sign in to (Google Drive, movie posters, the Nest cameras, mail), kept on the
/// TVs and copied to every TV linked to them.
struct ConnectionsView: View {
    @Environment(Fleet.self) private var fleet
    var hub: HubSettings

    var body: some View {
        Form {
            if let s = hub.s {
                Section {
                    PageLink("Google Drive") { DriveView(hub: hub) } label: { IconRow(symbol: "", color: .clear, title: "Google Drive", value: s.google?.statusText) }
                    PageLink("Movie Posters") { PostersView(hub: hub) } label: { IconRow(symbol: "", color: .clear, title: "Movie Posters", value: s.tmdb == true ? "On" : "Off") }
                    PageLink("Nest Cameras") { CamerasView(hub: hub) } label: { IconRow(symbol: "", color: .clear, title: "Nest Cameras", value: s.nest?.statusText) }
                    PageLink("Mail") { MailView(hub: hub) } label: { IconRow(symbol: "", color: .clear, title: "Mail", value: mailSummary(s)) }
                } footer: {
                    Text("Keys entered here are copied to every TV linked to \(fleet.hubClient()?.hub.name ?? "this TV"). Speakers, lights, appliances, the Wi‑Fi and this device’s cameras sign in on their own pages in Smart Home.")
                }
                if let e = hub.error {
                    Section { Text(e).font(.footnote).foregroundStyle(Palette.attention) }
                }
            } else {
                HubSettingsPending(hub: hub)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Accounts")
        .inlineTitle()
        .task { await hub.loadIfNeeded(fleet) }
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
        // A finished sign-in shows here (and on Accounts) as soon as the sheet closes.
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
                    fleet.say("Movie Posters", hub.s?.note ?? "Saved. Posters appear as the library refreshes.")
                }) { Text("Save") }
                // A blank Save would erase the key on every TV: only a key that's been typed can be saved.
                .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } footer: { Text("A free key from themoviedb.org adds official posters, genres and ratings. Your own poster.jpg files always win.") }
        }
        .formStyle(.grouped)
        .navigationTitle("Movie Posters").inlineTitle()
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
                    fleet.say("Nest Cameras", hub.s?.nest?.connected == true || p.isEmpty ? "Saved." : "Saved. Press Connect Cameras… to sign in.")
                }) { Text("Save") }
                    // Not before the TVs' settings are read: the fields would still be blank, and saving blanks
                    // clears the project (signing every TV out of the cameras) and the doorbell's subscription.
                    .disabled(hub.s == nil)
            }
            Section {
                Toggle("Person Alerts", isOn: Binding(get: { hub.s?.nest?.person ?? true }, set: { setAlert("person", $0) }))
                    .disabled(hub.s == nil)
                Toggle("Motion Alerts", isOn: Binding(get: { hub.s?.nest?.motion ?? false }, set: { setAlert("motion", $0) }))
                    .disabled(hub.s == nil)
            } footer: { Text(doorbellNote) }
        }
        .formStyle(.grouped)
        .navigationTitle("Nest Cameras").inlineTitle()
        // Opened before the settings were read (the read the page it came from started stops as this one opens).
        .task { await hub.loadIfNeeded(fleet) }
        .task { await hub.follow(fleet) }
        .onAppear { fill() }
        .onChange(of: hub.s?.nest?.project) { _, _ in fill() }
        .onChange(of: hub.s?.nest?.doorbell) { _, _ in fill() }
        .sheet(isPresented: $signIn, onDismiss: { Task { await hub.load(fleet.hubClient()) } }) { HubSignIn(grant: "cameras") }
    }

    private var doorbellNote: String {
        // The TV's words, pointing at where things are in Settings now (a TV not yet updated names older pages).
        if let s = hub.s?.nest?.doorbellStatus, !s.isEmpty { return currentSettingsPaths(s) }
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
            } else if hub.s != nil {
                Section { Text("Install Tailscale on the TV and this device, signed in to the same account. The TV then offers a link that works from anywhere.") }
            } else {
                // Not read yet: never "Install Tailscale" for a TV that may well have its link.
                HubSettingsPending(hub: hub)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Away From Home").inlineTitle()
        // Opened before the settings were read (the read General started stops as this page opens).
        .task { await hub.loadIfNeeded(fleet) }
    }
}

struct ShortcutsView: View {
    @Environment(Fleet.self) private var fleet
    var hub: HubSettings
    var body: some View {
        Form {
            if hub.s == nil {
                HubSettingsPending(hub: hub)
            }
            Section {
                if let u = hub.s?.shareUrl { Button("Copy “Share to TV” Link") { copyToClipboard(u) } }
                if let u = hub.s?.notifyUrl { Button("Copy Announcement Link") { copyToClipboard(u) } }
            } footer: {
                Text("In the Shortcuts app, add “Get Contents of URL” with Method POST and one of these links: share what you send to the TV, or announce on every TV (great for “When I get home”).")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Shortcuts").inlineTitle()
        // Opened before the settings were read (the read General started stops as this page opens).
        .task { await hub.loadIfNeeded(fleet) }
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
                    // Cleared: back to General, where its row has gone.
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

/// Settings → TVs → All TVs: one tap for all of them (it used to sit at the bottom of Home). Update All is on
/// Software Update, beside every TV's version.
struct EveryTVSection: View {
    @Environment(Fleet.self) private var fleet
    @State private var busy: String?

    var body: some View {
        Section {
            row("Pause All", "Everything that’s playing") { await keyAll("playpause", onlyPlaying: true) }
            row("Mute All", "Every TV that’s on") { await keyAll("mute") }
            row("Woodruff Home on All", "Every TV that’s on") { await keyAll("home") }
        } header: {
            Text("All TVs")
        }
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
            for tv in targets { g.addTask { await EveryTVSection.press(key, on: tv, fleet: f) } }
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

/// Settings → General → Sync Across Devices: where everything was last saved, and Sync Now.
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
