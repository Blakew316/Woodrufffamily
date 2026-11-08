import SwiftUI
import WoodruffKit

/// Settings on Apple TV: the family (connected or not, with the family code typed in as another way in), this Apple
/// TV's name as the iPhone lists it, the family's TVs, pairing one found on the Wi‑Fi, and this app's version.
struct SettingsTab: View {
    @Environment(Fleet.self) private var fleet
    @StateObject private var discovery = TVDiscovery()
    private let sync = SettingsSync.shared
    @State private var picked: DiscoveredTV?
    @State private var key = ""
    @State private var link = ""
    @State private var code = ""
    @State private var codeNote: String?
    @State private var name = TVJoin.name == "Apple TV" ? "" : TVJoin.name
    @State private var busy = false
    @State private var note: String?

    var body: some View {
        NavigationStack {
            List {
                if sync.familyCode == nil {
                    Section {
                        ConnectPhoneCard()
                            .listRowBackground(Color.clear)
                            .padding(.vertical, 20)
                    }
                }
                Section {
                    LabeledContent("Family", value: sync.familyCode == nil ? "Not connected" : sync.otherCode ? "Another family code" : "Connected")
                    LabeledContent("Sync", value: sync.status)
                    if sync.familyCode == nil || sync.otherCode || sync.needsCode {
                        TextField("Enter Family Code", text: $code)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.characters)
                            .onSubmit(useCode)
                        Button("Use Code", action: useCode)
                            .disabled(code.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } header: {
                    Text("Family")
                } footer: {
                    Text(codeNote ?? "The family code is in Woodruff on your iPhone or Mac, under Settings → General → Sync Across Devices.")
                }
                Section {
                    TextField("Name, like Master Bedroom", text: $name)
                        .onSubmit {
                            UserDefaults.standard.set(name.trimmingCharacters(in: .whitespaces), forKey: "atv.name")
                            TVJoin.shared.announce()
                        }
                } header: {
                    Text("This Apple TV")
                } footer: {
                    Text("The name your iPhone shows for it, under Settings → TVs.")
                }
                Section("TVs") {
                    let paired = fleet.tvs.filter { !$0.isUnpaired }
                    if paired.isEmpty { Text("None yet. They come with the family.").foregroundStyle(.secondary) }
                    ForEach(paired) { tv in
                        LabeledContent(tv.name, value: tv.online ? (tv.nowPlaying?.title ?? "On") : "Off")
                    }
                }
                Section {
                    let ids = Set(fleet.hubs.map(\.id))
                    let found = discovery.found.filter { !ids.contains($0.id) }
                    if found.isEmpty { Text("Looking on the Wi‑Fi…").foregroundStyle(.secondary) }
                    ForEach(found) { tv in
                        Button(tv.name) { picked = tv; key = "" }.disabled(busy)
                    }
                    TextField("Or type the TV’s link", text: $link)
                        .onSubmit { pairLink() }
                } header: {
                    Text("Add a TV")
                } footer: {
                    Text(note ?? "The key is the part after “k=” in the link on the TV’s Phone screen. Pair one TV and the TVs linked to it come with it.")
                }
                Section("Woodruff") {
                    LabeledContent("Version", value: version)
                }
            }
            .background { TVBackdrop() }
            .navigationTitle("Settings")
            .onAppear { discovery.start() }
            .onDisappear { discovery.stop() }
            .alert("Pair with \(picked?.name ?? "TV")", isPresented: Binding(get: { picked != nil }, set: { if !$0 { picked = nil } })) {
                TextField("Pairing key", text: $key)
                Button("Pair") { pairPicked() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Type the key after “k=” in the link on the TV’s Phone screen.")
            }
        }
    }

    private var version: String {
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let c = (Bundle.main.object(forInfoDictionaryKey: "WoodruffCommit") as? String).map { String($0.prefix(7)) } ?? ""
        return c.isEmpty ? "Build \(b)" : "Build \(b) · \(c)"
    }

    private func useCode() {
        if let problem = sync.enter(code: code) {
            codeNote = problem
        } else {
            code = ""
            codeNote = "Connected. The family’s TVs and settings are coming over."
            TVJoin.shared.announce()
        }
    }

    private func pairPicked() {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let p = picked, !k.isEmpty else { return }
        if let c = TVConnection.parse(k) { connect(c) }
        else if let base = p.base { connect(TVConnection(base: base, key: k)) }
        else { note = "\(p.name) didn’t give an address. Type its whole link instead." }
    }

    private func pairLink() {
        let t = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        guard let c = TVConnection.parse(t) else { note = "That isn’t a TV link. It ends in ?k=…"; return }
        connect(c)
    }

    private func connect(_ c: TVConnection) {
        busy = true; note = nil
        Task {
            do {
                let hub = try await fleet.pair(c)
                link = ""
                note = "Paired with \(hub.name)."
            } catch { note = error.localizedDescription }
            busy = false
        }
    }
}
