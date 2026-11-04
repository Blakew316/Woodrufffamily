import SwiftUI
import QuickLook
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
                PageLink("To") { SendToView(to: to) } label: {
                    LabeledContent("To", value: toSummary)
                }
            }
            Section {
                PageLink("Photos & Files") { FilesView() } label: { IconRow(symbol: "folder.fill", color: .blue, title: "Photos & Files") }
                PageLink("Open a Link") { OpenLinkView() } label: { IconRow(symbol: "link", color: .indigo, title: "Open a Link") }
                Button { startSlideshow() } label: {
                    HStack {
                        IconRow(symbol: "photo.fill", color: .orange, title: "Start Photo Slideshow", subtitle: slideshowTV.map { "On \($0.hub.name)" })
                        if startingSlideshow { ProgressView().controlSize(.small) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(startingSlideshow)
            }
        }
        .formStyle(.grouped)
        .scrollDismissesKeyboard(.interactively)
        .screenTitle("Send")
        .task { await loadPhones() }
    }

    @State private var startingSlideshow = false

    /// The remote's TV when it's paired here (the slideshow has no relay), else the TV that links it.
    private var slideshowTV: TVClient? {
        if let tv = fleet.selected, let own = fleet.hub(tv.id) { return TVClient(hub: own, routeID: "this") }
        return fleet.hubClient()
    }

    private func startSlideshow() {
        guard let c = slideshowTV else { fleet.show(TVError.notPaired); return }
        startingSlideshow = true
        Task {
            do {
                try await c.slideshow(start: true)
                fleet.say("Slideshow", "The photo slideshow is starting on \(c.hub.name).")
            } catch { fleet.show(error) }
            startingSlideshow = false
        }
    }

    /// Someone to send it to: a TV, or a phone.
    private var hasRecipient: Bool { to.allTVs || !to.tvs.isEmpty || !to.phones.isEmpty }

    private var canSend: Bool { !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && hasRecipient }

    private var toSummary: String {
        let others = to.knownPhones.filter { $0.id != fleet.phone.id && $0.name.caseInsensitiveCompare(fleet.phone.name) != .orderedSame }
        let names = Set(others.map { $0.name.lowercased() })
        let phonesOn = Set(others.filter { to.phones.contains($0.id) }.map { $0.name.lowercased() }).count
        if to.allTVs && (names.isEmpty || phonesOn == names.count) { return to.pin ? "Everyone · Pinned" : "Everyone" }
        var parts: [String] = []
        if to.allTVs { parts.append("All TVs") } else if !to.tvs.isEmpty { parts.append(to.tvs.count == 1 ? (to.tvs.first.flatMap { fleet.tv($0)?.name } ?? "1 TV") : "\(to.tvs.count) TVs") }
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
        guard let c = fleet.hubClient() else { fleet.show(TVError.notPaired); return }
        guard hasRecipient else { fleet.say("Who Gets It?", "Pick at least one TV or phone under To."); return }
        let (title, body) = split(message)
        let anyTV = to.allTVs || !to.tvs.isEmpty
        let tvList: [String]? = to.allTVs ? nil : to.tvs.map { $0 == c.hub.id ? "this" : $0 }
        let pin = to.pin
        sending = true
        Task {
            do {
                let r = try await c.announce(title: title, body: body, tv: anyTV, tvs: tvList, phones: Array(to.phones), allPhones: false, from: fleet.phone.name, pin: pin)
                message = ""
                focused = false
                var words: [String] = []
                if let n = r.tvs, n > 0 { words.append(n == 1 ? "1 TV" : "\(n) TVs") }
                if let n = r.phones, n > 0 { words.append(n == 1 ? "1 phone" : "\(n) phones") }
                if !words.isEmpty {
                    fleet.say(pin ? "Pinned on Every TV" : "Sent", "Sent to " + words.joined(separator: " and ") + ".")
                } else if r.tvs == nil && r.phones == nil {
                    // An older TV that doesn't count who got it.
                    fleet.say(pin ? "Pinned on Every TV" : "Sent", "Sent.")
                } else if pin {
                    fleet.say("Pinned on Every TV", "It shows on each TV’s Home as soon as it’s on.")
                } else {
                    // Said honestly: the TVs took the message, but none were on to show it and no phone was reached.
                    fleet.say("Not Delivered Yet", "No TV or phone was reached just now. Turn on “Keep on Every TV’s Home” to leave it for when they’re on.")
                }
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
    @State private var opening = false
    @FocusState private var focused: Bool

    /// Links open on the remote's TV when it's paired here; a TV only linked through another opens it on that one.
    private var target: TVClient? {
        if let tv = fleet.selected, let own = fleet.hub(tv.id) { return TVClient(hub: own, routeID: "this") }
        return fleet.hubClient()
    }

    private var address: String {
        let s = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return "" }
        // "youtube.com/watch?v=…" typed without its start still opens.
        return s.contains("://") ? s : "https://" + s
    }

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
                Text("YouTube links open in YouTube, Apple Music in Apple Music, videos in Woodruff’s player. It opens on \(target?.hub.name ?? "the TV").")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Open a Link")
        .inlineTitle()
        #if os(iOS)
        .toolbar { ToolbarItem(placement: .primaryAction) { openButton } }
        #else
        .macPageBar { openButton }
        #endif
        .onAppear { focused = true }
    }

    private var openButton: some View {
        Button { open() } label: { if opening { ProgressView() } else { Text("Open") } }
            .buttonStyle(.glassProminent)
            .disabled(address.isEmpty || opening)
    }

    private func open() {
        let url = address
        guard !url.isEmpty, !opening else { return }
        guard let c = target else { fleet.show(TVError.notPaired); return }
        opening = true
        Task {
            do {
                try await c.open(url)
                fleet.say("Opening", "It’s opening on \(c.hub.name).")
                dismiss()
            } catch { fleet.show(error) }
            opening = false
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
    @State private var previewing: URL?
    /// The file under the pointer (for Space → Quick Look on the Mac): kept where moving the pointer redraws nothing.
    @State private var hover = HoverSpot()
    /// What's shown, worked out again only when the folder, the search or a view option changes (not at every redraw:
    /// sorting a big folder by name the way Files does is slow).
    @State private var shown: [FileEntry] = []
    /// Why the TV's storage couldn't be opened (with Try Again, instead of placeholders forever).
    @State private var failed: String?
    /// Waiting for "Delete" to be confirmed: nothing on the TV goes without asking (there's no bin to get it back).
    @State private var deleting: FileEntry?

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
    private func filtered(_ listing: FolderListing?) -> [FileEntry] {
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

    /// Upload, or a new folder.
    private var addMenu: some View {
        Menu {
            Button { importing = true } label: { Label("Upload", systemImage: "square.and.arrow.up") }
            Button { askFolder = true } label: { Label("New Folder", systemImage: "folder.badge.plus") }
        } label: { Image(systemName: "plus") }
        .disabled(listing == nil)
    }

    #if os(macOS)
    /// The Mac: the view options and Add beside the search field (the window draws its own bar).
    @ViewBuilder private var filesButtons: some View {
        optionsMenu
        addMenu
    }
    #endif

    var body: some View {
        // Worked out once for the page: the pictures are handed their addresses.
        let client = self.client
        Group {
            if listing == nil, let failed {
                VStack(spacing: 14) {
                    EmptyState(symbol: "wifi.exclamationmark", title: "Can’t Open the TV’s Storage", message: failed)
                    ActionButton(action: { await loadRoots() }) { Text("Try Again") }
                        .buttonStyle(.glass)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if listing == nil {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 108, maximum: 150), spacing: 10)], spacing: 28) {
                        ForEach(0..<12, id: \.self) { _ in
                            VStack(spacing: 8) { Placeholder(corner: 10).frame(width: 84, height: 70); Placeholder(corner: 4).frame(width: 70, height: 12) }
                        }
                    }
                    .padding(16)
                    .shimmer()
                }
            } else if layout == .grid {
                gridView(client)
            } else {
                listView(client)
            }
        }
        #if os(macOS)
        .pageSearch(text: $filter, prompt: "Search") { filesButtons }
        #else
        .pageSearch(text: $filter, prompt: "Search")
        #endif
        .navigationTitle(listing.map { $0.path == root?.path ? (root?.name ?? "Photos & Files") : ($0.path as NSString).lastPathComponent } ?? "Photos & Files")
        .screenTitle(listing.map { $0.path == root?.path ? (root?.name ?? "Photos & Files") : ($0.path as NSString).lastPathComponent } ?? "Photos & Files")
        #if os(iOS)
        .toolbar {
            ToolbarItem(placement: .primaryAction) { optionsMenu }
            ToolbarItem(placement: .primaryAction) { addMenu }
        }
        #endif
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { r in
            if case .success(let urls) = r { upload(urls) }
        }
        .alert("New Folder", isPresented: $askFolder) {
            TextField("Name", text: $newFolder)
            Button("Create") {
                let name = newFolder.trimmingCharacters(in: .whitespacesAndNewlines)
                newFolder = ""
                guard !name.isEmpty, let dir = listing?.path else { return }
                act {
                    guard let c = client else { throw TVError.notPaired }
                    try await c.mkdir(in: dir, name: name)
                    reload()
                }
            }
            .disabled(newFolder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) { newFolder = "" }
        }
        .confirmationDialog("Delete “\(deleting?.name ?? "")”?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { f in
            Button(f.dir ? "Delete Folder" : "Delete", role: .destructive) { delete(f) }
            Button("Cancel", role: .cancel) {}
        } message: { f in
            Text(f.dir ? "Everything in it is deleted from the TV too. This can’t be undone." : "It’s deleted from the TV. This can’t be undone.")
        }
        .task { await loadRoots() }
        .quickLookPreview($previewing)
        .dropDestination(for: URL.self) { urls, _ in upload(urls); return true }
        #if os(macOS)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.space) { if let f = hover.file, !f.dir { quickLook(f); return .handled }; return .ignored }
        #endif
        .onChange(of: filter) { _, _ in refreshShown() }
        .onChange(of: show) { _, _ in refreshShown() }
        .onChange(of: sort) { _, _ in refreshShown() }
        .onChange(of: showHidden) { _, _ in refreshShown() }
        #if os(iOS)
        .sheet(item: Binding(get: { saving.map { ShareItem(url: $0) } }, set: { saving = $0?.url })) { ShareSheet(items: [$0.url]) }
        #endif
    }

    /// Quick Look: downloads the file and previews it (Space on the Mac over a file, or Quick Look in its menu).
    private func quickLook(_ f: FileEntry) {
        guard let c = client else { return }
        progress = "Opening \(f.name)…"
        Task {
            defer { progress = nil }
            do {
                let (tmp, _) = try await URLSession.woodruff.download(from: c.downloadURL(f.path))
                let dest = FileManager.default.temporaryDirectory.appendingPathComponent(f.name)
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: tmp, to: dest)
                previewing = dest
            } catch { fleet.show(error) }
        }
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

    private func listView(_ client: TVClient?) -> some View {
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
            ForEach(shown) { f in row(f, client) }
            Text(footer).font(.footnote).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity).listRowSeparator(.hidden).padding(.vertical, 10)
        }
        .listStyle(.plain)
    }

    private func gridView(_ client: TVClient?) -> some View {
        ScrollView {
            if let progress { HStack(spacing: 12) { ProgressView(); Text(progress).font(.subheadline) }.padding() }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 108, maximum: 150), spacing: 10, alignment: .top)], spacing: 28) {
                if let up = upButton {
                    Button { open(up.0) } label: { tileLabel(kind: .up, title: up.1, lines: ["Back"]) }
                        .buttonStyle(PressScale(scale: 0.95))
                }
                ForEach(shown) { f in tile(f, client) }
            }
            .padding(.horizontal, 16).padding(.top, 8)
            Text(footer).font(.footnote).foregroundStyle(.secondary).padding(.vertical, 24)
        }
    }

    private func kindOf(_ f: FileEntry, _ client: TVClient?) -> FileGlyph.Kind {
        if f.dir { return .folder }
        // Its own picture, unless it's a very big file (downloading all of it for an icon isn't worth it).
        if f.isImage, (f.size ?? 0) <= 15_000_000, let u = client?.downloadURL(f.path) { return .image(u) }
        if f.isVideo { return .document(f.ext.uppercased(), .video) }
        if f.isAudio { return .document(f.ext.uppercased(), .audio) }
        if ["zip", "rar", "7z", "gz", "tar"].contains(f.ext) { return .document(f.ext.uppercased(), .zip) }
        if ["pem", "cer", "crt", "p12", "key", "csr"].contains(f.ext) { return .document(f.ext.uppercased(), .badge) }
        return .document(f.ext.uppercased(), .plain)
    }

    /// Files' dates: the time for today, else a short date (11/1/26).
    private func shortDate(_ f: FileEntry) -> String? {
        guard let ms = f.modified else { return nil }
        let d = Date(timeIntervalSince1970: ms / 1000)
        if Calendar.current.isDateInToday(d) { return d.formatted(date: .omitted, time: .shortened) }
        return d.formatted(.dateTime.month(.defaultDigits).day(.defaultDigits).year(.twoDigits))
    }

    private func detail(_ f: FileEntry) -> String {
        if f.dir { return shortDate(f) ?? "" }
        return [shortDate(f), formatBytes(f.size)].compactMap { $0 }.joined(separator: " – ")
    }

    @ViewBuilder private func tile(_ f: FileEntry, _ client: TVClient?) -> some View {
        let label = tileLabel(kind: kindOf(f, client), title: f.name, lines: [shortDate(f), f.dir ? nil : formatBytes(f.size)].compactMap { $0 })
            .onHover { [hover] inside in if inside { hover.file = f } else if hover.file?.id == f.id { hover.file = nil } }
        Group {
            if f.dir { Button { open(f.path) } label: { label }.buttonStyle(PressScale(scale: 0.95)) }
            else { Menu { menu(f) } label: { label }.menuStyle(.button).buttonStyle(.plain) }
        }
        .contextMenu { menu(f) }
    }

    /// As Files lays out an icon: the picture, the name (two lines, cut in the middle), then the date and the size.
    private func tileLabel(kind: FileGlyph.Kind, title: String, lines: [String]) -> some View {
        VStack(spacing: 3) {
            FileGlyph(kind: kind, size: 92).frame(height: 96, alignment: .bottom).padding(.bottom, 6)
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
            ForEach(lines, id: \.self) { Text($0).font(.footnote).foregroundStyle(.secondary).lineLimit(1) }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .contentShape(Rectangle())
    }

    @ViewBuilder private func row(_ f: FileEntry, _ client: TVClient?) -> some View {
        let label = HStack(spacing: 12) {
            FileGlyph(kind: kindOf(f, client), size: 40)
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
        .swipeActions { Button(role: .destructive) { deleting = f } label: { Label("Delete", systemImage: "trash") } }
    }

    @ViewBuilder private func menu(_ f: FileEntry) -> some View {
        if f.dir {
            Button { withTV { c in try await c.slideshow(folder: f.path, start: false); fleet.say("Slideshow", "The slideshow on \(c.hub.name) shows \(f.name) now.") } } label: { Label("Use for Slideshow", systemImage: "play.rectangle") }
        }
        if f.isMedia {
            Button {
                withTV { c in
                    let r = try await c.play(path: f.path)
                    if r.started?.bool == false { fleet.say("Ready on \(c.hub.name)", r.message ?? "Open Woodruff on \(c.hub.name) to start it.") }
                    else if let m = r.message { fleet.say("Playing on \(c.hub.name)", m) }
                }
            } label: { Label("Play on TV", systemImage: "play.tv") }
        }
        if f.isImage {
            Button { withTV { c in try await c.background(f.path); fleet.say("Background Set", "\(f.name) is \(c.hub.name)’s background.") } } label: { Label("Set as TV Background", systemImage: "photo.on.rectangle") }
        }
        if !f.dir {
            Button { quickLook(f) } label: { Label("Quick Look", systemImage: "eye") }
            Button { save(f) } label: { Label("Save to This Device", systemImage: "square.and.arrow.down") }
        }
        Divider()
        Button(role: .destructive) { deleting = f } label: { Label("Delete", systemImage: "trash") }
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

    /// [op] on the TV whose storage this is; says so when there's none, or when the TV says no.
    private func withTV(_ op: @escaping (TVClient) async throws -> Void) {
        guard let c = client else { fleet.show(TVError.notPaired); return }
        Task { do { try await op(c) } catch { fleet.show(error) } }
    }

    private func delete(_ f: FileEntry) {
        withTV { c in
            try await c.delete(f.path)
            reload()
        }
    }

    private func loadRoots() async {
        guard let c = client else { failed = TVError.notPaired.localizedDescription; return }
        failed = nil
        do {
            let r = try await c.roots()
            roots = r
            if let first = r.first {
                if path == nil || listing == nil { open(path ?? first.path) }
            } else {
                failed = "\(c.hub.name) didn’t list any storage."
            }
        } catch {
            if Task.isCancelled { return }
            failed = error.localizedDescription
        }
    }

    /// Opens folder [p]: the place moves only once the TV has answered with what's in it.
    private func open(_ p: String) {
        guard let c = client else { fleet.show(TVError.notPaired); return }
        Task {
            do {
                let l = try await c.list(p)
                path = p
                let list = filtered(l)
                withAnimation(.snappy) {
                    listing = l
                    shown = list
                }
                failed = nil
            } catch {
                if listing == nil { failed = error.localizedDescription } else { fleet.show(error) }
            }
        }
    }

    private func reload() { if let path { open(path) } }

    /// The search or a view option changed: what's shown is worked out again.
    private func refreshShown() { shown = filtered(listing) }

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

/// The file under the pointer in the TV's files. A plain box: the pointer moving over the icons changes it all the time,
/// and nothing on screen shows it.
final class HoverSpot {
    var file: FileEntry?
}

/// File icons drawn the way Apple's Files app draws them: the two-tone blue folder, a photo's own picture
/// with a thin border, and a white page with a folded corner, a grey glyph and the file's type underneath.
struct FileGlyph: View {
    enum Glyph { case plain, zip, badge, video, audio }
    enum Kind { case folder, up, image(URL), document(String, Glyph) }
    var kind: Kind
    var size: CGFloat

    var body: some View {
        switch kind {
        case .folder: FolderIcon().frame(width: size, height: size * 0.8)
        case .up:
            Image(systemName: "arrow.turn.left.up")
                .font(.system(size: size * 0.36, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size * 0.8)
        case .image(let url):
            // An icon's worth of the picture, kept in memory only (these are the TV's own photos, often big).
            Artwork(url: url, contentMode: .fit, maxPixel: 256, storeOnDisk: false)
                .frame(maxWidth: size * 0.86, maxHeight: size * 0.86)
                .background(Color.white)
                .overlay(Rectangle().strokeBorder(.black.opacity(0.18), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.3), radius: 1.5, y: 1)
        case .document(let ext, let glyph):
            PageIcon(ext: ext, glyph: glyph).frame(width: size * 0.62, height: size * 0.82)
        }
    }
}

/// The Files folder: a darker back panel with its tab, and a lighter front panel.
struct FolderIcon: View {
    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height, r = w * 0.07
            ZStack(alignment: .topLeading) {
                // Back panel and tab
                UnevenRoundedRectangle(topLeadingRadius: r, bottomLeadingRadius: r, bottomTrailingRadius: r, topTrailingRadius: r * 0.6, style: .continuous)
                    .fill(Color(red: 0.36, green: 0.62, blue: 0.93))
                    .frame(width: w * 0.42, height: h * 0.3)
                RoundedRectangle(cornerRadius: r, style: .continuous)
                    .fill(Color(red: 0.36, green: 0.62, blue: 0.93))
                    .frame(width: w, height: h * 0.86)
                    .offset(y: h * 0.1)
                // Front panel
                RoundedRectangle(cornerRadius: r, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.55, green: 0.78, blue: 1), Color(red: 0.43, green: 0.69, blue: 0.98)], startPoint: .top, endPoint: .bottom))
                    .frame(width: w, height: h * 0.76)
                    .offset(y: h * 0.24)
            }
        }
    }
}

/// A white page with a folded top-right corner, a grey glyph and the type (ZIP, PDF…) at the bottom.
struct PageIcon: View {
    var ext: String
    var glyph: FileGlyph.Glyph

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height, fold = w * 0.3
            ZStack {
                PageShape(fold: fold).fill(Color(white: 0.96))
                PageShape(fold: fold).stroke(.black.opacity(0.1), lineWidth: 0.5)
                // The folded corner.
                Path { p in
                    p.move(to: CGPoint(x: w - fold, y: 0))
                    p.addLine(to: CGPoint(x: w - fold, y: fold))
                    p.addLine(to: CGPoint(x: w, y: fold))
                    p.closeSubpath()
                }
                .fill(Color(white: 0.84))
                glyphView(w: w)
                    .foregroundStyle(Color(white: 0.6))
                    .position(x: w / 2, y: glyph == .zip ? h * 0.36 : h * 0.44)
                Text(ext.isEmpty ? "" : String(ext.prefix(4)))
                    .font(.system(size: w * 0.15, weight: .medium))
                    .foregroundStyle(Color(white: 0.6))
                    .position(x: w / 2, y: h * 0.86)
            }
            .shadow(color: .black.opacity(0.25), radius: 1.2, y: 0.8)
        }
    }

    @ViewBuilder private func glyphView(w: CGFloat) -> some View {
        switch glyph {
        case .zip:
            // A zipper down the page.
            VStack(spacing: w * 0.03) {
                Capsule().frame(width: w * 0.12, height: w * 0.2)
                ForEach(0..<4, id: \.self) { i in
                    Capsule().frame(width: w * 0.14, height: w * 0.05).offset(x: i % 2 == 0 ? -w * 0.04 : w * 0.04)
                }
            }
        case .badge: Image(systemName: "seal.fill").font(.system(size: w * 0.38))
        case .video: Image(systemName: "play.fill").font(.system(size: w * 0.3))
        case .audio: Image(systemName: "music.note").font(.system(size: w * 0.32, weight: .semibold))
        case .plain: EmptyView()
        }
    }
}

/// A page outline with its top-right corner cut for the fold.
struct PageShape: Shape {
    var fold: CGFloat
    func path(in r: CGRect) -> Path {
        var p = Path()
        let c: CGFloat = min(r.width, r.height) * 0.05
        p.move(to: CGPoint(x: r.minX + c, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - fold, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + fold))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - c))
        p.addQuadCurve(to: CGPoint(x: r.maxX - c, y: r.maxY), control: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + c, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: r.maxY - c), control: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + c))
        p.addQuadCurve(to: CGPoint(x: r.minX + c, y: r.minY), control: CGPoint(x: r.minX, y: r.minY))
        p.closeSubpath()
        return p
    }
}
