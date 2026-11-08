import SwiftUI

/// A page opened on the Mac's page stack: its title (for Woodruff's Back button) and the page itself.
struct PageRoute: Hashable {
    let id = UUID()
    let title: String
    /// Mac: what Back in Woodruff's top bar says for this page ("Settings").
    var backTo: String = "Back"
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

    func push(_ title: String, backTo: String = "Back", _ view: some View) {
        path.append(PageRoute(title: title, backTo: backTo, view: AnyView(MacPage(title: title, backTo: backTo) { view }.environment(\.macPageTitle, title))))
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
#if os(macOS) || os(tvOS)
/// Mac Settings' right-hand side: a page opened from it opens right there (not over the whole window).
struct MacPanePush {
    let push: (String, AnyView) -> Void
}
private struct MacPanePushKey: EnvironmentKey { static let defaultValue: MacPanePush? = nil }
extension EnvironmentValues {
    var macPanePush: MacPanePush? {
        get { self[MacPanePushKey.self] }
        set { self[MacPanePushKey.self] = newValue }
    }
}
#endif
private struct MacPageTitleKey: EnvironmentKey { static let defaultValue = "Back" }
extension EnvironmentValues {
    /// Inside the Mac window's page stack (not a sheet with a stack of its own).
    var macPageStack: Bool {
        get { self[MacPageStackKey.self] }
        set { self[MacPageStackKey.self] = newValue }
    }
    /// The name of the page you're on (a page opened from it says "‹ <this>" on its Back button).
    var macPageTitle: String {
        get { self[MacPageTitleKey.self] }
        set { self[MacPageTitleKey.self] = newValue }
    }
}

/// A row that opens a page. On iPhone it's an ordinary navigation link. On the Mac the page goes on the window's own
/// stack, so Woodruff's Back button (under the search field) returns from it.
struct PageLink<Label: View, Destination: View>: View {
    var title: String
    var destination: () -> Destination
    var label: () -> Label
    @Environment(\.macPageStack) private var onStack
    @Environment(\.macPageTitle) private var here
    #if os(macOS) || os(tvOS)
    @Environment(\.macPanePush) private var panePush
    #endif

    init(_ title: String, @ViewBuilder destination: @escaping () -> Destination, @ViewBuilder label: @escaping () -> Label) {
        self.title = title
        self.destination = destination
        self.label = label
    }

    var body: some View {
        #if os(macOS)
        // In Mac Settings' right-hand side: opened right there.
        if let panePush {
            Button { panePush.push(title, AnyView(destination().environment(\.macPageTitle, title))) } label: {
                HStack(spacing: 8) {
                    label().frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        // The page opened carries its own Back button (under the search field), however it was opened.
        else if onStack {
            NavigationLink(value: PageRoute(title: title, backTo: here, view: AnyView(page))) { label() }
        } else {
            NavigationLink { page } label: { label() }
        }
        #elseif os(tvOS)
        // In Settings' right-hand side (the Mac's layout): opened right there.
        if let panePush {
            Button { panePush.push(title, AnyView(destination().environment(\.macPageTitle, title))) } label: {
                HStack(spacing: 8) {
                    label().frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                }
            }
        } else {
            NavigationLink { destination() } label: { label() }
        }
        #else
        NavigationLink { destination() } label: { label() }
        #endif
    }

    #if os(macOS)
    private var page: some View {
        MacPage(title: title, backTo: here, onStack: onStack) { destination() }
            .environment(\.macPageTitle, title)
    }
    #endif
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

#if os(macOS)
/// A page opened from another on the Mac: its Back button ("‹ Settings") and its name at the top left, right under
/// the search field. Back closes just this page (⌘[ too).
struct MacPage<Content: View>: View {
    var title: String
    var backTo: String
    /// On the window's own page stack: Back takes this page off it. Elsewhere (a sheet's stack), Back dismisses it.
    var onStack = true
    @ViewBuilder var content: () -> Content

    // No `@Environment(\.dismiss)` here. On the window's stack it changes every time a page on the stack redraws, so
    // every page redrew, the page under this one redrew its links, which redrew this page, and so on without end: the
    // Mac app hung or crashed (an AppKit layout loop) opening Recent Messages, Camera Alerts, Shortcuts or Wi-Fi.
    var body: some View {
        content()
            // A bar (not an inset): the window draws one soft edge under Woodruff's bar and Back together.
            // On the window's stack, Back is in Woodruff's own top bar (at its left); a sheet's pages keep their own row.
            .safeAreaBar(edge: .top, spacing: 0) {
                if !onStack {
                    MacDismissBackRow(title: title, backTo: backTo)
                }
            }
    }
}

/// Back for a page opened off the window's stack: only this row reads `dismiss`, so only this row redraws with it.
private struct MacDismissBackRow: View {
    var title: String
    var backTo: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        MacBackRow(title: title, backTo: backTo) { dismiss() }
    }
}

/// "‹ Settings   TVs": the way back, and where you are.
struct MacBackRow: View {
    var title: String
    var backTo: String
    var back: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: back) {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left").font(.body.weight(.semibold))
                    Text(backTo).lineLimit(1)
                }
                .padding(.horizontal, 4)
            }
            .buttonStyle(.glass)
            .controlSize(.large)
            .keyboardShortcut("[", modifiers: .command)
            .help("Back to \(backTo) (⌘[)")
            // The page's name is already at the top of the window; it isn't repeated here.
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.top, 2)
        .padding(.bottom, 10)
        // No frosted strip of its own: it sits in the page's top bar, whose soft edge keeps a page scrolling under
        // it readable (a strip of its own showed as a band with a hard top edge under Woodruff's bar).
    }
}
#endif
