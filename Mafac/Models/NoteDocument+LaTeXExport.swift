//
//  NoteDocument+LaTeXExport.swift
//  Mafac
//
//  Phase 5: pure, no-I/O serialization used only for clipboard export
//  ("Copy as LaTeX" for a single math block, "Copy Note as Markdown" for a
//  whole document) — never for file persistence. Deliberately a separate
//  type from `NoteMarkdownCodec` (Phase 4, `NoteDocument+Markdown.swift`),
//  even though both walk the same `[NoteBlock]` structure, because the two
//  formats serve different, incompatible goals:
//
//  - `NoteMarkdownCodec.encode`/`decode` (Phase 4) is a **round-trippable
//    file format**: math blocks are fenced as ```` ```math ... ``` ````
//    specifically because that fence is unambiguous to re-parse on
//    `decode` (a fenced block can contain a literal `$$` without any
//    escaping ambiguity). Changing that format's delimiter would risk
//    breaking every previously-saved `.mafac` file, so Phase 4's format
//    must stay stable regardless of what Phase 5 needs.
//  - This type is **write-only, one-way clipboard export**, aimed at
//    other apps' Markdown-math parsers (Notion, Obsidian, Craft), which
//    universally expect the `$$...$$` convention for display/block math,
//    not a fenced ` ```math ` code block (a fenced block would just paste
//    as literal preformatted text, not render as an equation).
//
//  Since there is no decode counterpart and no round-tripping requirement
//  here, the two concerns are kept in separate files/types on purpose,
//  per the standing rule "keep file-persistence format and clipboard-
//  export format as clearly separate concerns even if they share
//  structure."
//
//  ## `$$...$$` block formatting: own-line delimiters, chosen deliberately
//
//  For both the single-block copy and the whole-note export, the `$$`
//  delimiters are emitted on their own lines, wrapping the LaTeX body:
//
//      $$
//      <latex>
//      $$
//
//  rather than inline on one line (`$$<latex>$$`). This is a deliberate
//  choice, not an oversight, reasoned through as follows:
//
//  - Obsidian, Notion, and Craft's Markdown-math handling is built on
//    CommonMark-family parsers (remark/MathJax-plugin style in Obsidian,
//    similar block-detection elsewhere) where **block-level** `$$` math
//    is recognized most reliably when the opening and closing `$$` each
//    sit alone on their own line — the same convention as fenced code
//    blocks, and it is unambiguous for LaTeX bodies that themselves span
//    multiple lines (e.g. `\begin{cases}...\end{cases}`, matrices), which
//    this app's shortcut system can absolutely produce.
//  - An inline `$$<latex>$$` on one line also works in most of these
//    parsers for short, single-line LaTeX, but degrades for multi-line
//    LaTeX bodies (a bare inline `$$` doesn't have a defined multi-line
//    behavior in several implementations) — the own-line form is strictly
//    safer and works for both cases, so there is no reason to special
//    -case short equations.
//  - For the whole-note export (`encode` below), block-level `$$...$$` is
//    additionally required to sit on its own paragraph, surrounded by
//    blank lines, exactly like a fenced code block or any other
//    block-level Markdown element — otherwise a parser may treat it as
//    running text (e.g. `$$` immediately after a text block's last word
//    with no blank line between them could be read as part of that
//    paragraph rather than a new block). `encode` gets this for free from
//    the same "join blocks with a blank line" convention Phase 4's codec
//    already established (see the worked trace in this file's tests /
//    the Phase 5 commit message): joining `["...textA", "$$\n<latex>\n$$",
//    "textB..."]` with `"\n\n"` naturally produces a blank line
//    immediately before and after every `$$` fence.
//
//  The single-block copy (`wrapAsLaTeXBlock`, used by "Copy as LaTeX")
//  does *not* add its own leading/trailing blank line beyond the `$$`
//  lines themselves — when pasted as the *entire* clipboard contents (the
//  only way it's used), the paste target's parser sees start-of-input and
//  end-of-input as implicit block boundaries, which every Markdown
//  implementation treats the same as a blank line for this purpose. No
//  known target app requires a literal blank line before the very first
//  or after the very last line of a pasted snippet.
//
//  ## Known limitations
//
//  - No escaping: if a math block's raw LaTeX itself contains a line that
//    is exactly `$$` on its own (unusual — bare `$$` isn't valid LaTeX
//    syntax on its own line), the emitted fence would be ambiguous to a
//    re-parser. Not a concern here since this format is write-only /
//    clipboard-only and is never read back by Mafac itself.
//  - Text blocks are passed through verbatim, same as Phase 4's codec — a
//    text block that itself contains a line consisting solely of `$$`
//    could visually run into an adjacent math export. Accepted tradeoff,
//    consistent with Phase 4's "plain text stays plain" philosophy.
//
enum NoteLaTeXExport {

    /// Wraps a single math block's raw LaTeX for a standalone clipboard
    /// copy ("Copy as LaTeX"), as block-level `$$...$$` — the delimiter
    /// Notion/Obsidian/Craft all recognize for display math. See the
    /// type-level doc comment for why the delimiters sit on their own
    /// lines rather than inline.
    static func wrapAsLaTeXBlock(_ latex: String) -> String {
        "$$\n\(latex)\n$$"
    }

    /// Serializes a whole `NoteDocument` for clipboard export ("Copy Note
    /// as Markdown"): `.text` blocks pass through verbatim, `.math`
    /// blocks become `$$...$$` (via `wrapAsLaTeXBlock`), and every block
    /// is joined by a blank line — the same "\n\n" join Phase 4's
    /// `NoteMarkdownCodec.encode` uses for its ```` ```math ```` fences,
    /// reused here because it's exactly what puts a blank line on both
    /// sides of every `$$` fence, which block-level Markdown math needs
    /// to be recognized reliably. Pure function — no I/O, no clipboard
    /// access; `NoteEditorView` is what actually puts the result on
    /// `NSPasteboard.general`.
    static func encode(_ document: NoteDocument) -> String {
        let parts: [String] = document.blocks.map { block in
            switch block.content {
            case .text(let text):
                return text
            case .math(let latex):
                return wrapAsLaTeXBlock(latex)
            }
        }
        return parts.joined(separator: "\n\n")
    }
}
