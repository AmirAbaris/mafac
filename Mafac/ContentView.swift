//
//  ContentView.swift
//  Mafac
//
//  Phase 1: one standalone math block, wired end-to-end — click in, type
//  shortcut keys per Resources/ShortcutTable.json (handled by
//  MathBlockView/MathBlockTextView), and watch it render live via
//  MathRenderView (the Phase 0 KaTeX/WKWebView pipeline, unchanged and
//  still reusable on its own).
//
//  Phase 2: adds the CheatSheetView sidebar. Visibility follows the math
//  block's focus by default (shown while focused, hidden otherwise), with
//  a \u{2318}/ shortcut that forces it into an explicit shown/hidden state,
//  persisted via @AppStorage so the override survives a relaunch.
//
//  Phase 3: replaces the single demo block with a full NoteDocument hosted
//  in NoteEditorView (text + interleaved math blocks, \u{2318}M to insert
//  one). ContentView owned the document and the note-wide
//  `focusedBlockID`.
//
//  Phase 4: adds local file persistence. ContentView is now a
//  NavigationSplitView — NotesListView (the sidebar of `.mafac` files in a
//  user-chosen folder, via NotesStore) as the master list, and the
//  currently-selected note's NoteEditorView + cheat-sheet sidebar as
//  detail, same as before just no longer the sole content of the window.
//
//  Persistence flow, read this before touching `selectedNoteURL`/
//  `openDocument`/`openMetadata`:
//
//  - `selectedNoteURL` is what NavigationSplitView's sidebar selection
//    binds to (List selection needs a Hashable id; a note's file URL is
//    that id, same as `NoteMetadata.id`).
//  - `openDocument`/`openMetadata` are the *loaded* note currently shown
//    in the detail pane — kept separate from `selectedNoteURL` because
//    selecting a row and having its content loaded/decoded from disk are
//    different moments (and the load can fail: file deleted externally).
//  - `loadSelectedNote(_:)` is the only place that changes `openDocument`/
//    `openMetadata` in response to a selection change. It always flushes
//    any pending autosave for the *previous* open note first, so quickly
//    switching notes never drops an edit that was still sitting in the
//    debounce window.
//  - Autosave: `.onChange(of: openDocument)` (NoteDocument is Equatable as
//    of Phase 4, see NoteDocument.swift) reschedules a debounced save via
//    `scheduleAutosave()`, the same cancel-and-restart `Task` pattern
//    Phase 2's `flashRecentlyUsed` already used for the cheat-sheet
//    highlight. `flushPendingSave()` (called on note switch, and on
//    NSApplication.willTerminateNotification so quitting doesn't lose the
//    last debounce window) cancels the pending task and saves immediately
//    instead of waiting out the delay.
//

import SwiftUI

/// Persisted cheat-sheet visibility mode. `automatic` is the default —
/// follow whether a math block has focus. Pressing \u{2318}/ flips into
/// whichever forced state is the opposite of what's currently on screen,
/// and that forced state sticks (across focus changes and app relaunches)
/// until \u{2318}/ is pressed again.
private enum CheatSheetOverride: Int {
    case automatic = 0
    case forcedShown = 1
    case forcedHidden = 2
}

struct ContentView: View {
    /// Folder selection, note listing, and load/save/create/rename/delete
    /// all live in NotesStore (Phase 4) — see that file for the
    /// security-scoped bookmark lifecycle in particular.
    @StateObject private var notesStore = NotesStore()

    /// The sidebar's current selection — a note's file URL, or nil if
    /// nothing is selected. Bound directly to NotesListView/List.
    @State private var selectedNoteURL: URL?

    /// The currently loaded note shown in the detail pane, and the
    /// metadata (url/title) it was loaded from. Both nil when nothing is
    /// selected, or when the selected note's file has gone missing.
    @State private var openDocument: NoteDocument?
    @State private var openMetadata: NoteMetadata?

    /// Which block in the open note — text or math — currently has
    /// keyboard focus, if any. Single source of truth shared with
    /// NoteEditorView; see that file's doc comment for the full
    /// focus-coordination story.
    @State private var focusedBlockID: UUID?

    /// `ShortcutEntry.id` of the most recently used shortcut, for the
    /// cheat-sheet's brief highlight. Cleared automatically after a short
    /// delay by `flashRecentlyUsed`.
    @State private var recentlyUsedShortcutID: String? = nil
    @State private var highlightResetTask: Task<Void, Never>? = nil

    /// Debounced-autosave timer. See the type-level doc comment above.
    @State private var saveTask: Task<Void, Never>? = nil

    /// Persisted across launches. Raw `Int` (rather than the enum
    /// directly) because `@AppStorage` needs a primitive/`RawRepresentable`
    /// UserDefaults-compatible type; we translate via `cheatSheetOverride`.
    @AppStorage("mafac.cheatSheet.override") private var overrideRawValue: Int = CheatSheetOverride.automatic.rawValue

    private let shortcutTable: ShortcutTable? = {
        try? ShortcutTable.loadFromBundle()
    }()

    private var cheatSheetOverride: CheatSheetOverride {
        CheatSheetOverride(rawValue: overrideRawValue) ?? .automatic
    }

    /// Whether the currently focused block is specifically a `.math`
    /// block (not just "something is focused") — the signal the cheat
    /// sheet's automatic visibility follows.
    private var isMathBlockFocused: Bool {
        guard let id = focusedBlockID, let openDocument else { return false }
        return openDocument.blocks.first(where: { $0.id == id })?.isMath ?? false
    }

    /// The cheat-sheet's actual on-screen visibility right now, combining
    /// the persisted override with live focus state.
    private var isCheatSheetVisible: Bool {
        switch cheatSheetOverride {
        case .automatic: return isMathBlockFocused
        case .forcedShown: return true
        case .forcedHidden: return false
        }
    }

    var body: some View {
        NavigationSplitView {
            NotesListView(notesStore: notesStore, selection: $selectedNoteURL)
        } detail: {
            detailContent
        }
        .navigationTitle(openMetadata?.title ?? "Mafac")
        .onAppear {
            if notesStore.folderURL == nil {
                notesStore.pickFolder()
            }
        }
        .onChange(of: selectedNoteURL) { _, newValue in
            loadSelectedNote(newValue)
        }
        .onChange(of: openDocument) { _, _ in
            scheduleAutosave()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            flushPendingSave()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            notesStore.reloadNotes()
        }
        .alert(
            "Notes Folder Unavailable",
            isPresented: Binding(
                get: { notesStore.folderAccessError != nil },
                set: { if !$0 { notesStore.folderAccessError = nil } }
            )
        ) {
            Button("Choose Folder\u{2026}") { notesStore.pickFolder() }
            Button("Dismiss", role: .cancel) {}
        } message: {
            Text(notesStore.folderAccessError ?? "")
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        HStack(spacing: 0) {
            Group {
                if notesStore.folderURL == nil {
                    placeholder(
                        systemImage: "folder.badge.questionmark",
                        title: "No Notes Folder Selected",
                        message: "Choose a folder to store your notes in.",
                        buttonTitle: "Choose Folder\u{2026}"
                    ) { notesStore.pickFolder() }
                } else if let shortcutTable, let openMetadata {
                    NoteEditorView(
                        document: openDocumentBinding,
                        focusedBlockID: $focusedBlockID,
                        shortcutTable: shortcutTable,
                        onShortcutUsed: { id in flashRecentlyUsed(id) },
                        isCheatSheetVisible: isCheatSheetVisible,
                        onToggleCheatSheet: { toggleCheatSheet() }
                    )
                    // Forces a fresh NoteUnifiedTextView (and Coordinator)
                    // whenever the open note changes, rather than trying
                    // to diff-and-reload one shared instance — see
                    // NoteEditorView's doc comment.
                    .id(openMetadata.id)
                } else if shortcutTable == nil {
                    Text("Failed to load ShortcutTable.json from the app bundle.")
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    placeholder(
                        systemImage: "note.text",
                        title: "No Note Selected",
                        message: "Choose a note from the sidebar, or create a new one.",
                        buttonTitle: "New Note"
                    ) {
                        if let metadata = notesStore.createNote() {
                            selectedNoteURL = metadata.url
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .frame(minWidth: 420, minHeight: 460)

            if isCheatSheetVisible, let shortcutTable {
                Divider()
                CheatSheetView(shortcutTable: shortcutTable, recentlyUsedID: recentlyUsedShortcutID)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: isCheatSheetVisible)
        // Hidden button is the standard SwiftUI trick for a
        // window-scoped keyboard shortcut that isn't tied to any visible
        // control: AppKit resolves \u{2318}/ as this button's key
        // equivalent before an ordinary keystroke would reach a block's
        // text view, so it works regardless of what has focus.
        // `.hidden()` keeps it invisible while `.background` keeps it
        // from affecting layout (it's sized to match its container).
        .background(
            Button("Toggle Cheat Sheet") {
                toggleCheatSheet()
            }
            .keyboardShortcut("/", modifiers: .command)
            .hidden()
        )
    }

    @ViewBuilder
    private func placeholder(
        systemImage: String,
        title: String,
        message: String,
        buttonTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title3.weight(.semibold))
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button(buttonTitle, action: action)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// `NoteEditorView` needs a non-optional `Binding<NoteDocument>`; this
    /// view only renders it once `openDocument` is non-nil (guarded in
    /// `detailContent`), so the `?? .empty(...)` fallback in the getter
    /// never actually fires in practice — it just satisfies the type
    /// without force-unwrapping.
    private var openDocumentBinding: Binding<NoteDocument> {
        Binding(
            get: { openDocument ?? .empty(title: openMetadata?.title ?? "Untitled") },
            set: { openDocument = $0 }
        )
    }

    private func toggleCheatSheet() {
        // Force into whichever state is the opposite of what's visible
        // right now, and persist it — from then on the override wins
        // over automatic focus-following until toggled again.
        overrideRawValue = isCheatSheetVisible
            ? CheatSheetOverride.forcedHidden.rawValue
            : CheatSheetOverride.forcedShown.rawValue
    }

    private func flashRecentlyUsed(_ id: String) {
        highlightResetTask?.cancel()
        recentlyUsedShortcutID = id
        highlightResetTask = Task {
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled else { return }
            recentlyUsedShortcutID = nil
        }
    }

    // MARK: - Note loading & persistence

    /// Reacts to a sidebar selection change: flushes any pending autosave
    /// for the note being left, then loads the newly selected one (or
    /// clears the detail pane if `url` is nil, or the file is gone —
    /// "note deleted externally" edge case, handled by `NotesStore.load`
    /// returning nil rather than throwing/crashing).
    private func loadSelectedNote(_ url: URL?) {
        flushPendingSave()
        focusedBlockID = nil

        guard let url, let metadata = notesStore.notes.first(where: { $0.url == url }) else {
            openDocument = nil
            openMetadata = nil
            return
        }
        guard let document = notesStore.load(metadata) else {
            // File vanished between being listed and being opened. Drop
            // the selection so the sidebar and detail pane agree there's
            // nothing to show, rather than showing a stale editor for a
            // note that no longer exists on disk.
            openDocument = nil
            openMetadata = nil
            selectedNoteURL = nil
            return
        }
        openMetadata = metadata
        openDocument = document
    }

    /// Debounced autosave: cancels any previously scheduled save and
    /// schedules a fresh one ~600ms out. Rapid consecutive edits keep
    /// pushing the save back so a fast typist isn't writing to disk on
    /// every keystroke; `flushPendingSave()` bypasses the delay when it
    /// genuinely matters (switching notes, quitting).
    private func scheduleAutosave() {
        guard let openDocument, let openMetadata else { return }
        saveTask?.cancel()
        let documentToSave = openDocument
        let metadataToSave = openMetadata
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            notesStore.save(documentToSave, to: metadataToSave)
        }
    }

    /// Cancels any pending debounced save and writes immediately if
    /// there's an open note. Synchronous (NotesStore.save is a plain
    /// blocking file write), so it's safe to call from a notification
    /// handler that needs the write to have happened before it returns
    /// (e.g. app termination).
    private func flushPendingSave() {
        saveTask?.cancel()
        saveTask = nil
        guard let openDocument, let openMetadata else { return }
        notesStore.save(openDocument, to: openMetadata)
    }
}

#Preview {
    ContentView()
}
