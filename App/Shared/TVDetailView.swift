import SwiftUI
import WoodruffKit

/// One TV: its screen and what's playing, the transport, its health with a fix for each problem, sign-ins, updates,
/// and the extras (LG direct control, installing from the Mac, Wake-on-LAN, Link Again).
struct TVDetailView: View {
    @Environment(Fleet.self) private var fleet
    var tvID: String
    @State private var showScreen = false
    @State private var askRelink = false
    @State private var relinkCode = ""
    @State private var signIn: String?
    @State private var renaming = false
    @State private var newName = ""
    /// Play/pause as just pressed, shown until the TV's own answer arrives (or for 4 seconds, if it never changes).
    @State private var flipped: Bool?
    @State private var taps = 0
    /// Wake-on-LAN was just sent: "Turning On…" until the TV answers (or a minute passes).
    @State private var waking = false
    @State private var forgetting = false

    private var tv: FleetTV? { fleet.tv(tvID) }
    private var report: HealthReport? { fleet.healthReports[tvID] }

    var body: some View {
        if let tv, tv.isUnpaired {
            PairFoundTVView(tv: tv)
        } else if let tv {
            Form {
                Section { header(tv) }
                    .listRowInsets(EdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10))
                if let p = tv.playing {
                    Section { transport(tv, p) }.listRowBackground(Color.clear)
                }
                Section { verdict(tv) }
                if let items = report?.attention, !items.isEmpty, !tv.alertsHidden {
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
                AndroidRemoteSection(tv: tv)
                #if os(macOS)
                SSHSection(tv: tv)
                #endif
                actions(tv)
            }
            .familyFormStyle()
            .navigationTitle(tv.name)
            .inlineTitle()
            .task(id: "\(tvID)|\(fleet.isActive)") { await healthLoop() }
            .task(id: waking) { await watchWake() }
            // The TV's own answer replaces a play/pause guess the moment it arrives.
            .onChange(of: tv.playing?.isPlaying) { _, _ in flipped = nil }
            .sheet(isPresented: $showScreen) {
                Group { if tv.nowPlaying != nil { NowPlayingSheet(tvID: tvID) } else { TVScreenSheet(tvID: tvID) } }
                    .sheetBanner()
                    .macResizable(width: 640, height: 780)
            }
            .sheet(item: Binding(get: { signIn.map { SignInGrant(grant: $0) } }, set: { signIn = $0?.grant }),
                   onDismiss: { Task { await fleet.loadHealth(tv) } }) { SignInSheet(grant: $0.grant, tv: tv).macResizable() }
            .alert("Rename TV", isPresented: $renaming) {
                TextField("Name", text: $newName)
                Button("Save") { fleet.rename(tv, to: newName) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This is the name you’ll see on every iPhone and Mac in the family. Leave it empty for the TV’s own name.")
            }
            .alert("Link \(tv.name) Again", isPresented: $askRelink) {
                TextField("6-digit code", text: $relinkCode)
                Button("Link") { relink(tv) }.disabled(relinkCode.filter(\.isNumber).isEmpty)
                Button("Cancel", role: .cancel) { relinkCode = "" }
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
                    // What's playing now; else, while it's on and nothing plays, its screen as last captured (only then:
                    // the capture goes with the view the moment the TV goes off or starts playing, so it never comes back
                    // later showing what was on screen before).
                    if let p = tv.nowPlaying { NowPlayingArt(playing: p, backdrop: true) }
                    else if tv.online { TVScreenThumb(tvID: tvID, paused: showScreen) }
                    else { Text("Off").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.5)) }
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
        let playing = flipped ?? p.isPlaying
        return HStack(spacing: 24) {
            Spacer()
            if p.can("back10") { GlassCircle(symbol: "gobackward.10", size: 52) { media(tv, "back10") } }
            GlassCircle(symbol: playing ? "pause.fill" : "play.fill", size: 64) { media(tv, "playpause") }
            if p.can("fwd30") { GlassCircle(symbol: "goforward.30", size: 52) { media(tv, "fwd30") } }
            Spacer()
        }
        .glassGroup(spacing: 24)
    }

    // MARK: Health

    @ViewBuilder private func verdict(_ tv: FleetTV) -> some View {
        let attention = tv.alertsHidden ? 0 : (report?.attention?.count ?? tv.health?.count ?? 0)
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verdictTitle(tv, attention)).font(.title3.weight(.semibold))
                    .foregroundStyle(verdictColor(tv, attention) == .orange ? Palette.attention : .primary)
                Text(verdictLine(tv)).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        if tv.link == "refused" { Button("Link Again…") { askRelink = true } }
        if tv.needsAttention {
            Button("Hide These Alerts") { withAnimation { fleet.hideAlerts(tv) } }
        } else if tv.alertsHidden {
            Button("Show Hidden Alerts") { withAnimation { fleet.showAlerts(tv) } }
        }
    }

    private func attentionRow(_ tv: FleetTV, _ a: AttentionItem) -> some View {
        Menu {
            // The TV's words, pointing at Settings as it is now (a TV not yet updated names older pages).
            if let d = a.detail { Text(currentSettingsPaths(d)) }
            fix(tv, a)
        } label: {
            HStack(spacing: 12) {
                Text(a.words).foregroundStyle(Palette.attention)
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
        case "update": Button("Update Now") { run { try await fleet.pushUpdate(tv, now: true); fleet.say("Updating", "\(tv.name) is updating now. It restarts into the new version in a minute or two (after the film, if one is playing).") } }
        case "install":
            Button("Open Woodruff on \(tv.name)") {
                run {
                    // LG direct control reaches the TV whatever is on screen; otherwise Woodruff on the TV.
                    if let lg = fleet.lg(for: tv), let launchWoodruff = LGKeyMap.action(for: "home") {
                        try await launchWoodruff(lg)
                        fleet.poke(tv.id)
                    } else if let c = fleet.client(for: tv) {
                        try await c.key("home")
                    } else {
                        throw TVError.offline("\(tv.name) can’t be reached from here.")
                    }
                    fleet.say("Opening Woodruff", "Press Install on \(tv.name).")
                }
            }
        case "crash": if let rep = report?.lastCrash?.report { Button("Copy Crash Report") { copyToClipboard(rep) } }
        default: EmptyView()
        }
    }

    private func signInRow(_ tv: FleetTV, _ name: String, _ row: SignInRow) -> some View {
        LabeledContent(name) {
            Text(row.text ?? row.state ?? "").foregroundStyle(row.attention == true ? Palette.attention : .secondary)
        }
    }

    @ViewBuilder private func updates(_ tv: FleetTV) -> some View {
        Section("Updates") {
            LabeledContent("Version", value: report?.version ?? tv.version ?? "Unknown")
            if let p = fleet.platform(of: tv), let r = fleet.latest[p] { LabeledContent("Newest", value: r.version?.description ?? r.tag_name) }
            if let u = report?.updates?.text { LabeledContent("Status", value: u) }
            if let i = report?.installedBy?.summary { LabeledContent("Installs", value: i) }
            if let l = report?.lastUpdateTry?.text { LabeledContent("Last Try", value: l) }
            if fleet.platform(of: tv) != .webOS {
                ActionButton(action: { try await fleet.pushUpdate(tv, now: true); fleet.say("Updating", "\(tv.name) is updating now. It restarts into the new version in a minute or two (after the film, if one is playing).") }) {
                    Text("Update Now")
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
        let onRemote = fleet.selectedID == tv.id && !fleet.remoteAll
        Section {
            Button("Rename…") { newName = tv.name; renaming = true }
            Button(onRemote ? "Open the Remote" : "Use This TV for the Remote") { openRemote(tv) }
            if tv.isHub || fleet.hub(tv.id) != nil {
                PageLink("Smoothness Report") { DiagnosticsView(tv: tv) }
            }
            if fleet.extras[tv.id]?.mac != nil {
                Button(waking ? "Turning On…" : "Turn On (Wake-on-LAN)") { waking = true; fleet.wake(tv) }
                    .disabled(waking)
            }
            // A link that stopped working already offers this at the top.
            if !tv.isHub && tv.link != "refused" { Button("Link Again…") { askRelink = true } }
            if let hub = fleet.hub(tv.id) {
                Button("Forget This TV", role: .destructive) { forgetting = true }
                    .confirmationDialog("Forget \(tv.name)?", isPresented: $forgetting, titleVisibility: .visible) {
                        Button("Forget \(tv.name)", role: .destructive) { fleet.unpair(hub.id) }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("It’s forgotten on every iPhone and Mac in the family. To pair it again, scan the QR code on its Phone screen.")
                    }
            }
        }
    }

    // MARK: Work

    /// Puts the remote on [tv] and opens it (the remote's sidebar on the Mac, the Remote tab on iPhone).
    private func openRemote(_ tv: FleetTV) {
        fleet.remoteAll = false
        fleet.selectedID = tv.id
        #if os(macOS)
        withAnimation(.smooth) { fleet.remotePanel = true }
        #else
        UserDefaults.standard.set(AppSection.remote.rawValue, forKey: "section")
        #endif
    }

    private func media(_ tv: FleetTV, _ action: String) {
        // Play/pause answers at once; the TV's own answer replaces the guess as soon as it changes.
        if action == "playpause" {
            let next = !(flipped ?? tv.playing?.isPlaying ?? false)
            withAnimation(.snappy) { flipped = next }
        }
        taps += 1
        let tap = taps
        Task {
            do {
                guard let c = fleet.client(for: tv) else { throw TVError.offline("\(tv.name) can’t be reached from here.") }
                // The client tells the fleet, which asks the TV again at once and a moment later.
                if action == "playpause" { try await c.key("playpause") } else { try await c.media(action) }
                // The TV never changed (it ignored the key): show what it really says, not a button that lies.
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                if taps == tap && flipped != nil { withAnimation(.snappy) { flipped = nil } }
            } catch {
                flipped = nil
                fleet.show(error)
            }
        }
    }

    private func relink(_ tv: FleetTV) {
        let code = relinkCode.filter(\.isNumber)
        relinkCode = ""
        guard !code.isEmpty else { return }
        run {
            guard let c = fleet.client(for: tv) else { throw TVError.offline("\(tv.name) can’t be reached from here.") }
            let r = try await c.relink(code: code)
            fleet.say("Linked Again", "\(r.name) is linked.")
            await fleet.refresh()
        }
    }

    /// After Wake-on-LAN: waits for the TV to answer, and says so if it never does.
    private func watchWake() async {
        guard waking else { return }
        for _ in 0..<60 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if Task.isCancelled { return }
            if fleet.tv(tvID)?.online == true { waking = false; return }
        }
        waking = false
        let name = fleet.tv(tvID)?.name ?? "The TV"
        fleet.say("Still Off", "\(name) didn’t answer after the wake-up. On an LG, turn on Quick Start+ and “Turn on via Wi‑Fi” in its settings, then try again.")
    }

    private func run(_ op: @escaping () async throws -> Void) { Task { do { try await op() } catch { fleet.show(error) } } }

    private func healthLoop() async {
        // Not while the app isn't in use (the Mac's windows hidden): asked again once it is.
        guard fleet.isActive else { return }
        while !Task.isCancelled {
            if let t = fleet.tv(tvID) { await fleet.loadHealth(t) }
            try? await Task.sleep(nanoseconds: 15_000_000_000)
        }
    }

    // MARK: Words

    private func verdictTitle(_ tv: FleetTV, _ n: Int) -> String {
        if tv.link == "refused" && !tv.alertsHidden { return "Its Link Stopped Working" }
        if !tv.online { return "Off or Asleep" }
        if tv.health?.status == "old" { return "Update for Health Reports" }
        if n == 1 { return "1 Thing Needs Attention" }
        if n > 1 { return "\(n) Things Need Attention" }
        return report == nil ? "Checking…" : "All Good"
    }
    private func verdictLine(_ tv: FleetTV) -> String {
        if tv.alertsHidden { return "Alerts you’ve seen are hidden" }
        if let e = fleet.healthErrors[tvID], report == nil || !tv.online { return e }
        if let at = report?.at { return "Checked \(relative(at))" + (report?.via.map { " · via \($0)" } ?? "") }
        return "Asking \(tv.name)…"
    }
    private func verdictColor(_ tv: FleetTV, _ n: Int) -> Color {
        if !tv.online && tv.link != "refused" { return .gray }
        if (tv.link == "refused" && !tv.alertsHidden) || n > 0 { return .orange }
        return .green
    }
}

struct SignInGrant: Identifiable { var grant: String; var id: String { grant } }

/// A TV's screen as last captured, on its page while it's on and nothing plays: a fresh capture every 3 seconds (not
/// while the big screen is open over the page, which captures its own). A view of its own: each capture redraws only
/// this, not the whole page. It's there only while the TV is on and idle, and its capture goes with it.
struct TVScreenThumb: View {
    @Environment(Fleet.self) private var fleet
    var tvID: String
    var paused: Bool
    @State private var screen: PlatformImage?

    var body: some View {
        ZStack {
            if let screen { Image(platformImage: screen).resizable().aspectRatio(contentMode: .fill) }
        }
        .task(id: [paused, fleet.isActive]) {
            // Not while the big screen is open, nor while the app isn't in use (the Mac's windows hidden).
            guard !paused, fleet.isActive else { return }
            while !Task.isCancelled {
                if let t = fleet.tv(tvID), t.online, t.nowPlaying == nil, fleet.platform(of: t) != .webOS, let c = fleet.client(for: t),
                   let d = try? await c.screen(width: 480), !Task.isCancelled,
                   // Still on and idle now the capture is back (it may have started playing meanwhile).
                   let latest = fleet.tv(tvID), latest.online, latest.nowPlaying == nil {
                    screen = PlatformImage(data: d)
                }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }
}

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
            .task(id: fleet.isActive) { await loop() }
        }
        .presentationDetents([.medium, .large])
        #if os(macOS)
        .frame(minWidth: 640, idealWidth: 640, maxWidth: .infinity, minHeight: 520, idealHeight: 520, maxHeight: .infinity)
        #endif
    }

    private func loop() async {
        // Not while the app isn't in use (the Mac's windows hidden): live again once it is.
        guard fleet.isActive else { return }
        while !Task.isCancelled {
            var wait: UInt64 = 800_000_000
            if let tv = fleet.tv(tvID), let c = fleet.client(for: tv) {
                do {
                    let data = try await c.screen()
                    // Decoded off the main thread (it comes about every second), ready to draw.
                    let img = await Task.detached(priority: .userInitiated) { NowPlayingSheet.decode(data) }.value
                    if Task.isCancelled { return }
                    image = img
                    note = nil
                } catch {
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
    @State private var problem: String?

    /// The report is the TV's own (`/api/diagnostics` has no relay): always asked of the TV itself.
    private var client: TVClient? { fleet.hub(tv.id).map { TVClient(hub: $0, routeID: "this") } }

    /// Record three minutes, and copy the report.
    @ViewBuilder private var reportButtons: some View {
        Button(left > 0 ? "Recording · \(left)s" : "Record 3 Min") {
            Task {
                do {
                    guard let c = client else { throw TVError.notPaired }
                    left = try await c.recordDiagnostics()
                } catch { fleet.show(error) }
            }
        }
        .disabled(left > 0)
        Button { copyToClipboard(text) } label: { Image(systemName: "doc.on.doc") }
            .disabled(text.isEmpty)
            .accessibilityLabel("Copy Report")
    }

    var body: some View {
        ScrollView {
            Text(text.isEmpty ? (problem ?? "Loading…") : text).font(.caption.monospaced()).textSelection(.enabled)
                .foregroundStyle(text.isEmpty && problem != nil ? Palette.attention : .primary)
                .frame(maxWidth: .infinity, alignment: .leading).padding()
        }
        .navigationTitle("Smoothness Report").inlineTitle()
        #if os(iOS)
        .toolbar { ToolbarItemGroup(placement: .primaryAction) { reportButtons } }
        #elseif os(tvOS)
        // Apple TV: over the report itself. Opened from Settings the page is laid out as Settings' pages are
        // (`TVSettingsPage`), which have no bar across the top to hold them.
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: 20) {
                reportButtons
                Spacer(minLength: 0)
            }
            .padding(.bottom, 12)
        }
        #else
        .macPageBar { reportButtons.buttonStyle(.glass) }
        #endif
        .task {
            while !Task.isCancelled {
                if let c = client {
                    do {
                        let r = try await c.diagnostics()
                        text = r.0; left = r.1; problem = nil
                    } catch {
                        if Task.isCancelled { return }
                        problem = error.localizedDescription
                    }
                } else {
                    problem = "Pair with \(tv.name) directly to see its report."
                }
                // While recording, every few seconds (the countdown and the report move); otherwise every 30.
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
    /// The sign-in has ended, one way or the other (no more spinner; Try Again when it didn't work).
    @State private var finished = false
    @State private var attempt = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Text(done ? "Signed In" : finished ? "Not Signed In" : "Signing In").font(.title2.bold())
                Text(status).multilineTextAlignment(.center).foregroundStyle(.secondary)
                if !finished {
                    ProgressView()
                } else if !done {
                    Button("Try Again") { attempt += 1 }.buttonStyle(.glassProminent)
                }
            }
            .padding(30)
            .navigationTitle("Sign In on \(tv.name)").inlineTitle()
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(done ? "Done" : finished ? "Close" : "Cancel") { dismiss() } } }
            .task(id: attempt) { await run() }
        }
        .presentationDetents([.medium])
        .sheetBanner()
    }

    private func run() async {
        done = false
        finished = false
        status = "Starting…"
        await follow()
        if !Task.isCancelled { finished = true }
    }

    private func follow() async {
        guard let hub = fleet.hub(tv.id) else { status = "Pair with \(tv.name) directly to sign it in from here."; return }
        let c = TVClient(hub: hub, routeID: "this")
        let s: SignInStart
        do { s = try await c.startSignIn(grant) } catch { status = error.localizedDescription; return }
        guard let url = URL(string: s.authUrl) else { status = "\(tv.name) didn’t give a sign-in link. Try again."; return }
        status = "Pick your Google account and allow access. This follows along."
        openURL(url)
        let until = Date().addingTimeInterval(600)
        var misses = 0
        while Date() < until {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if Task.isCancelled { return }
            let st: SignInStatus
            do {
                st = try await c.signInStatus(state: s.state, grant: grant)
                misses = 0
            } catch {
                if Task.isCancelled { return }
                // A moment without an answer (this device was asleep in the browser, the Wi‑Fi blinked): keep following.
                misses += 1
                if misses >= 6 { status = error.localizedDescription; return }
                continue
            }
            if st.status == "finishing" { status = "Finishing on \(tv.name)…" }
            if st.isFinal {
                done = st.status == "signedIn"
                status = st.message ?? (done ? "\(tv.name) is signed in." : "Sign-in \(st.status).")
                if done && st.weekly == true { status += " Google ends test sign-ins after 7 days; publish the app in Google Cloud to stop that." }
                await fleet.loadHealth(tv)
                return
            }
        }
        status = "The sign-in wasn’t finished within 10 minutes. Try again."
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
                        .onSubmit { connect() }
                    Button(busy ? "Allow it on the TV…" : "Connect") { connect() }
                        .disabled(address.isEmpty || busy)
                }
            } header: { Text("LG Direct Control") } footer: {
                Text("LG lets Woodruff take keys only while it’s on screen. Connected directly, the remote works in every app, types into any keyboard, switches inputs, and turns \(tv.name) off and on.")
            }
            .onAppear { if host.isEmpty { host = fleet.extras[tv.id]?.lastHost ?? "" } }
        }
    }

    private var address: String { host.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func connect() {
        let h = address
        guard !h.isEmpty, !busy else { return }
        busy = true
        Task {
            do {
                try await fleet.connectLG(tv, host: h)
                fleet.say("Connected", "The remote now works in every app on \(tv.name).")
            } catch { fleet.show(error) }
            busy = false
        }
    }
}

/// Google TV and Android TV: the Android TV remote, paired once with the code the TV shows (see `AndroidTVRemote`).
struct AndroidRemoteSection: View {
    @Environment(Fleet.self) private var fleet
    var tv: FleetTV
    @State private var typedHost = ""
    @State private var code = ""
    @State private var askingCode = false
    @State private var busy = false

    private var remote: AndroidTVRemote { AndroidTVRemote.shared }

    var body: some View {
        if fleet.platform(of: tv) == .android {
            let known = fleet.androidAddress(for: tv)
            let host = known ?? typedHost.trimmingCharacters(in: .whitespacesAndNewlines)
            Section {
                if remote.isPaired(host: host) {
                    LabeledContent("Remote for Every App", value: "On")
                    Button("Forget", role: .destructive) { remote.forget(host: host) }
                } else if askingCode {
                    TextField("Enter the code on the TV", text: $code)
                        .autocorrectionDisabled()
                        #if os(iOS) || os(tvOS)
                        .textInputAutocapitalization(.characters)
                        #endif
                        .onSubmit { finish(host) }
                    Button(busy ? "Checking…" : "Done") { finish(host) }
                        .disabled(busy || code.filter(\.isHexDigit).count != 6)
                    Button("Cancel") { cancel(host) }
                } else {
                    if known == nil {
                        TextField("TV’s address, e.g. 192.168.1.40", text: $typedHost).autocorrectionDisabled()
                    }
                    LabeledContent("Remote for Every App") {
                        Button(busy ? "Pairing…" : "Pair") { start(host) }.disabled(busy || host.isEmpty)
                    }
                }
            } footer: {
                Text("Lets the remote work in every app and turn \(tv.name) on and off.")
            }
        }
    }

    private func start(_ host: String) {
        guard !host.isEmpty, !busy else { return }
        busy = true
        Task {
            do {
                try await remote.startPairing(host: host)
                code = ""
                askingCode = true
            } catch { fleet.show(error) }
            busy = false
        }
    }

    private func finish(_ host: String) {
        let typed = code.filter(\.isHexDigit)
        guard typed.count == 6, !busy else { return }
        busy = true
        Task {
            do {
                try await remote.finishPairing(host: host, code: typed)
                // An address typed here: kept as the TV's, so the remote finds it (see `Fleet.androidAddress`).
                if fleet.androidAddress(for: tv) != host { fleet.extras[tv.id, default: TVExtras()].lastHost = host }
                askingCode = false
                code = ""
                fleet.say("Paired", "The remote now works in every app on \(tv.name).")
            } catch {
                // A mistyped code can be typed again while the TV still shows it; otherwise start over.
                if !remote.isPairing(host: host) { askingCode = false }
                fleet.show(error)
            }
            busy = false
        }
    }

    private func cancel(_ host: String) {
        remote.cancelPairing(host: host)
        askingCode = false
        code = ""
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
                    Button("Save") {
                        let h = host.trimmingCharacters(in: .whitespacesAndNewlines)
                        fleet.extras[tv.id, default: TVExtras()].ssh = WebOSSSH(host: h, mode: mode, keyPath: keyPath.trimmingCharacters(in: .whitespacesAndNewlines))
                        result = "Saved. Software Update can install on \(tv.name) from this Mac now."
                    }
                    .disabled(host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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

/// A Woodruff TV heard on the Wi‑Fi that isn't paired yet: pair it with the key from its Phone screen.
struct PairFoundTVView: View {
    @Environment(Fleet.self) private var fleet
    var tv: FleetTV
    @State private var key = ""
    @State private var busy = false
    @State private var scanning = false
    /// Why the last try didn't pair (shown under the key, where it was typed).
    @State private var note: String?

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(tv.name).font(.title2.bold())
                    Text("Found on your Wi‑Fi\(tv.foundAt.map { " at \($0.host ?? "")" } ?? ""). Pair it once and it joins the others here.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            Section {
                #if os(iOS) || os(tvOS)
                Button("Scan Its QR Code") { scanning = true }
                #endif
                TextField("Pairing key", text: $key).autocorrectionDisabled()
                    #if os(iOS) || os(tvOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .onSubmit { pair(key) }
                Button(busy ? "Pairing…" : "Pair") { pair(key) }.disabled(key.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                if let note { Text(note).font(.footnote).foregroundStyle(Palette.attention) }
            } footer: {
                Text("On \(tv.name), open Woodruff → Settings → Phone connection. Scan the QR code, or type the key after “k=” in the link it shows.")
            }
        }
        .familyFormStyle()
        .navigationTitle(tv.name)
        .inlineTitle()
        #if os(iOS) || os(tvOS)
        .sheet(isPresented: $scanning) {
            let scanner = QRScannerView { code in
                scanning = false
                if let c = TVConnection.parse(code) { connect(c) }
                else { note = "That QR code isn’t a TV’s pairing code. Scan the one on \(tv.name)’s Phone screen." }
            }
            .ignoresSafeArea()
            #if os(iOS)
            // iPhone and iPad: a bar over the camera with a close button (as Pair a TV's scanner has).
            NavigationStack {
                scanner.toolbar { ToolbarItem(placement: .cancellationAction) { Button(role: .close) { scanning = false } } }
            }
            #else
            scanner
            #endif
        }
        #endif
    }

    private func pair(_ k: String) {
        let k = k.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty, !busy else { return }
        guard let base = tv.foundAt else { note = "\(tv.name) stopped answering on the Wi‑Fi. Make sure it’s on, then try again."; return }
        // A pasted link works too (the key is the part after “k=”).
        connect(TVConnection.parse(k) ?? TVConnection(base: base, key: k))
    }

    private func connect(_ c: TVConnection) {
        busy = true
        note = nil
        Task {
            do { let h = try await fleet.pair(c); fleet.say("Paired", "\(h.name) is connected.") } catch { note = error.localizedDescription }
            busy = false
        }
    }
}

/// Shows the fleet's banner (a result or an error) over a sheet: the window's own alert can't appear while a sheet
/// covers it, so a failure inside one went unseen until it closed. While the sheet is up it takes the banner itself.
struct SheetBanner: ViewModifier {
    @Environment(Fleet.self) private var fleet
    @State private var shown: Banner?
    /// The sheet opens sheets of its own that show the banner too (a TV's page: Now Playing over it). One of those
    /// that's open takes it first: this one, under it, could only show it once that closed. Left alone, it's shown here.
    var afterOwnSheets = false

    func body(content: Content) -> some View {
        content
            .onChange(of: fleet.banner) { _, b in
                guard let b else { return }
                guard afterOwnSheets else {
                    shown = b
                    fleet.banner = nil
                    return
                }
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    guard fleet.banner == b else { return }
                    shown = b
                    fleet.banner = nil
                }
            }
            .alert(shown?.title ?? "", isPresented: Binding(get: { shown != nil }, set: { if !$0 { shown = nil } }), presenting: shown) { _ in
                Button("OK", role: .cancel) {}
            } message: { b in
                Text(b.message)
            }
    }
}

extension View {
    /// See `SheetBanner`: for the content of a sheet or full-screen cover.
    func sheetBanner(afterOwnSheets: Bool = false) -> some View { modifier(SheetBanner(afterOwnSheets: afterOwnSheets)) }
}
