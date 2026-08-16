//
//  NoteTextBlockView.swift
//  Mafac
//
//  Phase 3: plain multi-line editable text surface for a `.text` block in
//  a NoteDocument. Deliberately NOT MathBlockTextView — no shortcut-table
//  keystroke interpretation, no structure/hole attributes, just ordinary
//  typing.
//
//  A custom NSTextView (rather than SwiftUI's own TextEditor) is used for
//  two reasons specific to Phase 3:
//
//  1. NoteEditorView's ⌘M handler needs to know exactly where the cursor
//     is inside the currently-focused text block, to split it into a
//     "before" and "after" block around the new math block. Plain
//     SwiftUI `TextEditor(text:)` (macOS 13, which `@FocusState` already
//     requires) exposes no such API — `TextEditor(text:selection:)`
//     didn't arrive until macOS 14. Wrapping NSTextView directly gives us
//     `selectedRange()` on demand.
//  2. Focus needs to be drivable both ways: user clicks set it (as with
//     any text view), but NoteEditorView also needs to *hand* focus to a
//     freshly-split block programmatically (e.g. move focus into the new
//     math block right after a ⌘M split, echoing Phase 1/2's UX where a
//     shortcut lands the cursor in the next hole). See `isFocused` below,
//     which mirrors the pattern MathBlockView already uses.
//
//  This view intentionally does not own the block's identity or position
//  in the document — it just edits a `String` in place. Splitting,
//  inserting, and reordering blocks all happen in NoteEditorView.
//

import SwiftUI
import AppKit

/// Lets NoteEditorView reach into a specific text block's live NSTextView
/// from outside the SwiftUI view tree — needed only by the ⌘M handler,
/// which runs at the note level and must read the currently-focused text
/// block's cursor position to know where to split. One handle per
/// text-block id; see `TextBlockRegistry` in NoteEditorView.swift for how
/// these are created and kept alive for exactly as long as the block
/// exists in the document.
final class TextBlockHandle {
    weak var textView: NSTextView?
}

struct NoteTextBlockView: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool

    /// Filled in by the coordinator on creation/update so NoteEditorView
    /// can query this block's live NSTextView from outside.
    var handle: TextBlockHandle

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, isFocused: $isFocused)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textContainer = NSTextContainer(containerSize: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        textContainer.heightTracksTextView = false

        let layoutManager = NSLayoutManager()
        layoutManager.addTextContainer(textContainer)

        let storage = NSTextStorage(string: text)
        storage.addLayoutManager(layoutManager)

        let textView = NSTextView(frame: .zero, textContainer: textContainer)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = NSColor.labelColor
        textView.isEditable = true
        textView.isSelectable = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [NSView.AutoresizingMask.width]
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.drawsBackground = false
        textView.delegate = context.coordinator

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        context.coordinator.textView = textView
        handle.textView = textView
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        handle.textView = textView

        // One-way-in sync, and only when the string actually differs (e.g.
        // a programmatic change like ⌘M seeding a fresh "before"/"after"
        // block's initial text) — never unconditionally on every body
        // re-evaluation. Typing already flows the other direction via the
        // coordinator's textDidChange, which updates `text` to match
        // `textView.string` exactly, so on the very next `updateNSView`
        // call after a keystroke the two already agree and this is a
        // no-op — it never fights the user's live cursor/selection.
        if textView.string != text {
            textView.string = text
        }

        // Focus-follows-state: if NoteEditorView has decided this block
        // should be focused (right after a ⌘M split hands focus to the
        // "after" text block, or to the new math block instead — see
        // MathBlockView's matching logic) but this text view isn't
        // actually first responder yet, claim it. Guarded both ways so
        // this never fights a live, user-driven focus change or loops
        // back on itself once satisfied.
        if isFocused, textView.window?.firstResponder !== textView {
            textView.window?.makeFirstResponder(textView)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        weak var textView: NSTextView?
        private var text: Binding<String>
        private var isFocused: Binding<Bool>

        init(text: Binding<String>, isFocused: Binding<Bool>) {
            self.text = text
            self.isFocused = isFocused
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            text.wrappedValue = tv.string
        }

        // Same signal MathBlockView.Coordinator uses (see its doc comment):
        // NSTextView posts these on becoming/resigning the window's field
        // editor, i.e. exactly "does this text block currently have
        // keyboard focus."
        func textDidBeginEditing(_ notification: Notification) {
            isFocused.wrappedValue = true
        }

        func textDidEndEditing(_ notification: Notification) {
            isFocused.wrappedValue = false
        }
    }
}
