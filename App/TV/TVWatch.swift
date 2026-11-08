import SwiftUI
import AVKit
import WoodruffKit

/// Watch on Apple TV: the library from the family's TVs (Continue Watching, Recently Added, Movies, TV Shows),
/// played right here in Apple's player, streamed from the TV that has it.
struct WatchTab: View {
    @Environment(Fleet.self) private var fleet
    @State private var home: WatchHome?
    @State private var problem: String?
    @State private var playing: PlayItem?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 50) {
                    if let home, let c = fleet.hubClient() {
                        let watching = home.continue ?? []
                        if !watching.isEmpty {
                            Row(name: "Continue Watching") {
                                ForEach(watching, id: \.key) { item in
                                    Poster(title: item.name, url: c.art(item.poster)) { play(item.key, item.name, from: item.position) }
                                }
                            }
                        }
                        shelf("Recently Added", home.recent ?? [], c)
                        shelf("Movies", home.movies?.items ?? [], c)
                        shelf("TV Shows", home.shows?.items ?? [], c)
                    } else if let problem {
                        Text(problem).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                    } else if fleet.hubClient() == nil {
                        Text("Pair one of the family’s TVs in Settings to see Movies and TV Shows.")
                            .foregroundStyle(.secondary).frame(maxWidth: .infinity)
                    } else {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                }
                .padding(.vertical, 40)
            }
            .task(id: fleet.hubs.count) { await load() }
            .fullScreenCover(item: $playing) { item in
                TVPlayer(url: item.url, start: item.start)
            }
        }
    }

    @ViewBuilder private func shelf(_ name: String, _ titles: [Title], _ c: TVClient) -> some View {
        let playable = titles.filter { $0.play != nil }
        if !playable.isEmpty {
            Row(name: name) {
                ForEach(playable) { t in
                    Poster(title: t.title, url: c.art(t.poster)) {
                        if let p = t.play { play(p.key, t.title, from: p.resume == true ? p.position : nil) }
                    }
                }
            }
        }
    }

    private func play(_ key: String, _ title: String, from position: Double?) {
        guard let c = fleet.hubClient() else { return }
        playing = PlayItem(url: c.streamURL(key), start: position ?? 0)
    }

    private func load() async {
        guard let c = fleet.hubClient() else { return }
        do { home = try await c.watchHome(); problem = nil } catch { problem = error.localizedDescription }
    }
}

struct PlayItem: Identifiable {
    let id = UUID()
    let url: URL
    let start: Double
}

private struct Row<Content: View>: View {
    let name: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(name).font(.title3.bold()).padding(.horizontal, 60)
            ScrollView(.horizontal) {
                LazyHStack(spacing: 40) { content }
                    .padding(.horizontal, 60)
                    .padding(.vertical, 30)
            }
            .scrollClipDisabled()
        }
    }
}

private struct Poster: View {
    let title: String
    let url: URL?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            AsyncImage(url: url) { img in
                img.resizable().aspectRatio(2 / 3, contentMode: .fill)
            } placeholder: {
                ZStack {
                    Color.gray.opacity(0.25)
                    Text(title).font(.caption).multilineTextAlignment(.center).padding(10)
                }
            }
            .frame(width: 240, height: 360)
            .clipped()
        }
        .buttonStyle(.card)
        .accessibilityLabel(title)
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
