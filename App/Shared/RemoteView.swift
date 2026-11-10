import SwiftUI
import WoodruffKit

/// The one remote, for every TV. The TV name at the top switches TVs (or All TVs). Keys go the best way each TV
/// allows: LG direct control when it's connected (reaches every app), otherwise Woodruff on the TV.
struct RemoteView: View {
    @Environment(Fleet.self) private var fleet
    /// In the Mac's right-hand sidebar: its own header instead of the window's toolbar.
    var embedded = false
    @State private var field: TypeState?
    @State private var typing = false
    @State private var presses = 0
    @State private var arrowTicks = 0
    @State private var okTicks = 0
    @State private var nowPlaying = false
    @State private var showPlaying = false
    @State private var lastFieldKey: String?

    private var tv: FleetTV? { fleet.selected }
    private var all: Bool { fleet.remoteAll }
    #if os(iOS) || os(tvOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// iPad (a wide window): what's playing beside the remote, its name next to the TV's at the top.
    private var padLayout: Bool { sizeClass == .regular }
    #else
    private let padLayout = false
    #endif
    #if os(iOS)
    @Environment(\.verticalSizeClass) private var heightClass
    /// iPhone on its side: the clickpad and the keys sit side by side, and what's playing is named in the top bar.
    private var lowLayout: Bool { heightClass == .compact }
    #else
    private let lowLayout = false
    #endif
    #if os(iOS)
    /// iPad: a keyboard's arrows, Return, Esc and Space are the remote's while it's on screen.
    private static let takesKeys = UIDevice.current.userInterfaceIdiom == .pad
    @FocusState private var keysFocused: Bool
    #endif
    /// What's playing is shown in the top bar (iPad, and iPhone on its side) instead of over the clickpad.
    private var titleInBar: Bool {
        guard padLayout || lowLayout, !all, let tv, tv.online, tv.link != "refused" else { return false }
        return tv.playing != nil
    }

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
            #if os(macOS)
            // On the Mac, a small remote in the middle of the window (the keyboard drives it too).
            VStack(spacing: 18) {
                if embedded {
                    VStack(spacing: 10) {
                        // Close, at the panel's own corner: the remote's button in Woodruff's bar is on Home only,
                        // and away from Home nothing on screen closed it. Beside it an LG's own menu (apps, inputs,
                        // channels, power), which the iPhone has in its toolbar and the Mac had nowhere. (A row of
                        // their own: the one below is already as wide as the panel.)
                        HStack {
                            if let tv, !all, fleet.lg(for: tv) != nil {
                                LGMenu(tv: tv).menuStyle(.button).buttonStyle(.glass).menuIndicator(.hidden).fixedSize()
                            }
                            Spacer()
                            Button { withAnimation(.smooth) { fleet.remotePanel = false } } label: { Image(systemName: "xmark") }
                                .buttonStyle(.glass).help("Close").accessibilityLabel("Close")
                        }
                        HStack {
                            TVPicker(allowAll: true)
                            Spacer()
                            Button { send("home") } label: { Image(systemName: "house") }
                                .buttonStyle(.glass).help("Home").accessibilityLabel("Home")
                            Button { typing = true } label: { Image(systemName: "keyboard") }
                                .buttonStyle(.glass).help("Keyboard").accessibilityLabel("Keyboard").disabled(all)
                        }
                    }
                }
                if hasTop { status.frame(height: topH, alignment: .top) }
                Clickpad(size: 200) { send($0) } onRepeat: { send($0, repeat: $1) }
                    // Power in the clickpad's top-right corner, as on the iPhone.
                    .overlay(alignment: .topTrailing) {
                        CornerKey(symbol: "power", label: "Power", size: 34) { send("power") }
                            .help("Power")
                            .offset(x: 22, y: -6)
                    }
                keys(42, 11)
                apps(34)
            }
            .frame(width: 280)
            .frame(width: geo.size.width, height: h, alignment: embedded ? .top : .center)
            .padding(.top, embedded ? 16 : 0)
            #else
            // iPad (a wide window): what's playing on the left, a larger remote on the right. iPhone: the remote alone.
            let wide = padLayout
            let showTop = hasTop && !titleInBar
            let k = wide ? min(76, max(54, h * 0.09)) : key
            let g2 = k * 0.26
            let aH = k * 0.78
            let fixedW = (showTop ? topH : 0) + k * 2 + g2 + aH + rows * 16 + 18
            let colW = wide ? min(540, max(400, geo.size.width * 0.44)) : min(geo.size.width, 460)
            let padW = max(150, min(colW - 40, wide ? 440 : 360, h - fixedW))
            // Home and power sit in the clickpad's top corners, inside the remote's own column.
            let corner = max(8, (colW - 40 - padW) / 2 - 2)
            let remote = VStack(spacing: 0) {
                if showTop { status.frame(height: topH, alignment: .top) }
                Spacer(minLength: 16)
                clickpad(padW, key: k, corner: corner)
                Spacer(minLength: 16)
                keys(k, g2)
                Spacer(minLength: 16).frame(maxHeight: 22)
                apps(aH)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 10)
            .frame(width: colW, height: h)
            // iPhone on its side, or a window too short for the keys under the clickpad: the two side by side.
            if lowLayout || (h < 480 && geo.size.width >= 560) {
                sideBySide(geo.size, showTop: showTop, topH: topH)
            } else if wide {
                HStack(spacing: 0) {
                    RemotePlayingPanel().frame(maxWidth: .infinity, maxHeight: .infinity)
                    remote
                }
                .padding(.trailing, 24)
                .frame(width: geo.size.width, height: h)
            } else {
                remote.frame(width: geo.size.width, height: h)
            }
            #endif
        }
        #if os(iOS) || os(tvOS)
        // Like the Siri Remote: a tick for each arrow, a firmer click for OK, a light tap for the other keys.
        .sensoryFeedback(.selection, trigger: arrowTicks)
        .sensoryFeedback(.impact(weight: .medium, intensity: 0.9), trigger: okTicks)
        .sensoryFeedback(.impact(weight: .light, intensity: 0.6), trigger: presses)
        #endif
        .toolbar {
            if !embedded {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 10) {
                    TVPicker(allowAll: true)
                        // Swipe sideways on the TV's name to move to the next or previous TV.
                        .simultaneousGesture(DragGesture(minimumDistance: 24).onEnded { v in
                            guard abs(v.translation.width) > abs(v.translation.height) else { return }
                            stepTV(v.translation.width < 0 ? 1 : -1)
                        })
                    // iPad: what's playing, beside the TV's name (tap for its controls).
                    if titleInBar, let p = tv?.playing {
                        Button { nowPlaying = true } label: {
                            Text(p.title).font(.headline).lineLimit(1)
                                .padding(.horizontal, 16).padding(.vertical, 9)
                                .glass(Capsule())
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: 380)
                    }
                }
            }
                #if !os(tvOS)
                .sharedBackgroundVisibility(.hidden)
                #endif
            if let tv, !all, fleet.lg(for: tv) != nil {
                ToolbarItem(placement: .primaryAction) { LGMenu(tv: tv) }
            }
            }
        }
        .inlineTitle()
        .sheet(isPresented: $typing) {
            if let tv {
                KeyboardSheet(tv: tv).macResizable(width: 480, height: 400)
                    #if os(iOS)
                    // iPhone and iPad: what the TV says back (text that didn't go through) shows over the keyboard.
                    .sheetBanner()
                    #endif
            }
        }
        .task(id: "\(fleet.selectedID ?? "")-\(all)-\(fleet.isActive)") { await fieldLoop() }
        .sheet(isPresented: $nowPlaying) { NowPlayingSheet().sheetBanner().macResizable(width: 560, height: 780) }
        // Handoff: the Mac offers to open the remote on the same TV.
        .userActivity("com.woodruff.family.remote") { a in
            a.title = "Woodruff Remote"
            a.isEligibleForHandoff = true
            if let id = fleet.selectedID { a.addUserInfoEntries(from: ["tv": id]) }
        }
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
        #elseif os(iOS)
        // iPad with a keyboard: the arrows, Return, Esc and Space drive the remote, as the Mac's keyboard does.
        .focusable(Self.takesKeys)
        .focusEffectDisabled(Self.takesKeys)
        .focused($keysFocused)
        .onAppear { keysFocused = true }
        // Back from the keyboard sheet or Now Playing, the keys are the remote's again.
        .onChange(of: typing || nowPlaying) { _, covered in if !covered { keysFocused = true } }
        .onKeyPress { press in handleKey(press) }
        #endif
    }

    // MARK: Pieces

    private var isOff: Bool { !all && (tv.map { !$0.online || $0.link == "refused" } ?? false) }

    private var topHeight: CGFloat {
        if isOff { return 30 }
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
            HStack(spacing: 6) {
                Text(tv.link == "refused" ? "\(tv.name) needs linking again" : "\(tv.name) is off")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                if fleet.extras[tv.id]?.mac != nil, tv.link != "refused" {
                    Text("·").foregroundStyle(.tertiary)
                    // Wakes it and watches closely, so the remote comes alive the moment the TV answers.
                    Button("Turn On") { fleet.wake(tv) }
                        .font(.subheadline.weight(.semibold))
                }
            }
            .frame(maxWidth: .infinity)
        } else if let tv, let p = tv.playing {
            NowPlayingDropdown(tv: tv, playing: p, expanded: $showPlaying)
        } else if let f = field?.field {
            Button { typing = true } label: {
                Text("Type into \(f.label?.isEmpty == false ? f.label! : "the text box")")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16).padding(.vertical, 10)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .glass(Capsule(), tint: Color.accentColor.opacity(0.18))
            .transition(.scale.combined(with: .opacity))
        }
    }

    #if !os(macOS)
    /// The clickpad, with Home and Power in its top corners ([corner] points out from them).
    private func clickpad(_ size: CGFloat, key: CGFloat, corner: CGFloat) -> some View {
        Clickpad(size: size) { send($0) } onRepeat: { send($0, repeat: $1) }
            .opacity(isOff ? 0.35 : 1)
            .allowsHitTesting(!isOff)
            .overlay(alignment: .topLeading) {
                CornerKey(symbol: "house.fill", label: "Home", size: key * 0.8) { send("home") }
                    .offset(x: -corner, y: -6)
            }
            .overlay(alignment: .topTrailing) {
                CornerKey(symbol: "power", label: "Power", size: key * 0.8) { send("power") }
                    .offset(x: corner, y: -6)
            }
    }

    /// iPhone on its side (or a window too short for one thing above another): the clickpad on the left and the keys
    /// beside it, each as large as the height allows, so nothing runs off the bottom.
    private func sideBySide(_ size: CGSize, showTop: Bool, topH: CGFloat) -> some View {
        let h = size.height
        let top: CGFloat = showTop ? topH + 12 : 0
        // The two rows of keys, the gap between them and the apps under them share the height: 3.04 keys' worth.
        let k: CGFloat = min(62, max(44, (h - 30 - top) / 3.04))
        let side: CGFloat = min(380, size.width * 0.46)
        let pad: CGFloat = max(150, min(size.width - side - 56, 360, h - 32))
        let room: CGFloat = (size.width - side - 40 - pad) / 2 - 2
        let corner: CGFloat = max(8, min(24, room))
        return HStack(spacing: 0) {
            clickpad(pad, key: k, corner: corner)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            VStack(spacing: 0) {
                if showTop { status.frame(height: topH, alignment: .top).padding(.bottom, 12) }
                keys(k, k * 0.26)
                Spacer(minLength: 12).frame(maxHeight: 22)
                apps(k * 0.78)
            }
            .padding(.horizontal, 20)
            .frame(width: side)
            .frame(maxHeight: .infinity)
        }
        .padding(.top, 8)
        .padding(.bottom, 10)
        .frame(width: size.width, height: h)
    }
    #endif

    /// Back and Mute, the keyboard in the middle, the volume rocker. OK on the clickpad plays and pauses.
    private func keys(_ key: CGFloat, _ gap: CGFloat) -> some View {
        HStack(alignment: .center, spacing: 0) {
            VStack(spacing: gap) {
                RoundKey(symbol: "chevron.backward", label: "Back", size: key) { send("back") }
                RoundKey(symbol: "speaker.slash.fill", label: "Mute", size: key) { send("mute") }
            }
            .frame(maxWidth: .infinity)
            // The TV's text box open: it lights up.
            RoundKey(symbol: "keyboard", label: "Keyboard", size: key, tint: field?.field != nil && !all ? Color.accentColor : nil) { typing = true }
                .disabled(all)
                .frame(maxWidth: .infinity)
            VolumeRocker(width: key, height: key * 2 + gap) { up, n in send(up ? "volup" : "voldown", repeat: n) }
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: 340)
        .glassGroup(spacing: gap)
    }

    private func apps(_ height: CGFloat) -> some View {
        HStack(spacing: 12) {
            AppKey(title: "Netflix", height: height, mark: AnyView(
                Text("N").font(.system(size: 21, weight: .black, design: .default))
                    .foregroundStyle(Color(red: 229 / 255, green: 9 / 255, blue: 20 / 255))
            )) { send("netflix") }
            AppKey(title: "YouTube", height: height, mark: AnyView(
                Image(systemName: "play.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 18)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color(red: 1, green: 0, blue: 0)))
            )) { send("youtube") }
        }
        .frame(maxWidth: 340)
    }

    /// Moves the remote to the next (or previous) paired TV.
    private func stepTV(_ by: Int) {
        let list = fleet.tvs.filter { !$0.isUnpaired }
        guard !list.isEmpty else { return }
        let i = list.firstIndex { $0.id == fleet.selectedID } ?? 0
        let next = list[(i + by + list.count) % list.count]
        withAnimation(.snappy) { fleet.remoteAll = false; fleet.selectedID = next.id }
        arrowTicks += 1
    }

    // MARK: Sending

    private func send(_ key: String, repeat n: Int = 0) {
        #if os(macOS)
        if n == 0 { MacFeedback.key() }
        #endif
        switch key {
        case "up", "down", "left", "right": arrowTicks += 1
        case "ok", "menu": okTicks += 1
        default: presses += 1
        }
        let targets = all ? fleet.tvs.filter(\.online) : (tv.map { [$0] } ?? [])
        for t in targets {
            Task {
                do {
                    try await RemoteKeys.press(key, on: t, fleet: fleet, repeat: n)
                    if key == "ok" && !all {
                        try? await Task.sleep(nanoseconds: 400_000_000)
                        if let s = try? await fleet.client(for: t)?.typeField() { withAnimation(.snappy) { field = s } }
                    }
                } catch RemoteKeys.Failure.powerNeedsPairing(let name) {
                    if !all { fleet.alert("Power", RemoteKeys.Failure.powerNeedsPairing(name).localizedDescription) }
                } catch {
                    if !all && n == 0 { fleet.show(error) }
                }
            }
        }
    }

    private func fieldLoop() async {
        field = nil
        // Not while the app isn't in use (the Mac's windows hidden): asked again once it is.
        guard fleet.isActive else { return }
        while !Task.isCancelled {
            if !all, let t = tv, t.online, let c = fleet.client(for: t), let s = try? await c.typeField() {
                // Only a change redraws the remote (it's asked every 2 seconds).
                if s != field { withAnimation(.snappy) { field = s } }
                // A text box just opened on the TV: bring the keyboard up (once per text box).
                let key = s.field.map { "\(t.id)-\($0.id)" }
                if let key, key != lastFieldKey, !typing { typing = true; okTicks += 1 }
                lastFieldKey = key
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    #if os(macOS) || os(iOS)
    /// The Mac's keyboard (and an iPad's) is the remote: arrows, Return = OK, Esc/Delete = Back, Space = Play/Pause,
    /// H, M, + and −.
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
    @State private var touch: CGPoint?
    @State private var swiped = false
    @State private var bumps = 0
    /// A finger is on the pad. Back to false by itself when the system takes the touch away (a sheet, a call), which
    /// never ends the gesture: the hold then stops, and the next touch starts clean.
    @GestureState private var touching = false

    var body: some View {
        ZStack {
            Circle().fill(Palette.padFill)
                .overlay(Circle().strokeBorder(.white.opacity(0.06)))
                .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
            Circle().fill(pressed == "ok" ? Palette.padCenter.opacity(0.7) : Palette.padCenter)
                .frame(width: size * 0.42, height: size * 0.42)
                .overlay(Text("OK").font(.title3.weight(.semibold)).foregroundStyle(.secondary))
                .scaleEffect(pressed == "ok" ? 0.96 : 1)
            // A soft ring where the finger is, like touching the Siri Remote's surface.
            if let touch {
                Circle().fill(.white.opacity(0.07))
                    .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 1))
                    .frame(width: size * 0.22, height: size * 0.22)
                    .position(touch)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
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
        #if os(iOS) || os(tvOS)
        .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.5), trigger: bumps)
        #endif
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .updating($touching) { _, state, _ in state = true }
                .onChanged { v in
                    withAnimation(.interactiveSpring(response: 0.18)) { touch = v.location }
                    if !began {
                        began = true
                        let zone = zoneAt(v.startLocation)
                        pressed = zone
                        startHold(zone)
                    }
                    if max(abs(v.translation.width), abs(v.translation.height)) > 26 {
                        hold?.cancel()
                        if !swiped { swiped = true; bumps += 1 }
                    }
                }
                .onEnded { v in
                    hold?.cancel()
                    withAnimation(.easeOut(duration: 0.25)) { touch = nil }
                    defer { pressed = nil; began = false; held = false; swiped = false }
                    if held { return }
                    let dx = v.translation.width, dy = v.translation.height
                    if max(abs(dx), abs(dy)) >= 26 {
                        let dir = abs(dx) > abs(dy) ? (dx > 0 ? "right" : "left") : (dy > 0 ? "down" : "up")
                        onKey(dir)
                        // Momentum: a fast flick keeps going a few more steps, slowing down, like the Siri Remote.
                        let fling = abs(dx) > abs(dy) ? abs(v.predictedEndTranslation.width - dx) : abs(v.predictedEndTranslation.height - dy)
                        let extra = fling.isFinite ? min(5, Int(fling / 90)) : 0
                        if extra > 0 {
                            Task {
                                for i in 1...extra {
                                    try? await Task.sleep(nanoseconds: UInt64(70_000_000 + i * 35_000_000))
                                    onRepeat(dir, i)
                                }
                            }
                        }
                    } else {
                        onKey(zoneAt(v.startLocation))
                    }
                }
        )
        .onChange(of: touching) { _, now in
            guard !now else { return }
            // After the gesture's own end has had its turn: only a touch taken away is left to tidy up.
            Task { @MainActor in
                guard began else { return }
                hold?.cancel()
                withAnimation(.easeOut(duration: 0.25)) { touch = nil }
                pressed = nil; began = false; held = false; swiped = false
            }
        }
        .onDisappear { hold?.cancel(); pressed = nil; began = false; held = false; swiped = false; touch = nil }
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
            // Never for ever: a touch the system took away doesn't end the gesture.
            while !Task.isCancelled && n < 60 {
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

/// A smaller round glass key for the clickpad's corners (Home, Keyboard).
struct CornerKey: View {
    var symbol: String
    var label: String
    var size: CGFloat = 46
    var tint: Color? = nil
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.38, weight: .semibold))
                .foregroundStyle(tint == nil ? Color.primary : .white)
                .frame(width: size, height: size)
                .contentShape(Circle())
                .glass(Circle(), tint: tint)
                #if os(iOS)
                // iPad's pointer lights up the circle, not the square around it.
                .contentShape(.hoverEffect, Circle())
                #endif
        }
        .buttonStyle(PressScale())
        .accessibilityLabel(label)
    }
}

/// A round glass key.
struct RoundKey: View {
    var symbol: String
    var label: String
    var size: CGFloat = 64
    var tint: Color? = nil
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.33, weight: .semibold))
                .foregroundStyle(tint == nil ? Color.primary : .white)
                .frame(width: size, height: size)
                .contentShape(Circle())
                .glass(Circle(), tint: tint)
                #if os(iOS)
                .contentShape(.hoverEffect, Circle())
                #endif
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
    /// Back to false by itself when the system takes the touch away (which never ends the gesture).
    @GestureState private var touching = false

    #if os(tvOS)
    /// Apple TV: a button the remote can land on and click, one press a click. (The touch below never happens there, so
    /// Now Playing's volume and mute could be neither reached nor pressed.)
    var body: some View {
        Button { onPress(0) } label: { label }
            .buttonStyle(PressScale())
    }
    #else
    var body: some View {
        label
            .contentShape(Rectangle())
            .opacity(down ? 0.55 : 1)
            .scaleEffect(down ? 0.9 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: down)
            .gesture(DragGesture(minimumDistance: 0)
                .updating($touching) { _, state, _ in state = true }
                .onChanged { _ in
                    guard !down else { return }
                    down = true
                    onPress(0)
                    task?.cancel()
                    task = Task {
                        try? await Task.sleep(nanoseconds: 450_000_000)
                        // At most about 8 seconds: a touch the system took away (a sheet, a call) never ends the
                        // gesture, and the volume mustn't keep climbing.
                        var n = 1
                        while !Task.isCancelled && n <= 60 { onPress(n); n += 1; try? await Task.sleep(nanoseconds: 140_000_000) }
                    }
                }
                .onEnded { _ in down = false; task?.cancel() })
            // A touch taken away: the repeating stops at once (not 8 seconds of volume later), and the next press works.
            .onChange(of: touching) { _, now in
                guard !now else { return }
                Task { @MainActor in
                    guard down else { return }
                    down = false
                    task?.cancel()
                }
            }
            .onDisappear { down = false; task?.cancel() }
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onPress(0) }
    }
    #endif
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
            // Glass behind, not around, so the brand colours stay true (glass tints what it contains).
            .background { Color.clear.glass(Capsule()) }
            #if os(iOS)
            .contentShape(.hoverEffect, Capsule())
            #endif
        }
        .buttonStyle(PressScale(scale: 0.96))
    }
}

/// One key on one TV, the best way it allows (the remote, the Mac's menus and keyboard, Settings' All TVs): LG direct
/// control when it's connected, then the Android TV remote when it's paired (both reach every app), otherwise
/// Woodruff on the TV. Power turns an LG or Android TV off through its own connection, and turns a TV that's off on
/// with Wake-on-LAN when its network address is known.
@MainActor
enum RemoteKeys {
    enum Failure: LocalizedError {
        case powerNeedsPairing(String), unreachable(String)
        var errorDescription: String? {
            switch self {
            case .powerNeedsPairing(let name): return "Turning \(name) on and off needs its remote paired: Settings, TVs, \(name), Remote for Every App."
            case .unreachable(let name): return "\(name) can’t be reached from here."
            }
        }
    }

    /// Keys that don't change what's on, so the TV isn't asked again after them.
    private static let quiet: Set<String> = ["volup", "voldown", "mute"]

    /// Presses [key] on [tv]. [android] false keeps the key on Woodruff (Woodruff Home, not the TV's own home screen).
    static func press(_ key: String, on tv: FleetTV, fleet: Fleet, repeat n: Int = 0, android: Bool = true) async throws {
        let canWake = !tv.online && fleet.extras[tv.id]?.mac != nil
        let atvHost = android && AndroidTVRemote.handles(key) ? fleet.androidRemoteHost(for: tv) : nil
        // Off, with no remote connection that can turn it on: Wake-on-LAN.
        if key == "power", canWake, atvHost == nil { fleet.wake(tv); return }
        if let lg = fleet.lg(for: tv), let action = LGKeyMap.action(for: key) {
            try await action(lg)
            // LG direct control doesn't pass through Woodruff, so ask the TV again here (keys sent through Woodruff
            // do this by themselves).
            if !quiet.contains(key) { fleet.poke(tv.id) }
            return
        }
        if let atvHost {
            // The Android TV remote reaches every app; when it can't, Woodruff on the TV still takes the key.
            do {
                try await AndroidTVRemote.shared.press(host: atvHost, key: key)
                if !quiet.contains(key) { fleet.poke(tv.id) }
                return
            } catch {
                if key == "power" {
                    if canWake { fleet.wake(tv); return }
                    throw error
                }
            }
        }
        // Not paired yet: only its remote (or an LG's own connection) can turn a TV off.
        if key == "power" { throw Failure.powerNeedsPairing(tv.name) }
        guard let c = fleet.client(for: tv) else { throw Failure.unreachable(tv.name) }
        try await c.key(key, repeat: n)
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
        case "power": return { try await $0.turnOff() }
        case "netflix": return { try await $0.launch("netflix") }
        case "youtube": return { try await $0.launch("youtube.leanback.v4") }
        case "home": return { try await $0.launch("com.woodruff.family") }
        default: b = nil
        }
        guard let b else { return nil }
        return { try await $0.press(b) }
    }
}

/// LG TVs connected directly: apps, inputs, channels and power, in the remote's toolbar (on the Mac, at the top of
/// the remote's panel).
struct LGMenu: View {
    @Environment(Fleet.self) private var fleet
    var tv: FleetTV
    @State private var apps: [LGRemote.App] = []
    @State private var inputs: [LGRemote.App] = []

    var body: some View {
        Menu {
            Section {
                Button("Channel Up") { run { try await $0.press(.channelUp) } }
                Button("Channel Down") { run { try await $0.press(.channelDown) } }
            }
            // Empty until the TV has said what it has (or when it couldn't be asked).
            Menu("Apps") { ForEach(apps) { a in Button(a.title) { run { try await $0.launch(a.id) } } } }
                .disabled(apps.isEmpty)
            Menu("Inputs") { ForEach(inputs) { i in Button(i.title) { run { try await $0.switchInput(i.id) } } } }
                .disabled(inputs.isEmpty)
            Section {
                Button("Turn Screen Off") { run { try await $0.screenOff() } }
                Button("Turn Off \(tv.name)", role: .destructive) { run { try await $0.turnOff() } }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .accessibilityLabel("\(tv.name) Options")
        .help("\(tv.name) Options")
        // Asked again for another TV (the remote's TV changed while the menu stayed).
        .task(id: tv.id) {
            apps = []
            inputs = []
            guard let lg = fleet.lg(for: tv) else { return }
            apps = (try? await lg.apps()) ?? []
            inputs = (try? await lg.inputs()) ?? []
        }
    }

    private func run(_ op: @escaping (LGRemote) async throws -> Void) {
        Task {
            do {
                guard let lg = fleet.lg(for: tv) else { return }
                try await op(lg)
                // Apps, inputs and power change what's on: show it right away.
                fleet.poke(tv.id)
            } catch { fleet.show(error) }
        }
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
    @State private var sending = false
    @State private var finished = false
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
                        Button(sending ? "Typing…" : "Type into \(tv.name)’s Own Keyboard") {
                            let t = text
                            own { try await lg.insertText(t); try await lg.sendEnter() }
                        }
                        .disabled(text.isEmpty || sending)
                    } footer: { Text("For other apps on this LG TV (Netflix, YouTube, the browser).") }
                } else if let host = fleet.androidRemoteHost(for: tv) {
                    Section {
                        Button(sending ? "Typing…" : "Type into \(tv.name)’s Own Keyboard") {
                            let t = text
                            own { try await AndroidTVRemote.shared.type(host: host, text: t) }
                        }
                        .disabled(text.isEmpty || sending)
                    } footer: { Text("For other apps on this TV, while their keyboard is on screen.") }
                }
            }
            .familyFormStyle()
            .navigationTitle("Keyboard")
            #if os(iOS)
            .navigationSubtitle(tv.name)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(role: .close) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Enter") { submit() }.buttonStyle(.glassProminent).disabled(state?.field == nil || sending)
                }
            }
            .task(id: fleet.isActive) { await loop() }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium, .large])
        #if os(macOS)
        .frame(minWidth: 440, idealWidth: 440, maxWidth: .infinity, minHeight: 360, idealHeight: 360, maxHeight: .infinity)
        #endif
    }

    private var fieldTitle: String {
        guard let f = state?.field else { return state?.note ?? "Select a text box on \(tv.name)" }
        let l = f.label?.isEmpty == false ? f.label! : "Text box"
        return f.secret == true ? "\(l) (hidden)" : l
    }

    private func loop() async {
        // Not while the app isn't in use (the Mac's windows hidden).
        guard fleet.isActive else { return }
        while !Task.isCancelled {
            if let s = try? await fleet.client(for: tv)?.typeField() {
                if s != state { state = s }
                let key = s.field.map { "\($0.id)" }
                if key != fieldKey { fieldKey = key; text = s.field?.text ?? "" }
            }
            try? await Task.sleep(nanoseconds: 1_200_000_000)
        }
    }

    private func clean(_ s: String) -> String { state?.field?.multiline == true ? s : s.replacingOccurrences(of: "\n", with: " ") }

    private func queue(_ new: String) {
        // Sent and closing: the text emptied here mustn't empty the TV's box too.
        guard !finished else { return }
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
        // Return and the Enter button both land here: once is enough.
        guard let f = state?.field, !sending else { return }
        let t = clean(text)
        pending?.cancel()
        sending = true
        Task {
            do {
                guard let c = fleet.client(for: tv) else { throw RemoteKeys.Failure.unreachable(tv.name) }
                try await c.type(t, field: f.id, submit: true)
                finished = true
                text = ""
                dismiss()
            } catch { fleet.show(error) }
            sending = false
        }
    }

    /// Text typed into the TV's own keyboard (another app's), then the sheet closes.
    private func own(_ op: @escaping () async throws -> Void) {
        guard !sending else { return }
        pending?.cancel()
        sending = true
        Task {
            do {
                try await op()
                dismiss()
            } catch { fleet.show(error) }
            sending = false
        }
    }
}

#if os(iOS) || os(tvOS)
/// iPad, beside the remote: what's playing on the remote's TV, its picture large, the time, and what it's about (as
/// the Watch banner shows it).
private struct RemotePlayingPanel: View {
    @Environment(Fleet.self) private var fleet
    /// What each title is about, read once each.
    @State private var stories: [String: String] = [:]

    var body: some View {
        let tv = fleet.selected
        let p = tv?.nowPlaying
        let titleID = fleet.artwork(for: p)?.titleID
        GeometryReader { g in
            let w = max(240, min(g.size.width - 64, 680))
            VStack(alignment: .leading, spacing: 18) {
                NowPlayingArt(playing: p, maxPixel: 1800)
                    .frame(width: w, height: w * 9 / 16)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.08)))
                    .shadow(color: .black.opacity(0.45), radius: 26, y: 14)
                VStack(alignment: .leading, spacing: 4) {
                    Text(p?.title ?? "Nothing Playing").font(.title2.bold()).lineLimit(2)
                    Text(tv.map { t in t.name + (p?.app.map { " · \($0)" } ?? "") } ?? "")
                        .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                if let p { LiveProgress(playing: p).frame(width: w) }
                if let id = titleID, let story = stories[id], !story.isEmpty {
                    Text(story).font(.body).foregroundStyle(.secondary)
                        .lineLimit(9)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: w, alignment: .leading)
                        .transition(.opacity)
                }
            }
            .frame(width: w)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: titleID) { await loadStory(titleID) }
    }

    private func loadStory(_ id: String?) async {
        guard let id, stories[id] == nil, let c = WatchSources.current(fleet) else { return }
        if let kept = TitleCache.shared.details(hub: c.sourceID, id: id)?.overview {
            stories[id] = kept
            return
        }
        guard let d = try? await c.title(id) else { return }
        TitleCache.shared.keep(d, hub: c.sourceID, id: id)
        withAnimation(.easeOut(duration: 0.3)) { stories[id] = d.overview ?? "" }
    }
}
#endif
