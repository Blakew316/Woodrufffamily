import SwiftUI
import WoodruffKit

/// The one remote, for every TV. The TV name at the top switches TVs (or All TVs). Keys go the best way each TV
/// allows: LG direct control when it's connected (reaches every app), otherwise Woodruff on the TV.
struct RemoteView: View {
    @Environment(Fleet.self) private var fleet
    @State private var field: TypeState?
    @State private var typing = false
    @State private var presses = 0
    @State private var nowPlaying = false
    @State private var showPlaying = false

    private var tv: FleetTV? { fleet.selected }
    private var all: Bool { fleet.remoteAll }

    var body: some View {
        GeometryReader { geo in
            // Everything fits between the top bar and the tab bar: the clickpad takes whatever height is left
            // after the fixed rows, so nothing ever runs under the tab bar.
            let h = geo.size.height
            let key = min(62, max(46, h * 0.085))
            let gap = key * 0.26
            let keysH = key * 2 + gap
            let appsH = key * 0.78
            let topH: CGFloat = hasTop ? topHeight : 0
            let rows: CGFloat = 4 // gaps between status, clickpad, keys, apps
            let fixed = topH + keysH + appsH + rows * 16 + 8 + 10
            let pad = max(150, min(geo.size.width - 40, 360, h - fixed))
            VStack(spacing: 0) {
                if hasTop { status.frame(height: topH, alignment: .top) }
                Spacer(minLength: 16)
                Clickpad(size: pad) { send($0) } onRepeat: { send($0, repeat: $1) }
                Spacer(minLength: 16)
                keys(key, gap)
                Spacer(minLength: 16).frame(maxHeight: 22)
                apps(appsH)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 10)
            .frame(maxWidth: 460)
            .frame(width: geo.size.width, height: h)
        }
        .haptic(presses)
        .toolbar {
            ToolbarItem(placement: .principal) { TVPicker(allowAll: true) }
                .sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .primaryAction) {
                Button { send("home") } label: { Image(systemName: "house") }
                    .accessibilityLabel("Home")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { typing = true } label: {
                    Image(systemName: "keyboard")
                }
                .disabled(all)
                .tint(field?.field != nil ? Color.accentColor : nil)
            }
            if let tv, !all, fleet.lg(for: tv) != nil {
                ToolbarItem(placement: .primaryAction) { LGMenu(tv: tv) }
            }
        }
        .inlineTitle()
        .sheet(isPresented: $typing) { if let tv { KeyboardSheet(tv: tv) } }
        .task(id: "\(fleet.selectedID ?? "")-\(all)") { await fieldLoop() }
        .sheet(isPresented: $nowPlaying) { NowPlayingSheet() }
        .onAppear {
            let r = UserDefaults.standard.string(forKey: "route")
            if r == "keyboard" { typing = true }
            if r == "nowplaying" { nowPlaying = true }
        }
        #if os(macOS)
        .navigationTitle("Remote")
        .focusable()
        .focusEffectDisabled()
        .onKeyPress { press in handleKey(press) }
        #endif
    }

    // MARK: Pieces

    private var topHeight: CGFloat {
        guard !all, let tv, tv.online, tv.link != "refused", tv.playing != nil else { return 66 }
        return showPlaying ? 120 : 44
    }

    private var hasTop: Bool {
        if all { return true }
        guard let tv else { return false }
        return !tv.online || tv.link == "refused" || tv.playing != nil || field?.field != nil
    }

    @ViewBuilder private var status: some View {
        if all {
            Text("Every key goes to the \(fleet.tvs.filter(\.online).count) TVs that are on.")
                .font(.footnote).foregroundStyle(.secondary)
        } else if let tv, !tv.online || tv.link == "refused" {
            HStack(spacing: 10) {
                Image(systemName: "wifi.exclamationmark").foregroundStyle(Palette.attention)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Can’t Reach \(tv.name)").font(.subheadline.weight(.semibold))
                    Text(tv.link == "refused" ? "Its link stopped working. Link it again in Settings → TVs." : "Check that it’s on and this device is on the same Wi‑Fi.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if let mac = fleet.extras[tv.id]?.mac {
                    Button("Turn On") { WakeOnLAN.wake(mac: mac, lastHost: fleet.extras[tv.id]?.lastHost) }
                        .buttonStyle(.glassProminent)
                }
            }
            .padding(14)
            .glass(RoundedRectangle(cornerRadius: 20, style: .continuous), interactive: false)
        } else if let tv, let p = tv.playing {
            NowPlayingDropdown(tv: tv, playing: p, expanded: $showPlaying)
        } else if let f = field?.field {
            Button { typing = true } label: {
                Label("Type into \(f.label?.isEmpty == false ? f.label! : "the text box")", systemImage: "keyboard")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16).padding(.vertical, 10)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .glass(Capsule(), tint: Color.accentColor.opacity(0.18))
            .transition(.scale.combined(with: .opacity))
        }
    }

    /// Back and Mute beside the volume rocker. OK on the clickpad plays and pauses; Home is in the top bar.
    private func keys(_ key: CGFloat, _ gap: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(spacing: gap) {
                RoundKey(symbol: "chevron.backward", label: "Back", size: key) { send("back") }
                RoundKey(symbol: "speaker.slash.fill", label: "Mute", size: key) { send("mute") }
            }
            .frame(maxWidth: .infinity)
            VolumeRocker(width: key, height: key * 2 + gap) { up, n in send(up ? "volup" : "voldown", repeat: n) }
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: 300)
        .glassGroup(spacing: gap)
    }

    private func apps(_ height: CGFloat) -> some View {
        HStack(spacing: 12) {
            AppKey(title: "Netflix", height: height, mark: AnyView(Text("N").font(.system(size: 19, weight: .black)).foregroundStyle(.red))) { send("netflix") }
            AppKey(title: "YouTube", height: height, mark: AnyView(Image(systemName: "play.rectangle.fill").foregroundStyle(.white, .red))) { send("youtube") }
        }
        .frame(maxWidth: 340)
    }

    // MARK: Sending

    private func send(_ key: String, repeat n: Int = 0) {
        presses += 1
        let targets = all ? fleet.tvs.filter(\.online) : (tv.map { [$0] } ?? [])
        for t in targets {
            Task {
                do {
                    if let lg = fleet.lg(for: t), let action = LGKeyMap.action(for: key) { try await action(lg) }
                    else { try await fleet.client(for: t)?.key(key, repeat: n) }
                    if key == "ok" && !all {
                        try? await Task.sleep(nanoseconds: 400_000_000)
                        if let s = try? await fleet.client(for: t)?.typeField() { withAnimation(.snappy) { field = s } }
                    }
                } catch {
                    if !all && n == 0 { fleet.show(error) }
                }
            }
        }
    }

    private func fieldLoop() async {
        field = nil
        while !Task.isCancelled {
            if !all, let t = tv, t.online, let c = fleet.client(for: t), let s = try? await c.typeField() {
                withAnimation(.snappy) { field = s }
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    #if os(macOS)
    /// The Mac's keyboard is the remote: arrows, Return = OK, Esc/Delete = Back, Space = Play/Pause, H, M, + and −.
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

/// The round clickpad: tap an edge for an arrow, the middle for OK; swipe for arrows; hold to repeat; hold OK for Menu.
struct Clickpad: View {
    var size: CGFloat
    var onKey: (String) -> Void
    var onRepeat: (String, Int) -> Void
    @State private var pressed: String?
    @State private var hold: Task<Void, Never>?
    @State private var held = false
    @State private var began = false

    var body: some View {
        ZStack {
            Circle().fill(Palette.padFill)
                .overlay(Circle().strokeBorder(.white.opacity(0.06)))
                .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
            Circle().fill(pressed == "ok" ? Palette.padCenter.opacity(0.7) : Palette.padCenter)
                .frame(width: size * 0.42, height: size * 0.42)
                .overlay(Text("OK").font(.system(size: size * 0.055, weight: .semibold)).foregroundStyle(.secondary))
                .scaleEffect(pressed == "ok" ? 0.96 : 1)
            ForEach(["up", "down", "left", "right"], id: \.self) { d in
                Image(systemName: "chevron.\(d == "up" ? "up" : d == "down" ? "down" : d == "left" ? "left" : "right")")
                    .font(.system(size: size * 0.055, weight: .semibold))
                    .foregroundStyle(pressed == d ? Color.primary : .secondary)
                    .scaleEffect(pressed == d ? 1.25 : 1)
                    .offset(offset(d, size * 0.38))
            }
        }
        .frame(width: size, height: size)
        .animation(.spring(response: 0.22, dampingFraction: 0.65), value: pressed)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    if !began {
                        began = true
                        let zone = zoneAt(v.startLocation)
                        pressed = zone
                        startHold(zone)
                    }
                    if max(abs(v.translation.width), abs(v.translation.height)) > 26 { hold?.cancel() }
                }
                .onEnded { v in
                    hold?.cancel()
                    defer { pressed = nil; began = false; held = false }
                    if held { return }
                    let dx = v.translation.width, dy = v.translation.height
                    if max(abs(dx), abs(dy)) >= 26 {
                        onKey(abs(dx) > abs(dy) ? (dx > 0 ? "right" : "left") : (dy > 0 ? "down" : "up"))
                    } else {
                        onKey(zoneAt(v.startLocation))
                    }
                }
        )
        .accessibilityElement()
        .accessibilityLabel("Clickpad")
        .accessibilityAction(named: "OK") { onKey("ok") }
        .accessibilityAction(named: "Up") { onKey("up") }
        .accessibilityAction(named: "Down") { onKey("down") }
        .accessibilityAction(named: "Left") { onKey("left") }
        .accessibilityAction(named: "Right") { onKey("right") }
    }

    /// Hold an arrow: a press after 450 ms, then one every 140 ms. Hold OK for 500 ms: Menu.
    private func startHold(_ zone: String) {
        hold?.cancel()
        hold = Task {
            if zone == "ok" {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled else { return }
                held = true
                onKey("menu")
                return
            }
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            held = true
            var n = 0
            while !Task.isCancelled {
                onRepeat(zone, n); n += 1
                try? await Task.sleep(nanoseconds: 140_000_000)
            }
        }
    }

    private func zoneAt(_ p: CGPoint) -> String {
        let dx = p.x - size / 2, dy = p.y - size / 2
        if hypot(dx, dy) < size * 0.21 { return "ok" }
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

/// A round glass key.
struct RoundKey: View {
    var symbol: String
    var label: String
    var size: CGFloat = 64
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.33, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: size, height: size)
                .contentShape(Circle())
                .glass(Circle())
        }
        .buttonStyle(PressScale())
        .accessibilityLabel(label)
    }
}

/// The tall + / − capsule; each half repeats while held.
struct VolumeRocker: View {
    var width: CGFloat = 64
    var height: CGFloat = 146
    var send: (Bool, Int) -> Void
    var body: some View {
        VStack(spacing: 0) {
            half("plus", up: true)
            Rectangle().fill(.separator).frame(width: width * 0.38, height: 0.5)
            half("minus", up: false)
        }
        .frame(width: width, height: height)
        .glass(Capsule())
    }
    private func half(_ symbol: String, up: Bool) -> some View {
        RepeatPress(onPress: { send(up, $0) }) {
            Image(systemName: symbol).font(.system(size: width * 0.33, weight: .semibold)).frame(width: width, height: height / 2)
        }
        .accessibilityLabel(up ? "Volume up" : "Volume down")
    }
}

/// Fires once on touch, then repeats every 140 ms after 450 ms of holding.
struct RepeatPress<Label: View>: View {
    var onPress: (Int) -> Void
    @ViewBuilder var label: Label
    @State private var task: Task<Void, Never>?
    @State private var down = false

    var body: some View {
        label
            .contentShape(Rectangle())
            .opacity(down ? 0.55 : 1)
            .scaleEffect(down ? 0.9 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: down)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !down else { return }
                    down = true
                    onPress(0)
                    task = Task {
                        try? await Task.sleep(nanoseconds: 450_000_000)
                        var n = 1
                        while !Task.isCancelled { onPress(n); n += 1; try? await Task.sleep(nanoseconds: 140_000_000) }
                    }
                }
                .onEnded { _ in down = false; task?.cancel() })
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onPress(0) }
    }
}

/// Netflix / YouTube capsules.
struct AppKey: View {
    var title: String
    var height: CGFloat = 50
    var mark: AnyView
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                mark
                Text(title).font(.headline)
            }
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, minHeight: height)
            .contentShape(Capsule())
            .glass(Capsule())
        }
        .buttonStyle(PressScale(scale: 0.96))
    }
}

/// Woodruff key names → LG direct control.
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

/// LG TVs connected directly: apps, inputs, channels and power, in the remote's toolbar.
struct LGMenu: View {
    @Environment(Fleet.self) private var fleet
    var tv: FleetTV
    @State private var apps: [LGRemote.App] = []
    @State private var inputs: [LGRemote.App] = []

    var body: some View {
        Menu {
            Section {
                Button { run { try await $0.press(.channelUp) } } label: { Label("Channel Up", systemImage: "chevron.up") }
                Button { run { try await $0.press(.channelDown) } } label: { Label("Channel Down", systemImage: "chevron.down") }
            }
            Menu { ForEach(apps) { a in Button(a.title) { run { try await $0.launch(a.id) } } } } label: { Label("Apps", systemImage: "square.grid.2x2") }
            Menu { ForEach(inputs) { i in Button(i.title) { run { try await $0.switchInput(i.id) } } } } label: { Label("Inputs", systemImage: "cable.connector") }
            Section {
                Button { run { try await $0.screenOff() } } label: { Label("Turn Screen Off", systemImage: "rectangle.slash") }
                Button(role: .destructive) { run { try await $0.turnOff() } } label: { Label("Turn Off \(tv.name)", systemImage: "power") }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .task {
            guard let lg = fleet.lg(for: tv) else { return }
            apps = (try? await lg.apps()) ?? []
            inputs = (try? await lg.inputs()) ?? []
        }
    }

    private func run(_ op: @escaping (LGRemote) async throws -> Void) {
        Task { do { if let lg = fleet.lg(for: tv) { try await op(lg) } } catch { fleet.show(error) } }
    }
}

/// The phone's keyboard on the TV's selected text box: each change sends the whole text; Enter presses Done.
struct KeyboardSheet: View {
    @Environment(Fleet.self) private var fleet
    @Environment(\.dismiss) private var dismiss
    var tv: FleetTV
    @State private var text = ""
    @State private var state: TypeState?
    @State private var fieldKey: String?
    @State private var pending: Task<Void, Never>?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 8) {
                        Circle().fill(state?.field != nil ? Color.green : .gray).frame(width: 7, height: 7)
                        Text(fieldTitle).font(.subheadline).foregroundStyle(state?.field != nil ? .primary : .secondary)
                        Spacer()
                        Button("Clear") { text = "" }.disabled(text.isEmpty)
                    }
                    TextField("", text: $text, axis: .vertical)
                        .font(.title3)
                        .lineLimit(state?.field?.multiline == true ? 3...10 : 1...4)
                        .focused($focused)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit { submit() }
                        .onChange(of: text) { _, new in queue(new) }
                        .frame(minHeight: 120, alignment: .top)
                } footer: {
                    Text("Letters appear on the TV as you type. Enter presses Done on the TV.")
                }
                if let lg = fleet.lg(for: tv) {
                    Section {
                        Button("Type into \(tv.name)’s Own Keyboard") {
                            let t = text
                            Task { do { try await lg.insertText(t); try await lg.sendEnter() } catch { fleet.show(error) } }
                        }
                    } footer: { Text("For other apps on this LG TV (Netflix, YouTube, the browser).") }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Keyboard")
            #if os(iOS)
            .navigationSubtitle(tv.name)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(role: .close) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Enter") { submit() }.buttonStyle(.glassProminent).disabled(state?.field == nil)
                }
            }
            .task { await loop() }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium, .large])
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 360)
        #endif
    }

    private var fieldTitle: String {
        guard let f = state?.field else { return state?.note ?? "Select a text box on \(tv.name)" }
        let l = f.label?.isEmpty == false ? f.label! : "Text box"
        return f.secret == true ? "\(l) (hidden)" : l
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
        if new.contains("\n") && state?.field?.multiline != true { submit(); return }
        guard let f = state?.field else { return }
        pending?.cancel()
        pending = Task {
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
