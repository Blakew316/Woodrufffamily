import Foundation
import SwiftUI
import WoodruffKit

/// Films and episodes kept on this device to watch with no connection (Settings → Watch → Downloads). They download
/// in the background, carry on with the app closed, use Wi‑Fi only unless cellular is allowed, and play from here
/// when Play is set to play on this device.
@Observable @MainActor
final class DriveDownloads: NSObject {
    static let shared = DriveDownloads()

    struct Item: Codable, Identifiable, Hashable {
        var file: String        // the Drive file
        var title: String       // as the player shows it
        var name: String        // the film or show, for the list
        var detail: String?     // "S2 E4 · Name"
        var poster: String?
        var bytes: Int64 = 0
        var done: Int64 = 0
        var state: String = "waiting"   // waiting, downloading, ready, failed
        var error: String?
        var id: String { file }
        var key: String { "drive:\(file)" }

        enum CodingKeys: String, CodingKey { case file, title, name, detail, poster, bytes, done, state, error }
    }

    private(set) var items: [Item] = []
    @ObservationIgnored private var tasks: [String: URLSessionDownloadTask] = [:]
    /// Getting a token to start (counted with the ones running).
    @ObservationIgnored private var starting: Set<String> = []
    /// Started again once after Google refused the token.
    @ObservationIgnored private var retried: Set<String> = []
    /// One session for good: the system carries on its downloads with the app closed.
    @ObservationIgnored private lazy var session: URLSession = makeSession()
    /// Downloading at once; the rest wait their turn.
    private static let atOnce = 2

    /// Cellular is allowed or not per download (the session allows it, each request says).
    static var cellular: Bool {
        get { UserDefaults.standard.bool(forKey: "watch.cellularDownloads") }
        set { UserDefaults.standard.set(newValue, forKey: "watch.cellularDownloads") }
    }

    nonisolated private static let folder: URL = {
        var dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Watch/Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Not in the iCloud backup: films are large and can be downloaded again.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        return dir
    }()
    nonisolated private static let list = folder.appendingPathComponent("downloads.json")

    override private init() {
        super.init()
        items = (try? JSONDecoder().decode([Item].self, from: Data(contentsOf: Self.list))) ?? []
    }

    private func makeSession() -> URLSession {
        let c = URLSessionConfiguration.background(withIdentifier: "woodruff.watch.downloads")
        c.allowsCellularAccess = true
        c.allowsExpensiveNetworkAccess = true
        c.sessionSendsLaunchEvents = true
        c.isDiscretionary = false
        return URLSession(configuration: c, delegate: self, delegateQueue: .main)
    }

    /// Picks up downloads that went on while the app was closed (and starts ones still waiting).
    func start() {
        session.getAllTasks { [weak self] running in
            Task { @MainActor in
                guard let self else { return }
                for t in running { if let f = t.taskDescription, let d = t as? URLSessionDownloadTask { self.tasks[f] = d } }
                for i in self.items where i.state == "waiting" || (i.state == "downloading" && self.tasks[i.file] == nil) {
                    await self.begin(i.file)
                }
            }
        }
    }

    private func save() {
        if let d = try? JSONEncoder().encode(items) { try? d.write(to: Self.list, options: .atomic) }
    }

    nonisolated static func localFile(_ file: String) -> URL { folder.appendingPathComponent("\(file).mp4") }

    /// The downloaded copy, when there's a finished one.
    func local(_ key: String) -> URL? {
        let f = String(key.dropFirst(key.hasPrefix("drive:") ? 6 : 0))
        guard items.contains(where: { $0.file == f && $0.state == "ready" }) else { return nil }
        let u = Self.localFile(f)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    func item(_ file: String) -> Item? { items.first { $0.file == file } }

    var usedBytes: Int64 { items.filter { $0.state == "ready" }.reduce(0) { $0 + $1.bytes } }

    // MARK: Adding and removing

    func add(file: String, title: String, name: String, detail: String?, poster: String?) {
        guard !items.contains(where: { $0.file == file }) else { return }
        items.append(Item(file: file, title: title, name: TitleText.withoutYear(name), detail: detail, poster: poster))
        save()
        Task { await begin(file) }
    }

    func remove(_ file: String) {
        tasks[file]?.cancel()
        tasks[file] = nil
        try? FileManager.default.removeItem(at: Self.localFile(file))
        items.removeAll { $0.file == file }
        save()
        startWaiting()
    }

    func retry(_ file: String) {
        update(file) { $0.state = "waiting"; $0.error = nil; $0.done = 0 }
        retried.remove(file)
        Task { await begin(file) }
    }

    private func update(_ file: String, _ f: (inout Item) -> Void) {
        guard let i = items.firstIndex(where: { $0.file == file }) else { return }
        f(&items[i])
    }

    /// Starts [file] when there's room (two at a time), else it waits its turn.
    private func begin(_ file: String) async {
        guard tasks[file] == nil, !starting.contains(file) else { return }
        guard tasks.count + starting.count < Self.atOnce else {
            if item(file)?.state != "waiting" {
                update(file) { $0.state = "waiting" }
                save()
            }
            return
        }
        starting.insert(file)
        defer { starting.remove(file) }
        do {
            var r = URLRequest(url: GoogleDrive.mediaURL(file))
            r.setValue("Bearer \(try await GoogleDrive.token())", forHTTPHeaderField: "Authorization")
            r.allowsCellularAccess = Self.cellular
            r.allowsExpensiveNetworkAccess = Self.cellular
            // Removed while the token came.
            guard item(file) != nil else { startWaiting(); return }
            let t = session.downloadTask(with: r)
            t.taskDescription = file
            tasks[file] = t
            update(file) { $0.state = "downloading"; $0.error = nil }
            t.resume()
        } catch {
            update(file) { $0.state = "failed"; $0.error = error.localizedDescription }
        }
        save()
    }

    /// The ones waiting, started while there's room.
    private func startWaiting() {
        for i in items where i.state == "waiting" && tasks[i.file] == nil && !starting.contains(i.file) {
            Task { await begin(i.file) }
        }
    }
}

// Read field by field, so a field added later never loses the list of downloads.
extension DriveDownloads.Item {
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        file = try c.decode(String.self, forKey: .file)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        // The film's or show's name, shown without its year (downloads kept from before names were cleaned too).
        name = try TitleText.withoutYear(c.decodeIfPresent(String.self, forKey: .name) ?? title)
        detail = try c.decodeIfPresent(String.self, forKey: .detail)
        poster = try c.decodeIfPresent(String.self, forKey: .poster)
        bytes = try c.decodeIfPresent(Int64.self, forKey: .bytes) ?? 0
        done = try c.decodeIfPresent(Int64.self, forKey: .done) ?? 0
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? "waiting"
        error = try c.decodeIfPresent(String.self, forKey: .error)
    }
}

extension DriveDownloads: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let f = downloadTask.taskDescription else { return }
        MainActor.assumeIsolated {
            // Shown in whole percents, not at every chunk.
            let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : (item(f)?.bytes ?? 0)
            if let had = item(f), had.state == "downloading", total > 0, had.bytes == total,
               (totalBytesWritten - had.done) * 100 < total { return }
            update(f) { i in
                i.done = totalBytesWritten
                if totalBytesExpectedToWrite > 0 { i.bytes = totalBytesExpectedToWrite }
                i.state = "downloading"
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let f = downloadTask.taskDescription else { return }
        let code = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        // Moved now: the system deletes it when this returns.
        let target = DriveDownloads.localFile(f)
        var moved = false
        var refused: String?
        if code == 200 {
            try? FileManager.default.removeItem(at: target)
            moved = (try? FileManager.default.moveItem(at: location, to: target)) != nil
        } else if code != 0 {
            // Google's answer says why (its daily limit, a file that's gone): read before the system deletes it.
            let small = ((try? FileManager.default.attributesOfItem(atPath: location.path)[.size] as? NSNumber)?.intValue ?? 0) < 65_536
            var body: Data?
            if small { body = try? Data(contentsOf: location) }
            refused = GoogleDrive.failure(code, body).message
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? NSNumber)?.int64Value ?? 0
        MainActor.assumeIsolated {
            if tasks[f] === downloadTask { tasks[f] = nil }
            // The token ran out on the way: once more with a fresh one.
            if code == 401, !retried.contains(f), item(f) != nil {
                retried.insert(f)
                update(f) { $0.state = "waiting"; $0.done = 0 }
                save()
                Task { @MainActor in
                    GoogleDrive.dropToken()
                    await self.begin(f)
                }
                return
            }
            retried.remove(f)
            update(f) { i in
                if moved { i.state = "ready"; i.bytes = size; i.done = size; i.error = nil } else {
                    i.state = "failed"; i.error = refused ?? (code == 200 ? "The download couldn’t be kept on this device." : "The download stopped.")
                }
            }
            save()
            startWaiting()
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let f = task.taskDescription else { return }
        let cancelled = (error as NSError).code == NSURLErrorCancelled
        MainActor.assumeIsolated {
            if tasks[f] === task { tasks[f] = nil }
            guard !cancelled else { return }
            update(f) { $0.state = "failed"; $0.error = error.localizedDescription }
            save()
            startWaiting()
        }
    }
}

// MARK: - Settings → Watch → Downloads

struct DownloadsView: View {
    private let downloads = DriveDownloads.shared
    @State private var cellular = DriveDownloads.cellular

    var body: some View {
        Form {
            Section {
                NavigationLink("Add Downloads") { DownloadPicker() }
                    .disabled(!GoogleDrive.signedIn)
                Toggle("Use Cellular Data", isOn: $cellular)
                    .onChange(of: cellular) { _, v in DriveDownloads.cellular = v }
                LabeledContent("Space Used", value: ByteCountFormatter.string(fromByteCount: downloads.usedBytes, countStyle: .file))
            } footer: {
                Text(GoogleDrive.signedIn ? "Downloads play with no connection when Play is set to play on this device. They carry on with the app closed."
                                          : "Sign in to Google Drive in Settings → Watch to download.")
            }
            if !downloads.items.isEmpty {
                Section("Downloads") {
                    ForEach(downloads.items) { i in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(i.name).font(.body)
                            if let d = i.detail { Text(d).font(.caption).foregroundStyle(.secondary) }
                            switch i.state {
                            case "ready":
                                Text(ByteCountFormatter.string(fromByteCount: i.bytes, countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                            case "failed":
                                HStack {
                                    Text(i.error ?? "Didn’t download.").font(.caption).foregroundStyle(Palette.attention)
                                    Spacer()
                                    Button("Try Again") { downloads.retry(i.file) }.font(.caption)
                                }
                            default:
                                ProgressView(value: i.bytes > 0 ? Double(i.done) / Double(i.bytes) : 0)
                                Text(i.bytes > 0 ? "\(ByteCountFormatter.string(fromByteCount: i.done, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: i.bytes, countStyle: .file))"
                                                 : (i.state == "waiting" ? "Waiting" : "Starting"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions { Button("Remove", role: .destructive) { downloads.remove(i.file) } }
                        .contextMenu { Button("Remove", role: .destructive) { downloads.remove(i.file) } }
                    }
                }
            }
        }
        .familyFormStyle()
        .navigationTitle("Downloads")
        .inlineTitle()
    }
}

/// The Drive library, to pick what to download: films, and a show's seasons and episodes.
private struct DownloadPicker: View {
    private let library = DriveLibrary.shared
    private let downloads = DriveDownloads.shared
    @State private var movies: [Title] = []
    @State private var shows: [Title] = []
    @State private var loaded = false

    var body: some View {
        Form {
            if movies.isEmpty && shows.isEmpty && !loaded {
                HStack { Spacer(); ProgressView(); Spacer() }
            } else if movies.isEmpty && shows.isEmpty {
                Text(library.error ?? "Nothing in the Drive library yet. Open Watch once to read Google Drive.")
                    .foregroundStyle(.secondary)
            }
            if !movies.isEmpty {
                Section("Movies") {
                    ForEach(movies) { t in
                        if let p = t.play {
                            DownloadRow(file: String(p.key.dropFirst(6)), title: p.title, name: t.title, detail: nil, poster: t.poster)
                        }
                    }
                }
            }
            if !shows.isEmpty {
                Section("TV Shows") {
                    ForEach(shows) { t in
                        NavigationLink(t.title) { ShowDownloads(show: t) }
                    }
                }
            }
        }
        .familyFormStyle()
        .navigationTitle("Add Downloads")
        .inlineTitle()
        .task {
            movies = (try? await library.library(place: "movies", sort: "title", unwatched: false, genre: nil, q: nil, offset: 0, limit: 120).items) ?? []
            var all: [Title] = []
            var offset = 0
            while let page = try? await library.library(place: "shows", sort: "title", unwatched: false, genre: nil, q: nil, offset: offset, limit: 120), !page.items.isEmpty {
                all += page.items; offset += page.items.count
                if offset >= page.count { break }
            }
            shows = all
            offset = movies.count
            while let page = try? await library.library(place: "movies", sort: "title", unwatched: false, genre: nil, q: nil, offset: offset, limit: 120), !page.items.isEmpty {
                movies += page.items; offset += page.items.count
                if offset >= page.count { break }
            }
            loaded = true
        }
    }
}

private struct ShowDownloads: View {
    let show: Title
    private let downloads = DriveDownloads.shared
    @State private var details: TitleDetails?
    @State private var picked = 0
    @State private var episodes: [Episode] = []
    @State private var loading = true
    @State private var failed: String?

    var body: some View {
        Form {
            if loading && episodes.isEmpty {
                HStack { Spacer(); ProgressView(); Spacer() }
            } else if let failed, episodes.isEmpty {
                Text(failed).foregroundStyle(Palette.attention)
            }
            if let seasons = details?.seasons, seasons.count > 1 {
                Picker("Season", selection: $picked) {
                    ForEach(Array(seasons.enumerated()), id: \.offset) { i, s in Text(s.name).tag(i) }
                }
            }
            if !episodes.isEmpty {
                Section {
                    Button("Download All \(episodes.count)") {
                        for e in episodes { add(e) }
                    }
                    .disabled(episodes.allSatisfy { downloads.item(String($0.key.dropFirst(6))) != nil })
                }
                Section {
                    ForEach(episodes) { e in
                        DownloadRow(file: String(e.key.dropFirst(6)), title: e.playTitle, name: show.title,
                                    detail: [e.code, e.name].compactMap { $0 }.joined(separator: " · "), poster: show.poster)
                    }
                }
            }
        }
        .familyFormStyle()
        .navigationTitle(show.title)
        .inlineTitle()
        .task {
            do {
                details = try await DriveLibrary.shared.title(show.id)
            } catch {
                failed = error.localizedDescription
                loading = false
                return
            }
            // The season the show is at: picking it reads its episodes (below); the one already picked is read here.
            let start = details?.season ?? 0
            if picked != start { picked = start } else { await load() }
        }
        .onChange(of: picked) { _, _ in Task { await load() } }
    }

    private func load() async {
        guard let s = details?.seasons?[safe: picked] else {
            loading = false
            if details != nil { failed = "No episodes in \(show.title)." }
            return
        }
        loading = true
        do {
            let list = try await DriveLibrary.shared.episodes(show: show.id, season: s.id).episodes
            // Another season picked meanwhile: its own read shows instead.
            guard details?.seasons?[safe: picked]?.id == s.id else { return }
            episodes = list
            failed = list.isEmpty ? "No episodes in \(s.name)." : nil
        } catch {
            guard details?.seasons?[safe: picked]?.id == s.id else { return }
            episodes = []
            failed = error.localizedDescription
        }
        loading = false
    }

    private func add(_ e: Episode) {
        downloads.add(file: String(e.key.dropFirst(6)), title: e.playTitle, name: show.title,
                      detail: [e.code, e.name].compactMap { $0 }.joined(separator: " · "), poster: show.poster)
    }
}

private struct DownloadRow: View {
    let file: String
    let title: String
    let name: String
    let detail: String?
    let poster: String?
    private let downloads = DriveDownloads.shared

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                if let d = detail, !d.isEmpty { Text(d).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            switch downloads.item(file)?.state {
            case "ready": Text("Downloaded").font(.caption).foregroundStyle(.secondary)
            case "downloading", "waiting": ProgressView().controlSize(.small)
            case "failed": Button("Try Again") { downloads.retry(file) }
            default: Button("Download") { downloads.add(file: file, title: title, name: name, detail: detail, poster: poster) }
            }
        }
    }
}
