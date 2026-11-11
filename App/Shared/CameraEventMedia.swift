import Foundation
import UserNotifications
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
#if os(macOS)
import CoreImage
#endif

/// What a camera saw for an alert, from Google: the event's short clip (newer Nest cameras and doorbells send one) or
/// a snapshot of the moment (the older ones; Google makes it only within 30 seconds of the event). Fetched the moment
/// an alert arrives, by the notification extension for a push and by the app for its own alerts, attached to the
/// notification and kept for ten minutes in the family's app group, so tapping the alert replays it above the live view.
///
/// The extension can't read the app's keychain, so the app keeps the cameras' Google sign-in in the app group as well
/// (this iPhone's own container, shared only with Woodruff's extensions).
enum CameraEventMedia {
    static let group = "group.com.woodruff.family"
    private static let sdm = "https://smartdevicemanagement.googleapis.com/v1/"

    private static var store: UserDefaults? { UserDefaults(suiteName: group) }

    static var folder: URL? {
        #if os(macOS)
        // The Mac app isn't in this app group (its own is the team's), so its own temporary folder. Asked for this
        // group's folder, macOS gives the path anyway and then guards it, asking whether to allow access to other
        // apps' data: with nobody at the locked Mac Studio to answer, every alert's picture failed to be written and
        // the alerts went out without one.
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        #else
        let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        #endif
        let f = base.appendingPathComponent("CameraEvents", isDirectory: true)
        try? FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        return f
    }

    // MARK: The last camera push (what the notification extension did with it)

    /// Written by the notification extension for each camera push, shown on Camera Alerts: when, and whether the
    /// alert got a picture (and if not, why).
    static func noteLastPush(_ what: String) {
        (store ?? .standard).set("\(Date().timeIntervalSince1970)|\(what)", forKey: "push.last")
    }

    static var lastPush: (at: Date, what: String)? {
        guard let s = store?.string(forKey: "push.last"), let bar = s.firstIndex(of: "|"),
              let t = Double(s[..<bar]) else { return nil }
        return (Date(timeIntervalSince1970: t), String(s[s.index(after: bar)...]))
    }

    /// Noted by the notification extension the moment a camera push arrives (by the event's short id), so the app
    /// never shows its own copy of that alert. Without it the app could: while the extension was still getting the
    /// push's picture (the alert isn't delivered yet), or after the alert was opened or cleared; and its copy, with no
    /// picture when this iPhone couldn't get one, replaced the push's alert or came as a second one.
    static func notePushKey(_ key: String) {
        guard let s = store, !key.isEmpty else { return }
        let now = Date().timeIntervalSince1970
        var keys = (s.dictionary(forKey: "push.keys") as? [String: Double] ?? [:]).filter { now - $0.value < 3600 }
        keys[key] = now
        s.set(keys, forKey: "push.keys")
    }

    /// Whether the Mac's push for [key] reached this iPhone in the last hour.
    static func pushArrived(_ key: String) -> Bool {
        guard let t = (store?.dictionary(forKey: "push.keys") as? [String: Double])?[key] else { return false }
        return Date().timeIntervalSince1970 - t < 3600
    }

    // MARK: The sign-in, kept current by the app

    static func keepCredentials(clientID: String?, secret: String?, refresh: String?, access: String?, expires: Double?) {
        guard let s = store else { return }
        s.set(clientID, forKey: "cam.client")
        s.set(secret, forKey: "cam.secret")
        s.set(refresh, forKey: "cam.refresh")
        s.set(access, forKey: "cam.access")
        s.set(expires, forKey: "cam.expires")
    }

    static func forgetCredentials() {
        for k in ["cam.client", "cam.secret", "cam.refresh", "cam.access", "cam.expires"] { store?.removeObject(forKey: k) }
    }

    /// A current Google token for the cameras: the one kept, else a fresh one from the refresh token.
    static func token() async -> String? {
        guard let s = store else { return nil }
        if let a = s.string(forKey: "cam.access"), s.double(forKey: "cam.expires") > Date().timeIntervalSince1970 + 30 { return a }
        guard let refresh = s.string(forKey: "cam.refresh"), let id = s.string(forKey: "cam.client"),
              let secret = s.string(forKey: "cam.secret") else { return nil }
        var r = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!, timeoutInterval: 8)
        r.httpMethod = "POST"
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let form = ["refresh_token": refresh, "client_id": id, "client_secret": secret, "grant_type": "refresh_token"]
        r.httpBody = form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&").data(using: .utf8)
        guard let (d, resp) = try? await URLSession.shared.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200,
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let a = j["access_token"] as? String else { return nil }
        let life = (j["expires_in"] as? Double) ?? Double((j["expires_in"] as? Int) ?? 3600)
        s.set(a, forKey: "cam.access")
        s.set(Date().timeIntervalSince1970 + life - 120, forKey: "cam.expires")
        return a
    }

    /// Google refused the kept token before its time (renewed elsewhere): the next `token()` renews it.
    private static func forgetAccess() {
        store?.removeObject(forKey: "cam.expires")
    }

    /// [using] when the caller gave one (the Mac's own sign-in), else the kept one.
    private static func bearer(_ using: String?) async -> String? {
        if let using { return using }
        return await token()
    }

    // MARK: The Mac Studio's picture of the event (CameraShare)

    /// The port the Mac Studio hands out the cameras' pictures on (`CameraShareKey.port`).
    static let sharePort = 8097

    /// Kept by the app (iPhone and iPad) for the notification extension: the key that opens the Mac Studio's pictures
    /// (made from the family code, never the code itself) and the Mac Studio's addresses, home and Tailscale.
    static func keepShare(token: String?, hosts: String?) {
        guard let s = store else { return }
        if let token, !token.isEmpty, s.string(forKey: "cam.shareToken") != token { s.set(token, forKey: "cam.shareToken") }
        if let hosts, !hosts.isEmpty, s.string(forKey: "cam.shareHosts") != hosts { s.set(hosts, forKey: "cam.shareHosts") }
    }

    /// The event's picture the Mac Studio kept for [key] (full size, the moment it alerted for), from whichever of its
    /// addresses answers first; asked again until [deadline] (the Mac may still be making it, or the network is
    /// changing). Saved as the event's snapshot, nil when it can't be had.
    /// [close]: the Mac's close-up of who or what was seen instead (cut from its full-size frame, a small file that
    /// comes quickly even far from home), saved beside the snapshot. Asked for once: with none, the caller cuts its
    /// own from the whole picture.
    static func fromMac(key: String, deadline: Date, close: Bool = false) async -> URL? {
        guard let s = store, let token = s.string(forKey: "cam.shareToken"), !token.isEmpty, let f = folder else { return nil }
        let hosts = (s.string(forKey: "cam.shareHosts") ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty }
        guard !hosts.isEmpty, key.allSatisfy(\.isHexDigit) else { return nil }
        // Asked again soon, and often: an iPhone woken by the alert has no network for its first second or more, and
        // a request made then fails at once. (The close-up was asked for once, so on a sleeping iPhone it never came;
        // the whole picture was asked for again only after longer and longer waits, and ran out of time.)
        var pause = 0.3
        while !Task.isCancelled {
            let left = deadline.timeIntervalSinceNow
            guard left > 0.3 else { return nil }
            // (A request that hangs is given up after a second and a half and made again; one that's coming in has
            // until the deadline.)
            let answered = Answered()
            let idle = min(left, 1.5)
            let jobs: [@Sendable () async -> Data?] = hosts.map { h in
                { await macEvent(h, key: key, token: token, timeout: idle, close: close, answered: answered) }
            }
            if let d = await FirstOf<Data>(jobs.count).run(jobs, deadline: deadline) {
                let file = f.appendingPathComponent(close ? "close-\(key).jpg" : "\(key).jpg")
                if (try? d.write(to: file, options: .atomic)) != nil { return file }
                return nil
            }
            // The Mac answered, and has no close-up of this event (it made none): nothing to ask again for. (Its
            // whole picture is asked for again: the Mac may still be making it.)
            if close, answered.isSet { return nil }
            try? await Task.sleep(nanoseconds: UInt64(min(pause, max(0, deadline.timeIntervalSinceNow - 0.3)) * 1_000_000_000))
            pause = min(pause + 0.15, 1)
        }
        return nil
    }

    /// Whether any of the Mac Studio's addresses answered a request (with a picture or without).
    private final class Answered: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    private static func macEvent(_ host: String, key: String, token: String, timeout: Double, close: Bool, answered: Answered) async -> Data? {
        var c = URLComponents()
        c.scheme = "http"; c.host = host; c.port = sharePort; c.path = close ? "/close" : "/event"
        c.queryItems = [URLQueryItem(name: "id", value: key), URLQueryItem(name: "k", value: token)]
        guard let url = c.url else { return nil }
        var r = URLRequest(url: url, timeoutInterval: timeout)
        r.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (d, resp) = try? await URLSession.shared.data(for: r), let code = (resp as? HTTPURLResponse)?.statusCode else { return nil }
        guard code == 200, d.count > 500 else { answered.set(); return nil }
        return d
    }

    /// The first picture of the event there is, by [deadline]: Google's clip or snapshot ([google] when it's already
    /// being fetched) or the Mac Studio's picture of it, asked for at the same time. nil when neither came.
    /// [prefersMac]: the Mac Studio's picture is the one wanted, whichever comes first (it's the moment the Mac picked
    /// for the alert, with where its subject is; Google's clip is just the clip). Google's is still asked for at the
    /// same time, and used when it has come and the Mac's hasn't a second and a half on (away from home the Mac
    /// can't be reached).
    static func firstPicture(camera: String, eventID: String?, clipURL: String?, key: String, deadline: Date,
                             google: Task<URL?, Never>? = nil, prefersMac: Bool = false) async -> (file: URL, fromMac: Bool)? {
        let fromGoogle: @Sendable () async -> (file: URL, fromMac: Bool)? = {
            let f: URL?
            if let google { f = await google.value }
            else { f = await fetch(camera: camera, eventID: eventID, clipURL: clipURL, key: key, until: deadline) }
            return f.map { ($0, false) }
        }
        if prefersMac {
            // The Mac's picture is asked for until the deadline. Google's stands in for it only from a second and a
            // half on (it's held back until then); with nothing from Google either, the Mac's is waited for to the
            // end. (It was given up after a second and a half whatever Google had, which for most of the family's
            // cameras is nothing: an iPhone still waking its network then showed only the push's small picture.)
            let release = min(deadline, Date().addingTimeInterval(1.5))
            let held: @Sendable () async -> (file: URL, fromMac: Bool)? = {
                guard let got = await fromGoogle() else { return nil }
                let wait = release.timeIntervalSinceNow
                if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
                return got
            }
            let wanted: @Sendable () async -> (file: URL, fromMac: Bool)? = {
                await fromMac(key: key, deadline: deadline).map { ($0, true) }
            }
            return await FirstOf<(file: URL, fromMac: Bool)>(2).run([held, wanted], deadline: deadline)
        }
        let mac: @Sendable () async -> (file: URL, fromMac: Bool)? = {
            await fromMac(key: key, deadline: deadline).map { ($0, true) }
        }
        return await FirstOf<(file: URL, fromMac: Bool)>(2).run([fromGoogle, mac], deadline: deadline)
    }

    // MARK: The clip or snapshot

    /// How long a replay is kept: long enough to tap the alert and watch it, short enough that nothing piles up.
    static let keptFor: TimeInterval = 600
    /// The Mac's picture of each event (what the iPhones fetch, and Send Test Camera Alert's) is kept an hour.
    static let eventKeptFor: TimeInterval = 3600

    /// What's kept for an alert (its short id), if it was fetched and is still fresh.
    static func cached(_ key: String) -> URL? {
        guard let f = folder else { return nil }
        for ext in ["mp4", "jpg"] {
            let u = f.appendingPathComponent("\(key).\(ext)")
            guard FileManager.default.fileExists(atPath: u.path) else { continue }
            if let d = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
               d.timeIntervalSinceNow < -keptFor {
                try? FileManager.default.removeItem(at: u)
                continue
            }
            return u
        }
        return nil
    }

    /// Lets go of every replay older than ten minutes (when an alert arrives, and each time the app opens).
    static func prune() {
        if let f = folder { prune(f) }
    }

    /// The event's clip (from [clipURL]) or else its snapshot (by [eventID]), saved under [key]; nil when Google has
    /// neither for it, or it doesn't come within [timeout] seconds.
    /// [using] is a Google token the caller already has (the Mac's own sign-in); else the one kept for the extension.
    static func fetch(camera: String, eventID: String?, clipURL: String?, key: String, timeout: Double, using: String? = nil) async -> URL? {
        await fetch(camera: camera, eventID: eventID, clipURL: clipURL, key: key, until: Date().addingTimeInterval(timeout), using: using)
    }

    /// The same by [deadline]: the clip and the snapshot are asked for at once, each again while Google isn't ready
    /// (a clip comes a few seconds after the event), and the first that comes is the one.
    static func fetch(camera: String, eventID: String?, clipURL: String?, key: String, until deadline: Date, using: String? = nil) async -> URL? {
        // A clip kept is the best there is; a snapshot kept is replaced only by the event's clip, never asked for again.
        let kept = cached(key)
        if let kept, kept.pathExtension == "mp4" || (clipURL ?? "").isEmpty { return kept }
        guard let f = folder else { return kept }
        prune(f)
        var jobs: [@Sendable () async -> URL?] = []
        if let clipURL, !clipURL.isEmpty, let u = URL(string: clipURL) {
            jobs.append { await clip(u, key: key, folder: f, using: using, deadline: deadline) }
        }
        if kept == nil, let eventID, !eventID.isEmpty {
            jobs.append { await snapshot(camera: camera, eventID: eventID, key: key, folder: f, using: using, deadline: deadline) }
        }
        guard !jobs.isEmpty else { return kept }
        return await FirstOf<URL>(jobs.count).run(jobs, deadline: deadline) ?? kept
    }

    /// Waits before asking Google again: [pause] seconds, never past [deadline].
    private static func again(_ pause: Double, _ deadline: Date) async {
        let s = min(pause, max(0, deadline.timeIntervalSinceNow - 0.5))
        if s > 0 { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }
    }

    /// The event's clip: Google makes it a few seconds after the event, so it's asked for again until it's there.
    private static func clip(_ u: URL, key: String, folder f: URL, using: String?, deadline: Date) async -> URL? {
        var pause = 0.6
        var renewed = false
        while !Task.isCancelled {
            let left = deadline.timeIntervalSinceNow
            guard left > 0.5, let token = await bearer(using) else { return nil }
            var r = URLRequest(url: u, timeoutInterval: min(left, 10))
            r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            // Straight to a file, not into memory (the notification extension has little to spare).
            if let (tmp, resp) = try? await URLSession.shared.download(for: r) {
                let size = (try? tmp.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if code == 200, size > 1000 {
                    let file = f.appendingPathComponent("\(key).mp4")
                    try? FileManager.default.removeItem(at: file)
                    if (try? FileManager.default.moveItem(at: tmp, to: file)) != nil { return file }
                }
                try? FileManager.default.removeItem(at: tmp)
                if code == 401, using == nil, !renewed { renewed = true; forgetAccess(); continue }
                if code == 403 { return nil }
            }
            await again(pause, deadline)
            pause = min(pause * 1.6, 3)
        }
        return nil
    }

    /// The event's snapshot (GenerateImage): Google makes it only within 30 seconds of the event, so it's asked for at
    /// once, and again after a moment when Google is busy or the network drops.
    private static func snapshot(camera: String, eventID: String, key: String, folder f: URL, using: String?, deadline: Date) async -> URL? {
        guard let cmd = URL(string: sdm + camera + ":executeCommand") else { return nil }
        var pause = 0.5
        var renewed = false
        var refused = 0
        while !Task.isCancelled {
            let left = deadline.timeIntervalSinceNow
            guard left > 0.5, let token = await bearer(using) else { return nil }
            var r = URLRequest(url: cmd, timeoutInterval: min(left, 8))
            r.httpMethod = "POST"
            r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try? JSONSerialization.data(withJSONObject: [
                "command": "sdm.devices.commands.CameraEventImage.GenerateImage", "params": ["eventId": eventID],
            ])
            if let (d, resp) = try? await URLSession.shared.data(for: r) {
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if code == 200 {
                    guard let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                          let results = j["results"] as? [String: Any], let url = results["url"] as? String,
                          let imageToken = results["token"] as? String, var c = URLComponents(string: url) else { return nil }
                    c.queryItems = (c.queryItems ?? []) + [URLQueryItem(name: "width", value: "1280")]
                    guard let imageURL = c.url else { return nil }
                    // The picture itself, asked again if the download fails (its link holds a while).
                    var tries = 0
                    while tries < 4, !Task.isCancelled, deadline.timeIntervalSinceNow > 0.3 {
                        tries += 1
                        var g = URLRequest(url: imageURL, timeoutInterval: min(deadline.timeIntervalSinceNow, 8))
                        g.setValue("Basic \(imageToken)", forHTTPHeaderField: "Authorization")
                        if let (img, ok) = try? await URLSession.shared.data(for: g), (ok as? HTTPURLResponse)?.statusCode == 200, img.count > 500 {
                            let file = f.appendingPathComponent("\(key).jpg")
                            return (try? img.write(to: file, options: .atomic)) != nil ? file : nil
                        }
                        await again(0.5, deadline)
                    }
                    return nil
                }
                if code == 401, using == nil, !renewed { renewed = true; forgetAccess(); continue }
                // A camera that makes no snapshots (the newer ones send clips), or the event's 30 seconds are over:
                // asked once more in case it was a moment too soon, then left.
                if (400..<500).contains(code), code != 429 {
                    refused += 1
                    if refused >= 2 { return nil }
                }
            }
            await again(pause, deadline)
            pause = min(pause * 1.6, 2.5)
        }
        return nil
    }

    /// A notification attachment of a kept file (a copy: the system moves what it's given).
    /// [time]: for a clip, how far in its small picture is taken from: the frame the Mac Studio picked for the alert
    /// (`ClipMoment`), when it said; else a second in.
    /// (An alert that closes in on its subject is given a picture cut to it, `closeUp`. iOS can clip an attachment's
    /// small picture to a rectangle itself, and that was used; but it clips its own small copy of the picture, so the
    /// close-up of a figure across the room came out a blur.)
    static func attachment(_ file: URL, identifier: String = "media", at time: Double? = nil) -> UNNotificationAttachment? {
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + file.pathExtension)
        guard (try? FileManager.default.copyItem(at: file, to: copy)) != nil else { return nil }
        var options: [AnyHashable: Any] = [:]
        // A clip's thumbnail (the picture on the alert's right).
        if file.pathExtension == "mp4" { options[UNNotificationAttachmentOptionsThumbnailTimeKey] = time ?? 1 }
        return try? UNNotificationAttachment(identifier: identifier, url: copy, options: options.isEmpty ? nil : options)
    }

    /// The most pixels across a picture is looked at or cut from: a camera's stream at its full size.
    static let fullSide = 1920

    /// The alert's picture close on its subject, as Google Home's is: [file] (a picture, or a clip's frame [time]
    /// seconds in) cut to [focus] (a unit rectangle from the top left) at the picture's full size, written beside
    /// it; nil when it can't be made or would be tiny (the alert then shows the picture whole).
    /// The Mac makes a small cut larger (`enlarged`): opened on an iPhone, a cut 300 pixels across is shown over a
    /// thousand across, and stretched there it's a blur.
    static func closeUp(_ file: URL, focus: CGRect, at time: Double? = nil) async -> URL? {
        #if os(iOS)
        // (An iPhone's notification step has little memory: a clip's frame is made a little smaller there, as it
        // always was. A picture is decoded once at its own size, which takes less than making a smaller copy of it.)
        let side = file.pathExtension == "mp4" ? 1600 : fullSide
        #else
        let side = fullSide
        #endif
        guard let image = await picture(file, maxSide: side, at: time ?? 1),
              let cut = SubjectCrop.crop(image, unit: focus), cut.width >= 64, cut.height >= 64, let f = folder else { return nil }
        #if os(macOS)
        let shown = enlarged(cut) ?? cut
        #else
        let shown = cut
        #endif
        guard let data = jpeg(shown, quality: 0.9) else { return nil }
        let out = f.appendingPathComponent("close-" + file.deletingPathExtension().lastPathComponent + ".jpg")
        return (try? data.write(to: out, options: .atomic)) != nil ? out : nil
    }

    #if os(macOS)
    private static let ci = CIContext(options: [.cacheIntermediates: false])

    /// [cut] made larger, when it's under [least] pixels across: up to two and a half times, by the method that keeps
    /// edges (Lanczos), then sharpened a little. No detail is added (there's none to add), but the phone no longer
    /// stretches a small picture four times with its own soft filter. nil when it's large enough as it is.
    static func enlarged(_ cut: CGImage, least: Int = 640) -> CGImage? {
        let long = max(cut.width, cut.height)
        guard long > 0, long < least, let scale = CIFilter(name: "CILanczosScaleTransform") else { return nil }
        let k = min(2.5, Double(least) / Double(long))
        scale.setValue(CIImage(cgImage: cut), forKey: kCIInputImageKey)
        scale.setValue(k, forKey: kCIInputScaleKey)
        scale.setValue(1.0, forKey: kCIInputAspectRatioKey)
        guard let larger = scale.outputImage else { return nil }
        let whole = CGRect(x: 0, y: 0, width: (Double(cut.width) * k).rounded(.down), height: (Double(cut.height) * k).rounded(.down))
        guard whole.width >= 1, whole.height >= 1 else { return nil }
        var out = larger
        // (Its edges repeated outwards first, so sharpening doesn't darken the picture's border.)
        if let sharpen = CIFilter(name: "CIUnsharpMask") {
            sharpen.setValue(larger.clampedToExtent(), forKey: kCIInputImageKey)
            sharpen.setValue(1.1 * k, forKey: kCIInputRadiusKey)
            sharpen.setValue(0.4, forKey: kCIInputIntensityKey)
            if let sharper = sharpen.outputImage { out = sharper }
        }
        return ci.createCGImage(out, from: whole)
    }

    /// The Mac's close-up of [key]'s event, while it's fresh (CameraShare's GET /close): the iPhones attach it as it
    /// is, with no full-size picture to decode in their little memory.
    static func closeImage(_ key: String) -> Data? {
        guard key.allSatisfy(\.isHexDigit), !key.isEmpty, let u = folder?.appendingPathComponent("close-event-\(key).jpg"),
              let d = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
              d.timeIntervalSinceNow > -eventKeptFor else { return nil }
        return try? Data(contentsOf: u)
    }
    #endif

    /// How many pixels across and down the picture in [file] is, read from its header (nothing is decoded).
    static func pixelSize(_ file: URL) -> (width: Int, height: Int)? {
        guard let src = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
        return pixelSize(src)
    }

    static func pixelSize(_ data: Data) -> (width: Int, height: Int)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return pixelSize(src)
    }

    private static func pixelSize(_ src: CGImageSource) -> (width: Int, height: Int)? {
        guard let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int, w > 0, h > 0 else { return nil }
        return (w, h)
    }

    /// A JPEG of the moment for the widget (as `still`), and where the alert's subject is in the file (a snapshot, or
    /// a clip's frame a second in, as its thumbnail shows): the person for "Person seen", else what stands out, as a
    /// unit rectangle from the top left; nil when nothing is found, and the small picture shows the whole scene. Both
    /// from one look at the file (decoded once: the notification extension has little memory and little time).
    static func stillAndFocus(_ file: URL, title: String) async -> (still: Data?, focus: CGRect?) {
        guard let image = await picture(file, maxSide: 1280) else { return (nil, nil) }
        let focus = SubjectCrop.unitFocus(in: image, kind: SubjectCrop.kind(title))
        let still = scaled(image, maxSide: 480).flatMap { jpeg($0, quality: 0.75) }
        return (still, focus)
    }

    // MARK: The Mac's picture of each event

    /// Where the Mac keeps the picture it alerted with for [key] (full size, for the iPhones and their extensions).
    static func eventFile(_ key: String) -> URL? {
        folder?.appendingPathComponent("event-\(key).jpg")
    }

    /// The kept picture of [key]'s event, while it's fresh (CameraShare's GET /event).
    static func eventImage(_ key: String) -> Data? {
        guard key.allSatisfy(\.isHexDigit), !key.isEmpty, let u = eventFile(key),
              let d = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
              d.timeIntervalSinceNow > -eventKeptFor else { return nil }
        return try? Data(contentsOf: u)
    }

    /// The Mac: the event's picture made ready to go out, from [file] (Google's snapshot or clip, or a frame of the
    /// stream): kept full size under [key] for the iPhones to fetch, where its subject is ([title]: the person for
    /// "Person seen", nothing for motion: the whole picture), and a still for the widget. Decoded once.
    /// [moved]: where the camera's picture changed around the event, when the Mac knows (`StreamMoment.moved`).
    /// A clip isn't looked at a second in whatever it shows there: the frame that shows what the alert is about is
    /// found in it (`ClipMoment`), and how far in that is comes back as [clipTime] (nil for a picture, or a clip that
    /// couldn't be looked through).
    /// [subject]: where the person is in the picture, when whoever picked it already knows (a frame of the stream:
    /// `StreamMoment`), in shares of the picture from its top left: the framing is put round that, and nobody is
    /// looked for again.
    static func keepEventPicture(_ file: URL, key: String, title: String, moved: SubjectCrop.Moved? = nil,
                                 subject: CGRect? = nil) async -> (file: URL, focus: CGRect?, image: CGImage, still: Data?, clipTime: Double?)? {
        let kind = SubjectCrop.kind(title)
        var moved = moved
        var clipTime: Double?
        var found: CGImage?
        #if os(macOS)
        if file.pathExtension == "mp4", let pick = await ClipMoment.best(file, person: kind == .person, maxSide: fullSide) {
            found = pick.image
            clipTime = pick.time
            // Where the clip's own picture changed in that frame says where its subject is better than the stream's
            // last few seconds do (another moment).
            if let there = pick.moved { moved = there }
            PushRelay.log.notice("clip for \(title, privacy: .public): \(pick.why, privacy: .public), the frame \(String(format: "%.1f", pick.time), privacy: .public) s in")
        }
        #endif
        if found == nil { found = await picture(file, maxSide: fullSide) }
        guard let image = found, let out = eventFile(key) else { return nil }
        // A picture that's already a JPEG no larger than that is kept as it came (a frame of the stream, Google's
        // snapshot): made into a JPEG a second time it only loses.
        var kept = false
        if clipTime == nil, file.pathExtension.lowercased() == "jpg", let size = pixelSize(file), max(size.width, size.height) <= fullSide,
           let bytes = try? Data(contentsOf: file) {
            kept = (try? bytes.write(to: out, options: .atomic)) != nil
        }
        if !kept {
            guard let full = jpeg(image, quality: 0.9), (try? full.write(to: out, options: .atomic)) != nil else { return nil }
        }
        var focus: CGRect?
        if kind != .whole, let subject {
            focus = SubjectCrop.unitFocus(around: subject, width: image.width, height: image.height)
        } else {
            let look = max(image.width, image.height) > 1280 ? (scaled(image, maxSide: 1280) ?? image) : image
            // (The looking takes a moment with the Mac's detector: off the main thread.)
            let changed = moved
            focus = await Task.detached(priority: .userInitiated) { SubjectCrop.unitFocus(in: look, kind: kind, moved: changed) }.value
        }
        let still = scaled(image, maxSide: 480).flatMap { jpeg($0, quality: 0.75) }
        return (out, focus, image, still, clipTime)
    }

    /// A focus as the push carries it ("x,y,w,h", unit rectangle from the top left).
    static func focusText(_ r: CGRect) -> String {
        String(format: "%.3f,%.3f,%.3f,%.3f", r.minX, r.minY, r.width, r.height)
    }

    static func focus(_ text: String?) -> CGRect? {
        guard let parts = text?.split(separator: ",").compactMap({ Double($0) }), parts.count == 4,
              parts[2] > 0.01, parts[3] > 0.01 else { return nil }
        let r = CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3]).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        return r.isNull || r.width < 0.01 || r.height < 0.01 ? nil : r
    }

    // MARK: The small picture the Mac sends inside the push

    /// What's left of a push's 4 KB for the picture when nothing else is long (`PushRelay.thumbnailBudget` works out
    /// the room each push really has).
    static let thumbnailLimit = 2200

    /// A small picture of the moment, from a snapshot or a clip's frame a second in, as base64 that fits in a push.
    /// The Mac adds it to a camera's push, so every iPhone has a picture for the alert even when it can't fetch one
    /// (no camera sign-in there, or the snapshot's 30 seconds are over: Send Test Camera Alert).
    static func thumbnail(_ file: URL) async -> String? {
        guard let image = await picture(file) else { return nil }
        return pushThumbnail(image, focus: nil, budget: thumbnailLimit)
    }

    /// The same small picture cropped to who or what the alert is about ([title]: "Person seen" is a person, motion
    /// the whole picture, else what stands out), so the few bytes there are carry the subject in more detail; and
    /// where that subject is in the whole picture (`focus`), for an attachment of the same moment.
    static func subjectThumbnail(_ file: URL, title: String) async -> (thumb: String?, focus: CGRect?) {
        guard let image = await picture(file, maxSide: 1280) else { return (nil, nil) }
        let focus = SubjectCrop.unitFocus(in: image, kind: SubjectCrop.kind(title))
        return (pushThumbnail(image, focus: focus, budget: thumbnailLimit), focus)
    }

    /// The push's small picture of [image] (cropped to [focus] when there is one), as base64 of at most [budget]
    /// characters: the biggest picture that fits, as HEIC when that carries more of it than JPEG does (HEIC holds
    /// about twice the detail in the same bytes; the iPhone turns it back into a JPEG to attach it).
    static func pushThumbnail(_ image: CGImage, focus: CGRect?, budget: Int) -> String? {
        guard budget >= 400 else { return nil }
        let subject = focus.flatMap { SubjectCrop.crop(image, unit: $0) } ?? image
        // What it's for is the alert's small picture (about a hundred pixels across on the screen), so it's sharpness
        // at that size that counts: a good quality first, at the biggest size that fits it, and a lower quality only
        // when even a small picture doesn't fit. (The biggest picture at any quality was tried first before: 300
        // pixels of smear, a fog on the alert.)
        let plans: [(quality: Double, sides: [Int])] = [
            (0.6, [280, 248, 220, 196, 172, 148]),
            (0.46, [220, 196, 172, 148, 124]),
            (0.34, [172, 148, 124, 100]),
            (0.25, [124, 100, 80, 64]),
        ]
        var small: [Int: CGImage] = [:]
        // The first plan a picture of [type] fits (the lower the better), its side, and the picture.
        func best(_ type: String) -> (plan: Int, side: Int, b64: String)? {
            for (n, plan) in plans.enumerated() {
                for side in plan.sides {
                    if small[side] == nil { small[side] = scaled(subject, maxSide: side) }
                    guard let s = small[side] else { continue }
                    // This Mac can't write the format at all.
                    guard let d = encode(s, type: type, quality: plan.quality) else { return nil }
                    let b = d.base64EncodedString()
                    if b.count <= budget { return (n, side, b) }
                }
            }
            return nil
        }
        let j = best(UTType.jpeg.identifier)
        #if os(macOS)
        // HEIC holds more in the same bytes: taken when it gets a better quality in, or the same at a bigger size
        // (the same either way goes as the JPEG every device reads).
        if let h = best(UTType.heic.identifier) {
            guard let j else { return h.b64 }
            if h.plan < j.plan || (h.plan == j.plan && h.side > j.side) { return h.b64 }
        }
        #endif
        return j?.b64
    }

    private static func encode(_ image: CGImage, type: String, quality: Double) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, type as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest) && out.length > 0 ? out as Data : nil
    }

    /// A picture of the moment for the TVs & Cameras widget: a JPEG at most 480 pixels across. [time]: a clip's frame
    /// that far in (a second in when it isn't said).
    static func still(_ file: URL, at time: Double = 1) async -> Data? {
        guard let image = await picture(file, at: time), let small = scaled(image, maxSide: 480) else { return nil }
        return jpeg(small, quality: 0.75)
    }

    /// The moment as an image at most [maxSide] pixels across: the snapshot itself, or a clip's frame [time] seconds
    /// in (a second, unless the Mac Studio picked another: `ClipMoment`; its first frame for a clip shorter than that).
    static func picture(_ file: URL, maxSide: Int = 480, at time: Double = 1) async -> CGImage? {
        if file.pathExtension == "mp4" {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maxSide, height: maxSide)
            if let i = try? await generator.image(at: CMTime(seconds: max(0, time), preferredTimescale: 600)).image { return i }
            return try? await generator.image(at: .zero).image
        }
        guard let src = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                            kCGImageSourceThumbnailMaxPixelSize: maxSide,
                                                            kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
    }

    /// The Mac's small picture as a file to attach (the full clip or snapshot couldn't be fetched here): a JPEG
    /// (a HEIC one is made a JPEG, the picture type every alert can show).
    static func thumbnailFile(_ base64: String) -> URL? {
        guard let d = Data(base64Encoded: base64), d.count > 100 else { return nil }
        var out = d
        // HEIC: "ftyp" four bytes in.
        if d.count > 12, d.subdata(in: 4..<8) == Data("ftyp".utf8) {
            guard let src = CGImageSourceCreateWithData(d as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(src, 0, nil),
                  let j = jpeg(image, quality: 0.92) else { return nil }
            out = j
        }
        let u = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        return (try? out.write(to: u, options: .atomic)) != nil ? u : nil
    }

    /// [data] (a JPEG of the moment) as a file to attach.
    static func jpegFile(_ data: Data, name: String) -> URL? {
        guard let f = folder else { return nil }
        let u = f.appendingPathComponent(name + ".jpg")
        return (try? data.write(to: u, options: .atomic)) != nil ? u : nil
    }

    private static func scaled(_ image: CGImage, maxSide: Int) -> CGImage? {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        let scale = min(1, Double(maxSide) / Double(max(w, h)))
        let nw = max(1, Int(Double(w) * scale)), nh = max(1, Int(Double(h) * scale))
        guard let ctx = CGContext(data: nil, width: nw, height: nh, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: nw, height: nh))
        return ctx.makeImage()
    }

    private static func jpeg(_ image: CGImage, quality: Double) -> Data? {
        encode(image, type: UTType.jpeg.identifier, quality: quality)
    }

    /// Clips and snapshots older than ten minutes are let go, and anything left from the alerts' attachments; the
    /// Mac's pictures of its events, and its close-ups of them, after an hour.
    private static func prune(_ f: URL) {
        let now = Date()
        for u in (try? FileManager.default.contentsOfDirectory(at: f, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            let name = u.lastPathComponent
            let life = name.hasPrefix("event-") || name.hasPrefix("close-event-") ? eventKeptFor : keptFor
            if let d = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate, d < now.addingTimeInterval(-life) {
                try? FileManager.default.removeItem(at: u)
            }
        }
    }
}

/// The first of several ways to get something that comes back with it, or nil when none does by the deadline. The
/// others are stopped, and never waited for (one stuck on a slow network can't hold up the alert).
final class FirstOf<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<T?, Never>?
    private var left: Int
    private var tasks: [Task<Void, Never>] = []

    init(_ count: Int) { left = count }

    func run(_ jobs: [@Sendable () async -> T?], deadline: Date) async -> T? {
        guard !jobs.isEmpty else { return nil }
        left = jobs.count
        return await withCheckedContinuation { (c: CheckedContinuation<T?, Never>) in
            lock.lock(); cont = c; lock.unlock()
            var made: [Task<Void, Never>] = []
            for job in jobs {
                made.append(Task { let r = await job(); self.end(r, counted: true) })
            }
            let wait = max(0, deadline.timeIntervalSinceNow)
            made.append(Task {
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                self.end(nil, counted: false, timeUp: true)
            })
            lock.lock()
            let over = cont == nil
            if !over { tasks = made }
            lock.unlock()
            if over { for t in made { t.cancel() } }
        }
    }

    private func end(_ r: T?, counted: Bool, timeUp: Bool = false) {
        lock.lock()
        if counted { left -= 1 }
        guard let c = cont, r != nil || timeUp || left <= 0 else { lock.unlock(); return }
        cont = nil
        let all = tasks
        tasks = []
        lock.unlock()
        c.resume(returning: r)
        for t in all { t.cancel() }
    }
}
