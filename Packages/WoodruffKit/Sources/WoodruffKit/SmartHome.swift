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
    /// Set when the speaker has stopped answering (unplugged, off the Wi‑Fi); cleared the moment it answers
    /// again. Optional so rooms saved before this existed still load.
    public var unreachableSince: Date? = nil
    public var isOffline: Bool { unreachableSince != nil }
    public var isPlaying: Bool { !isOffline && (state == "PLAYING" || state == "TRANSITIONING") }
    public var isPaused: Bool { !isOffline && state == "PAUSED_PLAYBACK" }
    public var isCoordinator: Bool { host == coordinatorHost }
    /// Something is loaded that Play can start (not an empty queue).
    public var canPlay: Bool { !isOffline && state != "NO_MEDIA_PRESENT" && (isPlaying || isTV || !(title ?? "").isEmpty) }
    /// A soundbar with surrounds or a Sub (a stereo pair, even with a Sub, isn't one).
    public var isHomeTheater: Bool {
        parts.contains { $0.role == .front } && parts.contains { $0.role == .sub || $0.role == .leftRear || $0.role == .rightRear }
    }
    /// A soundbar (or Amp) with a TV input.
    public var hasTVInput: Bool {
        if isHomeTheater || isTV { return true }
        let m = (model ?? "").lowercased()
        return ["arc", "beam", "ray", "playbar", "playbase", "amp"].contains { m.contains($0) }
    }
    /// "Playing", "Paused", "Stopped", "Offline"… for the tile and lists.
    public var stateName: String {
        if isOffline { return "Offline" }
        switch state {
        case "PLAYING": return "Playing"
        case "TRANSITIONING": return "Starting"
        case "PAUSED_PLAYBACK": return "Paused"
        case "STOPPED": return "Stopped"
        default: return "Not Playing"
        }
    }
    /// "Arc · Sub · 2 Surrounds", or "Era 100 Stereo Pair".
    public var setupSummary: String? {
        guard parts.count > 1 else { return nil }
        if !isHomeTheater {
            let pair = "\(model ?? "Stereo") Pair"
            return parts.contains(where: { $0.role == .sub }) ? pair + " · Sub" : pair
        }
        var bits = [model ?? "Soundbar"]
        if parts.contains(where: { $0.role == .sub }) { bits.append("Sub") }
        let rears = parts.filter { $0.role == .leftRear || $0.role == .rightRear }.count
        if rears > 0 { bits.append(rears == 1 ? "Surround" : "\(rears) Surrounds") }
        return bits.joined(separator: " · ")
    }
}

/// One answer to asking a room for its state: whether the speaker itself answered, and whether its group's
/// leader answered for what's playing.
public struct SonosPoll: Sendable {
    public var room: SonosRoom
    public var answered: Bool
    public var transportAnswered: Bool
}

/// A speaker that answered with the household's rooms.
struct SonosFound: Sendable {
    var host: String
    var rooms: [SonosRoom]
}

/// Why a Sonos command didn't work.
public enum SonosError: LocalizedError, Sendable {
    case refused(Int?)
    case badAddress
    public var errorDescription: String? {
        switch self {
        case .refused(let c?) where c == 701: return "That isn't available right now."
        case .refused: return "The speaker said no."
        case .badAddress: return "The speaker's address isn't valid."
        }
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
        guard !host.isEmpty, let url = URL(string: "http://\(host):1400\(path)") else { throw SonosError.badAddress }
        var r = URLRequest(url: url, timeoutInterval: 4)
        r.httpMethod = "POST"
        r.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        r.setValue("\"urn:schemas-upnp-org:service:\(service):1#\(action)\"", forHTTPHeaderField: "SOAPACTION")
        let body = args.map { "<\($0.0)>\(escape($0.1))</\($0.0)>" }.joined()
        r.httpBody = Data("""
        <?xml version="1.0" encoding="utf-8"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:\(action) xmlns:u="urn:schemas-upnp-org:service:\(service):1">\(body)</u:\(action)></s:Body></s:Envelope>
        """.utf8)
        let (d, resp) = try await URLSession.shared.data(for: r)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            // A UPnP fault names its reason by number (701: not possible right now, e.g. Next on the TV input).
            throw SonosError.refused(Int(tag("errorCode", in: String(decoding: d, as: UTF8.self)) ?? ""))
        }
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
    public static func pause(_ r: SonosRoom) async throws {
        do {
            _ = try await transport(r.coordinatorHost, "Pause")
        } catch SonosError.refused(let code) where code == 701 {
            // The TV's sound, line-in and some radio streams can't pause ("transition not available"): stopping
            // is what pausing means there, and Play starts them again.
            _ = try await transport(r.coordinatorHost, "Stop")
        }
    }

    /// Whether a state a speaker reports is the one asked for (starting counts as playing, stopped as paused).
    static func sameState(_ reported: String, _ asked: String) -> Bool {
        let playing: Set<String> = ["PLAYING", "TRANSITIONING"]
        if playing.contains(asked) { return playing.contains(reported) }
        if asked == "PAUSED_PLAYBACK" || asked == "STOPPED" { return reported == "PAUSED_PLAYBACK" || reported == "STOPPED" }
        return reported == asked
    }
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
            // Every speaker's address in the group, invisible ones too (the second of an older stereo pair).
            var known: [String: String] = [:]
            for m in all { if let u = attr("UUID", in: openTag(m)), let h = hostOf(openTag(m)) { known[u] = h } }
            guard let ch = known[coord] else { continue }
            let names = members.compactMap { attr("ZoneName", in: openTag($0)) }
            for m in members {
                let head = openTag(m)
                guard let id = attr("UUID", in: head), let h = hostOf(head), let name = attr("ZoneName", in: head) else { continue }
                var room = SonosRoom(id: id, name: name, zone: name, host: h, coordinatorHost: ch, groupNames: names)
                room.coordinatorID = coord
                room.parts = parts(member: m, id: id, host: h, known: known)
                out.append(room)
            }
        }
        return out.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The speakers in one room, from its channel map ("RINCON_A:LF,RF;RINCON_B:SW;RINCON_C:LR;RINCON_D:RR").
    static func parts(member m: String, id: String, host: String, known: [String: String] = [:]) -> [SonosPart] {
        let head = openTag(m)
        var hosts = known
        hosts[id] = host
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
            // A soundbar is "LF,RF"; one side alone is half of a stereo pair (with or without a Sub).
            else if chans == ["LF"] { role = .left }
            else if chans == ["RF"] { role = .right }
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
        guard let url = URL(string: "http://\(host):1400/xml/device_description.xml") else { return nil }
        var r = URLRequest(url: url, timeoutInterval: 4)
        r.httpMethod = "GET"
        guard let answer = try? await URLSession.shared.data(for: r) else { return nil }
        let xml = String(decoding: answer.0, as: UTF8.self)
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
        // The TV's sound plays by itself once it's chosen; Play is only a nudge, and a soundbar that turns it down
        // (the TV sending nothing yet) has still switched, so that isn't a failure.
        _ = try? await transport(r.host, "Play", [("Speed", "1")])
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
    public static func refresh(_ r: SonosRoom) async -> SonosRoom { await poll(r, leader: true).room }

    /// Just a room's own volume and mute (what's playing comes from its group's leader).
    public static func levels(_ r: SonosRoom) async -> SonosRoom { await poll(r, leader: false).room }

    /// Asks a room for its volume and mute, and (as its group's leader) what the group is playing, saying
    /// which parts got an answer so a speaker that's gone quiet isn't mistaken for one still playing.
    public static func poll(_ r: SonosRoom, leader: Bool) async -> SonosPoll {
        var r = r
        var transportOK = false
        if leader {
            if let t = try? await transport(r.coordinatorHost, "GetTransportInfo") {
                transportOK = true
                r.state = tag("CurrentTransportState", in: t) ?? r.state
            }
            if transportOK, let p = try? await transport(r.coordinatorHost, "GetPositionInfo") {
                let meta = unescape(tag("TrackMetaData", in: p) ?? "")
                let uri = tag("TrackURI", in: p) ?? ""
                r.isTV = uri.hasPrefix("x-sonos-htastream")
                r.title = tag("dc:title", in: meta).map(unescape)
                r.artist = tag("dc:creator", in: meta).map(unescape)
                r.album = tag("upnp:album", in: meta).map(unescape)
                if let a = tag("upnp:albumArtURI", in: meta).map(unescape), !a.isEmpty {
                    r.art = a.hasPrefix("http") ? URL(string: a) : URL(string: "http://\(r.coordinatorHost):1400\(a)")
                } else { r.art = nil }
                // Radio streams put the station in the title and the song in streamContent.
                if let stream = tag("r:streamContent", in: meta).map(unescape), !stream.isEmpty { r.artist = r.title; r.title = stream }
                if r.isTV { r.title = "TV"; r.artist = nil; r.album = nil; r.art = nil }
                else if uri.hasPrefix("x-rincon-stream:") && (r.title ?? "").isEmpty { r.title = "Line-In" }
                // An empty queue: nothing loaded, whatever the last track was.
                if r.state == "NO_MEDIA_PRESENT" { r.title = nil; r.artist = nil; r.album = nil; r.art = nil }
            }
            // The leader is this speaker and it didn't answer: don't wait twice more for it.
            if !transportOK && r.host == r.coordinatorHost { return SonosPoll(room: r, answered: false, transportAnswered: false) }
        }
        var answered = false
        if let v = try? await rendering(r.host, "GetVolume") {
            answered = true
            r.volume = Int(tag("CurrentVolume", in: v) ?? "") ?? r.volume
            if let m = try? await rendering(r.host, "GetMute") { r.muted = tag("CurrentMute", in: m) == "1" }
        }
        if answered { r.unreachableSince = nil }   // it answered: it is there after all
        return SonosPoll(room: r, answered: answered, transportAnswered: transportOK)
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
    /// True when it can't be reached right now (unplugged, off at the wall, off the Wi‑Fi). Optional so lights
    /// saved before this existed still load.
    public var offline: Bool? = nil
    /// The white temperatures it takes, in kelvin (from Govee's account API when known).
    public var kelvinMin: Int? = nil
    public var kelvinMax: Int? = nil
    public var isHome: Bool { source == "home" }
    public var isOffline: Bool { offline == true }
    /// Lit, as far as anyone can tell (an unreachable light isn't shown as on).
    public var isLit: Bool { on && !isOffline }
    /// A white temperature this light accepts.
    public func clampKelvin(_ k: Int) -> Int {
        let lo = kelvinMin ?? 2000, hi = max(lo, kelvinMax ?? 9000)
        return max(lo, min(hi, k))
    }

    public init(id: String, sku: String, name: String, ip: String? = nil, cloud: Bool = false, on: Bool = false,
                brightness: Int = 100, color: LightColor? = nil, kelvin: Int? = nil, source: String? = nil, zone: String? = nil,
                offline: Bool? = nil) {
        self.id = id; self.sku = sku; self.name = name; self.ip = ip; self.cloud = cloud; self.on = on
        self.brightness = brightness; self.color = color; self.kelvin = kelvin; self.source = source; self.zone = zone
        self.offline = offline
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
            let all = d["capabilities"] as? [[String: Any]] ?? []
            let caps = all.compactMap { $0["type"] as? String }
            guard caps.contains("devices.capabilities.on_off") else { return nil }
            let name = (d["deviceName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? product(sku)
            var l = GoveeLight(id: id, sku: sku, name: name, ip: nil, cloud: true)
            // The white temperatures this model takes (they differ: 2000–9000 K, 2700–6500 K…).
            if let ct = all.first(where: { $0["instance"] as? String == "colorTemperatureK" }),
               let range = (ct["parameters"] as? [String: Any])?["range"] as? [String: Any],
               let lo = (range["min"] as? NSNumber)?.intValue, let hi = (range["max"] as? NSNumber)?.intValue, lo > 0, hi >= lo {
                l.kelvinMin = lo
                l.kelvinMax = hi
            }
            return l
        }
    }

    public static func openState(_ l: GoveeLight, key: String) async -> GoveeLight {
        var l = l
        guard let j = try? await open("/device/state", key: key, body: ["requestId": UUID().uuidString, "payload": ["sku": l.sku, "device": l.id]]),
              let caps = (j["payload"] as? [String: Any])?["capabilities"] as? [[String: Any]] else { return l }
        var rgb: LightColor?
        var kelvin: Int?
        for c in caps {
            let v = (c["state"] as? [String: Any])?["value"]
            switch c["instance"] as? String {
            case "online":
                // Govee's own word on whether the light is connected (unplugged lamps say false).
                if let b = v as? Bool { l.offline = !b } else if let s = v as? String { l.offline = s.lowercased() != "true" }
            case "powerSwitch": if let n = v as? NSNumber { l.on = n.intValue == 1 }
            case "brightness": if let n = v as? NSNumber, n.intValue > 0 { l.brightness = min(100, n.intValue) }
            case "colorRgb":
                if let n = (v as? NSNumber)?.intValue, n > 0 { rgb = LightColor(r: (n >> 16) & 255, g: (n >> 8) & 255, b: n & 255) }
            case "colorTemperatureK": if let n = (v as? NSNumber)?.intValue, n > 0 { kelvin = n }
            default: break
            }
        }
        // White (a temperature) or a colour, never both: Govee keeps the last colour while in white.
        if let kelvin { l.kelvin = kelvin; l.color = nil } else if let rgb { l.color = rgb; l.kelvin = nil }
        return l
    }

    static func openControl(_ l: GoveeLight, key: String, type: String, instance: String, value: Int) async throws {
        _ = try await open("/device/control", key: key, body: [
            "requestId": UUID().uuidString,
            "payload": ["sku": l.sku, "device": l.id, "capability": ["type": type, "instance": instance, "value": value]],
        ])
    }

    /// Carries out one change through Govee's cloud: the current Open API, else the original one (older keys).
    static func control(_ l: GoveeLight, key: String, _ c: LightCommand) async throws {
        let type: String, instance: String, value: Int
        let legacy: Data
        switch c {
        case .power(let on):
            type = "devices.capabilities.on_off"; instance = "powerSwitch"; value = on ? 1 : 0
            legacy = cloudBody(l, name: "turn", value: on ? "on" : "off")
        case .brightness(let v):
            let v = max(1, min(100, v))
            type = "devices.capabilities.range"; instance = "brightness"; value = v
            legacy = cloudBody(l, name: "brightness", value: v)
        case .color(let rgb):
            let r = max(0, min(255, rgb.r)), g = max(0, min(255, rgb.g)), b = max(0, min(255, rgb.b))
            type = "devices.capabilities.color_setting"; instance = "colorRgb"; value = (r << 16) | (g << 8) | b
            legacy = cloudBody(l, name: "color", value: ["r": r, "g": g, "b": b])
        case .kelvin(let k):
            let k = l.clampKelvin(k)
            type = "devices.capabilities.color_setting"; instance = "colorTemperatureK"; value = k
            legacy = cloudBody(l, name: "colorTem", value: k)
        }
        do {
            try await openControl(l, key: key, type: type, instance: instance, value: value)
        } catch let first {
            // A key made for the original API only works there; if that fails too, say what the current one said.
            do { try await cloudControl(key: key, body: legacy) } catch { throw first }
        }
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
        guard let answer = try? await URLSession.shared.data(for: r),
              let v = try? JSONDecoder().decode(JSONValue.self, from: answer.0) else { return l }
        var rgb: LightColor?
        var kelvin: Int?
        for p in v["data"]?["properties"]?.array ?? [] {
            if let o = p["online"] { l.offline = !(o.bool ?? (o.string?.lowercased() == "true")) }
            if let s = p["powerState"]?.string { l.on = s == "on" }
            if let b = p["brightness"]?.int, b > 0 { l.brightness = min(100, b) }
            if let c = p["color"], let r = c["r"]?.int, let g = c["g"]?.int, let b = c["b"]?.int, r + g + b > 0 { rgb = LightColor(r: r, g: g, b: b) }
            if let k = p["colorTem"]?.int, k > 0 { kelvin = k }
        }
        if let kelvin { l.kelvin = kelvin; l.color = nil } else if let rgb { l.color = rgb; l.kelvin = nil }
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
    /// Each light's own channel to us; closed with the listener so none are left open.
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    var onScan: ((String, String, String) -> Void)?          // ip, device id, sku
    var onStatus: ((String, Bool, Int, LightColor?, Int?) -> Void)? // ip, on, brightness, color, kelvin

    func start() {
        guard listener == nil, let port = NWEndpoint.Port(rawValue: 4002) else { return }
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        guard let l = try? NWListener(using: params, on: port) else { return }
        l.newConnectionHandler = { [weak self] c in
            MainActor.assumeIsolated {
                guard let self else { c.cancel(); return }
                let key = ObjectIdentifier(c)
                self.connections[key] = c
                c.stateUpdateHandler = { [weak self] st in
                    switch st {
                    case .failed, .cancelled: MainActor.assumeIsolated { _ = self?.connections.removeValue(forKey: key) }
                    default: break
                    }
                }
                c.start(queue: .main)
                self.receive(c)
            }
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
        for c in connections.values { c.cancel() }
        connections.removeAll()
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

    /// A change to an Apple Home light that didn't go through: say so where the lights are, and stop holding
    /// what was asked so the light shows how it really is.
    public func homeControlFailed(_ id: String, _ message: String) {
        held[id] = nil
        goveeError = message
        homeError = message
    }

    /// A change to an Apple Home light went through: clear an earlier Apple Home failure.
    public func homeControlSucceeded() {
        if let e = homeError, goveeError == e { goveeError = nil }
        homeError = nil
    }
    @ObservationIgnored private var homeError: String?

    /// The lights in Apple Home (Cync and other Matter lights), from the iPhone app.
    public func setHomeLights(_ list: [GoveeLight]) {
        var next = lights.filter { !$0.isHome }
        for var l in list {
            if let n = names[l.id], !n.isEmpty { l.name = n }
            // A value read before a change just made lands here too; keep what was asked for a moment.
            l = holding(l)
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
        speakers.first { $0.id == lastSpeakerID } ?? speakers.first(where: \.isPlaying) ?? speakers.first { !$0.isOffline } ?? speakers.first
    }

    public func speaker(_ id: String) -> SonosRoom? { speakers.first { $0.id == id } }
    public func light(_ id: String) -> GoveeLight? { lights.first { $0.id == id } }

    public func allLights(_ on: Bool) { for l in lights where l.on != on && !l.isOffline { setOn(l, on) } }


    public func start() {
        guard loop == nil, !Demo.isOn else { return }
        // Lamps remembered from last time get `lanTimeout` to answer (even away, when nobody asks them).
        let now = Date()
        for l in lights where l.ip != nil { lastSeen[l.id] = now }
        #if canImport(Network)
        lan.onScan = { [weak self] ip, id, sku in self?.found(ip: ip, id: id, sku: sku) }
        lan.onStatus = { [weak self] ip, on, b, c, k in self?.status(ip: ip, on: on, brightness: b, color: c, kelvin: k) }
        lan.start()
        browseSonos()
        #endif
        // One round every 2.5 seconds. What's playing is asked every round while music plays (a new song shows
        // within a moment) and every other round when nothing is; the lamps every other round.
        loop = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                guard let self else { return }
                // Away from home nothing on this network is ours: no searching, and the speakers less often.
                let away = Fleet.shared.probablyAway
                // The slow ones (the household's rooms, Govee's cloud) run beside the rounds, never holding them up.
                let first = tick == 0
                if tick % 120 == 0 {
                    Task {
                        await self.findSonos()
                        if first { await self.refreshSpeakers() }
                    }
                }
                if tick % 48 == 0 { Task { await self.refreshCloud() } }
                // Ask for lights a few times early on (UDP answers can get lost), then every five minutes.
                if !away, [0, 2, 6, 12, 24].contains(tick) || tick % 120 == 0 { self.scanLights() }
                let playing = self.speakers.contains(where: \.isPlaying)
                let speakersDue = away ? tick % 12 == 0 : (playing || tick % 2 == 0)
                if speakersDue { await self.refreshSpeakers() }
                if !away && tick % 2 == 0 { self.pollLights() }
                self.checkReachable()
                tick += 1
                try? await Task.sleep(nanoseconds: 2_500_000_000)
            }
        }
    }

    /// The app came back to the front: listen afresh and ask everything for its state straight away.
    public func wake() {
        guard loop != nil else { return }
        #if canImport(Network)
        lan.restart()
        #endif
        // Nothing answered while the app was asleep; give the lamps a moment before calling them offline.
        let now = Date()
        for l in lights where l.ip != nil { lastSeen[l.id] = max(lastSeen[l.id] ?? .distantPast, now.addingTimeInterval(-lanTimeout + 15)) }
        Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            pollLights()
            askOfflineSpeakers = true
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
        let mine = ObjectIdentifier(b)
        b.stateUpdateHandler = { [weak self] state in
            guard case .failed = state else { return }
            // Delivered on the main queue (started there below). The network changed, or the system let it go
            // while the app was away: it used to stay stopped for good. Browse again in a moment.
            MainActor.assumeIsolated {
                guard let self, let current = self.browser, ObjectIdentifier(current) == mine else { return }
                current.cancel()
                self.browser = nil
                Task {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    if self.browser == nil { self.browseSonos() }
                }
            }
        }
        b.start(queue: .main)
        browser = b
    }
    #endif

    private func seed(_ host: String) {
        guard !host.contains(":") else { return }
        // Each speaker announces itself; only a new address (or none known yet) is worth asking for the rooms.
        if sonosSeed == nil || speakers.isEmpty || (sonosSeed != host && !knownSonosHosts.contains(host)) {
            useSeed(host)
            // Rooms just found have no state yet: ask them what they're playing straight away.
            Task {
                await findSonos()
                await refreshSpeakers()
            }
        }
    }

    /// Every address our speakers had last time (rooms, and their Subs and surrounds).
    private var knownSonosHosts: [String] {
        var out: [String] = []
        for r in speakers {
            if !out.contains(r.host) { out.append(r.host) }
            for p in r.parts { if let h = p.host, !out.contains(h) { out.append(h) } }
        }
        return out
    }

    private func useSeed(_ host: String) {
        sonosSeed = host
        UserDefaults.standard.set(host, forKey: "sonosSeed")
    }

    @ObservationIgnored private var finding: Task<Void, Never>?

    /// The household's rooms, from the last speaker that answered (or by asking the network on port 1400). One
    /// search at a time: a second call waits for the one already looking.
    public func findSonos() async {
        if let running = finding { await running.value; return }
        await runFind()
    }

    private func runFind() async {
        let t = Task { await self.findSonosNow() }
        finding = t
        await t.value
        if finding == t { finding = nil }
    }

    /// After a change to the groups: a search already under way began before it, so look again once it's done.
    private func findSonosAfterChange() async {
        if let running = finding { await running.value }
        if let running = finding { await running.value; return }   // a newer one started meanwhile
        await runFind()
    }

    private func findSonosNow() async {
        if let s = sonosSeed, let rooms = try? await Sonos.rooms(from: s), !rooms.isEmpty { merge(rooms); return }
        // The saved speaker is off or has a new address (DHCP): any other one we know lists the household too.
        let others = knownSonosHosts.filter { $0 != sonosSeed }
        if !others.isEmpty {
            let got: SonosFound? = await withTaskGroup(of: SonosFound?.self) { g in
                for h in others {
                    g.addTask {
                        guard let rooms = try? await Sonos.rooms(from: h), !rooms.isEmpty else { return nil }
                        return SonosFound(host: h, rooms: rooms)
                    }
                }
                for await r in g { if let r { g.cancelAll(); return r } }
                return nil
            }
            if let got {
                useSeed(got.host)
                merge(got.rooms)
                return
            }
        }
        guard !Fleet.shared.probablyAway else { return }
        #if canImport(Darwin)
        let hosts = LANScan.prefixes().flatMap { p in (1...254).map { p + String($0) } }
        let found: String? = await withTaskGroup(of: String?.self) { g in
            for h in hosts {
                g.addTask {
                    guard let url = URL(string: "http://\(h):1400/xml/device_description.xml") else { return nil }
                    var r = URLRequest(url: url, timeoutInterval: 1.5)
                    r.httpMethod = "HEAD"
                    guard let answer = try? await URLSession.shared.data(for: r),
                          (answer.1 as? HTTPURLResponse)?.statusCode == 200 else { return nil }
                    return h
                }
            }
            for await h in g { if let h { g.cancelAll(); return h } }
            return nil
        }
        if let h = found, let rooms = try? await Sonos.rooms(from: h), !rooms.isEmpty {
            useSeed(h)
            merge(rooms)
        }
        #endif
    }

    private func merge(_ rooms: [SonosRoom]) {
        var next = rooms.map { r -> SonosRoom in
            var r = r
            if let n = names[r.id], !n.isEmpty { r.name = n }
            r.groupNames = r.groupNames.map { g in rooms.first { $0.zone == g }.flatMap { names[$0.id] } ?? g }
            if let old = speakers.first(where: { $0.id == r.id }) {
                r.state = old.state; r.title = old.title; r.artist = old.artist; r.album = old.album; r.art = old.art
                r.volume = old.volume; r.muted = old.muted; r.isTV = old.isTV; r.model = old.model
                for i in r.parts.indices { r.parts[i].model = old.parts.first { $0.id == r.parts[i].id }?.model }
                // Still quiet at the same address stays offline; at a new address it's asked afresh.
                if old.host == r.host { r.unreachableSince = old.unreachableSince } else { sonosMisses[r.id] = 0 }
            }
            return r
        }
        // A speaker that has dropped out of the household's list (unplugged a while) stays, shown offline, for a
        // few hours, unless it's now part of another room (made a surround, or half of a stereo pair).
        let listed = Set(next.map(\.id) + next.flatMap { $0.parts.map(\.id) })
        var kept = false
        for old in speakers where !listed.contains(old.id) {
            let since = old.unreachableSince ?? Date()
            guard since.timeIntervalSinceNow > -6 * 3600 else { continue }
            var o = old
            o.unreachableSince = since
            o.state = ""; o.title = nil; o.artist = nil; o.album = nil; o.art = nil; o.isTV = false
            o.coordinatorHost = o.host; o.coordinatorID = o.id; o.groupNames = [o.name]
            next.append(o)
            kept = true
        }
        if kept { next.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
        speakers = next
        persist()
        Task { await fillModels() }
    }

    /// Asks each speaker once what it is ("Arc", "Sub", "Era 100").
    private func fillModels() async {
        for r in speakers where !r.isOffline {
            if r.model == nil, let m = await Sonos.model(r.host), let i = speakers.firstIndex(where: { $0.id == r.id }) {
                speakers[i].model = m
            }
            for p in r.parts where p.model == nil {
                guard let h = p.host, let m = await Sonos.model(h),
                      let i = speakers.firstIndex(where: { $0.id == r.id }),
                      let j = speakers[i].parts.firstIndex(where: { $0.id == p.id }) else { continue }
                speakers[i].parts[j].model = m
            }
        }
        persist()
    }

    /// Rebuilds the rooms after grouping changes (a failure is shown on the room [id]).
    public func regroup(_ id: String? = nil, _ op: @escaping @Sendable () async throws -> Void) async {
        do { try await op() } catch { if let id, let r = speaker(id) { report(r, error) } }
        try? await Task.sleep(nanoseconds: 600_000_000)
        // Never the answer of a search that began before the change (it would show the old groups).
        await findSonosAfterChange()
        await refreshSpeakers()
        // Sonos can take a moment longer to settle which speaker leads the group.
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await self.findSonosAfterChange()
            await self.refreshSpeakers()
        }
    }

    /// Unanswered asks in a row, per room and per group leader (by address).
    @ObservationIgnored private var sonosMisses: [String: Int] = [:]
    @ObservationIgnored private var leaderMisses: [String: Int] = [:]
    /// When a command last went to a group (by its leader's address) or a room's volume or mute (by id): a
    /// refresh that began before then carries an older answer and mustn't undo it.
    @ObservationIgnored private var transportAt: [String: Date] = [:]
    @ObservationIgnored private var levelsAt: [String: Date] = [:]
    /// When the refresh whose answer was last used began, per room and per group leader (by address): refreshes
    /// overlap (one after a command, the regular one), and an older one that answers last never puts back what
    /// it saw over a newer answer.
    @ObservationIgnored private var polledAt: [String: Date] = [:]
    @ObservationIgnored private var leaderPolledAt: [String: Date] = [:]
    /// What a command just asked a group to do (by its leader's address): kept on screen until the speaker says
    /// the same or a few seconds pass, so one that's a moment slow to switch doesn't flick back to the old state.
    @ObservationIgnored private var expected: [String: (state: String, until: Date)] = [:]
    @ObservationIgnored private var refreshCount = 0
    /// Ask the offline speakers too on the next refresh (the app just came back to the front).
    @ObservationIgnored private var askOfflineSpeakers = false
    @ObservationIgnored private var lastRediscovery = Date.distantPast

    public func refreshSpeakers() async {
        guard !speakers.isEmpty else { return }
        let started = Date()
        refreshCount += 1
        // An offline speaker is asked about every sixth time (each ask waits out a timeout).
        let askAll = askOfflineSpeakers || refreshCount % 6 == 1
        askOfflineSpeakers = false
        let current = speakers.filter { !$0.isOffline || askAll }
        guard !current.isEmpty else { return }
        // What's playing is asked once per group (of its leader); each room only for its own volume.
        var leaders: [String: SonosRoom] = [:]
        for r in current where leaders[r.coordinatorHost] == nil || r.isCoordinator { leaders[r.coordinatorHost] = r }
        let leaderIDs = Set(leaders.values.map(\.id))
        let polls: [SonosPoll] = await withTaskGroup(of: SonosPoll.self) { g in
            for r in current { g.addTask { await Sonos.poll(r, leader: leaderIDs.contains(r.id)) } }
            var out: [SonosPoll] = []
            for await p in g { out.append(p) }
            return out
        }
        let byID = Dictionary(polls.map { ($0.room.id, $0) }, uniquingKeysWith: { a, _ in a })
        var playing: [String: SonosRoom] = [:]
        for p in polls where leaderIDs.contains(p.room.id) {
            let h = p.room.coordinatorHost
            // A refresh that began later has already heard from this leader.
            guard (leaderPolledAt[h] ?? .distantPast) <= started else { continue }
            leaderPolledAt[h] = started
            if p.transportAnswered { playing[h] = p.room; leaderMisses[h] = 0 } else { leaderMisses[h, default: 0] += 1 }
        }
        let held = Set(pendingVolume.filter { $0.value.timeIntervalSinceNow > -2.5 }.keys)
        let now = Date()
        // Only the playing state comes from the refresh; names, models and parts may have changed meanwhile.
        var next = speakers
        var lost = false
        for i in next.indices {
            guard let p = byID[next[i].id] else { continue }
            // A refresh that began later has already said how this room is: this older answer only arrived last.
            guard (polledAt[next[i].id] ?? .distantPast) <= started else { continue }
            polledAt[next[i].id] = started
            var r = next[i]
            if p.answered {
                sonosMisses[r.id] = 0
                r.unreachableSince = nil
            } else {
                let n = (sonosMisses[r.id] ?? 0) + 1
                sonosMisses[r.id] = n
                // One lost answer is the Wi‑Fi; two in a row and it's gone (shown Offline until it answers).
                if n >= 2 && r.unreachableSince == nil { r.unreachableSince = Date(); lost = true }
            }
            if r.isOffline {
                r.state = ""; r.title = nil; r.artist = nil; r.album = nil; r.art = nil; r.isTV = false
                next[i] = r
                continue
            }
            if (transportAt[r.coordinatorHost] ?? .distantPast) < started {
                if let l = playing[r.coordinatorHost] {
                    r.state = l.state; r.title = l.title; r.artist = l.artist; r.album = l.album; r.art = l.art; r.isTV = l.isTV
                    // Just asked to play or pause: that shows until the speaker says the same (or time runs out).
                    if let e = expected[r.coordinatorHost] {
                        if Sonos.sameState(l.state, e.state) || e.until < now { expected[r.coordinatorHost] = nil } else { r.state = e.state }
                    }
                } else if (leaderMisses[r.coordinatorHost] ?? 0) >= 2 {
                    // The group's leader has gone quiet: what it was playing isn't known any more.
                    r.state = ""; r.title = nil; r.artist = nil; r.album = nil; r.art = nil; r.isTV = false
                }
            }
            if p.answered && (levelsAt[r.id] ?? .distantPast) < started {
                if !held.contains(r.id) { r.volume = p.room.volume }   // not while it's being dragged
                r.muted = p.room.muted
            }
            next[i] = r
        }
        if next != speakers { speakers = next; onChange?() }
        // A speaker went quiet: it may have a new address, or have left its group. Ask for the rooms again.
        if lost && lastRediscovery.timeIntervalSinceNow < -30 {
            lastRediscovery = Date()
            Task {
                await self.findSonos()
                await self.refreshSpeakers()
            }
        }
    }

    /// A short note when a speaker didn't do what was asked (room id → message); it clears itself.
    public private(set) var speakerErrors: [String: String] = [:]

    public func report(_ room: SonosRoom, _ error: Error) {
        let quiet: [URLError.Code] = [.timedOut, .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet]
        let msg: String
        if let u = error as? URLError, quiet.contains(u.code) { msg = "\(room.name) isn't answering." }
        else if let e = error as? SonosError, let d = e.errorDescription { msg = d }
        else { msg = "\(room.name) didn't do that." }
        speakerErrors[room.id] = msg
        Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if self.speakerErrors[room.id] == msg { self.speakerErrors[room.id] = nil }
        }
    }

    /// Runs [op] on the room (at its latest address and group leader) and refreshes straight after, so the tile
    /// answers at once. With [expect] the group shows that state immediately, and goes back if the speaker says no.
    public func sonos(_ room: SonosRoom, expect: String? = nil, _ op: @escaping @Sendable (SonosRoom) async throws -> Void) async {
        let r = speaker(room.id) ?? room
        lastSpeakerID = r.id
        let group = r.coordinatorHost
        var before: [String: String] = [:]
        if let expect {
            for i in speakers.indices where speakers[i].coordinatorHost == group {
                before[speakers[i].id] = speakers[i].state
                speakers[i].state = expect
            }
        }
        transportAt[group] = Date()
        levelsAt[r.id] = Date()
        do {
            try await op(r)
            speakerErrors[r.id] = nil
            if let expect { expected[group] = (state: expect, until: Date().addingTimeInterval(4)) }
        } catch {
            expected[group] = nil
            for i in speakers.indices { if let s = before[speakers[i].id] { speakers[i].state = s } }
            report(r, error)
        }
        transportAt[group] = Date()
        levelsAt[r.id] = Date()
        try? await Task.sleep(nanoseconds: 300_000_000)
        await refreshSpeakers()
        // A new track (or the TV's sound) takes a moment longer to show.
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await self.refreshSpeakers()
        }
    }

    /// Play or pause, whichever the room isn't doing now.
    public func playPause(_ room: SonosRoom) async {
        let r = speaker(room.id) ?? room
        if r.isPlaying { await sonos(r, expect: "PAUSED_PLAYBACK") { try await Sonos.pause($0) } }
        else { await sonos(r, expect: "PLAYING") { try await Sonos.play($0) } }
    }

    public func setMute(_ room: SonosRoom, _ on: Bool) async {
        if let i = speakers.firstIndex(where: { $0.id == room.id }) { speakers[i].muted = on }
        await sonos(room) { try await Sonos.setMute($0, on) }
    }

    /// Switches a soundbar to the TV's sound.
    public func playTV(_ room: SonosRoom) async {
        await sonos(room, expect: "PLAYING") { try await Sonos.playTV($0) }
    }

    @ObservationIgnored private var pendingVolume: [String: Date] = [:]
    @ObservationIgnored private var volumeSends: [String: Task<Void, Never>] = [:]

    /// Dragging the slider: shows each value at once and sends the newest one about every 150 ms, one send at a
    /// time (two at once could arrive out of order and leave the speaker on an older value), and the refresh
    /// leaves the level alone until it settles.
    public func setVolume(_ room: SonosRoom, _ v: Int) {
        let v = max(0, min(100, v))
        let id = room.id
        if let i = speakers.firstIndex(where: { $0.id == id }) { speakers[i].volume = v }
        pendingVolume[id] = Date()
        levelsAt[id] = Date()
        lastSpeakerID = id
        guard volumeSends[id] == nil else { return }   // the one running sends the newest value next
        volumeSends[id] = Task { [weak self] in
            var sent: Int?
            while true {
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard let home = self else { return }
                let target = home.speaker(id) ?? room
                let latest = home.speaker(id)?.volume ?? v
                if latest == sent { break }   // the speaker has the newest value
                do {
                    try await Sonos.setVolume(target, latest)
                } catch {
                    home.report(target, error)
                    break
                }
                sent = latest
                home.pendingVolume[id] = Date()
                home.levelsAt[id] = Date()
            }
            self?.volumeSends[id] = nil
        }
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
        let now = Date()
        for l in lights {
            guard let ip = l.ip else { continue }
            // The first ask starts the clock: a lamp that never answers is offline after `lanTimeout`.
            if lastSeen[l.id] == nil { lastSeen[l.id] = now }
            lan.status(ip)
        }
        #endif
    }

    // MARK: Reachability and held changes

    /// When each light last answered on the Wi‑Fi (light id → time).
    @ObservationIgnored private var lastSeen: [String: Date] = [:]
    /// What Govee's cloud last said about each light being connected (light id → online).
    @ObservationIgnored private var cloudOnline: [String: Bool] = [:]
    /// How long a lamp asked every five seconds may stay silent before it's called offline (six asks).
    private let lanTimeout: TimeInterval = 30
    /// What was just asked of each light, held for a few seconds so an answer sent before the change
    /// (a poll already on its way, Govee's cloud lagging) doesn't flick it back.
    @ObservationIgnored private var held: [String: (state: GoveeLight, until: Date)] = [:]

    /// Silent on the Wi‑Fi for a while, or not on it at all.
    private func lanSilent(_ l: GoveeLight) -> Bool {
        guard l.ip != nil else { return true }
        guard let seen = lastSeen[l.id] else { return false }  // not asked yet
        return Date().timeIntervalSince(seen) > lanTimeout
    }

    /// One of two lamps sharing a device ID: only its own address tells it apart, never Govee's cloud.
    private func twinned(_ l: GoveeLight) -> Bool {
        l.id.contains("@") || lights.contains { $0.id.hasPrefix(l.id + "@") }
    }

    /// Govee's cloud can reach it: on the account, a key saved, and not one of a pair.
    private func cloudUsable(_ l: GoveeLight, hasKey: Bool? = nil) -> Bool {
        guard l.cloud, !l.isHome, hasKey ?? (goveeKey?.isEmpty == false) else { return false }
        return !twinned(l)
    }

    /// Works out which lights can't be reached and shows it; they come back by themselves when they answer.
    private func checkReachable() {
        let hasKey = goveeKey?.isEmpty == false
        var changed = false
        for i in lights.indices {
            let l = lights[i]
            let offline: Bool
            if l.isHome {
                // Apple Home says (through the iPhone app); with nothing here to reach it (the Mac), it's out of reach.
                offline = homeControl == nil || l.isOffline
            } else {
                let cloudUp = cloudUsable(l, hasKey: hasKey) && cloudOnline[l.id] != false
                offline = lanSilent(l) && !cloudUp
            }
            let v: Bool? = offline ? true : nil
            if lights[i].offline != v { lights[i].offline = v; changed = true }
        }
        if changed { onChange?() }
    }

    private func hold(_ l: GoveeLight, for seconds: TimeInterval) {
        held[l.id] = (state: l, until: Date().addingTimeInterval(seconds))
    }

    /// A reported state, with a change just asked for kept until the light confirms it or the hold runs out.
    private func holding(_ incoming: GoveeLight) -> GoveeLight {
        guard let h = held[incoming.id] else { return incoming }
        let s = h.state
        // Give or take the rounding a light does on the way back (Apple Home goes through hue, saturation and
        // mireds): an exact match never came, so the change was never taken as done.
        let confirmed = incoming.on == s.on
            && (!s.on || (incoming.brightness == s.brightness && Self.near(incoming.color, s.color) && Self.near(incoming.kelvin, s.kelvin, by: 100)))
        if confirmed || h.until < Date() {
            held[incoming.id] = nil
            return incoming
        }
        var l = incoming
        l.on = s.on; l.brightness = s.brightness; l.color = s.color; l.kelvin = s.kelvin
        return l
    }

    private static func near(_ a: LightColor?, _ b: LightColor?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return abs(a.r - b.r) <= 8 && abs(a.g - b.g) <= 8 && abs(a.b - b.b) <= 8
    }

    private static func near(_ a: Int?, _ b: Int?, by d: Int) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return abs(a - b) <= d
    }

    /// Every light that answered the search, by address: what it says it is (shown in Settings → Smart Home → Lights).
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
               // Both answering in the same search round (not one lamp that just moved to a new address).
               answers.contains(where: { $0.ip == other && $0.device == id && $0.at.timeIntervalSinceNow > -20 }) {
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
        lastSeen[lights[i].id] = Date()
        var l = lights[i]
        l.on = on
        // Some lamps say 0 while off; keep the level they'll come back on at.
        if brightness > 0 { l.brightness = min(100, brightness) }
        // White (a colour temperature) or a colour, never a stale mix of both.
        if let kelvin, kelvin > 0 { l.kelvin = kelvin; l.color = nil }
        else if let color, color != LightColor(r: 0, g: 0, b: 0) { l.color = color; l.kelvin = nil }
        l = holding(l)
        l.offline = nil
        // Lamps answer every few seconds; only an actual change redraws anything.
        guard l != lights[i] else { return }
        lights[i] = l
        onChange?()
    }

    @ObservationIgnored private var cloudRefresh: Task<Void, Never>?

    /// One at a time: a second call waits for the one already running.
    public func refreshCloud() async {
        if let running = cloudRefresh { await running.value; return }
        let t = Task { await self.refreshCloudNow() }
        cloudRefresh = t
        await t.value
        cloudRefresh = nil
    }

    private func refreshCloudNow() async {
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
                    // Its white range, for it and its twin (same model).
                    if d.kelvinMin != nil {
                        for j in lights.indices where lights[j].id == d.id || lights[j].id.hasPrefix(d.id + "@") {
                            lights[j].kelvinMin = d.kelvinMin
                            lights[j].kelvinMax = d.kelvinMax
                        }
                    }
                } else {
                    var l = d
                    if let n = names[d.id] { l.name = n }
                    lights.append(l)
                }
            }
            // Lights not answering on the Wi‑Fi: their state comes from Govee (never for twins, which the cloud
            // can't tell apart). The list can change while waiting (a search, a rename), so each answer is put
            // back by ID, state only.
            let targets = lights.filter { $0.cloud && !twinned($0) && lanSilent($0) }
            for t in targets {
                var probe = t
                probe.offline = nil  // so an answer that never came isn't read as Govee's word
                let fresh: GoveeLight
                if open { fresh = await Govee.openState(probe, key: key) } else { fresh = await Govee.cloudState(probe, key: key) }
                if let off = fresh.offline { cloudOnline[t.id] = !off }
                guard let i = lights.firstIndex(where: { $0.id == t.id }), lanSilent(lights[i]) else { continue }
                var l = lights[i]
                l.on = fresh.on
                l.brightness = fresh.brightness
                l.color = fresh.color
                l.kelvin = fresh.kelvin
                lights[i] = holding(l)
            }
            checkReachable()
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

    /// Turns a light on or off: on the LAN when it's there, else through Govee's cloud (or Apple Home).
    public func setOn(_ l: GoveeLight, _ on: Bool) {
        let before = update(l) { $0.on = on }
        send(l.id, .power(on), before: before)
    }

    public func setBrightness(_ l: GoveeLight, _ v: Int) {
        // 0 % is off, as in the Home app.
        guard v > 0 else { setOn(l, false); return }
        let v = min(100, v)
        let wasOn = light(l.id)?.isLit ?? l.on
        let before = update(l) { $0.brightness = v; $0.on = true }
        send(l.id, .brightness(v), turnOn: !wasOn, before: before)
    }

    public func setColor(_ l: GoveeLight, _ c: LightColor) {
        let c = LightColor(r: max(0, min(255, c.r)), g: max(0, min(255, c.g)), b: max(0, min(255, c.b)))
        let wasOn = light(l.id)?.isLit ?? l.on
        let before = update(l) { $0.color = c; $0.kelvin = nil; $0.on = true }
        send(l.id, .color(c), turnOn: !wasOn, before: before)
    }

    public func setWhite(_ l: GoveeLight, kelvin: Int) {
        let current = light(l.id) ?? l
        // Apple Home lights clamp to their own range; Govee lamps to their model's.
        let k = current.isHome ? max(1000, min(10_000, kelvin)) : current.clampKelvin(kelvin)
        let wasOn = current.isLit
        let before = update(l) { $0.kelvin = k; $0.color = nil; $0.on = true }
        send(l.id, .kelvin(k), turnOn: !wasOn, before: before)
    }

    /// Shows a change at once; returns the light as it was, to put back if the change can't be carried out.
    @discardableResult
    private func update(_ l: GoveeLight, _ f: (inout GoveeLight) -> Void) -> GoveeLight? {
        guard let i = lights.firstIndex(where: { $0.id == l.id }) else { return nil }
        let before = lights[i]
        f(&lights[i])
        onChange?()
        return before
    }

    /// Changes sent to each light, counted: a check or a failure that belongs to an older change leaves a newer
    /// one alone.
    @ObservationIgnored private var commandSeq: [String: Int] = [:]

    /// A change that didn't happen: the light goes back to how it was shown before it (unless it's been changed
    /// again since), instead of showing something it isn't doing.
    private func restore(_ before: GoveeLight?, seq: Int) {
        guard let before, commandSeq[before.id] == seq, let i = lights.firstIndex(where: { $0.id == before.id }) else { return }
        held[before.id] = nil
        lights[i].on = before.on
        lights[i].brightness = before.brightness
        lights[i].color = before.color
        lights[i].kelvin = before.kelvin
        onChange?()
    }

    /// Sends a change by the light's own path: Apple Home; its address on the Wi‑Fi (always, for twins);
    /// else Govee's cloud — and the cloud too when the Wi‑Fi doesn't answer after the change.
    private func send(_ id: String, _ c: LightCommand, turnOn: Bool = false, before: GoveeLight? = nil) {
        guard let l = light(id) else { return }
        let seq = (commandSeq[id] ?? 0) + 1
        commandSeq[id] = seq
        if l.isHome {
            guard let homeControl else {
                goveeError = "\(l.name) is in Apple Home, which only the iPhone app can reach."
                restore(before, seq: seq)
                return
            }
            hold(l, for: 6)
            homeControl(l, c)
            return
        }
        #if canImport(Network)
        if let ip = l.ip, !(lanSilent(l) && cloudUsable(l)) {
            hold(l, for: 6)
            if turnOn { lanSend(ip, .power(true)) }
            lanSend(ip, c)
            let sent = Date()
            let viaCloud = cloudUsable(l)
            Task { [weak self] in
                // UDP can lose a packet either way. Ask the lamp how it is; while it hasn't taken the change, send it
                // again (twice at most). The lamp's answer clears the hold once it matches.
                for attempt in 0..<3 {
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    guard let home = self, home.commandSeq[id] == seq, home.held[id] != nil else { return }
                    guard let addr = home.light(id)?.ip else { break }
                    if attempt > 0 {
                        if turnOn { home.lanSend(addr, .power(true)) }
                        home.lanSend(addr, c)
                    }
                    home.lan.status(addr)
                }
                try? await Task.sleep(nanoseconds: 800_000_000)
                // Never answered at all: the change goes through Govee's cloud when it can.
                guard let home = self, home.commandSeq[id] == seq, home.held[id] != nil, viaCloud,
                      (home.lastSeen[id] ?? .distantPast) < sent, let now = home.light(id) else { return }
                home.cloud(now, c, turnOn: turnOn, before: before, seq: seq)
            }
            return
        }
        #endif
        cloud(l, c, turnOn: turnOn, before: before, seq: seq)
    }

    #if canImport(Network)
    private func lanSend(_ ip: String, _ c: LightCommand) {
        switch c {
        case .power(let on): lan.turn(ip, on)
        case .brightness(let v): lan.brightness(ip, v)
        case .color(let rgb): lan.color(ip, rgb)
        case .kelvin(let k): lan.kelvin(ip, k)
        }
    }
    #endif

    private func cloud(_ l: GoveeLight, _ c: LightCommand, turnOn: Bool = false, before: GoveeLight? = nil, seq: Int) {
        guard let key = goveeKey, !key.isEmpty, l.cloud, !twinned(l) else {
            goveeError = twinned(l)
                ? "\(l.name) is reached only on the Wi‑Fi (it shares its Govee ID with its twin). Check it’s plugged in."
                : "Turn on LAN Control for \(l.name) in the Govee app, or add a Govee API key."
            // Nowhere to send it: don't leave the light showing a change it never got.
            restore(before, seq: seq)
            return
        }
        hold(l, for: 15)
        let steps: [LightCommand] = (turnOn ? [LightCommand.power(true)] : []) + [c]
        let id = l.id
        Task { [weak self] in
            var failure: Error?
            for step in steps {
                do { try await Govee.control(l, key: key, step) } catch { failure = error; break }
            }
            guard let self else { return }
            if let failure {
                // It didn't happen: show the light as it was (unless it's been changed again since), then as
                // Govee says it is.
                self.held[id] = nil
                self.restore(before, seq: seq)
                self.goveeError = failure.localizedDescription
                await self.refreshCloud()
            } else if self.goveeError != nil {
                self.goveeError = nil
            }
        }
    }
}
