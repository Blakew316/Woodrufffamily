import Foundation
#if canImport(Network)
import Network

/// A Woodruff TV heard on the network (mDNS `_woodruff._tcp`, as TvLinks.kt and tvfind.js advertise it).
public struct DiscoveredTV: Identifiable, Hashable, Sendable {
    /// The TV's own id from the TXT record "id" (the same id `/api/status` reports), or its service name.
    public var id: String
    public var name: String
    public var host: String
    public var port: Int
    public var base: URL? { URL(string: "http://\(host.contains(":") ? "[\(host)]" : host):\(port)") }
}

/// Browses for Woodruff TVs and resolves each to an address and port.
/// Discovery finds the TVs; pairing still needs each TV's key (its QR code), or a hub that's already paired.
@MainActor
public final class TVDiscovery: ObservableObject {
    @Published public private(set) var found: [DiscoveredTV] = []
    @Published public private(set) var browsing = false
    private var browser: NWBrowser?
    private var resolving: [String: NWConnection] = [:]

    public init() {}

    public func start() {
        guard browser == nil else { return }
        let params = NWParameters()
        params.includePeerToPeer = false
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: "_woodruff._tcp", domain: nil), using: params)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in self?.update(results) }
        }
        b.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                if case .failed = state { self?.stop() }
            }
        }
        b.start(queue: .main)
        browser = b
        browsing = true
    }

    public func stop() {
        browser?.cancel()
        browser = nil
        resolving.values.forEach { $0.cancel() }
        resolving = [:]
        browsing = false
    }

    private func update(_ results: Set<NWBrowser.Result>) {
        for r in results {
            guard case let .service(name, _, _, _) = r.endpoint else { continue }
            var tvId = name
            if case let .bonjour(txt) = r.metadata, let id = txt["id"], !id.isEmpty { tvId = id }
            if found.contains(where: { $0.id == tvId }) || resolving[tvId] != nil { continue }
            resolve(r.endpoint, id: tvId, name: name)
        }
        let names = Set(results.compactMap { r -> String? in
            if case let .service(name, _, _, _) = r.endpoint { return name }; return nil
        })
        found.removeAll { !names.contains($0.name) }
    }

    /// Opens a throwaway TCP connection to learn the service's address and port.
    private func resolve(_ endpoint: NWEndpoint, id: String, name: String) {
        let params = NWParameters.tcp
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
        let c = NWConnection(to: endpoint, using: params)
        resolving[id] = c
        c.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if case let .hostPort(host, port)? = c.currentPath?.remoteEndpoint {
                    var h = "\(host)"
                    if let pct = h.firstIndex(of: "%") { h = String(h[..<pct]) }
                    let tv = DiscoveredTV(id: id, name: name, host: h, port: Int(port.rawValue))
                    Task { @MainActor in
                        guard let self else { return }
                        self.found.removeAll { $0.id == id }
                        self.found.append(tv)
                        self.found.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                    }
                }
                c.cancel()
                Task { @MainActor in self?.resolving[id] = nil }
            case .failed, .cancelled:
                Task { @MainActor in self?.resolving[id] = nil }
            default: break
            }
        }
        c.start(queue: .main)
    }
}

/// Wake-on-LAN magic packets (turns on TVs that support it, e.g. LG with "Turn on via Wi-Fi").
public enum WakeOnLAN {
    public static func packet(mac: String) -> Data? {
        let hex = mac.split(whereSeparator: { ":-. ".contains($0) }).joined()
        guard hex.count == 12 else { return nil }
        var bytes = [UInt8]()
        var i = hex.startIndex
        for _ in 0..<6 {
            let j = hex.index(i, offsetBy: 2)
            guard let b = UInt8(hex[i..<j], radix: 16) else { return nil }
            bytes.append(b); i = j
        }
        var out = [UInt8](repeating: 0xFF, count: 6)
        for _ in 0..<16 { out += bytes }
        return Data(out)
    }

    /// Sends the packet to the broadcast address (and to the TV's last address) on ports 9 and 7.
    public static func wake(mac: String, lastHost: String? = nil) {
        guard let data = packet(mac: mac) else { return }
        var hosts = ["255.255.255.255"]
        if let lastHost {
            hosts.append(lastHost)
            let parts = lastHost.split(separator: ".")
            if parts.count == 4 { hosts.append(parts.prefix(3).joined(separator: ".") + ".255") }
        }
        for h in hosts {
            for p: UInt16 in [9, 7] {
                let params = NWParameters.udp
                params.allowLocalEndpointReuse = true
                let c = NWConnection(host: NWEndpoint.Host(h), port: NWEndpoint.Port(rawValue: p)!, using: params)
                c.stateUpdateHandler = { s in
                    if case .ready = s { c.send(content: data, completion: .contentProcessed { _ in c.cancel() }) }
                    if case .failed = s { c.cancel() }
                }
                c.start(queue: .global())
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) { c.cancel() }
            }
        }
    }
}
#endif
