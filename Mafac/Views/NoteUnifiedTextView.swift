//
//  NoteUnifiedTextView.swift
//  Mafac
//
//  A note is ONE continuous NSTextView — plain text and math share the
//  same flow, the way every ordinary note app works. At rest, a math
//  expression is a single MathInlineAttachment character showing its
//  typeset symbol (via LaTeXInlineRenderer). Clicking it doesn't open any
//  separate box/popup — it swaps that one character for its live,
//  editable raw LaTeX source (with hole placeholders, shortcut-key
//  expansion, Tab-to-next-hole, structured backspace — all the logic
//  MathBlockTextView used to own on its own standalone text view, now
//  scoped to `activeMathRange` here instead) right in place, highlighted
//  so it reads as "you're editing math here". Clicking elsewhere,
//  pressing Return, or pressing Escape collapses it straight back to the
//  rendered symbol. There is never a second text view or floating panel
//  involved — only ever this one.
//
//  While a math expression is expanded, its live characters aren't an
//  NSTextAttachment (there's nothing to attach — it's just text), so
//  `currentBlocks()` recognizes it via the `.mafacActiveMath` attribute
//  (tagged with the block's id) instead of `.attachment`, and derives its
//  latex the same way MathBlockTextView always did — stripping hole
//  placeholders. That keeps `[NoteBlock]` (and therefore autosave)
//  correct even if a save lands mid-edit.
//

import AppKit

extension NSAttributedString.Key {
    /// UUID shared by every character of one shortcut-inserted snippet
    /// (including content later typed into its holes) — used to find
    /// structure boundaries for atomic backspace, exactly as
    /// MathBlockTextView originally used it.
    static let mafacStructure = NSAttributedString.Key("MafacStructure")

    /// Int hole index, present only on a hole's placeholder character
    /// while unedited. Drives Tab navigation.
    static let mafacHole = NSAttributedString.Key("MafacHole")

    /// Present on every character of the currently-expanded math range,
    /// valued with that block's id — lets `currentBlocks()` recognize an
    /// in-progress raw-source edit as still being one `.math` block.
    static let mafacActiveMath = NSAttributedString.Key("MafacActiveMath")
}

final class NoteUnifiedTextView: NSTextView {

    static let baseFont = NSFont.systemFont(ofSize: 17)
    private static let mathFont = NSFont.monospacedSystemFont(ofSize: 17, weight: .medium)
    private static let mathHighlight = NSColor.controlAccentColor.withAlphaComponent(0.16)
    private static let holePlaceholder = "\u{25A2}" // ▢

    /// Fired after any edit — typing, a math attachment being inserted,
    /// a math expression's latex changing, or a math expansion being
    /// committed — with the note's current content re-derived from the
    /// text storage.
    var onBlocksChanged: (([NoteBlock]) -> Void)?

    /// Fired when a math expression expands/collapses in place, with
    /// that block's id (or nil once collapsed) — mirrors the old
    /// per-block `isFocused` signal the cheat sheet follows.
    var onFocusedMathBlockChanged: ((UUID?) -> Void)?

    /// Fired synchronously whenever a shortcut is inserted while a math
    /// expression is expanded, for the cheat sheet's "recently used"
    /// highlight.
    var onShortcutUsed: ((String) -> Void)?

    var shortcutTable: ShortcutTable?
    private var hasLeaderEntries: Bool {
        shortcutTable?.entries.contains { $0.tier == .leader } ?? false
    }

    /// Non-nil exactly while one math expression is expanded to its raw,
    /// editable source — the range of that raw text within the shared
    /// text storage. Grows/shrinks as the user types.
    private var activeMathRange: NSRange?
    private var activeMathBlockID: UUID?
    private var activeStructureHoleCount: [UUID: Int] = [:]
    private var activePendingLeader = false

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
        typingAttributes = [.font: Self.baseFont, .foregroundColor: NSColor.textColor]
    }

    // MARK: - Loading / reading the document

    func setBlocks(_ blocks: [NoteBlock]) {
        activeMathRange = nil
        activeMathBlockID = nil
        activeStructureHoleCount = [:]
        activePendingLeader = false
        textStorage?.setAttributedString(Self.attributedString(from: blocks))
        typingAttributes = [.font: Self.baseFont, .foregroundColor: NSColor.textColor]
    }

    /// Re-derives `[NoteBlock]` from the live text storage: each
    /// MathInlineAttachment (a collapsed math expression) or
    /// `.mafacActiveMath`-tagged run (one currently expanded) becomes a
    /// `.math` block; everything else accumulates into `.text` blocks
    /// split at those boundaries.
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

        storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { attrs, range, _ in
            if let attachment = attrs[.attachment] as? MathInlineAttachment {
                flushText()
                blocks.append(NoteBlock(id: attachment.blockID, content: .math(latex: attachment.latex)))
            } else if let activeID = attrs[.mafacActiveMath] as? UUID {
                flushText()
                let raw = storage.attributedSubstring(from: range).string
                let latex = raw.replacingOccurrences(of: Self.holePlaceholder, with: "")
                blocks.append(NoteBlock(id: activeID, content: .math(latex: latex)))
            } else {
                textBuffer += storage.attributedSubstring(from: range).string
            }
        }
        flushText()

        return blocks.isEmpty ? [NoteBlock(content: .text(""))] : blocks
    }

    private static func attributedString(from blocks: [NoteBlock]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let attrs: [NSAttributedString.Key: Any] = [.font: baseFont, .foregroundColor: NSColor.textColor]
        for block in blocks {
            switch block.content {
            case .text(let text):
                result.append(NSAttributedString(string: text, attributes: attrs))
            case .math(let latex):
                result.append(NSAttributedString(attachment: MathInlineAttachment(blockID: block.id, latex: latex)))
            }
        }
        if result.length == 0 {
            result.append(NSAttributedString(string: "", attributes: attrs))
        }
        return result
    }

    // MARK: - Starting a new math expression (toolbar button / ⌘M)

    /// Begins a fresh, empty math expression in place at the cursor —
    /// no attachment is inserted up front; if the user clicks away
    /// without typing anything, nothing is left behind.
    func insertMathAttachment() {
        guard let storage = textStorage else { return }
        if activeMathRange != nil { deactivateMathEditing() }

        let range = selectedRange()
        guard shouldChangeText(in: range, replacementString: "") else { return }
        storage.beginEditing()
        storage.replaceCharacters(in: range, with: NSAttributedString(string: "", attributes: mathAttributes()))
        storage.endEditing()

        let blockID = UUID()
        activeMathRange = NSRange(location: range.location, length: 0)
        activeMathBlockID = blockID
        activeStructureHoleCount = [:]

        setSelectedRange(NSRange(location: range.location, length: 0))
        onFocusedMathBlockChanged?(blockID)
    }

    override func didChangeText() {
        super.didChangeText()
        onBlocksChanged?(currentBlocks())
    }

    func latexOfFocusedMathBlock() -> String? {
        guard let range = activeMathRange, let storage = textStorage else { return nil }
        let raw = storage.attributedSubstring(from: range).string
        return raw.replacingOccurrences(of: Self.holePlaceholder, with: "")
    }

    // MARK: - Click to expand / collapse in place

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        if let charIndex = attachmentCharacterIndex(at: point),
           let attachment = textStorage?.attribute(.attachment, at: charIndex, effectiveRange: nil) as? MathInlineAttachment {
            activateMathEditing(for: attachment, at: charIndex)
            return
        }

        if activeMathRange != nil {
            let clickIndex = characterIndexForInsertion(at: point)
            if !isIndexWithinActiveRange(clickIndex) {
                deactivateMathEditing()
            }
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

    private func isIndexWithinActiveRange(_ index: Int) -> Bool {
        guard let activeMathRange else { return false }
        return index >= activeMathRange.location && index <= NSMaxRange(activeMathRange)
    }

    private func activateMathEditing(for attachment: MathInlineAttachment, at charIndex: Int) {
        guard let storage = textStorage else { return }
        if activeMathBlockID == attachment.blockID, activeMathRange != nil { return }
        if activeMathRange != nil { deactivateMathEditing() }

        let (displayText, holeRanges) = Self.expandHoles(in: attachment.latex)
        let structureID = UUID()
        let attrString = NSAttributedString(string: displayText, attributes: mathAttributes())

        guard shouldChangeText(in: NSRange(location: charIndex, length: 1), replacementString: displayText) else { return }
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: charIndex, length: 1), with: attrString)
        if attrString.length > 0 {
            storage.addAttribute(.mafacStructure, value: structureID, range: NSRange(location: charIndex, length: attrString.length))
        }
        for (idx, hole) in holeRanges.enumerated() {
            storage.addAttribute(.mafacHole, value: idx, range: NSRange(location: charIndex + hole.location, length: hole.length))
        }
        storage.endEditing()

        let newRange = NSRange(location: charIndex, length: attrString.length)
        activeMathRange = newRange
        activeMathBlockID = attachment.blockID
        activeStructureHoleCount = [structureID: holeRanges.count]
        applyActiveMathAttribute(over: newRange)

        didChangeText()
        onFocusedMathBlockChanged?(attachment.blockID)

        if let firstHole = holeRanges.first {
            setSelectedRange(NSRange(location: charIndex + firstHole.location, length: firstHole.length))
        } else {
            setSelectedRange(NSRange(location: charIndex + attrString.length, length: 0))
        }
        window?.makeFirstResponder(self)
    }

    private func deactivateMathEditing() {
        guard let range = activeMathRange, let blockID = activeMathBlockID, let storage = textStorage else { return }
        let raw = range.length > 0 ? storage.attributedSubstring(from: range).string : ""
        let latex = raw.replacingOccurrences(of: Self.holePlaceholder, with: "")

        activeMathRange = nil
        activeMathBlockID = nil
        activeStructureHoleCount = [:]
        activePendingLeader = false

        guard shouldChangeText(in: range, replacementString: "") else { return }

        if latex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            storage.beginEditing()
            storage.replaceCharacters(in: range, with: "")
            storage.endEditing()
            setSelectedRange(NSRange(location: range.location, length: 0))
        } else {
            let attachment = MathInlineAttachment(blockID: blockID, latex: latex)
            let replacement = NSAttributedString(attachment: attachment)
            storage.beginEditing()
            storage.replaceCharacters(in: range, with: replacement)
            storage.endEditing()
            setSelectedRange(NSRange(location: range.location + replacement.length, length: 0))
        }
        didChangeText()
        onFocusedMathBlockChanged?(nil)
    }

    // MARK: - Keystroke interpretation while a math expression is expanded

    override func insertText(_ string: Any, replacementRange: NSRange) {
        guard activeMathRange != nil else {
            super.insertText(string, replacementRange: replacementRange)
            return
        }

        let text: String
        if let s = string as? String { text = s }
        else if let attr = string as? NSAttributedString { text = attr.string }
        else { text = "" }
        guard !text.isEmpty else { return }

        let effectiveRange = replacementRange.location == NSNotFound ? selectedRange() : replacementRange
        guard isRangeWithinActive(effectiveRange) else {
            deactivateMathEditing()
            super.insertText(string, replacementRange: replacementRange)
            return
        }

        if activePendingLeader {
            activePendingLeader = false
            if text.count == 1, let table = shortcutTable, let entry = table.entry(forTrigger: ";" + text) {
                insertMathShortcut(entry, at: effectiveRange)
            } else {
                insertMathLiteral(";", at: effectiveRange)
                insertMathLiteral(text, at: selectedRange())
            }
            return
        }
        if text == ";" && hasLeaderEntries {
            activePendingLeader = true
            return
        }
        if text.count == 1, let table = shortcutTable, let entry = table.entry(forTrigger: text) {
            insertMathShortcut(entry, at: effectiveRange)
            return
        }
        insertMathLiteral(text, at: effectiveRange)
    }

    override func insertNewline(_ sender: Any?) {
        if activeMathRange != nil {
            deactivateMathEditing()
            return
        }
        super.insertNewline(sender)
    }

    override func cancelOperation(_ sender: Any?) {
        if activePendingLeader {
            activePendingLeader = false
            return
        }
        if activeMathRange != nil {
            deactivateMathEditing()
            return
        }
        super.cancelOperation(sender)
    }

    private func isRangeWithinActive(_ range: NSRange) -> Bool {
        guard let activeMathRange else { return false }
        return range.location >= activeMathRange.location && NSMaxRange(range) <= NSMaxRange(activeMathRange)
    }

    private func mathAttributes() -> [NSAttributedString.Key: Any] {
        [.font: Self.mathFont, .foregroundColor: NSColor.textColor, .backgroundColor: Self.mathHighlight]
    }

    private func applyActiveMathAttribute(over range: NSRange) {
        guard let storage = textStorage, let blockID = activeMathBlockID, range.length > 0 else { return }
        storage.addAttribute(.mafacActiveMath, value: blockID, range: range)
    }

    private func growActiveRange(by delta: Int) {
        guard let activeMathRange else { return }
        let newRange = NSRange(location: activeMathRange.location, length: max(0, activeMathRange.length + delta))
        self.activeMathRange = newRange
        applyActiveMathAttribute(over: newRange)
    }

    private func insertMathShortcut(_ entry: ShortcutEntry, at range: NSRange) {
        guard let storage = textStorage else { return }
        let structureID = UUID()
        let (snippetText, holeRanges) = Self.expandHoles(in: entry.latex)
        let snippet = NSAttributedString(string: snippetText, attributes: mathAttributes())

        guard shouldChangeText(in: range, replacementString: snippet.string) else { return }
        storage.beginEditing()
        storage.replaceCharacters(in: range, with: snippet)
        if snippet.length > 0 {
            storage.addAttribute(.mafacStructure, value: structureID, range: NSRange(location: range.location, length: snippet.length))
        }
        for (idx, hole) in holeRanges.enumerated() {
            storage.addAttribute(.mafacHole, value: idx, range: NSRange(location: range.location + hole.location, length: hole.length))
        }
        storage.endEditing()

        growActiveRange(by: snippet.length - range.length)
        activeStructureHoleCount[structureID] = holeRanges.count
        didChangeText()
        onShortcutUsed?(entry.id)

        if let firstHole = holeRanges.first {
            setSelectedRange(NSRange(location: range.location + firstHole.location, length: firstHole.length))
        } else {
            setSelectedRange(NSRange(location: range.location + snippet.length, length: 0))
        }
    }

    private func insertMathLiteral(_ text: String, at range: NSRange) {
        guard let storage = textStorage else { return }
        var attrs = mathAttributes()
        attrs[.mafacHole] = nil
        if let structID = structureContainingOpenHole(at: range.location, storage: storage) {
            attrs[.mafacStructure] = structID
        }

        guard shouldChangeText(in: range, replacementString: text) else { return }
        storage.beginEditing()
        storage.replaceCharacters(in: range, with: NSAttributedString(string: text, attributes: attrs))
        storage.endEditing()

        growActiveRange(by: (text as NSString).length - range.length)
        didChangeText()
        setSelectedRange(NSRange(location: range.location + (text as NSString).length, length: 0))
    }

    private func structureContainingOpenHole(at location: Int, storage: NSTextStorage) -> UUID? {
        guard let activeMathRange else { return nil }
        guard location > activeMathRange.location, location < NSMaxRange(activeMathRange) else { return nil }
        guard let before = storage.attribute(.mafacStructure, at: location - 1, effectiveRange: nil) as? UUID else { return nil }
        guard let after = storage.attribute(.mafacStructure, at: location, effectiveRange: nil) as? UUID else { return nil }
        return before == after ? before : nil
    }

    // MARK: - Hole navigation (Tab / Shift-Tab), bounded to the active range

    override func insertTab(_ sender: Any?) {
        guard activeMathRange != nil else {
            super.insertTab(sender)
            return
        }
        if let next = rangeOfHole(strictlyAfter: selectedRange().location) {
            setSelectedRange(next)
        }
    }

    override func insertBacktab(_ sender: Any?) {
        guard activeMathRange != nil else {
            super.insertBacktab(sender)
            return
        }
        if let prev = rangeOfHole(strictlyBefore: selectedRange().location) {
            setSelectedRange(prev)
        }
    }

    private func rangeOfHole(strictlyAfter location: Int) -> NSRange? {
        guard let activeMathRange, let storage = textStorage, activeMathRange.length > 0 else { return nil }
        var found: NSRange?
        storage.enumerateAttribute(.mafacHole, in: activeMathRange, options: []) { value, range, stop in
            guard value != nil else { return }
            if range.location > location {
                found = range
                stop.pointee = true
            }
        }
        return found
    }

    private func rangeOfHole(strictlyBefore location: Int) -> NSRange? {
        guard let activeMathRange, let storage = textStorage, activeMathRange.length > 0 else { return nil }
        var found: NSRange?
        storage.enumerateAttribute(.mafacHole, in: activeMathRange, options: [.reverse]) { value, range, stop in
            guard value != nil else { return }
            if range.location < location {
                found = range
                stop.pointee = true
            }
        }
        return found
    }

    // MARK: - Structured backspace / delete, bounded to the active range

    override func deleteBackward(_ sender: Any?) {
        guard let activeMathRange, let storage = textStorage else {
            super.deleteBackward(sender)
            return
        }
        let sel = selectedRange()
        guard isRangeWithinActive(sel) else {
            super.deleteBackward(sender)
            return
        }

        if sel.length > 0 {
            if storage.attribute(.mafacHole, at: sel.location, effectiveRange: nil) != nil,
               let structRange = clampedStructureRange(at: sel.location, storage: storage),
               structureIsUnedited(structRange) {
                replaceActive(range: structRange, with: "")
                return
            }
            replaceActive(range: sel, with: "")
            return
        }

        let caret = sel.location
        guard caret > activeMathRange.location else { return }

        if let structRange = enclosingStructureRange(endingAt: caret, storage: storage), structureIsUnedited(structRange) {
            replaceActive(range: structRange, with: "")
            return
        }
        replaceActive(range: NSRange(location: caret - 1, length: 1), with: "")
    }

    override func deleteForward(_ sender: Any?) {
        guard let activeMathRange, let storage = textStorage else {
            super.deleteForward(sender)
            return
        }
        let sel = selectedRange()
        guard isRangeWithinActive(sel) else {
            super.deleteForward(sender)
            return
        }

        if sel.length > 0 {
            replaceActive(range: sel, with: "")
            return
        }

        let caret = sel.location
        guard caret < NSMaxRange(activeMathRange) else { return }

        if let structRange = enclosingStructureRange(startingAt: caret, storage: storage), structureIsUnedited(structRange) {
            replaceActive(range: structRange, with: "")
            return
        }
        replaceActive(range: NSRange(location: caret, length: 1), with: "")
    }

    private func replaceActive(range: NSRange, with text: String) {
        guard let storage = textStorage else { return }
        guard shouldChangeText(in: range, replacementString: text) else { return }
        storage.beginEditing()
        storage.replaceCharacters(in: range, with: text)
        storage.endEditing()
        growActiveRange(by: (text as NSString).length - range.length)
        didChangeText()
        setSelectedRange(NSRange(location: range.location, length: 0))
    }

    private func clampedStructureRange(at location: Int, storage: NSTextStorage) -> NSRange? {
        guard let activeMathRange else { return nil }
        var range = NSRange(location: 0, length: 0)
        guard storage.attribute(.mafacStructure, at: location, effectiveRange: &range) != nil else { return nil }
        return range.intersection(activeMathRange)
    }

    private func enclosingStructureRange(endingAt location: Int, storage: NSTextStorage) -> NSRange? {
        guard let activeMathRange, location > activeMathRange.location, location <= NSMaxRange(activeMathRange) else { return nil }
        var range = NSRange(location: 0, length: 0)
        guard storage.attribute(.mafacStructure, at: location - 1, effectiveRange: &range) != nil else { return nil }
        guard range.location + range.length == location else { return nil }
        return range
    }

    private func enclosingStructureRange(startingAt location: Int, storage: NSTextStorage) -> NSRange? {
        guard let activeMathRange, location < NSMaxRange(activeMathRange) else { return nil }
        var range = NSRange(location: 0, length: 0)
        guard storage.attribute(.mafacStructure, at: location, effectiveRange: &range) != nil else { return nil }
        guard range.location == location else { return nil }
        return range
    }

    private func structureIsUnedited(_ range: NSRange) -> Bool {
        guard let storage = textStorage, range.length > 0 else { return false }
        guard let structID = storage.attribute(.mafacStructure, at: range.location, effectiveRange: nil) as? UUID else { return false }
        let holeCount = activeStructureHoleCount[structID] ?? 0
        if holeCount == 0 { return true }

        var lastHoleStillPlaceholder = false
        storage.enumerateAttribute(.mafacHole, in: range, options: []) { value, _, stop in
            if let idx = value as? Int, idx == holeCount - 1 {
                lastHoleStillPlaceholder = true
                stop.pointee = true
            }
        }
        return lastHoleStillPlaceholder
    }

    // MARK: - Hole-placeholder expansion (shared by fresh shortcuts and re-expanding existing latex)

    /// Parses a latex string (either a fresh `ShortcutEntry.latex`
    /// template or an existing block's stored latex) and replaces each
    /// empty "{}" group with "{▢}", recording the placeholder's range
    /// (relative to the result's own start) as a hole, in order.
    private static func expandHoles(in raw: String) -> (text: String, holeRanges: [NSRange]) {
        var result = ""
        var holeRanges: [NSRange] = []
        var i = raw.startIndex
        while i < raw.endIndex {
            let c = raw[i]
            if c == "{" {
                let next = raw.index(after: i)
                if next < raw.endIndex, raw[next] == "}" {
                    result.append("{")
                    let holeStart = (result as NSString).length
                    result.append(holePlaceholder)
                    holeRanges.append(NSRange(location: holeStart, length: (holePlaceholder as NSString).length))
                    result.append("}")
                    i = raw.index(after: next)
                    continue
                }
            }
            result.append(c)
            i = raw.index(after: i)
        }
        return (result, holeRanges)
    }
}
