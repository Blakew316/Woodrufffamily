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
    static let attention = Color(light: Color(red: 0.54, green: 0.31, blue: 0), dark: Color(red: 1, green: 0.71, blue: 0.28))
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

// MARK: - Liquid Glass

extension View {
    /// Liquid Glass in [shape] (iOS 26 / macOS 26), a material on older Macs.
    @ViewBuilder func glass<S: Shape>(_ shape: S, tint: Color? = nil, interactive: Bool = true) -> some View {
        if #available(iOS 26, macOS 26, *) {
            self.glassEffect(tint.map { Glass.regular.tint($0).interactive(interactive) } ?? Glass.regular.interactive(interactive), in: shape)
        } else {
            self.background { if let tint { shape.fill(tint.gradient) } else { shape.fill(.regularMaterial) } }
        }
    }

    /// Groups nearby glass so it blends and morphs together.
    @ViewBuilder func glassGroup(spacing: CGFloat = 16) -> some View {
        if #available(iOS 26, macOS 26, *) { GlassEffectContainer(spacing: spacing) { self } } else { self }
    }
}

// MARK: - Settings-style rows

/// The coloured rounded square with a white symbol, as in iOS Settings.
struct IconTile: View {
    var symbol: String
    var color: Color
    var size: CGFloat = 29
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.52, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: size * 0.235, style: .continuous))
    }
}

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
        }
        .buttonStyle(PressScale())
    }
}

/// Shrinks a little under the finger, springs back.
struct PressScale: ButtonStyle {
    var scale: CGFloat = 0.92
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .brightness(configuration.isPressed ? -0.04 : 0)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// A white capsule "Play" button, or a glass capsule for secondary actions.
struct CapsuleButton: View {
    var title: String
    var symbol: String?
    var prominent = true
    var action: () -> Void
    var body: some View {
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
        }
        .buttonStyle(PressScale(scale: 0.95))
    }
}

struct SecondaryGlass: ViewModifier {
    var on: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if on { content.glass(Capsule()).environment(\.colorScheme, .dark) } else { content }
    }
}

/// Runs an action against a TV, showing its error (the TV's own words) if it fails.
struct ActionButton<Label: View>: View {
    @Environment(Fleet.self) private var fleet
    var role: ButtonRole? = nil
    var action: () async throws -> Void
    @ViewBuilder var label: Label
    @State private var busy = false

    var body: some View {
        Button(role: role) {
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
        .disabled(busy)
    }
}

// MARK: - TV picker (top of Remote and Watch)

/// "● Living Room ⌄": picks the TV the remote, Watch and Send act on, or every TV at once.
struct TVPicker: View {
    @Environment(Fleet.self) private var fleet
    var allowAll = false

    var body: some View {
        Menu {
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
        } label: {
            HStack(spacing: 6) {
                Circle().fill(dotColor).frame(width: 7, height: 7)
                Text(allowAll && fleet.remoteAll ? "All TVs" : (fleet.selected?.name ?? "TV"))
                    .font(.headline)
                Image(systemName: "chevron.down").font(.caption.weight(.bold)).foregroundStyle(.secondary)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 14).padding(.vertical, 9)
            .contentShape(Capsule())
            .glass(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
    }

    private var dotColor: Color {
        if allowAll && fleet.remoteAll { return fleet.tvs.contains(where: \.online) ? .green : .gray }
        guard let t = fleet.selected else { return .gray }
        return t.online ? (t.link == "refused" ? .orange : .green) : .gray
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
/// otherwise fading in as it arrives.
struct Artwork: View {
    var url: URL?
    var contentMode: ContentMode = .fill
    var body: some View {
        CachedImage(url: url, contentMode: contentMode) {
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
        #if os(iOS)
        if let ns { self.matchedTransitionSource(id: id, in: ns) } else { self }
        #else
        self
        #endif
    }

    /// Opens with a zoom out of the tile marked [id].
    @ViewBuilder func zoomDestination(_ id: String, _ ns: Namespace.ID?) -> some View {
        #if os(iOS)
        if let ns { self.navigationTransition(.zoom(sourceID: id, in: ns)) } else { self }
        #else
        self
        #endif
    }
}

// MARK: - Formatting

func relative(_ ms: Double?) -> String {
    guard let ms, ms > 0 else { return "never" }
    let d = Date(timeIntervalSince1970: ms / 1000)
    if abs(d.timeIntervalSinceNow) < 45 { return "just now" }
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .short
    return f.localizedString(for: d, relativeTo: Date())
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

    @ViewBuilder func haptic<T: Equatable>(_ trigger: T) -> some View {
        #if os(iOS)
        self.sensoryFeedback(.impact(weight: .light, intensity: 0.7), trigger: trigger)
        #else
        self
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
#endif

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
        #if os(iOS)
        self.searchable(text: text, prompt: prompt)
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
    /// Mac: a sheet opens at a comfortable fixed size. Nothing on iPhone.
    @ViewBuilder func macResizable(width: CGFloat = 680, height: CGFloat = 760, minWidth: CGFloat = 360, minHeight: CGFloat = 320, aspect: CGFloat? = nil) -> some View {
        #if os(macOS)
        self.frame(width: width, height: aspect.map { width / $0 } ?? height)
        #else
        self
        #endif
    }
}

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
            #if os(iOS)
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
