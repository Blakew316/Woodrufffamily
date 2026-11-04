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
    /// The services announced right now, by TV id: one that couldn't be reached yet (a TV announces itself while
    /// it's still starting up) is tried again rather than never.
    private var listed: [String: (endpoint: NWEndpoint, name: String)] = [:]
    /// Failed tries in a row per TV id (each one waits longer before the next).
    private var attempts: [String: Int] = [:]
    /// start() was called and stop() wasn't: a browser that fails is started again.
    private var wanted = false

    public init() {}

    public func start() {
        wanted = true
        guard browser == nil else { return }
        let params = NWParameters()
        params.includePeerToPeer = false
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: "_woodruff._tcp", domain: nil), using: params)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in self?.update(results) }
        }
        let mine = ObjectIdentifier(b)
        b.stateUpdateHandler = { [weak self] state in
            // Delivered on the main queue (started there below).
            MainActor.assumeIsolated {
                guard let self, let current = self.browser, ObjectIdentifier(current) == mine else { return }
                // The network changed, or the system let it go while the app was away: it used to stay stopped
                // for good (no TV heard switching on again). Look again shortly.
                switch state {
                case .failed, .cancelled: self.restartSoon()
                default: break
                }
            }
        }
        b.start(queue: .main)
        browser = b
        browsing = true
    }

    public func stop() {
        wanted = false
        tearDown()
    }

    private func tearDown() {
        browser?.cancel()
        browser = nil
        resolving.values.forEach { $0.cancel() }
        resolving = [:]
        listed = [:]
        attempts = [:]
        browsing = false
    }

    private func restartSoon() {
        tearDown()
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, self.wanted, self.browser == nil else { return }
            self.start()
        }
    }

    private func update(_ results: Set<NWBrowser.Result>) {
        var now: [String: (endpoint: NWEndpoint, name: String)] = [:]
        for r in results {
            guard case let .service(name, _, _, _) = r.endpoint else { continue }
            var tvId = name
            if case let .bonjour(txt) = r.metadata, let id = txt["id"], !id.isEmpty { tvId = id }
            now[tvId] = (endpoint: r.endpoint, name: name)
            if found.contains(where: { $0.id == tvId }) || resolving[tvId] != nil { continue }
            resolve(r.endpoint, id: tvId, name: name)
        }
        listed = now
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
            // Delivered on the main queue (started there below).
            MainActor.assumeIsolated {
                guard let self else { c.cancel(); return }
                switch state {
                case .ready:
                    if case let .hostPort(host, port)? = c.currentPath?.remoteEndpoint {
                        var h = "\(host)"
                        if let pct = h.firstIndex(of: "%") { h = String(h[..<pct]) }
                        self.found.removeAll { $0.id == id }
                        self.found.append(DiscoveredTV(id: id, name: name, host: h, port: Int(port.rawValue)))
                        self.found.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                        self.attempts[id] = nil
                    }
                    c.cancel()
                case .waiting, .failed:
                    // Not reachable yet (still starting up, or the network changed): this connection would wait
                    // for good. Let it go and try again in a little while, as long as the TV is still announced.
                    c.cancel()
                    self.retry(id, after: c)
                case .cancelled:
                    if self.resolving[id] === c { self.resolving[id] = nil }
                default: break
                }
            }
        }
        c.start(queue: .main)
        // Never left resolving forever.
        let key = ObjectIdentifier(c)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard let self, let stuck = self.resolving[id], ObjectIdentifier(stuck) == key else { return }
            stuck.cancel()
            self.retry(id, after: stuck)
        }
    }

    /// Tries [id] again after a wait (5 s, doubling to a minute) if it's still announced and not found meanwhile.
    private func retry(_ id: String, after c: NWConnection) {
        guard resolving[id] === c else { return }
        resolving[id] = nil
        let n = (attempts[id] ?? 0) + 1
        attempts[id] = n
        let wait = UInt64(min(60, 5 << min(n - 1, 4)))
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: wait * 1_000_000_000)
            guard let self, self.browser != nil, self.resolving[id] == nil, !self.found.contains(where: { $0.id == id }),
                  let l = self.listed[id] else { return }
            self.resolve(l.endpoint, id: id, name: l.name)
        }
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
        #if canImport(Darwin)
        // Network framework doesn't do broadcasts, so the packets to the broadcast addresses below never left this
        // device and "Turn On" only worked while the TV's address was still known. A plain socket with
        // SO_BROADCAST can (on iPhone only the TV's own address goes, as iOS keeps broadcasts for apps Apple
        // allows). A few times, a moment apart: one packet is easily lost on Wi‑Fi.
        var everywhere = hosts
        for p in LANScan.prefixes() where !everywhere.contains(p + "255") { everywhere.append(p + "255") }
        let targets = everywhere
        for attempt in 0..<3 {
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(400 * attempt)) {
                for h in targets { for p: UInt16 in [9, 7] { _ = WakeOnLAN.sendUDP(data, to: h, port: p) } }
            }
        }
        #endif
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

    #if canImport(Darwin)
    /// One UDP datagram from a plain socket that may broadcast. True when it went.
    static func sendUDP(_ data: Data, to host: String, port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { return false }
        let sent = data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> Int in
            withUnsafePointer(to: &addr) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    sendto(fd, buf.baseAddress, buf.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        return sent == data.count
    }
    #endif
}
#endif

#if canImport(Darwin)
import Darwin

/// Finds Woodruff TVs by asking every address on the home network (for a TV whose network announcement doesn't
/// reach Apple devices, as LG's can't): each TV answers `/manifest.webmanifest` with its name, no key needed.
public enum LANScan {
    /// This device's IPv4 networks as "a.b.c." prefixes (Wi‑Fi / Ethernet, not VPNs).
    public static func prefixes() -> [String] {
        var out: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let i = p.pointee
            guard let addr = i.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: i.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            let parts = ip.split(separator: ".")
            guard parts.count == 4, !ip.hasPrefix("169.254"), !ip.hasPrefix("100.") else { continue }
            let prefix = parts.prefix(3).joined(separator: ".") + "."
            if !out.contains(prefix) { out.append(prefix) }
        }
        return out
    }

    /// Every Woodruff TV answering on the home network (about two seconds).
    public static func find() async -> [DiscoveredTV] {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 1.2
        config.timeoutIntervalForResource = 1.5
        config.httpMaximumConnectionsPerHost = 2
        let session = URLSession(configuration: config)
        var hosts: [String] = []
        for p in prefixes() { for n in 1...254 { hosts.append(p + String(n)) } }
        var found: [DiscoveredTV] = []
        await withTaskGroup(of: DiscoveredTV?.self) { g in
            var it = hosts.makeIterator()
            func next() -> String? { it.next() }
            for _ in 0..<48 { if let h = next() { g.addTask { await probe(h, session) } } }
            while let r = await g.next() {
                if let r { found.append(r) }
                if let h = next() { g.addTask { await probe(h, session) } }
            }
        }
        session.invalidateAndCancel()
        return found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func probe(_ host: String, _ s: URLSession) async -> DiscoveredTV? {
        for port in [8090, 8080] {
            guard let url = URL(string: "http://\(host):\(port)/manifest.webmanifest"),
                  let answer = try? await s.data(from: url), (answer.1 as? HTTPURLResponse)?.statusCode == 200,
                  let o = try? JSONSerialization.jsonObject(with: answer.0) as? [String: Any],
                  let name = o["name"] as? String, (o["icons"] as? [Any]) != nil else { continue }
            return DiscoveredTV(id: "lan-\(host)", name: name, host: host, port: port)
        }
        return nil
    }
}
#endif

#if canImport(Network)
import Network

/// Is something at this address? Answers (port open), refused (the device is there, the port shut), or nothing
/// (switched off, or not on the network).
public enum NetProbe {
    public enum Result: Sendable { case answers, refused, nothing }

    private final class Once: @unchecked Sendable {
        let lock = NSLock()
        var done = false
        let conn: NWConnection
        let c: CheckedContinuation<Result, Never>
        init(_ conn: NWConnection, _ c: CheckedContinuation<Result, Never>) { self.conn = conn; self.c = c }
        func finish(_ r: Result) {
            lock.lock(); defer { lock.unlock() }
            guard !done else { return }
            done = true
            conn.cancel()
            c.resume(returning: r)
        }
    }

    public static func check(host: String, port: UInt16, timeout: Double = 3) async -> Result {
        await withCheckedContinuation { (c: CheckedContinuation<Result, Never>) in
            let conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? 8090, using: .tcp)
            let once = Once(conn, c)
            conn.stateUpdateHandler = { s in
                switch s {
                case .ready: once.finish(.answers)
                case .waiting(let e):
                    if case let .posix(code) = e, code == .ECONNREFUSED { once.finish(.refused) }
                case .failed(let e):
                    if case let .posix(code) = e, code == .ECONNREFUSED { once.finish(.refused) } else { once.finish(.nothing) }
                default: break
                }
            }
            conn.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { once.finish(.nothing) }
        }
    }
}
#endif
