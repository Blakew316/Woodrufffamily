import SwiftUI
import WoodruffKit

/// Every TV at a glance: on or off, what's playing, health, version, and one-tap actions across all of them.
struct DashboardView: View {
    @Environment(Fleet.self) private var fleet
    @State private var broadcasting = false

    private let columns = [GridItem(.adaptive(minimum: 300, maximum: 520), spacing: 14)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                overview
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(fleet.tvs) { tv in
                        NavigationLink(value: tv.id) { TVCard(tv: tv) }
                            .buttonStyle(.plain)
                            .contextMenu { TVQuickActions(tv: tv) }
                    }
                }
                everyTV
            }
            .padding()
        }
        .screenTitle("TVs")
        .navigationDestination(for: String.self) { id in TVDetailView(tvID: id) }
        .refreshable { await fleet.refresh(); await fleet.loadAllHealth() }
        .toolbar {
            ToolbarItem {
                Button { Task { await fleet.refresh(); await fleet.loadAllHealth() } } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r")
            }
        }
        .task { await fleet.loadAllHealth() }
    }

    private var overview: some View {
        let online = fleet.tvs.filter(\.online).count
        let playing = fleet.tvs.filter { $0.playing != nil }.count
        return HStack(spacing: 12) {
            Stat(value: "\(online)/\(fleet.tvs.count)", label: "Online", symbol: "power", tint: online == fleet.tvs.count ? .green : .orange)
            Stat(value: "\(playing)", label: "Playing", symbol: "play.fill", tint: .accentColor)
            Stat(value: "\(fleet.tvs.filter(\.needsAttention).count)", label: "Need attention", symbol: "exclamationmark.triangle.fill",
                 tint: fleet.tvs.contains(where: \.needsAttention) ? .orange : .secondary)
            Stat(value: "\(fleet.updatesWaiting)", label: "Updates", symbol: "arrow.down.circle.fill", tint: fleet.updatesWaiting > 0 ? .blue : .secondary)
        }
    }

    /// Actions that go to every TV at once.
    private var everyTV: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text("Every TV").font(.headline)
                let cols = [GridItem(.adaptive(minimum: 150), spacing: 10)]
                LazyVGrid(columns: cols, alignment: .leading, spacing: 10) {
                    ActionButton(action: { try await broadcast("playpause") }) { Label("Play / Pause All", systemImage: "playpause.fill") }
                    ActionButton(action: { try await broadcast("mute") }) { Label("Mute All", systemImage: "speaker.slash.fill") }
                    ActionButton(action: { try await broadcast("home") }) { Label("All to Home", systemImage: "house.fill") }
                    ActionButton(action: {
                        let (n, failed) = await fleet.pushUpdateToAll()
                        fleet.say("Updates", failed.isEmpty ? "Asked \(n) TV\(n == 1 ? "" : "s") to update now. Each installs once nobody's using it." : failed.joined(separator: "\n"))
                    }) { Label("Update All", systemImage: "arrow.down.circle") }
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func broadcast(_ key: String) async throws {
        var failed: [String] = []
        await withTaskGroup(of: String?.self) { g in
            for tv in fleet.tvs where tv.online {
                guard let c = fleet.client(for: tv) else { continue }
                g.addTask { do { try await c.key(key); return nil } catch { return "\(tv.name): \(error.localizedDescription)" } }
            }
            for await f in g { if let f { failed.append(f) } }
        }
        if !failed.isEmpty { throw TVError.badAnswer(failed.joined(separator: "\n")) }
    }
}

struct Stat: View {
    var value: String
    var label: String
    var symbol: String
    var tint: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(value).font(.title2.bold()).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// One TV's tile.
struct TVCard: View {
    @Environment(Fleet.self) private var fleet
    var tv: FleetTV

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    StatusDot(color: color)
                    Text(tv.name).font(.headline)
                    if tv.id == fleet.selectedID { Image(systemName: "appletvremote.gen4.fill").font(.caption).foregroundStyle(.tint) }
                    Spacer()
                    if fleet.isBehind(tv) { Label("Update", systemImage: "arrow.down.circle.fill").font(.caption).foregroundStyle(.blue) }
                    platformBadge
                }
                Text(statusLine).font(.subheadline).foregroundStyle(tv.needsAttention ? Color.orange : .secondary).lineLimit(2)
                if let p = tv.playing {
                    NowPlayingRow(playing: p)
                }
                HStack {
                    if let v = tv.version { Text("v\(v)").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                    if !tv.isHub, let hub = fleet.hub(tv.hubID), fleet.hub(tv.id) == nil {
                        Text("via \(hub.name)").font(.caption).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    if tv.onScreen { Text("Woodruff on screen").font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
    }

    @ViewBuilder private var platformBadge: some View {
        switch fleet.platform(of: tv) {
        case .webOS?: Text("LG").font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2).background(.quaternary, in: Capsule())
        case .android?: Text("Android").font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2).background(.quaternary, in: Capsule())
        default: EmptyView()
        }
    }

    private var color: Color {
        if !tv.online { return .gray }
        if tv.needsAttention { return .orange }
        return .green
    }

    private var statusLine: String {
        if tv.link == "refused" { return "Link again: this TV turned down its hub's link" }
        if !tv.online { return "Off · seen \(relative(tv.seen))" }
        if let h = tv.health, h.status == "attention" { return "Needs attention · \(h.first ?? "")" }
        if let p = tv.playing { return p.isPlaying ? "Playing on \(p.app ?? "TV")" : "Paused · \(p.app ?? "TV")" }
        return "Nothing playing"
    }
}

/// Title, subtitle and a progress bar that keeps moving between refreshes.
struct NowPlayingRow: View {
    var playing: NowPlaying
    @State private var fetchedAt = Date()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: playing.isPlaying ? "play.fill" : "pause.fill").font(.caption)
                    Text(playing.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                }
                if let s = playing.subtitle, !s.isEmpty { Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                if let d = playing.duration, d > 0 {
                    let pos = min(d, (playing.position ?? 0) + (playing.isPlaying ? ctx.date.timeIntervalSince(fetchedAt) * 1000 : 0))
                    ProgressView(value: pos, total: d)
                    HStack {
                        Text(formatTime(ms: pos))
                        Spacer()
                        Text("-" + formatTime(ms: d - pos))
                    }
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
        .onChange(of: playing) { _, _ in fetchedAt = Date() }
    }
}

/// Right-click / long-press actions on a TV.
struct TVQuickActions: View {
    @Environment(Fleet.self) private var fleet
    var tv: FleetTV
    var body: some View {
        Button { fleet.selectedID = tv.id } label: { Label("Use for Remote", systemImage: "appletvremote.gen4") }
        Button { Task { do { try await fleet.client(for: tv)?.key("home") } catch { fleet.show(error) } } } label: { Label("Open Woodruff Home", systemImage: "house") }
        Button { Task { do { try await fleet.pushUpdate(tv); fleet.say("Asked \(tv.name) to update", "It installs the newest version once nobody's using it.") } catch { fleet.show(error) } } } label: {
            Label("Check for Updates", systemImage: "arrow.down.circle")
        }
        if let mac = fleet.extras[tv.id]?.mac {
            Button { WakeOnLAN.wake(mac: mac, lastHost: fleet.extras[tv.id]?.lastHost) } label: { Label("Turn On (Wake-on-LAN)", systemImage: "power") }
        }
    }
}

/// The sidebar's footer on iPad and Mac.
struct FleetSidebarSummary: View {
    @Environment(Fleet.self) private var fleet
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(fleet.tvs) { tv in
                HStack(spacing: 6) {
                    StatusDot(color: tv.online ? (tv.needsAttention ? .orange : .green) : .gray)
                    Text(tv.name).font(.caption).lineLimit(1)
                    Spacer()
                    if tv.playing?.isPlaying == true { Image(systemName: "play.fill").font(.caption2).foregroundStyle(.secondary) }
                }
            }
            if let at = fleet.refreshedAt {
                Text("Updated \(at.formatted(date: .omitted, time: .standard))").font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }
}
