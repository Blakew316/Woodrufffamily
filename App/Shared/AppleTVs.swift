import SwiftUI
import Network
import WoodruffKit
#if canImport(UIKit)
import UIKit
#endif

/// The family's Apple TVs running Woodruff, found on the Wi‑Fi (each announces itself), for Settings → TVs: whether
/// each is in the family, and Connect for one that isn't (it gives the Apple TV the family's code once someone
/// allows it there with the remote; the settings sync then brings it every TV, key and sign-in).
struct FoundAppleTV: Identifiable, Equatable {
    var id: String
    var name: String
    var base: String
    var build: String
    var fp: String
}

@Observable @MainActor
final class AppleTVFinder {
    static let shared = AppleTVFinder()
    private(set) var found: [FoundAppleTV] = []
    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: "_woodruffatv._tcp", domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            var list: [FoundAppleTV] = []
            for r in results {
                guard case .bonjour(let txt) = r.metadata, let id = txt["id"], let u = txt["u"] else { continue }
                var name = txt["name"] ?? ""
                if name.isEmpty, case .service(let n, _, _, _) = r.endpoint { name = n }
                list.append(FoundAppleTV(id: id, name: name.isEmpty ? "Apple TV" : name, base: u, build: txt["build"] ?? "", fp: txt["fp"] ?? ""))
            }
            list.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            Task { @MainActor in self?.found = list }
        }
        b.start(queue: .main)
        browser = b
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }

    /// The family code's fingerprint here (never the code), to tell which Apple TVs are in this family.
    static func familyPrint() -> String? {
        guard let code = FamilyCode.load().record?.code else { return nil }
        return FamilyCode.fingerprint(FamilyCode.key(code)).map { String(format: "%02x", $0) }.joined()
    }

    private static var deviceName: String {
        #if os(iOS)
        return UIDevice.current.userInterfaceIdiom == .pad ? "Your iPad" : "Your iPhone"
        #else
        return Host.current().localizedName ?? "Your Mac"
        #endif
    }

    /// Gives [atv] the family's code; it waits there for Allow (a minute at most). Nil when it's connected, else why not.
    static func connect(_ atv: FoundAppleTV) async -> String? {
        guard let code = FamilyCode.load().record?.code else {
            return "This device doesn’t have the family code yet. Enter it under Settings → General → Sync Across Devices first."
        }
        guard let base = URL(string: atv.base) else { return "\(atv.name) didn’t give an address." }
        var r = URLRequest(url: base.appendingPathComponent("join"))
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: ["code": code, "from": deviceName])
        r.timeoutInterval = 75
        do {
            let (d, resp) = try await URLSession.shared.data(for: r)
            if (resp as? HTTPURLResponse)?.statusCode == 200 { return nil }
            let why = ((try? JSONSerialization.jsonObject(with: d)) as? [String: Any])?["error"] as? String
            return why ?? "\(atv.name) didn’t take the code."
        } catch {
            return "Can’t reach \(atv.name). Make sure this device is on the same Wi‑Fi."
        }
    }
}

/// Settings → TVs → Apple TVs.
struct AppleTVsSection: View {
    @State private var finder = AppleTVFinder.shared
    @State private var busy: String?
    @State private var note: String?

    var body: some View {
        let mine = AppleTVFinder.familyPrint()
        Section {
            if finder.found.isEmpty {
                Text("None found on this Wi‑Fi").foregroundStyle(.secondary)
            }
            ForEach(finder.found) { atv in
                let inFamily = mine != nil && atv.fp == mine
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(atv.name)
                        Text(state(atv, inFamily)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !inFamily {
                        Button(busy == atv.id ? "Allow on the TV…" : "Connect") { connect(atv) }
                            .buttonStyle(.borderless)
                            .disabled(busy != nil)
                    }
                }
            }
        } header: {
            Text("Apple TVs")
        } footer: {
            Text(note ?? "Connect gives an Apple TV the family’s TVs, keys and settings. Then choose Allow on the Apple TV with its remote.")
        }
        .onAppear { finder.start() }
    }

    private func state(_ atv: FoundAppleTV, _ inFamily: Bool) -> String {
        let build = atv.build.isEmpty ? "" : " · Build \(atv.build)"
        if inFamily { return "In the family" + build }
        return (atv.fp.isEmpty ? "Not connected" : "Uses another family code") + build
    }

    private func connect(_ atv: FoundAppleTV) {
        busy = atv.id
        note = "Choose Allow on \(atv.name) with its remote."
        Task {
            let problem = await AppleTVFinder.connect(atv)
            busy = nil
            note = problem ?? "\(atv.name) is connected. Its TVs and settings are coming over."
        }
    }
}
