//
//  NoteDocument+Markdown.swift
//  Mafac
//
//  Phase 4: pure, no-I/O encode/decode between `NoteDocument` and the
//  on-disk Markdown format. `NotesStore` is the only thing that touches the
//  file system; everything here is a plain (String) <-> (NoteDocument)
//  transformation, so it can (and should) be reasoned about like ordinary
//  parsing code.
//
//  ## Format
//
//  - `.text(String)` blocks are written verbatim — no escaping, no
//    wrapping. This is what makes the file plain, greppable Markdown that
//    opens fine in any text editor.
//  - `.math(latex:)` blocks become a fenced section:
//      ```math
//      <latex, verbatim, may be multi-line>
//      ```
//  - Blocks are joined with a blank line (`"\n\n"`) between each pair, the
//    same convention Markdown itself uses between paragraphs/fenced blocks.
//
//  ## Why decode isn't just "split on ```math / ``` "
//
//  Naive line-scanning breaks on blank-line bookkeeping: encode's `"\n\n"`
//  join means every block boundary — text-to-math, math-to-text, or a
//  hypothetical text-to-text — inserts exactly one blank *separator* line
//  that is not part of either block's actual content. Decode has to know
//  which blank lines are real content and which are join artifacts, or
//  round-tripping silently gains/loses blank lines at every boundary.
//
//  The key invariant (verified by hand, see the worked example below and
//  the phase's commit message for a second trace):
//
//      lines(A + "\n\n" + B) == lines(A) + [""] + lines(B)
//
//  for ANY strings A, B, where `lines(s) = s.components(separatedBy: "\n")`.
//  That is, joining two arbitrary strings with "\n\n" always inserts
//  *exactly one* empty-string element into the line array, regardless of
//  whether A/B already end/start with their own blank lines. So decode can
//  locate every fenced math span first (they're unambiguous: a line that's
//  exactly "```math", followed later by a line that's exactly "```"), and
//  then, for every text segment between two such spans (or before the
//  first / after the last), strip exactly one boundary line on each side
//  that has a neighboring block, before rejoining the rest as that text
//  block's content. See `appendTextSegment` below.
//
//  ## Known limitations (inherent to "text passes through as-is")
//
//  - A text block that itself contains a line reading exactly "```math"
//    followed later by a line reading exactly "```" will be misparsed as a
//    math fence on reload. There is no escaping mechanism for this in v1 —
//    accepted tradeoff for keeping plain text genuinely plain (no
//    escaping/quoting noise) per the plan's stated preference.
//  - If LaTeX source itself contains a line that is exactly "```" (highly
//    unusual — backtick-only lines aren't valid LaTeX), the fence closes
//    early. Not expected in practice for math content typed via the
//    shortcut system.
//  - CRLF line endings are normalized to LF on decode (a file edited by a
//    CRLF-only external tool round-trips its content but not its exact
//    line-ending bytes).
//  - Adjacent `.text` blocks with no block between them (not something the
//    current UI ever produces — `\u{2318}M` always sandwiches a new math
//    block between two text blocks) merge into a single `.text` block on
//    reload, joined by the same blank line that separated them. No content
//    is lost, only the block-count/structure, which is invisible to the
//    user.
//
enum NoteMarkdownCodec {

    private static let fenceOpen = "```math"
    private static let fenceClose = "```"

    /// Serializes a `NoteDocument`'s blocks to the on-disk Markdown string.
    /// Pure function — no I/O, no normalization of the input.
    static func encode(_ document: NoteDocument) -> String {
        let parts: [String] = document.blocks.map { block in
            switch block.content {
            case .text(let text):
                return text
            case .math(let latex):
                return "\(fenceOpen)\n\(latex)\n\(fenceClose)"
            }
        }
        return parts.joined(separator: "\n\n")
    }

    /// Parses a Markdown string (as produced by `encode`, or hand-written
    /// by a user in a plain text editor) back into a `NoteDocument`. Always
    /// returns at least one block, even for empty input, matching
    /// `NoteDocument.empty`'s invariant that a document always has >= 1
    /// block.
    ///
    /// `title` is supplied by the caller (derived from the file name by
    /// `NotesStore`) rather than embedded in the Markdown body — keeping
    /// title out of the round-trip entirely sidesteps a whole class of
    /// front-matter-parsing edge cases that don't matter for this app.
    static func decode(_ markdown: String, title: String) -> NoteDocument {
        // Normalize CRLF -> LF up front so line comparisons below don't
        // have to special-case a trailing "\r" on every line.
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")

        struct FenceSpan {
            let start: Int   // index of the "```math" line
            let end: Int     // index of the matching "```" line
            let latex: String
        }

        // Pass 1: locate every fenced math span, left to right,
        // non-overlapping. A "```math" line with no later "```" line is
        // not a valid fence (would swallow the rest of the document) —
        // left as literal text instead.
        var spans: [FenceSpan] = []
        var i = 0
        while i < lines.count {
            if lines[i] == fenceOpen {
                var j = i + 1
                var closeIndex: Int? = nil
                while j < lines.count {
                    if lines[j] == fenceClose {
                        closeIndex = j
                        break
                    }
                    j += 1
                }
                if let closeIndex {
                    let latex = lines[(i + 1)..<closeIndex].joined(separator: "\n")
                    spans.append(FenceSpan(start: i, end: closeIndex, latex: latex))
                    i = closeIndex + 1
                    continue
                }
            }
            i += 1
        }

        var blocks: [NoteBlock] = []

        // Extracts the text block (if any) sitting in lines[low..<high].
        // `low` is the index right after the previous block ended (or 0 at
        // the very start of the document); `high` is the index of the next
        // fence's opening line (or lines.count at the very end).
        //
        // - If low > 0, there is a preceding block, which means join()
        //   inserted exactly one separator blank line at index `low`
        //   (per the invariant in the type's doc comment) — skip it.
        // - If hasSuccessor, there is a following fence, which means
        //   join() inserted exactly one separator blank line at index
        //   `high - 1` — skip it too.
        //
        // What's left, if anything, is the segment's real content. An
        // empty *range* (start >= end) means "no text block here" (e.g.
        // two math blocks with nothing between them); a range containing
        // a single "" element means a genuine, deliberate empty text
        // block (e.g. the trailing empty block \u{2318}M leaves after a
        // math block).
        func appendTextSegment(low: Int, high: Int, hasSuccessor: Bool) {
            var start = low
            var end = high
            if start > 0 { start += 1 }
            if hasSuccessor { end -= 1 }
            guard start < end else { return }
            let content = lines[start..<end].joined(separator: "\n")
            blocks.append(NoteBlock(content: .text(content)))
        }

        var cursor = 0
        for span in spans {
            appendTextSegment(low: cursor, high: span.start, hasSuccessor: true)
            blocks.append(NoteBlock(content: .math(latex: span.latex)))
            cursor = span.end + 1
        }
        appendTextSegment(low: cursor, high: lines.count, hasSuccessor: false)

        if blocks.isEmpty {
            blocks = [NoteBlock(content: .text(""))]
        }

        return NoteDocument(title: title, blocks: blocks)
    }
}
