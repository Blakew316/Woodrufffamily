import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Sample mode (launch argument `-demo YES`): a pretend family of TVs answering every route with sample data, so
/// the app can be tried, and screenshotted in CI, without a TV. Pictures come from the app bundle (Demo folder).
public enum Demo {
    public static var isOn: Bool { UserDefaults.standard.bool(forKey: "demo") }
    public static let hub = Hub(id: "tv-living", name: "Living Room", connection: TVConnection(base: URL(string: "http://demo.woodruff:8090")!, key: "demo"))

    public static func register() {
        URLProtocol.registerClass(DemoURLProtocol.self)
    }

    static let now = Date().timeIntervalSince1970 * 1000

    static func json(_ path: String, _ q: [String: String]) -> Any? {
        switch path {
        case "/api/status": return ["id": "tv-living", "name": "Living Room", "onScreen": true, "version": "2.0.214"]
        case "/api/tvs": return ["tvs": tvs]
        case "/api/tvs/health", "/api/health": return health(q["id"] ?? "this")
        case "/api/phone/hello": return ["phone": phones[0], "phones": phones]
        case "/api/phones": return ["phones": phones]
        case "/api/inbox": return ["messages": [], "seq": 3, "epoch": "e1"]
        case "/api/type", "/api/tvs/type": return ["field": ["id": 7, "label": "Search file names", "secret": false, "multiline": false, "text": "vacation"]]
        case "/api/watch/home": return watchHome
        case "/api/library": return ["state": "ready", "count": movies.count, "offset": 0, "items": q["place"] == "shows" ? shows : movies, "genres": ["Drama", "Thriller", "Comedy", "Family"], "rated": true]
        case "/api/library/search": return ["state": "ready", "q": q["q"] ?? "", "first": "movies", "movies": Array(movies.prefix(3)), "shows": Array(shows.prefix(2)), "capped": ["movies": false, "shows": false]]
        case "/api/library/title": return titleDetails(q["id"] ?? "")
        case "/api/library/episodes": return ["state": "ready", "episodes": episodes]
        case "/api/memories": return memories
        case "/api/settings": return settings
        case "/api/roots": return [["name": "Internal storage", "path": "/storage/emulated/0", "removable": false, "free": 18e9],
                                   ["name": "USB drive", "path": "/storage/usb1", "removable": true, "free": 120e9]]
        case "/api/list": return files
        default: return nil
        }
    }

    static func image(_ path: String, _ q: [String: String]) -> String? {
        switch path {
        case "/api/poster":
            let id = q["id"] ?? ""
            return (q["kind"] == "backdrop" ? "bd_" : "") + id
        case "/api/memories/thumb", "/api/memories/photo":
            return (q["path"] as NSString?)?.lastPathComponent.replacingOccurrences(of: ".jpg", with: "")
        case "/api/screen", "/api/tvs/screen": return q["id"] == "tv-den" ? "tv_screen2" : "tv_screen"
        default: return nil
        }
    }

    // MARK: Sample data

    static let playingLiving: [String: Any] = ["title": "Midnight Harbor", "subtitle": "", "app": "Woodruff Family", "playing": true, "position": 2_710_000.0, "duration": 6_790_000.0, "can": ["playpause", "back10", "fwd30"], "key": "drive:m_midnight_harbor"]
    static let playingDen: [String: Any] = ["title": "Backyard Science · S2 E4", "subtitle": "The Volcano", "app": "YouTube", "playing": true, "position": 390_000.0, "duration": 1_299_000.0, "can": ["playpause", "back10", "fwd30", "next"], "key": "drive:t_backyard_science"]

    /// The TVs as the hub answers right now. The ones that are on were just heard from, as a real hub hears from its
    /// linked TVs every few seconds (a `seen` that never moves would read as a TV the hub has lost touch with).
    static var tvs: [[String: Any]] {
        let heard = Date().timeIntervalSince1970 * 1000
        return [
            ["id": "this", "name": "Living Room", "online": true, "onScreen": true, "playing": playingLiving, "version": "2.0.214", "seen": heard, "link": "ok", "health": ["status": "good", "count": 0, "first": NSNull()]],
            ["id": "tv-den", "name": "Den", "online": true, "onScreen": false, "playing": playingDen, "version": "2.0.209", "seen": heard, "link": "ok", "health": ["status": "attention", "count": 2, "first": "Google Drive’s sign-in ended"]],
            ["id": "tv-kitchen", "name": "Kitchen", "online": false, "onScreen": false, "playing": NSNull(), "version": "2.0.214", "seen": now - 7_200_000, "link": "ok", "health": ["status": "unknown", "count": 0, "first": NSNull()]],
            ["id": "tv-bedroom", "name": "Bedroom", "online": false, "onScreen": false, "playing": NSNull(), "version": NSNull(), "seen": now - 86_400_000, "link": "refused", "health": ["status": "unknown", "count": 0, "first": NSNull()]],
        ]
    }

    static func health(_ id: String) -> [String: Any] {
        let den = id == "tv-den"
        var r: [String: Any] = [
            "id": id, "name": den ? "Den" : "Living Room", "at": now, "android": 34, "version": den ? "2.0.209" : "2.0.214",
            "status": den ? "attention" : "good",
            "sentence": den ? "Google Drive’s sign-in ended, and the last update didn’t install." : "Everything’s working.",
            "attention": den ? [["id": "signin.drive", "words": "Google Drive’s sign-in ended", "detail": "Sign in again on Den to stream from Drive.", "fix": "signin", "grant": "drive"],
                                ["id": "update.failed", "words": "The last update didn’t install", "detail": "Den will try again when nobody’s watching.", "fix": "update"]] : [],
            "installedBy": ["summary": "Updates itself", "by": "Woodruff"],
            "updates": ["step": den ? "error" : "upToDate", "text": den ? "Couldn’t install 2.0.214" : "Up to date", "attention": den, "auto": true, "testTv": !den, "asks": false],
            "signIns": [
                "drive": ["state": den ? "expired" : "signedIn", "text": den ? "Sign-in ended" : "Signed in", "attention": den],
                "photos": ["state": "signedIn", "text": "Connected", "attention": false],
                "calendar": ["state": den ? "notSignedIn" : "signedIn", "text": den ? "Not connected" : "Connected", "attention": false],
                "cameras": ["state": "signedIn", "text": den ? "Can’t reach Google" : "Connected", "attention": false],
                "doorbell": ["state": "watching", "text": "Watching", "attention": false],
            ],
            "freeSpace": ["free": 9.2e9, "text": "9.2 GB free", "attention": false],
            "keys": ["text": "All set", "googleClientId": true, "googleClientSecret": true, "camerasProject": true, "tmdb": true],
            "uptime": 3.6e8,
        ]
        if id != "this" { r["via"] = "Living Room" }
        return r
    }

    static let phones: [[String: Any]] = [
        ["id": "demo-phone-0001", "name": "Blake’s iPhone", "alerts": true, "seen": now],
        ["id": "demo-ipad-0002", "name": "Living Room iPad", "alerts": true, "seen": now],
        ["id": "demo-ipad-0003", "name": "Kitchen iPad", "alerts": false, "seen": now],
    ]

    static func title(_ id: String, _ name: String, _ year: Int, show: Bool, genres: [String], rating: Double, caption: String? = nil) -> [String: Any] {
        var t: [String: Any] = ["id": id, "kind": show ? "show" : "movie", "title": name, "year": year,
                                "poster": "/api/poster?id=\(id)&kind=poster&v=1", "backdrop": "/api/poster?id=\(id)&kind=backdrop&v=1",
                                "genres": genres, "rating": rating, "watched": false, "added": now,
                                "play": ["key": "drive:\(id)", "title": name, "position": 0, "label": show ? "Play S1 E1" : "Play", "duration": 6e6]]
        if let caption { t["caption"] = caption }
        return t
    }

    static let movies: [[String: Any]] = [
        title("m_midnight_harbor", "Midnight Harbor", 2024, show: false, genres: ["Thriller", "Drama"], rating: 7.8),
        title("m_ironwood", "Ironwood", 2025, show: false, genres: ["Adventure"], rating: 7.1),
        title("m_last_light", "The Last Light", 2023, show: false, genres: ["Drama"], rating: 8.2),
        title("m_neon_alley", "Neon Alley", 2024, show: false, genres: ["Thriller"], rating: 6.9),
        title("m_orbit", "Orbit", 2021, show: false, genres: ["Sci-Fi"], rating: 7.4),
        title("m_paper_planes", "Paper Planes", 2022, show: false, genres: ["Family"], rating: 7.0),
        title("m_summer_cabin", "Summer at the Cabin", 2020, show: false, genres: ["Comedy"], rating: 6.5),
    ]
    static let shows: [[String: Any]] = [
        title("t_backyard_science", "Backyard Science", 2023, show: true, genres: ["Family"], rating: 8.4, caption: "New · S2 E5"),
        title("t_kitchen_rules", "Kitchen Rules", 2021, show: true, genres: ["Reality"], rating: 7.2),
        title("t_detective_rowe", "Detective Rowe", 2019, show: true, genres: ["Crime"], rating: 8.0),
        title("t_the_lighthouse", "The Lighthouse", 2022, show: true, genres: ["Drama"], rating: 7.7, caption: "New season"),
    ]

    static func cont(_ id: String, _ name: String, kind: String, code: String?, episode: String?, pos: Double, dur: Double, upNext: Bool = false) -> [String: Any] {
        ["key": "drive:\(id)", "playTitle": name, "titleId": id, "kind": kind, "name": name, "code": code ?? NSNull(), "episode": episode ?? NSNull(),
         "position": pos, "duration": dur, "upNext": upNext, "poster": "/api/poster?id=\(id)&kind=poster&v=1", "drive": true,
         "play": ["key": "drive:\(id)", "title": name, "position": pos, "label": "Resume", "duration": dur, "resume": true]]
    }

    static let watchHome: [String: Any] = [
        "state": "ready", "tv": "Living Room", "updated": now,
        "featured": [movies[0], shows[0], movies[2], shows[3], movies[4]],
        "continue": [cont("m_midnight_harbor", "Midnight Harbor", kind: "movie", code: nil, episode: nil, pos: 2_710_000, dur: 6_790_000),
                     cont("t_backyard_science", "Backyard Science", kind: "show", code: "S2 E4", episode: "The Volcano", pos: 390_000, dur: 1_299_000),
                     cont("t_kitchen_rules", "Kitchen Rules", kind: "show", code: "S3 E1", episode: "Fresh Start", pos: 0, dur: 2_600_000, upNext: true),
                     cont("m_orbit", "Orbit", kind: "movie", code: nil, episode: nil, pos: 900_000, dur: 6_500_000)],
        "recent": [shows[3], movies[1], movies[3], shows[2], movies[5]],
        "movies": ["count": movies.count, "items": movies],
        "shows": ["count": shows.count, "items": shows],
    ]

    static func titleDetails(_ id: String) -> [String: Any] {
        var t = (movies + shows).first { ($0["id"] as? String) == id } ?? shows[0]
        let show = (t["kind"] as? String) == "show"
        t["overview"] = show ? "Two curious kids and their grandad turn the back garden into a laboratory, one question at a time: why the sky goes orange, where the rain goes, and what the ants are doing all day."
                             : "A harbour pilot on her last night shift finds a ship that isn’t on any manifest, and a crew that insists it’s 1987."
        t["ageRating"] = show ? "TV-G" : "PG-13"
        t["cast"] = ["A. Rivers", "B. Lane", "C. Moss"]
        t["runtime"] = show ? NSNull() : 113
        t["seasons"] = show ? [["id": "s1", "name": "Season 1"], ["id": "s2", "name": "Season 2"]] : []
        t["season"] = show ? 1 : 0
        t["playName"] = show ? "The Volcano" : NSNull()
        t["playMinutes"] = show ? 24 : 113
        t["play"] = ["key": "drive:\(id)-e4", "title": "S2 E4", "position": 390_000, "label": show ? "Resume S2 E4" : "Resume", "duration": 1_440_000, "resume": true]
        t["restart"] = ["key": "drive:\(id)-e4", "title": "S2 E4", "position": 0, "label": show ? "Play from the Start" : "Start Over", "duration": 1_440_000]
        t["watchKey"] = "drive:\(id)"
        return t
    }

    static func episode(_ name: String, _ about: String, _ n: Int, _ watched: Bool) -> [String: Any] {
        var e: [String: Any] = [:]
        e["key"] = "drive:ep\(n)"
        e["playTitle"] = "S2 E\(n)"
        e["code"] = "S2 E\(n)"
        e["number"] = n
        e["special"] = false
        e["name"] = name
        e["overview"] = about
        let still: String = "bd_mem_" + String(format: "%02d", n * 2)
        e["still"] = "/api/poster?id=" + still + "&kind=still&v=1"
        e["runtime"] = 24
        e["position"] = n == 4 ? 390_000.0 : 0.0
        e["duration"] = 1_440_000.0
        e["watched"] = watched
        e["upNext"] = n == 4
        e["new"] = n == 5
        return e
    }

    static let episodes: [[String: Any]] = [
        episode("Magnets", "The fridge door becomes a laboratory.", 1, true),
        episode("Ice", "How long a block of ice lasts in the sun, measured every hour.", 2, true),
        episode("Wind", "Kites, paper and the neighbour’s washing line.", 3, true),
        episode("The Volcano", "A trip to the island turns into a lesson about what is under our feet.", 4, false),
        episode("Rain", "Where the water goes after it hits the roof.", 5, false),
    ]

    static func memory(_ n: Int) -> [String: Any] {
        let name: String = "mem_" + String(format: "%02d", n)
        var m: [String: Any] = [:]
        m["path"] = "/storage/emulated/0/Pictures/Family Memories/" + name + ".jpg"
        m["name"] = name + ".jpg"
        m["video"] = n == 4 || n == 11
        m["taken"] = now - Double(n) * 259_200_000
        m["size"] = 420_000
        m["v"] = 1
        return m
    }

    static let memories: [String: Any] = [
        "items": (0..<18).map(memory),
        "folder": "/storage/emulated/0/Pictures/Family Memories", "fit": [1920, 1080], "free": 9.2e9, "slideshow": true,
    ]

    static let settings: [String: Any] = [
        "notifyUrl": "http://192.168.1.20:8090/api/notify?k=demo&tvs=all", "shareUrl": "http://192.168.1.20:8090/api/share?k=demo",
        "google": ["clientId": "1234-abc.apps.googleusercontent.com", "hasSecret": true, "connected": true, "redirectUri": "https://blakew316.github.io/woodrufffiles/oauth.html", "text": "Signed in"],
        "tmdb": true, "weather": "Austin, TX", "version": "2.0.214", "crash": "", "awayUrl": "http://100.101.5.7:8090/?k=demo",
        "nest": ["project": "abc-123", "connected": true, "doorbell": "projects/home/subscriptions/doorbell", "doorbellStatus": "", "person": true, "motion": false, "text": "Connected"],
        "mail": [["id": "m1", "email": "family@icloud.com", "provider": "iCloud"]],
        "providers": [["id": "ICLOUD", "label": "iCloud", "help": "Use an app-specific password from appleid.apple.com.", "custom": false],
                      ["id": "GMAIL", "label": "Gmail", "help": "Use an app password.", "custom": false],
                      ["id": "CUSTOM", "label": "Other", "help": "", "custom": true]],
    ]

    static func file(_ n: String, _ dir: Bool, _ size: Double) -> [String: Any] {
        var f: [String: Any] = [:]
        f["name"] = n
        f["path"] = "/storage/emulated/0/" + n
        f["dir"] = dir
        f["size"] = size
        f["modified"] = now
        return f
    }

    static let files: [String: Any] = [
        "path": "/storage/emulated/0", "parent": NSNull(), "free": 18e9,
        "files": [file("DCIM", true, 0), file("Movies", true, 0), file("Pictures", true, 0), file("Music", true, 0), file("Download", true, 0),
                  file("Documents", true, 0), file("Family vacation.mp4", false, 2.2e9), file("Beach sunset.jpg", false, 4e6), file("Playlist.mp3", false, 8e6)],
    ]

    public static var releases: [TVPlatform: Release] {
        let dec = JSONDecoder()
        func r(_ tag: String) -> Release? { try? dec.decode(Release.self, from: Data(#"{"tag_name":"\#(tag)","name":"\#(tag)","assets":[]}"#.utf8)) }
        var out: [TVPlatform: Release] = [:]
        out[.android] = r("v2.0.214")
        out[.webOS] = r("webos-214")
        return out
    }
}

/// Answers requests to the demo hub from `Demo`.
final class DemoURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "demo.woodruff" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url else { return }
        let c = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var q: [String: String] = [:]
        for i in c?.queryItems ?? [] { q[i.name] = i.value ?? "" }
        var data = Data("{\"ok\":true}".utf8)
        var type = "application/json"
        if let name = Demo.image(url.path, q) {
            let file = Bundle.main.url(forResource: name, withExtension: "jpg") ?? Bundle.main.url(forResource: name.replacingOccurrences(of: "bd_", with: ""), withExtension: "jpg")
            if let file, let d = try? Data(contentsOf: file) { data = d; type = "image/jpeg" }
        } else if let obj = Demo.json(url.path, q), let d = try? JSONSerialization.data(withJSONObject: obj) {
            data = d
        }
        let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": type])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}
