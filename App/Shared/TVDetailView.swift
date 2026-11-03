import SwiftUI
import WoodruffKit

/// One TV: its screen and what's playing, the transport, its health with a fix for each problem, sign-ins, updates,
/// and the extras (LG direct control, installing from the Mac, Wake-on-LAN, Link Again).
struct TVDetailView: View {
    @Environment(Fleet.self) private var fleet
    var tvID: String
    @State private var screen: PlatformImage?
    @State private var showScreen = false
    @State private var askRelink = false
    @State private var relinkCode = ""
    @State private var signIn: String?
    @State private var fetchedAt = Date()

    private var tv: FleetTV? { fleet.tv(tvID) }
    private var report: HealthReport? { fleet.healthReports[tvID] }

    var body: some View {
        if let tv {
            Form {
                Section { header(tv) }
                    .listRowInsets(EdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10))
                if let p = tv.playing {
                    Section { transport(tv, p) }.listRowBackground(Color.clear)
                }
                Section { verdict(tv) }
                if let items = report?.attention, !items.isEmpty {
                    Section {
                        ForEach(items) { a in attentionRow(tv, a) }
                    }
                }
                if let rows = report?.signIns?.rows, !rows.isEmpty {
                    Section("Sign-Ins") {
                        ForEach(rows, id: \.0) { name, row in signInRow(tv, name, row) }
                    }
                }
                updates(tv)
                if let r = report { more(r) }
                LGSection(tv: tv)
                #if os(macOS)
                SSHSection(tv: tv)
                #endif
                actions(tv)
            }
            .formStyle(.grouped)
            .navigationTitle(tv.name)
            .inlineTitle()
            .task(id: tvID) { await healthLoop() }
            .task(id: "screen-\(tvID)") { await screenLoop() }
            .onChange(of: tv.playing) { _, _ in fetchedAt = Date() }
            .sheet(isPresented: $showScreen) {
                if tv.playing != nil { NowPlayingSheet(tvID: tvID) } else { TVScreenSheet(tvID: tvID) }
            }
            .sheet(item: Binding(get: { signIn.map { SignInGrant(grant: $0) } }, set: { signIn = $0?.grant })) { SignInSheet(grant: $0.grant, tv: tv) }
            .alert("Link \(tv.name) Again", isPresented: $askRelink) {
                TextField("6-digit code", text: $relinkCode)
                Button("Link") { relink(tv) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("On \(tv.name): Settings → TVs & phones → Other TVs → Link this TV to another. Type the code it shows.")
            }
        } else {
            EmptyState(symbol: "tv.slash", title: "TV Not Found", message: "It isn’t linked any more.")
        }
    }

    // MARK: Header and transport

    private func header(_ tv: FleetTV) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Button { showScreen = true } label: {
                ZStack {
                    Rectangle().fill(.black)
                    if tv.playing != nil { NowPlayingArt(playing: tv.playing, backdrop: true) }
                    else if let screen { Image(platformImage: screen).resizable().aspectRatio(contentMode: .fill) }
                    else { Image(systemName: tv.online ? "tv" : "moon.zzz.fill").font(.title2).foregroundStyle(.white.opacity(0.5)) }
                }
                .frame(width: 136, height: 77)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.08)))
            }
            .buttonStyle(PressScale(scale: 0.96))
            VStack(alignment: .leading, spacing: 3) {
                if let p = tv.playing {
                    Text(p.title).font(.headline).lineLimit(2)
                    Text(p.app ?? "").font(.subheadline).foregroundStyle(.secondary)
                    LiveProgress(playing: p).padding(.top, 4)
                } else {
                    Text(tv.online ? "Nothing Playing" : "Off").font(.headline)
                    Text(tv.online ? (tv.onScreen ? "Woodruff is on screen" : "Another app is on screen") : "Seen \(relative(tv.seen))")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func transport(_ tv: FleetTV, _ p: NowPlaying) -> some View {
        HStack(spacing: 24) {
            Spacer()
            if p.can("back10") { GlassCircle(symbol: "gobackward.10", size: 52) { media(tv, "back10") } }
            GlassCircle(symbol: p.isPlaying ? "pause.fill" : "play.fill", size: 64) { media(tv, "playpause") }
            if p.can("fwd30") { GlassCircle(symbol: "goforward.30", size: 52) { media(tv, "fwd30") } }
            if p.can("next") { GlassCircle(symbol: "forward.end.fill", size: 52) { media(tv, "next") } }
            Spacer()
        }
        .glassGroup(spacing: 24)
    }

    // MARK: Health

    @ViewBuilder private func verdict(_ tv: FleetTV) -> some View {
        let attention = report?.attention?.count ?? tv.health?.count ?? 0
        HStack(spacing: 14) {
            Image(systemName: verdictSymbol(tv, attention)).font(.system(size: 30)).symbolRenderingMode(.multicolor)
                .foregroundStyle(verdictColor(tv, attention))
            VStack(alignment: .leading, spacing: 2) {
                Text(verdictTitle(tv, attention)).font(.title3.weight(.semibold))
                Text(verdictLine(tv)).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        if tv.link == "refused" { Button("Link Again…") { askRelink = true } }
    }

    private func attentionRow(_ tv: FleetTV, _ a: AttentionItem) -> some View {
        Menu {
            if let d = a.detail { Text(d) }
            fix(tv, a)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
                Text(a.words).foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
        }
        .menuStyle(.button).buttonStyle(.plain)
    }

    @ViewBuilder private func fix(_ tv: FleetTV, _ a: AttentionItem) -> some View {
        switch a.fix {
        case "signin":
            if fleet.hub(tv.id) != nil, let g = a.grant { Button("Sign In from Here") { signIn = g } }
            else { Text("Sign in on \(tv.name): its screen shows a code to scan.") }
        case "update": Button("Check for Updates") { run { try await fleet.pushUpdate(tv); fleet.say("Checking for Updates", "\(tv.name) checks now.") } }
        case "install": Button("Open Woodruff on \(tv.name)") { run { try await fleet.client(for: tv)?.key("home"); fleet.say("Opening Woodruff", "Press Install on \(tv.name).") } }
        case "crash": if let rep = report?.lastCrash?.report { Button("Copy Crash Report") { copyToClipboard(rep) } }
        default: EmptyView()
        }
    }

    private func signInRow(_ tv: FleetTV, _ name: String, _ row: SignInRow) -> some View {
        let (symbol, color): (String, Color) = {
            switch name {
            case "Google Drive": return ("externaldrive.fill", .blue)
            case "Google Photos": return ("photo.fill", .blue)
            case "Google Calendar": return ("calendar", .blue)
            case "Cameras": return ("video.fill", .green)
            default: return ("bell.fill", .red)
            }
        }()
        return IconRow(symbol: symbol, color: color, title: name, value: row.text ?? row.state ?? "",
                       valueColor: row.attention == true ? Palette.attention : .secondary)
    }

    @ViewBuilder private func updates(_ tv: FleetTV) -> some View {
        Section("Updates") {
            LabeledContent("Version", value: report?.version ?? tv.version ?? "Unknown")
            if let p = fleet.platform(of: tv), let r = fleet.latest[p] { LabeledContent("Newest", value: r.version?.description ?? r.tag_name) }
            if let u = report?.updates?.text { LabeledContent("Status", value: u) }
            if let i = report?.installedBy?.summary { LabeledContent("Installs", value: i) }
            if let l = report?.lastUpdateTry?.text { LabeledContent("Last Try", value: l) }
            if fleet.platform(of: tv) != .webOS {
                ActionButton(action: { try await fleet.pushUpdate(tv); fleet.say("Checking for Updates", "\(tv.name) checks GitHub now and installs once nobody’s watching.") }) {
                    Text("Check for Updates")
                }
                .disabled(!tv.online)
            }
        }
    }

    @ViewBuilder private func more(_ r: HealthReport) -> some View {
        Section("Stability & Space") {
            if let c = r.lastCrash { LabeledContent("Last Crash", value: c.text ?? "") }
            if let c = r.closedByAndroid?.text { LabeledContent("Closed by Android", value: c) }
            if let f = r.freeSpace?.text { LabeledContent("Free Space", value: f) }
            if let k = r.keys?.text { LabeledContent("Keys", value: k) }
            if let up = r.uptime { LabeledContent("Running For", value: Duration.seconds(up / 1000).formatted(.units(allowed: [.days, .hours, .minutes], width: .abbreviated, maximumUnitCount: 2))) }
            Button("Copy Health Report") { copyToClipboard(r.asText) }
        }
    }

    @ViewBuilder private func actions(_ tv: FleetTV) -> some View {
        Section {
            Button("Use This TV for the Remote") { fleet.remoteAll = false; fleet.selectedID = tv.id }
            if tv.isHub || fleet.hub(tv.id) != nil {
                NavigationLink("Smoothness Report") { DiagnosticsView(tv: tv) }
            }
            if let mac = fleet.extras[tv.id]?.mac {
                Button("Turn On (Wake-on-LAN)") { WakeOnLAN.wake(mac: mac, lastHost: fleet.extras[tv.id]?.lastHost) }
            }
            if !tv.isHub { Button("Link Again…") { askRelink = true } }
            if let hub = fleet.hub(tv.id) {
                Button("Forget This TV", role: .destructive) { fleet.unpair(hub.id) }
            }
        }
    }

    // MARK: Work

    private func media(_ tv: FleetTV, _ action: String) {
        run {
            guard let c = fleet.client(for: tv) else { return }
            if action == "playpause" { try await c.key("playpause") } else { try await c.media(action) }
            try? await Task.sleep(nanoseconds: 700_000_000)
            await fleet.refresh()
        }
    }

    private func relink(_ tv: FleetTV) {
        let code = relinkCode
        relinkCode = ""
        run {
            let r = try await fleet.client(for: tv)?.relink(code: code)
            fleet.say("Linked Again", "\(r?.name ?? tv.name) is linked.")
            await fleet.refresh()
        }
    }

    private func run(_ op: @escaping () async throws -> Void) { Task { do { try await op() } catch { fleet.show(error) } } }

    private func healthLoop() async {
        while !Task.isCancelled {
            if let t = fleet.tv(tvID) { await fleet.loadHealth(t) }
            try? await Task.sleep(nanoseconds: 15_000_000_000)
        }
    }

    private func screenLoop() async {
        while !Task.isCancelled {
            if !showScreen, let t = fleet.tv(tvID), t.online, t.playing == nil, fleet.platform(of: t) != .webOS, let c = fleet.client(for: t) {
                if let d = try? await c.screen(width: 480) { screen = PlatformImage(data: d) }
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
    }

    // MARK: Words

    private func verdictTitle(_ tv: FleetTV, _ n: Int) -> String {
        if tv.link == "refused" { return "Its Link Stopped Working" }
        if !tv.online { return "Off or Asleep" }
        if tv.health?.status == "old" { return "Update for Health Reports" }
        if n == 1 { return "1 Thing Needs Attention" }
        if n > 1 { return "\(n) Things Need Attention" }
        return report == nil ? "Checking…" : "All Good"
    }
    private func verdictLine(_ tv: FleetTV) -> String {
        if let e = fleet.healthErrors[tvID], report == nil || !tv.online { return e }
        if let at = report?.at { return "Checked \(relative(at))" + (report?.via.map { " · via \($0)" } ?? "") }
        return "Asking \(tv.name)…"
    }
    private func verdictSymbol(_ tv: FleetTV, _ n: Int) -> String {
        if !tv.online && tv.link != "refused" { return "moon.zzz.fill" }
        if tv.link == "refused" || n > 0 { return "exclamationmark.triangle.fill" }
        return "checkmark.circle.fill"
    }
    private func verdictColor(_ tv: FleetTV, _ n: Int) -> Color {
        if !tv.online && tv.link != "refused" { return .gray }
        if tv.link == "refused" || n > 0 { return .orange }
        return .green
    }
}

struct SignInGrant: Identifiable { var grant: String; var id: String { grant } }

/// The TV's screen, live, with what's playing (tap the screen on a TV's page).
struct TVScreenSheet: View {
    @Environment(Fleet.self) private var fleet
    @Environment(\.dismiss) private var dismiss
    var tvID: String
    @State private var image: PlatformImage?
    @State private var note: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
                ZStack {
                    Rectangle().fill(.black)
                    if let image { Image(platformImage: image).resizable().aspectRatio(contentMode: .fit) }
                    else { Text(note ?? "Loading…").font(.subheadline).foregroundStyle(.white.opacity(0.7)).padding().multilineTextAlignment(.center) }
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                if let tv = fleet.tv(tvID), let p = tv.playing {
                    VStack(spacing: 4) {
                        Text(p.title).font(.title3.weight(.semibold))
                        Text(p.app ?? "").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(20)
            .navigationTitle(fleet.tv(tvID)?.name ?? "TV").inlineTitle()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(role: .close) { dismiss() } } }
            .task { await loop() }
        }
        .presentationDetents([.medium, .large])
        #if os(macOS)
        .frame(minWidth: 640, minHeight: 520)
        #endif
    }

    private func loop() async {
        while !Task.isCancelled {
            var wait: UInt64 = 800_000_000
            if let tv = fleet.tv(tvID), let c = fleet.client(for: tv) {
                do { image = PlatformImage(data: try await c.screen()); note = nil } catch {
                    note = error.localizedDescription
                    wait = (error as? TVError)?.status == 409 ? 3_000_000_000 : 4_000_000_000
                }
            }
            try? await Task.sleep(nanoseconds: wait)
        }
    }
}

/// The Smoothness Report, with Record 3 Minutes.
struct DiagnosticsView: View {
    @Environment(Fleet.self) private var fleet
    var tv: FleetTV
    @State private var text = ""
    @State private var left = 0

    var body: some View {
        ScrollView {
            Text(text.isEmpty ? "Loading…" : text).font(.caption.monospaced()).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding()
        }
        .navigationTitle("Smoothness Report").inlineTitle()
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button(left > 0 ? "Recording · \(left)s" : "Record 3 Min") {
                    Task { do { left = try await fleet.client(for: tv)?.recordDiagnostics() ?? 0 } catch { fleet.show(error) } }
                }
                .disabled(left > 0)
                Button { copyToClipboard(text) } label: { Image(systemName: "doc.on.doc") }
            }
        }
        .task {
            while !Task.isCancelled {
                if let c = fleet.client(for: tv), let r = try? await c.diagnostics() { text = r.0; left = r.1 }
                try? await Task.sleep(nanoseconds: left > 0 ? 5_000_000_000 : 30_000_000_000)
            }
        }
    }
}

/// Signs a TV in to Google (Drive, Photos, Calendar, cameras) from here, on home Wi‑Fi.
struct SignInSheet: View {
    @Environment(Fleet.self) private var fleet
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    var grant: String
    var tv: FleetTV
    @State private var status = "Starting…"
    @State private var done = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Image(systemName: done ? "checkmark.circle.fill" : "person.badge.key.fill")
                    .font(.system(size: 56)).foregroundStyle(done ? Color.green : Color.accentColor)
                    .symbolEffect(.bounce, value: done)
                Text(status).multilineTextAlignment(.center).foregroundStyle(.secondary)
                if !done { ProgressView() }
            }
            .padding(30)
            .navigationTitle("Sign In on \(tv.name)").inlineTitle()
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(done ? "Done" : "Cancel") { dismiss() } } }
            .task { await run() }
        }
        .presentationDetents([.medium])
    }

    private func run() async {
        guard let hub = fleet.hub(tv.id) else { status = "Pair with \(tv.name) directly to sign it in from here."; return }
        let c = TVClient(hub: hub, routeID: "this")
        do {
            let s = try await c.startSignIn(grant)
            guard let url = URL(string: s.authUrl) else { return }
            status = "Pick your Google account and allow access. This follows along."
            openURL(url)
            let until = Date().addingTimeInterval(600)
            while Date() < until && !Task.isCancelled {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                let st = try await c.signInStatus(state: s.state, grant: grant)
                if st.status == "finishing" { status = "Finishing on \(tv.name)…" }
                if st.isFinal {
                    done = st.status == "signedIn"
                    status = st.message ?? (done ? "\(tv.name) is signed in." : "Sign-in \(st.status).")
                    if done && st.weekly == true { status += " Google ends test sign-ins after 7 days; publish the app in Google Cloud to stop that." }
                    await fleet.loadHealth(tv)
                    return
                }
            }
        } catch { status = error.localizedDescription }
    }
}

/// LG direct control on an LG TV's page: lets the one remote reach every app on it.
struct LGSection: View {
    @Environment(Fleet.self) private var fleet
    var tv: FleetTV
    @State private var host = ""
    @State private var busy = false

    var body: some View {
        if fleet.platform(of: tv) != .android {
            Section {
                if let h = fleet.extras[tv.id]?.lgHost {
                    LabeledContent("Connected", value: h)
                    if let mac = fleet.extras[tv.id]?.mac { LabeledContent("Wake-on-LAN", value: mac) }
                    Button("Disconnect", role: .destructive) { fleet.forgetLG(tv) }
                } else {
                    TextField("TV’s address, e.g. 192.168.1.40", text: $host).autocorrectionDisabled()
                    Button(busy ? "Allow it on the TV…" : "Connect") {
                        busy = true
                        Task {
                            do { try await fleet.connectLG(tv, host: host.trimmingCharacters(in: .whitespaces)); fleet.say("Connected", "The remote now works in every app on \(tv.name).") }
                            catch { fleet.show(error) }
                            busy = false
                        }
                    }
                    .disabled(host.isEmpty || busy)
                }
            } header: { Text("LG Direct Control") } footer: {
                Text("LG lets Woodruff take keys only while it’s on screen. Connected directly, the remote works in every app, types into any keyboard, switches inputs, and turns \(tv.name) off and on.")
            }
            .onAppear { if host.isEmpty { host = fleet.extras[tv.id]?.lastHost ?? "" } }
        }
    }
}

#if os(macOS)
/// Installing LG updates from this Mac over SSH (Developer Mode or rooted).
struct SSHSection: View {
    @Environment(Fleet.self) private var fleet
    var tv: FleetTV
    @State private var host = ""
    @State private var mode: WebOSSSH.Mode = .developerMode
    @State private var keyPath = ""
    @State private var result: String?

    var body: some View {
        if fleet.platform(of: tv) == .webOS {
            Section {
                TextField("Address", text: $host)
                Picker("Access", selection: $mode) { ForEach(WebOSSSH.Mode.allCases, id: \.self) { Text($0.label).tag($0) } }
                TextField("Private key", text: $keyPath, prompt: Text("~/.ssh/tv_webos"))
                HStack {
                    Button("Save") { fleet.extras[tv.id, default: TVExtras()].ssh = WebOSSSH(host: host, mode: mode, keyPath: keyPath); result = "Saved." }
                    Button("Test") {
                        let ssh = WebOSSSH(host: host, mode: mode, keyPath: keyPath)
                        result = "Testing…"
                        Task { result = await WebOSInstaller.test(ssh).map { "Failed: \($0)" } ?? "SSH works. Updates install from here." }
                    }
                }
                if let result { Text(result).font(.caption).foregroundStyle(.secondary) }
            } header: { Text("Install Updates from This Mac") } footer: {
                Text("Developer Mode: get the key once with ares-novacom --getkey (saved as ~/.ssh/tv_webos) and keep Dev Mode Status on.")
            }
            .onAppear {
                let s = fleet.extras[tv.id]?.ssh
                host = s?.host ?? fleet.extras[tv.id]?.lgHost ?? fleet.extras[tv.id]?.lastHost ?? ""
                mode = s?.mode ?? .developerMode
                keyPath = s?.keyPath ?? ""
            }
        }
    }
}
#endif
