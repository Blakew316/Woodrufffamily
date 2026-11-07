import SwiftUI
import WoodruffKit

/// The top of Settings, only when something isn't working on this device: each sign-in or connection that's failing,
/// a TV that turned this device's pairing down, and (on a Mac) an update or TestFlight upload that went wrong, each
/// with what it says and where to fix it. Nothing shows when all is well.
struct NeedsAttentionSection: View {
    @Environment(Fleet.self) private var fleet
    let hub: HubSettings

    struct Issue: Identifiable {
        var id: String
        var title: String
        var detail: String
        var inAccounts = false
    }

    private var issues: [Issue] { Self.issues(fleet) }

    /// Everything not working on this device right now (none when all is well).
    @MainActor static func issues(_ fleet: Fleet) -> [Issue] {
        var out: [Issue] = []
        func add(_ id: String, _ title: String, _ detail: String?, accounts: Bool = true) {
            guard let d = detail?.trimmingCharacters(in: .whitespacesAndNewlines), !d.isEmpty else { return }
            out.append(Issue(id: id, title: title, detail: d, inAccounts: accounts))
        }
        if SmartThings.shared.connected { add("st", "SmartThings", SmartThings.shared.error) }
        if NestCameras.shared.connected { add("nest", "Nest Cameras", NestCameras.shared.error) }
        if Cync.shared.connected { add("cync", "Cync Lights", Cync.shared.error) }
        if Dreo.shared.connected { add("dreo", "Dreo Fans", Dreo.shared.error) }
        if DecoWifi.shared.connected { add("deco", "Deco Wi‑Fi", DecoWifi.shared.error) }
        for tv in fleet.tvs where tv.link == "refused" {
            add("tv-\(tv.id)", tv.name, "Turned down this device’s link. Link it again with the code the TV shows.", accounts: false)
        }
        #if os(macOS)
        let u = UpdaterStatus.shared
        if u.hasProblem { add("updates", "Updates", u.detail ?? u.summary, accounts: false) }
        if let tf = u.testFlight, tf.problem { add("testflight", "TestFlight", tf.detail ?? tf.value, accounts: false) }
        #endif
        return out
    }

    var body: some View {
        let list = issues
        if !list.isEmpty {
            Section {
                ForEach(list) { issue in
                    if issue.inAccounts {
                        PageLink("Accounts") { ConnectionsView(hub: hub) } label: { row(issue) }
                    } else {
                        row(issue)
                    }
                }
            } header: {
                Text("Needs Attention")
            }
        }
    }

    private func row(_ issue: Issue) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(issue.title).foregroundStyle(Palette.attention)
            Text(issue.detail).font(.footnote).foregroundStyle(.secondary).lineLimit(4)
        }
        .padding(.vertical, 2)
    }
}
