import SwiftUI
import WoodruffKit

/// The remote, laid out like the Siri Remote: a clickpad (tap or swipe), Back, Home, Play/Pause, volume, Mute,
/// Netflix and YouTube, typing into the TV's text box, and what's playing. Picks any TV, or every TV at once.
/// With LG direct control connected, keys reach every app on an LG TV, not only Woodruff.
struct RemoteView: View {
    @Environment(Fleet.self) private var fleet
    @State private var everyTV = false
    @State private var field: TypeState?
    @State private var typing = false
    @State private var pressCount = 0

    var tv: FleetTV? { fleet.selected }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                picker
                if let tv, !tv.online, !everyTV { offlineBanner(tv) }
                if let f = field?.field, !everyTV {
                    Button { typing = true } label: {
                        Label("Type into \(f.label?.isEmpty == false ? f.label! : "the text box")", systemImage: "keyboard")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
                Clickpad { key in send(key) } onHold: { key in send(key) } onRepeat: { key, n in send(key, repeat: n) }
                    .frame(maxWidth: 320)
                buttons
                apps
                if let tv, let p = tv.playing, !everyTV {
                    Card { VStack { NowPlayingRow(playing: p); MediaControls(tv: tv, playing: p) } }
                }
                if let tv, !everyTV, fleet.lg(for: tv) != nil { LGExtras(tv: tv) }
            }
            .padding()
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .screenTitle("Remote")
        .haptic(pressCount)
        .toolbar {
            ToolbarItem {
                Button { typing = true } label: { Label("Keyboard", systemImage: field?.field != nil ? "keyboard.fill" : "keyboard") }
                    .disabled(everyTV)
            }
        }
        .sheet(isPresented: $typing) { if let tv { KeyboardSheet(tv: tv) } }
        .task(id: fleet.selectedID) { await fieldLoop() }
        #if os(macOS)
        .focusable()
        .onKeyPress { press in handleKey(press) }
        #endif
    }

    private var picker: some View {
        Menu {
            ForEach(fleet.tvs) { t in
                Button { everyTV = false; fleet.selectedID = t.id } label: {
                    Label("\(t.name) — \(statusWord(t))", systemImage: t.id == fleet.selectedID && !everyTV ? "checkmark" : "tv")
                }
            }
            Divider()
            Button { everyTV = true } label: { Label("Every TV at Once", systemImage: everyTV ? "checkmark" : "tv.and.mediabox") }
        } label: {
            HStack(spacing: 6) {
                Text(everyTV ? "Every TV" : (tv?.name ?? "Pick a TV")).font(.title2.bold())
                Image(systemName: "chevron.down.circle.fill").foregroundStyle(.secondary)
            }
            .foregroundStyle(.primary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func offlineBanner(_ tv: FleetTV) -> some View {
        Card {
            HStack {
                Image(systemName: "wifi.exclamationmark").foregroundStyle(.orange)
                VStack(alignment: .leading) {
                    Text("Can't reach \(tv.name)").font(.headline)
                    Text(tv.link == "refused" ? "Its link stopped working. Link it again from its page under TVs." : "Check that it's on and this device is on the same Wi-Fi.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let mac = fleet.extras[tv.id]?.mac {
                    Button("Turn On") { WakeOnLAN.wake(mac: mac, lastHost: fleet.extras[tv.id]?.lastHost) }
                }
            }
        }
    }

    private var buttons: some View {
        Grid(horizontalSpacing: 18, verticalSpacing: 16) {
            GridRow {
                RoundKey(symbol: "chevron.backward", label: "Back") { send("back") }
                RoundKey(symbol: "house.fill", label: "Home") { send("home") }
                RoundKey(symbol: "speaker.slash.fill", label: "Mute") { send("mute") }
            }
            GridRow {
                RoundKey(symbol: "playpause.fill", label: "Play/Pause") { send("playpause") }
                RepeatKey(symbol: "speaker.minus.fill", label: "Vol −") { n in send("voldown", repeat: n) }
                RepeatKey(symbol: "speaker.plus.fill", label: "Vol +") { n in send("volup", repeat: n) }
            }
        }
    }

    private var apps: some View {
        HStack(spacing: 12) {
            Button { send("netflix") } label: {
                Text("NETFLIX").font(.headline.weight(.heavy)).foregroundStyle(.red).frame(maxWidth: .infinity, minHeight: 44)
            }
            Button { send("youtube") } label: {
                Label("YouTube", systemImage: "play.rectangle.fill").font(.headline).foregroundStyle(.red).frame(maxWidth: .infinity, minHeight: 44)
            }
        }
        .buttonStyle(.bordered)
    }

    // MARK: Sending

    /// Through LG direct control when it's connected (reaches every app), otherwise Woodruff's /api/key.
    private func send(_ key: String, repeat n: Int = 0) {
        pressCount += 1
        let targets = everyTV ? fleet.tvs.filter(\.online) : (tv.map { [$0] } ?? [])
        for t in targets {
            Task {
                do {
                    if let lg = fleet.lg(for: t), let action = LGKeyMap.action(for: key) {
                        try await action(lg)
                    } else {
                        try await fleet.client(for: t)?.key(key, repeat: n)
                    }
                    if key == "ok" && !everyTV {
                        try? await Task.sleep(nanoseconds: 400_000_000)
                        field = try? await fleet.client(for: t)?.typeField()
                    }
                } catch {
                    if !everyTV && n == 0 { fleet.show(error) }
                }
            }
        }
    }

    private func fieldLoop() async {
        field = nil
        while !Task.isCancelled {
            if !everyTV, let t = tv, t.online, let c = fleet.client(for: t) {
                field = try? await c.typeField()
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    private func statusWord(_ t: FleetTV) -> String {
        if t.link == "refused" { return "Link again" }
        if !t.online { return "Off" }
        if let p = t.playing { return (p.isPlaying ? "Playing " : "Paused · ") + p.title }
        return "Nothing playing"
    }

    #if os(macOS)
    /// The Mac's keyboard is a remote too: arrows, Return = OK, Delete/Esc = Back, Space = Play/Pause, H = Home, M = Mute.
    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .upArrow: send("up")
        case .downArrow: send("down")
        case .leftArrow: send("left")
        case .rightArrow: send("right")
        case .return: send("ok")
        case .escape, .delete: send("back")
        case .space: send("playpause")
        default:
            switch press.characters.lowercased() {
            case "h": send("home")
            case "m": send("mute")
            case "=", "+": send("volup")
            case "-": send("voldown")
            default: return .ignored
            }
        }
        return .handled
    }
    #endif
}

/// The round clickpad: tap the edges for arrows, the middle for OK, swipe for arrows, hold for repeat / menu.
struct Clickpad: View {
    var onKey: (String) -> Void
    var onHold: (String) -> Void
    var onRepeat: (String, Int) -> Void
    @State private var pressed: String?
    @State private var holdTask: Task<Void, Never>?
    @State private var held = false
    @State private var start: CGPoint?

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            ZStack {
                Circle().fill(.background.secondary)
                    .overlay(Circle().stroke(.quaternary))
                    .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
                Circle().fill(pressed == "ok" ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.05))
                    .frame(width: size * 0.38, height: size * 0.38)
                ForEach(["up", "down", "left", "right"], id: \.self) { d in
                    Image(systemName: "chevron.\(d == "up" ? "up" : d == "down" ? "down" : d == "left" ? "left" : "right")")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(pressed == d ? Color.accentColor : .secondary)
                        .offset(offset(d, size * 0.36))
                }
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        if start == nil {
                            start = v.startLocation
                            let zone = zoneAt(v.startLocation, size)
                            pressed = zone
                            beginHold(zone)
                        }
                        if v.translation.width.magnitude > 26 || v.translation.height.magnitude > 26 {
                            holdTask?.cancel()
                        }
                    }
                    .onEnded { v in
                        holdTask?.cancel()
                        defer { pressed = nil; start = nil; held = false }
                        if held { return }
                        let dx = v.translation.width, dy = v.translation.height
                        if max(dx.magnitude, dy.magnitude) >= 26 {
                            onKey(dx.magnitude > dy.magnitude ? (dx > 0 ? "right" : "left") : (dy > 0 ? "down" : "up"))
                        } else {
                            onKey(zoneAt(v.startLocation, size))
                        }
                    }
            )
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement()
        .accessibilityLabel("Clickpad")
        .accessibilityAction(named: "OK") { onKey("ok") }
        .accessibilityAction(named: "Up") { onKey("up") }
        .accessibilityAction(named: "Down") { onKey("down") }
        .accessibilityAction(named: "Left") { onKey("left") }
        .accessibilityAction(named: "Right") { onKey("right") }
    }

    /// Hold an arrow: one press after 450 ms, then one every 140 ms (repeat 1, 2, 3…). Hold OK 500 ms: Menu.
    private func beginHold(_ zone: String) {
        holdTask?.cancel()
        holdTask = Task {
            if zone == "ok" {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled else { return }
                held = true
                onHold("menu")
                return
            }
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            held = true
            onRepeat(zone, 0)
            var n = 1
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 140_000_000)
                if Task.isCancelled { break }
                onRepeat(zone, n); n += 1
            }
        }
    }

    private func zoneAt(_ p: CGPoint, _ size: CGFloat) -> String {
        let dx = p.x - size / 2, dy = p.y - size / 2
        if hypot(dx, dy) < size * 0.19 { return "ok" }
        return abs(dx) > abs(dy) ? (dx > 0 ? "right" : "left") : (dy > 0 ? "down" : "up")
    }

    private func offset(_ d: String, _ r: CGFloat) -> CGSize {
        switch d {
        case "up": return CGSize(width: 0, height: -r)
        case "down": return CGSize(width: 0, height: r)
        case "left": return CGSize(width: -r, height: 0)
        default: return CGSize(width: r, height: 0)
        }
    }
}

struct RoundKey: View {
    var symbol: String
    var label: String
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.title2).frame(width: 64, height: 64)
                    .background(.background.secondary, in: Circle())
                    .overlay(Circle().stroke(.quaternary))
                Text(label).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// A key that repeats while held (volume).
struct RepeatKey: View {
    var symbol: String
    var label: String
    var action: (Int) -> Void
    @State private var task: Task<Void, Never>?
    @State private var down = false

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: symbol).font(.title2).frame(width: 64, height: 64)
                .background(down ? AnyShapeStyle(Color.accentColor.opacity(0.25)) : AnyShapeStyle(.background.secondary), in: Circle())
                .overlay(Circle().stroke(.quaternary))
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard !down else { return }
                down = true
                action(0)
                task = Task {
                    try? await Task.sleep(nanoseconds: 450_000_000)
                    var n = 1
                    while !Task.isCancelled { action(n); n += 1; try? await Task.sleep(nanoseconds: 140_000_000) }
                }
            }
            .onEnded { _ in down = false; task?.cancel() })
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(label)
        .accessibilityAction { action(0) }
    }
}

/// Woodruff key names → LG direct-control commands.
enum LGKeyMap {
    static func action(for key: String) -> ((LGRemote) async throws -> Void)? {
        let b: LGRemote.Button?
        switch key {
        case "up": b = .up
        case "down": b = .down
        case "left": b = .left
        case "right": b = .right
        case "ok": b = .enter
        case "back": b = .back
        case "menu": b = .menu
        case "info": b = .info
        case "volup": return { try await $0.volumeUp() }
        case "voldown": return { try await $0.volumeDown() }
        case "mute": return { lg in let v = try await lg.volume(); try await lg.setMute(!v.muted) }
        case "netflix": return { try await $0.launch("netflix") }
        case "youtube": return { try await $0.launch("youtube.leanback.v4") }
        case "home": return { try await $0.launch("com.woodruff.family") }
        default: b = nil
        }
        guard let b else { return nil }
        return { try await $0.press(b) }
    }
}

/// The phone's keyboard on the TV's selected text box: every change sends the whole text; Return presses Done.
struct KeyboardSheet: View {
    @Environment(Fleet.self) private var fleet
    @Environment(\.dismiss) private var dismiss
    var tv: FleetTV
    @State private var text = ""
    @State private var state: TypeState?
    @State private var fieldKey: String?
    @State private var sendTask: Task<Void, Never>?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let f = state?.field {
                        Label(f.secret == true ? "\(f.label ?? "Text box") (hidden)" : (f.label ?? "Text box"), systemImage: "character.cursor.ibeam")
                    } else {
                        Text(state?.note ?? "Select a text box on \(tv.name) first.").foregroundStyle(.secondary)
                    }
                }
                Section {
                    TextField("Type here", text: $text, axis: state?.field?.multiline == true ? .vertical : .horizontal)
                        .focused($focused)
                        .autocorrectionDisabled()
                        .onSubmit { submit() }
                        .onChange(of: text) { _, new in queue(new) }
                }
                Section {
                    Button("Send and Press Done") { submit() }.disabled(state?.field == nil)
                    Button("Clear", role: .destructive) { text = "" }
                }
                if fleet.lg(for: tv) != nil {
                    Section("LG keyboard (any app)") {
                        Button("Type into the TV's on-screen keyboard") {
                            let t = text
                            Task { do { try await fleet.lg(for: tv)?.insertText(t); try await fleet.lg(for: tv)?.sendEnter() } catch { fleet.show(error) } }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Type on \(tv.name)")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await loop() }
            .onAppear { focused = true }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 360)
        #endif
    }

    private func loop() async {
        while !Task.isCancelled {
            if let s = try? await fleet.client(for: tv)?.typeField() {
                state = s
                let key = s.field.map { "\($0.id)" }
                if key != fieldKey { fieldKey = key; text = s.field?.text ?? "" }
            }
            try? await Task.sleep(nanoseconds: 1_200_000_000)
        }
    }

    private func clean(_ s: String) -> String { state?.field?.multiline == true ? s : s.replacingOccurrences(of: "\n", with: " ") }

    private func queue(_ new: String) {
        guard let f = state?.field else { return }
        sendTask?.cancel()
        sendTask = Task {
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            try? await fleet.client(for: tv)?.type(clean(new), field: f.id)
        }
    }

    private func submit() {
        guard let f = state?.field else { return }
        let t = clean(text)
        Task {
            do {
                try await fleet.client(for: tv)?.type(t, field: f.id, submit: true)
                text = ""
                dismiss()
            } catch { fleet.show(error) }
        }
    }
}

/// LG direct control extras: apps, inputs, channels, numbers, power and the screen.
struct LGExtras: View {
    @Environment(Fleet.self) private var fleet
    var tv: FleetTV
    @State private var apps: [LGRemote.App] = []
    @State private var inputs: [LGRemote.App] = []

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Label("LG Direct Control", systemImage: "bolt.horizontal.fill").font(.headline)
                HStack {
                    lgButton("Play", "play.fill") { try await $0.press(.play) }
                    lgButton("Pause", "pause.fill") { try await $0.press(.pause) }
                    lgButton("Ch +", "chevron.up.square") { try await $0.press(.channelUp) }
                    lgButton("Ch −", "chevron.down.square") { try await $0.press(.channelDown) }
                    lgButton("Settings", "gearshape") { try await $0.press(.qmenu) }
                    lgButton("Screen Off", "rectangle.slash") { try await $0.screenOff() }
                    lgButton("Power Off", "power") { try await $0.turnOff() }
                }
                Menu("Apps") {
                    ForEach(apps) { a in Button(a.title) { run { try await $0.launch(a.id) } } }
                }
                .disabled(apps.isEmpty)
                Menu("Inputs") {
                    ForEach(inputs) { i in Button(i.title) { run { try await $0.switchInput(i.id) } } }
                }
                .disabled(inputs.isEmpty)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5)) {
                    ForEach(["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"], id: \.self) { n in
                        Button(n) { run { try await $0.press(LGRemote.Button(rawValue: n)!) } }.buttonStyle(.bordered)
                    }
                }
            }
        }
        .task {
            guard let lg = fleet.lg(for: tv) else { return }
            apps = (try? await lg.apps()) ?? []
            inputs = (try? await lg.inputs()) ?? []
        }
    }

    private func lgButton(_ title: String, _ symbol: String, _ op: @escaping (LGRemote) async throws -> Void) -> some View {
        Button { run(op) } label: { VStack { Image(systemName: symbol); Text(title).font(.caption2) }.frame(maxWidth: .infinity) }
            .buttonStyle(.bordered)
    }

    private func run(_ op: @escaping (LGRemote) async throws -> Void) {
        Task { do { if let lg = fleet.lg(for: tv) { try await op(lg) } } catch { fleet.show(error) } }
    }
}

/// Setting up LG direct control on a TV's page.
struct LGSection: View {
    @Environment(Fleet.self) private var fleet
    var tv: FleetTV
    @State private var host = ""
    @State private var busy = false

    var body: some View {
        if fleet.platform(of: tv) != .android {
            Section {
                if let h = fleet.extras[tv.id]?.lgHost {
                    LabeledContent("Connected to", value: h)
                    if let mac = fleet.extras[tv.id]?.mac { LabeledContent("Wake-on-LAN", value: mac) }
                    Button("Disconnect", role: .destructive) { fleet.forgetLG(tv) }
                } else {
                    TextField("TV's address (e.g. 192.168.1.40)", text: $host)
                        .autocorrectionDisabled()
                    Button(busy ? "Accept on the TV…" : "Connect") {
                        busy = true
                        Task {
                            do { try await fleet.connectLG(tv, host: host.trimmingCharacters(in: .whitespaces)); fleet.say("LG direct control is on", "The remote now works in every app on \(tv.name).") } catch { fleet.show(error) }
                            busy = false
                        }
                    }
                    .disabled(host.isEmpty || busy)
                }
            } header: {
                Text("LG Direct Control")
            } footer: {
                Text("Optional. LG TVs only let Woodruff take keys while it's on screen. Connected directly, this app is a full remote in every app (Netflix included), types into any keyboard, switches inputs and turns the TV off and on. The TV asks once to allow it.")
            }
            .onAppear { if host.isEmpty { host = fleet.extras[tv.id]?.lastHost ?? "" } }
        }
    }
}
