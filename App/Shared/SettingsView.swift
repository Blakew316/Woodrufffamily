import SwiftUI
import WoodruffKit

/// Settings: this device, paired TVs, each hub's connections (Drive, posters, cameras, mail), weather,
/// away from home, shortcuts, the last crash, alerts and the GitHub token for webOS updates.
struct SettingsView: View {
    @Environment(Fleet.self) private var fleet
    @State private var addingTV = false

    var body: some View {
        @Bindable var fleet = fleet
        Form {
            Section("This Device") {
                TextField("Name", text: $fleet.phone.name)
                    .onSubmit { Task { await fleet.sayHelloEverywhere() } }
                Toggle("Lock-Screen Alerts (ntfy)", isOn: Binding(get: { fleet.phone.alerts }, set: { on in
                    fleet.phone.alerts = on
                    Task {
                        for h in fleet.hubs { _ = try? await TVClient(hub: h, routeID: "this").hello(fleet.phone, alerts: on) }
                    }
                }))
                NavigationLink("Recent Messages") { MessagesView() }
                Toggle("Notify When a TV Goes Off or Needs Attention", isOn: Binding(
                    get: { UserDefaults.standard.object(forKey: "notifyFleet") as? Bool ?? true },
                    set: { UserDefaults.standard.set($0, forKey: "notifyFleet"); if $0 { Notifier.requestPermission() } }))
            }

            Section {
                ForEach(fleet.hubs) { hub in
                    NavigationLink { ConnectionsView(hubID: hub.id) } label: {
                        VStack(alignment: .leading) {
                            Text(hub.name)
                            Text(hub.connection.base.absoluteString).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions { Button("Forget", role: .destructive) { fleet.unpair(hub.id) } }
                    .contextMenu { Button("Forget \(hub.name)", role: .destructive) { fleet.unpair(hub.id) } }
                }
                Button { addingTV = true } label: { Label("Pair Another TV", systemImage: "plus") }
            } header: {
                Text("Paired TVs")
            } footer: {
                Text("Each paired TV also brings the TVs linked to it. Pair more than one so the others stay reachable when one is off.")
            }

            Section {
                SecureField("GitHub token (for LG releases)", text: Binding(get: { fleet.githubToken ?? "" }, set: { fleet.githubToken = $0 }))
            } header: {
                Text("Updates")
            } footer: {
                Text("The Android app's releases are public. The webOS port's are in a private repository: a fine-grained token with read access to Contents of Blakew316/woodrufffiles-webos lets this app see them.")
            }

            Section {
                Text("Woodruff Family \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .screenTitle("Settings")
        .sheet(isPresented: $addingTV) {
            NavigationStack {
                ScrollView { PairPanel().padding() }
                    .navigationTitle("Pair a TV")
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { addingTV = false } } }
            }
            #if os(macOS)
            .frame(minWidth: 520, minHeight: 560)
            #endif
        }
    }
}

/// Messages sent to this device (announcements), kept for a week.
struct MessagesView: View {
    @Environment(Fleet.self) private var fleet
    var body: some View {
        List(fleet.recentMessages) { m in
            VStack(alignment: .leading, spacing: 3) {
                Text(m.title).font(.headline)
                if let b = m.body, !b.isEmpty { Text(b).font(.subheadline) }
                Text([m.from, m.at.map { Date(timeIntervalSince1970: $0 / 1000).formatted(date: .abbreviated, time: .shortened) }].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .overlay { if fleet.recentMessages.isEmpty { EmptyState(symbol: "tray", title: "No Messages", message: "Announcements sent to this device show up here.") } }
        .navigationTitle("Recent Messages")
    }
}

/// One hub's settings, the same as the phone page's Connections and the rest of its Settings tab.
struct ConnectionsView: View {
    @Environment(Fleet.self) private var fleet
    var hubID: String
    @State private var s: TVSettings?
    @State private var clientID = ""
    @State private var secret = ""
    @State private var tmdb = ""
    @State private var project = ""
    @State private var doorbell = ""
    @State private var weather = ""
    @State private var addingMail = false
    @State private var signIn: String?

    private var client: TVClient? { fleet.hub(hubID).map { TVClient(hub: $0, routeID: "this") } }

    var body: some View {
        Form {
            if let s {
                Section {
                    LabeledContent("Status", value: s.google?.statusText ?? "")
                    if s.google?.connected != true { Button("Sign In…") { signIn = "drive" } }
                    TextField("Client ID", text: $clientID).autocorrectionDisabled()
                    SecureField("Client secret", text: $secret)
                    save { self.s = try await client?.saveGoogle(clientID: clientID, secret: secret); secret = "" }
                    if let r = s.google?.redirectUri, !r.isEmpty { Button("Copy Redirect URI") { copyToClipboard(r) } }
                } header: { Text("Google Drive") } footer: { Text("Keys saved on one TV are copied to the TVs linked to it.") }

                Section("Posters (TMDB)") {
                    LabeledContent("Status", value: s.tmdb == true ? "On" : "Off")
                    SecureField("TMDB API key or read token", text: $tmdb)
                    save {
                        let r = try await client?.saveTMDB(tmdb)
                        self.s = r; tmdb = ""
                        fleet.say("Posters", r?.note ?? "Saved. Posters appear as the library refreshes.")
                    }
                }

                Section {
                    LabeledContent("Status", value: s.nest?.statusText ?? "")
                    if s.nest?.connected != true && !(s.nest?.project ?? "").isEmpty { Button("Connect Cameras…") { signIn = "cameras" } }
                    TextField("Device Access project ID", text: $project).autocorrectionDisabled()
                    TextField("Doorbell Pub/Sub subscription", text: $doorbell).autocorrectionDisabled()
                    save { self.s = try await client?.saveNest(["project": project, "doorbell": doorbell]) }
                    Toggle("Person alerts", isOn: Binding(get: { s.nest?.person ?? true }, set: { v in Task { self.s = try? await client?.saveNest(["person": v]) } }))
                    Toggle("Motion alerts", isOn: Binding(get: { s.nest?.motion ?? false }, set: { v in Task { self.s = try? await client?.saveNest(["motion": v]) } }))
                } header: { Text("Cameras") } footer: { Text(s.nest?.doorbellStatus?.isEmpty == false ? s.nest!.doorbellStatus! : "Doorbell rings and person alerts pop up on every TV.") }

                Section("Mail") {
                    ForEach(s.mail ?? []) { m in
                        LabeledContent(m.email, value: m.provider ?? "")
                            .swipeActions { Button("Remove", role: .destructive) { act { self.s = try await client?.deleteMail(m.id) } } }
                            .contextMenu { Button("Remove", role: .destructive) { act { self.s = try await client?.deleteMail(m.id) } } }
                    }
                    Button("Add Account…") { addingMail = true }
                }

                Section("Weather on Home") {
                    TextField("City or ZIP", text: $weather)
                    save { self.s = try await client?.saveWeather(weather) }
                }

                Section("Away From Home") {
                    if let a = s.awayUrl, !a.isEmpty {
                        Text(a).font(.caption.monospaced()).textSelection(.enabled)
                        Button("Pair Using This Link") { fleet.handle(url: URL(string: a)!) }
                        Button("Copy Link") { copyToClipboard(a) }
                    } else {
                        Text("Install Tailscale on the TV and this device (same account). The TV then offers a link that works anywhere.").font(.caption)
                    }
                }

                Section {
                    if let u = s.shareUrl { Button("Copy “Share to TV” Link") { copyToClipboard(u) } }
                    if let u = s.notifyUrl { Button("Copy Announcement Link") { copyToClipboard(u) } }
                } header: { Text("Shortcuts") } footer: { Text("Use these in the Shortcuts app: POST to the link to open what you share on the TV, or to announce on every TV (for automations like “when I get home”).") }

                if let crash = s.crash, !crash.isEmpty {
                    Section("Last Crash on This TV") {
                        Text(crash.split(separator: "\n").prefix(14).joined(separator: "\n")).font(.caption2.monospaced())
                        Button("Copy") { copyToClipboard(crash) }
                        save("Clear") { self.s = try await client?.clearCrash() }
                    }
                }

                Section { LabeledContent("Woodruff on this TV", value: s.version ?? "") }
            } else {
                ProgressView()
            }
        }
        .formStyle(.grouped)
        .navigationTitle(fleet.hub(hubID)?.name ?? "TV")
        .task { await load() }
        .sheet(isPresented: $addingMail) { if let s { AddMailSheet(providers: s.providers ?? []) { self.s = $0 } client: { client } } }
        .sheet(item: Binding(get: { signIn.map { SignInGrant(grant: $0) } }, set: { signIn = $0?.grant })) { g in
            if let tv = fleet.tv(hubID) { SignInSheet(grant: g.grant, tv: tv) }
        }
    }

    private func load() async {
        do {
            s = try await client?.settings()
            clientID = s?.google?.clientId ?? ""
            project = s?.nest?.project ?? ""
            doorbell = s?.nest?.doorbell ?? ""
            weather = s?.weather ?? ""
        } catch { fleet.show(error) }
    }

    private func save(_ title: String = "Save", _ op: @escaping () async throws -> Void) -> some View {
        ActionButton(action: op) { Text(title) }
    }

    private func act(_ op: @escaping () async throws -> Void) { Task { do { try await op() } catch { fleet.show(error) } } }
}

struct AddMailSheet: View {
    @Environment(Fleet.self) private var fleet
    @Environment(\.dismiss) private var dismiss
    var providers: [TVSettings.Provider]
    var done: (TVSettings?) -> Void
    var client: () -> TVClient?
    @State private var provider = "ICLOUD"
    @State private var email = ""
    @State private var password = ""
    @State private var host = ""
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Picker("Provider", selection: $provider) { ForEach(providers) { Text($0.label).tag($0.id) } }
                if let help = providers.first(where: { $0.id == provider })?.help { Text(help).font(.caption).foregroundStyle(.secondary) }
                TextField("Email", text: $email).autocorrectionDisabled()
                SecureField("App-specific password", text: $password)
                if providers.first(where: { $0.id == provider })?.custom == true { TextField("IMAP server", text: $host) }
            }
            .formStyle(.grouped)
            .navigationTitle("Add Mail Account")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(busy ? "Signing In…" : "Add") {
                        busy = true
                        Task {
                            do { done(try await client()?.addMail(provider: provider, email: email, password: password, host: host.isEmpty ? nil : host, port: nil)); dismiss() }
                            catch { fleet.show(error) }
                            busy = false
                        }
                    }
                    .disabled(email.isEmpty || password.isEmpty || busy)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 320)
        #endif
    }
}
