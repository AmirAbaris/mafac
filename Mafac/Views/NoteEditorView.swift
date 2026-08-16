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

import SwiftUI

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
        // over the default Window > Minimize (⌘M) menu item.
        .background(
            Button("Insert Math Block") {
                insertMathBlockAtCursor()
            }
            .keyboardShortcut("m", modifiers: .command)
            .hidden()
        )
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

        case .math(let latex):
            VStack(alignment: .leading, spacing: 6) {
                Text("MATH BLOCK")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)

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
}
