import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Every action on one TV. A TV paired here is reached directly (`routeID == "this"`); a TV linked to a hub is
/// reached through that hub's relays (`/api/tvs/key`, `/api/tvs/type`, …), as the phone page does.
/// Hub-wide features (Memories, files, library, notes, settings) are called on a "this" client of the hub.
public struct TVClient: Sendable {
    public let hub: Hub
    public let routeID: String
    public var t: TVTransport { TVTransport(hub.connection) }
    public var isDirect: Bool { routeID == "this" }

    public init(hub: Hub, routeID: String) {
        self.hub = hub
        self.routeID = routeID
    }

    /// Tells the app's running `Fleet` that this TV was just asked to change what it plays (or whether it's on),
    /// so it asks the TV again right away, and a moment later, instead of on its next round: what's playing,
    /// play/pause and position show the change at once on every screen. [target] says which TV when it isn't
    /// this client's own: a linked TV's id, or "all". Does nothing where no Fleet runs (widgets).
    func changed(_ target: String? = nil) {
        let hubID = hub.id
        let route = target ?? routeID
        Task { @MainActor in Fleet.commandSent(hub: hubID, route: route) }
    }

    /// Keys that change nothing worth asking the TV about again.
    static let quietKeys: Set<String> = ["volup", "voldown", "mute"]

    // MARK: Remote

    /// Key names: up down left right ok back home menu playpause volup voldown mute netflix youtube
    /// (webOS also play pause next prev ff rew info amazon disney).
    public func key(_ key: String, repeat n: Int = 0) async throws {
        if isDirect { try await t.post("/api/key", ["key": key, "repeat": n > 0 ? n : nil], timeout: 6) }
        else { try await t.post("/api/tvs/key", ["id": routeID, "key": key, "repeat": n > 0 ? n : nil], timeout: 8) }
        if !TVClient.quietKeys.contains(key) { changed() }
    }

    /// ↺10, 30↻, Next. Play/pause goes through `key("playpause")`, as the phone page does.
    @discardableResult
    public func media(_ action: String) async throws -> Bool? {
        let r: JSONValue
        if isDirect {
            r = try await t.post("/api/media", ["action": action])
        } else {
            r = try await t.post("/api/tvs/media", ["id": routeID, "action": action])
        }
        changed()
        return r["playing"]?.bool
    }

    public func typeField() async throws -> TypeState {
        isDirect ? try await t.get("/api/type", timeout: 6) : try await t.get("/api/tvs/type", ["id": routeID], timeout: 10)
    }

    /// Sends the text box's whole text; [submit] presses Done. [field] is echoed with the JSON type the TV gave.
    public func type(_ text: String, field: JSONValue?, submit: Bool = false) async throws {
        let fid: Any? = field.flatMap { f -> Any? in
            switch f { case .number(let n): return n == n.rounded() ? Int(n) : n; case .string(let s): return s; default: return nil }
        }
        if isDirect { try await t.post("/api/type", ["id": fid, "text": text, "submit": submit], timeout: 8) }
        else { try await t.post("/api/tvs/type", ["id": routeID, "field": fid, "text": text, "submit": submit], timeout: 10) }
    }

    /// A JPEG of the TV's screen (Android: Woodruff's own windows; webOS: refused with a message).
    public func screen(width: Int = 960) async throws -> Data {
        let q: [String: String?] = isDirect ? ["w": String(width), "t": String(Int(Date().timeIntervalSince1970 * 1000))]
                                            : ["id": routeID, "t": String(Int(Date().timeIntervalSince1970 * 1000))]
        let (d, _) = try await t.data("GET", isDirect ? "/api/screen" : "/api/tvs/screen", query: q, timeout: 8)
        return d
    }

    // MARK: Health & updates

    /// The TV's health report. A TV that's off, refused or too old throws `HealthUnavailable` (with its last report).
    public func health() async throws -> HealthReport {
        let req = t.request("GET", "/api/tvs/health", query: ["id": routeID], timeout: 15)
        let d: Data, resp: URLResponse
        do { (d, resp) = try await URLSession.woodruff.data(for: req) } catch {
            throw TVError.offline("Can't reach \(hub.name).")
        }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status == 200 { return try t.decode(d) }
        if status == 409, let u = try? JSONDecoder().decode(HealthUnavailable.self, from: d) { throw u }
        throw TVError.from(status: status, data: d)
    }

    /// Android: checks GitHub now and installs the newest build once nobody's using the TV.
    public func checkForUpdates() async throws {
        try await t.post("/api/tvs/update/check", ["id": routeID])
    }

    public func relink(code: String) async throws -> RelinkResult {
        try await t.post("/api/tvs/relink", ["id": routeID, "code": code.filter(\.isNumber)], timeout: 25)
    }

    public func diagnostics() async throws -> (String, Int) {
        let (d, r) = try await t.data("GET", "/api/diagnostics")
        return (String(decoding: d, as: UTF8.self), Int(r.value(forHTTPHeaderField: "X-Recording-Left") ?? "0") ?? 0)
    }

    public func recordDiagnostics() async throws -> Int {
        try await t.post("/api/diagnostics/record")["seconds"]?.int ?? 0
    }

    // MARK: Messages

    @discardableResult
    public func announce(title: String, body: String, tv: Bool, tvs: [String]? = nil, phones: [String]?, allPhones: Bool, from: String, pin: Bool) async throws -> AnnounceResult {
        var b: [String: Any?] = ["title": title, "body": body, "tv": tv, "from": from, "pin": pin]
        if allPhones { b["phones"] = "all" } else if let phones, !phones.isEmpty { b["phones"] = phones }
        if let tvs { b["tvs"] = tvs }
        return try await t.post("/api/announce", b)
    }

    public func phones() async throws -> [Phone] { try await t.get("/api/phones", as: PhoneList.self).phones }

    public func hello(_ p: PhoneIdentity, alerts: Bool? = nil) async throws -> PhoneHello {
        try await t.post("/api/phone/hello", ["id": p.id, "name": p.name, "alerts": alerts])
    }

    public func inbox(phone: String, after: Int?, epoch: String?, timeout: TimeInterval = 10) async throws -> Inbox {
        try await t.get("/api/inbox", ["id": phone, "after": after.map(String.init), "epoch": epoch], timeout: timeout)
    }

    public func open(_ url: String) async throws {
        try await t.post("/api/open", ["url": url])
        changed()
    }
    public func slideshow(folder: String? = nil, start: Bool) async throws {
        var b: [String: Any?] = ["start": start]
        if let folder { b["folder"] = folder }
        try await t.post("/api/slideshow", b)
        if start { changed() }
    }
    public func background(_ path: String) async throws { try await t.post("/api/background", ["path": path]) }

    // MARK: Files

    public func roots() async throws -> [StorageRoot] { try await t.get("/api/roots") }
    public func list(_ path: String) async throws -> FolderListing { try await t.get("/api/list", ["path": path]) }
    public func downloadURL(_ path: String) -> URL { hub.connection.url("/api/download", ["path": path]) }
    public func mkdir(in path: String, name: String) async throws {
        _ = try await t.data("POST", "/api/mkdir", query: ["path": path, "name": name])
    }
    public func delete(_ path: String) async throws {
        _ = try await t.data("POST", "/api/delete", query: ["path": path], body: try JSONSerialization.data(withJSONObject: ["path": path]))
    }
    @discardableResult
    public func play(path: String? = nil, key: String? = nil, title: String? = nil, position: Double? = nil, resume: Bool? = nil) async throws -> PlayResult {
        let r: PlayResult = try await t.post("/api/play", ["path": path, "key": key, "title": title, "position": position, "resume": resume])
        changed()
        return r
    }

    /// Raw-bytes upload into folder [path] (`/api/upload`). Returns the name the TV gave it.
    public func upload(file: URL, to path: String, name: String) async throws -> String {
        let (d, _) = try await uploadFile(file, "/api/upload", ["path": path, "name": name])
        return (try? JSONDecoder().decode(JSONValue.self, from: d))?["name"]?.string ?? name
    }

    func uploadFile(_ file: URL, _ route: String, _ query: [String: String?]) async throws -> (Data, HTTPURLResponse) {
        var r = t.request("POST", route, query: query, body: nil, contentType: nil, timeout: 600)
        r.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (d, resp) = try await URLSession.woodruff.upload(for: r, fromFile: file)
        guard let http = resp as? HTTPURLResponse else { throw TVError.badAnswer("No answer") }
        guard (200..<300).contains(http.statusCode) else { throw TVError.from(status: http.statusCode, data: d) }
        return (d, http)
    }

    // MARK: Family Memories

    public func memories() async throws -> Memories { try await t.get("/api/memories", timeout: 30) }
    public func thumbURL(_ m: MemoryItem) -> URL { hub.connection.url("/api/memories/thumb", ["path": m.path, "v": m.version]) }
    public func photoURL(_ m: MemoryItem) -> URL { hub.connection.url("/api/memories/photo", ["path": m.path, "v": m.version]) }
    public func addMemory(file: URL, name: String, taken: Date?) async throws -> MemoryItem {
        let q: [String: String?] = ["name": name, "taken": taken.map { String(Int($0.timeIntervalSince1970 * 1000)) }]
        let (d, _) = try await uploadFile(file, "/api/memories/add", q)
        return try JSONDecoder().decode(MemoryAdded.self, from: d).item
    }
    public func deleteMemory(_ m: MemoryItem) async throws -> Memories { try await t.post("/api/memories/delete", ["path": m.path]) }
    public func showMemory(_ m: MemoryItem) async throws {
        try await t.post("/api/memories/show", ["path": m.path])
        changed()
    }

    // MARK: Watch

    public func watchHome() async throws -> WatchHome { try await t.get("/api/watch/home", timeout: 15) }
    public func library(place: String, sort: String, unwatched: Bool, genre: String?, q: String?, offset: Int, limit: Int = 60) async throws -> LibraryPage {
        try await t.get("/api/library", ["place": place, "sort": sort, "unwatched": unwatched ? "1" : "0", "genre": genre, "q": q?.isEmpty == false ? q : nil,
                                         "offset": String(offset), "limit": String(limit)])
    }
    public func search(_ q: String) async throws -> SearchResults { try await t.get("/api/library/search", ["q": q, "limit": "100"]) }
    public func title(_ id: String) async throws -> TitleDetails { try await t.get("/api/library/title", ["id": id], timeout: 20) }
    public func episodes(show: String, season: String) async throws -> EpisodeList {
        for _ in 0..<10 {
            let r: EpisodeList = try await t.get("/api/library/episodes", ["show": show, "season": season], timeout: 20)
            if r.state != "loading" { return r }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return EpisodeList(state: "loading", episodes: [])
    }
    public func markWatched(_ keys: [String], _ on: Bool) async throws { try await t.post("/api/library/watched", ["keys": keys, "watched": on]) }
    public func removeContinue(key: String, title: String) async throws { try await t.post("/api/continue/remove", ["key": key, "title": title]) }

    /// Art: absolute TMDB links as they are; the TV's own `/api/poster?…` with the key.
    public func art(_ s: String?, small: Bool = false) -> URL? {
        guard var s, !s.isEmpty else { return nil }
        if s.hasPrefix("http") {
            if small { s = s.replacingOccurrences(of: "/t/p/original/", with: "/t/p/w300/") }
            return URL(string: s)
        }
        guard var c = URLComponents(string: s) else { return nil }
        var items = c.queryItems ?? []
        items.append(URLQueryItem(name: "k", value: hub.connection.key))
        c.queryItems = items
        return c.url(relativeTo: hub.connection.base)?.absoluteURL
    }

    /// Starts [action] on TV [target] ("this", a linked id, or "all" for Watch Together), as the phone page routes it.
    public func start(_ action: PlayAction, on target: String, fromStart: Bool = false, showId: String? = nil) async throws -> PlayResult {
        let pos = fromStart ? 0 : (action.position ?? 0)
        let resume: Bool? = fromStart ? nil : (action.resume == true ? true : nil)
        let latest: Bool? = fromStart ? nil : (action.latest == true ? true : nil)
        if target == "this" && !action.isDrive {
            return try await play(key: action.key, title: action.title, position: pos, resume: resume)
        }
        let r: PlayResult
        if target == "this" {
            r = try await t.post("/api/watch", ["key": action.key, "title": action.title, "position": pos, "resume": resume, "latest": latest], timeout: 15)
        } else {
            r = try await t.post("/api/tvs/watch", ["id": target, "key": action.key, "title": action.title, "position": pos,
                                                    "resume": resume, "latest": latest, "showId": showId], timeout: 20)
        }
        changed(target)
        return r
    }

    // MARK: Settings

    public func settings() async throws -> TVSettings { try await t.get("/api/settings") }
    public func saveGoogle(clientID: String, secret: String) async throws -> TVSettings {
        try await t.post("/api/settings/google", ["client_id": clientID, "client_secret": secret])
    }
    public func saveTMDB(_ key: String) async throws -> TVSettings { try await t.post("/api/settings/tmdb", ["key": key], timeout: 20) }
    public func saveNest(_ fields: [String: Any?]) async throws -> TVSettings { try await t.post("/api/settings/nest", fields) }
    public func saveWeather(_ place: String) async throws -> TVSettings { try await t.post("/api/settings/weather", ["place": place], timeout: 30) }
    public func addMail(provider: String, email: String, password: String, host: String?, port: Int?) async throws -> TVSettings {
        try await t.post("/api/mail", ["provider": provider, "email": email, "password": password, "host": host, "port": port], timeout: 50)
    }
    public func deleteMail(_ id: String) async throws -> TVSettings { try await t.post("/api/mail/delete", ["id": id]) }
    public func clearCrash() async throws -> TVSettings { try await t.post("/api/crash/clear") }

    // MARK: Notes (kept on the TV)

    public func notes() async throws -> [TVNote] { (try await t.get("/api/notes") as TVNoteList).notes }
    /// Adds a note (no id) or changes one; [pinned] nil leaves it as it was.
    @discardableResult
    public func saveNote(id: String?, title: String, body: String, pinned: Bool?) async throws -> TVNote? {
        var b: [String: Any?] = ["title": title, "body": body]
        if let id { b["id"] = id }
        if let pinned { b["pinned"] = pinned }
        return (try await t.post("/api/notes", b) as TVNoteSaved).note
    }
    public func deleteNote(_ id: String) async throws { try await t.post("/api/notes/delete", ["id": id]) }

    public func startSignIn(_ grant: String) async throws -> SignInStart { try await t.post("/api/signin", ["grant": grant]) }
    public func signInStatus(state: String, grant: String) async throws -> SignInStatus {
        try await t.get("/api/signin/status", ["state": state, "grant": grant])
    }
}
