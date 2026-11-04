import SwiftUI

/// A page opened on the Mac's page stack: its title (for Woodruff's Back button) and the page itself.
struct PageRoute: Hashable {
    let id = UUID()
    let title: String
    let view: AnyView

    static func == (a: PageRoute, b: PageRoute) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

#if os(macOS)
/// The Mac window's pages: whatever the sidebar picked at the bottom, and what's been opened from it on top. Woodruff
/// keeps the stack itself so its own Back button (under the search field) always knows where it goes, and so the
/// sidebar can always take you straight back to a section's first page.
@Observable @MainActor
final class MacNav {
    static let shared = MacNav()
    var path: [PageRoute] = []

    func push(_ title: String, _ view: some View) {
        path.append(PageRoute(title: title, view: AnyView(view)))
    }

    func pop() {
        if !path.isEmpty { path.removeLast() }
    }

    func reset() {
        if !path.isEmpty { path.removeAll() }
    }
}
#endif

private struct MacPageStackKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// Inside the Mac window's page stack (not a sheet with a stack of its own).
    var macPageStack: Bool {
        get { self[MacPageStackKey.self] }
        set { self[MacPageStackKey.self] = newValue }
    }
}

/// A row that opens a page. On iPhone it's an ordinary navigation link. On the Mac the page goes on the window's own
/// stack, so Woodruff's Back button (under the search field) returns from it.
struct PageLink<Label: View, Destination: View>: View {
    var title: String
    var destination: () -> Destination
    var label: () -> Label
    @Environment(\.macPageStack) private var onStack

    init(_ title: String, @ViewBuilder destination: @escaping () -> Destination, @ViewBuilder label: @escaping () -> Label) {
        self.title = title
        self.destination = destination
        self.label = label
    }

    var body: some View {
        #if os(macOS)
        if onStack {
            NavigationLink(value: PageRoute(title: title, view: AnyView(destination()))) { label() }
        } else {
            NavigationLink { destination() } label: { label() }
        }
        #else
        NavigationLink { destination() } label: { label() }
        #endif
    }
}

extension PageLink where Label == Text {
    /// A link that's just its title.
    init(_ title: String, @ViewBuilder destination: @escaping () -> Destination) {
        self.init(title, destination: destination) { Text(title) }
    }
}

extension View {
    /// Mac: the buttons a page had in the window's toolbar, in a row at the top of the page instead (the window draws
    /// its own bar). Nothing on iPhone, where they stay in the toolbar.
    @ViewBuilder func macPageBar<Items: View>(@ViewBuilder _ items: () -> Items) -> some View {
        #if os(macOS)
        self.safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                items()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 6)
        }
        #else
        self
        #endif
    }
}
