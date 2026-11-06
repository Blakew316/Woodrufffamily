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
    /// Waiting for "Delete" to be confirmed (a family photo is gone for good once it's deleted on the TV).
    @State private var deleting: MemoryItem?

    #if os(iOS)
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)
    #else
    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 2)]
    #endif
    private var client: TVClient? { fleet.hubClient() }
    @Namespace private var zoom
    @AppStorage("memories.columns") private var columnCount = 3
    /// Where the grid is scrolled to, read only by the month capsule: the grid isn't redrawn as it moves.
    @State private var spot = MemoriesSpot()
    /// What's worked out once per answer (the counts, each photo's month), not again at every redraw.
    @State private var index = MemoriesIndex()
    @State private var pinchBase: Int?

    private var gridColumns: [GridItem] {
        #if os(iOS)
        Array(repeating: GridItem(.flexible(), spacing: 2), count: max(2, min(6, columnCount)))
        #else
        columns
        #endif
    }

    /// The slideshow, add photos and (Mac) add from a folder.
    @ViewBuilder private var pageButtons: some View {
        Button {
            act { c in
                try await c.slideshow(folder: memories?.folder, start: true)
                fleet.say("Slideshow", "Family Memories is playing on \(c.hub.name).")
            }
        } label: { Image(systemName: "play.rectangle.on.rectangle") }
        .disabled(!index.hasPhotos)
        .accessibilityLabel("Slideshow on TV")
        PhotosPicker(selection: $picks, matching: .any(of: [.images, .videos])) { Image(systemName: "plus") }
            .disabled(uploading != nil)
            .accessibilityLabel("Add Photos")
        #if os(macOS)
        Button { importing = true } label: { Image(systemName: "folder.badge.plus") }
            .accessibilityLabel("Add from a Folder")
        #endif
    }

    var body: some View {
        // Worked out once for the page: the tiles are handed their pictures' addresses.
        let client = self.client
        ScrollView {
            if let m = memories {
                if let u = uploading {
                    ProgressView("Adding \(u.done + 1) of \(u.of)…", value: Double(u.done), total: Double(u.of))
                        .padding(.horizontal, 20).padding(.bottom, 10)
                }
                // Like Photos: one continuous grid; the month floats in a glass capsule while scrolling.
                LazyVGrid(columns: gridColumns, spacing: 2) {
                    ForEach(m.items) { item in
                        Button { viewing = item } label: { tile(item, client).zoomSource(item.path, zoom) }
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
                    Text("\(index.photos) Photos, \(index.videos) Videos")
                        .font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                        .padding(.vertical, 18)
                }
            } else if let error {
                VStack(spacing: 14) {
                    EmptyState(symbol: "wifi.exclamationmark", title: "Can’t Load Memories", message: error)
                    ActionButton(action: { await load() }) { Text("Try Again") }
                        .buttonStyle(.glass)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 60)
            } else {
                LazyVGrid(columns: gridColumns, spacing: 2) {
                    ForEach(0..<18, id: \.self) { _ in Placeholder(corner: 0).aspectRatio(1, contentMode: .fit) }
                }
                .shimmer()
            }
        }
        .scrollPosition(id: Binding(get: { spot.top }, set: { spot.top = $0 }), anchor: .top)
        .onScrollPhaseChange { _, phase in
            if spot.scrolling != phase.isScrolling { spot.scrolling = phase.isScrolling }
        }
        .overlay(alignment: .top) { MonthCapsule(spot: spot, index: index) }
        .screenTitle("Family Memories")
        #if os(macOS)
        .dropDestination(for: URL.self) { urls, _ in Task { await addFiles(urls) }; return true }
        #endif
        .refreshable { await load() }
        #if os(iOS)
        .toolbar { ToolbarItemGroup(placement: .primaryAction) { pageButtons } }
        #else
        // The window draws its own bar on the Mac: these sit at the top of the page.
        .macPageBar { pageButtons.buttonStyle(.glass) }
        #endif
        .onChange(of: picks) { _, new in if !new.isEmpty { Task { await add(new) } } }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.image, .movie], allowsMultipleSelection: true) { r in
            if case .success(let urls) = r { Task { await addFiles(urls) } }
        }
        .task { await load() }
        .confirmationDialog(deleting?.video == true ? "Delete This Video?" : "Delete This Photo?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { item in
            Button("Delete", role: .destructive) { act { c in take(try await c.deleteMemory(item)) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("It’s removed from Family Memories on the TVs. This can’t be undone.")
        }
        #if os(iOS)
        .fullScreenCover(item: $viewing) { item in
            MemoryViewer(items: memories?.items ?? [], start: item, folder: memories?.folder, onChange: { take($0) }).zoomDestination(item.path, zoom)
        }
        #else
        .sheet(item: $viewing) { item in MemoryViewer(items: memories?.items ?? [], start: item, folder: memories?.folder, onChange: { take($0) }).macResizable(width: 1000, height: 720, minWidth: 600, minHeight: 450) }
        #endif
    }

    private func tile(_ item: MemoryItem, _ client: TVClient?) -> some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay { TVImage(url: client?.thumbURL(item), maxPixel: 512) }
            .clipped()
            .overlay(alignment: .bottomTrailing) {
                if item.video { Image(systemName: "video.fill").font(.caption).foregroundStyle(.white).shadow(radius: 2).padding(5) }
            }
    }

    @ViewBuilder private func itemMenu(_ item: MemoryItem) -> some View {
        Button(item.video ? "Play on TV" : "Show on TV") { act { c in try await c.showMemory(item) } }
        if !item.video {
            Button("Set as TV Background") { act { c in try await c.background(item.path); fleet.say("Background Set", "It’s \(c.hub.name)’s background now.") } }
        }
        Button("Delete", role: .destructive) { deleting = item }
    }

    /// [op] on the TV that holds Family Memories; says so when there's none, or when the TV says no.
    private func act(_ op: @escaping (TVClient) async throws -> Void) {
        guard let c = client else { fleet.show(TVError.notPaired); return }
        Task { do { try await op(c) } catch { fleet.show(error) } }
    }

    private func load() async {
        guard let c = client else { error = TVError.notPaired.localizedDescription; return }
        do {
            take(try await c.memories())
            if error != nil { error = nil }
            if UserDefaults.standard.string(forKey: "route") == "photo", viewing == nil { viewing = memories?.items.first }
        } catch {
            if Task.isCancelled { return }
            self.error = error.localizedDescription
        }
    }

    /// The TV's answer, shown (and what's worked out from it with it) only when it's new: the page is asked again after
    /// every add and delete, and pulling to refresh, and redraws only for what changed.
    private func take(_ m: Memories) {
        guard m != memories else { return }
        index = MemoriesIndex(m.items)
        memories = m
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
                    // Shrunk and written off the main thread: the page keeps moving while a big photo is prepared.
                    let name = "IMG_\(Int(Date().timeIntervalSince1970))_\(i).jpg", box = fit
                    prepared = try await Task.detached(priority: .userInitiated) { try MemoryPrep.photo(data, name: name, fit: box) }.value
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
                let p: PreparedMemory
                if isVideo {
                    p = PreparedMemory(file: url, name: url.lastPathComponent, taken: nil)
                } else {
                    // Read, shrunk and written off the main thread.
                    let box = fit
                    p = try await Task.detached(priority: .userInitiated) { try MemoryPrep.photo(try Data(contentsOf: url), name: url.lastPathComponent, fit: box) }.value
                }
                _ = try await c.addMemory(file: p.file, name: p.name, taken: p.taken)
                if p.file != url { try? FileManager.default.removeItem(at: p.file) }
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

/// Where the Memories grid is scrolled to, and whether it's moving: written as it scrolls, read only by the month
/// capsule.
@Observable final class MemoriesSpot {
    var top: String?
    var scrolling = false
}

/// What the Memories page works out once per answer from the TV: the counts, and each photo's month.
struct MemoriesIndex {
    var photos = 0
    var videos = 0
    var hasPhotos: Bool { photos > 0 }
    /// Each item's month ("July 2025"; empty when it has no date), by path.
    var month: [String: String] = [:]
    /// The first item's month (shown before the grid has scrolled anywhere).
    var first = ""

    init() {}

    init(_ items: [MemoryItem]) {
        let cal = Calendar.current
        var names: [Int: String] = [:]
        month.reserveCapacity(items.count)
        for i in items {
            if i.video { videos += 1 } else { photos += 1 }
            guard let d = i.takenDate else { month[i.path] = ""; continue }
            let c = cal.dateComponents([.year, .month], from: d)
            let k = (c.year ?? 0) * 100 + (c.month ?? 0)
            let name = names[k] ?? d.formatted(.dateTime.month(.wide).year())
            names[k] = name
            month[i.path] = name
        }
        first = items.first.flatMap { month[$0.path] } ?? ""
    }
}

/// The month of the photos at the top of the screen ("July 2025") in a glass capsule: shown while the grid scrolls,
/// gone a moment after it stops (as Photos does). Only this follows the scrolling.
private struct MonthCapsule: View {
    var spot: MemoriesSpot
    var index: MemoriesIndex
    @State private var shown = false

    var body: some View {
        let name = spot.top.flatMap { index.month[$0] } ?? index.first
        ZStack {
            if shown, !name.isEmpty {
                Text(name)
                    .font(.subheadline.weight(.semibold))
                    .contentTransition(.numericText())
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .glass(Capsule(), interactive: false)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .animation(.snappy, value: name)
            }
        }
        .allowsHitTesting(false)
        .task(id: spot.scrolling) {
            if spot.scrolling {
                withAnimation(.smooth(duration: 0.25)) { shown = true }
            } else if shown {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(.smooth(duration: 0.4)) { shown = false }
            }
        }
    }
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
    /// The Family Memories folder, so Slideshow on TV shows these photos (not whatever folder it last showed).
    var folder: String? = nil
    var onChange: (Memories) -> Void
    @State private var current: String = ""
    @State private var follow = false
    @State private var shareURL: URL?
    @State private var chrome = true
    @State private var confirmDelete = false
    /// Downloading the one shown to share it (once at a time).
    @State private var sharing = false
    #if os(macOS)
    @FocusState private var keys: Bool
    #endif

    private var client: TVClient? { fleet.hubClient() }
    private var item: MemoryItem? { items.first { $0.path == current } }

    var body: some View {
        // Worked out once for the viewer: the photos are handed their addresses.
        let client = self.client
        ZStack {
            Color.black.ignoresSafeArea()
            photos(client)
            if chrome { controls.transition(.opacity) }
        }
        .environment(\.colorScheme, .dark)
        .onAppear { current = start.path }
        // The photos either side are made ready, so the next swipe (or arrow) shows one at once.
        .task(id: current) { await prepareNeighbours(client) }
        .task(id: "\(current)-\(follow)") {
            guard follow, let it = item else { return }
            try? await Task.sleep(nanoseconds: 160_000_000)
            guard !Task.isCancelled else { return }
            do {
                guard let c = client else { throw TVError.notPaired }
                try await c.showMemory(it)
            } catch {
                if Task.isCancelled { return }
                follow = false
                fleet.show(error)
            }
        }
        .confirmationDialog(item?.video == true ? "Delete This Video?" : "Delete This Photo?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { delete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It’s removed from Family Memories on the TVs. This can’t be undone.")
        }
        // Errors from here show over the viewer, not hidden behind it until it closes.
        .sheetBanner()
        #if os(iOS)
        .sheet(item: Binding(get: { shareURL.map { ShareItem(url: $0) } }, set: { shareURL = $0?.url })) { ShareSheet(items: [$0.url]) }
        #else
        // ← and → go through them, as in Photos.
        .focusable()
        .focusEffectDisabled()
        .focused($keys)
        .onAppear { keys = true }
        .onKeyPress(.leftArrow) { step(-1); return .handled }
        .onKeyPress(.rightArrow) { step(1); return .handled }
        #endif
    }

    #if os(iOS)
    private func photos(_ client: TVClient?) -> some View {
        TabView(selection: $current) {
            ForEach(items) { m in
                ZoomableImage(url: client?.photoURL(m)).tag(m.path)
                    .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { chrome.toggle() } }
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .ignoresSafeArea()
    }
    #else
    /// The Mac has no swiping pages (a plain TabView there is a strip of blank tabs): one photo, with the arrows.
    private func photos(_ client: TVClient?) -> some View {
        ZStack {
            if let m = item {
                ZoomableImage(url: client?.photoURL(m))
                    .id(m.path)
                    .transition(.opacity)
                    .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { chrome.toggle() } }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
    }
    #endif

    /// The next and previous photos decoded (as the viewer shows them), the two beyond those downloaded. A moment after
    /// the photo shown changes, so it goes first; stopped when it changes again.
    private func prepareNeighbours(_ client: TVClient?) async {
        guard let c = client, let i = items.firstIndex(where: { $0.path == current }) else { return }
        try? await Task.sleep(nanoseconds: 300_000_000)
        guard !Task.isCancelled else { return }
        let near = [i + 1, i - 1].filter { items.indices.contains($0) }.map { c.photoURL(items[$0]) }
        let far = [i + 2, i - 2].filter { items.indices.contains($0) }.map { c.photoURL(items[$0]) }
        let px = ZoomableImage.maxPixel
        await withTaskGroup(of: Void.self) { g in
            for u in near { g.addTask(priority: .utility) { _ = await ImageStore.shared.image(u, maxPixel: px) } }
            for u in far { g.addTask(priority: .utility) { await ImageStore.shared.prefetch(u) } }
        }
    }

    /// The next (or previous) photo, when there is one.
    private func step(_ by: Int) {
        guard let i = items.firstIndex(where: { $0.path == current }), items.indices.contains(i + by) else { return }
        withAnimation(.easeInOut(duration: 0.2)) { current = items[i + by].path }
    }

    private var controls: some View {
        VStack {
            HStack {
                GlassCircle(symbol: "xmark") { dismiss() }.accessibilityLabel("Close")
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
                    if let it = item, !it.video {
                        Button("Set as TV Background") { act { c in try await c.background(it.path); fleet.say("Background Set", "It’s \(c.hub.name)’s background now.") } }
                    }
                    Button("Slideshow on TV") {
                        act { c in
                            try await c.slideshow(folder: folder, start: true)
                            fleet.say("Slideshow", "Family Memories is playing on \(c.hub.name).")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 17, weight: .semibold)).frame(width: 44, height: 44).glass(Circle())
                }
                .menuStyle(.button).buttonStyle(.plain)
                .accessibilityLabel("More")
            }
            Spacer()
            #if os(macOS)
            HStack {
                GlassCircle(symbol: "chevron.left") { step(-1) }.opacity(items.first?.path == current ? 0.35 : 1)
                    .accessibilityLabel("Previous")
                Spacer()
                GlassCircle(symbol: "chevron.right") { step(1) }.opacity(items.last?.path == current ? 0.35 : 1)
                    .accessibilityLabel("Next")
            }
            Spacer()
            #endif
            HStack {
                Group {
                    if sharing {
                        ProgressView().frame(width: 44, height: 44).glass(Circle(), interactive: false)
                    } else {
                        GlassCircle(symbol: "square.and.arrow.up") { share() }
                    }
                }
                #if os(macOS)
                .accessibilityLabel("Save to Downloads")
                #else
                .accessibilityLabel("Share")
                #endif
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
                GlassCircle(symbol: "trash") { if item != nil { confirmDelete = true } }.accessibilityLabel("Delete")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .glassGroup()
    }

    /// [op] on the TV that holds Family Memories; says so when there's none, or when the TV says no.
    private func act(_ op: @escaping (TVClient) async throws -> Void) {
        guard let c = client else { fleet.show(TVError.notPaired); return }
        Task { do { try await op(c) } catch { fleet.show(error) } }
    }

    private func delete() {
        guard let it = item else { return }
        act { c in
            let m = try await c.deleteMemory(it)
            onChange(m)
            dismiss()
        }
    }

    private func share() {
        guard let it = item, !sharing else { return }
        guard let c = client else { fleet.show(TVError.notPaired); return }
        sharing = true
        Task {
            defer { sharing = false }
            do {
                let name = it.video ? it.name : (it.name as NSString).deletingPathExtension + ".jpg"
                let dest = try await LocalCopy.fetch(it.video ? c.downloadURL(it.path) : c.photoURL(it), name: name, from: c.hub.name)
                #if os(macOS)
                // Kept in Downloads (a temporary folder would be emptied).
                let kept = try LocalCopy.toDownloads(dest)
                NSWorkspace.shared.activateFileViewerSelecting([kept])
                #else
                shareURL = dest
                #endif
            } catch { fleet.show(error) }
        }
    }
}

/// Pinch and double-tap zoom on a photo.
struct ZoomableImage: View {
    /// The pixels a photo is decoded at on its longer side (the viewer gets its neighbours ready at the same).
    static let maxPixel = 1800
    var url: URL?
    @State private var scale: CGFloat = 1
    @State private var last: CGFloat = 1
    var body: some View {
        TVImage(url: url, contentMode: .fit, maxPixel: Self.maxPixel)
            .scaleEffect(scale)
            .gesture(MagnifyGesture()
                .onChanged { v in scale = max(1, min(5, last * v.magnification)) }
                .onEnded { _ in last = scale })
            .onTapGesture(count: 2) { withAnimation(.spring) { scale = scale > 1 ? 1 : 2.5; last = scale } }
    }
}
