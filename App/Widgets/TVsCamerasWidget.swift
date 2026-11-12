import SwiftUI
import WidgetKit
import ActivityKit
import ImageIO

// The TVs & Cameras widget (medium): Master Bedroom, Living Room and Kyler's Room down the left, with what each is
// playing (none is marked as the remote's: a tap on any opens the remote on it); the Doorbell and Front Driveway's
// latest pictures on the right. A camera opens it live.

struct TVsCamerasWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: PhoneWidgetShare.tvsCamerasKind, provider: ShareProvider()) { entry in
            TVsCamerasView(s: entry.s, cameras: PhoneWidgetShare.loadCameras(), date: entry.date)
                .environment(\.colorScheme, .dark)
                .containerBackground(for: .widget) {
                    // Deep navy, a touch brighter at the top left.
                    WidgetBackdrop()
                }
        }
        .configurationDisplayName("TVs & Cameras")
        .description("What the TVs are playing, with the doorbell and driveway beside them.")
        .supportedFamilies([.systemMedium])
        .contentMarginsDisabled()
        // Reloaded by the Mac Studio's push a moment after each alert from a camera it shows.
        .pushHandler(CameraWidgetsPushHandler.self)
    }
}

struct TVsCamerasView: View {
    let s: PhoneWidgetShare.Snapshot?
    let cameras: [PhoneWidgetShare.CameraLine]
    let date: Date

    /// The three TVs in the order Blake chose, then any others to fill three rows.
    private var tvs: [PhoneWidgetShare.TVLine] {
        let all = s?.tvs ?? []
        let stale = s?.tvsStale(at: date) ?? false
        func key(_ n: String) -> String { n.lowercased().replacingOccurrences(of: "’", with: "'") }
        var out: [PhoneWidgetShare.TVLine] = []
        for name in ["master bedroom", "living room", "kyler's room"] {
            if let t = all.first(where: { key($0.name) == name }) { out.append(t) }
        }
        for t in all where out.count < 3 && !out.contains(where: { $0.id == t.id }) { out.append(t) }
        return stale ? out.map { var t = $0; t.title = nil; t.isPlaying = false; t.progress = nil; t.left = nil; return t } : out
    }

    /// The doorbell, then the driveway (by name), else the first two cameras (the same choice decides which alerts
    /// reload this widget).
    private var cams: [PhoneWidgetShare.CameraLine] { PhoneWidgetShare.shownCameras(cameras) }

    var body: some View {
        HStack(spacing: 9) {
            VStack(spacing: 4) {
                if tvs.isEmpty {
                    Text(PhoneWidgetShare.emptyText).font(.caption).foregroundStyle(WidgetPalette.sky)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ForEach(tvs) { tv in
                        Link(destination: URL(string: "woodruff://remote?tv=\(tv.id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")")!) {
                            row(tv)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            VStack(spacing: 6) {
                ForEach(0..<2, id: \.self) { i in
                    if i < cams.count {
                        let c = cams[i]
                        Link(destination: URL(string: "woodruff://camera?id=\(c.id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")")!) {
                            camera(c)
                        }
                    } else {
                        RoundedRectangle(cornerRadius: 11, style: .continuous).fill(WidgetPalette.cyan.opacity(0.1))
                            .overlay(Text("Camera").font(.caption2).foregroundStyle(WidgetPalette.sky.opacity(0.6)))
                    }
                }
            }
            // Wider than it was (118): the gap beside the TV rows had room for it.
            .frame(width: 140)
            .frame(maxHeight: .infinity)
        }
        .padding(11)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: A TV

    private func row(_ tv: PhoneWidgetShare.TVLine) -> some View {
        HStack(spacing: 8) {
            artwork(tv)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(tv.name).font(.system(size: 10, weight: .bold)).foregroundStyle(WidgetPalette.ice).lineLimit(1)
                    Spacer(minLength: 2)
                    if tv.title != nil, let left = tv.left {
                        Text(left).font(.system(size: 10, weight: .medium)).monospacedDigit().foregroundStyle(WidgetPalette.sky)
                    }
                }
                Text(tv.title ?? (tv.online ? "On" : "Off"))
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(WidgetPalette.frost)
                    .lineLimit(1)
                if tv.title != nil, let p = tv.progress {
                    GeometryReader { g in
                        Capsule().fill(WidgetPalette.cyan.opacity(0.25))
                            .overlay(alignment: .leading) { Capsule().fill(WidgetPalette.cyan).frame(width: g.size.width * p) }
                    }
                    .frame(height: 3)
                    .padding(.top, 3)
                }
            }
        }
        .padding(.vertical, 4).padding(.leading, 4).padding(.trailing, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    @ViewBuilder private func artwork(_ tv: PhoneWidgetShare.TVLine) -> some View {
        if tv.title != nil, let image = WidgetImage.load(tv.art, pixels: 120) {
            Image(uiImage: image).resizable().scaledToFill()
                .frame(width: 34, height: 34).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(WidgetPalette.cyan.opacity(0.14))
                .frame(width: 34, height: 34)
                .overlay(Image(systemName: "tv").font(.system(size: 14, weight: .semibold)).foregroundStyle(WidgetPalette.cyan))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(WidgetPalette.cyan.opacity(0.45), lineWidth: 0.75))
        }
    }

    // MARK: A camera

    private func camera(_ c: PhoneWidgetShare.CameraLine) -> some View {
        let fresh = c.eventAt.map { date.timeIntervalSince($0) < 600 } ?? false
        // The picture fills its box and is cut to it: a filling image alone sizes itself to the picture, which made the
        // whole widget larger than its space (everything looked zoomed in and the bottom was cut off).
        return WidgetPalette.cyan.opacity(0.1)
            .overlay {
                if let image = WidgetImage.load(c.file, pixels: 480) {
                    Image(uiImage: image).resizable().scaledToFill()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        .overlay(LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .center, endPoint: .bottom))
        .overlay(alignment: .bottom) {
            HStack(spacing: 4) {
                Text(c.doorbell ? "Doorbell" : shortName(c.name)).lineLimit(1)
                Spacer(minLength: 2)
                // Always on one line ("10:25 PM" was breaking onto a second): the name gives way instead.
                if let at = c.at {
                    Text(at, style: .time).foregroundStyle(.white.opacity(0.78))
                        .lineLimit(1).fixedSize().layoutPriority(1)
                }
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.6), radius: 2)
            .padding(.horizontal, 6).padding(.bottom, 5)
        }
        .overlay(alignment: .topLeading) {
            if fresh, let e = c.event {
                Text(e).font(.system(size: 9.5, weight: .bold)).foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.red.opacity(0.92), in: Capsule())
                    .padding(6)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    /// "Front Driveway camera" → "Front Driveway".
    private func shortName(_ n: String) -> String {
        n.replacingOccurrences(of: " camera", with: "", options: .caseInsensitive)
    }
}


// MARK: - The doorbell on the Lock Screen

/// The doorbell's latest picture with what happened and when, on the Lock Screen. Opens it live.
struct DoorbellLockWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: PhoneWidgetShare.doorbellKind, provider: ShareProvider()) { entry in
            DoorbellLockView(camera: Self.doorbell(PhoneWidgetShare.loadCameras()), date: entry.date)
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("Doorbell")
        .description("The doorbell's latest picture and alert.")
        .supportedFamilies([.accessoryRectangular])
        .pushHandler(CameraWidgetsPushHandler.self)
    }

    static func doorbell(_ cameras: [PhoneWidgetShare.CameraLine]) -> PhoneWidgetShare.CameraLine? {
        PhoneWidgetShare.doorbell(cameras)
    }
}

struct DoorbellLockView: View {
    let camera: PhoneWidgetShare.CameraLine?
    let date: Date

    var body: some View {
        if let c = camera {
            let fresh = c.eventAt.map { date.timeIntervalSince($0) < 3600 } ?? false
            HStack(spacing: 8) {
                Group {
                    if let image = WidgetImage.load(c.file, pixels: 200) {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        Image(systemName: "video.doorbell.fill").font(.title2)
                    }
                }
                .frame(width: 62, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Doorbell").font(.headline).widgetAccentable().lineLimit(1)
                    Text(fresh ? (c.event ?? "Seen") : "Latest picture").font(.caption).lineLimit(1)
                    if let at = c.eventAt ?? c.at { Text(at, style: .time).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer(minLength: 0)
            }
            .widgetURL(URL(string: "woodruff://camera?id=\(c.id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")"))
        } else {
            Text("Open Woodruff to see the doorbell.").font(.caption)
        }
    }
}


// MARK: - The doorbell ringing (Live Activity)

struct DoorbellLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DoorbellAttributes.self) { context in
            DoorbellRingView(attributes: context.attributes, at: context.state.at, thumb: context.state.thumb)
                .background(WidgetBackdrop())   // the app icon's colours
                .activityBackgroundTint(WidgetPalette.navyBottom)
                .activitySystemActionForegroundColor(.white)
                .widgetURL(Self.link(context.attributes))
        } dynamicIsland: { context in
            let a = context.attributes
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    DoorbellPicture(camera: a.camera, thumb: context.state.thumb, rang: context.state.at).frame(width: 64, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Someone\u{2019}s at the door").font(.headline).lineLimit(1)
                        Text(context.state.at, style: .time).font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Link(destination: Self.link(a)) {
                        Text("Open").font(.subheadline.weight(.semibold)).padding(.horizontal, 10).padding(.vertical, 6)
                            .background(.white.opacity(0.18), in: Capsule())
                    }
                }
            } compactLeading: {
                Image(systemName: "video.doorbell.fill").foregroundStyle(.orange)
            } compactTrailing: {
                Text(context.state.at, style: .time).font(.caption.weight(.semibold)).frame(maxWidth: 60)
            } minimal: {
                Image(systemName: "video.doorbell.fill").foregroundStyle(.orange)
            }
            .widgetURL(Self.link(a))
            .keylineTint(.orange)
        }
    }

    static func link(_ a: DoorbellAttributes) -> URL {
        URL(string: "woodruff://camera?id=\(a.camera.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")")!
    }
}

/// The ring's picture: the doorbell's still kept since it rang (the alert's own picture, once its extension has it),
/// else the small picture the Mac sent with the ring, else the doorbell's latest still, or its symbol.
struct DoorbellPicture: View {
    let camera: String
    /// The Mac's small picture of the ring (base64), and when it rang.
    var thumb: String? = nil
    var rang: Date? = nil
    var body: some View {
        let line = PhoneWidgetShare.loadCameras().first { $0.id == camera }
        // Kept as it rang or since (a few seconds' leeway: the Mac's clock and this iPhone's can differ a little).
        let ofRing = rang.flatMap { r in line?.at.map { $0 >= r.addingTimeInterval(-5) } } ?? false
        let kept = ofRing ? WidgetImage.load(line?.file, pixels: 360) : nil
        if let image = kept ?? WidgetImage.decode(thumb, pixels: 360) ?? WidgetImage.load(line?.file, pixels: 360) {
            Image(uiImage: image).resizable().scaledToFill()
        } else {
            Color.white.opacity(0.08).overlay(Image(systemName: "video.doorbell.fill").font(.title2).foregroundStyle(.white.opacity(0.6)))
        }
    }
}

struct DoorbellRingView: View {
    let attributes: DoorbellAttributes
    let at: Date
    var thumb: String? = nil
    var body: some View {
        HStack(spacing: 12) {
            DoorbellPicture(camera: attributes.camera, thumb: thumb, rang: at)
                .frame(width: 112, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text("Someone\u{2019}s at the door").font(.headline).foregroundStyle(.white).lineLimit(1)
                Text(attributes.name).font(.subheadline).foregroundStyle(WidgetPalette.ice).lineLimit(1)
                Text(at, style: .time).font(.caption).foregroundStyle(WidgetPalette.ice.opacity(0.8))
            }
            Spacer(minLength: 0)
            Text("Open").font(.subheadline.weight(.semibold)).foregroundStyle(WidgetPalette.frost)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(WidgetPalette.cyan.opacity(0.25), in: Capsule())
                .overlay(Capsule().strokeBorder(WidgetPalette.cyan, lineWidth: 1))
        }
        .padding(14)
    }
}


/// A picture in the app group, decoded no larger than [pixels] across: widgets and Live Activities have little memory,
/// and decoding a picture at full size only to draw it small uses it up.
enum WidgetImage {
    static func load(_ name: String?, pixels: Int) -> UIImage? {
        guard let name, let url = PhoneWidgetShare.artURL(name),
              let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return image(src, pixels: pixels)
    }

    /// A picture carried as base64 (the Mac's small picture of a ring, JPEG or HEIC).
    static func decode(_ base64: String?, pixels: Int) -> UIImage? {
        guard let base64, let data = Data(base64Encoded: base64),
              let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return image(src, pixels: pixels)
    }

    private static func image(_ src: CGImageSource, pixels: Int) -> UIImage? {
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceShouldCacheImmediately: true,
                                     kCGImageSourceThumbnailMaxPixelSize: pixels]
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}

/// The widgets' colours, taken from the app icon: its steel-blue to deep-navy background with a soft cyan glow,
/// its glowing cyan for outlines and accents, its ice blue for labels and its white for what matters most.
enum WidgetPalette {
    static let navyTop = Color(red: 0.220, green: 0.325, blue: 0.443)      // steel
    static let navyMid = Color(red: 0.114, green: 0.200, blue: 0.314)
    static let navyBottom = Color(red: 0.031, green: 0.067, blue: 0.122)   // deep navy
    static let cyan = Color(red: 0.227, green: 0.678, blue: 0.875)         // the icon's glow
    /// Labels.
    static let sky = Color(red: 0.659, green: 0.831, blue: 0.961)          // ice
    static let ice = sky
    /// What's on, the main words.
    static let frost = Color(red: 0.976, green: 0.992, blue: 0.992)        // white core
}

/// Behind every widget: the icon's fade from steel blue to deep navy, with its cyan glow in the middle.
struct WidgetBackdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [WidgetPalette.navyTop, WidgetPalette.navyMid, WidgetPalette.navyBottom], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [WidgetPalette.cyan.opacity(0.16), .clear], center: .center, startRadius: 0, endRadius: 220)
        }
    }
}
