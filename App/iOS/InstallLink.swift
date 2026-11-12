import SwiftUI

/// The install link: the newest build of the app, published by the Mac Studio on GitHub after each release, which
/// this iPhone or iPad can install by itself from anywhere: without TestFlight, the home network or a Mac.
/// (`scripts/updater.py` publishes it there: the app, what iOS reads to install it, and a note of which build it is.
/// The app is signed for the family's own devices and installs on no other.)
@Observable @MainActor
final class InstallLink {
    static let shared = InstallLink()

    private static let files = "https://github.com/Blakew316/Woodrufffamily/releases/download/install-link/"

    /// The build published there: nil until it's been read, or when it couldn't be.
    private(set) var build: Int?
    private(set) var checking = false
    private(set) var failed = false

    /// Whether what's published is newer than the app that's running.
    var newer: Bool { (build ?? 0) > (Int(AppBuild.build) ?? 0) }

    /// Reads which build is published.
    func check() async {
        guard !checking, let url = URL(string: Self.files + "latest.json") else { return }
        checking = true
        defer { checking = false }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let note = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let published = (note["build"] as? NSNumber)?.intValue else {
            failed = true
            return
        }
        failed = false
        build = published
    }

    /// Hands the published build to iOS, which asks before installing it and then puts it in this app's place (the app
    /// closes when it does: opened again, it's the new build).
    func install() {
        guard let url = URL(string: "itms-services://?action=download-manifest&url=" + Self.files + "manifest.plist") else { return }
        UIApplication.shared.open(url)
    }
}

/// Settings → General → Woodruff Family: whether the install link has a newer build, and the button that installs it.
struct InstallLinkRows: View {
    private let link = InstallLink.shared

    var body: some View {
        Group {
            LabeledContent("Install Link", value: value)
            if link.newer, let build = link.build {
                Button("Install Build \(build)") { link.install() }
            }
        }
        .task { await link.check() }
    }

    private var value: String {
        if let build = link.build { return link.newer ? "Build \(build)" : "Up to Date" }
        if link.checking { return "Checking" }
        return link.failed ? "Not Reached" : ""
    }
}
