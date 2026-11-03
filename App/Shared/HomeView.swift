import SwiftUI
import WoodruffKit

/// Home (Mac), like Apple's Home app: what's going on across the house at a glance, a large tile for every TV
/// with what it's playing and its controls, and actions for all of them. The remote slides out on the right.
struct HomeView: View {
    @Environment(Fleet.self) private var fleet
    @State private var openTV: String?
    @Namespace private var zoom

    private let columns = [GridItem(.adaptive(minimum: 320, maximum: 520), spacing: 18)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                summary
                VStack(alignment: .leading, spacing: 14) {
                    Text("TVs").font(.title2.bold())
                    LazyVGrid(columns: columns, spacing: 18) {
                        ForEach(fleet.tvs) { tv in
                            HomeTVTile(tv: tv) { open(tv.id) }
                                .matchedGeometryEffect(id: tv.id, in: zoom, isSource: openTV != tv.id)
                                .opacity(openTV == tv.id ? 0 : 1)
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
        .blur(radius: openTV == nil ? 0 : 8)
        .overlay { if openTV != nil { Color.black.opacity(0.25).ignoresSafeArea().onTapGesture { close() } } }
        .overlay {
            // The tile grows into the TV's page (and shrinks back into its tile).
            if let id = openTV {
                TVDetailView(tvID: id)
                    .overlay(alignment: .topTrailing) {
                        GlassCircle(symbol: "xmark", size: 34) { close() }.padding(14)
                    }
                    .background(Palette.groupedBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .matchedGeometryEffect(id: id, in: zoom, isSource: true)
                    .shadow(color: .black.opacity(0.35), radius: 40, y: 20)
                    .padding(28)
                    .frame(maxWidth: 820)
                    #if os(macOS)
                    .onExitCommand { close() }
                    #endif
                    .transition(.asymmetric(insertion: .identity, removal: .opacity))
            }
        }
        .navigationTitle(openTV.flatMap { fleet.tv($0)?.name } ?? "Home")
        .refreshable { await fleet.refresh(); await fleet.loadAllHealth() }
    }

    /// The Home app's status line: small capsules for what needs a look.
    private var summary: some View {
        let playing = fleet.tvs.filter { $0.playing != nil }.count
        let on = fleet.tvs.filter { $0.online && !$0.isUnpaired }.count
        let attention = fleet.tvs.filter(\.needsAttention).count
        return ScrollView(.horizontal) {
            HStack(spacing: 10) {
                StatusPill(title: "\(on) of \(fleet.tvs.count) On", tint: nil)
                let found = fleet.tvs.filter(\.isUnpaired).count
                if found > 0 { StatusPill(title: found == 1 ? "1 TV to Pair" : "\(found) TVs to Pair", tint: .accentColor) }
                if playing > 0 { StatusPill(title: "\(playing) Playing", tint: nil) }
                if attention > 0 {
                    Menu {
                        Button("Hide All Alerts") { withAnimation { fleet.hideAllAlerts() } }
                    } label: {
                        StatusPill(title: attention == 1 ? "1 Needs Attention" : "\(attention) Need Attention", tint: Palette.attention)
                    }
                    .menuStyle(.button).buttonStyle(.plain).fixedSize()
                }
                if fleet.updatesWaiting > 0 { StatusPill(title: fleet.updatesWaiting == 1 ? "1 Update" : "\(fleet.updatesWaiting) Updates", tint: .blue) }
            }
        }
        .scrollIndicators(.hidden)
    }

    private func open(_ id: String) {
        #if os(macOS)
        MacFeedback.snap()
        #endif
        withAnimation(.spring(response: 0.5, dampingFraction: 0.86)) { openTV = id }
    }

    private func close() {
        withAnimation(.spring(response: 0.45, dampingFraction: 0.9)) { openTV = nil }
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
    @State private var renaming = false
    @State private var newName = ""

    var body: some View {
        let p = tv.playing
        // A TV that stopped keeps the picture of what it last played, dimmed, so the grid stays rich.
        let art = p ?? (tv.isUnpaired ? nil : fleet.lastPlaying[tv.id])
        ZStack(alignment: .bottomLeading) {
            if art != nil && fleet.artwork(for: art) != nil {
                Color.clear
                    .overlay { NowPlayingArt(playing: art, backdrop: true) }
                    .clipped()
                    .saturation(p == nil ? 0.35 : 1)
                    .opacity(p == nil ? 0.55 : 1)
                LinearGradient(stops: [.init(color: .black.opacity(0.15), location: 0), .init(color: .black.opacity(0.88), location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center) {
                    Text(tv.name).font(.title3.bold())
                    if tv.needsAttention { Circle().fill(Palette.attention).frame(width: 8, height: 8) }
                    Spacer()
                    Text(state).font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                if let p {
                    Text(p.title).font(.headline).lineLimit(1)
                    Text([p.subtitle, p.app].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · "))
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    LiveProgress(playing: p, times: false, tint: .white).padding(.top, 10)
                } else {
                    Text(idleLine).font(.headline).foregroundStyle(tv.online ? .primary : .secondary)
                }
                HStack(spacing: 8) {
                    if let p { Transport(tv: tv, playing: p, compact: true) }
                    Spacer()
                    if !tv.online, let mac = fleet.extras[tv.id]?.mac {
                        Button("Turn On") { WakeOnLAN.wake(mac: mac, lastHost: fleet.extras[tv.id]?.lastHost) }
                            .buttonStyle(.glass)
                    }
                    if tv.isUnpaired {
                        Button("Pair") { open() }.buttonStyle(.glassProminent)
                    } else if tv.online {
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
        .foregroundStyle(hasArt ? Color.white : Color.primary)
        .frame(height: 230)
        .background { RoundedRectangle(cornerRadius: 24, style: .continuous).fill(hasArt ? Color.black : Palette.cardFill) }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(.white.opacity(hovering ? 0.18 : 0.06)))
        .opacity(tv.online ? 1 : 0.6)
        .shadow(color: .black.opacity(hovering ? 0.3 : 0.15), radius: hovering ? 18 : 10, y: hovering ? 10 : 5)
        .scaleEffect(hovering ? 1.01 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: hovering)
        .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        #if os(macOS)
        .hoverTilt()
        #endif
        .onTapGesture(perform: open)
        .onHover { hovering = $0 }
        .alert("Rename TV", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Save") { fleet.rename(tv, to: newName) }
            Button("Cancel", role: .cancel) {}
        }
        .contextMenu {
            Button("Open") { open() }
            Button("Rename…") { newName = tv.name; renaming = true }
            Button("Use for the Remote") { fleet.remoteAll = false; fleet.selectedID = tv.id; fleet.remotePanel = true }
            Button("Check for Updates") { Task { do { try await fleet.pushUpdate(tv) } catch { fleet.show(error) } } }
            if tv.needsAttention { Button("Hide Alerts") { fleet.hideAlerts(tv) } }
            if tv.alertsHidden { Button("Show Hidden Alerts") { fleet.showAlerts(tv) } }
        }
    }

    private var hasArt: Bool {
        let art = tv.playing ?? (tv.isUnpaired ? nil : fleet.lastPlaying[tv.id])
        return art != nil && fleet.artwork(for: art) != nil
    }

    private var state: String {
        if tv.isUnpaired { return "Not Paired" }
        if tv.link == "refused" && tv.needsAttention { return "Link Again" }
        if !tv.online { return "Off" }
        if fleet.isBehind(tv) { return "Update Available" }
        if let p = tv.playing { return p.isPlaying ? "Playing" : "Paused" }
        return "On"
    }

    private var idleLine: String {
        if tv.isUnpaired { return "Found on your Wi‑Fi" }
        if tv.link == "refused" { return tv.alertsHidden ? "Off" : "Its link stopped working" }
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

/// Search results for the Mac's toolbar search: Movies and TV Shows from the library.
struct LibrarySearchResults: View {
    @Environment(Fleet.self) private var fleet
    var query: String
    @State private var r: SearchResults?
    @State private var openTitle: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                if let r {
                    let sections = r.first == "shows" ? [("TV Shows", r.shows), ("Movies", r.movies)] : [("Movies", r.movies), ("TV Shows", r.shows)]
                    ForEach(sections, id: \.0) { name, list in
                        if !list.isEmpty { ShelfRow(name) { ForEach(list) { PosterTile(title: $0) } } }
                    }
                    if r.movies.isEmpty && r.shows.isEmpty {
                        EmptyState(symbol: "magnifyingglass", title: "No Results", message: "Nothing in Movies or TV Shows matches “\(query)”.")
                            .padding(.top, 60)
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 80)
                }
            }
            .padding(.vertical, 24)
        }
        .navigationTitle("Search")
        .environment(\.openTitle, OpenTitleAction { openTitle = $0 })
        .sheet(item: Binding(get: { openTitle.map { TitleRef(id: $0) } }, set: { openTitle = $0?.id })) { TitleSheet(id: $0.id) }
        .task(id: query) {
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard !Task.isCancelled else { return }
            r = try? await fleet.hubClient()?.search(query)
        }
    }
}
