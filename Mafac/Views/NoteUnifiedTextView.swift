//
//  NoteUnifiedTextView.swift
//  Mafac
//
//  A note is ONE continuous NSTextView — plain text and math share the
//  same flow, the way every ordinary note app works. At rest, a math
//  expression is a single MathInlineAttachment character showing its
//  typeset symbol (via LaTeXInlineRenderer). Clicking it (or ⌘M for a
//  fresh one) opens a small floating box — MathEditPopover, hosting
//  MathBoxTextView — anchored right at that position, where you edit its
//  raw LaTeX source. Closing the box (Return, Escape, or clicking away)
//  commits the result back into this text view's storage as an updated
//  (or freshly created, or removed if left empty) MathInlineAttachment.
//
//  This text view itself therefore has no "math mode" state of its own —
//  `openPopover` is just a reference to whichever box is currently open,
//  if any, so a second ⌘M/toolbar press can close the current one
//  instead of stacking another.
//

import AppKit

final class NoteUnifiedTextView: NSTextView {

    static let baseFont = NSFont.systemFont(ofSize: 20)

    /// The one font/color pair every character in the note carries. Kept
    /// in one place because it has to be re-applied after edits — see
    /// `normalizeAttributes()`.
    static var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: baseFont, .foregroundColor: NSColor.textColor]
    }

    /// Fired after any edit — typing, or a math expression being
    /// inserted/updated/removed — with the note's current content
    /// re-derived from the text storage.
    var onBlocksChanged: (([NoteBlock]) -> Void)?

    /// Fired when a math expression's edit popover opens/closes, with
    /// that block's id (or nil once closed) — mirrors the old per-block
    /// `isFocused` signal the cheat sheet follows.
    var onFocusedMathBlockChanged: ((UUID?) -> Void)?

    /// Fired synchronously whenever a shortcut is inserted while a math
    /// popover is open, for the cheat sheet's "recently used" highlight.
    var onShortcutUsed: ((String) -> Void)?

    var shortcutTable: ShortcutTable?

    /// The currently-open math edit popover, if any.
    private var openPopover: MathEditPopover?

    func configureForNoteInput() {
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        isAutomaticDataDetectionEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticTextCompletionEnabled = false
        smartInsertDeleteEnabled = false
        usesFontPanel = false
        usesRuler = false
        isRichText = true // required to host inline NSTextAttachments
        allowsUndo = true
        font = Self.baseFont
        textColor = .textColor
        typingAttributes = Self.baseAttributes
    }

    // MARK: - Loading / reading the document

    func setBlocks(_ blocks: [NoteBlock]) {
        textStorage?.setAttributedString(Self.attributedString(from: blocks))
        normalizeAttributes()
    }

    /// Re-stamps the note's font and colour across the whole storage.
    ///
    /// An `NSTextAttachment` string carries no attributes of its own, so
    /// the moment a math expression is inserted, the character after it
    /// has neither `.font` nor `.foregroundColor` — and NSLayoutManager
    /// draws attribute-less text as plain black, which is invisible on a
    /// dark background and unfixable by typing, because every following
    /// keystroke inherits the same empty attributes. Re-applying the base
    /// attributes after every edit (and resetting `typingAttributes`, so
    /// the caret itself is correct before the next keystroke) keeps the
    /// note in one consistent style no matter what was inserted.
    private func normalizeAttributes() {
        guard let storage = textStorage else { return }
        if storage.length > 0 {
            // Collect first, mutate after: only genuinely mis-styled runs
            // are touched, so an ordinary keystroke doesn't invalidate
            // layout for the entire note.
            var dirty: [NSRange] = []
            storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length), options: []) { attrs, range, _ in
                let fontMatches = (attrs[.font] as? NSFont) == Self.baseFont
                let colorMatches = (attrs[.foregroundColor] as? NSColor) == NSColor.textColor
                if !fontMatches || !colorMatches { dirty.append(range) }
            }
            if !dirty.isEmpty {
                storage.beginEditing()
                for range in dirty { storage.addAttributes(Self.baseAttributes, range: range) }
                storage.endEditing()
            }
        }
        typingAttributes = Self.baseAttributes
    }

    /// Re-derives `[NoteBlock]` from the live text storage: each
    /// MathInlineAttachment becomes a `.math` block; everything else
    /// accumulates into `.text` blocks split at those boundaries. A math
    /// expression is always represented as an attachment here — editing
    /// happens in a separate popover, never inline in this storage.
    func currentBlocks() -> [NoteBlock] {
        guard let storage = textStorage, storage.length > 0 else { return [NoteBlock(content: .text(""))] }
        var blocks: [NoteBlock] = []
        var textBuffer = ""

        func flushText() {
            if !textBuffer.isEmpty {
                blocks.append(NoteBlock(content: .text(textBuffer)))
                textBuffer = ""
            }
        }

        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if let attachment = value as? MathInlineAttachment {
                flushText()
                blocks.append(NoteBlock(id: attachment.blockID, content: .math(latex: attachment.latex)))
            } else {
                textBuffer += storage.attributedSubstring(from: range).string
            }
        }
        flushText()

        return blocks.isEmpty ? [NoteBlock(content: .text(""))] : blocks
    }

    private static func attributedString(from blocks: [NoteBlock]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for block in blocks {
            switch block.content {
            case .text(let text):
                result.append(NSAttributedString(string: text, attributes: baseAttributes))
            case .math(let latex):
                result.append(attachmentString(MathInlineAttachment(blockID: block.id, latex: latex)))
            }
        }
        if result.length == 0 {
            result.append(NSAttributedString(string: "", attributes: baseAttributes))
        }
        return result
    }

    /// A math attachment as an attributed string carrying the note's own
    /// font/colour, so the characters typed after it inherit a real style
    /// instead of the attachment's empty attribute set.
    private static func attachmentString(_ attachment: MathInlineAttachment) -> NSAttributedString {
        let result = NSMutableAttributedString(attachment: attachment)
        result.addAttributes(baseAttributes, range: NSRange(location: 0, length: result.length))
        return result
    }

    override func didChangeText() {
        super.didChangeText()
        normalizeAttributes()
        onBlocksChanged?(currentBlocks())
    }

    // MARK: - Starting a new math expression (toolbar button / ⌘M)

    /// Opens the edit popover for a fresh, empty math expression at the
    /// cursor — nothing is left behind in the note if the box is closed
    /// without typing anything. If a popover is already open, this
    /// closes (and commits) it instead of stacking a second one.
    func insertMathAttachment() {
        if let popover = openPopover {
            popover.commitAndCloseExternally()
            return
        }

        let range = selectedRange()
        guard let storage = textStorage, shouldChangeText(in: range, replacementString: "") else { return }
        let blockID = UUID()
        let placeholder = MathInlineAttachment(blockID: blockID, latex: "")
        storage.beginEditing()
        storage.replaceCharacters(in: range, with: Self.attachmentString(placeholder))
        storage.endEditing()
        didChangeText()
        presentMathPopover(for: placeholder, at: range.location)
    }

    // MARK: - Click to open the edit popover

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        if let charIndex = attachmentCharacterIndex(at: point),
           let attachment = textStorage?.attribute(.attachment, at: charIndex, effectiveRange: nil) as? MathInlineAttachment {
            presentMathPopover(for: attachment, at: charIndex)
            return
        }
        super.mouseDown(with: event)
    }

    private func attachmentCharacterIndex(at viewPoint: NSPoint) -> Int? {
        guard let layoutManager, let textContainer, let storage = textStorage, storage.length > 0 else { return nil }
        let containerPoint = NSPoint(x: viewPoint.x - textContainerOrigin.x, y: viewPoint.y - textContainerOrigin.y)
        let glyphIndex = layoutManager.glyphIndex(for: containerPoint, in: textContainer)
        guard glyphIndex < layoutManager.numberOfGlyphs else { return nil }
        let glyphRect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyphIndex, length: 1), in: textContainer)
        guard glyphRect.contains(containerPoint) else { return nil }
        let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        return storage.attribute(.attachment, at: charIndex, effectiveRange: nil) != nil ? charIndex : nil
    }

    // MARK: - The popover itself

    private func presentMathPopover(for attachment: MathInlineAttachment, at charIndex: Int) {
        guard let layoutManager, let textContainer else { return }
        let glyphRange = layoutManager.glyphRange(forCharacterRange: NSRange(location: charIndex, length: 1), actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        rect.origin.x += textContainerOrigin.x
        rect.origin.y += textContainerOrigin.y

        let popover = MathEditPopover()
        openPopover = popover
        onFocusedMathBlockChanged?(attachment.blockID)
        popover.show(
            anchoredTo: rect,
            in: self,
            initialLatex: attachment.latex,
            shortcutTable: shortcutTable,
            onShortcutUsed: { [weak self] id in self?.onShortcutUsed?(id) }
        ) { [weak self] latex in
            self?.commitPopoverResult(latex, blockID: attachment.blockID, fallbackIndex: charIndex)
        }
    }

    private func commitPopoverResult(_ latex: String, blockID: UUID, fallbackIndex: Int) {
        openPopover = nil
        guard let storage = textStorage else { return }
        let range = currentAttachmentRange(for: blockID) ?? NSRange(location: min(fallbackIndex, storage.length), length: 0)
        let trimmed = latex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard shouldChangeText(in: range, replacementString: "") else { return }
        storage.beginEditing()
        if trimmed.isEmpty {
            storage.replaceCharacters(in: range, with: "")
        } else {
            storage.replaceCharacters(in: range, with: Self.attachmentString(MathInlineAttachment(blockID: blockID, latex: trimmed)))
        }
        storage.endEditing()
        didChangeText()
        onFocusedMathBlockChanged?(nil)
    }

    /// Scans for the MathInlineAttachment matching `blockID` — needed
    /// because the char index captured when the popover opened can go
    /// stale if anything shifted offsets while it was open.
    private func currentAttachmentRange(for blockID: UUID) -> NSRange? {
        guard let storage = textStorage else { return nil }
        var found: NSRange?
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
            if let attachment = value as? MathInlineAttachment, attachment.blockID == blockID {
                found = range
                stop.pointee = true
            }
        }
        return found
    }
}
