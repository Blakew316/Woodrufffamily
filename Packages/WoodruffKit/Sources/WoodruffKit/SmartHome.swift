import Foundation
import Observation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Network)
import Network
#endif

// The rest of the house next to the TVs: Sonos speakers (their own local UPnP control, no account) and Govee
// lights (their LAN API, plus Govee's cloud API when a key is set).

// MARK: - Sonos

/// One Sonos room (a speaker, or the coordinator of a group of them).
public struct SonosRoom: Identifiable, Hashable, Sendable {
    public var id: String            // RINCON_… of the room's speaker
    public var name: String          // "Master Bedroom"
    public var host: String          // its address
    public var coordinatorHost: String
    public var groupNames: [String]  // the rooms playing together with it
    public var state: String = ""    // PLAYING, PAUSED_PLAYBACK, STOPPED, TRANSITIONING
    public var title: String?
    public var artist: String?
    public var album: String?
    public var art: URL?
    public var volume: Int = 0
    public var muted = false
    public var isPlaying: Bool { state == "PLAYING" || state == "TRANSITIONING" }
    public var isCoordinator: Bool { host == coordinatorHost }
}

/// Talks to Sonos speakers over their own local SOAP API (port 1400).
public enum Sonos {
    static func soap(_ host: String, _ path: String, _ service: String, _ action: String, _ args: [(String, String)] = []) async throws -> String {
        var r = URLRequest(url: URL(string: "http://\(host):1400\(path)")!, timeoutInterval: 4)
        r.httpMethod = "POST"
        r.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        r.setValue("\"urn:schemas-upnp-org:service:\(service):1#\(action)\"", forHTTPHeaderField: "SOAPACTION")
        let body = args.map { "<\($0.0)>\(escape($0.1))</\($0.0)>" }.joined()
        r.httpBody = Data("""
        <?xml version="1.0" encoding="utf-8"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:\(action) xmlns:u="urn:schemas-upnp-org:service:\(service):1">\(body)</u:\(action)></s:Body></s:Envelope>
        """.utf8)
        let (d, resp) = try await URLSession.shared.data(for: r)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw TVError.badAnswer("The speaker said no") }
        return String(decoding: d, as: UTF8.self)
    }

    static func transport(_ host: String, _ action: String, _ extra: [(String, String)] = []) async throws -> String {
        try await soap(host, "/MediaRenderer/AVTransport/Control", "AVTransport", action, [("InstanceID", "0")] + extra)
    }
    static func rendering(_ host: String, _ action: String, _ extra: [(String, String)] = []) async throws -> String {
        try await soap(host, "/MediaRenderer/RenderingControl/Control", "RenderingControl", action, [("InstanceID", "0"), ("Channel", "Master")] + extra)
    }

    // Playback goes to the group's coordinator; volume to each speaker.
    public static func play(_ r: SonosRoom) async throws { _ = try await transport(r.coordinatorHost, "Play", [("Speed", "1")]) }
    public static func pause(_ r: SonosRoom) async throws { _ = try await transport(r.coordinatorHost, "Pause") }
    public static func next(_ r: SonosRoom) async throws { _ = try await transport(r.coordinatorHost, "Next") }
    public static func previous(_ r: SonosRoom) async throws { _ = try await transport(r.coordinatorHost, "Previous") }
    public static func setVolume(_ r: SonosRoom, _ v: Int) async throws { _ = try await rendering(r.host, "SetVolume", [("DesiredVolume", String(max(0, min(100, v))))]) }
    public static func setMute(_ r: SonosRoom, _ on: Bool) async throws { _ = try await rendering(r.host, "SetMute", [("DesiredMute", on ? "1" : "0")]) }

    /// Every room, from any one speaker: the household's group topology.
    public static func rooms(from host: String) async throws -> [SonosRoom] {
        let xml = unescape(tag("ZoneGroupState", in: try await soap(host, "/ZoneGroupTopology/Control", "ZoneGroupTopology", "GetZoneGroupState")) ?? "")
        var out: [SonosRoom] = []
        for group in matches(#"<ZoneGroup [^>]*>.*?</ZoneGroup>"#, in: xml) {
            let coord = attr("Coordinator", in: group) ?? ""
            let members = matches(#"<ZoneGroupMember [^>]*?/?>"#, in: group).filter { attr("Invisible", in: $0) != "1" }
            func hostOf(_ m: String) -> String? { attr("Location", in: m).flatMap { URL(string: $0)?.host } }
            guard let coordMember = members.first(where: { attr("UUID", in: $0) == coord }), let ch = hostOf(coordMember) else { continue }
            let names = members.compactMap { attr("ZoneName", in: $0) }
            for m in members {
                guard let id = attr("UUID", in: m), let h = hostOf(m), let name = attr("ZoneName", in: m) else { continue }
                out.append(SonosRoom(id: id, name: name, host: h, coordinatorHost: ch, groupNames: names))
            }
        }
        return out.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// What a room is playing, its state and volume.
    public static func refresh(_ r: SonosRoom) async -> SonosRoom {
        var r = r
        if let t = try? await transport(r.coordinatorHost, "GetTransportInfo") { r.state = tag("CurrentTransportState", in: t) ?? r.state }
        if let p = try? await transport(r.coordinatorHost, "GetPositionInfo") {
            let meta = unescape(tag("TrackMetaData", in: p) ?? "")
            r.title = tag("dc:title", in: meta).map(unescape)
            r.artist = tag("dc:creator", in: meta).map(unescape)
            r.album = tag("upnp:album", in: meta).map(unescape)
            if let a = tag("upnp:albumArtURI", in: meta).map(unescape), !a.isEmpty {
                r.art = a.hasPrefix("http") ? URL(string: a) : URL(string: "http://\(r.coordinatorHost):1400\(a)")
            } else { r.art = nil }
            // Radio streams put the station in the title and the song in streamContent.
            if let stream = tag("r:streamContent", in: meta).map(unescape), !stream.isEmpty { r.artist = r.title; r.title = stream }
        }
        if let v = try? await rendering(r.host, "GetVolume") { r.volume = Int(tag("CurrentVolume", in: v) ?? "") ?? r.volume }
        if let m = try? await rendering(r.host, "GetMute") { r.muted = tag("CurrentMute", in: m) == "1" }
        return r
    }

    // MARK: Tiny XML helpers (the answers are small and regular)

    static func tag(_ name: String, in s: String) -> String? {
        guard let open = s.range(of: "<\(name)(\s[^>]*)?>", options: .regularExpression),
              let close = s.range(of: "</\(name)>", range: open.upperBound..<s.endIndex) else { return nil }
        return String(s[open.upperBound..<close.lowerBound])
    }
    static func attr(_ name: String, in s: String) -> String? {
        guard let r = s.range(of: " \(name)=\"([^\"]*)\"", options: .regularExpression) else { return nil }
        let m = s[r]
        guard let q1 = m.firstIndex(of: "\"") else { return nil }
        return unescape(String(m[m.index(after: q1)..<m.index(before: m.endIndex)]))
    }
    static func matches(_ pattern: String, in s: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { Range($0.range, in: s).map { String(s[$0]) } }
    }
    static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'").replacingOccurrences(of: "&amp;", with: "&")
    }
    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}

// MARK: - Govee

public struct LightColor: Codable, Hashable, Sendable {
    public var r: Int, g: Int, b: Int
    public init(r: Int, g: Int, b: Int) { self.r = r; self.g = g; self.b = b }
}

/// One Govee light.
public struct GoveeLight: Identifiable, Hashable, Sendable {
    public var id: String          // its MAC-style device id ("1F:80:…")
    public var sku: String         // model, e.g. H6076
    public var name: String
    public var ip: String?         // set when it answers on the LAN
    public var cloud: Bool         // known to Govee's cloud API
    public var on = false
    public var brightness = 100    // 1…100
    public var color: LightColor?
    public var kelvin: Int?
}

/// Govee's LAN API (UDP: scan on 4001, answers on 4002, commands on 4003) and its cloud API.
public enum Govee {
    static let cloudBase = "https://developer-api.govee.com/v1"

    static func json(_ cmd: String, _ data: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["msg": ["cmd": cmd, "data": data]])) ?? Data()
    }

    // MARK: Cloud

    public static func cloudDevices(key: String) async throws -> [GoveeLight] {
        var r = URLRequest(url: URL(string: "\(cloudBase)/devices")!, timeoutInterval: 10)
        r.setValue(key, forHTTPHeaderField: "Govee-API-Key")
        let (d, resp) = try await URLSession.shared.data(for: r)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw TVError.badAnswer("Govee didn’t accept the API key.") }
        let v = try JSONDecoder().decode(JSONValue.self, from: d)
        return v["data"]?["devices"]?.array.compactMap { dev in
            guard let id = dev["device"]?.string, let model = dev["model"]?.string else { return nil }
            return GoveeLight(id: id, sku: model, name: dev["deviceName"]?.string ?? model, ip: nil, cloud: true)
        } ?? []
    }

    public static func cloudState(_ l: GoveeLight, key: String) async -> GoveeLight {
        var l = l
        var c = URLComponents(string: "\(cloudBase)/devices/state")!
        c.queryItems = [URLQueryItem(name: "device", value: l.id), URLQueryItem(name: "model", value: l.sku)]
        var r = URLRequest(url: c.url!, timeoutInterval: 10)
        r.setValue(key, forHTTPHeaderField: "Govee-API-Key")
        guard let (d, _) = try? await URLSession.shared.data(for: r), let v = try? JSONDecoder().decode(JSONValue.self, from: d) else { return l }
        for p in v["data"]?["properties"]?.array ?? [] {
            if let s = p["powerState"]?.string { l.on = s == "on" }
            if let b = p["brightness"]?.int { l.brightness = b }
            if let c = p["color"], let r = c["r"]?.int, let g = c["g"]?.int, let b = c["b"]?.int { l.color = LightColor(r: r, g: g, b: b) }
            if let k = p["colorTem"]?.int { l.kelvin = k }
        }
        return l
    }

    static func cloudBody(_ l: GoveeLight, name: String, value: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["device": l.id, "model": l.sku, "cmd": ["name": name, "value": value]])) ?? Data()
    }

    static func cloudControl(key: String, body: Data) async throws {
        var r = URLRequest(url: URL(string: "\(cloudBase)/devices/control")!, timeoutInterval: 10)
        r.httpMethod = "PUT"
        r.setValue(key, forHTTPHeaderField: "Govee-API-Key")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = body
        let (_, resp) = try await URLSession.shared.data(for: r)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw TVError.badAnswer("Govee didn’t do that. Try again in a moment.") }
    }
}

#if canImport(Network)
/// Finds Govee lights on the LAN and keeps their state, through one UDP listener.
@MainActor
final class GoveeLAN {
    private var listener: NWListener?
    var onScan: ((String, String, String) -> Void)?          // ip, device id, sku
    var onStatus: ((String, Bool, Int, LightColor?, Int?) -> Void)? // ip, on, brightness, color, kelvin

    func start() {
        guard listener == nil, let port = NWEndpoint.Port(rawValue: 4002), let l = try? NWListener(using: .udp, on: port) else { return }
        l.newConnectionHandler = { [weak self] c in
            c.start(queue: .main)
            self?.receive(c)
        }
        l.start(queue: .main)
        listener = l
    }

    private func receive(_ c: NWConnection) {
        c.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, let v = try? JSONDecoder().decode(JSONValue.self, from: data), let msg = v["msg"] {
                var ip: String?
                if case let .hostPort(host, _) = c.endpoint { ip = "\(host)".components(separatedBy: "%").first }
                let d = msg["data"]
                Task { @MainActor in
                    switch msg["cmd"]?.string {
                    case "scan":
                        if let ip = d?["ip"]?.string ?? ip, let dev = d?["device"]?.string { self.onScan?(ip, dev, d?["sku"]?.string ?? "Govee") }
                    case "devStatus":
                        if let ip {
                            let color = d?["color"].flatMap { c -> LightColor? in
                                guard let r = c["r"]?.int, let g = c["g"]?.int, let b = c["b"]?.int else { return nil }
                                return LightColor(r: r, g: g, b: b)
                            }
                            self.onStatus?(ip, d?["onOff"]?.int == 1, d?["brightness"]?.int ?? 100, color, d?["colorTemInKelvin"]?.int)
                        }
                    default: break
                    }
                }
            }
            if error == nil { Task { @MainActor in self.receive(c) } }
        }
    }

    /// Asks every address on the home network (and, on the Mac, Govee's multicast group) who's a Govee light.
    func scan() {
        let msg = Govee.json("scan", ["account_topic": "reserve"])
        var targets: [String] = []
        #if os(macOS)
        targets.append("239.255.255.250")
        #endif
        for p in LANScan.prefixes() { for n in 1...254 { targets.append(p + String(n)) } }
        for t in targets { send(msg, to: t, port: 4001) }
    }

    func status(_ ip: String) { send(Govee.json("devStatus", [:]), to: ip, port: 4003) }
    func turn(_ ip: String, _ on: Bool) { send(Govee.json("turn", ["value": on ? 1 : 0]), to: ip, port: 4003) }
    func brightness(_ ip: String, _ v: Int) { send(Govee.json("brightness", ["value": max(1, min(100, v))]), to: ip, port: 4003) }
    func color(_ ip: String, _ c: LightColor) {
        send(Govee.json("colorwc", ["color": ["r": c.r, "g": c.g, "b": c.b], "colorTemInKelvin": 0]), to: ip, port: 4003)
    }
    func kelvin(_ ip: String, _ k: Int) {
        send(Govee.json("colorwc", ["color": ["r": 0, "g": 0, "b": 0], "colorTemInKelvin": k]), to: ip, port: 4003)
    }

    private func send(_ data: Data, to host: String, port: UInt16) {
        let c = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .udp)
        c.stateUpdateHandler = { s in
            if case .ready = s { c.send(content: data, completion: .contentProcessed { _ in c.cancel() }) }
            if case .failed = s { c.cancel() }
        }
        c.start(queue: .global())
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { c.cancel() }
    }
}
#endif

// MARK: - The house

/// Speakers and lights, found and kept up to date alongside the TVs.
@Observable @MainActor
public final class SmartHome {
    public static let shared = SmartHome()

    public private(set) var speakers: [SonosRoom] = []
    public private(set) var lights: [GoveeLight] = []
    public var lightNames: [String: String] = Saved.load("lightNames", as: [String: String].self) ?? [:] {
        didSet { Saved.save("lightNames", lightNames); applyNames() }
    }
    public var goveeKey: String? {
        get { Keychain.get("govee.key") }
        set { Keychain.set(newValue, for: "govee.key"); Task { await refreshCloud() } }
    }
    public private(set) var goveeError: String?

    private var sonosSeed: String? = UserDefaults.standard.string(forKey: "sonosSeed")
    private var loop: Task<Void, Never>?
    #if canImport(Network)
    private let lan = GoveeLAN()
    private var browser: NWBrowser?
    #endif

    init() {}

    public func start() {
        guard loop == nil, !Demo.isOn else { return }
        #if canImport(Network)
        lan.onScan = { [weak self] ip, id, sku in self?.found(ip: ip, id: id, sku: sku) }
        lan.onStatus = { [weak self] ip, on, b, c, k in self?.status(ip: ip, on: on, brightness: b, color: c, kelvin: k) }
        lan.start()
        browseSonos()
        #endif
        loop = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                guard let self else { return }
                if tick % 60 == 0 { await self.findSonos(); self.scanLights(); await self.refreshCloud() }
                await self.refreshSpeakers()
                if tick % 2 == 0 { self.pollLights() }
                tick += 1
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    // MARK: Sonos

    #if canImport(Network)
    /// Sonos speakers announce `_sonos._tcp`; any one of them lists the whole household.
    private func browseSonos() {
        let b = NWBrowser(for: .bonjour(type: "_sonos._tcp", domain: nil), using: NWParameters())
        b.browseResultsChangedHandler = { [weak self] results, _ in
            for r in results {
                let c = NWConnection(to: r.endpoint, using: .tcp)
                c.stateUpdateHandler = { s in
                    if case .ready = s, case let .hostPort(host, _)? = c.currentPath?.remoteEndpoint {
                        let h = "\(host)".components(separatedBy: "%").first ?? "\(host)"
                        Task { @MainActor in self?.seed(h) }
                        c.cancel()
                    }
                    if case .failed = s { c.cancel() }
                }
                c.start(queue: .main)
            }
        }
        b.start(queue: .main)
        browser = b
    }
    #endif

    private func seed(_ host: String) {
        guard !host.contains(":") else { return }
        if sonosSeed != host || speakers.isEmpty {
            sonosSeed = host
            UserDefaults.standard.set(host, forKey: "sonosSeed")
            Task { await findSonos() }
        }
    }

    /// The household's rooms, from the last speaker that answered (or by asking the network on port 1400).
    public func findSonos() async {
        if let s = sonosSeed, let rooms = try? await Sonos.rooms(from: s), !rooms.isEmpty { merge(rooms); return }
        #if canImport(Darwin)
        let hosts = LANScan.prefixes().flatMap { p in (1...254).map { p + String($0) } }
        let found: String? = await withTaskGroup(of: String?.self) { g in
            for h in hosts {
                g.addTask {
                    var r = URLRequest(url: URL(string: "http://\(h):1400/xml/device_description.xml")!, timeoutInterval: 1.5)
                    r.httpMethod = "HEAD"
                    guard let (_, resp) = try? await URLSession.shared.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
                    return h
                }
            }
            for await h in g { if let h { g.cancelAll(); return h } }
            return nil
        }
        if let h = found, let rooms = try? await Sonos.rooms(from: h), !rooms.isEmpty {
            sonosSeed = h
            UserDefaults.standard.set(h, forKey: "sonosSeed")
            merge(rooms)
        }
        #endif
    }

    private func merge(_ rooms: [SonosRoom]) {
        speakers = rooms.map { r in
            var r = r
            if let old = speakers.first(where: { $0.id == r.id }) {
                r.state = old.state; r.title = old.title; r.artist = old.artist; r.album = old.album; r.art = old.art
                r.volume = old.volume; r.muted = old.muted
            }
            return r
        }
    }

    public func refreshSpeakers() async {
        guard !speakers.isEmpty else { return }
        let current = speakers
        let fresh = await withTaskGroup(of: SonosRoom.self) { g in
            for r in current { g.addTask { await Sonos.refresh(r) } }
            var out: [SonosRoom] = []
            for await r in g { out.append(r) }
            return out
        }
        speakers = current.map { r in fresh.first { $0.id == r.id } ?? r }
    }

    /// Runs [op] and refreshes the room straight after, so the tile answers at once.
    public func sonos(_ room: SonosRoom, _ op: @escaping @Sendable (SonosRoom) async throws -> Void) async {
        do { try await op(room) } catch {}
        try? await Task.sleep(nanoseconds: 300_000_000)
        await refreshSpeakers()
    }

    public func setVolume(_ room: SonosRoom, _ v: Int) {
        if let i = speakers.firstIndex(where: { $0.id == room.id }) { speakers[i].volume = v }
        Task { try? await Sonos.setVolume(room, v) }
    }

    // MARK: Govee

    private func scanLights() {
        #if canImport(Network)
        lan.scan()
        #endif
    }

    private func pollLights() {
        #if canImport(Network)
        for l in lights { if let ip = l.ip { lan.status(ip) } }
        #endif
    }

    private func found(ip: String, id: String, sku: String) {
        if let i = lights.firstIndex(where: { $0.id == id }) { lights[i].ip = ip }
        else { lights.append(GoveeLight(id: id, sku: sku, name: lightNames[id] ?? "Govee \(sku)", ip: ip, cloud: false)) }
        lights.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        #if canImport(Network)
        lan.status(ip)
        #endif
    }

    private func status(ip: String, on: Bool, brightness: Int, color: LightColor?, kelvin: Int?) {
        guard let i = lights.firstIndex(where: { $0.ip == ip }) else { return }
        lights[i].on = on; lights[i].brightness = brightness
        if let color, color != LightColor(r: 0, g: 0, b: 0) { lights[i].color = color }
        lights[i].kelvin = kelvin
    }

    public func refreshCloud() async {
        guard let key = goveeKey, !key.isEmpty else { goveeError = nil; return }
        do {
            let devs = try await Govee.cloudDevices(key: key)
            goveeError = nil
            for d in devs {
                if let i = lights.firstIndex(where: { $0.id == d.id }) {
                    lights[i].cloud = true
                    if lightNames[d.id] == nil { lights[i].name = d.name }
                } else {
                    var l = d
                    if let n = lightNames[d.id] { l.name = n }
                    lights.append(await Govee.cloudState(l, key: key))
                }
            }
            lights.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        } catch { goveeError = error.localizedDescription }
    }

    private func applyNames() {
        for i in lights.indices { if let n = lightNames[lights[i].id], !n.isEmpty { lights[i].name = n } }
    }

    /// Turns a light on or off: on the LAN when it's there, else through Govee's cloud.
    public func setOn(_ l: GoveeLight, _ on: Bool) {
        update(l) { $0.on = on }
        #if canImport(Network)
        if let ip = l.ip { lan.turn(ip, on); return }
        #endif
        cloud(l, "turn", on ? "on" : "off")
    }

    public func setBrightness(_ l: GoveeLight, _ v: Int) {
        update(l) { $0.brightness = v; $0.on = true }
        #if canImport(Network)
        if let ip = l.ip { lan.brightness(ip, v); return }
        #endif
        cloud(l, "brightness", v)
    }

    public func setColor(_ l: GoveeLight, _ c: LightColor) {
        update(l) { $0.color = c; $0.kelvin = nil; $0.on = true }
        #if canImport(Network)
        if let ip = l.ip { lan.color(ip, c); return }
        #endif
        cloud(l, "color", ["r": c.r, "g": c.g, "b": c.b])
    }

    public func setWhite(_ l: GoveeLight, kelvin: Int) {
        update(l) { $0.kelvin = kelvin; $0.color = nil; $0.on = true }
        #if canImport(Network)
        if let ip = l.ip { lan.kelvin(ip, kelvin); return }
        #endif
        cloud(l, "colorTem", kelvin)
    }

    public func rename(_ l: GoveeLight, _ name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        lightNames[l.id] = n.isEmpty ? nil : n
    }

    private func update(_ l: GoveeLight, _ f: (inout GoveeLight) -> Void) {
        if let i = lights.firstIndex(where: { $0.id == l.id }) { f(&lights[i]) }
    }

    private func cloud(_ l: GoveeLight, _ name: String, _ value: Any) {
        guard let key = goveeKey, !key.isEmpty, l.cloud else { goveeError = "Turn on LAN Control for \(l.name) in the Govee app, or add a Govee API key."; return }
        let body = Govee.cloudBody(l, name: name, value: value)
        Task {
            do { try await Govee.cloudControl(key: key, body: body) } catch { goveeError = error.localizedDescription }
        }
    }
}
