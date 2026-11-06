import SwiftUI
import WidgetKit

// The TVs & Cameras widget (medium): Master Bedroom, Living Room and Kyler's Room down the left, with what each is
// playing and the remote's TV lit; the Doorbell and Front Driveway's latest pictures on the right. A TV opens the
// remote on it, a camera opens it live.

struct TVsCamerasWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: PhoneWidgetShare.tvsCamerasKind, provider: ShareProvider()) { entry in
            TVsCamerasView(s: entry.s, cameras: PhoneWidgetShare.loadCameras(), date: entry.date)
                .environment(\.colorScheme, .dark)
                .containerBackground(for: .widget) {
                    LinearGradient(colors: [Color(red: 0.13, green: 0.14, blue: 0.19), Color(red: 0.06, green: 0.06, blue: 0.09)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                }
        }
        .configurationDisplayName("TVs & Cameras")
        .description("What the TVs are playing, with the doorbell and driveway beside them.")
        .supportedFamilies([.systemMedium])
        .contentMarginsDisabled()
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

    /// The doorbell, then the driveway (by name), else the first two cameras.
    private var cams: [PhoneWidgetShare.CameraLine] {
        let door = cameras.first { $0.doorbell } ?? cameras.first { $0.name.localizedCaseInsensitiveContains("door") }
        let drive = cameras.first { $0.name.localizedCaseInsensitiveContains("drive") && $0.id != door?.id }
        var out = [door, drive].compactMap { $0 }
        for c in cameras where out.count < 2 && !out.contains(where: { $0.id == c.id }) { out.append(c) }
        return out
    }

    var body: some View {
        HStack(spacing: 9) {
            VStack(spacing: 4) {
                if tvs.isEmpty {
                    Text(PhoneWidgetShare.emptyText).font(.caption).foregroundStyle(.secondary)
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
                        RoundedRectangle(cornerRadius: 11, style: .continuous).fill(.white.opacity(0.06))
                            .overlay(Text("Camera").font(.caption2).foregroundStyle(.tertiary))
                    }
                }
            }
            .frame(width: 118)
        }
        .padding(11)
    }

    // MARK: A TV

    private func row(_ tv: PhoneWidgetShare.TVLine) -> some View {
        let selected = tv.id == s?.selectedTV
        return HStack(spacing: 8) {
            artwork(tv)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    dot(tv)
                    Text(tv.name).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 2)
                    if tv.title != nil, let left = tv.left {
                        Text(left).font(.system(size: 10, weight: .medium)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                Text(tv.title ?? (tv.online ? "On" : "Off"))
                    .font(.system(size: 13, weight: selected ? .bold : .semibold, design: .rounded))
                    .foregroundStyle(tv.title != nil ? Color.primary : tv.online ? Color.secondary : Color.secondary.opacity(0.6))
                    .lineLimit(1)
                if tv.title != nil, let p = tv.progress {
                    GeometryReader { g in
                        Capsule().fill(.white.opacity(0.18))
                            .overlay(alignment: .leading) { Capsule().fill(.white).frame(width: g.size.width * p) }
                    }
                    .frame(height: 3)
                    .padding(.top, 3)
                }
            }
        }
        .padding(.vertical, 4).padding(.leading, 4).padding(.trailing, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.1))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
            }
        }
    }

    @ViewBuilder private func artwork(_ tv: PhoneWidgetShare.TVLine) -> some View {
        if tv.title != nil, let a = tv.art, let url = PhoneWidgetShare.artURL(a), let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image).resizable().scaledToFill()
                .frame(width: 34, height: 34).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(0.07))
                .frame(width: 34, height: 34)
                .overlay(Image(systemName: "tv").font(.system(size: 14, weight: .medium)).foregroundStyle(.white.opacity(0.45)))
        }
    }

    @ViewBuilder private func dot(_ tv: PhoneWidgetShare.TVLine) -> some View {
        if !tv.online {
            Circle().strokeBorder(.white.opacity(0.4), lineWidth: 1.2).frame(width: 6, height: 6)
        } else {
            Circle().fill(tv.title == nil ? Color.white.opacity(0.5) : tv.isPlaying ? Color.green : Color.yellow).frame(width: 6, height: 6)
        }
    }

    // MARK: A camera

    private func camera(_ c: PhoneWidgetShare.CameraLine) -> some View {
        let fresh = c.eventAt.map { date.timeIntervalSince($0) < 600 } ?? false
        return ZStack {
            if let f = c.file, let url = PhoneWidgetShare.artURL(f), let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Color.white.opacity(0.06)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .overlay(LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .center, endPoint: .bottom))
        .overlay(alignment: .bottom) {
            HStack(spacing: 4) {
                Text(c.doorbell ? "Doorbell" : shortName(c.name)).lineLimit(1)
                Spacer(minLength: 2)
                if let at = c.at { Text(at, style: .time).foregroundStyle(.white.opacity(0.78)) }
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
