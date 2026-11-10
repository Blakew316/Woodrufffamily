import SwiftUI
#if canImport(QuickLook)
import QuickLook
#endif
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
    #if os(macOS)
    /// Files are being dragged over the page.
    @State private var dropTargeted = false
    /// Files dropped on the page, on their way to the TV: "Sending 2 of 3…".
    @State private var sendingFiles: String?
    /// False while the page is out of sight under one opened from it (Settings keeps it there): nowhere to drop then.
    @Environment(\.isEnabled) private var isEnabled
    #endif

    var body: some View {
        #if os(macOS)
        macBody
        #else
        phoneBody
        #endif
    }

    #if os(macOS)
    /// The Mac: a composer card in the middle of the page (who it goes to inside it, Send beside the words), then the
    /// other things to send as three cards under it.
    private var macBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Send a Message").font(.system(size: 30, weight: .bold, design: .rounded))
                    Text("It shows on the TVs and the family’s phones.").font(.title3).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 0) {
                    PageLink("To") { SendToView(to: to) } label: {
                        HStack(spacing: 8) {
                            Text("To").foregroundStyle(.secondary)
                            Text(toSummary).fontWeight(.semibold)
                            Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
                            Spacer(minLength: 0)
                        }
                        .font(.body)
                        .padding(.horizontal, 20).padding(.vertical, 14)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider().padding(.horizontal, 20)
                    TextField("Write a message…", text: $message, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 19, weight: .regular, design: .rounded))
                        .lineLimit(4...10)
                        .focused($focused)
                        .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 8)
                    HStack {
                        Text("A short first line becomes its title.").font(.footnote).foregroundStyle(.tertiary)
                        Spacer()
                        Button { send() } label: {
                            HStack(spacing: 8) {
                                if sending { ProgressView().controlSize(.small) }
                                Text("Send").fontWeight(.semibold)
                            }
                            .padding(.horizontal, 14)
                        }
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                        .disabled(!canSend || sending)
                        .keyboardShortcut(.return, modifiers: .command)
                        .help("Send (⌘↩)")
                    }
                    .padding(.horizontal, 20).padding(.bottom, 16)
                }
                // What's being written is content: a plain fill with a hairline round it, not glass. The glass is its
                // Send button's (and the three cards' under it, which are buttons themselves).
                .background(.quinary, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(.quaternary, lineWidth: 1).allowsHitTesting(false)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Also Send").font(.headline).foregroundStyle(.secondary)
                    HStack(spacing: 14) {
                        PageLink("Photos & Files") { FilesView() } label: {
                            SendCard(symbol: "folder.fill", tint: .blue, title: "Photos & Files",
                                     detail: sendingFiles ?? (dropTargeted ? "Drop to send" : "Put them on a TV"))
                        }
                        .buttonStyle(.plain)
                        PageLink("Open a Link") { OpenLinkView() } label: {
                            SendCard(symbol: "link", tint: .indigo, title: "Open a Link", detail: "A page or video on a TV")
                        }
                        .buttonStyle(.plain)
                        Button { startSlideshow() } label: {
                            SendCard(symbol: "photo.on.rectangle.angled", tint: .orange, title: "Photo Slideshow",
                                     detail: startingSlideshow ? "Starting…" : (slideshowTV.map { "On \($0.hub.name)" } ?? "On the TV"))
                        }
                        .buttonStyle(.plain)
                        .disabled(startingSlideshow)
                    }
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(.horizontal, 28).padding(.vertical, 24)
            .frame(maxWidth: .infinity)
        }
        .task { await loadPhones() }
        .onAppear { focused = true }
        // Files dropped anywhere on the page go to the TV, as Photos & Files' Upload sends them.
        .dropDestination(for: URL.self) { urls, _ in
            guard isEnabled else { return false }
            sendFiles(urls)
            return true
        } isTargeted: { dropTargeted = $0 && isEnabled }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
    }

    /// Files dropped on the page go into the TV's storage (the first it lists), where Photos & Files shows them.
    private func sendFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        guard let c = fleet.hubClient() else { fleet.show(TVError.notPaired); return }
        guard sendingFiles == nil else { fleet.alert("One Moment", "Wait for the file being sent to finish, then try again."); return }
        sendingFiles = "Sending…"
        Task {
            defer { sendingFiles = nil }
            do {
                guard let root = try await c.roots().first else { throw TVError.badAnswer("\(c.hub.name) didn’t list any storage.") }
                for (i, url) in urls.enumerated() {
                    if urls.count > 1 { sendingFiles = "Sending \(i + 1) of \(urls.count)…" }
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Double.init) ?? 0
                    if let free = root.free, size > free { throw TVError.badAnswer("\(url.lastPathComponent) is \(formatBytes(size)); there’s \(formatBytes(free)) free.") }
                    _ = try await c.upload(file: url, to: root.path, name: url.lastPathComponent)
                }
                fleet.say("Sent to \(c.hub.name)", urls.count == 1 ? "\(urls[0].lastPathComponent) is in \(root.name)." : "\(urls.count) files are in \(root.name).")
            } catch { fleet.show(error) }
        }
    }
    #endif

    private var phoneBody: some View {
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
        .familyFormStyle()
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
        guard hasRecipient else { fleet.alert("Who Gets It?", "Pick at least one TV or phone under To."); return }
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
                    fleet.alert("Not Delivered Yet", "No TV or phone was reached just now. Turn on “Keep on Every TV’s Home” to leave it for when they’re on.")
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
        .familyFormStyle()
        .navigationTitle("Send To")
        .inlineTitle()
    }
}

/// Opens a YouTube, Apple Music or video link on the remote's TV.
struct OpenLinkView: View {
    @Environment(Fleet.self) private var fleet
    @Environment(\.dismiss) private var dismiss
    #if os(macOS)
    @Environment(\.macPanePush) private var panePush
    #endif
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

    /// The address typed reads as one (a host after the scheme, no spaces).
    private var valid: Bool {
        guard !address.isEmpty, !address.contains(where: \.isWhitespace), let u = URL(string: address) else { return false }
        return u.scheme?.lowercased().hasPrefix("http") == false || u.host?.isEmpty == false
    }

    var body: some View {
        Form {
            Section {
                TextField("https://", text: $link)
                    .focused($focused)
                    .autocorrectionDisabled()
                    #if os(iOS) || os(tvOS)
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
        .familyFormStyle()
        .navigationTitle("Open a Link")
        .inlineTitle()
        #if os(iOS) || os(tvOS)
        .toolbar { ToolbarItem(placement: .primaryAction) { openButton } }
        #else
        .macPageBar { openButton }
        #endif
        .onAppear { focused = true }
    }

    private var openButton: some View {
        Button { open() } label: { if opening { ProgressView() } else { Text("Open") } }
            .buttonStyle(.glassProminent)
            .disabled(!valid || opening)
    }

    private func open() {
        let url = address
        guard !url.isEmpty, !opening else { return }
        guard valid else { fleet.alert("Not a Link", "Type or paste the whole address, like youtube.com/watch?v=…"); return }
        guard let c = target else { fleet.show(TVError.notPaired); return }
        opening = true
        Task {
            do {
                try await c.open(url)
                fleet.say("Opening", "It’s opening on \(c.hub.name).")
                #if os(macOS)
                // In Mac Settings' right-hand side this page is the window's own root: `dismiss` there closed the
                // whole window. It goes back to Send instead.
                if let panePush { panePush.pop() } else { dismiss() }
                #else
                dismiss()
                #endif
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
    #if os(macOS)
    /// The file or folder picked on the Mac, as in Finder (a click, or the arrow keys): a double-click, Return and
    /// Space act on it.
    @State private var selection: FileEntry.ID?
    /// Goes up each time the one picked moves other than by a click (the arrow keys among the icons, the way back up
    /// out of a folder): it's then scrolled into view. A click never scrolls anything.
    @State private var reveal = 0
    /// Files are being dragged over the page: the files show they're where it would go.
    @State private var dropTargeted = false
    /// How many icons fit across (the up and down arrows move the one picked a row), and how tall the icons' part of
    /// the page is (a click anywhere in it that isn't on an icon picks nothing).
    @State private var iconsAcross = 1
    @State private var iconsHeight: CGFloat = 0
    /// The icon clicked last, and when: a second click on it soon after is a double-click.
    @State private var lastClick: (id: FileEntry.ID, at: Date)?
    /// The list is wide enough for the dates beside the names.
    @State private var showsDates = true
    /// The files have the keyboard (the arrow keys move the one picked).
    @FocusState private var filesFocused: Bool
    #endif
    /// What's shown, worked out again only when the folder, the search or a view option changes (not at every redraw:
    /// sorting a big folder by name the way Files does is slow).
    @State private var shown: [FileEntry] = []
    /// Why the TV's storage couldn't be opened (with Try Again, instead of placeholders forever).
    @State private var failed: String?
    /// Waiting for "Delete" to be confirmed: nothing on the TV goes without asking (there's no bin to get it back).
    @State private var deleting: FileEntry?
    /// Each folder opened gets a number: an answer for one opened before the last is dropped (tapping through
    /// folders quickly never lands back in an earlier one).
    @State private var opening = 0

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
            Button("Upload…") { importing = true }
            Button("New Folder…") { askFolder = true }
        } label: { Image(systemName: "plus") }
        .disabled(listing == nil || progress != nil)
        .accessibilityLabel("Add")
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
                #if os(macOS)
                macFiles(client)
                #else
                gridView(client)
                #endif
            } else {
                #if os(macOS)
                macFiles(client)
                #else
                listView(client)
                #endif
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
        // Inside a folder, Back goes up one folder (below). The system's Back, and its edge swipe, left Files from
        // any depth.
        .navigationBarBackButtonHidden(upButton != nil)
        #endif
        #if os(iOS) || os(tvOS)
        .toolbar {
            #if os(iOS)
            if let up = upButton {
                ToolbarItem(placement: .topBarLeading) {
                    Button { open(up.0) } label: { Image(systemName: "chevron.backward") }
                        .accessibilityLabel("Back")
                }
            }
            #endif
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
                guard !name.contains("/"), name != ".", name != ".." else {
                    fleet.alert("Can’t Use That Name", "A folder’s name can’t have “/” in it.")
                    return
                }
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
        #if canImport(QuickLook)
        .quickLookPreview($previewing)
        #endif
        #if os(macOS)
        // Files dragged in go into the folder shown; while they're over the page, the files show they're the place.
        .dropDestination(for: URL.self) { urls, _ in
            upload(urls)
            return true
        } isTargeted: { dropTargeted = $0 }
        // Space is Quick Look for the file picked, as in Finder. Asked for through the app's own Space handler, which
        // has every Space before any page does (for the TV's play and pause): a key press here never arrived.
        .onAppear { SpaceKey.page = { spaceKey() } }
        .onDisappear { SpaceKey.page = nil }
        // Another folder: nothing is picked, except on the way back up, where the folder you came out of is (as in
        // Finder).
        .onChange(of: listing?.path) { old, _ in
            selection = old.flatMap { was in shown.first { $0.dir && (was == $0.path || was.hasPrefix($0.path + "/")) } }?.id
            if selection != nil { reveal += 1 }
        }
        #elseif !os(tvOS)
        .dropDestination(for: URL.self) { urls, _ in upload(urls); return true }
        #endif
        .onChange(of: filter) { _, _ in refreshShown() }
        .onChange(of: show) { _, _ in refreshShown() }
        .onChange(of: sort) { _, _ in refreshShown() }
        .onChange(of: showHidden) { _, _ in refreshShown() }
        #if os(iOS) || os(tvOS)
        .sheet(item: Binding(get: { saving.map { ShareItem(url: $0) } }, set: { saving = $0?.url })) { ShareSheet(items: [$0.url]) }
        #endif
    }

    /// Quick Look: downloads the file and previews it (Space on the Mac with a file picked, or Quick Look in its menu).
    private func quickLook(_ f: FileEntry) {
        guard let c = client else { fleet.show(TVError.notPaired); return }
        guard progress == nil else { return }
        progress = "Opening \(f.name)…"
        Task {
            defer { progress = nil }
            do {
                previewing = try await LocalCopy.fetch(c.downloadURL(f.path), name: f.name, from: c.hub.name)
            } catch { fleet.show(error) }
        }
    }

    /// View, sort, filter, hidden files and the storage, in one menu (as the Files app does it).
    private var optionsMenu: some View {
        Menu {
            Picker("View", selection: $layout) {
                Text("Icons").tag(Layout.grid)
                Text("List").tag(Layout.list)
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
        .accessibilityLabel("View Options")
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
        .swipeActions { Button("Delete", role: .destructive) { deleting = f } }
    }

    @ViewBuilder private func menu(_ f: FileEntry) -> some View {
        if f.dir {
            Button("Use for Slideshow") { withTV { c in try await c.slideshow(folder: f.path, start: false); fleet.say("Slideshow", "The slideshow on \(c.hub.name) shows \(f.name) now.") } }
        }
        if f.isMedia {
            Button { playOnTV(f) } label: { Text("Play on TV") }
        }
        if f.isImage {
            Button("Set as TV Background") { withTV { c in try await c.background(f.path); fleet.say("Background Set", "\(f.name) is \(c.hub.name)’s background.") } }
        }
        if !f.dir {
            Button("Quick Look") { quickLook(f) }.disabled(progress != nil)
            Button("Save to This Device") { save(f) }.disabled(progress != nil)
        }
        Divider()
        Button("Delete", role: .destructive) { deleting = f }
    }

    /// A photo, a video or music plays on the TV (its menu's Play on TV, and a double-click on the Mac).
    private func playOnTV(_ f: FileEntry) {
        withTV { c in
            let r = try await c.play(path: f.path)
            if r.started?.bool == false { fleet.alert("Ready on \(c.hub.name)", r.message ?? "Open Woodruff on \(c.hub.name) to start it.") }
            else if let m = r.message { fleet.say("Playing on \(c.hub.name)", m) }
        }
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
        opening += 1
        let mine = opening
        Task {
            do {
                let l = try await c.list(p)
                guard mine == opening else { return }
                path = p
                let list = filtered(l)
                withAnimation(.snappy) {
                    listing = l
                    shown = list
                }
                failed = nil
            } catch {
                guard mine == opening else { return }
                if listing == nil { failed = error.localizedDescription } else { fleet.show(error) }
            }
        }
    }

    private func reload() { if let path { open(path) } }

    /// The search or a view option changed: what's shown is worked out again.
    private func refreshShown() { shown = filtered(listing) }

    private func upload(_ urls: [URL]) {
        guard let dir = listing?.path, let c = client else { return }
        guard progress == nil else { fleet.alert("One Moment", "Wait for the file being sent to finish, then try again."); return }
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
        guard let c = client else { fleet.show(TVError.notPaired); return }
        guard progress == nil else { return }
        progress = "Downloading \(f.name)…"
        Task {
            defer { progress = nil }
            do {
                let dest = try await LocalCopy.fetch(c.downloadURL(f.path), name: f.name, from: c.hub.name)
                #if os(macOS)
                let kept = try LocalCopy.toDownloads(dest)
                NSWorkspace.shared.activateFileViewerSelecting([kept])
                #else
                saving = dest
                #endif
            } catch { fleet.show(error) }
        }
    }

    #if os(macOS)
    // MARK: The Mac, as Finder does it

    /// A folder on the way down to the one shown.
    private struct Crumb {
        var name: String
        var path: String
    }

    /// The file or folder picked, while it's among those shown.
    private var picked: FileEntry? {
        guard let id = selection else { return nil }
        return shown.first { $0.id == id }
    }

    /// The one a right-click or a double-click in the list is on.
    private func entry(_ ids: Set<FileEntry.ID>) -> FileEntry? {
        guard let id = ids.first else { return nil }
        return shown.first { $0.id == id }
    }

    /// A double-click, or Return: a folder opens; a photo, a video or music plays on the TV; any other file shows in
    /// Quick Look (what was first in each one's menu).
    private func openItem(_ f: FileEntry) {
        if f.dir { open(f.path) } else if f.isMedia { playOnTV(f) } else { quickLook(f) }
    }

    /// Return (⌘↓ too, among the icons): opens the one picked.
    private func openPicked() -> KeyPress.Result {
        guard let f = picked else { return .ignored }
        openItem(f)
        return .handled
    }

    /// Space: Quick Look for the file picked, or the one showing put away again, as in Finder. False with no file
    /// picked: the press is then the TV's play and pause, as on every other page.
    private func spaceKey() -> Bool {
        if previewing != nil {
            previewing = nil
            return true
        }
        guard let f = picked, !f.dir else { return false }
        quickLook(f)
        return true
    }

    /// The Mac's files, laid out as a Finder window: where you are across the top (a folder above is a click away),
    /// the files as a list or as icons with one picked at a time, and how many there are along the bottom.
    private func macFiles(_ client: TVClient?) -> some View {
        VStack(spacing: 0) {
            macPath
            ScrollViewReader { proxy in
                Group {
                    if layout == .grid { macIcons(client) } else { macList(client) }
                }
                // The one picked comes into view when the arrow keys among the icons move it, and on the way back up
                // out of a folder. (In the list, the system does it for its own arrow keys.)
                .onChange(of: reveal) { _, _ in
                    if let id = selection { proxy.scrollTo(id) }
                }
            }
            .overlay {
                // Files dragged over the page: a ring around where they'd go, as a Finder window shows it.
                if dropTargeted {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 3)
                        .allowsHitTesting(false)
                }
            }
            macStatus
        }
    }

    /// The folders from the storage's own down to the one shown, each with where it is.
    private var crumbs: [Crumb] {
        guard let l = listing else { return [] }
        let top = root?.path ?? l.path
        var out = [Crumb(name: root?.name ?? "Photos & Files", path: top)]
        guard l.path != top else { return out }
        let rest = l.path.dropFirst(top.count)
        if l.path.hasPrefix(top), top.hasSuffix("/") || rest.hasPrefix("/") {
            var at = top.hasSuffix("/") ? String(top.dropLast()) : top
            for part in rest.split(separator: "/") {
                at += "/\(part)"
                out.append(Crumb(name: String(part), path: at))
            }
            // The folder just above is where the TV says it is.
            if out.count > 1, let parent = l.parent { out[out.count - 2].path = parent }
        } else {
            // Not under the storage as it's named (the TV gave the folder another way): the folder above, and this one.
            if let parent = l.parent, parent != top { out.append(Crumb(name: (parent as NSString).lastPathComponent, path: parent)) }
            out.append(Crumb(name: (l.path as NSString).lastPathComponent, path: l.path))
        }
        return out
    }

    /// Where you are, from the storage down, as Finder's path bar has it: a folder above is a click away.
    private var macPath: some View {
        let crumbs = self.crumbs
        return HStack(spacing: 6) {
            ForEach(Array(crumbs.enumerated()), id: \.offset) { i, crumb in
                if i > 0 {
                    Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                if i == crumbs.count - 1 {
                    Text(crumb.name).fontWeight(.semibold).lineLimit(1).truncationMode(.middle).layoutPriority(1)
                } else {
                    macCrumb(crumb, above: i == crumbs.count - 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.top, 2).padding(.bottom, 6)
    }

    /// A folder above, in the path: a click goes there. The one just above has Finder's ⌘↑ too.
    @ViewBuilder private func macCrumb(_ crumb: Crumb, above: Bool) -> some View {
        let button = Button(crumb.name) { open(crumb.path) }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        if above {
            button.keyboardShortcut(.upArrow, modifiers: .command).help("Enclosing Folder (⌘↑)")
        } else {
            button
        }
    }

    /// Along the bottom, as Finder's status bar: what's being sent or fetched, else how many items and how much room.
    private var macStatus: some View {
        HStack(spacing: 8) {
            if let progress {
                ProgressView().controlSize(.small)
                Text(progress).lineLimit(1).truncationMode(.middle)
            } else {
                Text(footer)
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16).padding(.vertical, 7)
    }

    /// What a right-click on empty space has: the same as Add.
    @ViewBuilder private var macAddItems: some View {
        Button("Upload…") { importing = true }.disabled(progress != nil)
        Button("New Folder…") { askFolder = true }.disabled(progress != nil)
    }

    /// The list: a click picks a row (the arrow keys move it), a double-click opens it, a right-click has its commands.
    private func macList(_ client: TVClient?) -> some View {
        List(selection: $selection) {
            ForEach(shown) { f in macRow(f, client) }
        }
        .listStyle(.inset)
        .contextMenu(forSelectionType: FileEntry.ID.self) { ids in
            if let f = entry(ids) { menu(f) } else if ids.isEmpty { macAddItems }
        } primaryAction: { ids in
            if let f = entry(ids) { openItem(f) }
        }
        // No ring round the whole list when it has the keyboard (Finder has none): the row picked shows it.
        .focusEffectDisabled()
        .focused($filesFocused)
        .onAppear { filesFocused = true }
        // Return opens the one picked, as a double-click does (once, however long it's held). Space is the app's own
        // handler's; it's here too for a press that does reach the list.
        .onKeyPress(.return, phases: .down) { _ in openPicked() }
        .onKeyPress(.space, phases: .down) { _ in spaceKey() ? .handled : .ignored }
        .onGeometryChange(for: Bool.self) { $0.size.width >= 440 } action: { showsDates = $0 }
    }

    /// A row as Finder's list has one: the icon and the name, then when it was changed and how big it is.
    private func macRow(_ f: FileEntry, _ client: TVClient?) -> some View {
        HStack(spacing: 10) {
            FileGlyph(kind: kindOf(f, client), size: 30).frame(width: 32, height: 30)
            Text(f.name).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 12)
            Group {
                if showsDates { Text(shortDate(f) ?? "").frame(width: 84, alignment: .trailing) }
                Text(f.dir ? "--" : formatBytes(f.size)).frame(width: 78, alignment: .trailing)
            }
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    /// The icons: a click picks one (the arrow keys move it), a double-click opens it, a right-click has its commands.
    /// There's no system grid that keeps a selection, so this is laid out as Apple's own sample of one is: the grid
    /// takes the keyboard (with no ring round it), and its keys move what's picked.
    private func macIcons(_ client: TVClient?) -> some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 108, maximum: 150), spacing: 10, alignment: .top)], spacing: 28) {
                ForEach(shown) { f in macTile(f, client).id(f.id) }
            }
            // How many fit across, as the grid works it out, for the up and down arrows.
            .onGeometryChange(for: Int.self) { max(1, Int(($0.size.width + 10) / 118)) } action: { iconsAcross = $0 }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: iconsHeight, alignment: .top)
            // A click that isn't on an icon picks nothing; a right-click there has what Add has.
            .background {
                Color.clear.contentShape(Rectangle())
                    .onTapGesture {
                        selection = nil
                        filesFocused = true
                    }
                    .contextMenu { macAddItems }
                    .accessibilityHidden(true)
            }
            .focusable()
            .focusEffectDisabled()
            .focused($filesFocused)
            .onAppear { filesFocused = true }
            .onKeyPress { press in macIconsKey(press) }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { iconsHeight = $0 }
    }

    /// An icon as Finder shows one picked: a plate behind the picture, the name on the selection colour.
    private func macTile(_ f: FileEntry, _ client: TVClient?) -> some View {
        let on = selection == f.id
        let lines = [shortDate(f), f.dir ? nil : formatBytes(f.size)].compactMap { $0 }
        return VStack(spacing: 3) {
            FileGlyph(kind: kindOf(f, client), size: 92)
                .frame(width: 96, height: 96, alignment: .bottom)
                .padding(4)
                .background { if on { RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.quaternary) } }
            Text(f.name)
                .font(.callout)
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 5).padding(.vertical, 1)
                // The system's own selection style: the highlight colour while the icons have the keyboard in the
                // front window and grey otherwise, and the name on it takes the colour that goes with each.
                .background(on ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            ForEach(lines, id: \.self) { Text($0).font(.footnote).foregroundStyle(.secondary).lineLimit(1) }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .contentShape(Rectangle())
        .onTapGesture { clicked(f) }
        .contextMenu { menu(f) }
        // VoiceOver: one item with its name, date and size, that opens as a double-click does.
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { openItem(f) }
    }

    /// A click on an icon picks it at once (nothing waits to see whether a second is coming); a second click on it
    /// within the system's double-click time opens it.
    private func clicked(_ f: FileEntry) {
        let now = Date()
        if let last = lastClick, last.id == f.id, now.timeIntervalSince(last.at) <= NSEvent.doubleClickInterval {
            lastClick = nil
            openItem(f)
        } else {
            lastClick = (f.id, now)
            selection = f.id
            filesFocused = true
        }
    }

    /// The keyboard among the icons: the arrows move the one picked (up and down by a row); Return, or ⌘↓ as in
    /// Finder, opens it.
    private func macIconsKey(_ press: KeyPress) -> KeyPress.Result {
        let command = press.modifiers.contains(.command)
        // A key held down keeps moving the one picked, but opens it only once.
        let held = press.phase == .repeat
        switch press.key {
        case .leftArrow: movePick(by: -1)
        case .rightArrow: movePick(by: 1)
        case .upArrow:
            // ⌘↑ is the folder above: the path has it.
            if command { return .ignored }
            movePick(by: -iconsAcross)
        case .downArrow:
            if command { return held ? .handled : openPicked() }
            movePick(by: iconsAcross)
        case .return: return held ? .handled : openPicked()
        // (The app's own Space handler has it first; here for a press that does reach the icons.)
        case .space: return held || spaceKey() ? .handled : .ignored
        default: return .ignored
        }
        return .handled
    }

    /// The one picked moves by [step] icons (to the first when there's none yet). Down from above a short last row
    /// lands on its last icon.
    private func movePick(by step: Int) {
        var j = 0
        if let i = shown.firstIndex(where: { $0.id == selection }) {
            j = i + step
            if step > 1, j >= shown.count, i / step < (shown.count - 1) / step { j = shown.count - 1 }
        }
        guard shown.indices.contains(j) else { return }
        selection = shown[j].id
        reveal += 1
    }
    #endif
}

/// A file from a TV kept on this device: downloaded under a name that's safe here, never over a file already there.
enum LocalCopy {
    /// [name] as the TV gave it, made safe as one file's name here (no folders, never empty).
    static func safeName(_ name: String) -> String {
        let s = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty || s == "." || s == ".." ? "File" : s
    }

    /// Downloads [url] to a temporary file called [name]; a refused answer is said, not kept as the file.
    static func fetch(_ url: URL, name: String, from tv: String) async throws -> URL {
        let (tmp, resp) = try await URLSession.woodruff.download(from: url)
        if let code = (resp as? HTTPURLResponse)?.statusCode, !(200..<300).contains(code) {
            try? FileManager.default.removeItem(at: tmp)
            throw TVError.badAnswer(code == 404 ? "\(tv) doesn’t have that file any more." : "\(tv) couldn’t send it (\(code)).")
        }
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(safeName(name))
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }

    #if os(macOS)
    /// Moved into Downloads, as "name 2.jpg" when "name.jpg" is there already.
    static func toDownloads(_ file: URL) throws -> URL {
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let stem = file.deletingPathExtension().lastPathComponent, ext = file.pathExtension
        var dest = dir.appendingPathComponent(file.lastPathComponent)
        var n = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = dir.appendingPathComponent(ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)")
            n += 1
        }
        try FileManager.default.moveItem(at: file, to: dest)
        return dest
    }
    #endif
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


#if os(macOS)
/// One of Send's other things to send: a glass card with its picture, name and what it does.
private struct SendCard: View {
    var symbol: String
    var tint: Color
    var title: String
    var detail: String
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .glass(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .scaleEffect(hover ? 1.02 : 1)
        .animation(.smooth(duration: 0.2), value: hover)
        .onHover { hover = $0 }
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}
#endif
