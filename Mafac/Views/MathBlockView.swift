//
//  MathBlockView.swift
//  Mafac
//
//  Phase 1: the standalone math block — wraps MathBlockTextView (the
//  keystroke interpreter in MathBlockTextView.swift) in an NSScrollView
//  and bridges it into SwiftUI.
//
//  The text view is treated as the source of truth while the block is
//  being edited. Its derived LaTeX string is surfaced outward via
//  `onLatexChange` (already debounced by MathBlockTextView), rather than
//  a two-way @Binding<String> — pushing an external string back into the
//  text view on every SwiftUI body re-evaluation would fight the text
//  view's own cursor/selection state and is unnecessary here, since
//  nothing else needs to *write into* the block from outside in Phase 1.
//

import SwiftUI
import AppKit

struct MathBlockView: NSViewRepresentable {
    var shortcutTable: ShortcutTable

    /// Called (debounced ~120ms by the text view) with the block's
    /// current LaTeX string whenever it changes.
    var onLatexChange: (String) -> Void

    /// Called synchronously with a `ShortcutEntry.id` every time a
    /// shortcut is inserted, for the cheat-sheet's "recently used"
    /// highlight (Phase 2). Optional — nil is a no-op.
    var onShortcutUsed: ((String) -> Void)? = nil

    /// Mirrors whether this block's text view currently has keyboard
    /// focus (is the first responder / actively editing), updated by
    /// the coordinator via NSTextViewDelegate's begin/end-editing
    /// notifications. Phase 2's ContentView uses this to show/hide the
    /// cheat-sheet automatically.
    @Binding var isFocused: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(isFocused: $isFocused)
    }

    func makeNSView(context: Context) -> NSScrollView {
        // Manual TextKit stack so we control exactly which NSTextView
        // subclass sits on top of it.
        let textContainer = NSTextContainer(containerSize: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        textContainer.heightTracksTextView = false

        let layoutManager = NSLayoutManager()
        layoutManager.addTextContainer(textContainer)

        let storage = NSTextStorage()
        storage.addLayoutManager(layoutManager)

        let textView = MathBlockTextView(frame: .zero, textContainer: textContainer)
        textView.configureForMathInput()
        textView.shortcutTable = shortcutTable
        textView.onLatexChanged = onLatexChange
        textView.onShortcutUsed = onShortcutUsed
        textView.font = NSFont.monospacedSystemFont(ofSize: 16, weight: .regular)
        textView.textColor = NSColor.labelColor
        textView.isEditable = true
        textView.isSelectable = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [NSView.AutoresizingMask.width]
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.delegate = context.coordinator

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        // Keep the shortcut table and callback current across SwiftUI
        // re-renders without touching the text view's live content or
        // selection (see the type-level doc comment for why).
        guard let textView = context.coordinator.textView else { return }
        textView.shortcutTable = shortcutTable
        textView.onLatexChanged = onLatexChange
        textView.onShortcutUsed = onShortcutUsed

        // Phase 3 addition: focus-follows-state. `isFocused` was purely an
        // outbound signal in Phase 1/2 (text view -> binding, via the
        // coordinator's textDidBeginEditing/EndEditing below); Phase 3
        // needs the reverse too, so NoteEditorView can hand keyboard focus
        // to a freshly-inserted math block (e.g. right after a ⌘M split)
        // by setting `isFocused` from outside. Guarded on both sides —
        // only acts when there's an actual mismatch to resolve — so it
        // never fights a live, user-driven focus change (e.g. clicking
        // into a different block resigns this text view first responder
        // the normal AppKit way; this block doesn't fight that) or loops
        // back on itself once satisfied.
        if isFocused, textView.window?.firstResponder !== textView {
            textView.window?.makeFirstResponder(textView)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        weak var textView: MathBlockTextView?
        private var isFocused: Binding<Bool>

        init(isFocused: Binding<Bool>) {
            self.isFocused = isFocused
        }

        // NSTextView (a subclass of NSText) posts these when it becomes /
        // resigns the window's field editor for actual text editing —
        // i.e. exactly the "does this math block currently have keyboard
        // focus" signal Phase 2's cheat-sheet needs. Using the delegate
        // callbacks (rather than overriding becomeFirstResponder /
        // resignFirstResponder on the text view itself) keeps all
        // SwiftUI-facing state in the coordinator, where the @Binding
        // lives.
        func textDidBeginEditing(_ notification: Notification) {
            isFocused.wrappedValue = true
        }

        func textDidEndEditing(_ notification: Notification) {
            isFocused.wrappedValue = false
        }
    }
}

#Preview {
    let table = (try? ShortcutTable.loadFromBundle()) ?? ShortcutTable(version: 1, entries: [])
    return MathBlockView(shortcutTable: table, onLatexChange: { _ in }, isFocused: .constant(true))
        .frame(width: 480, height: 120)
}
