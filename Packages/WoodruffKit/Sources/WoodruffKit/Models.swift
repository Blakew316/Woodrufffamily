import Foundation

// The JSON the TVs send, field for field (see the TV apps' server/Companion.kt and webos/service/src/*.js).
// Everything a TV might leave out is optional, so older and newer TVs both decode.

/// What a TV is playing (NowPlaying.toJson).
public struct NowPlaying: Codable, Hashable, Sendable {
    public var title: String
    public var subtitle: String?
    public var app: String?
    public var playing: Bool?
    public var position: Double?
    public var duration: Double?
    public var can: [String]?
    public var key: String?
    /// When `position` was true (set by the app when the answer arrives; the TVs don't send it). With it, the
    /// position right now is `position` plus the time since, while it plays.
    public var reportedAt: Date? = nil

    enum CodingKeys: String, CodingKey {
        case title, subtitle, app, playing, position, duration, can, key
    }

    public var isPlaying: Bool { playing ?? false }
    public func can(_ action: String) -> Bool { can?.contains(action) ?? false }

    /// The names a TV's own input app goes by (the app that shows an HDMI box or the aerial).
    static let inputApps: Set<String> = ["tv", "live tv", "live channels", "tv input", "input", "inputs", "source", "sources"]

    /// What the TV calls playing is only one of its inputs on screen: an HDMI box such as the Apple TV, shown by the
    /// TV's own input app. Android says such an input "plays" for as long as it's on, under the input's name ("Apple
    /// TV HDMI 4"), with no length and nothing of its own to tell; the TV can't see what the box itself is doing. It
    /// isn't something playing: the app showed it as a film that never stopped.
    public var isInput: Bool {
        guard (key ?? "").isEmpty, (duration ?? 0) <= 0 else { return false }
        if title.range(of: "hdmi", options: .caseInsensitive) != nil { return true }
        return Self.inputApps.contains((app ?? "").trimmingCharacters(in: .whitespaces).lowercased())
    }
    public var progress: Double? {
        guard let d = duration, d > 0, let p = position else { return nil }
        return min(1, max(0, p / d))
    }

    /// Milliseconds played at [date]: where the TV said it was, plus the time since, while it plays (never past the end).
    public func estimatedPosition(at date: Date) -> Double {
        let base = position ?? 0
        guard isPlaying, let since = reportedAt else { return base }
        var pos = base + max(0, date.timeIntervalSince(since)) * 1000
        if let d = duration, d > 0 { pos = min(d, pos) }
        return pos
    }

    /// This answer (just arrived, at [now]) laid over what was shown before, so a progress bar keeps moving
    /// smoothly: a new title, a pause, a play or a seek shows at once, but a slightly stale position (a hub
    /// relaying a linked TV, a slow answer) never pulls the bar backwards. While nothing changes the result
    /// equals [old], so nothing redraws for it.
    public func smoothed(after old: NowPlaying?, now: Date) -> NowPlaying {
        var fresh = self
        fresh.reportedAt = now
        guard let old, let oldAt = old.reportedAt else { return fresh }
        var same = self
        same.reportedAt = oldAt
        if same == old { return old }
        guard isPlaying, old.isPlaying, title == old.title, key == old.key,
              let pos = position, let was = old.position else { return fresh }
        let elapsed = now.timeIntervalSince(oldAt)
        guard elapsed >= 0 else { return fresh }
        var expected = was + elapsed * 1000
        if let d = duration, d > 0 { expected = min(d, expected) }
        let drift = pos - expected
        // Further along than the bar (a skip forward), or well behind it (a skip back): show the TV's word.
        if drift > NowPlaying.aheadTolerance || drift < -NowPlaying.behindTolerance { return fresh }
        // Where the bar already is: keep its clock (re-anchored now and then, never backwards).
        var kept = self
        if elapsed < NowPlaying.reanchorAfter {
            kept.position = was
            kept.reportedAt = oldAt
        } else {
            kept.position = max(pos, expected)
            kept.reportedAt = now
        }
        return kept
    }

    /// How far (ms) an answer may run ahead of, or behind, the bar before it counts as a jump.
    static let aheadTolerance: Double = 1_500
    static let behindTolerance: Double = 5_000
    /// Seconds between re-anchoring a bar that agrees with the TV.
    static let reanchorAfter: TimeInterval = 10
}

public struct HealthSummary: Codable, Hashable, Sendable {
    public var status: String
    public var count: Int?
    public var first: String?
}

public struct TVStatus: Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var onScreen: Bool?
    public var version: String?
    public var playing: NowPlaying?
    public var health: HealthSummary?
}

public struct TVListEntry: Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var online: Bool
    public var onScreen: Bool?
    public var playing: NowPlaying?
    public var version: String?
    public var seen: Double?
    public var link: String?
    public var health: HealthSummary?
}

public struct TVList: Codable, Sendable { public var tvs: [TVListEntry] }

// MARK: Health

public struct SignInRow: Codable, Hashable, Sendable {
    public var state: String?
    public var text: String?
    public var attention: Bool?
    public var since: Double?
    public var detail: String?
}

public struct AttentionItem: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var words: String
    public var detail: String?
    public var fix: String?
    public var grant: String?
}

public struct HealthReport: Codable, Hashable, Sendable {
    public struct Updates: Codable, Hashable, Sendable {
        public var step: String?
        public var text: String?
        public var attention: Bool?
        public var auto: Bool?
        public var testTv: Bool?
        public var asks: Bool?
        public var reason: String?
    }
    public struct InstalledBy: Codable, Hashable, Sendable {
        public var summary: String?
        public var by: String?
        public var firstInstall: Double?
        public var lastUpdate: Double?
    }
    public struct Row: Codable, Hashable, Sendable {
        public var text: String?
        public var reason: String?
        public var allowed: Bool?
        public var attention: Bool?
        public var detail: String?
    }
    public struct Crash: Codable, Hashable, Sendable {
        public var at: Double?
        public var text: String?
        public var attention: Bool?
        public var summary: String?
        public var lines: String?
        public var report: String?
    }
    public struct Space: Codable, Hashable, Sendable {
        public var free: Double?
        public var text: String?
        public var attention: Bool?
    }
    public struct Keys: Codable, Hashable, Sendable {
        public var text: String?
        public var googleClientId: Bool?
        public var googleClientSecret: Bool?
        public var camerasProject: Bool?
        public var tmdb: Bool?
    }
    public struct SignIns: Codable, Hashable, Sendable {
        public var drive: SignInRow?
        public var photos: SignInRow?
        public var calendar: SignInRow?
        public var cameras: SignInRow?
        public var doorbell: SignInRow?

        public var rows: [(String, SignInRow)] {
            [("Google Drive", drive), ("Google Photos", photos), ("Google Calendar", calendar), ("Cameras", cameras), ("Doorbell alerts", doorbell)]
                .compactMap { n, r in r.map { (n, $0) } }
        }
    }

    public var id: String?
    public var name: String?
    public var at: Double?
    public var android: Int?
    public var version: String?
    public var platformName: String?
    public var status: String?
    public var sentence: String?
    public var attention: [AttentionItem]?
    public var installedBy: InstalledBy?
    public var updates: Updates?
    public var lastUpdateTry: Row?
    public var installPermission: Row?
    public var popUps: Row?
    public var signIns: SignIns?
    public var lastCrash: Crash?
    public var closedByAndroid: Row?
    public var freeSpace: Space?
    public var keys: Keys?
    public var uptime: Double?
    public var via: String?

    enum CodingKeys: String, CodingKey {
        case id, name, at, android, version, status, sentence, attention, installedBy, updates, lastUpdateTry, installPermission, popUps
        case signIns, lastCrash, closedByAndroid, freeSpace, keys, uptime, via
        case platformName = "platform"
    }

    /// webOS reports `platform: "webos"` and `android: 0`.
    public var platform: TVPlatform? {
        if platformName?.lowercased() == "webos" { return .webOS }
        if let a = android, a > 0 { return .android }
        return nil
    }

    public var needsAttention: Bool { status == "attention" || !(attention ?? []).isEmpty }

    /// The whole report as text, for Copy (as the phone page builds it).
    public var asText: String {
        var lines = ["\(name ?? "TV") · Woodruff \(version ?? "?")", sentence ?? ""]
        for a in attention ?? [] { lines.append("• \(a.words)" + (a.detail.map { " — \($0)" } ?? "")) }
        if let u = updates { lines.append("Updates: \(u.text ?? "")" + (u.reason.map { " (\($0))" } ?? "")) }
        if let i = installedBy?.summary { lines.append("Installed: \(i)") }
        for (n, r) in signIns?.rows ?? [] { lines.append("\(n): \(r.text ?? r.state ?? "")") }
        if let s = freeSpace?.text { lines.append("Space: \(s)") }
        if let k = keys?.text { lines.append("Keys: \(k)") }
        if let c = lastCrash?.summary { lines.append("Last crash: \(c)") }
        if let v = via { lines.append("Via \(v)") }
        return lines.filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

/// /api/tvs/health's 409: the TV is off, refused, didn't answer or is too old; with its last report.
public struct HealthUnavailable: Codable, Hashable, Sendable, LocalizedError {
    public var errorDescription: String? { message }
    public var status: String
    public var message: String
    public var version: String?
    public var seen: Double?
    public var last: HealthReport?
}

// MARK: Keyboard

public struct TypeField: Codable, Hashable, Sendable {
    public var id: JSONValue
    public var label: String?
    public var secret: Bool?
    public var multiline: Bool?
    public var text: String?
}

public struct TypeState: Codable, Hashable, Sendable {
    public var field: TypeField?
    public var note: String?
}

// MARK: Phones & inbox

public struct Phone: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var alerts: Bool?
    public var seen: Double?
    public var topic: String?
}

public struct PhoneHello: Codable, Sendable {
    public var phone: Phone
    public var phones: [Phone]
}

public struct PhoneList: Codable, Sendable { public var phones: [Phone] }

public struct InboxMessage: Codable, Hashable, Sendable, Identifiable {
    public var seq: Int
    public var title: String
    public var body: String?
    public var from: String?
    public var at: Double?
    public var msgID: String?
    public var link: String?
    public var id: String { msgID ?? "seq-\(seq)" }

    enum CodingKeys: String, CodingKey {
        case seq, title, body, from, at, link
        case msgID = "id"
    }
}

public struct Inbox: Codable, Sendable {
    public var messages: [InboxMessage]
    public var seq: Int?
    public var epoch: String?
}

public struct AnnounceResult: Codable, Sendable {
    public var phones: Int?
    public var tvs: Int?
}

// MARK: Files

public struct StorageRoot: Codable, Hashable, Sendable, Identifiable {
    public var name: String
    public var path: String
    public var removable: Bool?
    public var free: Double?
    public var id: String { path }
}

public struct FileEntry: Codable, Hashable, Sendable, Identifiable {
    public var name: String
    public var path: String
    public var dir: Bool
    public var size: Double?
    public var modified: Double?
    public var id: String { path }

    public var ext: String { (name as NSString).pathExtension.lowercased() }
    public var isImage: Bool { ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp"].contains(ext) }
    public var isVideo: Bool { ["mp4", "m4v", "mkv", "webm", "mov", "avi", "ts", "m2ts", "wmv", "flv", "3gp", "mpg", "mpeg"].contains(ext) }
    public var isAudio: Bool { ["mp3", "m4a", "aac", "flac", "ogg", "wav", "opus", "wma"].contains(ext) }
    public var isMedia: Bool { isImage || isVideo || isAudio }
}

public struct FolderListing: Codable, Sendable {
    public var path: String
    public var parent: String?
    public var free: Double?
    public var files: [FileEntry]
}

public struct PlayResult: Codable, Sendable {
    public var started: JSONValue?
    public var message: String?
    public var tv: String?
    public var of: Int?
    public var failed: [String]?
}

// MARK: Family Memories

public struct MemoryItem: Codable, Hashable, Sendable, Identifiable {
    public var path: String
    public var name: String
    public var video: Bool
    public var taken: Double?
    public var size: Double?
    public var v: Double?
    public var id: String { path }
    public var version: String { v.flatMap { $0.isFinite ? Int(exactly: $0.rounded(.towardZero)) : nil }.map(String.init) ?? "0" }
    public var takenDate: Date? { taken.map { Date(timeIntervalSince1970: $0 / 1000) } }
}

/// Equatable, so an answer that brings nothing new is told apart (the Memories page redraws only when something changed).
public struct Memories: Codable, Sendable, Equatable {
    public var items: [MemoryItem]
    public var folder: String?
    public var fit: [Double]?
    public var free: Double?
    public var slideshow: Bool?
}

public struct MemoryAdded: Codable, Sendable { public var item: MemoryItem }

// MARK: Watch

public struct PlayAction: Codable, Hashable, Sendable {
    public var key: String
    public var title: String
    public var position: Double?
    public var label: String?
    public var duration: Double?
    public var resume: Bool?
    public var latest: Bool?
    public var isDrive: Bool { key.hasPrefix("drive:") }

    public init(key: String, title: String, position: Double?, label: String?, duration: Double?, resume: Bool?, latest: Bool?) {
        self.key = key; self.title = title; self.position = position; self.label = label
        self.duration = duration; self.resume = resume; self.latest = latest
    }
}

public struct Title: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var kind: String
    public var title: String
    public var year: Int?
    public var poster: String?
    public var backdrop: String?
    public var genres: [String]?
    public var rating: Double?
    public var watched: Bool?
    public var caption: String?
    public var added: Double?
    public var play: PlayAction?

    enum CodingKeys: String, CodingKey { case id, kind, title, year, poster, backdrop, genres, rating, watched, caption, added, play }
}

public struct ContinueItem: Codable, Hashable, Sendable, Identifiable {
    public var key: String
    public var playTitle: String
    public var titleId: String?
    public var kind: String
    public var name: String
    public var code: String?
    public var episode: String?
    public var position: Double?
    public var duration: Double?
    public var upNext: Bool?
    public var poster: String?
    public var drive: Bool?
    public var play: PlayAction
    public var restart: PlayAction?
    public var id: String { key }
    public var progress: Double { guard let d = duration, d > 0 else { return 0 }; return min(1, (position ?? 0) / d) }

    enum CodingKeys: String, CodingKey {
        case key, playTitle, titleId, kind, name, code, episode, position, duration, upNext, poster, drive, play, restart
    }
}

public struct Episode: Codable, Hashable, Sendable, Identifiable {
    public var key: String
    public var playTitle: String
    public var code: String?
    public var number: Int?
    public var special: Bool?
    public var name: String
    public var overview: String?
    public var still: String?
    public var runtime: Double?
    public var position: Double?
    public var duration: Double?
    public var watched: Bool?
    public var upNext: Bool?
    public var new: Bool?
    public var id: String { key }
    public var progress: Double { guard let d = duration, d > 0 else { return 0 }; return min(1, (position ?? 0) / d) }
}

public struct Shelf: Codable, Hashable, Sendable {
    public var count: Int
    public var items: [Title]
}

/// Equatable, so the library asked for again every couple of minutes is kept (and redrawn) only when it changed.
public struct WatchHome: Codable, Sendable, Equatable {
    public var state: String
    public var tv: String?
    public var updated: Double?
    public var featured: [Title]?
    public var `continue`: [ContinueItem]?
    public var recent: [Title]?
    public var movies: Shelf?
    public var shows: Shelf?
}

public struct LibraryPage: Codable, Sendable {
    public var state: String
    public var count: Int
    public var offset: Int
    public var items: [Title]
    public var genres: [String]?
    public var rated: Bool?
    public var capped: Int?
}

public struct SearchResults: Codable, Sendable {
    public var state: String
    public var q: String?
    public var first: String?
    public var movies: [Title]
    public var shows: [Title]
}

public struct Season: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
}

public struct TitleDetails: Codable, Sendable {
    public var id: String
    public var kind: String
    public var title: String
    public var year: Int?
    public var poster: String?
    public var backdrop: String?
    public var genres: [String]?
    public var rating: Double?
    public var caption: String?
    public var overview: String?
    public var runtime: Double?
    public var ageRating: String?
    public var cast: [String]?
    public var seasons: [Season]?
    public var season: Int?
    public var films: [Episode]?
    public var play: PlayAction?
    public var restart: PlayAction?
    public var playMinutes: Double?
    public var playName: String?
    public var watchKey: String?
    public var watched: Bool?

    enum CodingKeys: String, CodingKey {
        case id, kind, title, year, poster, backdrop, genres, rating, caption, overview, runtime, ageRating, cast, seasons, season
        case films, play, restart, playMinutes, playName, watchKey, watched
    }
}

public struct EpisodeList: Codable, Sendable {
    public var state: String
    public var episodes: [Episode]
}

// Read as the synthesized ones would, but with the film's or show's name shown without its year ("Vice (2018)" is
// "Vice"): done here, as each answer is read, so every page (and every title added later) shows the same name. What
// plays (`play`, `playTitle`) is left as the TV named it.

extension Title {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decode(String.self, forKey: .kind)
        title = try TitleText.withoutYear(c.decode(String.self, forKey: .title))
        year = try c.decodeIfPresent(Int.self, forKey: .year)
        poster = try c.decodeIfPresent(String.self, forKey: .poster)
        backdrop = try c.decodeIfPresent(String.self, forKey: .backdrop)
        genres = try c.decodeIfPresent([String].self, forKey: .genres)
        rating = try c.decodeIfPresent(Double.self, forKey: .rating)
        watched = try c.decodeIfPresent(Bool.self, forKey: .watched)
        caption = try c.decodeIfPresent(String.self, forKey: .caption)
        added = try c.decodeIfPresent(Double.self, forKey: .added)
        play = try c.decodeIfPresent(PlayAction.self, forKey: .play)
    }
}

extension ContinueItem {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        playTitle = try c.decode(String.self, forKey: .playTitle)
        titleId = try c.decodeIfPresent(String.self, forKey: .titleId)
        kind = try c.decode(String.self, forKey: .kind)
        name = try TitleText.withoutYear(c.decode(String.self, forKey: .name))
        code = try c.decodeIfPresent(String.self, forKey: .code)
        episode = try c.decodeIfPresent(String.self, forKey: .episode)
        position = try c.decodeIfPresent(Double.self, forKey: .position)
        duration = try c.decodeIfPresent(Double.self, forKey: .duration)
        upNext = try c.decodeIfPresent(Bool.self, forKey: .upNext)
        poster = try c.decodeIfPresent(String.self, forKey: .poster)
        drive = try c.decodeIfPresent(Bool.self, forKey: .drive)
        play = try c.decode(PlayAction.self, forKey: .play)
        restart = try c.decodeIfPresent(PlayAction.self, forKey: .restart)
    }
}

extension TitleDetails {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decode(String.self, forKey: .kind)
        title = try TitleText.withoutYear(c.decode(String.self, forKey: .title))
        year = try c.decodeIfPresent(Int.self, forKey: .year)
        poster = try c.decodeIfPresent(String.self, forKey: .poster)
        backdrop = try c.decodeIfPresent(String.self, forKey: .backdrop)
        genres = try c.decodeIfPresent([String].self, forKey: .genres)
        rating = try c.decodeIfPresent(Double.self, forKey: .rating)
        caption = try c.decodeIfPresent(String.self, forKey: .caption)
        overview = try c.decodeIfPresent(String.self, forKey: .overview)
        runtime = try c.decodeIfPresent(Double.self, forKey: .runtime)
        ageRating = try c.decodeIfPresent(String.self, forKey: .ageRating)
        cast = try c.decodeIfPresent([String].self, forKey: .cast)
        seasons = try c.decodeIfPresent([Season].self, forKey: .seasons)
        season = try c.decodeIfPresent(Int.self, forKey: .season)
        films = try c.decodeIfPresent([Episode].self, forKey: .films)
        play = try c.decodeIfPresent(PlayAction.self, forKey: .play)
        restart = try c.decodeIfPresent(PlayAction.self, forKey: .restart)
        playMinutes = try c.decodeIfPresent(Double.self, forKey: .playMinutes)
        playName = try c.decodeIfPresent(String.self, forKey: .playName)
        watchKey = try c.decodeIfPresent(String.self, forKey: .watchKey)
        watched = try c.decodeIfPresent(Bool.self, forKey: .watched)
    }
}

// MARK: Settings

/// Equatable, so a read that brings nothing new is told apart (the Settings pages redraw only when something changed).
public struct TVSettings: Codable, Sendable, Equatable {
    public struct Google: Codable, Sendable, Equatable {
        public var clientId: String?
        public var hasSecret: Bool?
        public var connected: Bool?
        public var redirectUri: String?
        public var state: String?
        public var text: String?
        public var statusText: String {
            if let text { return text }
            if connected == true { return "Signed in" }
            return hasSecret == true ? "Not signed in" : "Not set up"
        }
    }
    public struct Nest: Codable, Sendable, Equatable {
        public var project: String?
        public var connected: Bool?
        public var doorbell: String?
        public var doorbellStatus: String?
        public var person: Bool?
        public var motion: Bool?
        public var state: String?
        public var text: String?
        public var statusText: String {
            if let text { return text }
            if connected == true { return "Connected" }
            return (project ?? "").isEmpty ? "Not set up" : "Not connected"
        }
    }
    public struct MailAccount: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        public var email: String
        public var provider: String?
    }
    public struct Provider: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        public var label: String
        public var help: String?
        public var custom: Bool?
    }
    public var notifyUrl: String?
    public var shareUrl: String?
    public var google: Google?
    public var tmdb: Bool?
    public var weather: String?
    public var version: String?
    public var crash: String?
    public var awayUrl: String?
    public var nest: Nest?
    public var mail: [MailAccount]?
    public var providers: [Provider]?
    public var note: String?
}

public struct SignInStart: Codable, Sendable {
    public var state: String
    public var authUrl: String
    public var expiresAt: Double?
    public var again: Bool?
    public var tv: String?
}

public struct SignInStatus: Codable, Sendable {
    public var status: String
    public var message: String?
    public var weekly: Bool?
    public var isFinal: Bool { ["signedIn", "cancelled", "failed", "replaced", "expired"].contains(status) }
}

public struct RelinkResult: Codable, Sendable {
    public var name: String
    public var id: String
}

// MARK: - Notes

/// A note kept on the TV (Command Center → Notes there).
public struct TVNote: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var body: String
    /// When it was last changed (ms since 1970).
    public var updated: Double
    public var pinned: Bool?

    public init(id: String, title: String, body: String, updated: Double, pinned: Bool? = nil) {
        self.id = id
        self.title = title
        self.body = body
        self.updated = updated
        self.pinned = pinned
    }

    public var isPinned: Bool { pinned ?? false }
    public var updatedAt: Date { Date(timeIntervalSince1970: updated / 1000) }
}

struct TVNoteList: Decodable { var notes: [TVNote] }
struct TVNoteSaved: Decodable { var note: TVNote? }
