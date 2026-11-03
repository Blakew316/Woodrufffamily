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
        let phonesOn = to.knownPhones.filter { to.phones.contains($0.id) }.count
        if to.allTVs && (to.knownPhones.isEmpty || phonesOn == to.knownPhones.filter { $0.id != fleet.phone.id }.count) { return to.pin ? "Everyone · Pinned" : "Everyone" }
        var parts: [String] = []
        if to.allTVs { parts.append("All TVs") } else if !to.tvs.isEmpty { parts.append(to.tvs.count == 1 ? (fleet.tv(to.tvs.first!)?.name ?? "1 TV") : "\(to.tvs.count) TVs") }
        if phonesOn > 0 { parts.append(phonesOn == 1 ? "1 phone" : "\(phonesOn) phones") }
        return parts.isEmpty ? "No one" : parts.joined(separator: ", ")
    }

    private func loadPhones() async {
        guard !to.loadedPhones, let c = fleet.hubClient(), let p = try? await c.phones() else { return }
        to.knownPhones = p
        to.phones = Set(p.filter { $0.id != fleet.phone.id }.map(\.id))
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
                ForEach(to.knownPhones) { p in
                    Toggle(isOn: Binding(get: { to.phones.contains(p.id) }, set: { if $0 { to.phones.insert(p.id) } else { to.phones.remove(p.id) } })) {
                        IconRow(symbol: p.name.lowercased().contains("ipad") ? "ipad" : "iphone", color: p.alerts == true ? .green : .gray,
                                title: p.id == fleet.phone.id ? "\(p.name) (this device)" : p.name,
                                subtitle: p.alerts == true ? "Lock screen" : "When Woodruff is open")
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

    var body: some View {
        List {
            if let progress {
                Section { HStack(spacing: 12) { ProgressView(); Text(progress).font(.subheadline) } }
            }
            if let l = listing {
                Section {
                    if let parent = l.parent, l.path != root?.path {
                        Button { open(parent) } label: { IconRow(symbol: "arrow.turn.left.up", color: .gray, title: "Back to \((parent as NSString).lastPathComponent)") }
                            .buttonStyle(.plain)
                    }
                    ForEach(l.files.filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) }) { f in row(f) }
                }
            } else {
                HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { storagePicker }
        .searchable(text: $filter, prompt: "Search")
        .navigationTitle(listing.map { $0.path == root?.path ? "Photos & Files" : ($0.path as NSString).lastPathComponent } ?? "Photos & Files")
        .toolbar {
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

    @ViewBuilder private var storagePicker: some View {
        if roots.count > 0 {
            HStack {
                Menu {
                    ForEach(roots) { r in
                        Button { open(r.path) } label: { Text(r.name); if let f = r.free { Text("\(formatBytes(f)) free") } }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(root?.name ?? "Storage").font(.subheadline.weight(.semibold))
                        Image(systemName: "chevron.down").font(.caption.weight(.bold))
                    }
                    .foregroundStyle(Color.accentColor)
                }
                .menuStyle(.button).buttonStyle(.plain)
                Spacer()
                if let f = listing?.free ?? root?.free { Text("\(formatBytes(f)) free").font(.footnote).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 20).padding(.vertical, 6)
        }
    }

    @ViewBuilder private func row(_ f: FileEntry) -> some View {
        let label = IconRow(symbol: icon(f), color: color(f), title: f.name, subtitle: f.dir ? "Folder" : "\(kind(f)) · \(formatBytes(f.size))")
        Group {
            if f.dir { Button { open(f.path) } label: { HStack { label; Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary) } }.buttonStyle(.plain) }
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
