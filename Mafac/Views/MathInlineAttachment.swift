//
//  MathInlineAttachment.swift
//  Mafac
//
//  One inline math expression, embedded as a single NSTextAttachment
//  character inside NoteUnifiedTextView's single continuous text storage
//  — no separate block, no separate preview panel. At rest it shows
//  `latex` typeset via LaTeXInlineRenderer, rasterized to `.image` so it
//  lays out like any other inline glyph; NoteUnifiedTextView swaps in a
//  live raw-source editor (MathBlockTextView, in a popover anchored to
//  this attachment) when the user clicks it, then re-rasterizes and
//  updates in place when that popover closes.
//

import AppKit

final class MathInlineAttachment: NSTextAttachment {
    /// Matches the owning `NoteBlock.id` this attachment represents, so
    /// NoteEditorView's Coordinator can serialize the text view's content
    /// back into `[NoteBlock]` and ContentView can track which math block
    /// (if any) currently has focus.
    let blockID: UUID

    private(set) var latex: String

    init(blockID: UUID = UUID(), latex: String) {
        self.blockID = blockID
        self.latex = latex
        super.init(data: nil, ofType: nil)
        refreshImage()
    }

    required init?(coder: NSCoder) {
        fatalError("MathInlineAttachment does not support NSCoding")
    }

    /// Updates the stored LaTeX and re-rasterizes `.image` to match.
    /// Callers are responsible for telling the layout manager the
    /// attachment's size may have changed (see
    /// `NoteUnifiedTextView.refreshAttachment(_:)`).
    func update(latex: String) {
        self.latex = latex
        refreshImage()
    }

    private static let font = NSFont.systemFont(ofSize: 18)
    private static let padding = NSSize(width: 6, height: 4)

    private func refreshImage() {
        let display = latex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "▢" : latex
        let attributed = LaTeXInlineRenderer.render(display, font: Self.font, color: .textColor)
        var size = attributed.size()
        size.width += Self.padding.width * 2
        size.height += Self.padding.height * 2
        size.width = max(size.width, 20)
        size.height = max(size.height, 20)

        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.textBackgroundColor.withAlphaComponent(0.6).setFill()
            let backgroundPath = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
            backgroundPath.fill()
            NSColor.gray.withAlphaComponent(0.35).setStroke()
            backgroundPath.lineWidth = 1
            backgroundPath.stroke()

            let drawPoint = NSPoint(x: Self.padding.width, y: Self.padding.height)
            attributed.draw(at: drawPoint)
            return true
        }
        self.image = image

        let baselineDrop = (size.height - Self.font.ascender + Self.font.descender) / 2
        bounds = CGRect(x: 0, y: -baselineDrop, width: size.width, height: size.height)
    }
}
