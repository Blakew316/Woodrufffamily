import SwiftUI
import WoodruffKit

/// The menu bar's mini-player, like the Music app's: the remote's TV by name, what it's playing with its artwork,
/// progress and transport, and every TV's state underneath (a click on one there makes it the remote's TV: the one
/// way to switch here).
struct MenuBarFleetView: View {
    @Environment(Fleet.self) private var fleet
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let tv = fleet.selected
        // What's on now only (no picture of the last thing it played once it's stopped, off or left paused).
        let p = tv?.nowPlaying
        VStack(alignment: .leading, spacing: 14) {
            // Whose picture and buttons these are. (It was a menu of the TVs as well: the list below already
            // switches, with a click on a TV.)
            Text(tv?.name ?? "No TV").font(.headline)

            ZStack(alignment: .bottomLeading) {
                Color.clear.overlay { NowPlayingArt(playing: p, backdrop: true) }.clipped()
                LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .center, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 2) {
                    Text(p?.title ?? "Nothing Playing").font(.headline).lineLimit(1)
                    Text([p?.subtitle, p?.app].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                }
                .foregroundStyle(.white)
                .padding(12)
            }
            .frame(height: 164)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            if let tv, let p {
                LiveProgress(playing: p)
                Transport(tv: tv, playing: p).frame(maxWidth: .infinity)
            }

            Divider()
            VStack(alignment: .leading, spacing: 8) {
                ForEach(fleet.tvs) { t in
                    HStack(spacing: 8) {
                        Circle().fill(dot(t)).frame(width: 7, height: 7)
                        Text(t.name).font(.subheadline)
                        Spacer()
                        Text(t.nowPlaying?.title ?? (t.online ? (t.isUnpaired ? "Not paired" : "On") : "Off"))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { if !t.isUnpaired { fleet.remoteAll = false; fleet.selectedID = t.id } }
                }
            }
            Divider()
            HStack {
                Button("Mini Player") { openWindow(id: "mini") }
                // Woodruff's own window (not the mini player); after it's been closed, a new one.
                Button("Open Woodruff") {
                    MainWindowOpener.openWindow = openWindow
                    MainWindowOpener.show()
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
        }
        .padding(16)
        .frame(width: 320)
    }

    private func dot(_ t: FleetTV) -> Color {
        if !t.online || t.isUnpaired { return .gray }
        if t.needsAttention { return Palette.attention }
        return t.nowPlaying?.isPlaying == true ? .accentColor : .green
    }
}

/// What the menu bar and the window's toolbar share: Watch's search and the Command Palette, and what the window
/// shows now (so View can tick its section, and Find is there to choose while there's a search field). Kept outside
/// the window, as `MacNav` keeps its pages, so the menus can reach it.
@Observable @MainActor
final class MacBar {
    static let shared = MacBar()
    /// What's typed in the toolbar's search field (Watch's). Its results take the place of Watch's first page.
    var query = "" {
        didSet { if query.isEmpty != oldValue.isEmpty { hasQuery = !query.isEmpty } }
    }
    /// Whether anything is typed there. It changes only when that does, so a menu item that goes by it (Back) isn't
    /// drawn again at every letter.
    private(set) var hasQuery = false
    /// The Command Palette is showing.
    var palette = false
    /// Goes up each time Find is chosen: the window puts the cursor in its search field.
    var finds = 0
    /// The section the window shows (none on a TV's own page). View ticks it.
    var section: AppSection?
    /// The toolbar has its search field now (Watch's first page, or its search results).
    var searchShown = false
}

/// Menu commands: Check for Updates, Open Woodruff (⌘N), Find (⌘F); in View the sections (⌘1–⌘3), Back (⌘[) and the
/// Command Palette (⌘K); and the TVs menu: refresh (⌘R), the remote's keys, and ⌥⌘1–⌥⌘4 to pick a TV. (Settings…,
/// ⌘,, is the system's own item for the Settings window. The Mini Player is in the Window menu by itself, as a
/// window of its own: its key, ⇧⌘M, is on its scene.)
struct WoodruffCommands: Commands {
    var fleet: Fleet
    var body: some Commands {
        // Under About, where Mac apps keep it: the family's updater looks for a new version now, and Woodruff says what
        // it found.
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { UpdaterStatus.shared.checkNow(reportTo: fleet) }
        }
        // Settings… (⌘,) is the system's own item here: it opens this Mac's Settings window (`MacSettingsWindow`).
        // One window: ⌘N brings it back or forward (New Window opened another beside it, sharing its pages).
        CommandGroup(replacing: .newItem) {
            Button("Open Woodruff") { MainWindowOpener.show() }.keyboardShortcut("n", modifiers: .command)
        }
        // Edit > Find: the cursor goes to the toolbar's search field (Watch's), while there is one.
        CommandGroup(after: .pasteboard) {
            Divider()
            FindCommand()
        }
        // View: the sections, as the toolbar has them (the one showing is ticked), then Back and the Command Palette.
        CommandGroup(before: .toolbar) {
            SectionCommands()
            Divider()
            BackCommand()
            Button("Command Palette…") { MacActions.showPalette() }
                .keyboardShortcut("k", modifiers: .command)
        }
        CommandMenu("TVs") {
            Button("Refresh All") { Task { await fleet.refresh(); await fleet.loadAllHealth() } }
                .keyboardShortcut("r", modifiers: .command)
            Button("Update Every Android TV") { MacActions.updateAll(fleet) }
            // The remote from the keyboard (its button is in the toolbar).
            Button("Remote") { withAnimation(.smooth) { fleet.remotePanel.toggle() } }
                .keyboardShortcut("r", modifiers: [.command, .option])
            Divider()
            // The TV the remote, Watch and Send act on: ⌥⌘1–4, with the remote's other keys (⌘1–3 are the sections).
            Button(tvName(0)) { pick(0) }.keyboardShortcut("1", modifiers: [.command, .option])
            Button(tvName(1)) { pick(1) }.keyboardShortcut("2", modifiers: [.command, .option])
            Button(tvName(2)) { pick(2) }.keyboardShortcut("3", modifiers: [.command, .option])
            Button(tvName(3)) { pick(3) }.keyboardShortcut("4", modifiers: [.command, .option])
            Divider()
            Button("Play / Pause") { send("playpause") }.keyboardShortcut("p", modifiers: [.command, .option])
            // ⇧⌘H: ⌥⌘H is the Mac's own Hide Others, which always took it first.
            Button("Home") { send("home") }.keyboardShortcut("h", modifiers: [.command, .shift])
            // No key of its own: ⌥⌘M is the Mac's own Minimize All (M in the remote's panel still mutes).
            Button("Mute") { send("mute") }
            Button("Volume Up") { send("volup") }.keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Button("Volume Down") { send("voldown") }.keyboardShortcut(.downArrow, modifiers: [.command, .option])
        }
    }

    @MainActor private func paired() -> [FleetTV] { fleet.tvs.filter { !$0.isUnpaired } }
    /// From `pairedNames` (the same TVs in the same order), not the TVs themselves: the menu is rebuilt whenever what
    /// it reads changes, and the TVs change every second or two while their names hardly ever do.
    @MainActor private func tvName(_ i: Int) -> String {
        let names = fleet.pairedNames
        return i < names.count ? names[i] : "TV \(i + 1)"
    }
    @MainActor private func pick(_ i: Int) {
        let list = paired()
        guard i < list.count else { return }
        fleet.remoteAll = false
        fleet.selectedID = list[i].id
    }

    /// The remote's keys, sent as the remote sends them (LG direct control for an LG that has it, every TV that's
    /// on when the remote is on All TVs), saying so when one doesn't go through.
    @MainActor private func send(_ key: String) {
        MacActions.send(key, fleet: fleet)
    }
}

// The menu items that follow the window, each a view of its own: a view is drawn again when what it reads changes
// (the section showing, whether there's a search field, whether there's a page to go back to), so the menu bar never
// shows an old tick or an item greyed that shouldn't be.

/// View's Home, Watch and Settings (⌘1–3): the one the window shows is ticked. Choosing one goes to its first page.
private struct SectionCommands: View {
    var body: some View {
        let shown = MacBar.shared.section
        item(.home, "1", shown)
        item(.watch, "2", shown)
        item(.settings, "3", shown)
    }

    private func item(_ section: AppSection, _ key: KeyEquivalent, _ shown: AppSection?) -> some View {
        Toggle(section.title, isOn: Binding(get: { shown == section }, set: { _ in MacActions.open(section) }))
            .keyboardShortcut(key, modifiers: .command)
    }
}

/// View > Back (⌘[), there to choose while a page is open on the window's stack or Watch's search results show.
private struct BackCommand: View {
    var body: some View {
        Button("Back") { MacActions.backFromMenu() }
            .keyboardShortcut("[", modifiers: .command)
            .disabled(!MacActions.canGoBack)
    }
}

/// Edit > Find (⌘F), there to choose while the toolbar has its search field.
private struct FindCommand: View {
    var body: some View {
        Button("Find") { MacActions.find() }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(!MacBar.shared.searchShown)
    }
}

/// What the Mac's keyboard, menus and command palette do to the TVs, done the way the remote does it, and what the
/// menus do to Woodruff's own window (its sections, Back, Find and the Command Palette).
@MainActor
enum MacActions {
    /// [key] on the remote's TV, or on every TV that's on when the remote is set to All TVs.
    static func send(_ key: String, fleet: Fleet) {
        let targets = fleet.remoteAll ? fleet.tvs.filter { $0.online && !$0.isUnpaired } : (fleet.selected.map { [$0] } ?? [])
        send(key, to: targets, fleet: fleet)
    }

    /// [key] on each of [targets] at once. Any that didn't go through say why (in one message). [woodruffHome]: Home
    /// opens Woodruff's Home, not an Android TV's own home screen.
    static func send(_ key: String, to targets: [FleetTV], fleet: Fleet, woodruffHome: Bool = false) {
        guard !targets.isEmpty else { return }
        let android = !(woodruffHome && key == "home")
        Task {
            var failed: [String] = []
            await withTaskGroup(of: String?.self) { group in
                for tv in targets {
                    group.addTask { await MacActions.press(key, on: tv, fleet: fleet, android: android) }
                }
                for await problem in group {
                    if let problem { failed.append(problem) }
                }
            }
            guard !failed.isEmpty else { return }
            fleet.say(targets.count == 1 ? "Couldn't do that" : "Didn’t Reach Every TV", failed.joined(separator: "\n"))
        }
    }

    /// Presses [key] on [tv] as the remote does (`RemoteKeys`: LG direct control or the Android TV remote when there
    /// is one, otherwise Woodruff on the TV). Nil when it went through, else what went wrong.
    private static func press(_ key: String, on tv: FleetTV, fleet: Fleet, android: Bool) async -> String? {
        do {
            try await RemoteKeys.press(key, on: tv, fleet: fleet, android: android)
            return nil
        } catch let e as RemoteKeys.Failure {
            return e.localizedDescription
        } catch {
            return "\(tv.name): \(error.localizedDescription)"
        }
    }

    /// The family's Settings, in Woodruff's own window. (⌘, opens this Mac's own Settings window instead.)
    static func openSettings() { open(.settings) }

    /// A section's first page (⌘1–3, and View's Home, Watch and Settings), in Woodruff's own window, opened again if
    /// it was closed: a camera filling it is put away, a page opened on top is closed and Watch's search is cleared,
    /// as a click on the section in the toolbar does.
    static func open(_ section: AppSection) {
        if CameraStreams.shared.full != nil { CameraStreams.shared.full = nil }
        MacNav.shared.reset()
        if !MacBar.shared.query.isEmpty { MacBar.shared.query = "" }
        UserDefaults.standard.set(section.rawValue, forKey: "section")
        MainWindowOpener.show()
    }

    /// Whether there's somewhere to go back to: a page opened on the window's stack, or Watch's search results.
    static var canGoBack: Bool { !MacNav.shared.path.isEmpty || MacBar.shared.hasQuery }

    /// Back (the toolbar's button): the page on top closes; with none, Watch's search results give way to Watch.
    static func back() {
        if !MacNav.shared.path.isEmpty {
            MacNav.shared.pop()
        } else if !MacBar.shared.query.isEmpty {
            withAnimation(.smooth(duration: 0.25)) { MacBar.shared.query = "" }
        }
    }

    /// Woodruff's own window is the one in front, with no sheet over it: not while the Mini Player or a film's
    /// window is, and not under a sheet (which has the keyboard, and whose pages have their own Back).
    private static var windowInFront: Bool {
        guard let window = MainWindow.current else { return false }
        return window.isMainWindow && window.attachedSheet == nil
    }

    /// View > Back (⌘[): as the toolbar's button, while Woodruff's own window is the one in front. A page inside
    /// Settings has its own Back and ⌘[ too: there's nothing on the window's stack then, so this is greyed and leaves
    /// the keys to it.
    static func backFromMenu() {
        if windowInFront { back() }
    }

    /// Edit > Find (⌘F): the cursor goes to the toolbar's search field.
    static func find() {
        if windowInFront { MacBar.shared.finds += 1 }
    }

    /// View > Command Palette (⌘K), in Woodruff's own window (opened again if it was closed). Not over another sheet,
    /// and not before a TV is paired (the window has only its welcome then).
    static func showPalette() {
        guard MainWindow.current?.attachedSheet == nil, !Fleet.shared.hubs.isEmpty else { return }
        MacBar.shared.palette = true
        MainWindowOpener.show()
    }

    /// Asks every Android TV that's on to update, and says how that went.
    static func updateAll(_ fleet: Fleet) {
        Task {
            let (asked, failed) = await fleet.pushUpdateToAll()
            if !failed.isEmpty {
                fleet.say("Update All", failed.joined(separator: "\n"))
            } else if asked == 0 {
                fleet.say("Update All", "No Android TV is on right now.")
            } else {
                fleet.say("Update All", "Asked \(asked) TV\(asked == 1 ? "" : "s") to update. Each installs once nobody’s watching.")
            }
        }
    }
}

/// Clicking Woodruff in the Dock brings its window back: out of the Dock when it's minimised, to the front when it's
/// behind, and a new one when it was closed (the menu bar's panel and the Mini Player don't count as the window).
@MainActor
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Handled here: nothing more for AppKit to do. (Not handled only if the window can't be opened from here yet.)
        !MainWindowOpener.show()
    }
}

/// Opens Woodruff's own window from outside SwiftUI (the Dock, the menus, a notification). The menu bar icon hands
/// over SwiftUI's openWindow at launch; it's always there, even with every window closed.
@MainActor
enum MainWindowOpener {
    static var openWindow: OpenWindowAction?

    /// Brings the window forward when it's open: out of the Dock, from behind, and back from ⌘H (a hidden app's
    /// window isn't on screen, but it isn't closed: it's the one to show, not a reason for a second). False when
    /// it's closed (`MainWindow.current` is nil from then).
    @discardableResult static func front() -> Bool {
        guard let w = MainWindow.current else { return false }
        if NSApp.isHidden { NSApp.unhide(nil) }
        if w.isMiniaturized { w.deminiaturize(nil) }
        w.makeKeyAndOrderFront(nil)
        return true
    }

    /// When a new window was last asked for here.
    private static var asked = Date.distantPast

    /// Whether the window is showing now (or on its way): the open one brought forward, else a new one.
    @discardableResult static func show() -> Bool {
        NSApp.activate()
        if front() { return true }
        // One is on its way already: asked for a moment ago and not up yet (⌘N held down), or the app has only just
        // started and its first window comes by itself (a clicked alert that started the app asks as well). Not a
        // second one beside it.
        let justAsked = Date().timeIntervalSince(asked) < 1
        let justStarted = AppWake.started.map { Date().timeIntervalSince($0) < 3 } ?? false
        if justAsked || justStarted { return true }
        guard let openWindow else { return false }
        asked = Date()
        openWindow(id: "main")
        return true
    }
}
