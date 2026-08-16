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

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        // Manual TextKit stack so we control exactly which NSTextView
        // subclass sits on top of it.
        let textContainer = NSTextContainer(containerSize: NSSize(width: 0, height: .greatestFiniteMagnitude))
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
        textView.font = .monospacedSystemFont(ofSize: 16, weight: .regular)
        textView.textColor = .labelColor
        textView.isEditable = true
        textView.isSelectable = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
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
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        weak var textView: MathBlockTextView?
    }
}

#Preview {
    let table = (try? ShortcutTable.loadFromBundle()) ?? ShortcutTable(version: 1, entries: [])
    return MathBlockView(shortcutTable: table) { _ in }
        .frame(width: 480, height: 120)
}
