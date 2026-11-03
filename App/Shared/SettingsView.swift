import SwiftUI
import WoodruffKit

/// The hub's settings, loaded once and shared by the Settings pages.
@Observable @MainActor final class HubSettings {
    var s: TVSettings?
    var loading = false
    func load(_ c: TVClient?) async {
        guard let c else { return }
        loading = true
        defer { loading = false }
        s = try? await c.settings()
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

            Section {} footer: {
                Text("Woodruff Family \(hub.s?.version ?? "")")
                    .frame(maxWidth: .infinity).font(.footnote).padding(.top, 4)
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
        .task { await hub.load(fleet.hubClient()) }
        .refreshable { await hub.load(fleet.hubClient()); await fleet.refresh() }
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

    var body: some View {
        Form {
            Section {
                Toggle("Lock-Screen Alerts", isOn: Binding(get: { fleet.phone.alerts }, set: { on in
                    fleet.phone.alerts = on
                    Task {
                        for h in fleet.hubs {
                            if let r = try? await TVClient(hub: h, routeID: "this").hello(fleet.phone, alerts: on) { topic = r.phone.topic }
                        }
                    }
                }))
                if fleet.phone.alerts, let topic {
                    LabeledContent("ntfy topic", value: topic)
                    Button("Copy Topic") { copyToClipboard(topic) }
                }
                #if os(macOS)
                Toggle("Click Sound on Remote Keys", isOn: Binding(
                    get: { UserDefaults.standard.object(forKey: "remoteClick") as? Bool ?? true },
                    set: { UserDefaults.standard.set($0, forKey: "remoteClick") }))
                #endif
                #if os(iOS)
                Toggle("Now Playing on Lock Screen", isOn: Binding(
                    get: { UserDefaults.standard.object(forKey: "liveActivity") as? Bool ?? true },
                    set: { UserDefaults.standard.set($0, forKey: "liveActivity"); LiveActivitySync.shared.sync(fleet) }))
                #endif
                Toggle("TV Alerts", isOn: Binding(
                    get: { UserDefaults.standard.object(forKey: "notifyFleet") as? Bool ?? true },
                    set: { UserDefaults.standard.set($0, forKey: "notifyFleet"); if $0 { Notifier.requestPermission() } }))
            } footer: {
                Text("Lock-screen alerts reach this device through the free ntfy app even when Woodruff is closed. TV alerts tell you when a TV goes off or needs attention.")
            }
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
            #if os(macOS)
            .frame(minWidth: 520, minHeight: 600)
            #endif
        }
    }
}

struct TVRow: View {
    @Environment(Fleet.self) private var fleet
    var tv: FleetTV
    @State private var fetchedAt = Date()

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
                        let pos = min(d, (p.position ?? 0) + (p.isPlaying ? ctx.date.timeIntervalSince(fetchedAt) * 1000 : 0))
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
        .onChange(of: tv.playing) { _, _ in fetchedAt = Date() }
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
                ForEach(fleet.tvs) { tv in row(tv) }
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
                Button("Check Now") { Task { await fleet.checkReleases(); await fleet.loadAllHealth() } }
            } header: { Text("Newest Releases") }

            Section {
                SecureField("GitHub token", text: Binding(get: { fleet.githubToken ?? "" }, set: { fleet.githubToken = $0 }))
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

struct ConnectionsView: View {
    @Environment(Fleet.self) private var fleet
    var hub: HubSettings
    @State private var signIn: String?

    var body: some View {
        Form {
            if let s = hub.s {
                Section {
                    NavigationLink { DriveView(hub: hub) } label: { IconRow(symbol: "externaldrive.fill.badge.icloud", color: .blue, title: "Google Drive", value: s.google?.statusText) }
                    NavigationLink { PostersView(hub: hub) } label: { IconRow(symbol: "film.fill", color: .orange, title: "Posters", value: s.tmdb == true ? "On" : "Off") }
                    NavigationLink { CamerasView(hub: hub) } label: { IconRow(symbol: "video.fill", color: .green, title: "Cameras", value: s.nest?.statusText) }
                    NavigationLink { MailView(hub: hub) } label: { IconRow(symbol: "envelope.fill", color: .blue, title: "Mail", value: (s.mail ?? []).isEmpty ? "Off" : "\(s.mail!.count)") }
                } footer: {
                    Text("Keys entered here are copied to every TV linked to \(fleet.hubClient()?.hub.name ?? "this TV").")
                }
            } else { ProgressView() }
        }
        .formStyle(.grouped)
        .navigationTitle("Connections")
        .inlineTitle()
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
                ActionButton(action: { hub.s = try await fleet.hubClient()?.saveGoogle(clientID: clientID, secret: secret); secret = "" }) { Text("Save") }
            } header: { Text("Keys") } footer: {
                Text("From Google Cloud → Credentials → OAuth client (Web application). Its redirect URI must be the one below.")
            }
            if let r = hub.s?.google?.redirectUri, !r.isEmpty {
                Section { Button("Copy Redirect URI") { copyToClipboard(r) } }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Google Drive").inlineTitle()
        .onAppear { clientID = hub.s?.google?.clientId ?? "" }
        .sheet(isPresented: $signIn) { if let tv = fleet.hubClient().flatMap({ fleet.tv($0.hub.id) }) { SignInSheet(grant: "drive", tv: tv) } }
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
                    let r = try await fleet.hubClient()?.saveTMDB(key)
                    hub.s = r; key = ""
                    fleet.say("Posters", r?.note ?? "Saved. Posters appear as the library refreshes.")
                }) { Text("Save") }
            } footer: { Text("A free key from themoviedb.org adds official posters, genres and ratings. Your own poster.jpg files always win.") }
        }
        .formStyle(.grouped)
        .navigationTitle("Posters").inlineTitle()
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
                ActionButton(action: { hub.s = try await fleet.hubClient()?.saveNest(["project": project, "doorbell": doorbell]) }) { Text("Save") }
            }
            Section {
                Toggle("Person Alerts", isOn: Binding(get: { hub.s?.nest?.person ?? true }, set: { v in Task { hub.s = try? await fleet.hubClient()?.saveNest(["person": v]) } }))
                Toggle("Motion Alerts", isOn: Binding(get: { hub.s?.nest?.motion ?? false }, set: { v in Task { hub.s = try? await fleet.hubClient()?.saveNest(["motion": v]) } }))
            } footer: { Text(hub.s?.nest?.doorbellStatus?.isEmpty == false ? hub.s!.nest!.doorbellStatus! : "Rings and people seen pop up on every TV.") }
        }
        .formStyle(.grouped)
        .navigationTitle("Cameras").inlineTitle()
        .onAppear { project = hub.s?.nest?.project ?? ""; doorbell = hub.s?.nest?.doorbell ?? "" }
        .sheet(isPresented: $signIn) { if let tv = fleet.hubClient().flatMap({ fleet.tv($0.hub.id) }) { SignInSheet(grant: "cameras", tv: tv) } }
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
                        .swipeActions { Button("Remove", role: .destructive) { Task { hub.s = try? await fleet.hubClient()?.deleteMail(m.id) } } }
                        .contextMenu { Button("Remove", role: .destructive) { Task { hub.s = try? await fleet.hubClient()?.deleteMail(m.id) } } }
                }
                Button("Add Account") { adding = true }
            } footer: { Text("New mail shows up on the TVs. Use an app-specific password.") }
        }
        .formStyle(.grouped)
        .navigationTitle("Mail").inlineTitle()
        .sheet(isPresented: $adding) { AddMailSheet(providers: hub.s?.providers ?? []) { hub.s = $0 } }
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
                ActionButton(action: { hub.s = try await fleet.hubClient()?.saveWeather(place) }) { Text("Save") }
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
                    Button("Use This Link Here") { fleet.handle(url: URL(string: a)!) }
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
    var hub: HubSettings
    var body: some View {
        Form {
            Section {
                Text((hub.s?.crash ?? "").split(separator: "\n").prefix(14).joined(separator: "\n")).font(.caption2.monospaced()).textSelection(.enabled)
            }
            Section {
                Button("Copy Report") { copyToClipboard(hub.s?.crash ?? "") }
                ActionButton(role: .destructive, action: { hub.s = try await fleet.hubClient()?.clearCrash() }) { Text("Clear") }
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

    var body: some View {
        NavigationStack {
            Form {
                Picker("Provider", selection: $provider) { ForEach(providers) { Text($0.label).tag($0.id) } }
                TextField("Email", text: $email).autocorrectionDisabled()
                SecureField("App-specific password", text: $password)
                if providers.first(where: { $0.id == provider })?.custom == true { TextField("IMAP server", text: $host) }
                if let help = providers.first(where: { $0.id == provider })?.help, !help.isEmpty { Text(help).font(.footnote).foregroundStyle(.secondary) }
            }
            .formStyle(.grouped)
            .navigationTitle("Add Account").inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(role: .close) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button { add() } label: { if busy { ProgressView() } else { Text("Add") } }
                        .buttonStyle(.glassProminent).disabled(email.isEmpty || password.isEmpty || busy)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 320)
        #endif
    }

    private func add() {
        busy = true
        Task {
            do { done(try await fleet.hubClient()?.addMail(provider: provider, email: email, password: password, host: host.isEmpty ? nil : host, port: nil)); dismiss() }
            catch { fleet.show(error) }
            busy = false
        }
    }
}
