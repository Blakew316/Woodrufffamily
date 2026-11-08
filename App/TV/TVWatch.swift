import SwiftUI
import AVKit
import WoodruffKit

/// Watch on Apple TV, as on the iPhone: the billboard of featured titles at the top (its picture across the screen,
/// the name, what it is and Play), then Continue Watching, Recently Added, Movies and TV Shows as rows of posters.
/// Everything plays right here in Apple's player, streamed from the TV that has it.
struct WatchTab: View {
    @Environment(Fleet.self) private var fleet
    @State private var home: WatchHome?
    @State private var problem: String?
    @State private var playing: PlayItem?
    @State private var page = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 40) {
                    if let home, let c = fleet.hubClient() {
                        let featured = (home.featured ?? []).filter { $0.play != nil }
                        if !featured.isEmpty { billboard(featured, c) }
                        let watching = home.continue ?? []
                        if !watching.isEmpty {
                            Row(name: "Continue Watching") {
                                ForEach(watching, id: \.key) { item in
                                    Button { play(item.play.key, from: item.position) } label: {
                                        PosterCard(title: item.name, subtitle: item.code ?? left(item), url: c.art(item.poster), progress: item.progress)
                                    }
                                    .buttonStyle(TVTileStyle(corner: 18, ring: false, lift: 1.1))
                                }
                            }
                        }
                        shelf("Recently Added", home.recent ?? [], c)
                        shelf("Movies", home.movies?.items ?? [], c)
                        shelf("TV Shows", home.shows?.items ?? [], c)
                    } else {
                        VStack(alignment: .leading, spacing: 20) {
                            Text("Watch").font(.system(size: 58, weight: .bold)).foregroundStyle(.white)
                            if let problem {
                                Text(problem).font(.title3).foregroundStyle(.white.opacity(0.7))
                            } else if fleet.hubClient() == nil {
                                Text("Movies and TV Shows come from the family’s TVs. Connect this Apple TV to the family in Settings.")
                                    .font(.title3).foregroundStyle(.white.opacity(0.7))
                            } else {
                                ProgressView()
                            }
                        }
                        .padding(80)
                    }
                }
                .padding(.bottom, 80)
            }
            .background { TVBackdrop() }
            .task(id: fleet.hubs.count) { await load() }
            .fullScreenCover(item: $playing) { item in
                TVPlayer(url: item.url, start: item.start)
            }
        }
    }

    /// The featured title across the screen; it moves on to the next every 12 seconds while the remote isn't on it.
    private func billboard(_ titles: [Title], _ c: TVClient) -> some View {
        let t = titles[min(page, titles.count - 1)]
        return ZStack(alignment: .bottomLeading) {
            TVArt(url: c.art(t.backdrop ?? t.poster))
                .id(t.id)
                .transition(.opacity)
            LinearGradient(stops: [.init(color: .clear, location: 0.3), .init(color: .black.opacity(0.85), location: 1)],
                           startPoint: .top, endPoint: .bottom)
            LinearGradient(stops: [.init(color: .black.opacity(0.55), location: 0), .init(color: .clear, location: 0.6)],
                           startPoint: .leading, endPoint: .trailing)
            VStack(alignment: .leading, spacing: 14) {
                Text(t.title).font(.system(size: 64, weight: .bold)).foregroundStyle(.white).lineLimit(2)
                    .shadow(color: .black.opacity(0.4), radius: 10)
                Text(meta(t)).font(.title3.weight(.medium)).foregroundStyle(.white.opacity(0.8))
                HStack(spacing: 30) {
                    if let p = t.play {
                        Button { play(p.key, from: p.resume == true ? p.position : nil) } label: {
                            Text(p.label ?? "Play").font(.headline.bold()).padding(.horizontal, 30)
                        }
                    }
                    if titles.count > 1 {
                        Button { withAnimation(.easeInOut(duration: 0.6)) { page = (page + 1) % titles.count } } label: {
                            Text("Next").font(.headline).padding(.horizontal, 20)
                        }
                    }
                }
                .padding(.top, 10)
                HStack(spacing: 10) {
                    ForEach(titles.indices, id: \.self) { i in
                        Circle().fill(.white.opacity(i == page ? 0.95 : 0.35)).frame(width: 12, height: 12)
                    }
                }
                .padding(.top, 8)
            }
            .padding(.horizontal, 80).padding(.bottom, 50)
        }
        .frame(height: 720)
        .frame(maxWidth: .infinity)
        .clipped()
        .task(id: page) {
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            guard !Task.isCancelled, titles.count > 1 else { return }
            withAnimation(.easeInOut(duration: 0.8)) { page = (page + 1) % titles.count }
        }
    }

    @ViewBuilder private func shelf(_ name: String, _ titles: [Title], _ c: TVClient) -> some View {
        let playable = titles.filter { $0.play != nil }
        if !playable.isEmpty {
            Row(name: name) {
                ForEach(playable) { t in
                    Button {
                        if let p = t.play { play(p.key, from: p.resume == true ? p.position : nil) }
                    } label: {
                        PosterCard(title: t.title, subtitle: t.caption ?? t.year.map(String.init), url: c.art(t.poster), progress: nil)
                    }
                    .buttonStyle(TVTileStyle(corner: 18, ring: false, lift: 1.1))
                }
            }
        }
    }

    private func meta(_ t: Title) -> String {
        var m: [String] = []
        if let y = t.year { m.append(String(y)) }
        if let g = t.genres, !g.isEmpty { m.append(g.prefix(2).joined(separator: ", ")) }
        if let r = t.rating { m.append(String(format: "★ %.1f", r)) }
        return m.joined(separator: " · ")
    }

    private func left(_ item: ContinueItem) -> String? {
        guard let d = item.duration, d > 0 else { return nil }
        let mins = Int(max(0, d - (item.position ?? 0)) / 60000)
        return mins >= 60 ? String(format: "%dh %02dm left", mins / 60, mins % 60) : "\(mins)m left"
    }

    /// [position] in milliseconds, as the TVs keep it.
    private func play(_ key: String, from position: Double?) {
        guard let c = fleet.hubClient() else { return }
        playing = PlayItem(url: c.streamURL(key), start: (position ?? 0) / 1000)
    }

    private func load() async {
        guard let c = fleet.hubClient() else { return }
        do { home = try await c.watchHome(); problem = nil } catch { problem = error.localizedDescription }
    }
}

struct PlayItem: Identifiable {
    let id = UUID()
    let url: URL
    /// Seconds.
    let start: Double
}

private struct Row<Content: View>: View {
    let name: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TVSectionTitle(text: name)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 44) { content }
                    .padding(.horizontal, 80)
                    .padding(.vertical, 36)
            }
            .scrollClipDisabled()
        }
    }
}

/// A poster with its name under it (and how far in, for Continue Watching), as on the iPhone.
private struct PosterCard: View {
    let title: String
    let subtitle: String?
    let url: URL?
    let progress: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TVArt(url: url)
                .frame(width: 250, height: 375)
                .overlay {
                    if url == nil {
                        Text(title).font(.headline).foregroundStyle(.white).multilineTextAlignment(.center).padding(16)
                    }
                }
                .overlay(alignment: .bottom) {
                    if let progress, progress > 0 {
                        Capsule().fill(.white.opacity(0.3)).frame(width: 214, height: 6)
                            .overlay(alignment: .leading) { Capsule().fill(.white).frame(width: 214 * progress, height: 6) }
                            .padding(.bottom, 16)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                Text(subtitle ?? " ").font(.caption).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
            }
            .frame(width: 250, alignment: .leading)
        }
    }
}

/// Apple's own player, full screen, from [start] seconds.
private struct TVPlayer: View {
    let url: URL
    let start: Double
    @State private var player: AVPlayer?

    var body: some View {
        VideoPlayer(player: player)
            .ignoresSafeArea()
            .onAppear {
                let p = AVPlayer(url: url)
                if start > 5 { p.seek(to: CMTime(seconds: start, preferredTimescale: 600)) }
                p.play()
                player = p
            }
            .onDisappear { player?.pause() }
    }
}
