import SwiftUI
import WoodruffKit

/// The menu bar's mini-player, like the Music app's: what the remote's TV is playing with its artwork, progress
/// and transport, a TV switcher, and every TV's state underneath.
struct MenuBarFleetView: View {
    @Environment(Fleet.self) private var fleet
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let tv = fleet.selected
        let p = tv?.playing
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
                Color.clear.overlay { NowPlayingArt(playing: p ?? tv.flatMap { fleet.lastPlaying[$0.id] }, backdrop: true) }.clipped()
                    .opacity(p == nil ? 0.5 : 1)
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
                        Text(t.playing?.title ?? (t.online ? (t.isUnpaired ? "Not paired" : "On") : "Off"))
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
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
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
        return t.playing?.isPlaying == true ? .accentColor : .green
    }
}

/// Menu commands: refresh, the remote's keys, and ⌘1–⌘4 to pick a TV.
struct WoodruffCommands: Commands {
    var fleet: Fleet
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(after: .windowArrangement) {
            Button("Mini Player") { openWindow(id: "mini") }.keyboardShortcut("m", modifiers: [.command, .shift])
        }
        CommandMenu("TVs") {
            Button("Refresh All") { Task { await fleet.refresh(); await fleet.loadAllHealth() } }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Update Every Android TV") { Task { _ = await fleet.pushUpdateToAll() } }
            Divider()
            Button(tvName(0)) { pick(0) }.keyboardShortcut("1", modifiers: .command)
            Button(tvName(1)) { pick(1) }.keyboardShortcut("2", modifiers: .command)
            Button(tvName(2)) { pick(2) }.keyboardShortcut("3", modifiers: .command)
            Button(tvName(3)) { pick(3) }.keyboardShortcut("4", modifiers: .command)
            Divider()
            Button("Play / Pause") { send("playpause") }.keyboardShortcut("p", modifiers: [.command, .option])
            Button("Home") { send("home") }.keyboardShortcut("h", modifiers: [.command, .option])
            Button("Mute") { send("mute") }.keyboardShortcut("m", modifiers: [.command, .option])
            Button("Volume Up") { send("volup") }.keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Button("Volume Down") { send("voldown") }.keyboardShortcut(.downArrow, modifiers: [.command, .option])
        }
    }

    @MainActor private func paired() -> [FleetTV] { fleet.tvs.filter { !$0.isUnpaired } }
    @MainActor private func tvName(_ i: Int) -> String { i < paired().count ? paired()[i].name : "TV \(i + 1)" }
    @MainActor private func pick(_ i: Int) {
        let list = paired()
        guard i < list.count else { return }
        fleet.remoteAll = false
        fleet.selectedID = list[i].id
    }

    private func send(_ key: String) {
        Task { @MainActor in try? await fleet.selectedClient?.key(key) }
    }
}
