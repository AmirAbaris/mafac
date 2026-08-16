//
//  MathBlockTextView.swift
//  Mafac
//
//  Phase 1: custom NSTextView subclass that turns keystrokes inside a math
//  block into LaTeX, using ShortcutTable (Models/ShortcutTable.swift) for
//  the trigger -> snippet lookup.
//
//  Design notes (read this before touching backspace/hole logic):
//
//  - The text view's visible text IS the raw LaTeX source (e.g. typing "f"
//    inserts the literal characters "\frac{▢}{▢}"), not a rendered
//    equation — rendering happens in the adjacent MathRenderView, fed by
//    `currentLatexString()` with hole placeholders stripped out.
//    "▢" (U+25A2 WHITE SQUARE WITH ROUNDED CORNERS) marks an empty hole.
//  - Two custom NSAttributedString attributes track structure, applied
//    directly on the live NSTextStorage rather than a separate side-model
//    that would have to be kept in sync by hand:
//      .mafacStructure — a UUID shared by every character of one
//        shortcut-inserted snippet (including any real content later typed
//        into its holes), so we can find its boundaries at any time.
//      .mafacHole — an Int hole index (0, 1, ...), applied ONLY to a
//        hole's placeholder character while it is still unedited. The
//        moment real content replaces the placeholder the attribute is
//        gone with it — that's how a "filled" hole is detected.
//    Each shortcut insertion claims its whole range with a single fresh
//    structure ID (nesting isn't tracked as a stack) — simple and correct
//    for the common single-level case; a shortcut typed inside another
//    shortcut's hole "adopts" the inner content as its own structure and
//    the outer structure's tag on that stretch of text is overwritten.
//  - Tab / Shift-Tab move the selection to the next/previous character
//    still carrying `.mafacHole`, found via a linear scan of the text
//    storage. Simple, and correct-by-construction since it's derived
//    fresh every time rather than tracked incrementally.
//  - Backspace deletes an entire shortcut-inserted structure in one press
//    when either (a) the caret sits exactly at the end of a structure
//    whose last hole is still unedited (or which has no holes at all,
//    e.g. "\pi" — always atomic), or (b) the current selection is itself
//    an unedited hole placeholder belonging to a structure that's still
//    fully untouched. Once real content has been committed, backspace
//    reverts to normal single-character deletion so editing inside a
//    filled structure isn't destructive.
//
//  Known limitation: there is no working Xcode/xcodebuild in the
//  environment this was written in (see PLAN.md Phase 1 note), so this
//  has been reasoned through carefully against the documented AppKit
//  APIs but not exercised interactively. Arrow-key navigation relies on
//  NSTextView's default selection-collapse behavior (pressing an arrow
//  key while a hole's placeholder is selected collapses to that edge)
//  rather than custom overrides — sensible for the common case, not
//  exhaustively tested. Undo grouping for shortcut-structural edits is
//  wired via shouldChangeText/didChangeText but not verified.
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

final class MathBlockTextView: NSTextView {

    /// Placeholder glyph shown inside an empty hole, e.g. "\sqrt{▢}".
    static let holePlaceholder = "▢"

    /// Called (debounced ~120ms) whenever the derived LaTeX string
    /// changes, with hole placeholders already stripped out.
    var onLatexChanged: ((String) -> Void)?

    /// Called synchronously (not debounced) with a `ShortcutEntry.id`
    /// every time a shortcut is successfully inserted. Phase 2's
    /// cheat-sheet uses this to briefly highlight the matching row.
    var onShortcutUsed: ((String) -> Void)?

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

    private var renderDebounceTimer: Timer?
    private let renderDebounceInterval: TimeInterval = 0.12

    // MARK: - Setup

    /// Call once after creating the text view (there is no NIB, so
    /// awakeFromNib never fires for a programmatically-created instance).
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

        // AppKit passes {NSNotFound, 0} here when there's no marked (IME
        // composition) text to replace, which is the common case for
        // plain typing — normalize that to "replace the current
        // selection" so we never hand NSNotFound to NSTextStorage.
        let effectiveRange = replacementRange.location == NSNotFound ? selectedRange() : replacementRange

        if pendingLeader {
            pendingLeader = false
            if let table = shortcutTable, let entry = table.entry(forTrigger: ";" + text) {
                insertShortcut(entry)
            } else {
                // Not a recognized leader sequence — fall back to typing
                // the leader character and the following key literally
                // rather than silently swallowing both.
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

    override func cancelOperation(_ sender: Any?) {
        if pendingLeader {
            pendingLeader = false
            return
        }
        super.cancelOperation(sender)
    }

    // MARK: - Shortcut insertion

    private func insertShortcut(_ entry: ShortcutEntry) {
        guard let storage = textStorage else { return }
        let insertRange = selectedRange()
        let structureID = UUID()
        let attrs = baseAttributes(inheritingStructureAt: insertRange.location)
        let (snippet, holeRanges) = Self.buildSnippet(for: entry, typingAttributes: attrs)

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

        if let firstHole = holeRanges.first {
            setSelectedRange(NSRange(location: insertRange.location + firstHole.location, length: firstHole.length))
        } else {
            setSelectedRange(NSRange(location: insertRange.location + snippet.length, length: 0))
        }
        scheduleRenderDebounced()
    }

    /// Parses a latex snippet from ShortcutTable.json (e.g. "\frac{}{}")
    /// and builds the attributed string to insert, replacing each empty
    /// "{}" group with "{▢}" and recording the placeholder's range
    /// (relative to the snippet's own start) as a hole, in order.
    private static func buildSnippet(
        for entry: ShortcutEntry,
        typingAttributes: [NSAttributedString.Key: Any]
    ) -> (NSAttributedString, [NSRange]) {
        let base = entry.latex
        var result = ""
        var holeRanges: [NSRange] = []
        var i = base.startIndex
        while i < base.endIndex {
            let c = base[i]
            if c == "{" {
                let next = base.index(after: i)
                if next < base.endIndex, base[next] == "}" {
                    result.append("{")
                    let holeStart = (result as NSString).length
                    result.append(holePlaceholder)
                    holeRanges.append(NSRange(location: holeStart, length: (holePlaceholder as NSString).length))
                    result.append("}")
                    i = base.index(after: next)
                    continue
                }
            }
            result.append(c)
            i = base.index(after: i)
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
        scheduleRenderDebounced()
    }

    /// Typing attributes (font/color) plus, if the insertion point is
    /// genuinely still inside one of a structure's open holes, that
    /// structure's ID — so content typed into a hole stays associated
    /// with the structure it belongs to.
    private func baseAttributes(inheritingStructureAt location: Int) -> [NSAttributedString.Key: Any] {
        var attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.monospacedSystemFont(ofSize: 15, weight: .regular),
            .foregroundColor: NSColor.labelColor
        ]
        if let storage = textStorage, let structID = structureContainingOpenHole(at: location, storage: storage) {
            attrs[.mafacStructure] = structID
        }
        return attrs
    }

    /// Returns the structure ID that `location` sits inside, but ONLY if
    /// it's genuinely sandwiched between two characters that still belong
    /// to that same structure (one on each side) — i.e. still inside an
    /// unclosed hole, not merely typed right after the structure's last
    /// character.
    ///
    /// This distinction matters because `NSAttributedString.attribute(at:
    /// effectiveRange:)` merges contiguous runs sharing an equal value: if
    /// we inherited `.mafacStructure` from just the *preceding* character
    /// alone, then once a leaf shortcut with zero holes (e.g. "\pi",
    /// "\alpha", "\times" — most of ShortcutTable.json) is inserted, any
    /// ordinary text typed right after it would keep getting tagged with
    /// that same structure ID forever, since nothing would ever stop the
    /// merge. `structureIsUnedited`'s zero-hole branch would then treat
    /// that entire merged run as "the leaf, still untouched", and a
    /// single Backspace would silently wipe out all of it, not just the
    /// leaf. Requiring agreement on *both* sides means a leaf's tag can
    /// never spread past its own last character (nothing typed after it
    /// is ever tagged with its ID, so nothing there can match on the far
    /// side), while multi-hole structures still correctly propagate their
    /// tag to newly typed hole content sitting between an unclosed "{"
    /// and its matching "}".
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

    // MARK: - Structured backspace / delete

    override func deleteBackward(_ sender: Any?) {
        guard let storage = textStorage else {
            super.deleteBackward(sender)
            return
        }
        let sel = selectedRange()

        if sel.length > 0 {
            // If the current selection is itself an unedited hole
            // placeholder belonging to a structure that hasn't been
            // touched since insertion, nuke the whole structure rather
            // than just the placeholder character — this is the common
            // "typed a shortcut, changed my mind, backspace" case.
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
        scheduleRenderDebounced()
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

    // MARK: - Derived LaTeX + debounced render

    /// The math block's current LaTeX string, with hole placeholders
    /// stripped to empty (an untouched "\frac{▢}{▢}" renders as the
    /// syntactically-valid, visually-empty "\frac{}{}").
    func currentLatexString() -> String {
        guard let storage = textStorage else { return "" }
        return storage.string.replacingOccurrences(of: Self.holePlaceholder, with: "")
    }

    private func scheduleRenderDebounced() {
        renderDebounceTimer?.invalidate()
        let timer = Timer(timeInterval: renderDebounceInterval, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.onLatexChanged?(self.currentLatexString())
        }
        RunLoop.main.add(timer, forMode: .common)
        renderDebounceTimer = timer
    }
}
