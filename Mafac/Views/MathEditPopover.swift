//
//  MathEditPopover.swift
//  Mafac
//
//  The little box's chrome: a small NSPopover anchored to a math
//  expression's position in the note, hosting a MathBoxTextView. Opening
//  it, typing, and closing it (Return, Escape, or clicking away — the
//  popover's own `.transient` behavior gives us click-away for free) is
//  the entire lifecycle; NoteUnifiedTextView never has any "math mode"
//  state of its own, it just asks this to show/commit.
//
//  Commit is funneled through exactly one place (`commit()`) regardless
//  of which of the three closing gestures triggered it, guarded by
//  `didCommit` so performClose()'s own popoverDidClose callback doesn't
//  double-fire it when Return/Escape already committed explicitly.
//

import AppKit

final class MathEditPopover: NSObject, NSPopoverDelegate {
    private let popover = NSPopover()
    private let boxTextView = MathBoxTextView()
    private var onCommit: ((String) -> Void)?
    private var didCommit = false

    func show(
        anchoredTo rect: NSRect,
        in view: NSView,
        initialLatex: String,
        shortcutTable: ShortcutTable?,
        onShortcutUsed: @escaping (String) -> Void,
        onCommit: @escaping (String) -> Void
    ) {
        self.onCommit = onCommit
        didCommit = false

        boxTextView.configureForMathInput()
        boxTextView.shortcutTable = shortcutTable
        boxTextView.onShortcutUsed = onShortcutUsed
        boxTextView.textStorage?.setAttributedString(NSAttributedString(string: ""))
        boxTextView.isVerticallyResizable = true
        boxTextView.isHorizontallyResizable = false
        boxTextView.autoresizingMask = [.width]
        boxTextView.textContainerInset = NSSize(width: 8, height: 6)
        boxTextView.textContainer?.widthTracksTextView = true
        if !initialLatex.isEmpty {
            boxTextView.loadExisting(latex: initialLatex)
        }
        boxTextView.onCommitKey = { [weak self] in self?.commitAndClose() }
        boxTextView.onCancelKey = { [weak self] in self?.close() }

        let scrollView = NSScrollView()
        scrollView.documentView = boxTextView
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let contentController = NSViewController()
        contentController.view = scrollView
        popover.contentViewController = contentController
        popover.contentSize = NSSize(width: 240, height: 40)
        popover.behavior = .transient
        popover.delegate = self

        popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
        view.window?.makeFirstResponder(boxTextView)
        boxTextView.selectFirstHoleOrEnd(hadInitialContent: !initialLatex.isEmpty)
    }

    /// Re-triggering ⌘M / the toolbar button while this popover is
    /// already open closes and commits it, rather than stacking a
    /// second one.
    func commitAndCloseExternally() {
        commitAndClose()
    }

    func popoverDidClose(_ notification: Notification) {
        commit()
    }

    private func commitAndClose() {
        commit()
        popover.performClose(nil)
    }

    private func close() {
        popover.performClose(nil)
    }

    private func commit() {
        guard !didCommit else { return }
        didCommit = true
        onCommit?(boxTextView.currentLatexString())
    }
}
