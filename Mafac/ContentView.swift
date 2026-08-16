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
//  a ⌘/ shortcut that forces it into an explicit shown/hidden state,
//  persisted via @AppStorage so the override survives a relaunch.
//
//  Phase 3: replaces the single demo block with a full NoteDocument hosted
//  in NoteEditorView (text + interleaved math blocks, ⌘M to insert one).
//  ContentView now owns the document and the note-wide `focusedBlockID`
//  (see NoteEditorView.swift's doc comment for why focus is a single
//  shared `UUID?` rather than a fixed `@FocusState` enum), and derives the
//  cheat sheet's automatic visibility from whether the currently focused
//  block specifically `isMath` — not just "is anything focused" — per the
//  Phase 3 brief's point 5.
//

import SwiftUI

/// Persisted cheat-sheet visibility mode. `automatic` is the default —
/// follow whether a math block has focus. Pressing ⌘/ flips into whichever
/// forced state is the opposite of what's currently on screen, and that
/// forced state sticks (across focus changes and app relaunches) until ⌘/
/// is pressed again.
private enum CheatSheetOverride: Int {
    case automatic = 0
    case forcedShown = 1
    case forcedHidden = 2
}

struct ContentView: View {
    /// The whole note, in memory only (Phase 4 adds file persistence —
    /// not started; see PLAN.md).
    @State private var document: NoteDocument = .empty(title: "New Note")

    /// Which block in the note — text or math — currently has keyboard
    /// focus, if any. Single source of truth shared with NoteEditorView;
    /// see that file's doc comment for the full focus-coordination story.
    @State private var focusedBlockID: UUID?

    /// `ShortcutEntry.id` of the most recently used shortcut, for the
    /// cheat-sheet's brief highlight. Cleared automatically after a short
    /// delay by `flashRecentlyUsed`. Sourced from whichever math block in
    /// the note last used a shortcut, not a single hardcoded block.
    @State private var recentlyUsedShortcutID: String? = nil
    @State private var highlightResetTask: Task<Void, Never>? = nil

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
        guard let id = focusedBlockID else { return false }
        return document.blocks.first(where: { $0.id == id })?.isMath ?? false
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
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Mafac")
                    .font(.largeTitle.bold())

                Text("Type normally. Press ⌘M to insert a math block at the cursor, then type shortcut keys inside it (e.g. r → √, f → fraction, p → π, i → ∫). ⌘/ toggles the shortcut reference.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let shortcutTable {
                    NoteEditorView(
                        document: $document,
                        focusedBlockID: $focusedBlockID,
                        shortcutTable: shortcutTable,
                        onShortcutUsed: { id in flashRecentlyUsed(id) }
                    )
                } else {
                    Text("Failed to load ShortcutTable.json from the app bundle.")
                        .foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .frame(minWidth: 560, minHeight: 460)

            if isCheatSheetVisible, let shortcutTable {
                Divider()
                CheatSheetView(shortcutTable: shortcutTable, recentlyUsedID: recentlyUsedShortcutID)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: isCheatSheetVisible)
        // Hidden button is the standard SwiftUI trick for a
        // window-scoped keyboard shortcut that isn't tied to any visible
        // control: AppKit resolves ⌘/ as this button's key equivalent
        // before an ordinary keystroke would reach a block's text view,
        // so it works regardless of what has focus. `.hidden()` keeps it
        // invisible while `.background` keeps it from affecting layout
        // (it's sized to match its container).
        .background(
            Button("Toggle Cheat Sheet") {
                toggleCheatSheet()
            }
            .keyboardShortcut("/", modifiers: .command)
            .hidden()
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
}

#Preview {
    ContentView()
}
