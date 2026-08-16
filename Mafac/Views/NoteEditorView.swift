//
//  NoteEditorView.swift
//  Mafac
//
//  Refactor: one continuous NoteUnifiedTextView (AppKit) hosts the whole
//  note — plain text and inline math attachments together, the way
//  ordinary note apps work. This SwiftUI wrapper just bridges
//  `Binding<NoteDocument>` to that text view's `[NoteBlock]` load/read
//  methods and exposes the toolbar actions (insert math, toggle cheat
//  sheet, copy as Markdown/LaTeX).
//
//  Focus coordination: `focusedBlockID` is non-nil exactly while a math
//  expression's edit popover is open (see NoteUnifiedTextView's
//  `onFocusedMathBlockChanged`) — same signal ContentView's cheat-sheet
//  auto-visibility used before, just now driven by "a math popover is
//  open" instead of "a math block's own text view has focus".
//
//  ⌘M / ⌘⇧C: same hidden-button key-equivalent trick previous phases
//  used (AppKit resolves them before they'd reach the text view or the
//  window's own menu), now just forwarding to
//  NoteEditorController.textView instead of block-array surgery.
//

import SwiftUI
import AppKit

/// Bridges toolbar/keyboard-shortcut actions (owned by this SwiftUI
/// view's body) to the live NoteUnifiedTextView instance (owned by the
/// NSViewRepresentable's Coordinator) — a plain reference holder rather
/// than plumbing the text view itself through every action closure.
private final class NoteEditorController: ObservableObject {
    weak var textView: NoteUnifiedTextView?
}

struct NoteEditorView: View {
    @Binding var document: NoteDocument
    @Binding var focusedBlockID: UUID?

    let shortcutTable: ShortcutTable?

    /// Forwarded up to ContentView so the shared cheat-sheet sidebar can
    /// flash the right row, regardless of which math expression in the
    /// note triggered it.
    var onShortcutUsed: (String) -> Void = { _ in }

    var isCheatSheetVisible: Bool = false
    var onToggleCheatSheet: () -> Void = {}

    @StateObject private var controller = NoteEditorController()

    var body: some View {
        NoteUnifiedTextRepresentable(
            document: $document,
            focusedBlockID: $focusedBlockID,
            shortcutTable: shortcutTable,
            onShortcutUsed: onShortcutUsed,
            controller: controller
        )
        .background(
            Group {
                Button("Insert Math Block") {
                    controller.textView?.insertMathAttachment()
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
                    controller.textView?.insertMathAttachment()
                } label: {
                    Label("Insert Math Block", systemImage: "x.squareroot")
                }
                .help("Insert a math expression at the cursor (\u{2318}M)")
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

    private func copyFocusedMathBlockAsLaTeX() {
        guard
            let focusedID = focusedBlockID,
            let block = document.blocks.first(where: { $0.id == focusedID }),
            case let .math(latex) = block.content
        else { return }
        copyLaTeXToPasteboard(latex)
    }

    private func copyLaTeXToPasteboard(_ latex: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(NoteLaTeXExport.wrapAsLaTeXBlock(latex), forType: .string)
    }

    private func copyNoteAsMarkdown() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(NoteLaTeXExport.encode(document), forType: .string)
    }
}

/// The NSViewRepresentable bridge proper — kept separate from
/// NoteEditorView (a plain `View`, not a representable) so the toolbar/
/// hidden-button SwiftUI chrome above doesn't have to live inside
/// `makeNSView`/`updateNSView`.
private struct NoteUnifiedTextRepresentable: NSViewRepresentable {
    @Binding var document: NoteDocument
    @Binding var focusedBlockID: UUID?
    let shortcutTable: ShortcutTable?
    let onShortcutUsed: (String) -> Void
    let controller: NoteEditorController

    func makeCoordinator() -> Coordinator {
        Coordinator(document: $document, focusedBlockID: $focusedBlockID, onShortcutUsed: onShortcutUsed)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NoteUnifiedTextView()
        textView.configureForNoteInput()
        textView.isEditable = true
        textView.isSelectable = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 4, height: 8)
        textView.textContainer?.widthTracksTextView = true
        textView.shortcutTable = shortcutTable
        textView.onBlocksChanged = context.coordinator.handleBlocksChanged
        textView.onFocusedMathBlockChanged = context.coordinator.handleFocusChanged
        textView.onShortcutUsed = onShortcutUsed
        textView.setBlocks(document.blocks)
        context.coordinator.lastPushedBlocks = document.blocks

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        context.coordinator.textView = textView
        controller.textView = textView
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        textView.shortcutTable = shortcutTable

        // Only reload the whole text view when the incoming document
        // genuinely differs from what this text view itself last pushed
        // out (an external change — switching notes) — never on the
        // round-trip echo of our own edits, which would blow away live
        // cursor position and any open math popover.
        if document.blocks != context.coordinator.lastPushedBlocks {
            textView.setBlocks(document.blocks)
            context.coordinator.lastPushedBlocks = document.blocks
        }
    }

    final class Coordinator {
        weak var textView: NoteUnifiedTextView?
        var lastPushedBlocks: [NoteBlock] = []

        private var document: Binding<NoteDocument>
        private var focusedBlockID: Binding<UUID?>
        private let onShortcutUsed: (String) -> Void

        init(document: Binding<NoteDocument>, focusedBlockID: Binding<UUID?>, onShortcutUsed: @escaping (String) -> Void) {
            self.document = document
            self.focusedBlockID = focusedBlockID
            self.onShortcutUsed = onShortcutUsed
        }

        func handleBlocksChanged(_ blocks: [NoteBlock]) {
            lastPushedBlocks = blocks
            document.wrappedValue.blocks = blocks
        }

        func handleFocusChanged(_ blockID: UUID?) {
            focusedBlockID.wrappedValue = blockID
        }
    }
}
