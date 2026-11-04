import SwiftUI
import WoodruffKit

/// First run: find the TVs on the network and pair with one (its QR code, or its link).
struct WelcomeView: View {
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    Image("Emblem").resizable().frame(width: 108, height: 108)
                        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                        .shadow(color: Color.accentColor.opacity(0.55), radius: 30)
                        .padding(.top, 48)
                    Text("Woodruff Family").font(.largeTitle.bold())
                    Text("Every TV in the house, in one place: the remote, what’s playing, Family Memories, messages, health and updates.")
                        .font(.body).multilineTextAlignment(.center).foregroundStyle(.secondary)
                        .frame(maxWidth: 440)
                        .padding(.bottom, 10)
                    PairPanel().frame(maxWidth: 520)
                }
                .padding(20)
            }
            .background {
                LinearGradient(colors: [Color.accentColor.opacity(0.35), .clear], startPoint: .top, endPoint: .center).ignoresSafeArea()
            }
        }
    }
}

/// Pair with a TV: scan (iPhone), paste its link, or pick one found on the network and type its key.
struct PairPanel: View {
    @Environment(Fleet.self) private var fleet
    @StateObject private var discovery = TVDiscovery()
    @State private var link = ""
    @State private var scanning = false
    @State private var busy = false
    @State private var picked: DiscoveredTV?
    @State private var key = ""
    /// Why the last link or code didn't pair (shown here, under the field).
    @State private var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("On any TV, open Woodruff → Settings → Phone connection. It shows a QR code and a link. Pairing one TV is enough: every TV linked to it shows up too.")
                .font(.callout).foregroundStyle(.secondary)

            #if os(iOS)
            Button { scanning = true } label: {
                Text("Scan the TV’s QR Code").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent).controlSize(.large)
            #endif

            HStack {
                TextField("http://192.168.1.20:8090/?k=…", text: $link)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never).keyboardType(.URL)
                    #endif
                    .onSubmit { pair(link) }
                Button("Pair") { pair(link) }.disabled(link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
            }
            #if os(iOS)
            PasteButton(payloadType: String.self) { s in if let first = s.first { link = first; pair(first) } }
                .labelStyle(.titleAndIcon)
            #endif
            if let note { Text(note).font(.footnote).foregroundStyle(Palette.attention) }

            Divider()
            HStack {
                Text("TVs on this network").font(.headline)
                Spacer()
                if discovery.browsing { ProgressView().controlSize(.small) }
            }
            if discovery.found.isEmpty {
                Text("Looking for Woodruff TVs… (the TV must be on, with Woodruff's phone connection started)")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(discovery.found) { tv in
                // Paired here already: nothing to do. Linked through another TV (or only heard on the Wi‑Fi): pairing
                // it directly too keeps it reachable when that TV is off.
                let paired = fleet.hub(tv.id) != nil
                let linked = !paired && fleet.tvs.contains { $0.id == tv.id && !$0.isUnpaired }
                Button {
                    picked = tv
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(tv.name).font(.body)
                            Text("\(tv.host):\(tv.port)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if paired { Text("Paired").font(.subheadline).foregroundStyle(.secondary) }
                        else {
                            if linked { Text("Linked").font(.subheadline).foregroundStyle(.secondary) }
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(paired || busy)
            }
            if busy { ProgressView("Pairing…") }
        }
        .padding(20)
        .glass(RoundedRectangle(cornerRadius: 28, style: .continuous), interactive: false)
        .onAppear { discovery.start() }
        .onDisappear { discovery.stop() }
        #if os(iOS)
        .sheet(isPresented: $scanning) {
            NavigationStack {
                QRScannerView { code in scanning = false; pair(code) }
                    .ignoresSafeArea()
                    .navigationTitle("Scan the TV's Code")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { scanning = false } } }
            }
        }
        #endif
        .alert("Pair with \(picked?.name ?? "TV")", isPresented: Binding(get: { picked != nil }, set: { if !$0 { picked = nil } })) {
            TextField("Pairing key", text: $key)
            Button("Pair") {
                let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
                key = ""
                guard let p = picked else { return }
                guard let base = p.base else { note = "\(p.name) didn’t give an address to pair with. Scan its QR code instead."; return }
                // A whole link pasted in works too.
                if let c = TVConnection.parse(k) { connect(c) } else { connect(TVConnection(base: base, key: k)) }
            }
            .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) { key = "" }
        } message: {
            Text("Type the key after “k=” in the link on the TV's Phone screen, or scan its QR code instead.")
        }
    }

    private func pair(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let c = TVConnection.parse(text) else {
            note = "That isn’t a TV link. Use the link or QR code from the TV’s Phone screen; it ends in ?k=…"
            return
        }
        connect(c)
    }

    private func connect(_ c: TVConnection) {
        guard !busy else { return }
        busy = true
        note = nil
        Task {
            do {
                let hub = try await fleet.pair(c)
                link = ""
                let count = fleet.tvs.filter { !$0.isUnpaired }.count
                fleet.say("Paired with \(hub.name)", count > 1 ? "\(count) TVs are connected." : "Link more TVs on the TV (Settings → TVs → Add another TV), or pair them here.")
            } catch { note = error.localizedDescription }
            busy = false
        }
    }
}
