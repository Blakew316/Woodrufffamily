import SwiftUI
#if os(macOS)
import AppKit
#endif
import WoodruffKit

#if os(macOS)
typealias PlatformImage = NSImage
extension Image { init(platformImage: NSImage) { self.init(nsImage: platformImage) } }
#else
typealias PlatformImage = UIImage
extension Image { init(platformImage: UIImage) { self.init(uiImage: platformImage) } }
#endif

// MARK: - Palette (the phone page's: iOS system colours, Woodruff's blue tint)

enum Palette {
    #if os(tvOS)
    /// Apple TV is always dark, except the row or button the remote is on: tvOS lights that one up and draws what's on
    /// it for a light background. There a warning takes the system's own text colour, like the words beside it (the
    /// phone's dark amber for white pages was brown on the lit row, and hard to read).
    static let attention = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(red: 1, green: 0.71, blue: 0.28, alpha: 1) : UIColor.label.resolvedColor(with: traits)
    })
    #else
    static let attention = Color(light: Color(red: 0.54, green: 0.31, blue: 0), dark: Color(red: 1, green: 0.71, blue: 0.28))
    #endif
    /// What a row says beside its name, on the row a list has lit as the one picked (iPad Settings' left column):
    /// light, to read on the highlight.
    static let onPicked = Color.white.opacity(0.85)
    static let cardFill = Color(light: .white, dark: Color(red: 0.11, green: 0.11, blue: 0.12))
    static let groupedBackground = Color(light: Color(red: 0.95, green: 0.95, blue: 0.97), dark: .black)
    static let keyFill = Color(light: .white, dark: Color(red: 0.17, green: 0.17, blue: 0.18))
    static let padFill = Color(light: Color(red: 0.90, green: 0.90, blue: 0.92), dark: Color(red: 0.15, green: 0.15, blue: 0.16))
    static let padCenter = Color(light: Color(red: 0.84, green: 0.84, blue: 0.87), dark: Color(red: 0.22, green: 0.22, blue: 0.23))
}

extension Color {
    init(light: Color, dark: Color) {
        #if os(macOS)
        self.init(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .vibrantDark]) != nil ? NSColor(dark) : NSColor(light) })
        #else
        self.init(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light) })
        #endif
    }
}

// MARK: - A page kept behind another

private struct PageHiddenKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// The Mac keeps Home and Settings as they were left while another page of the window shows: this page is one of
    /// them, hidden just now. What it does to the window (its title, the toolbar) and what it keeps going (its
    /// cameras, anything that moves by itself) rests until it shows again.
    var pageHidden: Bool {
        get { self[PageHiddenKey.self] }
        set { self[PageHiddenKey.self] = newValue }
    }
}

private struct HomeRoomsInBarKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// The Mac window's toolbar has Home's rooms (one pill with a menu: `MacHomeRoomMenu`), so Home leaves out its
    /// own row of room tabs.
    var homeRoomsInBar: Bool {
        get { self[HomeRoomsInBarKey.self] }
        set { self[HomeRoomsInBarKey.self] = newValue }
    }
}

// MARK: - Liquid Glass

extension View {
    /// Liquid Glass in [shape] (iOS 26 / macOS 26), a material on older Macs.
    @ViewBuilder func glass<S: Shape>(_ shape: S, tint: Color? = nil, interactive: Bool = true) -> some View {
        if #available(iOS 26, macOS 26, *) {
            self.modifier(GlassIn(shape: shape, tint: tint, interactive: interactive))
        } else {
            self.background { if let tint { shape.fill(tint.gradient) } else { shape.fill(.regularMaterial) } }
        }
    }

    /// Groups nearby glass so it blends and morphs together.
    @ViewBuilder func glassGroup(spacing: CGFloat = 16) -> some View {
        if #available(iOS 26, macOS 26, *) { GlassEffectContainer(spacing: spacing) { self } } else { self }
    }
}

/// Liquid Glass in a shape. On one of Home's tiles while Home is being arranged it's a plain material instead: a
/// board's glass is drawn together, as one layer behind all its tiles (`HomeBoard`), and a tile dragged across another
/// wouldn't cover it (the one underneath would show through). The same view either way, so nothing is built again when
/// arranging starts or ends.
@available(iOS 26, macOS 26, tvOS 26, *)
private struct GlassIn<S: Shape>: ViewModifier {
    var shape: S
    var tint: Color?
    var interactive: Bool
    @Environment(\.homeArranging) private var arranging

    func body(content: Content) -> some View {
        let glass = tint.map { Glass.regular.tint($0).interactive(interactive) } ?? Glass.regular.interactive(interactive)
        content
            .background { if arranging { shape.fill(.regularMaterial) } }
            .glassEffect(arranging ? .identity : glass, in: shape)
    }
}

// MARK: - Settings-style rows

/// A row: icon tile, title (and subtitle), and a trailing value.
struct IconRow: View {
    var symbol: String
    var color: Color
    var title: String
    var subtitle: String? = nil
    var value: String? = nil
    var valueColor: Color = .secondary

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).foregroundStyle(.primary)
                if let subtitle { Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 8)
            if let value { Text(value).foregroundStyle(valueColor).lineLimit(1) }
        }
        .padding(.vertical, subtitle == nil ? 2 : 0)
    }
}

// MARK: - Buttons

/// A round glass button (the phone page's toolbar circles).
struct GlassCircle: View {
    var symbol: String
    var tint: Color? = nil
    var size: CGFloat = 44
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
                // One smaller than a fingertip still takes a touch 44 points across (it looks and sits as it did).
                .contentShape(Circle().inset(by: min(0, (size - 44) / 2)))
                // iPad's pointer lights up the circle, not the square around it.
                .contentShape(.hoverEffect, Circle())
                #endif
        }
        .buttonStyle(PressScale())
        #if os(tvOS)
        // Apple TV: round is the shape tvOS lifts while the remote is on it (PressScale).
        .buttonBorderShape(.circle)
        #endif
    }
}

/// Shrinks a little under the finger, springs back. On iPad it also lights up under the pointer.
struct PressScale: ButtonStyle {
    var scale: CGFloat = 0.92
    func makeBody(configuration: Configuration) -> some View {
        #if os(tvOS)
        PressScaleFocused(configuration: configuration, scale: scale)
        #else
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .brightness(configuration.isPressed ? -0.04 : 0)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
            #if os(iOS)
            .hoverEffect(.highlight)
            #endif
        #endif
    }
}

/// iPad: what a small pill on Home opens (the weather, the thermostat's controls) comes out of the pill as a popover,
/// as on the Mac, and as a sheet again when the window is narrow. iPhone keeps its sheets.
@MainActor
enum PillPanels {
    #if os(iOS)
    static let popOver = UIDevice.current.userInterfaceIdiom == .pad
    #else
    static let popOver = false
    #endif
}

#if os(tvOS)
/// Apple TV: the one the remote is on gets tvOS's own lift (it grows toward you over a soft shadow, as the system's
/// buttons do), not a scale, a light and a shadow drawn by hand. A click still dips it.
private struct PressScaleFocused: View {
    let configuration: ButtonStyleConfiguration
    let scale: CGFloat
    @Environment(\.isFocused) private var focused

    var body: some View {
        configuration.label
            .hoverEffect(.lift)
            .scaleEffect(configuration.isPressed ? scale : 1)
            // Lifted, it stays over its neighbours.
            .zIndex(focused ? 1 : 0)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}
#endif

/// A white capsule "Play" button, or a glass capsule for secondary actions.
struct CapsuleButton: View {
    var title: String
    var symbol: String?
    var prominent = true
    /// iPhone and iPad: how far past its edge a touch still counts, for one drawn smaller than a fingertip.
    var reach: CGFloat = 0
    var action: () -> Void
    var body: some View {
        #if os(tvOS)
        // Apple TV: tvOS's own glass buttons, in its own shape and size. They light up and lift by themselves while the
        // remote is on them, and choose words that read on them. Play is the prominent one: it stands out before the
        // remote reaches it, without looking picked.
        if prominent {
            Button(action: action) { tvLabel }.buttonStyle(.glassProminent)
        } else {
            Button(action: action) { tvLabel }.buttonStyle(.glass)
        }
        #else
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol { Image(systemName: symbol).font(.subheadline.weight(.bold)) }
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
            }
            .fixedSize()
            .padding(.horizontal, 18).padding(.vertical, 10)
            .foregroundStyle(prominent ? Color.black : .white)
            .background { if prominent { Capsule().fill(.white) } }
            .modifier(SecondaryGlass(on: !prominent))
            #if os(iOS)
            // The whole capsule takes the touch, and a little past it when asked (nothing moves or changes size).
            .contentShape(Capsule().inset(by: -reach))
            // iPad's pointer lights up the capsule itself.
            .contentShape(.hoverEffect, Capsule())
            #endif
        }
        .buttonStyle(PressScale(scale: 0.95))
        #endif
    }

    #if os(tvOS)
    /// The words (and symbol) alone, on one line: the button's type, spacing and colours are tvOS's.
    private var tvLabel: some View {
        Group {
            if let symbol { Label(title, systemImage: symbol) } else { Text(title) }
        }
        .lineLimit(1)
        .fixedSize()
    }
    #endif
}

struct SecondaryGlass: ViewModifier {
    var on: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if on { content.glass(Capsule()).environment(\.colorScheme, .dark) } else { content }
    }
}

/// Runs an action against a TV, showing its error (the TV's own words) if it fails. On Apple TV it isn't switched off
/// while it works: a button the remote is on that's switched off loses the focus, which jumped somewhere else on the
/// page. A second press meanwhile does nothing.
struct ActionButton<Label: View>: View {
    @Environment(Fleet.self) private var fleet
    var role: ButtonRole? = nil
    var action: () async throws -> Void
    @ViewBuilder var label: Label
    @State private var busy = false

    var body: some View {
        Button(role: role) {
            guard !busy else { return }
            busy = true
            Task {
                do { try await action() } catch { fleet.show(error) }
                busy = false
            }
        } label: {
            HStack {
                label
                if busy { Spacer(); ProgressView().controlSize(.small) }
            }
        }
        #if !os(tvOS)
        .disabled(busy)
        #endif
    }
}

// MARK: - TV picker (top of Remote and Watch)

/// "● Living Room ⌄": picks the TV the remote, Watch and Send act on, or every TV at once.
struct TVPicker: View {
    @Environment(Fleet.self) private var fleet
    var allowAll = false
    /// In the Mac window's toolbar: the same type and the same room round its name as the pills beside it there
    /// (Home | Watch | Settings, Movies | TV Shows), so it's exactly as tall as they are.
    var bar = false
    /// Between two buttons in a bar with little room (Now Playing on iPhone): the name shortens to fit instead of
    /// keeping its full width and sliding under them.
    var squeezes = false

    #if os(iOS)
    /// The menu's choice for every TV at once (no TV has this id).
    private static let everyTV = "*"

    /// What the menu has picked: All TVs, or the TV the remote is on.
    private var picked: Binding<String> {
        Binding(get: { allowAll && fleet.remoteAll ? Self.everyTV : (fleet.selected?.id ?? "") },
                set: { id in
                    if id == Self.everyTV { fleet.remoteAll = true } else { fleet.remoteAll = false; fleet.selectedID = id }
                })
    }
    #endif

    var body: some View {
        Menu {
            #if os(iOS)
            // A picker, so the system draws the checkmark (and VoiceOver says which is picked). All TVs is a plain row
            // like the rest: no icon of its own.
            Picker("TV", selection: picked) {
                if allowAll {
                    Text("All TVs").tag(Self.everyTV)
                    Divider()
                }
                ForEach(fleet.tvs.filter { !$0.isUnpaired }) { t in
                    // Its name over what it's doing.
                    VStack(alignment: .leading) {
                        Text(t.name)
                        Text(statusWord(t))
                    }
                    .tag(t.id)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            #else
            if allowAll {
                Button { fleet.remoteAll = true } label: {
                    Label("All TVs", systemImage: fleet.remoteAll ? "checkmark" : "tv.and.mediabox")
                }
                Divider()
            }
            ForEach(fleet.tvs.filter { !$0.isUnpaired }) { t in
                Button { fleet.remoteAll = false; fleet.selectedID = t.id } label: {
                    if t.id == fleet.selectedID && !(allowAll && fleet.remoteAll) { Label(t.name, systemImage: "checkmark") }
                    else { Text(t.name) }
                    Text(statusWord(t))
                }
            }
            #endif
        } label: {
            HStack(spacing: bar ? 8 : 6) {
                Circle().fill(dotColor).frame(width: bar ? 8 : 7, height: bar ? 8 : 7)
                Text(allowAll && fleet.remoteAll ? "All TVs" : (fleet.selected?.name ?? "TV"))
                    .font(bar ? .title3.weight(.semibold) : .headline)
                    .lineLimit(1)
                    .minimumScaleFactor(squeezes ? 0.8 : 1)
                Image(systemName: "chevron.down").font(.caption.weight(.bold)).foregroundStyle(.secondary)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, bar ? 18 : 14).padding(.vertical, bar ? 10 : 9)
            .modifier(BarPillType(on: bar))
            .contentShape(Capsule())
            .glass(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize(horizontal: !squeezes, vertical: true)
        // Between Close and More on the narrowest iPhone there are about 239 points: never wider than that, whatever
        // the bar offers, so a long name at a large text size shrinks, then shortens, and never reaches the buttons.
        .frame(maxWidth: squeezes ? 230 : nil)
    }

    private var dotColor: Color {
        if allowAll && fleet.remoteAll { return fleet.tvs.contains(where: \.online) ? .green : .gray }
        guard let t = fleet.selected else { return .gray }
        return t.online ? (t.link == "refused" ? .orange : .green) : .gray
    }
}

/// The size of type of the Mac toolbar's pills (as Home's tabs: a size up), for the TV picker when it's one of them.
/// Elsewhere the picker's type is left alone, to follow the device's own text size.
private struct BarPillType: ViewModifier {
    var on: Bool
    func body(content: Content) -> some View {
        if on { content.dynamicTypeSize(.xxLarge) } else { content }
    }
}

func statusWord(_ t: FleetTV) -> String {
    if t.link == "refused" { return "Link again" }
    if !t.online { return "Off" }
    // A title left paused reads as nothing playing, as it does on its tile.
    if let p = t.nowPlaying { return (p.isPlaying ? "Playing " : "Paused · ") + p.title }
    return "Nothing playing"
}

// MARK: - Pictures

/// A picture from a TV (posters, thumbnails, photos): at once when it's been seen before (kept by ImageStore),
/// otherwise fading in as it arrives. [maxPixel] is the most it needs on its longer side (a poster tile 512, a
/// backdrop 1800), [storeOnDisk] false for a picture looked at once (a big photo in the TV's files).
struct Artwork: View {
    var url: URL?
    var contentMode: ContentMode = .fill
    var maxPixel: Int = 1800
    var storeOnDisk: Bool = true
    var body: some View {
        CachedImage(url: url, contentMode: contentMode, maxPixel: maxPixel, storeOnDisk: storeOnDisk) {
            Rectangle().fill(.quinary)
        } failure: {
            Rectangle().fill(.quaternary)
        }
    }
}

typealias TVImage = Artwork

// MARK: - Loading placeholders

/// A soft light that sweeps across placeholder shapes while content loads (calm under Reduce Motion).
struct Shimmer: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var phase: CGFloat = -1
    func body(content: Content) -> some View {
        content
            .overlay {
                if !reduce {
                    GeometryReader { g in
                        LinearGradient(colors: [.clear, .white.opacity(0.12), .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: g.size.width * 0.6)
                            .offset(x: phase * g.size.width * 1.6)
                    }
                    .mask(content)
                }
            }
            .onAppear { withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) { phase = 1 } }
    }
}

extension View {
    func shimmer() -> some View { modifier(Shimmer()) }
}

/// A rounded placeholder block.
struct Placeholder: View {
    var corner: CGFloat = 12
    var body: some View { RoundedRectangle(cornerRadius: corner, style: .continuous).fill(.quaternary) }
}

// MARK: - Ambient motion

/// Whether ambient motion rests where it's read (`@AmbientResting private var resting: Bool` in the view that moves):
/// Home's drifting backdrop, a fan's blades, a washer's drum, sound rising from a speaker. It rests while the app isn't
/// in use (its windows hidden, minimised or covered; an iPhone or Apple TV in the background), as it always did, and
/// on the Mac also while the window it's in isn't the one in use: another app in front, or a film playing in a window
/// of its own. (A sheet or popover is a window of its own, so what moves inside it follows that one.)
@propertyWrapper
struct AmbientResting: DynamicProperty {
    #if os(macOS)
    @Environment(\.appearsActive) private var appearsActive
    /// On a page the Mac keeps behind the one showing: it rests there too.
    @Environment(\.pageHidden) private var pageHidden
    #endif

    @MainActor var wrappedValue: Bool {
        #if os(macOS)
        return !Fleet.shared.isActive || !appearsActive || pageHidden
        #else
        return !Fleet.shared.isActive
        #endif
    }
}

// MARK: - Zoom transitions

private struct ZoomNamespaceKey: EnvironmentKey { static let defaultValue: Namespace.ID? = nil }
extension EnvironmentValues {
    /// Where tiles register as the source of the zoom into what they open (iOS).
    var zoomNamespace: Namespace.ID? {
        get { self[ZoomNamespaceKey.self] }
        set { self[ZoomNamespaceKey.self] = newValue }
    }
}

extension View {
    /// Marks this tile as where a zoom transition starts (iOS 18+), when a namespace is set.
    @ViewBuilder func zoomSource(_ id: String, _ ns: Namespace.ID?) -> some View {
        #if os(iOS) || os(tvOS)
        if let ns { self.matchedTransitionSource(id: id, in: ns) } else { self }
        #else
        self
        #endif
    }

    /// Opens with a zoom out of the tile marked [id].
    @ViewBuilder func zoomDestination(_ id: String, _ ns: Namespace.ID?) -> some View {
        #if os(iOS) || os(tvOS)
        if let ns { self.navigationTransition(.zoom(sourceID: id, in: ns)) } else { self }
        #else
        self
        #endif
    }
}

// MARK: - Formatting

/// "5 min. ago": one formatter for every row that says when (making one costs more than using it).
private let shortRelative: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .short
    return f
}()

func relative(_ ms: Double?) -> String {
    guard let ms, ms > 0 else { return "never" }
    let d = Date(timeIntervalSince1970: ms / 1000)
    if abs(d.timeIntervalSinceNow) < 45 { return "just now" }
    return shortRelative.localizedString(for: d, relativeTo: Date())
}

func formatBytes(_ n: Double?) -> String {
    guard let n else { return "" }
    return ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
}

func formatTime(ms: Double?) -> String {
    guard let ms, ms >= 0 else { return "--:--" }
    let s = Int(ms / 1000)
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}

/// "1h 08m left".
func timeLeft(position: Double?, duration: Double?) -> String? {
    guard let d = duration, d > 0 else { return nil }
    let left = Int(max(0, d - (position ?? 0)) / 60000)
    return left >= 60 ? String(format: "%dh %02dm left", left / 60, left % 60) : "\(left)m left"
}

/// Help written on the TVs (a problem's details, the doorbell's status, a TV's messages), pointing at the phone app's
/// Settings as it is now: TVs not yet updated still name pages it used to have (Connections, its Cameras, and the
/// last crash at the top of Settings).
func currentSettingsPaths(_ text: String) -> String {
    guard text.contains("Settings → ") else { return text }
    return text
        .replacingOccurrences(of: "Settings → Connections → Cameras", with: "Settings → Accounts → Nest Cameras")
        .replacingOccurrences(of: "Settings → Connections →", with: "Settings → Accounts →")
        .replacingOccurrences(of: "Settings → Last Crash on This TV", with: "Settings → General → Last Crash on This TV")
}

/// The word for opening something, for a line that says how: "Click" on a Mac, "Select" on Apple TV (the remote
/// selects), "Tap" on iPhone and iPad.
#if os(macOS)
let tapWord = "Click"
#elseif os(tvOS)
let tapWord = "Select"
#else
let tapWord = "Tap"
#endif

/// Where the accounts for lights, fans and appliances are, for a line that sends someone there. The Mac's Settings has
/// Devices in its own list; iPhone and iPad have it inside Smart Home; an Apple TV can't sign in to them itself.
#if os(macOS)
let devicesSettingsPath = "Settings → Devices"
#elseif os(tvOS)
let devicesSettingsPath = "Settings → Smart Home → Devices on an iPhone"
#else
let devicesSettingsPath = "Settings → Smart Home → Devices"
#endif

struct EmptyState: View {
    var symbol: String
    var title: String
    var message: String
    var body: some View { ContentUnavailableView(title, systemImage: symbol, description: Text(message)) }
}

extension View {
    func screenTitle(_ t: String) -> some View {
        #if os(iOS)
        return self.navigationTitle(t).navigationBarTitleDisplayMode(.large)
        #else
        return self.navigationTitle(t)
        #endif
    }

    func inlineTitle() -> some View {
        #if os(iOS)
        return self.navigationBarTitleDisplayMode(.inline)
        #else
        return self
        #endif
    }
}

func copyToClipboard(_ s: String) {
    #if os(macOS)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
    #else
    UIPasteboard.general.string = s
    #endif
}

struct ShareItem: Identifiable { var url: URL; var id: URL { url } }

#if os(iOS)
struct ShareSheet: UIViewControllerRepresentable {
    var items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ c: UIActivityViewController, context: Context) {}
}
#elseif os(tvOS)
struct ShareSheet: View {
    var items: [Any]
    var body: some View { Text("Sharing isn’t available on Apple TV.").padding(60) }
}
#endif

// MARK: - Forms

#if os(tvOS)
/// Words with nothing to press under them, at the end of a page: the remote can land on them. Apple TV scrolls a page
/// only to what the remote can be on, so words below the last button could never be brought into view.
private struct TVReachable: ViewModifier {
    @FocusState private var focused: Bool
    func body(content: Content) -> some View {
        content.focusable().focused($focused).opacity(focused ? 1 : 0.8)
    }
}
#endif

extension View {
    /// Read-only words the Apple TV's remote can scroll to (`TVReachable`); as they are everywhere else.
    @ViewBuilder func tvReachable() -> some View {
        #if os(tvOS)
        modifier(TVReachable())
        #else
        self
        #endif
    }

    /// Settings pages: grouped on iPhone and Mac; on Apple TV plain rows as its own Settings app has them (no frosted
    /// platters behind each row).
    @ViewBuilder func familyFormStyle() -> some View {
        #if os(tvOS)
        self.formStyle(.automatic).listStyle(.plain)
        #else
        self.formStyle(.grouped)
        #endif
    }
}

// MARK: - Search that's safe on the Mac

extension View {
    /// A search field: the system one on iPhone; on the Mac one inside the page, because the window already has
    /// a search field in its toolbar and a second one crashes AppKit.
    @ViewBuilder func pageSearch(text: Binding<String>, prompt: String) -> some View {
        pageSearch(text: text, prompt: prompt) { EmptyView() }
    }

    /// The same, with a page's own buttons beside the field on the Mac (they were in the window's toolbar; on iPhone
    /// they stay in the toolbar, so [trailing] isn't shown there).
    @ViewBuilder func pageSearch<Trailing: View>(text: Binding<String>, prompt: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        #if os(tvOS)
        self.searchable(text: text, prompt: prompt)
        #elseif os(iOS)
        // Under the page's title, not at the bottom (iOS 26's default), where the app's tab bar covers it.
        self.searchable(text: text, placement: .navigationBarDrawer, prompt: prompt)
        #else
        self.safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(prompt, text: text).textFieldStyle(.plain)
                    if !text.wrappedValue.isEmpty {
                        Button { text.wrappedValue = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .glass(Capsule(), interactive: false)
                .frame(maxWidth: 420)
                Spacer(minLength: 0)
                trailing()
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
        }
        #endif
    }
}

extension View {
    /// Mac: a sheet opens at a comfortable fixed size, no taller than the screen has room for (`macSheetHeight`).
    /// Nothing on iPhone.
    @ViewBuilder func macResizable(width: CGFloat = 680, height: CGFloat = 760, minWidth: CGFloat = 360, minHeight: CGFloat = 320, aspect: CGFloat? = nil) -> some View {
        #if os(macOS)
        self.frame(width: width, height: macSheetHeight(aspect.map { width / $0 } ?? height, atLeast: minHeight))
        #else
        self
        #endif
    }
}

#if os(macOS)
/// How tall a sheet can be on this Mac: as tall as [wanted], or as tall as the screen has room for when that's less
/// (the sheets were made on a big screen; a 13-inch MacBook's is shorter than some of them, and their last rows and
/// buttons were off the bottom of it). The room is the screen the window is on, without the menu bar and the Dock,
/// less a little air above and below; never under [atLeast].
func macSheetHeight(_ wanted: CGFloat, atLeast: CGFloat = 320) -> CGFloat {
    guard let room = NSScreen.main?.visibleFrame.height else { return wanted }
    return min(wanted, max(atLeast, room - 60))
}
#endif

/// An iPad-style corner grip: a soft curved stroke in a tile's corner, bright white under the pointer or finger.
struct ResizeGrip: View {
    var trailing: Bool
    /// Faintly visible (the pointer is over the tile); fully white when the pointer is on the grip itself.
    var shown = true
    var active = false
    @State private var hovering = false

    var body: some View {
        CornerCurve(trailing: trailing)
            .stroke(.white.opacity(hovering || active ? 1 : (shown ? 0.8 : 0)), style: StrokeStyle(lineWidth: hovering || active ? 5 : 4, lineCap: .round))
            .shadow(color: .black.opacity(0.45), radius: 2)
            .frame(width: 22, height: 22)
            #if os(iOS) || os(tvOS)
            // A finger-sized target.
            .padding(11)
            #else
            .padding(7)
            #endif
            .contentShape(Rectangle())
            #if os(macOS)
            .pointerStyle(.frameResize(position: trailing ? .bottomTrailing : .bottomLeading))
            #endif
            .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
            .help("Drag to resize")
    }
}

struct CornerCurve: Shape {
    var trailing: Bool
    func path(in r: CGRect) -> Path {
        var p = Path()
        if trailing {
            p.move(to: CGPoint(x: r.maxX, y: r.minY))
            p.addQuadCurve(to: CGPoint(x: r.minX, y: r.maxY), control: CGPoint(x: r.maxX, y: r.maxY))
        } else {
            p.move(to: CGPoint(x: r.minX, y: r.minY))
            p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.maxY), control: CGPoint(x: r.minX, y: r.maxY))
        }
        return p
    }
}


/// The app's colours, taken from its icon: the background's steel blue fading to deep navy, its glowing cyan, its ice
/// blue and its white core. Home, its tiles, the Mac's bar and Settings follow it (as the widgets do).
/// The Mac layout's sizes, as the Apple TV draws them (it's seen from across the room): 1 on the Mac.
#if os(tvOS)
let macScale: CGFloat = 1.75
#else
let macScale: CGFloat = 1
#endif

enum IconPalette {
    static let steel = Color(red: 0.220, green: 0.325, blue: 0.443)
    static let mid = Color(red: 0.114, green: 0.200, blue: 0.314)
    static let deep = Color(red: 0.031, green: 0.067, blue: 0.122)
    static let cyan = Color(red: 0.227, green: 0.678, blue: 0.875)
    static let ice = Color(red: 0.659, green: 0.831, blue: 0.961)
    static let white = Color(red: 0.976, green: 0.992, blue: 0.992)
    /// A tile that's on: ice-white, a touch bluer at the bottom.
    static let onTile = LinearGradient(colors: [Color(red: 0.914, green: 0.965, blue: 1.0), Color(red: 0.749, green: 0.890, blue: 0.980)],
                                       startPoint: .top, endPoint: .bottom)
}

/// The icon's background, for a page: steel blue at the top fading to deep navy, a soft cyan glow in the middle.
struct IconBackdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [IconPalette.steel, IconPalette.mid, IconPalette.deep], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [IconPalette.cyan.opacity(0.14), .clear], center: UnitPoint(x: 0.5, y: 0.4), startRadius: 0, endRadius: 700)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}
