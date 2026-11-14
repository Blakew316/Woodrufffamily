import SwiftUI
import Network
import WoodruffKit
#if canImport(UIKit)
import UIKit
#endif

/// The family's Apple TVs on the Wi‑Fi, for Settings → TVs: each by its own name, whether it's on, and whether it's in
/// the family (Connect for one that isn't: it gives the Apple TV the family's code once someone allows it there with
/// the remote; the settings sync then brings it every TV, key and sign-in).
///
/// An Apple TV was found only by Woodruff's own announcement, which it makes only while Woodruff is open there: tvOS
/// stops every app that isn't on screen, and each update closes it. So after an update, or with another app up, an
/// Apple TV that was on and on the Wi‑Fi wasn't found at all. Now it's found by what the Apple TV itself announces
/// whenever it's on, whatever app is up (AirPlay), by the name it has in its own Settings; Woodruff's announcement,
/// matched to it by address, adds its family and build while Woodruff is open there, and what that said last is kept.
struct FoundAppleTV: Identifiable, Equatable {
    var id: String
    var name: String
    /// Woodruff's address on it, while Woodruff is open there ("" when it isn't).
    var base: String
    var build: String
    var fp: String
    /// Woodruff is open on it now (Connect can reach it).
    var woodruffOpen = true
    /// The Apple TV itself is on the Wi‑Fi now.
    var onNetwork = true
}

@Observable @MainActor
final class AppleTVFinder {
    static let shared = AppleTVFinder()
    private(set) var found: [FoundAppleTV] = []
    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var airplay: NWBrowser?
    /// start() was called and stop() wasn't: a search that fails is started again.
    @ObservationIgnored private var wanted = false

    /// Woodruff open on an Apple TV, as it announces itself.
    private struct Open: Equatable {
        var id: String, name: String, base: String, build: String, fp: String
        var ip: String? { URL(string: base)?.host }
    }
    /// An Apple TV as it announces itself (AirPlay), and its address once worked out.
    private struct Seen {
        var key: String, name: String, endpoint: NWEndpoint
        var ip: String?
        /// When it was first announced (its address is waited for a moment before it's listed without one).
        var since: Date
    }
    /// What Woodruff on an Apple TV said last (kept, by the Apple TV's own id).
    private struct Known: Codable {
        var name: String
        var woodruff: String
        var fp: String
        var build: String
        var at: Double
    }
    @ObservationIgnored private var open: [String: Open] = [:]
    @ObservationIgnored private var seen: [String: Seen] = [:]
    @ObservationIgnored private var resolving: [String: NWConnection] = [:]
    @ObservationIgnored private var rebuildDue = false
    private static let knownKey = "appleTVs.known"
    /// An Apple TV not on the Wi‑Fi now is still listed (as not on it) when it was this recently.
    private static let keptFor: TimeInterval = 30 * 86400

    func start() {
        wanted = true
        startWoodruff()
        startAirPlay()
    }

    func stop() {
        wanted = false
        browser?.cancel(); browser = nil
        airplay?.cancel(); airplay = nil
        for c in resolving.values { c.cancel() }
        resolving = [:]
    }

    // MARK: Woodruff open on an Apple TV

    private func startWoodruff() {
        guard browser == nil else { return }
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: "_woodruffatv._tcp", domain: nil), using: .tcp)
        let mine = ObjectIdentifier(b)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            var list: [String: Open] = [:]
            for r in results {
                guard case .bonjour(let txt) = r.metadata, let id = txt["id"], let u = txt["u"] else { continue }
                var name = txt["name"] ?? ""
                if name.isEmpty, case .service(let n, _, _, _) = r.endpoint { name = n }
                list[id] = Open(id: id, name: name.isEmpty ? "Apple TV" : name, base: u, build: txt["build"] ?? "", fp: txt["fp"] ?? "")
            }
            Task { @MainActor in
                // Only the search running now (not one that failed and was let go).
                guard let self, let current = self.browser, ObjectIdentifier(current) == mine else { return }
                self.open = list
                self.rebuild()
            }
        }
        b.stateUpdateHandler = { [weak self] state in
            guard case .failed = state else { return }
            // Delivered on the main queue (started there below). The network changed, or the system let the search go
            // while the app was away: the list stopped there for good until the app was opened again. Looked for
            // again in a moment.
            MainActor.assumeIsolated {
                guard let self, let current = self.browser, ObjectIdentifier(current) == mine else { return }
                current.cancel()
                self.browser = nil
                self.open = [:]
                self.rebuild()
                self.again { $0.startWoodruff() }
            }
        }
        b.start(queue: .main)
        browser = b
    }

    // MARK: The Apple TVs themselves

    private func startAirPlay() {
        guard airplay == nil else { return }
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: "_airplay._tcp", domain: nil), using: .tcp)
        let mine = ObjectIdentifier(b)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            var list: [String: (name: String, endpoint: NWEndpoint)] = [:]
            for r in results {
                // Apple TVs only (not the HomePods, the Macs or other makers' TVs that take AirPlay too).
                guard case .bonjour(let txt) = r.metadata, case .service(let name, _, _, _) = r.endpoint,
                      (txt["model"] ?? "").lowercased().hasPrefix("appletv") else { continue }
                let key = (txt["deviceid"] ?? "").isEmpty ? name : txt["deviceid"]!
                list[key] = (name, r.endpoint)
            }
            Task { @MainActor in
                guard let self, let current = self.airplay, ObjectIdentifier(current) == mine else { return }
                var next: [String: Seen] = [:]
                for (key, v) in list {
                    // Its address, as worked out before, while it's announced the same way.
                    let ip = self.seen[key].flatMap { $0.endpoint == v.endpoint ? $0.ip : nil }
                    next[key] = Seen(key: key, name: v.name, endpoint: v.endpoint, ip: ip, since: self.seen[key]?.since ?? Date())
                }
                self.seen = next
                for s in next.values where s.ip == nil { self.resolve(s) }
                self.rebuild()
            }
        }
        b.stateUpdateHandler = { [weak self] state in
            guard case .failed = state else { return }
            MainActor.assumeIsolated {
                guard let self, let current = self.airplay, ObjectIdentifier(current) == mine else { return }
                current.cancel()
                self.airplay = nil
                self.seen = [:]
                self.rebuild()
                self.again { $0.startAirPlay() }
            }
        }
        b.start(queue: .main)
        airplay = b
    }

    /// [start] again in a few seconds, while the list is still wanted.
    private func again(_ start: @escaping @MainActor (AppleTVFinder) -> Void) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, self.wanted else { return }
            start(self)
        }
    }

    /// The Apple TV's address (IPv4), from a throwaway connection to what it announced: what Woodruff on it gives as
    /// its address, so the two are known to be the same Apple TV.
    private func resolve(_ s: Seen) {
        guard resolving[s.key] == nil else { return }
        let params = NWParameters.tcp
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
        let c = NWConnection(to: s.endpoint, using: params)
        let key = s.key, endpoint = s.endpoint
        resolving[key] = c
        c.stateUpdateHandler = { [weak self] state in
            // Delivered on the main queue (started there below).
            MainActor.assumeIsolated {
                guard let self else { c.cancel(); return }
                switch state {
                case .ready:
                    if case let .hostPort(host, _)? = c.currentPath?.remoteEndpoint {
                        var h = "\(host)"
                        if let pct = h.firstIndex(of: "%") { h = String(h[..<pct]) }
                        if self.seen[key]?.endpoint == endpoint { self.seen[key]?.ip = h }
                        self.rebuild()
                    }
                    c.cancel()
                case .waiting, .failed:
                    // Not reachable this moment (waking, or the network changing): asked again in a little while.
                    c.cancel()
                    self.retry(key)
                case .cancelled:
                    if self.resolving[key] === c { self.resolving[key] = nil }
                default: break
                }
            }
        }
        c.start(queue: .main)
        // Never left waiting.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard let self, self.resolving[key] === c else { return }
            c.cancel()
            self.resolving[key] = nil
            self.retry(key)
        }
    }

    /// The Apple TV [key]'s address asked for again in ten seconds, while it's still announced without one.
    private func retry(_ key: String) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard let self, self.wanted, let s = self.seen[key], s.ip == nil, self.resolving[key] == nil else { return }
            self.resolve(s)
        }
    }

    // MARK: The list

    private func rebuild() {
        let now = Date().timeIntervalSince1970
        var known = Saved.load(Self.knownKey, as: [String: Known].self) ?? [:]
        var rows: [FoundAppleTV] = []
        var matched = Set<String>()
        var seen = self.seen, open = self.open
        // One whose address is still being worked out waits a moment (two seconds at most) before it's listed: it may
        // be one Woodruff is open on, and it showed twice until the two were matched.
        let waiting = seen.values.filter { $0.ip == nil && Date().timeIntervalSince($0.since) < 2 }
        for w in waiting { seen[w.key] = nil }
        if !waiting.isEmpty, !rebuildDue {
            rebuildDue = true
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 2_100_000_000)
                self?.rebuildDue = false
                self?.rebuild()
            }
        }
        #if os(tvOS)
        // On an Apple TV the list is of the others (each by its address, so only once it's known).
        open[TVJoin.id] = nil
        let me = TVJoin.address()
        seen = seen.filter { $0.value.ip != nil && $0.value.ip != me }
        #endif
        for s in seen.values {
            if let ip = s.ip, let w = open.values.first(where: { $0.ip == ip }) {
                matched.insert(w.id)
                known[s.key] = Known(name: s.name, woodruff: w.id, fp: w.fp, build: w.build, at: now)
                rows.append(FoundAppleTV(id: w.id, name: s.name, base: w.base, build: w.build, fp: w.fp))
            } else {
                let k = known[s.key]
                let id = (k?.woodruff ?? "").isEmpty ? "airplay-\(s.key)" : k!.woodruff
                rows.append(FoundAppleTV(id: id, name: s.name, base: "", build: k?.build ?? "", fp: k?.fp ?? "",
                                         woodruffOpen: false))
                // Kept from now on too (as not in the family yet), so it's listed while it's off; once its address is
                // known (an Apple TV doesn't keep itself in its own list).
                if s.ip != nil {
                    if k == nil { known[s.key] = Known(name: s.name, woodruff: "", fp: "", build: "", at: now) }
                    else { known[s.key]?.name = s.name; known[s.key]?.at = now }
                }
            }
        }
        // Woodruff open on an Apple TV not matched yet (its address still being worked out, or AirPlay not found).
        for w in open.values where !matched.contains(w.id) && !rows.contains(where: { $0.id == w.id }) {
            let name = known.values.first { $0.woodruff == w.id }?.name ?? w.name
            rows.append(FoundAppleTV(id: w.id, name: name, base: w.base, build: w.build, fp: w.fp))
        }
        // The ones seen before that aren't on the Wi‑Fi now (switched off at the wall, or away).
        for (key, k) in known where self.seen[key] == nil && now - k.at < Self.keptFor {
            let id = k.woodruff.isEmpty ? "airplay-\(key)" : k.woodruff
            guard !rows.contains(where: { $0.id == id }) else { continue }
            rows.append(FoundAppleTV(id: id, name: k.name, base: "", build: k.build, fp: k.fp, woodruffOpen: false, onNetwork: false))
        }
        known = known.filter { now - $0.value.at < Self.keptFor }
        Saved.save(Self.knownKey, known)
        #if os(tvOS)
        rows.removeAll { $0.id == TVJoin.id }
        #endif
        rows.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if rows != found { found = rows }
    }

    /// The family code's fingerprint here (never the code), to tell which Apple TVs are in this family.
    static func familyPrint() -> String? {
        guard let code = FamilyCode.load().record?.code else { return nil }
        return FamilyCode.fingerprint(FamilyCode.key(code)).map { String(format: "%02x", $0) }.joined()
    }

    private static var deviceName: String {
        #if os(iOS) || os(tvOS)
        return UIDevice.current.userInterfaceIdiom == .pad ? "Your iPad" : "Your iPhone"
        #else
        return Host.current().localizedName ?? "Your Mac"
        #endif
    }

    /// Gives [atv] the family's code; it waits there for Allow (a minute at most). Nil when it's connected, else why not.
    static func connect(_ atv: FoundAppleTV) async -> String? {
        guard let code = FamilyCode.load().record?.code else {
            #if os(macOS)
            // (On the Mac the page is in Settings' own list, not inside General.)
            return "This device doesn’t have the family code yet. Enter it under Settings → Sync Across Devices first."
            #else
            return "This device doesn’t have the family code yet. Enter it under Settings → General → Sync Across Devices first."
            #endif
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
    /// This device's family code's fingerprint: read from the Keychain (slow) as the page opens, not at every redraw.
    @State private var mine: String?

    var body: some View {
        Section {
            if finder.found.isEmpty {
                // On an Apple TV the list is of the others (it doesn't list itself).
                #if os(tvOS)
                Text("No other Apple TV on this Wi‑Fi").foregroundStyle(.secondary)
                #else
                Text("No Apple TV on this Wi‑Fi").foregroundStyle(.secondary)
                #endif
            }
            ForEach(finder.found) { atv in
                let inFamily = mine != nil && atv.fp == mine
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(atv.name)
                        Text(state(atv, inFamily)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    // Connect reaches Woodruff on it, so only while Woodruff is open there.
                    if !inFamily && atv.woodruffOpen {
                        Button(busy == atv.id ? "Allow on the TV…" : "Connect") { connect(atv) }
                            .buttonStyle(.borderless)
                            .disabled(busy != nil)
                    }
                }
            }
        } header: {
            Text("Apple TVs")
        } footer: {
            Text(note ?? "Connect gives an Apple TV the family’s TVs, keys and settings. Open Woodruff on it, choose Connect, then Allow on the Apple TV with its remote.")
        }
        .onAppear {
            mine = AppleTVFinder.familyPrint()
            finder.start()
        }
    }

    /// "In the family · Build 767", and whether it's on with Woodruff closed, or off the Wi‑Fi. (Its family and build
    /// are what Woodruff on it said last, while it isn't open there.)
    private func state(_ atv: FoundAppleTV, _ inFamily: Bool) -> String {
        let build = atv.build.isEmpty ? "" : " · Build \(atv.build)"
        let family = inFamily ? "In the family" : atv.fp.isEmpty ? "Not connected" : "Uses another family code"
        if !atv.onNetwork { return "Not on the Wi‑Fi" + (atv.fp.isEmpty ? "" : " · " + family) }
        if !atv.woodruffOpen { return "On · Woodruff closed" + (atv.fp.isEmpty ? "" : " · " + family + build) }
        return family + build
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
