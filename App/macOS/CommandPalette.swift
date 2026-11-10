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
        // Only what would do something right now: no Pause All with nothing playing, no Mute All with every TV off.
        let on = fleet.tvs.filter { $0.online && !$0.isUnpaired }
        let playing = on.filter { $0.playing?.isPlaying == true }
        if !playing.isEmpty {
            all.append(Item(id: "a-pause", title: "Pause All", detail: "Every TV that’s playing", symbol: "pause.fill") {
                MacActions.send("playpause", to: playing, fleet: fleet)
            })
        }
        if !on.isEmpty {
            all.append(Item(id: "a-mute", title: "Mute All", detail: "Every TV that’s on", symbol: "speaker.slash.fill") {
                MacActions.send("mute", to: on, fleet: fleet)
            })
            all.append(Item(id: "a-home", title: "Woodruff Home on All", detail: "Every TV that’s on", symbol: "house.fill") {
                MacActions.send("home", to: on, fleet: fleet, woodruffHome: true)
            })
            all.append(Item(id: "a-update", title: "Update All", detail: "Ask every Android TV to update", symbol: "arrow.down.circle") {
                MacActions.updateAll(fleet)
            })
        }
        all.append(Item(id: "a-remote", title: "Remote", detail: "Open the remote", symbol: "appletvremote.gen4") { fleet.remotePanel = true })
        all.append(Item(id: "a-mini", title: "Mini Player", detail: "The floating player", symbol: "rectangle.on.rectangle") { openWindow(id: "mini") })
        let home = SmartHome.shared
        // A light that's unplugged or off at the wall can't take a change, so it isn't offered one.
        let reachable = home.lights.filter { !$0.isOffline }
        if reachable.contains(where: { $0.on }) {
            all.append(Item(id: "lights-off", title: "Turn Off All Lights", detail: "Every light that’s on", symbol: "lightbulb.slash") { home.allLights(false) })
        }
        if reachable.contains(where: { !$0.on }) {
            all.append(Item(id: "lights-on", title: "Turn On All Lights", detail: "Every light that’s off", symbol: "lightbulb.fill") { home.allLights(true) })
        }
        for l in reachable {
            all.append(Item(id: "light-\(l.id)", title: l.name, detail: l.on ? "Light · On — turn off" : "Light · Off — turn on", symbol: "lightbulb") { home.setOn(l, !l.on) })
        }
        // Speakers that can play or pause now (not offline, not an empty queue).
        for r in home.speakers where r.canPlay {
            all.append(Item(id: "spk-\(r.id)", title: r.name, detail: r.isPlaying ? "Sonos · \(r.title ?? "Playing") — pause" : "Sonos — play", symbol: "hifispeaker") {
                Task { await home.playPause(r) }
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
                    // The arrows move through the list while typing (on the field itself, which has the focus).
                    .onKeyPress(.downArrow) { index = min(index + 1, max(0, list.count - 1)); return .handled }
                    .onKeyPress(.upArrow) { index = max(index - 1, 0); return .handled }
            }
            .padding(16)
            Divider()
            ScrollViewReader { proxy in
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
                            .id(item.id)
                            .onTapGesture { index = i; run(list) }
                        }
                        if list.isEmpty && !query.isEmpty {
                            Text("Nothing matches “\(query)”.")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 40)
                        }
                    }
                    .padding(8)
                }
                // The highlighted row stays in view as the arrows move past the bottom.
                .onChange(of: index) { _, i in
                    if list.indices.contains(i) { proxy.scrollTo(list[i].id) }
                }
            }
            .frame(maxHeight: .infinity)
        }
        // Fills its pop-up (a fixed size on the Mac), rather than floating in the middle of it.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Esc closes it wherever the focus is.
        .background { Button("Close") { dismiss() }.keyboardShortcut(.cancelAction).opacity(0).frame(width: 0, height: 0).accessibilityHidden(true) }
        .onAppear { focused = true }
        .onChange(of: query) { _, _ in index = 0 }
        .onExitCommand { dismiss() }
    }

    private func run(_ list: [Item]) {
        guard list.indices.contains(index) else { return }
        list[index].run()
        dismiss()
    }
}

/// Woodruff's own window (the one with Home, not the mini player or the menu bar's panel), for the menu bar's
/// Open Woodruff. Nil from the moment it closes: once it's closed, a new one is opened instead. Hidden with the app
/// (⌘H) or in the Dock it's still this one, and is brought back (whether it's on screen doesn't tell: a hidden app's
/// window isn't, and was taken for closed).
@MainActor
enum MainWindow {
    private static let box = WeakWindow()
    /// Hears that window close.
    private static var closing: NSObjectProtocol?

    static var current: NSWindow? {
        get { box.window }
        set {
            box.window = newValue
            if let closing { NotificationCenter.default.removeObserver(closing) }
            closing = newValue.map { window in
                NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { note in
                    // Only while it's still the one kept (a new window may have taken its place meanwhile).
                    let closed = note.object as? NSWindow
                    MainActor.assumeIsolated { if closed === MainWindow.current { MainWindow.current = nil } }
                }
            }
        }
    }
}

private final class WeakWindow {
    weak var window: NSWindow?
}

/// Keeps the main window's size and place between launches, and notes which window it is.
struct WindowMemory: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { WindowWatcher() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Hears the moment it's in a window (on every launch, and for a window opened again later).
private final class WindowWatcher: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        _ = window.setFrameAutosaveName("WoodruffMainWindow")
        MainWindow.current = window
    }
}
