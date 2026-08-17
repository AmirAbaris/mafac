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
    private var scrollView: NSScrollView?

    /// The popover starts at `minSize` and grows with the expression up to
    /// `maxSize`, past which the box scrolls instead — without a ceiling a
    /// long expression would grow the popover taller than the window.
    private static let minSize = NSSize(width: 280, height: 44)
    private static let maxSize = NSSize(width: 620, height: 260)

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
        self.scrollView = scrollView

        let contentController = NSViewController()
        contentController.view = scrollView
        popover.contentViewController = contentController
        popover.behavior = .transient
        popover.delegate = self

        boxTextView.onTextChanged = { [weak self] in self?.resizeToFit() }
        // Sizes the popover to `initialLatex` before it's ever shown, so
        // reopening a long expression doesn't start cramped and then jump.
        resizeToFit()

        popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
        view.window?.makeFirstResponder(boxTextView)
        boxTextView.selectFirstHoleOrEnd(hadInitialContent: !initialLatex.isEmpty)
    }

    /// Grows the popover to fit what's been typed: wider as a single line
    /// lengthens, then taller once it hits the width cap and starts
    /// wrapping, then scrolling once it hits the height cap too.
    private func resizeToFit() {
        guard let storage = boxTextView.textStorage else { return }
        let inset = boxTextView.textContainerInset
        // Insets on both sides, plus a little slack so the caret sitting
        // past the last glyph doesn't land hard against the edge.
        let chrome = NSSize(width: inset.width * 2 + 6, height: inset.height * 2 + 4)

        let natural = storage.size().width + chrome.width
        let width = min(max(Self.minSize.width, natural.rounded(.up)), Self.maxSize.width)

        // Measured off the attributed string rather than the live layout
        // manager: asking the real text container to re-measure mid-edit
        // would fight `widthTracksTextView` and disturb the layout the
        // user is currently typing into.
        let bounding = storage.boundingRect(
            with: NSSize(width: width - chrome.width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let height = min(
            max(Self.minSize.height, (bounding.height + chrome.height).rounded(.up)),
            Self.maxSize.height
        )

        let size = NSSize(width: width, height: height)
        if size != popover.contentSize {
            popover.contentSize = size
            scrollView?.hasVerticalScroller = height >= Self.maxSize.height
        }
        // Runs even when the size didn't change — that's exactly the
        // capped case, where the caret is the thing that would otherwise
        // scroll out of sight.
        boxTextView.scrollRangeToVisible(boxTextView.selectedRange())
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
