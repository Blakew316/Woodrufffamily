import SwiftUI
import WoodruffKit

/// Settings → Notes: the notes kept on the TVs (the same ones as Command Center → Notes on a TV), to read, write, pin
/// and delete from here.
struct NotesView: View {
    @Environment(Fleet.self) private var fleet
    @State private var notes: [TVNote] = []
    @State private var loaded = false
    @State private var error: String?
    @State private var editing: TVNote?

    private var pinned: [TVNote] { notes.filter(\.isPinned) }
    private var rest: [TVNote] { notes.filter { !$0.isPinned } }

    var body: some View {
        Form {
            if let error {
                Section { Text(error).foregroundStyle(Palette.attention) }
            } else if !loaded {
                Section { HStack { Spacer(); ProgressView(); Spacer() } }
            }
            if !pinned.isEmpty {
                Section {
                    ForEach(pinned) { n in row(n) }
                } header: { Text("Pinned") }
            }
            notesSection
        }
        .familyFormStyle()
        .navigationTitle("Notes")
        .inlineTitle()
        .task { await load() }
        .refreshable { await load() }
        .sheet(item: $editing) { n in editor(n) }
    }

    private var notesSection: some View {
        Section {
            ForEach(rest) { n in row(n) }
            Button("New Note") { editing = TVNote(id: "", title: "", body: "", updated: 0, pinned: false) }
        } header: {
            Text(pinned.isEmpty ? "" : "Notes")
        } footer: {
            Text(loaded && notes.isEmpty ? "Notes you write here show on the TVs, in Command Center → Notes." : "")
        }
    }

    private func editor(_ n: TVNote) -> some View {
        NavigationStack {
            NoteEditor(note: n) { title, body in
                await save(n, title: title, body: body, pinned: n.id.isEmpty ? false : nil, quiet: true)
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 420)
        #endif
    }

    private func row(_ n: TVNote) -> some View {
        Button { editing = n } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(n.title.isEmpty ? "Untitled" : n.title).font(.body.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
                if !n.body.isEmpty {
                    Text(n.body).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
                Text(n.updatedAt, style: .relative).font(.caption).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(n.isPinned ? "Unpin" : "Pin") { Task { _ = await save(n, title: n.title, body: n.body, pinned: !n.isPinned) } }
            Button("Delete", role: .destructive) { Task { await delete(n) } }
        }
        .swipeActions {
            Button("Delete", role: .destructive) { Task { await delete(n) } }
            Button(n.isPinned ? "Unpin" : "Pin") { Task { _ = await save(n, title: n.title, body: n.body, pinned: !n.isPinned) } }
        }
    }

    private func load() async {
        guard let c = fleet.hubClient() else { error = "No TV is reachable right now."; return }
        do {
            let list = try await c.notes()
            withAnimation(.smooth(duration: 0.25)) { notes = Self.sorted(list) }
            error = nil
        } catch { self.error = "Couldn’t read the notes: \(error.localizedDescription)" }
        loaded = true
    }

    /// Saved on the TV, or why not ([quiet]: said by the editor that asked, not on this page).
    private func save(_ n: TVNote, title: String, body: String, pinned: Bool?, quiet: Bool = false) async -> String? {
        guard let c = fleet.hubClient() else {
            let why = "No TV is reachable right now."
            if !quiet { error = why }
            return why
        }
        do {
            try await c.saveNote(id: n.id.isEmpty ? nil : n.id, title: title, body: body, pinned: pinned)
            await load()
            return nil
        } catch {
            let why = "Couldn’t save the note: \(error.localizedDescription)"
            if !quiet { self.error = why }
            return why
        }
    }

    private func delete(_ n: TVNote) async {
        guard let c = fleet.hubClient() else { error = "No TV is reachable right now."; return }
        withAnimation(.smooth(duration: 0.25)) { notes.removeAll { $0.id == n.id } }
        do { try await c.deleteNote(n.id) } catch { self.error = "Couldn’t delete the note: \(error.localizedDescription)"; await load() }
    }

    /// Newest first.
    static func sorted(_ list: [TVNote]) -> [TVNote] { list.sorted { $0.updated > $1.updated } }
}

/// One note's title and text. Saved with Done.
struct NoteEditor: View {
    let note: TVNote
    /// Saves it: nil when the TV took it, else why not.
    let onSave: (String, String) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var text = ""
    @State private var saving = false
    @State private var failed: String?

    var body: some View {
        Form {
            Section { TextField("Title", text: $title) }
            Section {
                TextEditor(text: $text).frame(minHeight: 180)
            }
            if let failed {
                Section { Text(failed).foregroundStyle(Palette.attention) }
            }
        }
        .familyFormStyle()
        .navigationTitle(note.id.isEmpty ? "New Note" : "Note")
        .inlineTitle()
        .onAppear { title = note.title; text = note.body }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    saving = true
                    failed = nil
                    Task {
                        let why = await onSave(title.trimmingCharacters(in: .whitespacesAndNewlines), text)
                        saving = false
                        if let why { failed = why } else { dismiss() }
                    }
                }
                .disabled(saving || (title.trimmingCharacters(in: .whitespaces).isEmpty && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }
        }
    }
}
