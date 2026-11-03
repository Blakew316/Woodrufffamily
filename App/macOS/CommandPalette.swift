import SwiftUI
import AppKit
import WoodruffKit

/// ⌘K: type to jump to a TV, play a title or run an action, from anywhere in the app.
struct CommandPalette: View {
    @Environment(Fleet.self) private var fleet
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @State private var query = ""
    @State private var index = 0
    @FocusState private var focused: Bool

    struct Item: Identifiable {
        var id: String
        var title: String
        var detail: String
        var symbol: String
        var run: @MainActor () -> Void
    }

    private var items: [Item] {
        var all: [Item] = []
        for tv in fleet.tvs where !tv.isUnpaired {
            all.append(Item(id: "tv-\(tv.id)", title: tv.name, detail: statusWord(tv), symbol: "tv") {
                fleet.remoteAll = false; fleet.selectedID = tv.id; fleet.remotePanel = true
            })
        }
        let actions: [(String, String, String, @MainActor () -> Void)] = [
            ("Pause All", "Every TV that’s playing", "pause.fill", { keyAll("playpause", playingOnly: true) }),
            ("Mute All", "Every TV that’s on", "speaker.slash.fill", { keyAll("mute") }),
            ("Woodruff Home on All", "Every TV that’s on", "house.fill", { keyAll("home") }),
            ("Update All", "Ask every Android TV to update", "arrow.down.circle", { Task { _ = await fleet.pushUpdateToAll() } }),
            ("Remote", "Open the remote", "appletvremote.gen4", { fleet.remotePanel = true }),
            ("Mini Player", "The floating player", "rectangle.on.rectangle", { openWindow(id: "mini") }),
        ]
        for a in actions { all.append(Item(id: "a-\(a.0)", title: a.0, detail: a.1, symbol: a.2, run: a.3)) }
        let home = SmartHome.shared
        if !home.lights.isEmpty {
            all.append(Item(id: "lights-off", title: "Turn Off All Lights", detail: "Every Govee light", symbol: "lightbulb.slash") { home.allLights(false) })
            all.append(Item(id: "lights-on", title: "Turn On All Lights", detail: "Every Govee light", symbol: "lightbulb.fill") { home.allLights(true) })
        }
        for l in home.lights {
            all.append(Item(id: "light-\(l.id)", title: l.name, detail: l.on ? "Light · On — turn off" : "Light · Off — turn on", symbol: "lightbulb") { home.setOn(l, !l.on) })
        }
        for r in home.speakers {
            all.append(Item(id: "spk-\(r.id)", title: r.name, detail: r.isPlaying ? "Sonos · \(r.title ?? "Playing") — pause" : "Sonos — play", symbol: "hifispeaker") {
                let playing = r.isPlaying
                Task { await home.sonos(r) { playing ? try await Sonos.pause($0) : try await Sonos.play($0) } }
            })
        }
        if let lib = fleet.library {
            var seen = Set<String>()
            for t in (lib.featured ?? []) + (lib.recent ?? []) + (lib.movies?.items ?? []) + (lib.shows?.items ?? []) where seen.insert(t.id).inserted {
                guard let p = t.play else { continue }
                all.append(Item(id: "t-\(t.id)", title: t.title, detail: "Play on \(fleet.selected?.name ?? "the TV")", symbol: "play.rectangle") {
                    PlayRouter.start(p, fleet: fleet)
                })
            }
        }
        guard !query.isEmpty else { return Array(all.prefix(12)) }
        let q = query.lowercased()
        return all.filter { $0.title.lowercased().contains(q) || $0.detail.lowercased().contains(q) }
            .sorted { ($0.title.lowercased().hasPrefix(q) ? 0 : 1) < ($1.title.lowercased().hasPrefix(q) ? 0 : 1) }
            .prefix(12).map { $0 }
    }

    var body: some View {
        let list = items
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search TVs, speakers, lights, titles and actions", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit { run(list) }
            }
            .padding(16)
            Divider()
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(Array(list.enumerated()), id: \.element.id) { i, item in
                        HStack(spacing: 12) {
                            Image(systemName: item.symbol).frame(width: 22).foregroundStyle(i == index ? .white : .secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.title).lineLimit(1)
                                Text(item.detail).font(.caption).foregroundStyle(i == index ? .white.opacity(0.8) : .secondary).lineLimit(1)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(i == index ? Color.accentColor : .clear))
                        .foregroundStyle(i == index ? .white : .primary)
                        .contentShape(Rectangle())
                        .onTapGesture { index = i; run(list) }
                    }
                }
                .padding(8)
            }
            .frame(height: 360)
        }
        .frame(width: 560)
        .onAppear { focused = true }
        .onChange(of: query) { _, _ in index = 0 }
        .onKeyPress(.downArrow) { index = min(index + 1, max(0, list.count - 1)); return .handled }
        .onKeyPress(.upArrow) { index = max(index - 1, 0); return .handled }
        .onExitCommand { dismiss() }
    }

    private func run(_ list: [Item]) {
        guard list.indices.contains(index) else { return }
        list[index].run()
        dismiss()
    }

    private func keyAll(_ key: String, playingOnly: Bool = false) {
        Task {
            for tv in fleet.tvs where tv.online && (!playingOnly || tv.playing?.isPlaying == true) {
                try? await fleet.client(for: tv)?.key(key)
            }
        }
    }
}

/// Keeps the main window's size and place between launches.
struct WindowMemory: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { v.window?.setFrameAutosaveName("WoodruffMainWindow") }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
