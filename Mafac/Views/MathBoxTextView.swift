//
//  MathBoxTextView.swift
//  Mafac
//
//  The little box: a small, self-contained NSTextView hosted inside
//  MathEditPopover, used to edit ONE math expression's raw LaTeX. Its
//  visible text IS the raw LaTeX source (e.g. typing "f" inserts the
//  literal characters "\frac{▢}{▢}"), never a live-typeset rendering —
//  turning that back into canonical latex is therefore trivial (strip
//  hole placeholders), which is the whole point: the previous design
//  tried to reconstruct latex from richly-typeset, restyled text and
//  that reconstruction broke in exactly the cases (^{}, \sqrt{}) users
//  hit first.
//
//  Ported from the pre-refactor MathBlockTextView (git history, commit
//  cc2cc2b), which owned its own standalone text view the same way this
//  one does — the only real differences are: no live-render debounce (no
//  separate preview view to feed here), and `loadExisting(latex:)` to
//  seed the box when re-opening an already-committed expression.
//

import AppKit

extension NSAttributedString.Key {
    /// UUID (per shortcut-inserted snippet) shared by all characters that
    /// belong to that snippet, including content later typed into its
    /// holes. Used to find structure boundaries for atomic backspace.
    static let mafacStructure = NSAttributedString.Key("MafacStructure")

    /// Int hole index, present only on a hole's placeholder character
    /// while it hasn't been typed into yet. Used for Tab navigation and
    /// to tell whether a structure is still "fresh".
    static let mafacHole = NSAttributedString.Key("MafacHole")
}

final class MathBoxTextView: NSTextView {

    /// Placeholder glyph shown inside an empty hole, e.g. "\sqrt{▢}".
    static let holePlaceholder = "▢"

    /// Called synchronously with a `ShortcutEntry.id` every time a
    /// shortcut is successfully inserted, for the cheat sheet's
    /// "recently used" highlight.
    var onShortcutUsed: ((String) -> Void)?

    /// Fired when Return is pressed — MathEditPopover commits and closes.
    var onCommitKey: (() -> Void)?

    /// Fired when Escape is pressed (and there's no pending leader to
    /// cancel instead) — MathEditPopover closes (which still commits;
    /// see its doc comment for why there's no separate discard gesture).
    var onCancelKey: (() -> Void)?

    /// Fired after every content change — MathEditPopover uses it to grow
    /// the popover so a long expression stays visible while it's typed.
    var onTextChanged: (() -> Void)?

    var shortcutTable: ShortcutTable? {
        didSet {
            hasLeaderEntries = shortcutTable?.entries.contains { $0.tier == .leader } ?? false
        }
    }
    private var hasLeaderEntries = false

    /// True after the user has pressed the leader key (";") and we're
    /// waiting for the next keystroke to complete a tier-2 sequence.
    private var pendingLeader = false

    /// Total hole count recorded at insertion time for each structure ID,
    /// so backspace can tell "no holes at all" (e.g. \pi, always atomic)
    /// apart from "holes exist but have been filled".
    private var structureHoleCount: [UUID: Int] = [:]

    // MARK: - Setup

    func configureForMathInput() {
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        isAutomaticDataDetectionEnabled = false
        isAutomaticLinkDetectionEnabled = false
        smartInsertDeleteEnabled = false
        isRichText = false
        allowsUndo = true
        font = NSFont.monospacedSystemFont(ofSize: 17, weight: .regular)
        textColor = .labelColor
    }

    /// Every mutation path in this view — `insertText`, shortcut
    /// insertion, backspace over a structure, `loadExisting` — funnels
    /// through `didChangeText()`, so overriding it here is the one place
    /// that catches them all.
    override func didChangeText() {
        super.didChangeText()
        onTextChanged?()
    }

    // MARK: - Keystroke interpretation

    override func insertText(_ string: Any, replacementRange: NSRange) {
        let text: String
        if let s = string as? String {
            text = s
        } else if let attr = string as? NSAttributedString {
            text = attr.string
        } else {
            text = ""
        }
        guard !text.isEmpty else { return }

        let effectiveRange = replacementRange.location == NSNotFound ? selectedRange() : replacementRange

        if pendingLeader {
            pendingLeader = false
            if let table = shortcutTable, let entry = table.entry(forTrigger: ";" + text) {
                insertShortcut(entry)
            } else {
                insertLiteral(";", replacementRange: effectiveRange)
                insertLiteral(text, replacementRange: nil)
            }
            return
        }

        if text == ";" && hasLeaderEntries {
            pendingLeader = true
            return
        }

        if text.count == 1, let table = shortcutTable, let entry = table.entry(forTrigger: text) {
            insertShortcut(entry)
            return
        }

        insertLiteral(text, replacementRange: effectiveRange)
    }

    override func insertNewline(_ sender: Any?) {
        onCommitKey?()
    }

    override func cancelOperation(_ sender: Any?) {
        if pendingLeader {
            pendingLeader = false
            return
        }
        onCancelKey?()
    }

    // MARK: - Shortcut insertion

    private func insertShortcut(_ entry: ShortcutEntry) {
        guard let storage = textStorage else { return }
        let insertRange = selectedRange()
        let structureID = UUID()
        let attrs = baseAttributes(inheritingStructureAt: insertRange.location)
        let (snippet, holeRanges) = Self.buildSnippet(for: Self.terminated(entry.latex), typingAttributes: attrs)

        guard shouldChangeText(in: insertRange, replacementString: snippet.string) else { return }

        storage.beginEditing()
        storage.replaceCharacters(in: insertRange, with: snippet)
        storage.addAttribute(
            .mafacStructure,
            value: structureID,
            range: NSRange(location: insertRange.location, length: snippet.length)
        )
        for (idx, hole) in holeRanges.enumerated() {
            storage.addAttribute(
                .mafacHole,
                value: idx,
                range: NSRange(location: insertRange.location + hole.location, length: hole.length)
            )
        }
        storage.endEditing()
        didChangeText()

        structureHoleCount[structureID] = holeRanges.count
        onShortcutUsed?(entry.id)
        selectFirstHole(in: holeRanges, offsetBy: insertRange.location, elseCaretAt: insertRange.location + snippet.length)
    }

    /// Appends the space that terminates a bare control word like
    /// `\partial`, so that whatever the user types next can't glue itself
    /// onto the command name — without it, `;D` followed by `y` produces
    /// the source `\partialy`, which is a different (undefined) command
    /// rather than ∂ applied to y. Snippets that end in a brace group
    /// (`\frac{}{}`, `\int_{}^{}`) or punctuation (`^{}`) already
    /// self-terminate and are returned unchanged.
    ///
    /// Only applied on fresh insertion, never in `buildSnippet` itself:
    /// that is shared with `loadExisting(latex:)`, which would otherwise
    /// append another space to an already-terminated command every time a
    /// box is reopened.
    private static func terminated(_ latex: String) -> String {
        guard latex.hasPrefix("\\"), let last = latex.last, last.isLetter else { return latex }
        return latex + " "
    }

    /// Parses a latex snippet (e.g. "\frac{}{}" from a fresh
    /// `ShortcutEntry`, or existing filled-in latex from
    /// `loadExisting(latex:)`) and builds the attributed string to
    /// insert, replacing each empty "{}" group with "{▢}" and recording
    /// the placeholder's range (relative to the snippet's own start) as
    /// a hole, in order.
    private static func buildSnippet(
        for latex: String,
        typingAttributes: [NSAttributedString.Key: Any]
    ) -> (NSAttributedString, [NSRange]) {
        var result = ""
        var holeRanges: [NSRange] = []
        var i = latex.startIndex
        while i < latex.endIndex {
            let c = latex[i]
            if c == "{" {
                let next = latex.index(after: i)
                if next < latex.endIndex, latex[next] == "}" {
                    result.append("{")
                    let holeStart = (result as NSString).length
                    result.append(holePlaceholder)
                    holeRanges.append(NSRange(location: holeStart, length: (holePlaceholder as NSString).length))
                    result.append("}")
                    i = latex.index(after: next)
                    continue
                }
            }
            result.append(c)
            i = latex.index(after: i)
        }
        let attributed = NSAttributedString(string: result, attributes: typingAttributes)
        return (attributed, holeRanges)
    }

    // MARK: - Literal insertion (fallthrough for anything not in the table)

    private func insertLiteral(_ text: String, replacementRange: NSRange?) {
        guard let storage = textStorage else { return }
        let range = replacementRange ?? selectedRange()
        var attrs = baseAttributes(inheritingStructureAt: range.location)
        attrs[.mafacHole] = nil

        guard shouldChangeText(in: range, replacementString: text) else { return }

        storage.beginEditing()
        storage.replaceCharacters(in: range, with: NSAttributedString(string: text, attributes: attrs))
        storage.endEditing()
        didChangeText()

        setSelectedRange(NSRange(location: range.location + (text as NSString).length, length: 0))
    }

    /// Typing attributes (font/color) plus, if the insertion point is
    /// genuinely still inside one of a structure's open holes, that
    /// structure's ID — so content typed into a hole stays associated
    /// with the structure it belongs to.
    private func baseAttributes(inheritingStructureAt location: Int) -> [NSAttributedString.Key: Any] {
        var attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.monospacedSystemFont(ofSize: 17, weight: .regular),
            .foregroundColor: NSColor.labelColor
        ]
        if let storage = textStorage, let structID = structureContainingOpenHole(at: location, storage: storage) {
            attrs[.mafacStructure] = structID
        }
        return attrs
    }

    /// Returns the structure ID `location` sits inside, but ONLY if it's
    /// genuinely sandwiched between two characters that still belong to
    /// that same structure — see MathBlockTextView's original doc
    /// comment (git history) for why symmetric matching prevents a leaf
    /// shortcut's tag from bleeding into whatever gets typed after it.
    private func structureContainingOpenHole(at location: Int, storage: NSTextStorage) -> Any? {
        guard location > 0, location < storage.length else { return nil }
        guard let before = storage.attribute(.mafacStructure, at: location - 1, effectiveRange: nil) as? UUID else {
            return nil
        }
        guard let after = storage.attribute(.mafacStructure, at: location, effectiveRange: nil) as? UUID else {
            return nil
        }
        return before == after ? before : nil
    }

    // MARK: - Hole navigation (Tab / Shift-Tab)

    override func insertTab(_ sender: Any?) {
        if let next = rangeOfHole(strictlyAfter: selectedRange().location) {
            setSelectedRange(next)
        } else {
            window?.selectNextKeyView(self)
        }
    }

    override func insertBacktab(_ sender: Any?) {
        if let prev = rangeOfHole(strictlyBefore: selectedRange().location) {
            setSelectedRange(prev)
        } else {
            window?.selectPreviousKeyView(self)
        }
    }

    private func rangeOfHole(strictlyAfter location: Int) -> NSRange? {
        guard let storage = textStorage, storage.length > 0 else { return nil }
        var found: NSRange?
        storage.enumerateAttribute(.mafacHole, in: NSRange(location: 0, length: storage.length), options: []) { value, range, stop in
            guard value != nil else { return }
            if range.location > location {
                found = range
                stop.pointee = true
            }
        }
        return found
    }

    private func rangeOfHole(strictlyBefore location: Int) -> NSRange? {
        guard let storage = textStorage, storage.length > 0 else { return nil }
        var found: NSRange?
        storage.enumerateAttribute(.mafacHole, in: NSRange(location: 0, length: storage.length), options: [.reverse]) { value, range, stop in
            guard value != nil else { return }
            if range.location < location {
                found = range
                stop.pointee = true
            }
        }
        return found
    }

    private func selectFirstHole(in holeRanges: [NSRange], offsetBy base: Int, elseCaretAt caret: Int) {
        if let firstHole = holeRanges.first {
            setSelectedRange(NSRange(location: base + firstHole.location, length: firstHole.length))
        } else {
            setSelectedRange(NSRange(location: caret, length: 0))
        }
    }

    // MARK: - Structured backspace / delete

    override func deleteBackward(_ sender: Any?) {
        guard let storage = textStorage else {
            super.deleteBackward(sender)
            return
        }
        let sel = selectedRange()

        if sel.length > 0 {
            var structRange = NSRange(location: 0, length: 0)
            if storage.attribute(.mafacHole, at: sel.location, effectiveRange: nil) != nil,
               storage.attribute(.mafacStructure, at: sel.location, effectiveRange: &structRange) != nil,
               structureIsUnedited(structRange) {
                replaceAndCollapse(range: structRange, with: "")
                return
            }
            replaceAndCollapse(range: sel, with: "")
            return
        }

        let caret = sel.location
        guard caret > 0 else { return }

        if let structRange = enclosingStructureRange(endingAt: caret), structureIsUnedited(structRange) {
            replaceAndCollapse(range: structRange, with: "")
            return
        }

        replaceAndCollapse(range: NSRange(location: caret - 1, length: 1), with: "")
    }

    override func deleteForward(_ sender: Any?) {
        guard let storage = textStorage else {
            super.deleteForward(sender)
            return
        }
        let sel = selectedRange()

        if sel.length > 0 {
            replaceAndCollapse(range: sel, with: "")
            return
        }

        let caret = sel.location
        guard caret < storage.length else { return }

        if let structRange = enclosingStructureRange(startingAt: caret), structureIsUnedited(structRange) {
            replaceAndCollapse(range: structRange, with: "")
            return
        }

        replaceAndCollapse(range: NSRange(location: caret, length: 1), with: "")
    }

    private func replaceAndCollapse(range: NSRange, with text: String) {
        guard let storage = textStorage else { return }
        guard shouldChangeText(in: range, replacementString: text) else { return }
        storage.beginEditing()
        storage.replaceCharacters(in: range, with: text)
        storage.endEditing()
        didChangeText()
        setSelectedRange(NSRange(location: range.location, length: 0))
    }

    private func enclosingStructureRange(endingAt location: Int) -> NSRange? {
        guard let storage = textStorage, location > 0, location <= storage.length else { return nil }
        var range = NSRange(location: 0, length: 0)
        guard storage.attribute(.mafacStructure, at: location - 1, effectiveRange: &range) != nil else { return nil }
        guard range.location + range.length == location else { return nil }
        return range
    }

    private func enclosingStructureRange(startingAt location: Int) -> NSRange? {
        guard let storage = textStorage, location < storage.length else { return nil }
        var range = NSRange(location: 0, length: 0)
        guard storage.attribute(.mafacStructure, at: location, effectiveRange: &range) != nil else { return nil }
        guard range.location == location else { return nil }
        return range
    }

    /// A structure is "unedited" (safe to delete atomically) if it has no
    /// holes at all (a leaf snippet like \pi — always atomic), or if its
    /// last hole (by index) still carries an unedited placeholder.
    private func structureIsUnedited(_ range: NSRange) -> Bool {
        guard let storage = textStorage, range.length > 0 else { return false }
        guard let structID = storage.attribute(.mafacStructure, at: range.location, effectiveRange: nil) as? UUID else {
            return false
        }
        let holeCount = structureHoleCount[structID] ?? 0
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

    // MARK: - Loading an existing expression for re-editing

    /// Seeds the box with an already-committed expression's raw latex —
    /// every empty "{}" group becomes a selectable "▢" hole (recursing
    /// into non-empty groups so nested empty groups still get holes),
    /// everything else is inserted literally. Left untagged with
    /// `.mafacStructure`/`.mafacCommand` — atomic-backspace grouping only
    /// matters for shortcuts typed fresh during this edit, not for
    /// pre-existing content, which does not need that structure to be
    /// safely editable.
    func loadExisting(latex: String) {
        guard let storage = textStorage else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.monospacedSystemFont(ofSize: 17, weight: .regular),
            .foregroundColor: NSColor.labelColor
        ]
        let (snippet, holeRanges) = Self.buildSnippet(for: latex, typingAttributes: attrs)
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: snippet)
        for hole in holeRanges {
            storage.addAttribute(.mafacHole, value: 0, range: hole)
        }
        storage.endEditing()
    }

    /// Places the caret appropriately after the box is first shown:
    /// jumps into the first hole for a fresh (empty-until-now) box, or
    /// to the very end for a re-opened existing expression (no auto
    /// hole-jump — re-editing is usually appending/fixing, not landing
    /// in an arbitrary hole).
    func selectFirstHoleOrEnd(hadInitialContent: Bool) {
        guard let storage = textStorage else { return }
        if !hadInitialContent, let firstHole = rangeOfHole(strictlyAfter: -1) {
            setSelectedRange(firstHole)
        } else {
            setSelectedRange(NSRange(location: storage.length, length: 0))
        }
    }

    // MARK: - Derived LaTeX

    /// The box's current LaTeX string, with hole placeholders stripped
    /// (an untouched "\frac{▢}{▢}" becomes the syntactically-valid,
    /// visually-empty "\frac{}{}").
    func currentLatexString() -> String {
        guard let storage = textStorage else { return "" }
        return storage.string.replacingOccurrences(of: Self.holePlaceholder, with: "")
    }
}
