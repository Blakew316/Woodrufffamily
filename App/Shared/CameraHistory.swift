import SwiftUI
import AVFoundation
import UserNotifications
import WoodruffKit

/// One of a camera's last events, as the Mac Studio keeps it for the camera's own page: what was seen and when, its
/// picture, and its clip when Google sent one (the newer cameras and doorbells do; the older ones a picture only).
struct CameraHistoryEvent: Codable, Equatable, Identifiable {
    /// The event's short id: its picture is GET /event?id=, its clip GET /clip?id=.
    var key: String
    var camera: String
    /// What the alert said ("Person seen").
    var title: String
    /// When it happened (seconds since 1970).
    var at: Double
    /// Its clip is kept.
    var clip: Bool
    /// The clip's length in seconds.
    var seconds: Double?

    var id: String { key }

    /// "7:34 PM · 8 sec": when it happened (with the day, when it wasn't today) and how long its clip is.
    var when: String {
        let date = Date(timeIntervalSince1970: at)
        var text = date.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDateInYesterday(date) {
            text = "Yesterday, " + text
        } else if !Calendar.current.isDateInToday(date) {
            text = date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) + ", " + text
        }
        guard let seconds, seconds >= 1 else { return text }
        let whole = Int(seconds.rounded())
        return text + " · " + (whole >= 60 ? "\(whole / 60) min \(whole % 60) sec" : "\(whole) sec")
    }
}

#if os(macOS)
/// The Mac Studio's keeping of each camera's last events.
///
/// Every alert that goes out already has its picture here, and Google's clip of it when the camera sends one; both
/// were let go of after a few minutes. The last few of each camera are now kept, so the camera's page on the
/// family's devices can list them and play one (`CameraHistoryClient`, the camera share's GET /history and GET /clip).
/// Google doesn't hand over its own history: the list holds what came since this was kept.
@MainActor
enum CameraHistory {
    /// How many of each camera's events are kept (the camera's page shows the last three).
    static let perCamera = 6
    private static var all: [CameraHistoryEvent] = []
    private static var loaded = false

    private static let folder: URL? = {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let f = base.appendingPathComponent("Woodruff Family/CameraHistory", isDirectory: true)
        do { try FileManager.default.createDirectory(at: f, withIntermediateDirectories: true) } catch { return nil }
        return f
    }()

    private static func load() {
        guard !loaded else { return }
        loaded = true
        guard let folder, let d = try? Data(contentsOf: folder.appendingPathComponent("index.json")),
              let kept = try? JSONDecoder().decode([CameraHistoryEvent].self, from: d) else { return }
        all = kept
    }

    private static func save() {
        guard let folder, let d = try? JSONEncoder().encode(all) else { return }
        try? d.write(to: folder.appendingPathComponent("index.json"), options: .atomic)
    }

    private static func file(_ key: String, _ ext: String) -> URL? {
        guard !key.isEmpty, key.count <= 32, key.allSatisfy(\.isHexDigit) else { return nil }
        return folder?.appendingPathComponent("\(key).\(ext)")
    }

    /// An alert went out for [camera] (or its clip came afterwards): its [picture] and its [clip] are kept under
    /// [key], whichever are given. Each camera's older events go, with their files.
    static func keep(key: String, camera: String, title: String, at: Date, picture: URL?, clip: URL?) async {
        guard let jpg = file(key, "jpg"), let mp4 = file(key, "mp4") else { return }
        load()
        let manager = FileManager.default
        if let picture, manager.fileExists(atPath: picture.path) {
            try? manager.removeItem(at: jpg)
            try? manager.copyItem(at: picture, to: jpg)
        }
        var length: Double?
        if let clip, clip.pathExtension == "mp4", manager.fileExists(atPath: clip.path) {
            try? manager.removeItem(at: mp4)
            if (try? manager.copyItem(at: clip, to: mp4)) != nil {
                let seconds = (try? await AVURLAsset(url: mp4).load(.duration))?.seconds ?? 0
                length = seconds.isFinite && seconds > 0 ? seconds : nil
            }
        }
        let hasClip = manager.fileExists(atPath: mp4.path)
        // Nothing to show for it: not listed.
        guard hasClip || manager.fileExists(atPath: jpg.path) else { return }
        var event = all.first { $0.key == key }
            ?? CameraHistoryEvent(key: key, camera: camera, title: title, at: at.timeIntervalSince1970, clip: false, seconds: nil)
        event.clip = hasClip
        if let length { event.seconds = length }
        all.removeAll { $0.key == key }
        all.append(event)
        all.sort { $0.at < $1.at }
        // Each camera's last few stay.
        var counts: [String: Int] = [:]
        var staying: [CameraHistoryEvent] = []
        for e in all.reversed() {
            counts[e.camera, default: 0] += 1
            if counts[e.camera, default: 0] <= perCamera {
                staying.append(e)
            } else {
                for ext in ["jpg", "mp4"] {
                    if let gone = file(e.key, ext) { try? manager.removeItem(at: gone) }
                }
            }
        }
        all = staying.reversed()
        save()
    }

    /// [camera]'s last events, newest first.
    static func events(camera: String) -> [CameraHistoryEvent] {
        load()
        return all.filter { $0.camera == camera }.reversed()
    }

    /// The kept picture of the event [key], and its clip.
    static func picture(_ key: String) -> Data? { file(key, "jpg").flatMap { try? Data(contentsOf: $0) } }
    static func clip(_ key: String) -> Data? { file(key, "mp4").flatMap { try? Data(contentsOf: $0) } }
    /// Whether the event [key] has a clip kept.
    static func hasClip(_ key: String) -> Bool { file(key, "mp4").map { FileManager.default.fileExists(atPath: $0.path) } ?? false }
}
#endif

/// A camera's last events, asked of the Mac Studio (its camera share, on its home address or its Tailscale one,
/// whichever answers first).
enum CameraHistoryClient {
    private static func get(_ path: String, id: String, timeout: Double) async -> Data? {
        guard let token = CameraShareKey.token() else { return nil }
        let hosts = (UserDefaults.standard.string(forKey: CameraShareKey.hostsKey) ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty }
        guard !hosts.isEmpty else { return nil }
        let jobs: [@Sendable () async -> Data?] = hosts.map { host in
            { await ask(host, path, id: id, token: token, timeout: timeout) }
        }
        return await FirstOf<Data>(jobs.count).run(jobs, deadline: Date().addingTimeInterval(timeout + 0.3))
    }

    private static func ask(_ host: String, _ path: String, id: String, token: String, timeout: Double) async -> Data? {
        var c = URLComponents()
        c.scheme = "http"
        c.host = host
        c.port = Int(CameraShareKey.port)
        c.path = path
        c.queryItems = [URLQueryItem(name: "id", value: id), URLQueryItem(name: "k", value: token)]
        guard let url = c.url else { return nil }
        var r = URLRequest(url: url, timeoutInterval: timeout)
        r.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (d, resp) = try? await URLSession.shared.data(for: r),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return d
    }

    /// Whether the Mac Studio answered the last time a list was asked for. While it doesn't (the phone away from
    /// home), pictures and clips come from what this device kept, without waiting on the network for each.
    nonisolated(unsafe) private(set) static var reached = false

    /// [camera]'s last events, newest first; none when the Mac Studio can't be reached (within [timeout] seconds).
    static func events(camera: String, timeout: Double = 6) async -> [CameraHistoryEvent] {
        guard let d = await get("/history", id: camera, timeout: timeout),
              let list = try? JSONDecoder().decode([CameraHistoryEvent].self, from: d) else {
            reached = false
            return []
        }
        reached = true
        #if os(iOS)
        // Kept on this device: the camera's page shows it at once next time, and when the Mac Studio is out of reach.
        if !list.isEmpty { CameraHistoryStore.save(list, camera: camera) }
        #endif
        return list
    }

    #if os(iOS)
    /// The picture of [event]: the Mac Studio's, kept on this device once fetched; else what its alert showed here.
    static func picture(_ event: CameraHistoryEvent) async -> Data? {
        if let f = CameraHistoryStore.has(event.key, "jpg"), let d = try? Data(contentsOf: f) { return d }
        if reached, let d = await get("/event", id: event.key, timeout: 8), d.count > 500 {
            if let f = CameraHistoryStore.file(event.key, "jpg") { try? d.write(to: f, options: .atomic) }
            return d
        }
        return CameraHistoryStore.has(event.key, "alert.jpg").flatMap { try? Data(contentsOf: $0) }
    }

    /// [event]'s clip kept on this device (fetched now if it isn't yet), so it opens at once, and away from home.
    @discardableResult
    static func keepClip(_ event: CameraHistoryEvent) async -> URL? {
        if let f = CameraHistoryStore.has(event.key, "mp4") { return f }
        guard event.clip, reached, let f = CameraHistoryStore.file(event.key, "mp4"),
              let d = await get("/clip", id: event.key, timeout: 15), d.count > 500 else { return nil }
        return (try? d.write(to: f, options: .atomic)) != nil ? f : nil
    }

    /// What opening [event] shows: its clip, else its picture, from this device when it's kept here and from the Mac
    /// Studio when it isn't. Out of the Mac Studio's reach, what this device has: at the least what the alert showed.
    static func media(_ event: CameraHistoryEvent) async -> URL? {
        if let clip = await keepClip(event) { return clip }
        if let f = CameraHistoryStore.has(event.key, "jpg") { return f }
        if let f = CameraHistoryStore.file(event.key, "jpg"),
           let d = await get("/event", id: event.key, timeout: reached ? 8 : 3), d.count > 500,
           (try? d.write(to: f, options: .atomic)) != nil { return f }
        return CameraHistoryStore.has(event.key, "alert.jpg")
    }
    #endif
}

#if os(iOS)
/// What this device knows of each camera's last events, kept on it: the list the Mac Studio last gave, each event's
/// picture and clip once fetched, and the alerts this device has had since, each noted with its full picture by the
/// notification step as it arrived (`CameraEventMedia.noteAlert`). The camera's page shows these at once, and they're
/// all there is while the Mac Studio can't be reached (away from home, or the Mac restarting: the list came up empty).
enum CameraHistoryStore {
    /// How many of a camera's events are kept here.
    static let perCamera = 6

    /// In the family's app group, where the notification step keeps what each alert brings. What was kept in the
    /// app's own folder before comes along once.
    private static let folder: URL? = {
        guard let f = CameraEventMedia.historyFolder else { return nil }
        let manager = FileManager.default
        if let old = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("CameraHistory", isDirectory: true),
           old.standardizedFileURL.path != f.standardizedFileURL.path,
           let files = try? manager.contentsOfDirectory(at: old, includingPropertiesForKeys: nil) {
            for file in files { try? manager.moveItem(at: file, to: f.appendingPathComponent(file.lastPathComponent)) }
            try? manager.removeItem(at: old)
        }
        return f
    }()

    /// A camera's list is kept under a name made from its id (an id is long, with slashes in it).
    private static func list(_ camera: String) -> URL? {
        var h: UInt64 = 0xcbf29ce484222325
        for b in camera.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return folder?.appendingPathComponent("list-\(String(h, radix: 16)).json")
    }

    /// Where the event [key]'s file is kept: "mp4" its clip, "jpg" the Mac Studio's picture of it, "alert.jpg" what
    /// its alert showed on this device.
    static func file(_ key: String, _ ext: String) -> URL? {
        guard !key.isEmpty, key.count <= 32, key.allSatisfy(\.isHexDigit) else { return nil }
        return folder?.appendingPathComponent("\(key).\(ext)")
    }

    /// That file, when it's here.
    static func has(_ key: String, _ ext: String) -> URL? {
        guard let f = file(key, ext), FileManager.default.fileExists(atPath: f.path) else { return nil }
        return f
    }

    /// [camera]'s list as last kept, newest first.
    static func events(camera: String) -> [CameraHistoryEvent] {
        guard let f = list(camera), let d = try? Data(contentsOf: f) else { return [] }
        return (try? JSONDecoder().decode([CameraHistoryEvent].self, from: d)) ?? []
    }

    static func save(_ events: [CameraHistoryEvent], camera: String) {
        guard let f = list(camera), let d = try? JSONEncoder().encode(Array(events.prefix(perCamera))) else { return }
        try? d.write(to: f, options: .atomic)
    }

    /// The alerts the notification step noted as they arrived, for every camera. One whose clip is here says so.
    private static func noted() -> [CameraHistoryEvent] {
        guard let folder, let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return [] }
        var out: [CameraHistoryEvent] = []
        for f in files where f.pathExtension == "json" && !f.lastPathComponent.hasPrefix("list-") {
            guard let d = try? Data(contentsOf: f), var e = try? JSONDecoder().decode(CameraHistoryEvent.self, from: d),
                  file(e.key, "jpg") != nil else { continue }
            e.clip = has(e.key, "mp4") != nil
            out.append(e)
        }
        return out
    }

    /// The kept list with the alerts this device has had for [camera] since (those the notification step noted, and
    /// those still in Notification Centre), newest first. Each such alert's own picture is kept for its row.
    static func known(camera: String) async -> [CameraHistoryEvent] {
        var all = events(camera: camera)
        var added = false
        for e in noted() where e.camera == camera && !all.contains(where: { $0.key == e.key }) {
            all.append(e)
            added = true
        }
        for n in await UNUserNotificationCenter.current().deliveredNotifications() {
            let content = n.request.content
            guard content.userInfo["camera"] as? String == camera, let key = content.userInfo["key"] as? String,
                  file(key, "jpg") != nil, !all.contains(where: { $0.key == key }) else { continue }
            keepAlertMedia(content, key: key)
            all.append(CameraHistoryEvent(key: key, camera: camera, title: content.title.isEmpty ? content.body : content.title,
                                          at: n.date.timeIntervalSince1970, clip: has(key, "mp4") != nil, seconds: nil))
            added = true
        }
        all.sort { $0.at > $1.at }
        let top = Array(all.prefix(perCamera))
        if added { save(top, camera: camera) }
        return top
    }

    /// What an alert showed on this device, kept for its event: its picture (the Mac Studio's when the alert could
    /// fetch it, else the small one the alert came with), and its clip when it had one.
    private static func keepAlertMedia(_ content: UNNotificationContent, key: String) {
        let manager = FileManager.default
        func copied(_ a: UNNotificationAttachment, to out: URL) -> Bool {
            let url = a.url
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            return (try? manager.copyItem(at: url, to: out)) != nil
        }
        if let out = file(key, "mp4"), !manager.fileExists(atPath: out.path),
           let a = content.attachments.first(where: { $0.url.pathExtension.lowercased() == "mp4" }) {
            _ = copied(a, to: out)
        }
        guard let out = file(key, "alert.jpg"), !manager.fileExists(atPath: out.path) else { return }
        if let a = content.attachments.first(where: { ["jpg", "jpeg", "png"].contains($0.url.pathExtension.lowercased()) }),
           copied(a, to: out) { return }
        if let kept = CameraEventMedia.cached(key), kept.pathExtension == "jpg", (try? manager.copyItem(at: kept, to: out)) != nil { return }
        if let t = content.userInfo["thumb"] as? String, let d = Data(base64Encoded: t), d.count > 200 {
            try? d.write(to: out, options: .atomic)
        }
    }

    @MainActor private static var warming = false

    /// Every camera's list, with its last three events' pictures and clips, fetched while the Mac Studio can be
    /// reached (as the app opens, and when iOS wakes it in the background), so they're on this device when it can't
    /// be. (Only each camera's newest clip was fetched ahead: the other two were there only once their camera's page
    /// had been open with the Mac Studio answering.) What no list holds any more is let go of.
    @MainActor static func warm(cameras: [String]) async {
        guard !warming, !cameras.isEmpty else { return }
        warming = true
        defer { warming = false }
        for camera in cameras {
            let list = await CameraHistoryClient.events(camera: camera)
            // Out of reach: nothing to fetch from anywhere.
            if list.isEmpty && !CameraHistoryClient.reached { return }
            for event in list.prefix(3) {
                if Task.isCancelled { return }
                _ = await CameraHistoryClient.picture(event)
                await CameraHistoryClient.keepClip(event)
            }
        }
        prune()
    }

    /// A camera's alert just reached this device and woke the app for it (its push asks for that): the event's full
    /// picture now, and its clip once the Mac Studio has it (it makes one from its stream about eight seconds after
    /// the event), kept here, so the camera's page has both without being opened first. Whether anything came.
    static func keepArriving(camera: String, key: String) async -> Bool {
        guard file(key, "jpg") != nil else { return false }
        let until = Date().addingTimeInterval(18)
        var got = false
        var first = true
        while Date() < until, !Task.isCancelled {
            let list = await CameraHistoryClient.events(camera: camera, timeout: first ? 3 : 5)
            first = false
            // Out of the Mac Studio's reach (away from home): nothing to wait for.
            if list.isEmpty && !CameraHistoryClient.reached { return got }
            if let event = list.first(where: { $0.key == key }) {
                if has(key, "jpg") == nil, await CameraHistoryClient.picture(event) != nil { got = true }
                if has(key, "mp4") != nil { return got }
                if event.clip { return await CameraHistoryClient.keepClip(event) != nil || got }
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        return got
    }

    /// Each camera's newest few stay (those its list holds, and the alerts noted since); the pictures, clips and
    /// notes of every other event go.
    private static func prune() {
        guard let folder, let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
        var byCamera: [String: [CameraHistoryEvent]] = [:]
        for f in files where f.lastPathComponent.hasPrefix("list-") {
            guard let d = try? Data(contentsOf: f), let list = try? JSONDecoder().decode([CameraHistoryEvent].self, from: d) else { continue }
            for e in list { byCamera[e.camera, default: []].append(e) }
        }
        for e in noted() where !(byCamera[e.camera] ?? []).contains(where: { $0.key == e.key }) {
            byCamera[e.camera, default: []].append(e)
        }
        var kept = Set<String>()
        for list in byCamera.values {
            for e in list.sorted(by: { $0.at > $1.at }).prefix(perCamera) { kept.insert(e.key) }
        }
        for f in files where !f.lastPathComponent.hasPrefix("list-") {
            let key = f.lastPathComponent.split(separator: ".").first.map(String.init) ?? ""
            if !kept.contains(key) { try? FileManager.default.removeItem(at: f) }
        }
    }
}

/// A camera's last three events under its live picture: one pane of Liquid Glass as wide as the picture, a row for
/// each event (a small picture of it, what was seen, and when) and nothing else. Tapping one plays it where the live
/// picture is. Nothing shows until the camera has had an event.
struct CameraEventsList: View {
    let camera: String
    /// An event was tapped and its clip (or picture) is on this device.
    var play: (CameraHistoryEvent, URL) -> Void

    @State private var events: [CameraHistoryEvent] = []
    @State private var pictures: [String: UIImage] = [:]
    /// The events whose picture the Mac Studio has been asked for (a row's small picture isn't made a third time).
    @State private var asked: Set<String> = []
    /// The event being fetched after a tap.
    @State private var opening: String?
    @Environment(\.displayScale) private var displayScale

    /// The pane has the camera picture's corners; a row's picture sits ten points inside them.
    private let pane = RoundedRectangle(cornerRadius: 28, style: .continuous)

    var body: some View {
        let shown = Array(events.prefix(3))
        // The stack is always here (the list is fetched from it); the pane only once there's an event to show.
        VStack(spacing: 0) {
            if !shown.isEmpty {
                VStack(spacing: 0) {
                    ForEach(shown) { event in
                        if event.id != shown.first?.id {
                            Rectangle().fill(.white.opacity(0.16))
                                .frame(height: 1 / max(1, displayScale))
                                .padding(.leading, 90)
                        }
                        Button { open(event) } label: { row(event) }
                            .buttonStyle(EventRowPress())
                    }
                }
                .clipShape(pane)
                .glass(pane, interactive: false)
                .padding(.top, 12)
            }
        }
        .environment(\.colorScheme, .dark)
        .task(id: camera) { await watch() }
    }

    private func row(_ event: CameraHistoryEvent) -> some View {
        HStack(spacing: 14) {
            ZStack {
                Color.white.opacity(0.1)
                if let image = pictures[event.key] {
                    Image(uiImage: image).resizable().scaledToFill()
                }
                if opening == event.key {
                    Color.black.opacity(0.35)
                    ProgressView().tint(.white)
                }
            }
            .frame(width: 66, height: 66)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(event.title).font(.body.weight(.medium)).foregroundStyle(.primary).lineLimit(2)
                Text(event.when).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .contentShape(Rectangle())
    }

    /// What this device already knows at once (the list the Mac Studio last gave, and the alerts had since), then the
    /// Mac Studio's list now, and again every twenty seconds while the camera is open (a new event shows by itself).
    /// Out of its reach (the phone away from home) the list stays what this device knows.
    private func watch() async {
        let known = await CameraHistoryStore.known(camera: camera)
        if !Task.isCancelled, events.isEmpty, !known.isEmpty {
            withAnimation(.smooth(duration: 0.3)) { events = known }
        }
        await thumbnails(known)
        while !Task.isCancelled {
            var latest = await CameraHistoryClient.events(camera: camera)
            if latest.isEmpty { latest = await CameraHistoryStore.known(camera: camera) }
            if !Task.isCancelled, latest != events, !(latest.isEmpty && !events.isEmpty) {
                withAnimation(.smooth(duration: 0.3)) { events = latest }
            }
            await thumbnails(latest)
            // Their clips are kept on this device too: each opens at once, and away from home.
            for event in latest.prefix(3) where event.clip && !Task.isCancelled {
                await CameraHistoryClient.keepClip(event)
            }
            try? await Task.sleep(nanoseconds: 20_000_000_000)
        }
    }

    /// The rows' small pictures: of the Mac Studio's picture of each event, else of what its alert showed.
    private func thumbnails(_ list: [CameraHistoryEvent]) async {
        for event in list.prefix(3) {
            // Made once from what this device has; once more when the Mac Studio could be asked for its picture.
            if pictures[event.key] != nil, asked.contains(event.key) || !CameraHistoryClient.reached { continue }
            let reached = CameraHistoryClient.reached
            guard let d = await CameraHistoryClient.picture(event), !Task.isCancelled else { continue }
            let image = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                guard let i = UIImage(data: d) else { return nil }
                return await i.byPreparingThumbnail(ofSize: CGSize(width: 264, height: 264)) ?? i
            }.value
            if reached { asked.insert(event.key) }
            if let image { pictures[event.key] = image }
        }
    }

    private func open(_ event: CameraHistoryEvent) {
        guard opening == nil else { return }
        opening = event.key
        Task {
            let file = await CameraHistoryClient.media(event)
            opening = nil
            if let file { play(event, file) }
        }
    }
}

/// A row of the events pane lightens under a finger; the glass is the pane's, not the row's.
private struct EventRowPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color.white.opacity(configuration.isPressed ? 0.12 : 0))
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}
#endif
