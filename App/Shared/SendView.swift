import SwiftUI
import UniformTypeIdentifiers
import WoodruffKit

/// Who an announcement goes to (Send → To).
@Observable final class Recipients {
    var allTVs = true
    var tvs: Set<String> = []
    var phones: Set<String> = []
    var pin = false
    var knownPhones: [Phone] = []
    var loadedPhones = false
}

/// Send: a message to TVs and phones (or kept on every TV's Home), the TV's photos and files, a link, the slideshow.
struct SendView: View {
    @Environment(Fleet.self) private var fleet
    @State private var message = ""
    @State private var to = Recipients()
    @State private var sending = false
    @FocusState private var focused: Bool

    var body: some View {
        Form {
            Section {
                // Like Messages: the send arrow sits in the message itself, and the box grows as you write.
                HStack(alignment: .bottom, spacing: 10) {
                    TextField("Message", text: $message, axis: .vertical)
                        .lineLimit(1...6)
                        .focused($focused)
                        .padding(.vertical, 6)
                    Button { send() } label: {
                        if sending {
                            ProgressView().frame(width: 32, height: 32)
                        } else {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 30))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, canSend ? Color.accentColor : Color.gray.opacity(0.4))
                        }
                    }
                    .buttonStyle(PressScale())
                    .disabled(!canSend || sending)
                    .accessibilityLabel("Send")
                    .animation(.snappy, value: canSend)
                }
                NavigationLink { SendToView(to: to) } label: {
                    LabeledContent("To", value: toSummary)
                }
            }
            Section {
                NavigationLink { FilesView() } label: { IconRow(symbol: "folder.fill", color: .blue, title: "Photos & Files") }
                NavigationLink { OpenLinkView() } label: { IconRow(symbol: "link", color: .indigo, title: "Open a Link") }
                Button {
                    Task {
                        do { try await fleet.hubClient()?.slideshow(start: true); fleet.say("Slideshow", "The photo slideshow is starting on \(fleet.hubClient()?.hub.name ?? "the TV").") }
                        catch { fleet.show(error) }
                    }
                } label: { IconRow(symbol: "photo.fill", color: .orange, title: "Start Photo Slideshow") }
                .buttonStyle(.plain)
            }
        }
        .formStyle(.grouped)
        .scrollDismissesKeyboard(.interactively)
        .screenTitle("Send")
        .task { await loadPhones() }
    }

    private var canSend: Bool { !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var toSummary: String {
        let others = to.knownPhones.filter { $0.id != fleet.phone.id && $0.name.caseInsensitiveCompare(fleet.phone.name) != .orderedSame }
        let names = Set(others.map { $0.name.lowercased() })
        let phonesOn = Set(others.filter { to.phones.contains($0.id) }.map { $0.name.lowercased() }).count
        if to.allTVs && (names.isEmpty || phonesOn == names.count) { return to.pin ? "Everyone · Pinned" : "Everyone" }
        var parts: [String] = []
        if to.allTVs { parts.append("All TVs") } else if !to.tvs.isEmpty { parts.append(to.tvs.count == 1 ? (fleet.tv(to.tvs.first!)?.name ?? "1 TV") : "\(to.tvs.count) TVs") }
        if phonesOn > 0 { parts.append(phonesOn == 1 ? "1 phone" : "\(phonesOn) phones") }
        return parts.isEmpty ? "No one" : parts.joined(separator: ", ")
    }

    private func loadPhones() async {
        guard !to.loadedPhones, let c = fleet.hubClient(), let p = try? await c.phones() else { return }
        to.knownPhones = p
        to.phones = Set(p.filter { $0.id != fleet.phone.id && $0.name.caseInsensitiveCompare(fleet.phone.name) != .orderedSame }.map(\.id))
        to.loadedPhones = true
    }

    /// The phone page's rule: a short first line is the title, the rest the body; otherwise "From <name>".
    private func split(_ text: String) -> (String, String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = t.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        if let first = lines.first, first.count <= 80 { return (first, lines.count > 1 ? lines[1].trimmingCharacters(in: .whitespacesAndNewlines) : "") }
        return ("From \(fleet.phone.name)", t)
    }

    private func send() {
        guard let c = fleet.hubClient() else { return }
        let (title, body) = split(message)
        let anyTV = to.allTVs || !to.tvs.isEmpty
        let tvList: [String]? = to.allTVs ? nil : to.tvs.map { $0 == c.hub.id ? "this" : $0 }
        sending = true
        Task {
            do {
                let r = try await c.announce(title: title, body: body, tv: anyTV, tvs: tvList, phones: Array(to.phones), allPhones: false, from: fleet.phone.name, pin: to.pin)
                message = ""
                focused = false
                var words: [String] = []
                if let n = r.tvs, n > 0 { words.append(n == 1 ? "the TV" : "\(n) TVs") }
                if let n = r.phones, n > 0 { words.append(n == 1 ? "1 phone" : "\(n) phones") }
                fleet.say(to.pin ? "Pinned on Every TV" : "Sent", words.isEmpty ? "Sent." : "Sent to " + words.joined(separator: " and ") + ".")
            } catch { fleet.show(error) }
            sending = false
        }
    }
}

/// Send → To: TVs, phones, and keeping it on every TV's Home.
struct SendToView: View {
    @Environment(Fleet.self) private var fleet
    @Bindable var to: Recipients

    struct PhoneGroup { var name: String; var ids: Set<String>; var lockScreen: Bool }

    private var phoneGroups: [PhoneGroup] {
        var groups: [String: PhoneGroup] = [:]
        for p in to.knownPhones where p.id != fleet.phone.id && p.name.caseInsensitiveCompare(fleet.phone.name) != .orderedSame {
            let key = p.name.lowercased()
            var g = groups[key] ?? PhoneGroup(name: p.name, ids: [], lockScreen: false)
            g.ids.insert(p.id)
            g.lockScreen = g.lockScreen || p.alerts == true
            groups[key] = g
        }
        return groups.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $to.allTVs) { IconRow(symbol: "tv.fill", color: .blue, title: "All TVs") }
                if !to.allTVs {
                    ForEach(fleet.tvs) { tv in
                        Toggle(isOn: Binding(get: { to.tvs.contains(tv.id) }, set: { if $0 { to.tvs.insert(tv.id) } else { to.tvs.remove(tv.id) } })) {
                            IconRow(symbol: "tv.fill", color: tv.online ? .blue : .gray, title: tv.name, subtitle: tv.online ? nil : "Off")
                        }
                    }
                }
                // One row per device (earlier installs left copies under the same name), none for this device.
                ForEach(phoneGroups, id: \.name) { g in
                    Toggle(isOn: Binding(
                        get: { !to.phones.isDisjoint(with: g.ids) },
                        set: { on in if on { to.phones.formUnion(g.ids) } else { to.phones.subtract(g.ids) } })) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(g.name)
                            Text(g.lockScreen ? "Lock screen" : "When Woodruff is open").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section {
                Toggle("Keep on Every TV’s Home", isOn: $to.pin)
            } footer: {
                Text("It stays on every TV’s Home until someone dismisses it there, also on TVs that are off right now.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Send To")
        .inlineTitle()
    }
}

/// Opens a YouTube, Apple Music or video link on the remote's TV.
struct OpenLinkView: View {
    @Environment(Fleet.self) private var fleet
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @FocusState private var focused: Bool

    var body: some View {
        Form {
            Section {
                TextField("https://", text: $link)
                    .focused($focused)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never).keyboardType(.URL)
                    #endif
                    .onSubmit { open() }
                #if os(iOS)
                PasteButton(payloadType: String.self) { s in link = s.first ?? "" }
                #endif
            } footer: {
                Text("YouTube links open in YouTube, Apple Music in Apple Music, videos in Woodruff’s player. It opens on \(fleet.selected?.name ?? "the TV").")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Open a Link")
        .inlineTitle()
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Open") { open() }.buttonStyle(.glassProminent).disabled(link.isEmpty)
            }
        }
        .onAppear { focused = true }
    }

    private func open() {
        let url = link.trimmingCharacters(in: .whitespaces)
        Task {
            do {
                guard let tv = fleet.selected, let hub = fleet.hubClient() else { return }
                // Links open on a TV paired here; a linked TV goes through its own pairing when there is one.
                let c = fleet.hub(tv.id).map { TVClient(hub: $0, routeID: "this") } ?? hub
                try await c.open(url)
                fleet.say("Opening", "It’s opening on \(c.hub.name).")
                dismiss()
            } catch { fleet.show(error) }
        }
    }
}

/// The TV's storage: browse, play, background, slideshow, save, upload, new folder, delete.
struct FilesView: View {
    @Environment(Fleet.self) private var fleet
    @State private var roots: [StorageRoot] = []
    @State private var listing: FolderListing?
    @State private var path: String?
    @State private var filter = ""
    @State private var importing = false
    @State private var newFolder = ""
    @State private var askFolder = false
    @State private var progress: String?
    @State private var saving: URL?

    private var client: TVClient? { fleet.hubClient() }
    private var root: StorageRoot? { roots.first { path?.hasPrefix($0.path) == true } ?? roots.first }

    enum Layout: String { case list, grid }
    enum Sort: String { case name, date, size, kind }
    enum Show: String { case all, folders, photos, videos, music, documents }
    @AppStorage("files.layout2") private var layout: Layout = .grid
    @AppStorage("files.sort") private var sort: Sort = .name
    @AppStorage("files.show") private var show: Show = .all
    @AppStorage("files.hidden") private var showHidden = false

    /// What's shown: search, the Show filter, hidden files, then the sort (folders first, like Files).
    private var shown: [FileEntry] {
        guard let l = listing else { return [] }
        let list = l.files.filter { f in
            if !showHidden && f.name.hasPrefix(".") { return false }
            if !filter.isEmpty && !f.name.localizedCaseInsensitiveContains(filter) { return false }
            switch show {
            case .all: return true
            case .folders: return f.dir
            case .photos: return f.isImage
            case .videos: return f.isVideo
            case .music: return f.isAudio
            case .documents: return !f.dir && !f.isMedia
            }
        }
        return list.sorted { x, y in
            if x.dir != y.dir { return x.dir }
            switch sort {
            case .name: return x.name.localizedStandardCompare(y.name) == .orderedAscending
            case .date: return (x.modified ?? 0) > (y.modified ?? 0)
            case .size: return (x.size ?? 0) > (y.size ?? 0)
            case .kind: return x.ext == y.ext ? x.name.localizedStandardCompare(y.name) == .orderedAscending : x.ext < y.ext
            }
        }
    }

    var body: some View {
        Group {
            if listing == nil {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if layout == .grid {
                gridView
            } else {
                listView
            }
        }
        .searchable(text: $filter, prompt: "Search")
        .navigationTitle(listing.map { $0.path == root?.path ? (root?.name ?? "Photos & Files") : ($0.path as NSString).lastPathComponent } ?? "Photos & Files")
        .screenTitle(listing.map { $0.path == root?.path ? (root?.name ?? "Photos & Files") : ($0.path as NSString).lastPathComponent } ?? "Photos & Files")
        .toolbar {
            ToolbarItem(placement: .primaryAction) { optionsMenu }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { importing = true } label: { Label("Upload", systemImage: "square.and.arrow.up") }
                    Button { askFolder = true } label: { Label("New Folder", systemImage: "folder.badge.plus") }
                } label: { Image(systemName: "plus") }
                .disabled(listing == nil)
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { r in
            if case .success(let urls) = r { upload(urls) }
        }
        .alert("New Folder", isPresented: $askFolder) {
            TextField("Name", text: $newFolder)
            Button("Create") {
                let name = newFolder; newFolder = ""
                act { try await client?.mkdir(in: listing?.path ?? "", name: name); reload() }
            }
            Button("Cancel", role: .cancel) {}
        }
        .task { await loadRoots() }
        #if os(iOS)
        .sheet(item: Binding(get: { saving.map { ShareItem(url: $0) } }, set: { saving = $0?.url })) { ShareSheet(items: [$0.url]) }
        #endif
    }

    /// View, sort, filter, hidden files and the storage, in one menu (as the Files app does it).
    private var optionsMenu: some View {
        Menu {
            Picker("View", selection: $layout) {
                Label("Icons", systemImage: "square.grid.2x2").tag(Layout.grid)
                Label("List", systemImage: "list.bullet").tag(Layout.list)
            }
            .pickerStyle(.inline)
            Picker("Sort By", selection: $sort) {
                Text("Name").tag(Sort.name); Text("Date").tag(Sort.date); Text("Size").tag(Sort.size); Text("Kind").tag(Sort.kind)
            }
            .pickerStyle(.menu)
            Picker("Show", selection: $show) {
                Text("All Items").tag(Show.all); Text("Folders").tag(Show.folders); Text("Photos").tag(Show.photos)
                Text("Videos").tag(Show.videos); Text("Music").tag(Show.music); Text("Documents").tag(Show.documents)
            }
            .pickerStyle(.menu)
            Toggle("Show Hidden Files", isOn: $showHidden)
            if roots.count > 1 {
                Picker("Storage", selection: Binding(get: { root?.path ?? "" }, set: { open($0) })) {
                    ForEach(roots) { r in Text(r.name + (r.free.map { " · \(formatBytes($0)) free" } ?? "")).tag(r.path) }
                }
                .pickerStyle(.menu)
            }
        } label: { Image(systemName: "ellipsis") }
    }

    /// The footer, as Files writes it: "15 items, 15.37 GB available".
    private var footer: String {
        let n = shown.count
        var t = n == 1 ? "1 item" : "\(n) items"
        if let f = listing?.free ?? root?.free { t += ", \(formatBytes(f)) available" }
        return t
    }

    private var upButton: (String, String)? {
        guard let l = listing, let parent = l.parent, l.path != root?.path else { return nil }
        return (parent, (parent as NSString).lastPathComponent)
    }

    private var listView: some View {
        List {
            if let progress { HStack(spacing: 12) { ProgressView(); Text(progress).font(.subheadline) } }
            if let up = upButton {
                Button { open(up.0) } label: {
                    HStack(spacing: 12) {
                        FileGlyph(kind: .up, size: 40)
                        Text(up.1).foregroundStyle(.primary)
                    }
                }
                .buttonStyle(.plain)
            }
            ForEach(shown) { f in row(f) }
            Text(footer).font(.footnote).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity).listRowSeparator(.hidden).padding(.vertical, 10)
        }
        .listStyle(.plain)
    }

    private var gridView: some View {
        ScrollView {
            if let progress { HStack(spacing: 12) { ProgressView(); Text(progress).font(.subheadline) }.padding() }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104, maximum: 140), spacing: 12, alignment: .top)], spacing: 22) {
                if let up = upButton {
                    Button { open(up.0) } label: { tileLabel(kind: .up, title: up.1, sub: "Back") }
                        .buttonStyle(PressScale(scale: 0.95))
                }
                ForEach(shown) { f in tile(f) }
            }
            .padding(.horizontal, 16).padding(.top, 8)
            Text(footer).font(.footnote).foregroundStyle(.secondary).padding(.vertical, 24)
        }
    }

    private func kindOf(_ f: FileEntry) -> FileGlyph.Kind {
        if f.dir { return .folder }
        if f.isImage, let u = client?.downloadURL(f.path) { return .image(u) }
        if f.isVideo { return .video }
        if f.isAudio { return .audio }
        return .document(f.ext.uppercased())
    }

    private func detail(_ f: FileEntry) -> String {
        let date = f.modified.map { Date(timeIntervalSince1970: $0 / 1000).formatted(date: .numeric, time: .omitted) }
        if f.dir { return date ?? "Folder" }
        return [date, formatBytes(f.size)].compactMap { $0 }.joined(separator: " – ")
    }

    @ViewBuilder private func tile(_ f: FileEntry) -> some View {
        let label = tileLabel(kind: kindOf(f), title: f.name, sub: detail(f))
        Group {
            if f.dir { Button { open(f.path) } label: { label }.buttonStyle(PressScale(scale: 0.95)) }
            else { Menu { menu(f) } label: { label }.menuStyle(.button).buttonStyle(.plain) }
        }
        .contextMenu { menu(f) }
    }

    /// A Files icon: the glyph or photo, the name (two lines, cut in the middle) and the date / size.
    private func tileLabel(kind: FileGlyph.Kind, title: String, sub: String) -> some View {
        VStack(spacing: 6) {
            FileGlyph(kind: kind, size: 78).frame(height: 84)
            Text(title).font(.caption).lineLimit(2).truncationMode(.middle).multilineTextAlignment(.center)
            Text(sub).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    @ViewBuilder private func row(_ f: FileEntry) -> some View {
        let label = HStack(spacing: 12) {
            FileGlyph(kind: kindOf(f), size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(f.name).lineLimit(1).truncationMode(.middle)
                Text(detail(f)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        Group {
            if f.dir { Button { open(f.path) } label: { label }.buttonStyle(.plain) }
            else { Menu { menu(f) } label: { label }.menuStyle(.button).buttonStyle(.plain) }
        }
        .contextMenu { menu(f) }
        .swipeActions { Button(role: .destructive) { act { try await client?.delete(f.path); reload() } } label: { Label("Delete", systemImage: "trash") } }
    }

    @ViewBuilder private func menu(_ f: FileEntry) -> some View {
        if f.dir {
            Button { act { try await client?.slideshow(folder: f.path, start: false); fleet.say("Slideshow", "The slideshow shows \(f.name) now.") } } label: { Label("Use for Slideshow", systemImage: "play.rectangle") }
        }
        if f.isMedia {
            Button { act { let r = try await client?.play(path: f.path); if let m = r?.message { fleet.say("Ready on the TV", m) } } } label: { Label("Play on TV", systemImage: "play.tv") }
        }
        if f.isImage {
            Button { act { try await client?.background(f.path); fleet.say("Background Set", "\(f.name) is the TV’s background.") } } label: { Label("Set as TV Background", systemImage: "photo.on.rectangle") }
        }
        if !f.dir {
            Button { save(f) } label: { Label("Save to This Device", systemImage: "square.and.arrow.down") }
        }
        Divider()
        Button(role: .destructive) { act { try await client?.delete(f.path); reload() } } label: { Label("Delete", systemImage: "trash") }
    }

    private func icon(_ f: FileEntry) -> String {
        f.dir ? "folder.fill" : f.isVideo ? "play.fill" : f.isImage ? "photo.fill" : f.isAudio ? "music.note" : f.ext == "apk" ? "shippingbox.fill" : "doc.fill"
    }
    private func color(_ f: FileEntry) -> Color {
        f.dir ? .blue : f.isVideo ? .purple : f.isImage ? .teal : f.isAudio ? .pink : .gray
    }
    private func kind(_ f: FileEntry) -> String {
        f.isVideo ? "Video" : f.isImage ? "Photo" : f.isAudio ? "Music" : f.ext.uppercased()
    }

    private func act(_ op: @escaping () async throws -> Void) { Task { do { try await op() } catch { fleet.show(error) } } }

    private func loadRoots() async {
        guard let c = client else { return }
        do {
            roots = try await c.roots()
            if path == nil, let first = roots.first { open(first.path) }
        } catch { fleet.show(error) }
    }

    private func open(_ p: String) {
        path = p
        Task {
            do { let l = try await client?.list(p); withAnimation(.snappy) { listing = l } } catch { fleet.show(error) }
        }
    }

    private func reload() { if let path { open(path) } }

    private func upload(_ urls: [URL]) {
        guard let dir = listing?.path, let c = client else { return }
        Task {
            for (i, url) in urls.enumerated() {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                progress = "Uploading \(i + 1) of \(urls.count): \(url.lastPathComponent)"
                do {
                    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Double.init) ?? 0
                    if let free = listing?.free, size > free { throw TVError.badAnswer("\(url.lastPathComponent) is \(formatBytes(size)); there’s \(formatBytes(free)) free.") }
                    _ = try await c.upload(file: url, to: dir, name: url.lastPathComponent)
                } catch { fleet.show(error); break }
            }
            progress = nil
            reload()
        }
    }

    private func save(_ f: FileEntry) {
        guard let c = client else { return }
        progress = "Downloading \(f.name)…"
        Task {
            defer { progress = nil }
            do {
                let (tmp, _) = try await URLSession.woodruff.download(from: c.downloadURL(f.path))
                let dest = FileManager.default.temporaryDirectory.appendingPathComponent(f.name)
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: tmp, to: dest)
                #if os(macOS)
                let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].appendingPathComponent(f.name)
                try? FileManager.default.removeItem(at: downloads)
                try FileManager.default.moveItem(at: dest, to: downloads)
                NSWorkspace.shared.activateFileViewerSelecting([downloads])
                #else
                saving = dest
                #endif
            } catch { fleet.show(error) }
        }
    }
}

/// File icons in the style of Apple's Files app: the blue folder, a photo's own picture, or a page with its kind.
struct FileGlyph: View {
    enum Kind { case folder, up, image(URL), video, audio, document(String) }
    var kind: Kind
    var size: CGFloat

    var body: some View {
        switch kind {
        case .folder:
            Image(systemName: "folder.fill")
                .resizable().aspectRatio(contentMode: .fit)
                .foregroundStyle(LinearGradient(colors: [Color(red: 0.45, green: 0.75, blue: 1), Color(red: 0.27, green: 0.6, blue: 0.97)], startPoint: .top, endPoint: .bottom))
                .frame(width: size, height: size * 0.82)
        case .up:
            Image(systemName: "arrow.turn.left.up")
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size * 0.82)
        case .image(let url):
            Artwork(url: url)
                .frame(width: size * 0.92, height: size * 0.72)
                .clipShape(RoundedRectangle(cornerRadius: max(3, size * 0.06), style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: max(3, size * 0.06), style: .continuous).strokeBorder(.white.opacity(0.15), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
        case .video: page(symbol: "play.fill", tint: .purple)
        case .audio: page(symbol: "music.note", tint: .pink)
        case .document(let ext): page(text: ext.isEmpty ? "DOC" : String(ext.prefix(4)), tint: .gray)
        }
    }

    /// A white page with a folded corner and the file's kind.
    private func page(symbol: String? = nil, text: String? = nil, tint: Color) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.08, style: .continuous)
                .fill(Color(white: 0.96))
                .overlay(RoundedRectangle(cornerRadius: size * 0.08, style: .continuous).strokeBorder(.black.opacity(0.08), lineWidth: 0.5))
            if let symbol { Image(systemName: symbol).font(.system(size: size * 0.3, weight: .semibold)).foregroundStyle(tint) }
            if let text { Text(text).font(.system(size: size * 0.16, weight: .bold, design: .rounded)).foregroundStyle(tint) }
        }
        .frame(width: size * 0.66, height: size * 0.84)
        .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)
    }
}
