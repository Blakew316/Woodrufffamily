import SwiftUI
import WoodruffKit

/// The menu bar: every TV at a glance, with quick controls, while the main window is closed.
struct MenuBarFleetView: View {
    @Environment(Fleet.self) private var fleet
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Woodruff TVs").font(.headline)
                Spacer()
                Button { Task { await fleet.refresh() } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless)
            }
            if fleet.tvs.isEmpty { Text("No TVs paired yet.").foregroundStyle(.secondary) }
            ForEach(fleet.tvs) { tv in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Circle().fill(tv.online ? (tv.needsAttention ? Color.orange : .green) : .gray).frame(width: 8, height: 8)
                        Text(tv.name).font(.subheadline.weight(.semibold))
                        Spacer()
                        if fleet.isBehind(tv) { Image(systemName: "arrow.down.circle.fill").foregroundStyle(.blue) }
                    }
                    if let p = tv.playing { Text(p.title).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    else if !tv.online { Text("Off · seen \(relative(tv.seen))").font(.caption).foregroundStyle(.secondary) }
                    else if let h = tv.health, h.status == "attention" { Text(h.first ?? "Needs attention").font(.caption).foregroundStyle(.orange) }
                }
            }
            Divider()
            HStack {
                Button("Open Woodruff") { NSApp.activate(ignoringOtherApps: true); NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil) }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding()
        .frame(width: 320)
    }
}

/// Menu commands: refresh, remote keys from the keyboard, update all.
struct WoodruffCommands: Commands {
    var fleet: Fleet
    var body: some Commands {
        CommandMenu("TVs") {
            Button("Refresh All") { Task { await fleet.refresh(); await fleet.loadAllHealth() } }.keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Update Every Android TV") { Task { _ = await fleet.pushUpdateToAll() } }
            Divider()
            Button("Play / Pause") { send("playpause") }.keyboardShortcut("p", modifiers: [.command, .option])
            Button("Home") { send("home") }.keyboardShortcut("h", modifiers: [.command, .option])
            Button("Mute") { send("mute") }.keyboardShortcut("m", modifiers: [.command, .option])
            Button("Volume Up") { send("volup") }.keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Button("Volume Down") { send("voldown") }.keyboardShortcut(.downArrow, modifiers: [.command, .option])
        }
    }
    private func send(_ key: String) {
        Task { @MainActor in try? await fleet.selectedClient?.key(key) }
    }
}
