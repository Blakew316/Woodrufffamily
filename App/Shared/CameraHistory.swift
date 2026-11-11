import SwiftUI
import AVFoundation
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

    /// [camera]'s last events, newest first; none when the Mac Studio can't be reached.
    static func events(camera: String) async -> [CameraHistoryEvent] {
        guard let d = await get("/history", id: camera, timeout: 6) else { return [] }
        return (try? JSONDecoder().decode([CameraHistoryEvent].self, from: d)) ?? []
    }

    /// The picture the Mac Studio kept of [event].
    static func picture(_ event: CameraHistoryEvent) async -> Data? {
        guard let d = await get("/event", id: event.key, timeout: 8), d.count > 500 else { return nil }
        return d
    }

    /// [event]'s clip (else its picture) as a file on this device, fetched once.
    static func media(_ event: CameraHistoryEvent) async -> URL? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CameraHistory", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("\(event.key).\(event.clip ? "mp4" : "jpg")")
        if FileManager.default.fileExists(atPath: file.path) { return file }
        guard let d = await get(event.clip ? "/clip" : "/event", id: event.key, timeout: 15), d.count > 500 else { return nil }
        return (try? d.write(to: file, options: .atomic)) != nil ? file : nil
    }
}

#if os(iOS)
/// A camera's last three events under its live picture, listed as Google Home lists them: a small picture of each,
/// what was seen, and when. Tapping one plays it where the live picture is.
struct CameraEventsList: View {
    let camera: String
    /// An event was tapped and its clip (or picture) is on this device.
    var play: (CameraHistoryEvent, URL) -> Void

    @State private var events: [CameraHistoryEvent] = []
    @State private var pictures: [String: UIImage] = [:]
    /// The event being fetched after a tap.
    @State private var opening: String?

    var body: some View {
        VStack(spacing: 3) {
            ForEach(events.prefix(3)) { event in
                Button { open(event) } label: { row(event) }
                    .buttonStyle(.plain)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .environment(\.colorScheme, .dark)
        .task(id: camera) { await watch() }
    }

    private func row(_ event: CameraHistoryEvent) -> some View {
        HStack(spacing: 14) {
            ZStack {
                Color(white: 0.24)
                if let image = pictures[event.key] {
                    Image(uiImage: image).resizable().scaledToFill()
                }
                if opening == event.key { ProgressView().tint(.white) }
            }
            .frame(width: 66, height: 66)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(event.title).font(.body.weight(.medium)).foregroundStyle(.white).lineLimit(2)
                Text(event.when).font(.subheadline).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color(white: 0.16))
        .contentShape(Rectangle())
    }

    /// The list now, and again every twenty seconds while the camera is open (a new event shows by itself).
    private func watch() async {
        while !Task.isCancelled {
            let latest = await CameraHistoryClient.events(camera: camera)
            if !Task.isCancelled, latest != events, !(latest.isEmpty && !events.isEmpty) {
                withAnimation(.smooth(duration: 0.25)) { events = latest }
            }
            for event in latest.prefix(3) where pictures[event.key] == nil {
                guard let d = await CameraHistoryClient.picture(event), !Task.isCancelled else { continue }
                let image = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                    guard let i = UIImage(data: d) else { return nil }
                    return await i.byPreparingThumbnail(ofSize: CGSize(width: 264, height: 264)) ?? i
                }.value
                if let image { pictures[event.key] = image }
            }
            try? await Task.sleep(nanoseconds: 20_000_000_000)
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
#endif
