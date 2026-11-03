import SwiftUI
import PhotosUI
import ImageIO
import UniformTypeIdentifiers
import WoodruffKit

/// Family Memories: the TV's photos and videos, newest first; add from Photos, view full screen, show on the TV.
struct MemoriesView: View {
    @Environment(Fleet.self) private var fleet
    @State private var memories: Memories?
    @State private var picks: [PhotosPickerItem] = []
    @State private var uploading: (done: Int, of: Int)?
    @State private var viewing: MemoryItem?
    @State private var importing = false
    @State private var error: String?

    #if os(iOS)
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)
    #else
    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 2)]
    #endif
    private var client: TVClient? { fleet.hubClient() }
    @Namespace private var zoom
    @AppStorage("memories.columns") private var columnCount = 3
    @State private var topItem: String?
    @State private var showMonth = false
    @State private var hideMonth: Task<Void, Never>?

    /// The month of the photos at the top of the screen ("July 2025").
    private var monthLabel: String? {
        guard let items = memories?.items, !items.isEmpty else { return nil }
        let item = items.first { $0.path == topItem } ?? items.first
        return item?.takenDate?.formatted(.dateTime.month(.wide).year())
    }
    @State private var pinchBase: Int?

    /// Photos grouped by the month they were taken, newest first.
    private func months(_ items: [MemoryItem]) -> [(String, [MemoryItem])] {
        var order: [String] = []
        var groups: [String: [MemoryItem]] = [:]
        for i in items {
            let key = i.takenDate.map { $0.formatted(.dateTime.month(.wide).year()) } ?? "Undated"
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(i)
        }
        return order.map { ($0, groups[$0]!) }
    }

    private var gridColumns: [GridItem] {
        #if os(iOS)
        Array(repeating: GridItem(.flexible(), spacing: 2), count: max(2, min(6, columnCount)))
        #else
        columns
        #endif
    }

    var body: some View {
        ScrollView {
            if let m = memories {
                if let u = uploading {
                    ProgressView("Adding \(u.done + 1) of \(u.of)…", value: Double(u.done), total: Double(u.of))
                        .padding(.horizontal, 20).padding(.bottom, 10)
                }
                // Like Photos: one continuous grid; the month floats in a glass capsule while scrolling.
                LazyVGrid(columns: gridColumns, spacing: 2) {
                    ForEach(m.items) { item in
                        Button { viewing = item } label: { tile(item).zoomSource(item.path, zoom) }
                            .buttonStyle(.plain)
                            .contextMenu { itemMenu(item) }
                    }
                }
                .scrollTargetLayout()
                #if os(iOS)
                // Pinch to see more or fewer photos across, like Photos.
                .simultaneousGesture(MagnifyGesture()
                    .onChanged { v in
                        let base = pinchBase ?? columnCount
                        pinchBase = base
                        let next = max(2, min(6, Int((Double(base) / v.magnification).rounded())))
                        if next != columnCount { withAnimation(.snappy) { columnCount = next } }
                    }
                    .onEnded { _ in pinchBase = nil })
                #endif
                if m.items.isEmpty {
                    EmptyState(symbol: "photo.on.rectangle", title: "No Memories Yet", message: "Add photos and videos from this device. Every TV’s slideshow can show them.")
                        .padding(.top, 60)
                } else {
                    let photos = m.items.filter { !$0.video }.count, videos = m.items.count - photos
                    Text("\(photos) Photos, \(videos) Videos")
                        .font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                        .padding(.vertical, 18)
                }
            } else if let error {
                EmptyState(symbol: "wifi.exclamationmark", title: "Can't Load Memories", message: error)
            } else {
                LazyVGrid(columns: gridColumns, spacing: 2) {
                    ForEach(0..<18, id: \.self) { _ in Placeholder(corner: 0).aspectRatio(1, contentMode: .fit) }
                }
                .shimmer()
            }
        }
        .scrollPosition(id: $topItem, anchor: .top)
        .onScrollPhaseChange { _, phase in
            // Shows while scrolling, fades a moment after it stops (as Photos does).
            if phase.isScrolling {
                hideMonth?.cancel()
                withAnimation(.smooth(duration: 0.25)) { showMonth = true }
            } else {
                hideMonth?.cancel()
                hideMonth = Task {
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    guard !Task.isCancelled else { return }
                    withAnimation(.smooth(duration: 0.4)) { showMonth = false }
                }
            }
        }
        .overlay(alignment: .top) {
            if showMonth, let monthLabel {
                Text(monthLabel)
                    .font(.subheadline.weight(.semibold))
                    .contentTransition(.numericText())
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .glass(Capsule(), interactive: false)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .animation(.snappy, value: monthLabel)
                    .allowsHitTesting(false)
            }
        }
        .screenTitle("Family Memories")
        #if os(macOS)
        .dropDestination(for: URL.self) { urls, _ in Task { await addFiles(urls) }; return true }
        #endif
        .refreshable { await load() }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    Task {
                        do { try await client?.slideshow(folder: memories?.folder, start: true); fleet.say("Slideshow", "Family Memories is playing on \(client?.hub.name ?? "the TV").") }
                        catch { fleet.show(error) }
                    }
                } label: { Image(systemName: "play.rectangle.on.rectangle") }
                .disabled(memories?.items.contains { !$0.video } != true)
                PhotosPicker(selection: $picks, matching: .any(of: [.images, .videos])) { Image(systemName: "plus") }
                    .disabled(uploading != nil)
                #if os(macOS)
                Button { importing = true } label: { Image(systemName: "folder.badge.plus") }
                #endif
            }
        }
        .onChange(of: picks) { _, new in if !new.isEmpty { Task { await add(new) } } }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.image, .movie], allowsMultipleSelection: true) { r in
            if case .success(let urls) = r { Task { await addFiles(urls) } }
        }
        .task { await load() }
        #if os(iOS)
        .fullScreenCover(item: $viewing) { item in
            MemoryViewer(items: memories?.items ?? [], start: item, onChange: { memories = $0 }).zoomDestination(item.path, zoom)
        }
        #else
        .sheet(item: $viewing) { item in MemoryViewer(items: memories?.items ?? [], start: item, onChange: { memories = $0 }).frame(minWidth: 800, minHeight: 600) }
        #endif
    }

    private func tile(_ item: MemoryItem) -> some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay { TVImage(url: client?.thumbURL(item)) }
            .clipped()
            .overlay(alignment: .bottomTrailing) {
                if item.video { Image(systemName: "video.fill").font(.caption).foregroundStyle(.white).shadow(radius: 2).padding(5) }
            }
    }

    @ViewBuilder private func itemMenu(_ item: MemoryItem) -> some View {
        Button { act { try await client?.showMemory(item) } } label: { Label(item.video ? "Play on TV" : "Show on TV", systemImage: "tv") }
        if !item.video {
            Button { act { try await client?.background(item.path); fleet.say("Background set", "It's the TV's background now.") } } label: { Label("Set as TV Background", systemImage: "photo.on.rectangle") }
        }
        Button(role: .destructive) { act { memories = try await client?.deleteMemory(item) } } label: { Label("Delete", systemImage: "trash") }
    }

    private func act(_ op: @escaping () async throws -> Void) { Task { do { try await op() } catch { fleet.show(error) } } }

    private func load() async {
        guard let c = client else { return }
        do {
            memories = try await c.memories(); error = nil
            if UserDefaults.standard.string(forKey: "route") == "photo", viewing == nil { viewing = memories?.items.first }
        } catch { self.error = error.localizedDescription }
    }

    // MARK: Adding

    private var fit: CGSize {
        let f = memories?.fit ?? [1920, 1080]
        return CGSize(width: f.first ?? 1920, height: f.count > 1 ? f[1] : 1080)
    }

    private func add(_ items: [PhotosPickerItem]) async {
        picks = []
        guard let c = client else { return }
        uploading = (0, items.count)
        var sent = 0.0
        for (i, item) in items.enumerated() {
            uploading = (i, items.count)
            do {
                let prepared: PreparedMemory
                if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }), let movie = try await item.loadTransferable(type: MovieFile.self) {
                    prepared = PreparedMemory(file: movie.url, name: movie.url.lastPathComponent, taken: nil)
                } else if let data = try await item.loadTransferable(type: Data.self) {
                    prepared = try MemoryPrep.photo(data, name: "IMG_\(Int(Date().timeIntervalSince1970))_\(i).jpg", fit: fit)
                } else { continue }
                let size = Double((try? prepared.file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                if let free = memories?.free, size > free - sent {
                    throw TVError.badAnswer("Not enough room on \(c.hub.name): \(formatBytes(free - sent)) free.")
                }
                _ = try await c.addMemory(file: prepared.file, name: prepared.name, taken: prepared.taken)
                sent += size
                try? FileManager.default.removeItem(at: prepared.file)
            } catch { fleet.show(error); break }
        }
        uploading = nil
        await load()
    }

    private func addFiles(_ urls: [URL]) async {
        guard let c = client else { return }
        uploading = (0, urls.count)
        for (i, url) in urls.enumerated() {
            uploading = (i, urls.count)
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                let isVideo = (UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie)) ?? false
                let p = isVideo ? PreparedMemory(file: url, name: url.lastPathComponent, taken: nil)
                                : try MemoryPrep.photo(try Data(contentsOf: url), name: url.lastPathComponent, fit: fit)
                _ = try await c.addMemory(file: p.file, name: p.name, taken: p.taken)
            } catch { fleet.show(error); break }
        }
        uploading = nil
        await load()
    }
}

struct PreparedMemory {
    var file: URL
    var name: String
    var taken: Date?
}

/// Shrinks a photo to the size the TV shows it at (JPEG, quality 0.9) and reads when it was taken, as the phone page does.
enum MemoryPrep {
    static func photo(_ data: Data, name: String, fit: CGSize) throws -> PreparedMemory {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { throw TVError.badAnswer("That photo couldn't be read.") }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
        let w = props[kCGImagePropertyPixelWidth] as? CGFloat ?? 0, h = props[kCGImagePropertyPixelHeight] as? CGFloat ?? 0
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        // Width and height as shown (EXIF orientations 5–8 turn the picture a quarter).
        let (dw, dh) = orientation >= 5 ? (h, w) : (w, h)
        let box = dh > dw ? CGSize(width: fit.height, height: fit.width) : fit
        let scale = min(1, box.width / max(1, dw), box.height / max(1, dh))
        let target = max(1, Int(max(dw, dh) * scale))
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: target]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { throw TVError.badAnswer("That photo couldn't be read.") }
        let stem = (name as NSString).deletingPathExtension
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("\(stem).jpg")
        try? FileManager.default.removeItem(at: out)
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { throw TVError.badAnswer("Couldn't prepare the photo") }
        CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw TVError.badAnswer("Couldn't prepare the photo") }
        return PreparedMemory(file: out, name: "\(stem).jpg", taken: takenDate(props))
    }

    /// EXIF DateTimeOriginal (else TIFF DateTime), read as local time.
    static func takenDate(_ props: [CFString: Any]) -> Date? {
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        guard let s = (exif?[kCGImagePropertyExifDateTimeOriginal] as? String) ?? (tiff?[kCGImagePropertyTIFFDateTime] as? String) else { return nil }
        let f = DateFormatter()
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        f.timeZone = .current
        return f.date(from: s)
    }
}

/// A video from the Photos library, copied to a temporary file.
struct MovieFile: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { m in SentTransferredFile(m.url) } importing: { received in
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent(received.file.lastPathComponent)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: received.file, to: dest)
            return MovieFile(url: dest)
        }
    }
}

/// Full-screen viewer: swipe through, zoom, show on the TV (following as you swipe), share, delete.
struct MemoryViewer: View {
    @Environment(Fleet.self) private var fleet
    @Environment(\.dismiss) private var dismiss
    var items: [MemoryItem]
    @State var start: MemoryItem
    var onChange: (Memories) -> Void
    @State private var current: String = ""
    @State private var follow = false
    @State private var shareURL: URL?
    @State private var chrome = true

    private var client: TVClient? { fleet.hubClient() }
    private var item: MemoryItem? { items.first { $0.path == current } }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            TabView(selection: $current) {
                ForEach(items) { m in
                    ZoomableImage(url: client?.photoURL(m)).tag(m.path)
                        .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { chrome.toggle() } }
                }
            }
            #if os(iOS)
            .tabViewStyle(.page(indexDisplayMode: .never))
            #endif
            .ignoresSafeArea()
            if chrome { controls.transition(.opacity) }
        }
        .environment(\.colorScheme, .dark)
        .onAppear { current = start.path }
        .task(id: "\(current)-\(follow)") {
            guard follow, let it = item else { return }
            try? await Task.sleep(nanoseconds: 160_000_000)
            guard !Task.isCancelled else { return }
            do { try await client?.showMemory(it) } catch { fleet.show(error); follow = false }
        }
        #if os(iOS)
        .sheet(item: Binding(get: { shareURL.map { ShareItem(url: $0) } }, set: { shareURL = $0?.url })) { ShareSheet(items: [$0.url]) }
        #endif
    }

    private var controls: some View {
        VStack {
            HStack {
                GlassCircle(symbol: "xmark") { dismiss() }
                Spacer()
                if let d = item?.takenDate {
                    VStack(spacing: 0) {
                        Text(d.formatted(.dateTime.month(.wide).day().year())).font(.subheadline.weight(.semibold))
                        Text(d.formatted(date: .omitted, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 6)
                    .glass(Capsule(), interactive: false)
                }
                Spacer()
                Menu {
                    if item?.video == false {
                        Button { act { try await client?.background(item!.path); fleet.say("Background Set", "It’s the TV’s background now.") } } label: { Label("Set as TV Background", systemImage: "photo.on.rectangle") }
                    }
                    Button { act { try await client?.slideshow(folder: nil, start: true) } } label: { Label("Slideshow on TV", systemImage: "play.rectangle") }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 17, weight: .semibold)).frame(width: 44, height: 44).glass(Circle())
                }
                .menuStyle(.button).buttonStyle(.plain)
            }
            Spacer()
            HStack {
                GlassCircle(symbol: "square.and.arrow.up") { share() }
                Spacer()
                Button { withAnimation(.snappy) { follow.toggle() } } label: {
                    Label(follow ? "Showing on TV" : "Show on TV", systemImage: follow ? "tv.fill" : "tv")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 18).frame(height: 44)
                        .foregroundStyle(follow ? .white : Color.accentColor)
                        .contentShape(Capsule())
                        .glass(Capsule(), tint: follow ? Color.accentColor : nil)
                }
                .buttonStyle(PressScale(scale: 0.96))
                Spacer()
                GlassCircle(symbol: "trash") {
                    guard let it = item else { return }
                    act { if let m = try await client?.deleteMemory(it) { onChange(m); dismiss() } }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .glassGroup()
    }

    private func act(_ op: @escaping () async throws -> Void) { Task { do { try await op() } catch { fleet.show(error) } } }

    private func share() {
        guard let it = item, let c = client else { return }
        Task {
            do {
                let (tmp, _) = try await URLSession.woodruff.download(from: it.video ? c.downloadURL(it.path) : c.photoURL(it))
                let name = it.video ? it.name : (it.name as NSString).deletingPathExtension + ".jpg"
                let dest = FileManager.default.temporaryDirectory.appendingPathComponent(name)
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: tmp, to: dest)
                #if os(macOS)
                NSWorkspace.shared.activateFileViewerSelecting([dest])
                #else
                shareURL = dest
                #endif
            } catch { fleet.show(error) }
        }
    }
}

/// Pinch and double-tap zoom on a photo.
struct ZoomableImage: View {
    var url: URL?
    @State private var scale: CGFloat = 1
    @State private var last: CGFloat = 1
    var body: some View {
        TVImage(url: url, contentMode: .fit)
            .scaleEffect(scale)
            .gesture(MagnifyGesture()
                .onChanged { v in scale = max(1, min(5, last * v.magnification)) }
                .onEnded { _ in last = scale })
            .onTapGesture(count: 2) { withAnimation(.spring) { scale = scale > 1 ? 1 : 2.5; last = scale } }
    }
}
