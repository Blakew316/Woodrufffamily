import Foundation
import UserNotifications
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

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
        // The Mac app has no app group: its own temporary folder (it only needs the file for a moment).
        let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let f = base.appendingPathComponent("CameraEvents", isDirectory: true)
        try? FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        return f
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
        var r = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!, timeoutInterval: 10)
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

    // MARK: The clip or snapshot

    /// How long a replay is kept: long enough to tap the alert and watch it, short enough that nothing piles up.
    static let keptFor: TimeInterval = 600

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
        if let kept = cached(key) { return kept }
        var given = using
        if given == nil { given = await token() }
        guard let f = folder, let token = given else { return nil }
        prune(f)
        if let clipURL, !clipURL.isEmpty, let u = URL(string: clipURL) {
            var r = URLRequest(url: u, timeoutInterval: timeout)
            r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if let (d, resp) = try? await URLSession.shared.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200, d.count > 1000 {
                let file = f.appendingPathComponent("\(key).mp4")
                if (try? d.write(to: file, options: .atomic)) != nil { return file }
            }
        }
        guard let eventID, !eventID.isEmpty, let cmd = URL(string: sdm + camera + ":executeCommand") else { return nil }
        var r = URLRequest(url: cmd, timeoutInterval: timeout)
        r.httpMethod = "POST"
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: [
            "command": "sdm.devices.commands.CameraEventImage.GenerateImage", "params": ["eventId": eventID],
        ])
        guard let (d, resp) = try? await URLSession.shared.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200,
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let results = j["results"] as? [String: Any], let url = results["url"] as? String,
              let imageToken = results["token"] as? String,
              var c = URLComponents(string: url) else { return nil }
        c.queryItems = (c.queryItems ?? []) + [URLQueryItem(name: "width", value: "1280")]
        guard let imageURL = c.url else { return nil }
        var g = URLRequest(url: imageURL, timeoutInterval: timeout)
        g.setValue("Basic \(imageToken)", forHTTPHeaderField: "Authorization")
        guard let (img, ok) = try? await URLSession.shared.data(for: g), (ok as? HTTPURLResponse)?.statusCode == 200, img.count > 500 else { return nil }
        let file = f.appendingPathComponent("\(key).jpg")
        return (try? img.write(to: file, options: .atomic)) != nil ? file : nil
    }

    /// A notification attachment of a kept file (a copy: the system moves what it's given).
    static func attachment(_ file: URL) -> UNNotificationAttachment? {
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + file.pathExtension)
        guard (try? FileManager.default.copyItem(at: file, to: copy)) != nil else { return nil }
        // A clip's thumbnail (the picture on the alert's right) from a second in, where who was seen is usually in view.
        let options: [AnyHashable: Any]? = file.pathExtension == "mp4" ? [UNNotificationAttachmentOptionsThumbnailTimeKey: 1] : nil
        return try? UNNotificationAttachment(identifier: "media", url: copy, options: options)
    }

    // MARK: The small picture the Mac sends inside the push

    /// Most of a push's 4 KB is left for this: a small JPEG of the moment, as base64.
    static let thumbnailLimit = 2400

    /// A small picture of the moment, from a snapshot or a clip's frame a second in, as base64 that fits in a push.
    /// The Mac adds it to a camera's push, so every iPhone has a picture for the alert even when it can't fetch one
    /// (no camera sign-in there, or the snapshot's 30 seconds are over: Send Test Camera Alert).
    static func thumbnail(_ file: URL) async -> String? {
        var image: CGImage?
        if file.pathExtension == "mp4" {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 480, height: 480)
            image = try? await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image
        } else if let src = CGImageSourceCreateWithURL(file as CFURL, nil) {
            image = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                 kCGImageSourceThumbnailMaxPixelSize: 480,
                                                                 kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
        }
        guard let image else { return nil }
        for side in [256, 208, 168, 136, 112] {
            guard let small = scaled(image, maxSide: side) else { continue }
            for quality in [0.6, 0.45, 0.3] {
                if let d = jpeg(small, quality: quality) {
                    let b64 = d.base64EncodedString()
                    if b64.count <= thumbnailLimit { return b64 }
                }
            }
        }
        return nil
    }

    /// The Mac's small picture as a file to attach (the full clip or snapshot couldn't be fetched here).
    static func thumbnailFile(_ base64: String) -> URL? {
        guard let d = Data(base64Encoded: base64), !d.isEmpty else { return nil }
        let u = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        return (try? d.write(to: u, options: .atomic)) != nil ? u : nil
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
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    /// Clips and snapshots older than ten minutes are let go, and anything left from the alerts' attachments.
    private static func prune(_ f: URL) {
        let old = Date().addingTimeInterval(-keptFor)
        for u in (try? FileManager.default.contentsOfDirectory(at: f, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            if let d = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate, d < old {
                try? FileManager.default.removeItem(at: u)
            }
        }
    }
}
