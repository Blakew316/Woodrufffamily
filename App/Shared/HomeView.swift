import SwiftUI
import WoodruffKit

/// Home (Mac), like Apple's Home app: what's going on across the house at a glance, a large tile for every TV
/// with what it's playing and its controls, and actions for all of them. The remote slides out on the right.
struct HomeView: View {
    @Environment(Fleet.self) private var fleet
    @State private var openTV: String?

    private let columns = [GridItem(.adaptive(minimum: 320, maximum: 520), spacing: 18)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                summary
                VStack(alignment: .leading, spacing: 14) {
                    Text("TVs").font(.title2.bold())
                    LazyVGrid(columns: columns, spacing: 18) {
                        ForEach(fleet.tvs) { tv in
                            HomeTVTile(tv: tv) { openTV = tv.id }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 14) {
                    Text("Every TV").font(.title2.bold())
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 14)], spacing: 14) {
                        SceneTile(title: "Pause All", detail: "Everything playing") { await all("playpause", onlyPlaying: true) }
                        SceneTile(title: "Mute All", detail: "Every TV that’s on") { await all("mute") }
                        SceneTile(title: "Woodruff Home", detail: "On every TV") { await all("home") }
                        SceneTile(title: "Update All", detail: fleet.updatesWaiting == 0 ? "All up to date" : "\(fleet.updatesWaiting) waiting") {
                            let (n, failed) = await fleet.pushUpdateToAll()
                            fleet.say("Update All", failed.isEmpty ? "Asked \(n) TV\(n == 1 ? "" : "s") to update. Each installs once nobody’s watching." : failed.joined(separator: "\n"))
                        }
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 1180, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Home")
        .navigationDestination(item: $openTV) { TVDetailView(tvID: $0) }
        .refreshable { await fleet.refresh(); await fleet.loadAllHealth() }
    }

    /// The Home app's status line: small capsules for what needs a look.
    private var summary: some View {
        let playing = fleet.tvs.filter { $0.playing != nil }.count
        let on = fleet.tvs.filter(\.online).count
        let attention = fleet.tvs.filter(\.needsAttention).count
        return ScrollView(.horizontal) {
            HStack(spacing: 10) {
                StatusPill(title: "\(on) of \(fleet.tvs.count) On", tint: nil)
                if playing > 0 { StatusPill(title: "\(playing) Playing", tint: nil) }
                if attention > 0 { StatusPill(title: attention == 1 ? "1 Needs Attention" : "\(attention) Need Attention", tint: Palette.attention) }
                if fleet.updatesWaiting > 0 { StatusPill(title: fleet.updatesWaiting == 1 ? "1 Update" : "\(fleet.updatesWaiting) Updates", tint: .blue) }
            }
        }
        .scrollIndicators(.hidden)
    }

    private func all(_ key: String, onlyPlaying: Bool = false) async {
        await withTaskGroup(of: Void.self) { g in
            for tv in fleet.tvs where tv.online && (!onlyPlaying || tv.playing?.isPlaying == true) {
                guard let c = fleet.client(for: tv) else { continue }
                g.addTask { try? await c.key(key) }
            }
        }
        try? await Task.sleep(nanoseconds: 700_000_000)
        await fleet.refresh()
    }
}

struct StatusPill: View {
    var title: String
    var tint: Color?
    var body: some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(tint ?? .primary)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .glass(Capsule(), interactive: false)
    }
}

/// One TV, as a Home app tile: its name and state, what it's playing over the title's artwork, the transport,
/// and the remote.
struct HomeTVTile: View {
    @Environment(Fleet.self) private var fleet
    var tv: FleetTV
    var open: () -> Void
    @State private var hovering = false

    var body: some View {
        let p = tv.playing
        ZStack(alignment: .bottomLeading) {
            if p != nil {
                Color.clear
                    .overlay { NowPlayingArt(playing: p, backdrop: true) }
                    .clipped()
                LinearGradient(stops: [.init(color: .black.opacity(0.15), location: 0), .init(color: .black.opacity(0.85), location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text(tv.name).font(.title3.bold())
                    Spacer()
                    Text(state).font(.caption.weight(.semibold))
                        .foregroundStyle(tv.needsAttention ? Palette.attention : .secondary)
                }
                Spacer(minLength: 12)
                if let p {
                    Text(p.title).font(.headline).lineLimit(1)
                    Text([p.subtitle, p.app].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · "))
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    LiveProgress(playing: p, times: false, tint: .white).padding(.top, 10)
                } else {
                    Text(idleLine).font(.headline).foregroundStyle(tv.online ? .primary : .secondary)
                    if tv.needsAttention, let first = tv.health?.first {
                        Text(first).font(.subheadline).foregroundStyle(Palette.attention).lineLimit(1)
                    }
                }
                HStack(spacing: 8) {
                    if let p { Transport(tv: tv, playing: p, compact: true) }
                    Spacer()
                    if !tv.online, let mac = fleet.extras[tv.id]?.mac {
                        Button("Turn On") { WakeOnLAN.wake(mac: mac, lastHost: fleet.extras[tv.id]?.lastHost) }
                            .buttonStyle(.glass)
                    }
                    if tv.online {
                        Button("Remote") {
                            fleet.remoteAll = false
                            fleet.selectedID = tv.id
                            withAnimation(.smooth) { fleet.remotePanel = true }
                        }
                        .buttonStyle(.glass)
                    }
                }
                .padding(.top, 12)
            }
            .padding(18)
        }
        .foregroundStyle(p != nil ? Color.white : Color.primary)
        .frame(height: 230)
        .background { if p == nil { RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Palette.cardFill) } }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(.white.opacity(hovering ? 0.18 : 0.06)))
        .opacity(tv.online ? 1 : 0.6)
        .shadow(color: .black.opacity(hovering ? 0.3 : 0.15), radius: hovering ? 18 : 10, y: hovering ? 10 : 5)
        .scaleEffect(hovering ? 1.01 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: hovering)
        .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .onTapGesture(perform: open)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Open") { open() }
            Button("Use for the Remote") { fleet.remoteAll = false; fleet.selectedID = tv.id; fleet.remotePanel = true }
            Button("Check for Updates") { Task { do { try await fleet.pushUpdate(tv) } catch { fleet.show(error) } } }
        }
    }

    private var state: String {
        if tv.link == "refused" { return "Link Again" }
        if !tv.online { return "Off" }
        if tv.needsAttention { return "Needs Attention" }
        if fleet.isBehind(tv) { return "Update Available" }
        if let p = tv.playing { return p.isPlaying ? "Playing" : "Paused" }
        return "On"
    }

    private var idleLine: String {
        if tv.link == "refused" { return "Its link stopped working" }
        if !tv.online { return "Seen \(relative(tv.seen))" }
        return tv.onScreen ? "Woodruff is on screen" : "Nothing playing"
    }
}

/// A Home app scene: one tap does it on every TV.
struct SceneTile: View {
    @Environment(Fleet.self) private var fleet
    var title: String
    var detail: String
    var action: () async -> Void
    @State private var busy = false

    var body: some View {
        Button {
            busy = true
            Task { await action(); busy = false }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(busy ? "Working…" : detail).font(.subheadline).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Palette.cardFill))
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(PressScale(scale: 0.97))
        .disabled(busy)
    }
}
