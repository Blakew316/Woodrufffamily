import SwiftUI
import WoodruffKit

/// Updates for every TV: the newest release of each TV app, each TV's version, and pushing the update out.
/// Android TVs are asked to check now (each installs once nobody's using it). LG TVs are installed from the Mac
/// over SSH, as `webos/tools/install.sh --ssh` does.
struct UpdatesView: View {
    @Environment(Fleet.self) private var fleet
    @State private var log: [String] = []
    @State private var installing: Set<String> = []

    var body: some View {
        Form {
            Section("Newest Releases") {
                ForEach(TVPlatform.allCases, id: \.self) { p in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(p.label)
                            Spacer()
                            if let r = fleet.latest[p] { Text(r.version?.description ?? r.tag_name).monospacedDigit().foregroundStyle(.secondary) }
                            else if fleet.releaseErrors[p] == nil { ProgressView().controlSize(.small) }
                        }
                        if let r = fleet.latest[p], let d = r.published_at { Text("Released \(d.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary) }
                        if let e = fleet.releaseErrors[p] { Text(e).font(.caption).foregroundStyle(.orange) }
                    }
                }
                Button("Check GitHub Again") { Task { await fleet.checkReleases() } }
            }

            Section {
                ForEach(fleet.tvs) { tv in row(tv) }
            } header: {
                Text("TVs")
            } footer: {
                Text("Android TVs download the newest release and install it themselves as soon as nobody's watching. A TV marked Test TV takes each version first; the others wait a day unless asked here.")
            }

            Section {
                ActionButton(action: {
                    let (n, failed) = await fleet.pushUpdateToAll()
                    log.insert("Asked \(n) Android TV\(n == 1 ? "" : "s") to update." + (failed.isEmpty ? "" : " " + failed.joined(separator: "; ")), at: 0)
                    try? await Task.sleep(nanoseconds: 10_000_000_000)
                    await fleet.loadAllHealth()
                }) { Label("Update Every Android TV Now", systemImage: "arrow.down.circle.fill") }
                #if os(macOS)
                ActionButton(action: { await installAllWebOS() }) { Label("Install the Newest Version on Every LG TV", systemImage: "arrow.down.app.fill") }
                    .disabled(fleet.latest[.webOS] == nil)
                #endif
            }

            if !log.isEmpty {
                Section("Activity") {
                    ForEach(Array(log.enumerated()), id: \.offset) { _, line in Text(line).font(.caption.monospaced()) }
                }
            }
        }
        .formStyle(.grouped)
        .screenTitle("Updates")
        .task { if fleet.latest.isEmpty { await fleet.checkReleases() }; await fleet.loadAllHealth() }
    }

    @ViewBuilder private func row(_ tv: FleetTV) -> some View {
        let report = fleet.healthReports[tv.id]
        let platform = fleet.platform(of: tv)
        HStack {
            StatusDot(color: tv.online ? .green : .gray)
            VStack(alignment: .leading, spacing: 2) {
                Text(tv.name)
                Text([platform?.label, tv.version.map { "v\($0)" }, report?.updates?.text].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if installing.contains(tv.id) { ProgressView().controlSize(.small) }
            else if fleet.isBehind(tv) {
                if platform == .webOS {
                    #if os(macOS)
                    Button("Install") { Task { await installWebOS(tv) } }.disabled(fleet.extras[tv.id]?.ssh == nil)
                    #else
                    Text("Update from the Mac").font(.caption).foregroundStyle(.secondary)
                    #endif
                } else {
                    ActionButton(action: { try await fleet.pushUpdate(tv); log.insert("\(tv.name): checking for the update now.", at: 0) }) { Text("Update") }
                        .disabled(!tv.online)
                }
            } else if tv.version != nil && fleet.latest[platform ?? .android] != nil {
                Label("Up to date", systemImage: "checkmark.circle.fill").labelStyle(.iconOnly).foregroundStyle(.green)
            }
        }
    }

    #if os(macOS)
    private func installWebOS(_ tv: FleetTV) async {
        guard let ssh = fleet.extras[tv.id]?.ssh, let release = fleet.latest[.webOS] else {
            log.insert("\(tv.name): set up SSH on its page under TVs first.", at: 0); return
        }
        guard let asset = release.assets.first(where: { $0.name == "woodruff-family.ipk" }) ?? release.assets.first(where: { $0.name.hasSuffix(".ipk") }) else {
            log.insert("The release has no .ipk package.", at: 0); return
        }
        installing.insert(tv.id)
        defer { installing.remove(tv.id) }
        do {
            log.insert("Downloading \(asset.name) (\(release.tag_name))…", at: 0)
            let file = try await ReleaseFeed(token: fleet.githubToken).download(asset)
            try await WebOSInstaller.install(file, on: ssh) { line in Task { @MainActor in log.insert("\(tv.name): \(line)", at: 0) } }
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            await fleet.refresh()
        } catch {
            log.insert("\(tv.name): \(error.localizedDescription)", at: 0)
        }
    }

    private func installAllWebOS() async {
        for tv in fleet.tvs where fleet.platform(of: tv) == .webOS && fleet.extras[tv.id]?.ssh != nil {
            await installWebOS(tv)
        }
    }
    #endif
}

#if os(macOS)
/// SSH settings for installing on an LG TV from the Mac (on the TV's page).
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
                TextField("TV's address", text: $host)
                Picker("Access", selection: $mode) { ForEach(WebOSSSH.Mode.allCases, id: \.self) { Text($0.label).tag($0) } }
                TextField("Private key (blank: ~/.ssh/tv_webos)", text: $keyPath)
                HStack {
                    Button("Save") {
                        fleet.extras[tv.id, default: TVExtras()].ssh = WebOSSSH(host: host, mode: mode, keyPath: keyPath)
                        result = "Saved."
                    }
                    Button("Test") {
                        let ssh = WebOSSSH(host: host, mode: mode, keyPath: keyPath)
                        result = "Testing…"
                        Task { result = await WebOSInstaller.test(ssh).map { "Failed: \($0)" } ?? "SSH works. Updates can be installed from here." }
                    }
                }
                if let result { Text(result).font(.caption).foregroundStyle(.secondary) }
            } header: {
                Text("Install Updates from This Mac")
            } footer: {
                Text("Developer Mode: get the key once with `ares-novacom --getkey` (saved as ~/.ssh/tv_webos) and keep Dev Mode Status on. Rooted TVs use root on port 22. The webOS releases are private: add a GitHub token in Settings → Updates.")
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
