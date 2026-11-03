import SwiftUI
import WoodruffKit

/// One TV: its live picture, what's playing with controls, its health report and every fix, updates, linking, LG control.
struct TVDetailView: View {
    @Environment(Fleet.self) private var fleet
    var tvID: String
    @State private var screen: PlatformImage?
    @State private var screenNote: String?
    @State private var showScreen = false
    @State private var relinkCode = ""
    @State private var askRelink = false
    @State private var lgHost = ""
    @State private var signIn: String?

    var tv: FleetTV? { fleet.tv(tvID) }
    var report: HealthReport? { fleet.healthReports[tvID] }

    var body: some View {
        if let tv {
            Form {
                screenSection(tv)
                if let p = tv.playing { playingSection(tv, p) }
                verdictSection(tv)
                if let r = report {
                    if let items = r.attention, !items.isEmpty { attentionSection(tv, items) }
                    signInsSection(tv, r)
                    updatesSection(tv, r)
                    stabilitySection(r)
                } else if fleet.healthErrors[tvID] == nil {
                    Section { HStack { ProgressView(); Text("Asking \(tv.name) how it's doing…").foregroundStyle(.secondary) } }
                }
                actionsSection(tv)
                LGSection(tv: tv)
                #if os(macOS)
                SSHSection(tv: tv)
                #endif
            }
            .formStyle(.grouped)
            .screenTitle(tv.name)
            .task(id: tvID) { await healthLoop(tv) }
            .task(id: "screen-\(tvID)") { await screenLoop() }
            .sheet(isPresented: $showScreen) { TVScreenSheet(tvID: tvID) }
            .sheet(item: Binding(get: { signIn.map { SignInGrant(grant: $0) } }, set: { signIn = $0?.grant })) { g in
                SignInSheet(grant: g.grant, tv: tv)
            }
            .alert("Link \(tv.name) again", isPresented: $askRelink) {
                TextField("6-digit code", text: $relinkCode)
                Button("Link") {
                    let code = relinkCode
                    relinkCode = ""
                    Task {
                        do {
                            let r = try await fleet.client(for: tv)?.relink(code: code)
                            fleet.say("Linked again", "\(r?.name ?? tv.name) is linked.")
                            await fleet.refresh()
                        } catch { fleet.show(error) }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("On \(tv.name), open Settings → TVs & phones → Other TVs → Link this TV to another, and type the code it shows.")
            }
        } else {
            EmptyState(symbol: "tv.slash", title: "TV not found", message: "It isn't linked any more.")
        }
    }

    // MARK: Sections

    @ViewBuilder private func screenSection(_ tv: FleetTV) -> some View {
        Section {
            Button { showScreen = true } label: {
                ZStack {
                    Rectangle().fill(.black)
                    if let screen { Image(platformImage: screen).resizable().aspectRatio(16 / 9, contentMode: .fit) }
                    else {
                        VStack(spacing: 6) {
                            Image(systemName: "tv").font(.largeTitle)
                            Text(screenNote ?? (tv.online ? "Loading the TV's picture…" : "Off")).font(.caption).multilineTextAlignment(.center)
                        }
                        .foregroundStyle(.white.opacity(0.7)).padding()
                    }
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
        } footer: {
            Text("Woodruff's own screens only (video shows black). LG TVs don't let apps share their screen.")
        }
    }

    @ViewBuilder private func playingSection(_ tv: FleetTV, _ p: NowPlaying) -> some View {
        Section("Now Playing") {
            NowPlayingRow(playing: p)
            MediaControls(tv: tv, playing: p)
        }
    }

    @ViewBuilder private func verdictSection(_ tv: FleetTV) -> some View {
        Section {
            HStack(alignment: .top) {
                Image(systemName: verdictSymbol(tv)).font(.title2).foregroundStyle(verdictColor(tv))
                VStack(alignment: .leading, spacing: 4) {
                    Text(verdictTitle(tv)).font(.headline)
                    if let s = report?.sentence { Text(s).font(.subheadline).foregroundStyle(.secondary) }
                    if let e = fleet.healthErrors[tvID] { Text(e).font(.subheadline).foregroundStyle(.secondary) }
                    if let via = report?.via { Text("Reported through \(via)").font(.caption).foregroundStyle(.tertiary) }
                }
            }
            if tv.link == "refused" {
                Button("Link Again…") { askRelink = true }
            }
        }
    }

    @ViewBuilder private func attentionSection(_ tv: FleetTV, _ items: [AttentionItem]) -> some View {
        Section("Needs Attention") {
            ForEach(items) { a in
                VStack(alignment: .leading, spacing: 6) {
                    Label(a.words, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    if let d = a.detail { Text(d).font(.caption).foregroundStyle(.secondary) }
                    fixButton(tv, a)
                }
                .padding(.vertical, 2)
            }
        }
    }

    @ViewBuilder private func fixButton(_ tv: FleetTV, _ a: AttentionItem) -> some View {
        switch a.fix {
        case "signin":
            if fleet.hub(tv.id) != nil, let g = a.grant { Button("Sign In from Here…") { signIn = g } }
            else { Text("Sign in on \(tv.name) itself (its screen shows a code to scan).").font(.caption) }
        case "update":
            ActionButton(action: { try await fleet.pushUpdate(tv); fleet.say("Checking for updates", "\(tv.name) checks now.") }) { Text("Check for Updates") }
        case "install":
            ActionButton(action: { try await fleet.client(for: tv)?.key("home"); fleet.say("Opening Woodruff", "Woodruff is opening on \(tv.name). Press Install there.") }) { Text("Open Woodruff on the TV") }
        case "crash":
            if let rep = report?.lastCrash?.report { Button("Copy Crash Report") { copyToClipboard(rep) } }
        case "keys":
            NavigationLink("Open Google Drive Settings") { ConnectionsView(hubID: tv.hubID) }
        default: EmptyView()
        }
    }

    @ViewBuilder private func signInsSection(_ tv: FleetTV, _ r: HealthReport) -> some View {
        if let rows = r.signIns?.rows, !rows.isEmpty {
            Section("Sign-Ins") {
                ForEach(rows, id: \.0) { name, row in
                    LabeledContent(name) {
                        Text(row.text ?? row.state ?? "").foregroundStyle(row.attention == true ? .orange : .secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder private func updatesSection(_ tv: FleetTV, _ r: HealthReport) -> some View {
        Section("Updates") {
            LabeledContent("Version", value: r.version ?? tv.version ?? "?")
            if let p = fleet.platform(of: tv), let newest = fleet.latest[p] {
                LabeledContent("Newest release", value: newest.version?.description ?? newest.tag_name)
            }
            if let u = r.updates?.text { LabeledContent("Status", value: u) }
            if let reason = r.updates?.reason { Text(reason).font(.caption).foregroundStyle(.secondary) }
            if let i = r.installedBy?.summary { LabeledContent("Installed", value: i) }
            if let l = r.lastUpdateTry?.text { LabeledContent("Last try", value: l) }
            if let ip = r.installPermission?.text { LabeledContent("Installing updates", value: ip) }
            if let pu = r.popUps?.text { LabeledContent("Pop-ups", value: pu) }
            if fleet.platform(of: tv) != .webOS {
                ActionButton(action: { try await fleet.pushUpdate(tv); fleet.say("Checking for updates", "\(tv.name) checks GitHub now and installs once nobody's using it.") }) {
                    Label("Check for Updates Now", systemImage: "arrow.down.circle")
                }
            } else {
                Text("LG TVs install updates through Homebrew Channel or the Mac app (Updates → Install on LG TVs).").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func stabilitySection(_ r: HealthReport) -> some View {
        Section("Stability & Space") {
            if let c = r.lastCrash {
                VStack(alignment: .leading) {
                    LabeledContent("Last crash", value: c.text ?? "")
                    if let s = c.summary { Text(s).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(6) }
                    if let rep = c.report { Button("Copy Crash Report") { copyToClipboard(rep) } }
                }
            }
            if let c = r.closedByAndroid?.text { LabeledContent("Closed by Android", value: c) }
            if let f = r.freeSpace?.text { LabeledContent("Free space", value: f) }
            if let k = r.keys?.text { LabeledContent("Keys", value: k) }
            if let up = r.uptime { LabeledContent("Running for", value: Duration.seconds(up / 1000).formatted(.units(allowed: [.days, .hours, .minutes], width: .abbreviated))) }
            Button("Copy Health Report") { copyToClipboard(r.asText) }
        }
    }

    @ViewBuilder private func actionsSection(_ tv: FleetTV) -> some View {
        Section("Actions") {
            Button { fleet.selectedID = tv.id } label: { Label("Use This TV for the Remote", systemImage: "appletvremote.gen4") }
            ActionButton(action: { try await fleet.client(for: tv)?.key("home") }) { Label("Open Woodruff Home", systemImage: "house") }
            if tv.isHub || fleet.hub(tv.id) != nil {
                NavigationLink { DiagnosticsView(tv: tv) } label: { Label("Smoothness Report", systemImage: "waveform.path.ecg") }
            }
            if let mac = fleet.extras[tv.id]?.mac {
                Button { WakeOnLAN.wake(mac: mac, lastHost: fleet.extras[tv.id]?.lastHost) } label: { Label("Turn On (Wake-on-LAN)", systemImage: "power") }
            }
            if !tv.isHub && tv.link != "refused" {
                Button("Link Again…") { askRelink = true }
            }
            if let hub = fleet.hub(tv.id) {
                Button("Forget This TV", role: .destructive) { fleet.unpair(hub.id) }
            }
        }
    }

    // MARK: Loops

    private func healthLoop(_ tv: FleetTV) async {
        while !Task.isCancelled {
            if let t = fleet.tv(tvID) { await fleet.loadHealth(t) }
            try? await Task.sleep(nanoseconds: 15_000_000_000)
        }
    }

    private func screenLoop() async {
        while !Task.isCancelled {
            if !showScreen, let t = fleet.tv(tvID), t.online, let c = fleet.client(for: t) {
                do {
                    let d = try await c.screen(width: 640)
                    screen = PlatformImage(data: d)
                    screenNote = nil
                } catch {
                    screen = nil
                    screenNote = error.localizedDescription
                    if fleet.platform(of: t) == .webOS { return }
                }
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
    }

    // MARK: Words

    private func verdictTitle(_ tv: FleetTV) -> String {
        if tv.link == "refused" { return "Its link stopped working" }
        if !tv.online { return "Off or asleep" }
        if report?.needsAttention == true || tv.health?.status == "attention" { return "Needs attention" }
        if tv.health?.status == "old" { return "Health reports start with the next version" }
        return report == nil ? "Checking…" : "Everything's working"
    }
    private func verdictSymbol(_ tv: FleetTV) -> String {
        if !tv.online { return "moon.zzz.fill" }
        if tv.needsAttention || report?.needsAttention == true { return "exclamationmark.triangle.fill" }
        return "checkmark.seal.fill"
    }
    private func verdictColor(_ tv: FleetTV) -> Color {
        if !tv.online { return .gray }
        if tv.needsAttention || report?.needsAttention == true { return .orange }
        return .green
    }
}

struct SignInGrant: Identifiable { var grant: String; var id: String { grant } }

/// ↺10, Play/Pause, 30↻, Next for what a TV plays.
struct MediaControls: View {
    @Environment(Fleet.self) private var fleet
    var tv: FleetTV
    var playing: NowPlaying

    var body: some View {
        HStack(spacing: 28) {
            Spacer()
            if playing.can("back10") { mediaButton("gobackward.10", "back10") }
            Button { send("playpause") } label: { Image(systemName: playing.isPlaying ? "pause.fill" : "play.fill").font(.title) }
            if playing.can("fwd30") { mediaButton("goforward.30", "fwd30") }
            if playing.can("next") { mediaButton("forward.end.fill", "next") }
            Spacer()
        }
        .buttonStyle(.borderless)
        .padding(.vertical, 4)
    }

    private func mediaButton(_ symbol: String, _ action: String) -> some View {
        Button { send(action) } label: { Image(systemName: symbol).font(.title2) }
    }

    private func send(_ action: String) {
        Task {
            do {
                guard let c = fleet.client(for: tv) else { return }
                if action == "playpause" { try await c.key("playpause") } else { try await c.media(action) }
                try? await Task.sleep(nanoseconds: 700_000_000)
                await fleet.refresh()
            } catch { fleet.show(error) }
        }
    }
}

/// The TV's live picture, about once a second, with its controls.
struct TVScreenSheet: View {
    @Environment(Fleet.self) private var fleet
    @Environment(\.dismiss) private var dismiss
    var tvID: String
    @State private var image: PlatformImage?
    @State private var note: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                ZStack {
                    Rectangle().fill(.black)
                    if let image { Image(platformImage: image).resizable().aspectRatio(contentMode: .fit) }
                    else { Text(note ?? "Loading…").foregroundStyle(.white.opacity(0.7)).padding().multilineTextAlignment(.center) }
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                if let tv = fleet.tv(tvID), let p = tv.playing {
                    NowPlayingRow(playing: p)
                    MediaControls(tv: tv, playing: p)
                }
                if let tv = fleet.tv(tvID) { MiniRemote(tv: tv) }
                Spacer()
            }
            .padding()
            .navigationTitle(fleet.tv(tvID)?.name ?? "TV")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await loop() }
        }
        #if os(macOS)
        .frame(minWidth: 640, minHeight: 600)
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

/// Arrows, OK and Back, for steering while watching the TV's picture.
struct MiniRemote: View {
    @Environment(Fleet.self) private var fleet
    var tv: FleetTV
    var body: some View {
        Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow { Color.clear.frame(width: 1, height: 1); key("chevron.up", "up"); Color.clear.frame(width: 1, height: 1) }
            GridRow { key("chevron.left", "left"); key("circle.fill", "ok"); key("chevron.right", "right") }
            GridRow { key("arrow.uturn.backward", "back"); key("chevron.down", "down"); key("house", "home") }
        }
    }
    private func key(_ symbol: String, _ k: String) -> some View {
        Button {
            Task { do { try await fleet.client(for: tv)?.key(k) } catch { fleet.show(error) } }
        } label: {
            Image(systemName: symbol).frame(width: 48, height: 40)
        }
        .buttonStyle(.bordered)
    }
}

/// The Smoothness Report (frame stats) with Record 3 Minutes.
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
        .navigationTitle("Smoothness Report")
        .toolbar {
            ToolbarItemGroup {
                Button(left > 0 ? "Recording… \(left)s" : "Record 3 Minutes") {
                    Task { do { left = try await fleet.client(for: tv)?.recordDiagnostics() ?? 0 } catch { fleet.show(error) } }
                }
                .disabled(left > 0)
                Button { copyToClipboard(text) } label: { Label("Copy", systemImage: "doc.on.doc") }
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

/// Signs this TV in to Google (Drive, Photos, Calendar, cameras) from here, on home Wi-Fi.
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
                Image(systemName: done ? "checkmark.circle.fill" : "person.badge.key").font(.system(size: 54)).foregroundStyle(done ? .green : .accentColor)
                Text(status).multilineTextAlignment(.center)
                if !done { ProgressView() }
            }
            .padding(30)
            .navigationTitle("Sign In on \(tv.name)")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(done ? "Done" : "Cancel") { dismiss() } } }
            .task { await run() }
        }
    }

    private func run() async {
        guard let hub = fleet.hub(tv.id) else { status = "Pair with \(tv.name) directly to sign it in from here."; return }
        let c = TVClient(hub: hub, routeID: "this")
        do {
            let s = try await c.startSignIn(grant)
            guard let url = URL(string: s.authUrl) else { return }
            status = "Pick your Google account in the browser and allow access. This page follows along."
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
