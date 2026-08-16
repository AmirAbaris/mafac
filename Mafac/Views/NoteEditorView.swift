//
//  NoteEditorView.swift
//  Mafac
//
//  Phase 3: renders a NoteDocument's blocks top-to-bottom — each `.text`
//  block as an editable NoteTextBlockView, each `.math` block as the
//  existing MathBlockView (Phase 1) paired with MathRenderView (Phase 0),
//  exactly as ContentView wired the single demo block in Phases 1-2, now
//  repeated per math block in a dynamic list.
//
//  Focus coordination (read this before touching `focusedBlockID`):
//
//  - A single `@Binding var focusedBlockID: UUID?` (owned by ContentView,
//    passed down) is the one source of truth for "which block, if any,
//    currently has keyboard focus" — whether that block is text or math.
//    This has to be a plain `Binding<UUID?>` rather than `@FocusState`,
//    because `@FocusState` only drives SwiftUI-native focusable views;
//    both NoteTextBlockView and MathBlockView are NSViewRepresentable
//    wrappers that track focus themselves via NSTextView's
//    become/resignFirstResponder notifications (see each view's
//    Coordinator) and report it out through a plain Bool binding — the
//    same pattern Phase 1/2 already used for the single demo block, now
//    generalized to a per-block value via `focusBinding(for:)` below.
//  - `focusBinding(for:)` derives a `Binding<Bool>` for one block's id
//    from the single `focusedBlockID`, using the standard
//    "one shared selection, N item bindings" trick: get returns whether
//    *this* id is the focused one, set moves `focusedBlockID` to this id
//    (or clears it if the caller is reporting itself un-focused and it
//    was the current one). This is what makes a *dynamic* number of
//    blocks — the array can grow/shrink/split at any time — work: nothing
//    here depends on a fixed enum of block identities the way a literal
//    `@FocusState<SomeEnum?>` would.
//  - Cheat-sheet gating (point 5 of the Phase 3 brief) lives in
//    ContentView, not here: it just needs to know whether the currently
//    focused block (if any) is specifically a `.math` block, which it can
//    compute from `document.blocks` + `focusedBlockID` without any extra
//    plumbing from this view.
//
//  ⌘M (insert math block at cursor):
//
//  - A hidden `Button` with `.keyboardShortcut("m", modifiers: .command)`
//    intercepts ⌘M the same way ContentView's Phase 2 code intercepted
//    ⌘/ — AppKit resolves a SwiftUI button's key equivalent while walking
//    the view hierarchy, before it would fall through to the window's
//    main menu, so this reliably wins over the default Window menu's
//    "Minimize" item (also bound to ⌘M) without needing to touch the
//    app's command set.
//  - If a `.text` block currently has focus, `TextBlockRegistry` (below)
//    is used to reach that block's *live* NSTextView and read its cursor
//    position directly — the whole reason NoteTextBlockView wraps
//    NSTextView instead of using SwiftUI's TextEditor (see that file's
//    doc comment). The text is split at the cursor into "before"/"after"
//    strings, and the one focused text block is replaced with three:
//    before-text, a fresh empty math block, after-text. `ForEach` then
//    diffs this correctly because all three get their own ids (the
//    before/after blocks are FRESH ids, not reused from the block being
//    split) — no attempt is made to reuse or mutate the old block's
//    NSTextView in place, which would be far more fragile than just
//    letting SwiftUI mount two brand-new NoteTextBlockView instances.
//  - If nothing is focused, or a math block is focused, ⌘M instead
//    appends a new math block (plus a trailing empty text block so
//    there's somewhere to type after it) at the end of the document.
//  - Either way, focus moves to the new math block afterward, so the
//    user can start typing a shortcut sequence immediately — matching
//    Phase 1's "shortcut lands the cursor in the next hole" feel.
//

//  Phase 5 (LaTeX export, copy to clipboard):
//
//  - "Copy as LaTeX" for one math block is reachable three ways, so it's
//    discoverable without needing to know a shortcut: a small clipboard
//    button in that block's "MATH BLOCK" header row, a right-click
//    .contextMenu on the block's container, and ⌘⇧C while a math block
//    has focus (the same hidden-button key-equivalent pattern Phase 2
//    used for ⌘/ and Phase 3 used for ⌘M — see
//    copyFocusedMathBlockAsLaTeX(), which is a no-op unless the
//    currently focused block is specifically `.math`, so the shortcut is
//    effectively scoped to "a math block has focus" without needing
//    separate enable/disable plumbing for the hidden button itself).
//  - "Copy Note as Markdown" (whole-note export) is a toolbar button
//    (.toolbar below) — always available, not focus-gated, since it
//    operates on the whole document rather than one block.
//  - Both actions use NoteLaTeXExport (Models/NoteDocument+LaTeXExport.swift),
//    a serializer deliberately separate from Phase 4's NoteMarkdownCodec
//    (the on-disk file format) — see that file's doc comment for why.
//    Both put a plain string on NSPasteboard.general; there is no
//    richer pasteboard type involved since the target apps' paste-as
//    -Markdown paths all work off plain text.
//

import SwiftUI
import AppKit

/// Live NSTextView handles for text blocks currently in the document,
/// keyed by block id. This exists purely so the ⌘M handler (which runs at
/// the note level, outside any single block's NSViewRepresentable) can
/// reach into the currently-focused text block's AppKit view on demand.
///
/// It's a plain `ObservableObject` with a non-`@Published` dictionary
/// rather than `@State` deliberately: `handle(for:)` is called during
/// `body` evaluation (from inside `ForEach`), and mutating it there must
/// NOT trigger a SwiftUI re-render — it's plumbing for later, not state
/// that drives this view's own layout. Held via `@StateObject` so the
/// object itself (and therefore its dictionary) survives across
/// NoteEditorView's body re-evaluations.
final class TextBlockRegistry: ObservableObject {
    private(set) var handles: [UUID: TextBlockHandle] = [:]

    func handle(for id: UUID) -> TextBlockHandle {
        if let existing = handles[id] { return existing }
        let handle = TextBlockHandle()
        handles[id] = handle
        return handle
    }

    func removeHandle(for id: UUID) {
        handles.removeValue(forKey: id)
    }
}

struct NoteEditorView: View {
    @Binding var document: NoteDocument
    @Binding var focusedBlockID: UUID?

    let shortcutTable: ShortcutTable?

    /// Forwarded up to ContentView so the shared cheat-sheet sidebar can
    /// flash the right row, regardless of which math block in the note
    /// triggered it.
    var onShortcutUsed: (String) -> Void = { _ in }

    /// Whether the math key guide (cheat sheet) is currently visible, so
    /// the toolbar toggle button can reflect its state — mirrors
    /// ContentView's `isCheatSheetVisible`.
    var isCheatSheetVisible: Bool = false

    /// Forwarded up to ContentView, which owns the cheat sheet's
    /// shown/hidden override — same action as the hidden ⌘/ shortcut, now
    /// with a discoverable toolbar button too.
    var onToggleCheatSheet: () -> Void = {}

    @StateObject private var textRegistry = TextBlockRegistry()

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(document.blocks) { block in
                    blockView(for: block)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Same hidden-button trick Phase 2's ContentView used for ⌘/ — see
        // the type-level doc comment above for why this reliably wins
        // over the default Window > Minimize (⌘M) menu item. Phase 5 adds
        // a second hidden button for ⌘⇧C ("Copy as LaTeX" while a math
        // block has focus) in the same background, grouped so `.hidden()`
        // applies to both without affecting layout.
        .background(
            Group {
                Button("Insert Math Block") {
                    insertMathBlockAtCursor()
                }
                .keyboardShortcut("m", modifiers: .command)

                Button("Copy Math Block as LaTeX") {
                    copyFocusedMathBlockAsLaTeX()
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
            }
            .hidden()
        )
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    insertMathBlockAtCursor()
                } label: {
                    Label("Insert Math Block", systemImage: "x.squareroot")
                }
                .help("Insert a math block at the cursor (\u{2318}M)")
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    onToggleCheatSheet()
                } label: {
                    Label(
                        isCheatSheetVisible ? "Hide Math Key Guide" : "Show Math Key Guide",
                        systemImage: isCheatSheetVisible ? "sidebar.right" : "sidebar.squares.right"
                    )
                }
                .help("Toggle the math shortcut key guide (\u{2318}/)")
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    copyNoteAsMarkdown()
                } label: {
                    Label("Copy Note as Markdown", systemImage: "doc.on.clipboard")
                }
                .help("Copy the whole note as Markdown, with math blocks as $$...$$")
            }
        }
    }

    @ViewBuilder
    private func blockView(for block: NoteBlock) -> some View {
        switch block.content {
        case .text:
            NoteTextBlockView(
                text: textBinding(for: block.id),
                isFocused: focusBinding(for: block.id),
                handle: textRegistry.handle(for: block.id)
            )
            .frame(minHeight: 32, idealHeight: 60, maxHeight: 220)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.gray.opacity(0.3), lineWidth: 1)
            )

        case .math(let latex):
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("MATH BLOCK")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Spacer()

                    // Discoverable, non-hidden entry point for "Copy as
                    // LaTeX" — the context menu and ⌘⇧C (below) cover the
                    // same action for users who already know about them.
                    Button {
                        copyLaTeXToPasteboard(latex)
                    } label: {
                        Image(systemName: "doc.on.clipboard")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Copy as LaTeX (⌘⇧C)")
                }

                MathBlockView(
                    shortcutTable: shortcutTable ?? ShortcutTable(version: 1, entries: []),
                    onLatexChange: { newLatex in updateMathLatex(id: block.id, latex: newLatex) },
                    onShortcutUsed: onShortcutUsed,
                    isFocused: focusBinding(for: block.id)
                )
                .frame(minHeight: 70)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                )

                MathRenderView(latex: latex)
                    .frame(minHeight: 60, idealHeight: 90)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                    )
            }
            .contextMenu {
                Button("Copy as LaTeX") {
                    copyLaTeXToPasteboard(latex)
                }
            }
        }
    }

    // MARK: - Bindings derived from the single document + focus source of truth

    /// Standard "one shared selection, N item bindings" derivation: get
    /// reflects whether `id` is the currently focused block; set moves
    /// (or clears) the shared `focusedBlockID`. Used for both `.text` and
    /// `.math` blocks so focus is uniform across block kinds.
    private func focusBinding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { focusedBlockID == id },
            set: { newValue in
                if newValue {
                    focusedBlockID = id
                } else if focusedBlockID == id {
                    focusedBlockID = nil
                }
            }
        )
    }

    private func textBinding(for id: UUID) -> Binding<String> {
        Binding(
            get: {
                guard case let .text(str)? = document.blocks.first(where: { $0.id == id })?.content else {
                    return ""
                }
                return str
            },
            set: { newValue in
                guard let idx = document.blocks.firstIndex(where: { $0.id == id }) else { return }
                document.blocks[idx].content = .text(newValue)
            }
        )
    }

    private func updateMathLatex(id: UUID, latex: String) {
        guard let idx = document.blocks.firstIndex(where: { $0.id == id }) else { return }
        document.blocks[idx].content = .math(latex: latex)
    }

    // MARK: - ⌘M: insert a math block at the cursor

    private func insertMathBlockAtCursor() {
        guard
            let focusedID = focusedBlockID,
            let idx = document.blocks.firstIndex(where: { $0.id == focusedID }),
            case .text = document.blocks[idx].content,
            let textView = textRegistry.handles[focusedID]?.textView
        else {
            appendMathBlock()
            return
        }

        let fullText = textView.string as NSString
        let cursor = min(max(textView.selectedRange().location, 0), fullText.length)
        let before = fullText.substring(to: cursor)
        let after = fullText.substring(from: cursor)

        let mathID = UUID()
        let replacement = [
            NoteBlock(content: .text(before)),
            NoteBlock(id: mathID, content: .math(latex: "")),
            NoteBlock(content: .text(after))
        ]

        document.blocks.replaceSubrange(idx...idx, with: replacement)
        // The block at `focusedID` no longer exists in the document (it
        // was replaced by two fresh text blocks) — drop its handle so the
        // registry doesn't accumulate stale entries for blocks that are
        // gone. The two new text blocks register their own handles
        // lazily, the next time `blockView(for:)` runs for them.
        textRegistry.removeHandle(for: focusedID)
        focusedBlockID = mathID
    }

    /// Fallback for ⌘M when nothing is focused, or when a math block
    /// (rather than text) currently is — appends a new math block at the
    /// end, plus a trailing empty text block so there's somewhere to keep
    /// typing after it.
    private func appendMathBlock() {
        let mathID = UUID()
        document.blocks.append(NoteBlock(id: mathID, content: .math(latex: "")))
        document.blocks.append(NoteBlock(content: .text("")))
        focusedBlockID = mathID
    }

    // MARK: - Phase 5: LaTeX export (copy to clipboard)

    /// ⌘⇧C handler. Deliberately a no-op unless the currently focused
    /// block is specifically `.math` — this is what "scopes" the shortcut
    /// to math blocks despite the hidden button itself always being wired
    /// up and able to intercept the key equivalent (same pattern as
    /// `insertMathBlockAtCursor`'s guard above, which similarly falls
    /// back rather than acting on the wrong kind of focused block).
    private func copyFocusedMathBlockAsLaTeX() {
        guard
            let focusedID = focusedBlockID,
            let block = document.blocks.first(where: { $0.id == focusedID }),
            case let .math(latex) = block.content
        else { return }
        copyLaTeXToPasteboard(latex)
    }

    /// Puts one math block's raw LaTeX on the general pasteboard, wrapped
    /// as a block-level `$$...$$` (see `NoteLaTeXExport.wrapAsLaTeXBlock`
    /// for the exact formatting and why). Shared by the per-block copy
    /// button, the context menu item, and the ⌘⇧C handler above.
    private func copyLaTeXToPasteboard(_ latex: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(NoteLaTeXExport.wrapAsLaTeXBlock(latex), forType: .string)
    }

    /// Toolbar action: serializes the whole document (`NoteLaTeXExport.
    /// encode`, text verbatim + math as `$$...$$`, blocks separated by
    /// blank lines) and puts the result on the general pasteboard as
    /// plain text, ready to paste as Markdown into Notion/Obsidian/Craft.
    private func copyNoteAsMarkdown() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(NoteLaTeXExport.encode(document), forType: .string)
    }
}
