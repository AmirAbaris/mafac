//
//  NotesListView.swift
//  Mafac
//
//  Phase 4: the sidebar list of notes in the chosen folder — the master
//  side of ContentView's NavigationSplitView. Click a row to select it
//  (ContentView reacts to the selection binding and loads the note into
//  NoteEditorView); the toolbar "+" / \u{2318}N creates a new note;
//  right-click or swipe a row for rename/delete.
//

import SwiftUI

struct NotesListView: View {
    @ObservedObject var notesStore: NotesStore
    @Binding var selection: URL?

    @State private var renamingNote: NoteMetadata?
    @State private var renameText: String = ""
    @State private var noteToDelete: NoteMetadata?

    var body: some View {
        Group {
            if notesStore.notes.isEmpty {
                emptyState
            } else {
                List(selection: $selection) {
                    ForEach(notesStore.notes) { note in
                        Text(note.title)
                            .lineLimit(1)
                            .tag(note.url)
                            .contextMenu {
                                Button("Rename\u{2026}") { beginRename(note) }
                                Button("Delete", role: .destructive) { noteToDelete = note }
                            }
                            .swipeActions {
                                Button("Delete", role: .destructive) { noteToDelete = note }
                                Button("Rename") { beginRename(note) }
                                    .tint(.blue)
                            }
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .frame(minWidth: 200)
        .toolbar {
            ToolbarItem {
                Button {
                    createNote()
                } label: {
                    Label("New Note", systemImage: "square.and.pencil")
                }
                .keyboardShortcut("n", modifiers: .command)
                .help("New Note (\u{2318}N)")
            }
        }
        .alert("Rename Note", isPresented: renameBinding) {
            TextField("Name", text: $renameText)
            Button("Rename") { commitRename() }
            Button("Cancel", role: .cancel) { renamingNote = nil }
        }
        .alert("Delete Note?", isPresented: deleteBinding) {
            Button("Delete", role: .destructive) { commitDelete() }
            Button("Cancel", role: .cancel) { noteToDelete = nil }
        } message: {
            Text("\u{201C}\(noteToDelete?.title ?? "")\u{201D} will be moved to the Trash.")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "note.text")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No notes yet")
                .foregroundStyle(.secondary)
            Button("New Note") { createNote() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var renameBinding: Binding<Bool> {
        Binding(get: { renamingNote != nil }, set: { if !$0 { renamingNote = nil } })
    }

    private var deleteBinding: Binding<Bool> {
        Binding(get: { noteToDelete != nil }, set: { if !$0 { noteToDelete = nil } })
    }

    private func createNote() {
        if let metadata = notesStore.createNote() {
            selection = metadata.url
        }
    }

    private func beginRename(_ note: NoteMetadata) {
        renameText = note.title
        renamingNote = note
    }

    private func commitRename() {
        guard let note = renamingNote else { return }
        if let renamed = notesStore.rename(note, to: renameText), selection == note.url {
            selection = renamed.url
        }
        renamingNote = nil
    }

    private func commitDelete() {
        guard let note = noteToDelete else { return }
        if selection == note.url { selection = nil }
        notesStore.delete(note)
        noteToDelete = nil
    }
}
