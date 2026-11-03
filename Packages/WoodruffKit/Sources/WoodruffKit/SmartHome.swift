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
public struct SonosRoom: Identifiable, Hashable, Sendable, Codable {
    public var id: String            // RINCON_… of the room's speaker
    public var name: String          // what the family calls it here (the Sonos room name unless renamed)
    public var zone: String = ""     // the room name in the Sonos app
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
    public var coordinatorID = ""
    /// The speakers that make up the room: a soundbar with its Sub and rear surrounds, or a stereo pair.
    public var parts: [SonosPart] = []
    /// Playing the TV's sound (a soundbar's TV input) rather than music.
    public var isTV = false
    /// The product, e.g. "Arc", once asked.
    public var model: String?
    public var isPlaying: Bool { state == "PLAYING" || state == "TRANSITIONING" }
    public var isCoordinator: Bool { host == coordinatorHost }
    /// A soundbar with surrounds or a Sub.
    public var isHomeTheater: Bool { parts.contains { $0.role != .front } }
    /// "Arc · Sub · 2 Surrounds".
    public var setupSummary: String? {
        guard parts.count > 1 else { return nil }
        var bits = [model ?? "Soundbar"]
        if parts.contains(where: { $0.role == .sub }) { bits.append("Sub") }
        let rears = parts.filter { $0.role == .leftRear || $0.role == .rightRear }.count
        if rears > 0 { bits.append(rears == 1 ? "Surround" : "\(rears) Surrounds") }
        return bits.joined(separator: " · ")
    }
}

/// One speaker inside a Sonos room, and the job it does there.
public struct SonosPart: Identifiable, Hashable, Sendable, Codable {
    public enum Role: String, Codable, Sendable { case front, sub, leftRear, rightRear, left, right }
    public var id: String
    public var host: String?
    public var role: Role
    public var model: String?
    public var roleName: String {
        switch role {
        case .front: return "Front"
        case .sub: return "Sub"
        case .leftRear: return "Left Surround"
        case .rightRear: return "Right Surround"
        case .left: return "Left"
        case .right: return "Right"
        }
    }
}

/// A soundbar's home theater settings, as in the Sonos app's Sound settings.
public struct SonosSound: Hashable, Sendable {
    public var nightSound: Bool?
    public var speech: Bool?
    public var loudness: Bool?
    public var bass: Int?          // -10…10
    public var treble: Int?        // -10…10
    public var subOn: Bool?
    public var subLevel: Int?      // -15…15
    public var surroundOn: Bool?
    public var surroundLevel: Int? // -15…15 (TV)
    public var musicSurroundLevel: Int?
    public var heightLevel: Int?   // -10…10 (Atmos height, Arc)
    public init() {}
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
            let coord = attr("Coordinator", in: openTag(group)) ?? ""
            // A member is a room; its Satellites (Sub, surrounds) sit inside it.
            let all = matches(#"<ZoneGroupMember [^>]*?(/>|>.*?</ZoneGroupMember>)"#, in: group)
            let members = all.filter { attr("Invisible", in: openTag($0)) != "1" }
            func hostOf(_ tag: String) -> String? { attr("Location", in: tag).flatMap { URL(string: $0)?.host } }
            guard let coordMember = members.first(where: { attr("UUID", in: openTag($0)) == coord }), let ch = hostOf(openTag(coordMember)) else { continue }
            let names = members.compactMap { attr("ZoneName", in: openTag($0)) }
            for m in members {
                let head = openTag(m)
                guard let id = attr("UUID", in: head), let h = hostOf(head), let name = attr("ZoneName", in: head) else { continue }
                var room = SonosRoom(id: id, name: name, zone: name, host: h, coordinatorHost: ch, groupNames: names)
                room.coordinatorID = coord
                room.parts = parts(member: m, id: id, host: h)
                out.append(room)
            }
        }
        return out.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The speakers in one room, from its channel map ("RINCON_A:LF,RF;RINCON_B:SW;RINCON_C:LR;RINCON_D:RR").
    static func parts(member m: String, id: String, host: String) -> [SonosPart] {
        let head = openTag(m)
        var hosts: [String: String] = [id: host]
        for sat in matches(#"<Satellite [^>]*?/?>"#, in: m) {
            if let sid = attr("UUID", in: sat), let h = attr("Location", in: sat).flatMap({ URL(string: $0)?.host }) { hosts[sid] = h }
        }
        let map = attr("HTSatChanMapSet", in: head) ?? attr("ChannelMapSet", in: head)
        guard let map, !map.isEmpty else { return [SonosPart(id: id, host: host, role: .front)] }
        var out: [SonosPart] = []
        for entry in map.split(separator: ";") {
            let bits = entry.split(separator: ":", maxSplits: 1)
            guard bits.count == 2 else { continue }
            let sid = String(bits[0]), ch = String(bits[1])
            // Channel codes vary by speaker ("LR", "LR,LR", "RR", "SW", "SW,SW", "LF,RF"…): read what they contain.
            let chans = Set(ch.split(separator: ",").map(String.init))
            let role: SonosPart.Role
            if chans.contains("SW") { role = .sub }
            else if chans.contains("LR") || chans.contains("LS") { role = .leftRear }
            else if chans.contains("RR") || chans.contains("RS") { role = .rightRear }
            else if chans == ["LF"] && !map.contains("SW") && !map.contains("LR") { role = .left }
            else if chans == ["RF"] && !map.contains("SW") && !map.contains("LR") { role = .right }
            else { role = .front }
            if !out.contains(where: { $0.id == sid }) { out.append(SonosPart(id: sid, host: hosts[sid], role: role)) }
        }
        // A soundbar room has one front (the bar itself); any other speaker read as "front" is a surround.
        if out.count > 1, out.contains(where: { $0.id == id }) {
            var leftNext = !out.contains { $0.role == .leftRear }
            for i in out.indices where out[i].role == .front && out[i].id != id {
                if leftNext { out[i].role = .leftRear } else { out[i].role = .rightRear }
                leftNext.toggle()
            }
        }
        let order: [SonosPart.Role] = [.front, .left, .right, .sub, .leftRear, .rightRear]
        return out.sorted { (order.firstIndex(of: $0.role) ?? 9) < (order.firstIndex(of: $1.role) ?? 9) }
    }

    static func openTag(_ s: String) -> String {
        guard let end = s.firstIndex(of: ">") else { return s }
        return String(s[...end])
    }

    /// A speaker's product name ("Arc", "Sub", "One SL").
    public static func model(_ host: String) async -> String? {
        var r = URLRequest(url: URL(string: "http://\(host):1400/xml/device_description.xml")!, timeoutInterval: 4)
        r.httpMethod = "GET"
        guard let (d, _) = try? await URLSession.shared.data(for: r) else { return nil }
        let xml = String(decoding: d, as: UTF8.self)
        return tag("displayName", in: xml) ?? tag("modelName", in: xml).map { $0.replacingOccurrences(of: "Sonos ", with: "") }
    }

    // MARK: Home theater

    static func rc(_ host: String, _ action: String, _ args: [(String, String)] = []) async throws -> String {
        try await soap(host, "/MediaRenderer/RenderingControl/Control", "RenderingControl", action, [("InstanceID", "0")] + args)
    }

    static func eq(_ host: String, _ type: String) async -> Int? {
        guard let x = try? await rc(host, "GetEQ", [("EQType", type)]) else { return nil }
        return Int(tag("CurrentValue", in: x) ?? "")
    }

    public static func setEQ(_ r: SonosRoom, _ type: String, _ value: Int) async throws {
        _ = try await rc(r.host, "SetEQ", [("EQType", type), ("DesiredValue", String(value))])
    }

    /// The soundbar's sound settings (those it has).
    public static func sound(_ r: SonosRoom) async -> SonosSound {
        var s = SonosSound()
        let h = r.host
        async let night = eq(h, "NightMode")
        async let speech = eq(h, "DialogLevel")
        async let subOn = eq(h, "SubEnable")
        async let subLevel = eq(h, "SubGain")
        async let surOn = eq(h, "SurroundEnable")
        async let surLevel = eq(h, "SurroundLevel")
        async let musicLevel = eq(h, "MusicSurroundLevel")
        async let height = eq(h, "HeightChannelLevel")
        async let bass = try? rc(h, "GetBass")
        async let treble = try? rc(h, "GetTreble")
        async let loud = try? rc(h, "GetLoudness", [("Channel", "Master")])
        s.nightSound = await night.map { $0 == 1 }
        s.speech = await speech.map { $0 == 1 }
        s.subOn = await subOn.map { $0 == 1 }
        s.subLevel = await subLevel
        s.surroundOn = await surOn.map { $0 == 1 }
        s.surroundLevel = await surLevel
        s.musicSurroundLevel = await musicLevel
        s.heightLevel = await height
        s.bass = await bass.flatMap { Int(tag("CurrentBass", in: $0) ?? "") }
        s.treble = await treble.flatMap { Int(tag("CurrentTreble", in: $0) ?? "") }
        s.loudness = await loud.flatMap { tag("CurrentLoudness", in: $0) }.map { $0 == "1" }
        return s
    }

    public static func setBass(_ r: SonosRoom, _ v: Int) async throws { _ = try await rc(r.host, "SetBass", [("DesiredBass", String(v))]) }
    public static func setTreble(_ r: SonosRoom, _ v: Int) async throws { _ = try await rc(r.host, "SetTreble", [("DesiredTreble", String(v))]) }
    public static func setLoudness(_ r: SonosRoom, _ on: Bool) async throws {
        _ = try await rc(r.host, "SetLoudness", [("Channel", "Master"), ("DesiredLoudness", on ? "1" : "0")])
    }

    /// Switches the soundbar to the TV's sound.
    public static func playTV(_ r: SonosRoom) async throws {
        _ = try await transport(r.host, "SetAVTransportURI", [("CurrentURI", "x-sonos-htastream:\(r.id):spdif"), ("CurrentURIMetaData", "")])
        _ = try await transport(r.host, "Play", [("Speed", "1")])
    }

    // MARK: Groups

    /// Has [room] play along with [leader]'s group.
    public static func join(_ room: SonosRoom, to leader: SonosRoom) async throws {
        _ = try await transport(room.host, "SetAVTransportURI", [("CurrentURI", "x-rincon:\(leader.coordinatorID.isEmpty ? leader.id : leader.coordinatorID)"), ("CurrentURIMetaData", "")])
    }

    /// Takes [room] out of its group.
    public static func leave(_ room: SonosRoom) async throws {
        _ = try await transport(room.host, "BecomeCoordinatorOfStandaloneGroup")
    }

    /// What a room is playing, its state and volume.
    public static func refresh(_ r: SonosRoom) async -> SonosRoom {
        var r = r
        if let t = try? await transport(r.coordinatorHost, "GetTransportInfo") { r.state = tag("CurrentTransportState", in: t) ?? r.state }
        if let p = try? await transport(r.coordinatorHost, "GetPositionInfo") {
            let meta = unescape(tag("TrackMetaData", in: p) ?? "")
            r.isTV = (tag("TrackURI", in: p) ?? "").hasPrefix("x-sonos-htastream")
            r.title = tag("dc:title", in: meta).map(unescape)
            r.artist = tag("dc:creator", in: meta).map(unescape)
            r.album = tag("upnp:album", in: meta).map(unescape)
            if let a = tag("upnp:albumArtURI", in: meta).map(unescape), !a.isEmpty {
                r.art = a.hasPrefix("http") ? URL(string: a) : URL(string: "http://\(r.coordinatorHost):1400\(a)")
            } else { r.art = nil }
            // Radio streams put the station in the title and the song in streamContent.
            if let stream = tag("r:streamContent", in: meta).map(unescape), !stream.isEmpty { r.artist = r.title; r.title = stream }
            if r.isTV { r.title = "TV"; r.artist = nil; r.album = nil; r.art = nil }
        }
        if let v = try? await rendering(r.host, "GetVolume") { r.volume = Int(tag("CurrentVolume", in: v) ?? "") ?? r.volume }
        if let m = try? await rendering(r.host, "GetMute") { r.muted = tag("CurrentMute", in: m) == "1" }
        return r
    }

    // MARK: Tiny XML helpers (the answers are small and regular)

    static func tag(_ name: String, in s: String) -> String? {
        guard let open = s.range(of: "<\(name)(\\s[^>]*)?>", options: .regularExpression),
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

/// One answer to the Govee search: an address and what's there.
public struct LightAnswer: Identifiable, Hashable, Sendable {
    public var ip: String
    public var device: String
    public var sku: String
    public var at: Date
    public var id: String { ip }
}

/// One Govee light.
public struct GoveeLight: Identifiable, Hashable, Sendable, Codable {
    public var id: String          // its MAC-style device id ("1F:80:…")
    public var sku: String         // model, e.g. H6076
    public var name: String
    public var ip: String?         // set when it answers on the LAN
    public var cloud: Bool         // known to Govee's cloud API
    public var on = false
    public var brightness = 100    // 1…100
    public var color: LightColor?
    public var kelvin: Int?
    /// Where it's controlled: "govee", or "home" (an Apple Home light, e.g. Cync over Matter).
    public var source: String? = nil
    /// Its room in Apple Home, used until one is chosen here.
    public var zone: String? = nil
    public var isHome: Bool { source == "home" }

    public init(id: String, sku: String, name: String, ip: String? = nil, cloud: Bool = false, on: Bool = false,
                brightness: Int = 100, color: LightColor? = nil, kelvin: Int? = nil, source: String? = nil, zone: String? = nil) {
        self.id = id; self.sku = sku; self.name = name; self.ip = ip; self.cloud = cloud; self.on = on
        self.brightness = brightness; self.color = color; self.kelvin = kelvin; self.source = source; self.zone = zone
    }
}

/// A change to an Apple Home light, carried out by the app (HomeKit lives in the iPhone app, not here).
public enum LightCommand: Sendable {
    case power(Bool)
    case brightness(Int)
    case color(LightColor)
    case kelvin(Int)
}

extension Govee {
    /// What Govee calls a model, for a light's first name ("Table Lamp 2 Pro" rather than "H6020").
    public static func product(_ sku: String) -> String {
        let known: [String: String] = [
            "H6020": "Table Lamp 2 Pro", "H6022": "Table Lamp 2", "H6076": "Floor Lamp", "H6072": "Lyra Floor Lamp",
            "H6079": "Floor Lamp Pro", "H607C": "Floor Lamp 2", "H60B0": "Uplighter Floor Lamp", "H6078": "Cylinder Floor Lamp",
            "H6073": "Floor Lamp", "H6058": "Glide Hexa", "H6061": "Glide Hexa Pro", "H6046": "TV Light Bars",
            "H6047": "Gaming Light Bars", "H6056": "Flow Plus Light Bars", "H6199": "TV Backlight", "H6168": "TV Backlight",
            "H6008": "Smart Bulb", "H6010": "Smart Bulb", "H6159": "Light Strip", "H619A": "Light Strip", "H61A2": "Light Strip",
        ]
        return known[sku.uppercased()].map { "Govee \($0)" } ?? "Govee \(sku)"
    }
}

/// Govee's LAN API (UDP: scan on 4001, answers on 4002, commands on 4003) and its cloud API.
public enum Govee {
    static let cloudBase = "https://developer-api.govee.com/v1"

    static func json(_ cmd: String, _ data: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["msg": ["cmd": cmd, "data": data]])) ?? Data()
    }

    #if canImport(Network)
    /// Sends one LAN command to a light (port 4003), or a scan (port 4001). Fire and forget.
    public static func lan(_ ip: String, _ cmd: String, _ data: [String: Any], port: UInt16 = 4003) {
        send(json(cmd, data), to: ip, port: port)
    }

    /// Turns a light on or off over the LAN (for widgets, which can't wait for the app).
    public static func lanTurn(_ ip: String, _ on: Bool) { lan(ip, "turn", ["value": on ? 1 : 0]) }

    static func send(_ data: Data, to host: String, port: UInt16) {
        let c = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .udp)
        c.stateUpdateHandler = { s in
            if case .ready = s { c.send(content: data, completion: .contentProcessed { _ in c.cancel() }) }
            if case .failed = s { c.cancel() }
        }
        c.start(queue: .global())
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { c.cancel() }
    }
    #endif

    // MARK: Cloud (Govee's current Open API: every model, including the newest lamps)

    static let openBase = "https://openapi.api.govee.com/router/api/v1"

    static func open(_ path: String, key: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        var r = URLRequest(url: URL(string: openBase + path)!, timeoutInterval: 12)
        r.setValue(key, forHTTPHeaderField: "Govee-API-Key")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body {
            r.httpMethod = "POST"
            r.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (d, resp) = try await URLSession.shared.data(for: r)
        let json = (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200, (json["code"] as? Int).map({ $0 == 200 }) ?? true else {
            if code == 401 || code == 403 { throw TVError.badAnswer("Govee didn’t accept the API key.") }
            if code == 429 { throw TVError.badAnswer("Govee says too many requests; trying again shortly.") }
            throw TVError.badAnswer((json["msg"] as? String ?? json["message"] as? String).map { "Govee: \($0)" } ?? "Govee answered \(code).")
        }
        return json
    }

    /// Every device on the Govee account (lights, lamps, strips…).
    public static func openDevices(key: String) async throws -> [GoveeLight] {
        let j = try await open("/user/devices", key: key)
        return (j["data"] as? [[String: Any]] ?? []).compactMap { d in
            guard let id = d["device"] as? String, let sku = d["sku"] as? String else { return nil }
            let caps = (d["capabilities"] as? [[String: Any]] ?? []).compactMap { $0["type"] as? String }
            guard caps.contains("devices.capabilities.on_off") else { return nil }
            let name = (d["deviceName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? product(sku)
            return GoveeLight(id: id, sku: sku, name: name, ip: nil, cloud: true)
        }
    }

    public static func openState(_ l: GoveeLight, key: String) async -> GoveeLight {
        var l = l
        guard let j = try? await open("/device/state", key: key, body: ["requestId": UUID().uuidString, "payload": ["sku": l.sku, "device": l.id]]),
              let caps = (j["payload"] as? [String: Any])?["capabilities"] as? [[String: Any]] else { return l }
        for c in caps {
            let v = (c["state"] as? [String: Any])?["value"]
            switch c["instance"] as? String {
            case "powerSwitch": if let n = v as? NSNumber { l.on = n.intValue == 1 }
            case "brightness": if let n = v as? NSNumber { l.brightness = max(1, min(100, n.intValue)) }
            case "colorRgb":
                if let n = (v as? NSNumber)?.intValue, n > 0 { l.color = LightColor(r: (n >> 16) & 255, g: (n >> 8) & 255, b: n & 255) }
            case "colorTemperatureK": if let n = (v as? NSNumber)?.intValue, n > 0 { l.kelvin = n }
            default: break
            }
        }
        return l
    }

    static func openControl(_ l: GoveeLight, key: String, type: String, instance: String, value: Int) async throws {
        _ = try await open("/device/control", key: key, body: [
            "requestId": UUID().uuidString,
            "payload": ["sku": l.sku, "device": l.id, "capability": ["type": type, "instance": instance, "value": value]],
        ])
    }

    // MARK: Cloud (the original API, for older keys)

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
        guard listener == nil, let port = NWEndpoint.Port(rawValue: 4002) else { return }
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        guard let l = try? NWListener(using: params, on: port) else { return }
        l.newConnectionHandler = { [weak self] c in
            c.start(queue: .main)
            self?.receive(c)
        }
        // iOS closes it while the app is in the background; open a new one when that happens.
        l.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                Task { @MainActor in
                    guard let self, self.listener === l else { return }
                    self.listener = nil
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    self.start()
                }
            default: break
            }
        }
        l.start(queue: .main)
        listener = l
    }

    /// Opens a fresh listener (after the app comes back to the front).
    func restart() {
        let old = listener
        listener = nil
        old?.cancel()
        start()
    }

    nonisolated private func receive(_ c: NWConnection) {
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
            if error == nil { self.receive(c) }
        }
    }

    /// Asks every address on the home network (and, on the Mac, Govee's multicast group) who's a Govee light.
    func scan(extra: [String] = []) {
        let msg = Govee.json("scan", ["account_topic": "reserve"])
        var targets: [String] = extra
        #if os(macOS)
        targets.append("239.255.255.250")
        #endif
        for p in LANScan.prefixes() { for n in 1...254 { targets.append(p + String(n)) } }
        // A few at a time, so a burst of 254 doesn't get dropped and a lamp's answer lost.
        for (i, chunk) in stride(from: 0, to: targets.count, by: 16).map({ Array(targets[$0..<min($0 + 16, targets.count)]) }).enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(60 * i)) { [weak self] in
                for t in chunk { self?.send(msg, to: t, port: 4001) }
            }
        }
    }

    /// Asks one address directly (a light added by hand).
    func probe(_ ip: String) {
        send(Govee.json("scan", ["account_topic": "reserve"]), to: ip, port: 4001)
        send(Govee.json("devStatus", [:]), to: ip, port: 4003)
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

    private func send(_ data: Data, to host: String, port: UInt16) { Govee.send(data, to: host, port: port) }
}
#endif

// MARK: - The house

/// Speakers and lights, found and kept up to date alongside the TVs.
@Observable @MainActor
public final class SmartHome {
    public static let shared = SmartHome()

    public private(set) var speakers: [SonosRoom] = []
    public private(set) var lights: [GoveeLight] = []
    /// Names the family gave speakers and lights here (device id → name).
    public var names: [String: String] = Saved.load("smartNames", as: [String: String].self) ?? Saved.load("lightNames", as: [String: String].self) ?? [:] {
        didSet { Saved.save("smartNames", names); applyNames() }
    }
    /// Which room each speaker and light is in (device id → room).
    public var rooms: [String: String] = Saved.load("smartRooms", as: [String: String].self) ?? [:] {
        didSet { Saved.save("smartRooms", rooms) }
    }
    /// Rooms added by hand (besides the TVs' rooms and Sonos's own).
    public var extraRooms: [String] = Saved.load("smartExtraRooms", as: [String].self) ?? [] {
        didSet { Saved.save("smartExtraRooms", extraRooms) }
    }
    /// The speaker the Control Center and Siri buttons act on when none is named: the last one used.
    public var lastSpeakerID: String? {
        get { UserDefaults.standard.string(forKey: "lastSpeaker") }
        set { UserDefaults.standard.set(newValue, forKey: "lastSpeaker") }
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

    init() {
        // What was found last time, so Home, Siri and Control Center work straight away.
        speakers = Saved.load("smartSpeakers2", as: [SonosRoom].self) ?? []
        lights = Saved.load("smartLights", as: [GoveeLight].self) ?? []
        applyNames()
    }

    private func persist() {
        // Never the same light twice (found on the Wi‑Fi and through the account at the same moment).
        var seen = Set<String>()
        let unique = lights.filter { seen.insert($0.id).inserted }
        if unique.count != lights.count { lights = unique }
        Saved.save("smartSpeakers2", speakers)
        Saved.save("smartLights", lights)
        onChange?()
    }

    /// Rooms other devices report themselves (Apple Home, SmartThings), used until one is chosen here.
    public var externalZones: [String: String] = [:]

    /// Carries out a change to an Apple Home light (set by the iPhone app).
    public var homeControl: ((GoveeLight, LightCommand) -> Void)?

    /// The lights in Apple Home (Cync and other Matter lights), from the iPhone app.
    public func setHomeLights(_ list: [GoveeLight]) {
        var next = lights.filter { !$0.isHome }
        for var l in list {
            if let n = names[l.id], !n.isEmpty { l.name = n }
            next.append(l)
        }
        next.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if next != lights { lights = next; persist() }
    }

    /// Called when what's found or its state changes (the Mac shares it with its widgets).
    public var onChange: (() -> Void)?

    // MARK: Rooms and names

    /// The room a speaker or light is in: chosen here, or a speaker's own Sonos room.
    public func room(of id: String) -> String? {
        if let r = rooms[id], !r.isEmpty { return r }
        return speakers.first { $0.id == id }?.zone ?? lights.first { $0.id == id }?.zone ?? externalZones[id]
    }

    public func setRoom(_ id: String, _ room: String?) {
        let r = room?.trimmingCharacters(in: .whitespaces)
        rooms[id] = (r?.isEmpty ?? true) ? nil : r
        if let r, !r.isEmpty, !knownRooms.contains(r) { extraRooms.append(r) }
    }

    /// Every room in the house: given by the app (the TVs' names), chosen for devices, or added by hand.
    public var knownRooms: [String] {
        var out = Set(extraRooms).union(rooms.values).union(speakers.map(\.zone))
        out.remove("")
        return out.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Renames a speaker or light (an empty name goes back to its own).
    public func rename(_ id: String, _ name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        names[id] = n.isEmpty ? nil : n
        if n.isEmpty {
            if let i = speakers.firstIndex(where: { $0.id == id }) { speakers[i].name = speakers[i].zone }
        }
        persist()
    }

    public var lastSpeaker: SonosRoom? {
        speakers.first { $0.id == lastSpeakerID } ?? speakers.first(where: \.isPlaying) ?? speakers.first
    }

    public func speaker(_ id: String) -> SonosRoom? { speakers.first { $0.id == id } }
    public func light(_ id: String) -> GoveeLight? { lights.first { $0.id == id } }

    public func allLights(_ on: Bool) { for l in lights where l.on != on { setOn(l, on) } }


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
                if tick % 60 == 0 { await self.findSonos() }
                if tick % 24 == 0 { await self.refreshCloud() }
                // Ask for lights a few times early on (UDP answers can get lost), then every five minutes.
                if [0, 1, 3, 6, 12].contains(tick) || tick % 60 == 0 { self.scanLights() }
                await self.refreshSpeakers()
                self.pollLights()
                tick += 1
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    /// The app came back to the front: listen afresh and ask everything for its state straight away.
    public func wake() {
        guard loop != nil else { return }
        #if canImport(Network)
        lan.restart()
        #endif
        Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            pollLights()
            await refreshSpeakers()
            await refreshCloud()
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
            if let n = names[r.id], !n.isEmpty { r.name = n }
            r.groupNames = r.groupNames.map { g in rooms.first { $0.zone == g }.flatMap { names[$0.id] } ?? g }
            if let old = speakers.first(where: { $0.id == r.id }) {
                r.state = old.state; r.title = old.title; r.artist = old.artist; r.album = old.album; r.art = old.art
                r.volume = old.volume; r.muted = old.muted; r.isTV = old.isTV; r.model = old.model
                for i in r.parts.indices { r.parts[i].model = old.parts.first { $0.id == r.parts[i].id }?.model }
            }
            return r
        }
        persist()
        Task { await fillModels() }
    }

    /// Asks each speaker once what it is ("Arc", "Sub", "Era 100").
    private func fillModels() async {
        for (i, r) in speakers.enumerated() {
            if r.model == nil, let m = await Sonos.model(r.host), i < speakers.count, speakers[i].id == r.id { speakers[i].model = m }
            for (j, p) in r.parts.enumerated() where p.model == nil {
                guard let h = p.host, let m = await Sonos.model(h), i < speakers.count, j < speakers[i].parts.count else { continue }
                speakers[i].parts[j].model = m
            }
        }
        persist()
    }

    /// Rebuilds the rooms after grouping changes.
    public func regroup(_ op: @escaping @Sendable () async throws -> Void) async {
        do { try await op() } catch {}
        try? await Task.sleep(nanoseconds: 600_000_000)
        await findSonos()
        await refreshSpeakers()
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
        // Only the playing state comes from the refresh; names, models and parts may have changed meanwhile.
        let next = speakers.map { cur -> SonosRoom in
            guard let f = fresh.first(where: { $0.id == cur.id }) else { return cur }
            var r = cur
            r.state = f.state; r.title = f.title; r.artist = f.artist; r.album = f.album; r.art = f.art
            r.volume = f.volume; r.muted = f.muted; r.isTV = f.isTV
            return r
        }
        if next != speakers { speakers = next; onChange?() }
    }

    /// Runs [op] and refreshes the room straight after, so the tile answers at once.
    public func sonos(_ room: SonosRoom, _ op: @escaping @Sendable (SonosRoom) async throws -> Void) async {
        lastSpeakerID = room.id
        do { try await op(room) } catch {}
        try? await Task.sleep(nanoseconds: 300_000_000)
        await refreshSpeakers()
    }

    public func setVolume(_ room: SonosRoom, _ v: Int) {
        if let i = speakers.firstIndex(where: { $0.id == room.id }) { speakers[i].volume = v }
        Task { try? await Sonos.setVolume(room, v) }
    }

    // MARK: Govee

    /// Addresses of lights added by hand, asked directly on every search.
    public private(set) var manualIPs: [String] = Saved.load("goveeManualIPs", as: [String].self) ?? []

    private func scanLights() {
        #if canImport(Network)
        lan.scan(extra: manualIPs)
        #endif
    }

    /// Reads names, rooms and hand-added lights again (after another device of the family's changed them).
    public func reloadSaved() {
        let n = Saved.load("smartNames", as: [String: String].self) ?? [:]
        if n != names { names = n }
        let r = Saved.load("smartRooms", as: [String: String].self) ?? [:]
        if r != rooms { rooms = r }
        let x = Saved.load("smartExtraRooms", as: [String].self) ?? []
        if x != extraRooms { extraRooms = x }
        manualIPs = Saved.load("goveeManualIPs", as: [String].self) ?? []
    }

    /// Searches the Wi‑Fi for lights again now.
    public func searchLights() { scanLights() }

    /// Adds a light by its address (from your router or the Govee app), for one that doesn't answer the search.
    public func addLight(ip: String) {
        let ip = ip.trimmingCharacters(in: .whitespaces)
        guard ip.split(separator: ".").count == 4 else { goveeError = "That doesn’t look like an address (like 192.168.1.42)."; return }
        if !manualIPs.contains(ip) { manualIPs.append(ip); Saved.save("goveeManualIPs", manualIPs) }
        #if canImport(Network)
        lan.probe(ip)
        #endif
    }

    private func pollLights() {
        #if canImport(Network)
        for l in lights { if let ip = l.ip { lan.status(ip) } }
        #endif
    }

    /// Every light that answered the search, by address: what it says it is (shown in Settings → Lights).
    public private(set) var answers: [LightAnswer] = []

    private func found(ip: String, id: String, sku: String) {
        answers.removeAll { $0.ip == ip }
        answers.append(LightAnswer(ip: ip, device: id, sku: sku, at: Date()))
        answers.sort { $0.ip.localizedStandardCompare($1.ip) == .orderedAscending }
        defer {
            lights.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            persist()
            #if canImport(Network)
            lan.status(ip)
            #endif
        }
        // Already known at this address (this lamp, or its twin split off below).
        if lights.contains(where: { $0.ip == ip && ($0.id == id || $0.id.hasPrefix(id + "@")) }) { return }
        // Addresses move; a light that used to have this one no longer does.
        for i in lights.indices where lights[i].ip == ip { lights[i].ip = nil }
        if let i = lights.firstIndex(where: { $0.id == id }) {
            // Two lamps answering with the same device ID from different addresses (some Govee lamps sold in
            // pairs do): they're still two lamps, each controlled at its own address.
            if let other = lights[i].ip, other != ip,
               answers.contains(where: { $0.ip == other && $0.device == id && $0.at.timeIntervalSinceNow > -180 }) {
                let twin = id + "@" + ip
                if let j = lights.firstIndex(where: { $0.id == twin }) { lights[j].ip = ip }
                else if let j = lights.firstIndex(where: { $0.id.hasPrefix(id + "@") && $0.ip == nil }) { lights[j].ip = ip }
                else { lights.append(GoveeLight(id: twin, sku: sku, name: names[twin] ?? "\(Govee.product(sku)) 2", ip: ip, cloud: false)) }
            } else {
                lights[i].ip = ip
            }
        } else if let j = lights.firstIndex(where: { $0.id.hasPrefix(id + "@") && $0.ip == nil }) {
            lights[j].ip = ip
        } else {
            lights.append(GoveeLight(id: id, sku: sku, name: names[id] ?? Govee.product(sku), ip: ip, cloud: false))
        }
    }

    private func status(ip: String, on: Bool, brightness: Int, color: LightColor?, kelvin: Int?) {
        guard let i = lights.firstIndex(where: { $0.ip == ip }) else { return }
        lights[i].on = on; lights[i].brightness = brightness
        if let color, color != LightColor(r: 0, g: 0, b: 0) { lights[i].color = color }
        lights[i].kelvin = kelvin
        onChange?()
    }

    public func refreshCloud() async {
        guard let key = goveeKey, !key.isEmpty else { goveeError = nil; return }
        do {
            // Govee's current API lists every model; the original one only older ones.
            var devs = (try? await Govee.openDevices(key: key)) ?? []
            var open = !devs.isEmpty
            if devs.isEmpty { devs = try await Govee.cloudDevices(key: key); open = false }
            goveeError = nil
            for d in devs {
                if let i = lights.firstIndex(where: { $0.id == d.id }) {
                    lights[i].cloud = true
                    lights[i].sku = d.sku
                    if names[d.id] == nil { lights[i].name = d.name }
                } else {
                    var l = d
                    if let n = names[d.id] { l.name = n }
                    lights.append(l)
                }
            }
            // Lights not answering on the Wi‑Fi: their state comes from Govee.
            for i in lights.indices where lights[i].cloud && lights[i].ip == nil {
                lights[i] = open ? await Govee.openState(lights[i], key: key) : await Govee.cloudState(lights[i], key: key)
            }
            lights.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            persist()
        } catch { goveeError = error.localizedDescription }
    }

    private func applyNames() {
        for i in lights.indices {
            if let n = names[lights[i].id], !n.isEmpty { lights[i].name = n }
            else if lights[i].name == "Govee \(lights[i].sku)" { lights[i].name = Govee.product(lights[i].sku) }
        }
        for i in speakers.indices { if let n = names[speakers[i].id], !n.isEmpty { speakers[i].name = n } }
    }

    /// Turns a light on or off: on the LAN when it's there, else through Govee's cloud.
    public func setOn(_ l: GoveeLight, _ on: Bool) {
        update(l) { $0.on = on }
        if l.isHome { homeControl?(l, .power(on)); return }
        #if canImport(Network)
        if let ip = l.ip { lan.turn(ip, on); return }
        #endif
        cloud(l, "turn", on ? "on" : "off")
    }

    public func setBrightness(_ l: GoveeLight, _ v: Int) {
        update(l) { $0.brightness = v; $0.on = true }
        if l.isHome { homeControl?(l, .brightness(v)); return }
        #if canImport(Network)
        if let ip = l.ip { lan.brightness(ip, v); return }
        #endif
        cloud(l, "brightness", v)
    }

    public func setColor(_ l: GoveeLight, _ c: LightColor) {
        update(l) { $0.color = c; $0.kelvin = nil; $0.on = true }
        if l.isHome { homeControl?(l, .color(c)); return }
        #if canImport(Network)
        if let ip = l.ip { lan.color(ip, c); return }
        #endif
        cloud(l, "color", ["r": c.r, "g": c.g, "b": c.b])
    }

    public func setWhite(_ l: GoveeLight, kelvin: Int) {
        update(l) { $0.kelvin = kelvin; $0.color = nil; $0.on = true }
        if l.isHome { homeControl?(l, .kelvin(kelvin)); return }
        #if canImport(Network)
        if let ip = l.ip { lan.kelvin(ip, kelvin); return }
        #endif
        cloud(l, "colorTem", kelvin)
    }

    private func update(_ l: GoveeLight, _ f: (inout GoveeLight) -> Void) {
        if let i = lights.firstIndex(where: { $0.id == l.id }) { f(&lights[i]); onChange?() }
    }

    private func cloud(_ l: GoveeLight, _ name: String, _ value: Any) {
        guard let key = goveeKey, !key.isEmpty, l.cloud else { goveeError = "Turn on LAN Control for \(l.name) in the Govee app, or add a Govee API key."; return }
        // Govee's current API first; the original one if this key only works there.
        let open: (String, String, Int)?
        switch name {
        case "turn": open = ("devices.capabilities.on_off", "powerSwitch", (value as? String) == "on" ? 1 : 0)
        case "brightness": open = ("devices.capabilities.range", "brightness", value as? Int ?? 100)
        case "color":
            let c = value as? [String: Int] ?? [:]
            open = ("devices.capabilities.color_setting", "colorRgb", ((c["r"] ?? 0) << 16) | ((c["g"] ?? 0) << 8) | (c["b"] ?? 0))
        case "colorTem": open = ("devices.capabilities.color_setting", "colorTemperatureK", value as? Int ?? 4000)
        default: open = nil
        }
        let body = Govee.cloudBody(l, name: name, value: value)
        Task {
            do {
                if let o = open {
                    do { try await Govee.openControl(l, key: key, type: o.0, instance: o.1, value: o.2); return } catch {}
                }
                try await Govee.cloudControl(key: key, body: body)
            } catch { goveeError = error.localizedDescription }
        }
    }
}
