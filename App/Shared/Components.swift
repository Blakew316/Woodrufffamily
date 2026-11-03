import SwiftUI
import WoodruffKit

#if os(macOS)
typealias PlatformImage = NSImage
extension Image {
    init(platformImage: NSImage) { self.init(nsImage: platformImage) }
}
#else
typealias PlatformImage = UIImage
extension Image {
    init(platformImage: UIImage) { self.init(uiImage: platformImage) }
}
#endif

/// A small coloured dot for a TV's state.
struct StatusDot: View {
    var color: Color
    var body: some View {
        Circle().fill(color).frame(width: 9, height: 9)
            .overlay(Circle().stroke(color.opacity(0.35), lineWidth: 3).scaleEffect(1.6))
    }
}

/// A rounded card used across the dashboard.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.quaternary, lineWidth: 0.5))
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
            if busy { ProgressView().controlSize(.small) } else { label }
        }
        .disabled(busy)
    }
}

/// An image from a TV (thumbnails, posters, photos), with the TV's key in its URL.
struct TVImage: View {
    var url: URL?
    var contentMode: ContentMode = .fill
    var body: some View {
        AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.2))) { phase in
            switch phase {
            case .success(let img): img.resizable().aspectRatio(contentMode: contentMode)
            case .failure: Rectangle().fill(.quaternary).overlay(Image(systemName: "photo").foregroundStyle(.secondary))
            default: Rectangle().fill(.quaternary.opacity(0.6))
            }
        }
    }
}

/// "Last seen 5 min ago".
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

/// Empty / not-connected states.
struct EmptyState: View {
    var symbol: String
    var title: String
    var message: String
    var body: some View {
        ContentUnavailableView(title, systemImage: symbol, description: Text(message))
    }
}

extension View {
    /// Large title on iOS, plain title on macOS.
    func screenTitle(_ t: String) -> some View {
        #if os(iOS)
        return self.navigationTitle(t).navigationBarTitleDisplayMode(.large)
        #else
        return self.navigationTitle(t)
        #endif
    }

    @ViewBuilder func haptic<T: Equatable>(_ trigger: T) -> some View {
        #if os(iOS)
        self.sensoryFeedback(.impact(weight: .light), trigger: trigger)
        #else
        self
        #endif
    }
}

/// Copies text to the clipboard.
func copyToClipboard(_ s: String) {
    #if os(macOS)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
    #else
    UIPasteboard.general.string = s
    #endif
}
