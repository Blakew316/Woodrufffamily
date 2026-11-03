import SwiftUI
import UniformTypeIdentifiers
import WoodruffKit

/// Send: a message to TVs and phones (or pinned on every TV's Home), the TV's photos and files, a link, the slideshow.
struct SendView: View {
    @Environment(Fleet.self) private var fleet
    @State private var message = ""
    @State private var toTV = true
    @State private var pickedTVs: Set<String> = []
    @State private var everyTV = true
    @State private var phones: [Phone] = []
    @State private var pickedPhones: Set<String> = []
    @State private var pin = false
    @State private var link = ""
    @State private var sending = false

    var body: some View {
        Form {
            Section {
                TextField("Message", text: $message, axis: .vertical).lineLimit(3...8)
                Button {
                    send()
                } label: {
                    if sending { ProgressView() } else { Label("Send", systemImage: "paperplane.fill") }
                }
                .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending)
            } header: { Text("Announcement") }

            Section("To") {
                Toggle("TV screens", isOn: $toTV)
                if toTV {
                    Toggle("Every TV", isOn: $everyTV)
                    if !everyTV {
                        ForEach(fleet.tvs) { tv in
                            Toggle(isOn: Binding(get: { pickedTVs.contains(tv.id) }, set: { on in if on { pickedTVs.insert(tv.id) } else { pickedTVs.remove(tv.id) } })) {
                                HStack { StatusDot(color: tv.online ? .green : .gray); Text(tv.name) }
                            }
                        }
                    }
                }
                ForEach(phones) { p in
                    Toggle(isOn: Binding(get: { pickedPhones.contains(p.id) }, set: { on in if on { pickedPhones.insert(p.id) } else { pickedPhones.remove(p.id) } })) {
                        VStack(alignment: .leading) {
                            Text(p.id == fleet.phone.id ? "\(p.name) (this device)" : p.name)
                            Text(p.alerts == true ? "Lock screen" : "When Woodruff is open").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Toggle("Keep on Every TV's Home", isOn: $pin)
            }

            Section("On the TV") {
                NavigationLink { FilesView() } label: { Label("Photos & Files", systemImage: "folder") }
                HStack {
                    TextField("Open a link (YouTube, Apple Music, a video…)", text: $link)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never).keyboardType(.URL)
                        #endif
                    ActionButton(action: {
                        try await fleet.selectedClient?.open(link.trimmingCharacters(in: .whitespaces))
                        fleet.say("Opened", "It's opening on \(fleet.selected?.name ?? "the TV").")
                        link = ""
                    }) { Text("Open") }
                    .disabled(link.isEmpty)
                }
                ActionButton(action: { try await fleet.hubClient()?.slideshow(start: true) }) {
                    Label("Start Photo Slideshow", systemImage: "play.rectangle.on.rectangle")
                }
            }
        }
        .formStyle(.grouped)
        .screenTitle("Send")
        .task { await loadPhones() }
    }

    private func loadPhones() async {
        guard let c = fleet.hubClient() else { return }
        if let p = try? await c.phones() {
            phones = p
            if pickedPhones.isEmpty { pickedPhones = Set(p.filter { $0.id != fleet.phone.id }.map(\.id)) }
        }
    }

    /// The page's rule: a short first line is the title, the rest the body; otherwise "From <name>".
    private func split(_ text: String) -> (String, String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = t.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        if let first = lines.first, first.count <= 80 {
            return (first, lines.count > 1 ? lines[1].trimmingCharacters(in: .whitespacesAndNewlines) : "")
        }
        return ("From \(fleet.phone.name)", t)
    }

    private func send() {
        guard let c = fleet.hubClient() else { return }
        let (title, body) = split(message)
        sending = true
        Task {
            do {
                let tvList: [String]? = toTV && !everyTV ? pickedTVs.compactMap { id in fleet.tv(id).map { $0.isHub && $0.hubID == c.hub.id ? "this" : $0.id } } : nil
                let r = try await c.announce(title: title, body: body, tv: toTV, tvs: tvList, phones: Array(pickedPhones), allPhones: false, from: fleet.phone.name, pin: pin)
                message = ""
                var words: [String] = []
                if let n = r.tvs, n > 0 { words.append(n == 1 ? "the TV" : "\(n) TVs") }
                if let n = r.phones, n > 0 { words.append(n == 1 ? "1 phone" : "\(n) phones") }
                fleet.say(pin ? "Pinned on every TV" : "Sent", words.isEmpty ? "Sent." : "Sent to " + words.joined(separator: " and ") + ".")
            } catch { fleet.show(error) }
            sending = false
        }
    }
}

/// The TV's storage: browse, play, set as background, use for the slideshow, save, upload, new folder, delete.
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

    var body: some View {
        List {
            if !roots.isEmpty {
                Section {
                    Picker("Storage", selection: Binding(get: { roots.first { path?.hasPrefix($0.path) == true }?.path ?? roots.first?.path ?? "" },
                                                          set: { open($0) })) {
                        ForEach(roots) { r in Text(r.name + (r.free.map { " · \(formatBytes($0)) free" } ?? "")).tag(r.path) }
                    }
                }
            }
            if let progress { Section { HStack { ProgressView(); Text(progress) } } }
            if let l = listing {
                Section(l.path) {
                    if let parent = l.parent { Button { open(parent) } label: { Label("Up", systemImage: "arrow.turn.left.up") } }
                    ForEach(l.files.filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) }) { f in
                        row(f)
                    }
                }
            } else {
                ProgressView()
            }
        }
        .searchable(text: $filter)
        .navigationTitle("Photos & Files")
        .toolbar {
            ToolbarItem {
                Menu {
                    Button { importing = true } label: { Label("Upload", systemImage: "square.and.arrow.up") }
                    Button { askFolder = true } label: { Label("New Folder", systemImage: "folder.badge.plus") }
                } label: { Label("Add", systemImage: "plus") }
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
                Task { do { try await client?.mkdir(in: listing?.path ?? "", name: name); reload() } catch { fleet.show(error) } }
            }
            Button("Cancel", role: .cancel) {}
        }
        .task { await loadRoots() }
        #if os(iOS)
        .sheet(item: Binding(get: { saving.map { ShareItem(url: $0) } }, set: { saving = $0?.url })) { item in ShareSheet(items: [item.url]) }
        #endif
    }

    private var client: TVClient? { fleet.hubClient() }

    @ViewBuilder private func row(_ f: FileEntry) -> some View {
        let label = HStack {
            Image(systemName: f.dir ? "folder.fill" : f.isImage ? "photo" : f.isVideo ? "film" : f.isAudio ? "music.note" : "doc")
                .foregroundStyle(f.dir ? Color.accentColor : .secondary).frame(width: 26)
            VStack(alignment: .leading) {
                Text(f.name).lineLimit(1)
                if !f.dir { Text(formatBytes(f.size)).font(.caption).foregroundStyle(.secondary) }
            }
        }
        Group {
            if f.dir { Button { open(f.path) } label: { label }.buttonStyle(.plain) }
            else { label }
        }
        .contextMenu { menu(f) }
        .swipeActions { Button(role: .destructive) { delete(f) } label: { Label("Delete", systemImage: "trash") } }
    }

    @ViewBuilder private func menu(_ f: FileEntry) -> some View {
        if f.dir {
            Button { act { try await client?.slideshow(folder: f.path, start: false); fleet.say("Slideshow", "The slideshow uses \(f.name) now.") } } label: { Label("Use for Slideshow", systemImage: "play.rectangle") }
        }
        if f.isMedia {
            Button { act { let r = try await client?.play(path: f.path); if let m = r?.message { fleet.say("Ready on the TV", m) } } } label: { Label("Play on TV", systemImage: "play.tv") }
        }
        if f.isImage {
            Button { act { try await client?.background(f.path); fleet.say("Background set", "\(f.name) is the TV's background.") } } label: { Label("Set as TV Background", systemImage: "photo.on.rectangle") }
        }
        if !f.dir {
            Button { save(f) } label: { Label("Save to This Device", systemImage: "square.and.arrow.down") }
        }
        Button(role: .destructive) { delete(f) } label: { Label("Delete", systemImage: "trash") }
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
            do { listing = try await client?.list(p) } catch { fleet.show(error) }
        }
    }

    private func reload() { if let path { open(path) } }

    private func delete(_ f: FileEntry) {
        act { try await client?.delete(f.path); reload() }
    }

    private func upload(_ urls: [URL]) {
        guard let dir = listing?.path, let c = client else { return }
        Task {
            for (i, url) in urls.enumerated() {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                progress = "Uploading \(i + 1) of \(urls.count): \(url.lastPathComponent)"
                do {
                    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Double.init) ?? 0
                    if let free = listing?.free, size > free { throw TVError.badAnswer("\(url.lastPathComponent) is \(formatBytes(size)); there's \(formatBytes(free)) free.") }
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

struct ShareItem: Identifiable { var url: URL; var id: URL { url } }

#if os(iOS)
struct ShareSheet: UIViewControllerRepresentable {
    var items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ c: UIActivityViewController, context: Context) {}
}
#endif
