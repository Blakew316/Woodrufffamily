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

    var body: some View {
        Form {
            if let error {
                Section { Text(error).foregroundStyle(Palette.attention) }
            }
            let pinned = notes.filter(\.isPinned)
            let rest = notes.filter { !$0.isPinned }
            if !pinned.isEmpty {
                Section("Pinned") { ForEach(pinned) { row($0) } }
            }
            Section {
                ForEach(rest) { row($0) }
                Button("New Note") { editing = TVNote(id: "", title: "", body: "", updated: 0, pinned: false) }
            } header: {
                if !pinned.isEmpty { Text("Notes") }
            } footer: {
                if loaded && notes.isEmpty { Text("Notes you write here show on the TVs, in Command Center → Notes.") }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Notes")
        .inlineTitle()
        .task { await load() }
        .refreshable { await load() }
        .sheet(item: $editing) { n in
            NavigationStack {
                NoteEditor(note: n) { title, body in
                    await save(n, title: title, body: body, pinned: n.id.isEmpty ? false : nil)
                }
            }
            #if os(macOS)
            .frame(minWidth: 460, minHeight: 420)
            #endif
        }
    }

    private func row(_ n: TVNote) -> some View {
        Button { editing = n } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(n.title.isEmpty ? "Untitled" : n.title).font(.body.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
                if !n.body.isEmpty {
                    Text(n.body).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
                Text(n.updatedAt, format: .relative(presentation: .named)).font(.caption).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(n.isPinned ? "Unpin" : "Pin") { Task { await save(n, title: n.title, body: n.body, pinned: !n.isPinned) } }
            Button("Delete", role: .destructive) { Task { await delete(n) } }
        }
        .swipeActions {
            Button("Delete", role: .destructive) { Task { await delete(n) } }
            Button(n.isPinned ? "Unpin" : "Pin") { Task { await save(n, title: n.title, body: n.body, pinned: !n.isPinned) } }
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

    private func save(_ n: TVNote, title: String, body: String, pinned: Bool?) async {
        guard let c = fleet.hubClient() else { error = "No TV is reachable right now."; return }
        do {
            try await c.saveNote(id: n.id.isEmpty ? nil : n.id, title: title, body: body, pinned: pinned)
            await load()
        } catch { self.error = "Couldn’t save the note: \(error.localizedDescription)" }
    }

    private func delete(_ n: TVNote) async {
        guard let c = fleet.hubClient() else { return }
        withAnimation(.smooth(duration: 0.25)) { notes.removeAll { $0.id == n.id } }
        do { try await c.deleteNote(n.id) } catch { self.error = "Couldn’t delete the note: \(error.localizedDescription)"; await load() }
    }

    /// Newest first.
    static func sorted(_ list: [TVNote]) -> [TVNote] { list.sorted { $0.updated > $1.updated } }
}

/// One note's title and text. Saved with Done.
struct NoteEditor: View {
    let note: TVNote
    let onSave: (String, String) async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var text = ""
    @State private var saving = false

    var body: some View {
        Form {
            Section { TextField("Title", text: $title) }
            Section {
                TextEditor(text: $text).frame(minHeight: 180)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(note.id.isEmpty ? "New Note" : "Note")
        .inlineTitle()
        .onAppear { title = note.title; text = note.body }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    saving = true
                    Task {
                        await onSave(title.trimmingCharacters(in: .whitespacesAndNewlines), text)
                        dismiss()
                    }
                }
                .disabled(saving || (title.trimmingCharacters(in: .whitespaces).isEmpty && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }
        }
    }
}
