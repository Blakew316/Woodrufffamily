import SwiftUI
import WoodruffKit

/// The menu bar's mini-player, like the Music app's: what the remote's TV is playing with its artwork, progress
/// and transport, a TV switcher, and every TV's state underneath.
struct MenuBarFleetView: View {
    @Environment(Fleet.self) private var fleet
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let tv = fleet.selected
        // What's on now only (no picture of the last thing it played once it's stopped, off or left paused).
        let p = tv?.nowPlaying
        VStack(alignment: .leading, spacing: 14) {
            Menu {
                ForEach(fleet.tvs.filter { !$0.isUnpaired }) { t in
                    Button { fleet.remoteAll = false; fleet.selectedID = t.id } label: {
                        Text(t.name); Text(statusWord(t))
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(tv?.name ?? "No TV").font(.headline)
                    Image(systemName: "chevron.down").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                }
            }
            .menuStyle(.button).buttonStyle(.plain).fixedSize()

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
                Button("Open Woodruff") {
                    NSApp.activate()
                    // Woodruff's own window (not the mini player); after it's been closed, a new one.
                    if let w = MainWindow.current, w.isVisible || w.isMiniaturized {
                        if w.isMiniaturized { w.deminiaturize(nil) }
                        w.makeKeyAndOrderFront(nil)
                    } else {
                        openWindow(id: "main")
                    }
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

/// Menu commands: Check for Updates, refresh, the remote's keys, and ⌘1–⌘4 to pick a TV.
struct WoodruffCommands: Commands {
    var fleet: Fleet
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        // Under About, where Mac apps keep it: the family's updater looks for a new version now, and Woodruff says what
        // it found.
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { UpdaterStatus.shared.checkNow(reportTo: fleet) }
        }
        CommandGroup(after: .windowArrangement) {
            Button("Mini Player") { openWindow(id: "mini") }.keyboardShortcut("m", modifiers: [.command, .shift])
        }
        CommandMenu("TVs") {
            Button("Refresh All") { Task { await fleet.refresh(); await fleet.loadAllHealth() } }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Update Every Android TV") { MacActions.updateAll(fleet) }
            Divider()
            Button(tvName(0)) { pick(0) }.keyboardShortcut("1", modifiers: .command)
            Button(tvName(1)) { pick(1) }.keyboardShortcut("2", modifiers: .command)
            Button(tvName(2)) { pick(2) }.keyboardShortcut("3", modifiers: .command)
            Button(tvName(3)) { pick(3) }.keyboardShortcut("4", modifiers: .command)
            Divider()
            Button("Play / Pause") { send("playpause") }.keyboardShortcut("p", modifiers: [.command, .option])
            // ⇧⌘H: ⌥⌘H is the Mac's own Hide Others, which always took it first.
            Button("Home") { send("home") }.keyboardShortcut("h", modifiers: [.command, .shift])
            Button("Mute") { send("mute") }.keyboardShortcut("m", modifiers: [.command, .option])
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

/// What the Mac's keyboard, menus and command palette do to the TVs, done the way the remote does it.
@MainActor
enum MacActions {
    /// [key] on the remote's TV, or on every TV that's on when the remote is set to All TVs.
    static func send(_ key: String, fleet: Fleet) {
        let targets = fleet.remoteAll ? fleet.tvs.filter { $0.online && !$0.isUnpaired } : (fleet.selected.map { [$0] } ?? [])
        send(key, to: targets, fleet: fleet)
    }

    /// [key] on each of [targets] at once. Any that didn't go through say why (in one message).
    static func send(_ key: String, to targets: [FleetTV], fleet: Fleet) {
        guard !targets.isEmpty else { return }
        Task {
            var failed: [String] = []
            await withTaskGroup(of: String?.self) { group in
                for tv in targets {
                    group.addTask { await MacActions.press(key, on: tv, fleet: fleet) }
                }
                for await problem in group {
                    if let problem { failed.append(problem) }
                }
            }
            guard !failed.isEmpty else { return }
            fleet.say(targets.count == 1 ? "Couldn't do that" : "Didn’t Reach Every TV", failed.joined(separator: "\n"))
        }
    }

    /// Presses [key] on [tv]: LG direct control when it's connected (it reaches every app), otherwise Woodruff on
    /// the TV. Nil when it went through, else what went wrong.
    private static func press(_ key: String, on tv: FleetTV, fleet: Fleet) async -> String? {
        do {
            if let lg = fleet.lg(for: tv), let action = LGKeyMap.action(for: key) {
                try await action(lg)
                // LG direct control doesn't pass through Woodruff: ask the TV what it's doing now.
                if !["volup", "voldown", "mute"].contains(key) { fleet.poke(tv.id) }
            } else if let client = fleet.client(for: tv) {
                // Woodruff tells the fleet itself, so what's playing updates at once.
                try await client.key(key)
            } else {
                return "\(tv.name) can't be reached from this Mac."
            }
            return nil
        } catch {
            return "\(tv.name): \(error.localizedDescription)"
        }
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
