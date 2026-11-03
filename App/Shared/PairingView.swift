import SwiftUI
import WoodruffKit

/// First run: find the TVs on the network and pair with one (its QR code, or its link).
struct WelcomeView: View {
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Image("Emblem").resizable().frame(width: 96, height: 96)
                        .padding(.top, 30)
                    Text("Woodruff Family").font(.largeTitle.bold())
                    Text("One app for every TV in the house: the remote, what's playing, Family Memories, messages, health and updates.")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary)
                        .frame(maxWidth: 460)
                    PairPanel()
                        .frame(maxWidth: 520)
                }
                .padding()
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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("On any TV, open Woodruff → Settings → Phone connection. It shows a QR code and a link. Pairing one TV is enough: every TV linked to it shows up too.")
                .font(.callout).foregroundStyle(.secondary)

            #if os(iOS)
            Button { scanning = true } label: {
                Label("Scan the TV's QR Code", systemImage: "qrcode.viewfinder").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            #endif

            HStack {
                TextField("http://192.168.1.20:8090/?k=…", text: $link)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never).keyboardType(.URL)
                    #endif
                    .onSubmit { pair(link) }
                Button("Pair") { pair(link) }.disabled(link.isEmpty || busy)
            }
            #if os(iOS)
            PasteButton(payloadType: String.self) { s in if let first = s.first { link = first; pair(first) } }
                .labelStyle(.titleAndIcon)
            #endif

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
                let paired = fleet.tvs.contains { $0.id == tv.id }
                Button {
                    picked = tv
                } label: {
                    HStack {
                        Image(systemName: "tv").frame(width: 28)
                        VStack(alignment: .leading) {
                            Text(tv.name).font(.body)
                            Text("\(tv.host):\(tv.port)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if paired { Label("Connected", systemImage: "checkmark.circle.fill").labelStyle(.iconOnly).foregroundStyle(.green) }
                        else { Image(systemName: "chevron.right").foregroundStyle(.tertiary) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(paired)
            }
            if busy { ProgressView("Pairing…") }
        }
        .padding()
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
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
                if let p = picked, let base = p.base { pair(base.absoluteString + "/?k=" + key.trimmingCharacters(in: .whitespaces)) }
                key = ""
            }
            Button("Cancel", role: .cancel) { key = "" }
        } message: {
            Text("Type the key after “k=” in the link on the TV's Phone screen, or scan its QR code instead.")
        }
    }

    private func pair(_ text: String) {
        guard let c = TVConnection.parse(text) else {
            fleet.say("That isn't a TV link", "Use the link or QR code from the TV's Phone screen; it ends in ?k=…")
            return
        }
        busy = true
        Task {
            do {
                let hub = try await fleet.pair(c)
                link = ""
                fleet.say("Paired with \(hub.name)", fleet.tvs.count > 1 ? "\(fleet.tvs.count) TVs are connected." : "Link more TVs on the TV (Settings → TVs → Add another TV), or pair them here.")
            } catch { fleet.show(error) }
            busy = false
        }
    }
}
