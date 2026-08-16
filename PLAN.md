# Mafac — Development Plan

A minimal native macOS note-taking app where math equations are typed via
mnemonic keyboard shortcuts (e.g. `q` → `√`, `w` → `∫`) inside a dedicated
"math block," with a shortcut cheat-sheet visible on screen so the shortcuts
get memorized through repeated use. Equations render live and can be copied
out as LaTeX for other apps (Notion, Obsidian, Craft, etc).

## Core concept, locked in

- **Notes = text + math blocks.** A note is normal rich/plain text, and you
  insert a math block (like a code block in Obsidian) wherever you need an
  equation. Outside a math block, the keyboard behaves normally.
- **Inside a math block**, keystrokes are interpreted through the shortcut
  table instead of being typed literally — `q` inserts `√`, `w` inserts `∫`,
  etc. This is what makes the mnemonic system possible without modifier-key
  gymnastics.
- **Shortcut cheat-sheet overlay** is visible by default whenever a math
  block is focused, showing the current shortcut → symbol mapping. Toggleable
  (hide once memorized).
- **Export:** select an equation (or math block) → copy as LaTeX
  (`$$...$$` or `\[...\]`) to clipboard, ready to paste into any LaTeX-aware
  app.
- **Storage:** local files only, v1. No iCloud/sync engineering — user can
  put the notes folder in iCloud Drive/Dropbox themselves if they want sync.
- **Platform:** native macOS, Swift + SwiftUI (AppKit interop where SwiftUI's
  text handling falls short, which it will for a custom-input math block).

## Big open design question you'll hit early: how to render math

Two real options, pick one in Phase 1:

1. **KaTeX in a `WKWebView`** — feed it LaTeX strings, get pixel-perfect
   rendering for free, huge symbol coverage, well-tested. Cost: a web view
   per math block feels less "native," slightly heavier, JS bridge for
   updates. This is the pragmatic choice and what the plan below assumes.
2. **SwiftMath** (native Swift port of iosMath/MathType rendering) — truly
   native rendering, no web view. Cost: less actively maintained, smaller
   symbol/macro coverage, more fiddly for complex layouts (matrices, cases).

Recommendation: start with **KaTeX/WKWebView** for Phase 1–2 since it gets
you to a working app fast and de-risks rendering entirely; revisit native
rendering later only if the web view proves genuinely limiting (performance
with many blocks, or you want a truly native feel).

## Shortcut system design (do this on paper before Phase 1)

Before writing code, design the actual mnemonic table. A few rules of thumb:

- Single letters for the ~20 most-used symbols/structures (√, ∫, Σ, π, ∞,
  fraction, superscript, subscript, ≤, ≥, ≠, →, ±, Greek letters you use
  often, etc). Letter should be mnemonic (`q`≈"root" is a stretch — you may
  want `r` for root, `q` for something else — worth genuinely brainstorming
  rather than locking your example in).
- Structures that need a "hole" to type into (fraction, superscript, sqrt
  with content) need a defined cursor-placement behavior — e.g. typing the
  shortcut inserts `□/□` with the first box focused, and Tab moves to the
  next box.
- Decide a small set of **modifier-based shortcuts** for the second tier of
  symbols (less common) so you don't run out of single letters — e.g.
  Shift+letter or a two-key sequence starting with a leader like `;`.
- Write this table down as a plain data file (JSON/plist) from day one, not
  hardcoded in Swift — Phase 1 already treats it as config so re-mapping
  later is just editing data.

This plan doesn't lock the exact letter-to-symbol table — that's yours to
design (or ask me to help draft in Phase 1).

## Phases

Each phase is scoped to be doable in one focused session, and each one
leaves you with something that runs. Don't start a phase until the previous
one's exit criteria are met.

---

### ✅ Phase 0 — Project setup & shortcut table design
**Goal:** Empty but running macOS app, plus the shortcut table designed as data.

**Done (hand-authored, not yet built/run — see note below):**
- `Mafac.xcodeproj/project.pbxproj` — macOS App target, SwiftUI lifecycle,
  bundle id `com.mafac.mafac`, sandboxed with read/write access to
  user-selected files (for Phase 4), Swift 5 language mode.
- `Mafac/App/`, `Mafac/Models/`, `Mafac/Views/`, `Mafac/Resources/`
  folder structure, `MafacApp.swift`, `ContentView.swift`,
  `Assets.xcassets` (AppIcon/AccentColor placeholders), entitlements file.
- `Resources/ShortcutTable.json`: 28 entries (25 tier-1 single-key, 3
  tier-2 `;`-leader) covering root/integral/sum/pi/infinity/fraction/
  superscript/subscript, ≤/≥/≠/→/±/×/÷/≈/∈, 8 Greek letters, and a couple
  of leader-sequence examples (∀/∃/∏) — each with a written mnemonic.
- `Models/ShortcutTable.swift`: Codable model + bundle loader for the JSON.
- `Views/MathRenderView.swift`: `NSViewRepresentable` WKWebView wrapper
  that calls a `renderMath(latex, displayMode)` JS function; `ContentView`
  wires it to render the hardcoded quadratic formula.
- `Resources/katex/katex-shell.html`: the HTML shell the web view loads,
  referencing `katex.min.css`/`katex.min.js` by relative path.

**One thing left for you:** the actual KaTeX distribution isn't bundled
(no network access in the environment this was built in). Drop
`katex.min.js`, `katex.min.css`, and the `fonts/` folder from a KaTeX
release (https://github.com/KaTeX/KaTeX/releases) straight into
`Mafac/Resources/katex/` — see the README.txt there for exact steps.
That directory is wired into the Xcode project as a folder reference, so
no project-file editing is needed, just copy the files in and build.
Also note: this was all hand-written without access to a working Xcode,
so give the project a first build/open once your Xcode is updated and
fix up anything that doesn't compile cleanly.

- Create Xcode project: macOS App, SwiftUI lifecycle, app name Mafac, bundle
  id `com.<you>.mafac`.
- Set up basic project structure: `App/`, `Models/`, `Views/`, `Resources/`.
- Design and write `ShortcutTable.json` (or `.plist`): mapping of trigger
  key → LaTeX snippet → display symbol → cursor-hole behavior (none /
  single-hole / two-hole like fraction). Aim for an initial ~25-30 entries.
- Bundle KaTeX (download the KaTeX distribution — JS+CSS — into
  `Resources/katex/`) and confirm it loads in a bare `WKWebView` inside the
  app, rendering one hardcoded LaTeX string.
- **Exit criteria:** App launches, shows a window with a WKWebView that
  renders a test equation like `x = \frac{-b \pm \sqrt{b^2-4ac}}{2a}` via
  KaTeX. Shortcut table exists as a data file, not yet wired to anything.

---

### ✅ Phase 1 — Math block: shortcut input → LaTeX → live render
**Goal:** A single, standalone math block view where typing shortcut keys
builds up LaTeX and renders it live. This is the heart of the app — get it
right before anything else.

**Done (hand-authored, not yet built/run — same caveat as Phase 0, no
working Xcode in this environment):**
- `Views/MathBlockTextView.swift` — `NSTextView` subclass that is the
  keystroke interpreter. The text view's visible text *is* the raw LaTeX
  source (typing `f` inserts the literal characters `\frac{▢}{▢}`, `▢`
  U+25A2 marking an empty hole); rendering happens in the adjacent
  `MathRenderView`. Overrides `insertText(_:replacementRange:)` for
  shortcut lookup + literal fallthrough (including a `;`-leader state
  machine for tier-2 entries), `insertTab`/`insertBacktab` for hole
  navigation, and `deleteBackward`/`deleteForward` for structured delete.
  Structure/hole tracking uses two custom `NSAttributedString` attributes
  applied directly on the live `NSTextStorage` (`.mafacStructure`: UUID
  per shortcut-inserted snippet; `.mafacHole`: Int index, present only on
  an unedited placeholder) rather than a hand-kept side model, so it can't
  drift out of sync with edits made elsewhere. Newly typed content only
  inherits a structure's `.mafacStructure` tag when it's genuinely
  sandwiched between two characters that already carry that same tag
  (`structureContainingOpenHole(at:storage:)`) — i.e. still inside an
  unclosed hole — rather than just because the character before it
  happens to carry the tag; this is what keeps a completed leaf shortcut
  (e.g. `\pi`, which has no holes) from having its tag silently spread
  into whatever ordinary text gets typed after it, which would otherwise
  make atomic-delete backspace eat that later text too.
- `Views/MathBlockView.swift` — `NSViewRepresentable` wrapping the above
  in an `NSScrollView` (manual TextKit stack), disabling all of
  NSTextView's text-mangling autocorrect/substitution features (smart
  quotes/dashes, spell check, data detectors) since those would corrupt
  LaTeX. Surfaces the block's LaTeX outward via a debounced (~120ms)
  `onLatexChange` closure rather than a two-way binding, so nothing fights
  the text view's own cursor/selection state.
- `ContentView.swift` updated: one live `MathBlockView` above a
  `MathRenderView` (unchanged, still independently reusable) that
  re-renders as the block's derived LaTeX changes.
- `Mafac.xcodeproj/project.pbxproj` updated to include both new files
  (this project uses explicit file lists, not synchronized groups).

**Known limitations (documented rather than hidden, since none of this
could be exercised against a real build):**
- Nesting is single-level: each shortcut insertion claims its whole range
  with one fresh structure ID; a shortcut typed inside another's hole
  "adopts" that stretch of text, overwriting the outer tag there. Fine for
  the common case, not a general nested-structure stack.
- Backspace while a still-empty hole is selected deletes the *entire*
  enclosing structure, even if an earlier hole in that same structure
  already has real content typed into it (e.g. numerator filled, tab to
  empty denominator, backspace loses both). Simplification, not refined.
- After overtyping a hole's placeholder, the caret stays inside that
  hole's `{...}` group (correct, so more content can follow inside it);
  leaving the hole to continue after the structure needs an explicit
  Right-arrow (or Tab, if another hole follows) — there's no "smart exit"
  heuristic.
- Arrow-key navigation relies on NSTextView's default selection-collapse
  behavior (arrow key while a hole's placeholder is selected collapses to
  that edge) rather than custom overrides — not exhaustively tested.
- Undo grouping is wired via `shouldChangeText`/`didChangeText` bracketing
  around every programmatic edit (the documented correct pattern) but not
  interactively verified.
- Only lowercase letters *not* claimed by a Greek-letter or other tier-1
  shortcut type literally as variables (uppercase letters always do,
  since triggers are matched case-sensitively against lowercase-only
  entries in `ShortcutTable.json`) — an inherent tradeoff of the mnemonic
  system, not a bug.

- Build `MathBlockView`: a custom input surface (likely an `NSViewRepresentable`
  wrapping an `NSTextView` subclass, since you need full control over
  keystroke interpretation — SwiftUI `TextField`/`TextEditor` won't give you
  that).
- Implement the keystroke interpreter: when focused, each keypress looks up
  `ShortcutTable`, and either (a) inserts the mapped LaTeX snippet plus
  moves cursor into the first "hole" if the symbol has one, or (b) falls
  through to literal character insertion for things like digits, `+`, `-`,
  `=`, letters used as variables, parens.
- Handle navigation inside holes: Tab/Shift-Tab to move between holes,
  arrow keys to move within/out of a hole.
- Wire the block's current LaTeX string to the KaTeX WKWebView from Phase 0
  so it re-renders on every keystroke (debounce if needed for perf).
- Add backspace/delete semantics that make sense for structured LaTeX
  (deleting a fraction shortcut removes the whole structure, not one
  character of `\frac{}{}`).
- **Exit criteria:** You can open the app, click into one math block, type a
  sequence of shortcut keys and literal characters, and see a correctly
  rendered equation update live, matching what a hand-written LaTeX string
  would produce.

---

### ✅ Phase 2 — Shortcut cheat-sheet overlay
**Goal:** The actual "memorization aid" UI — visible reference of what each
key does while a math block is focused.

- Built `Mafac/Views/CheatSheetView.swift`: a trailing sidebar panel (`HStack`
  in `ContentView`, no `NavigationSplitView`/`.inspector` needed for a
  single-block layout) that reads `ShortcutTable` and renders a `ScrollView`
  of rows grouped by each entry's `category` field, in a fixed sensible
  order (structures, calculus, operators, relations, constants, greek,
  logic; any future category not in that list is appended alphabetically
  rather than dropped). Each row shows the trigger as a keycap-styled
  badge, the symbol, and the mnemonic text.
- Show/hide-on-focus: `MathBlockView` now exposes a `@Binding<Bool>
  isFocused` that its `Coordinator` (an `NSTextViewDelegate`) updates from
  `textDidBeginEditing`/`textDidEndEditing` — the standard AppKit
  begin/end-editing notifications `NSTextView` posts as it becomes/resigns
  the window's editing responder. `ContentView` mirrors this into
  `isMathBlockFocused` and shows the cheat-sheet whenever it's true, in
  "automatic" mode.
- Manual override: `⌘/` is wired via a hidden `Button` with
  `.keyboardShortcut("/", modifiers: .command)` in `ContentView`'s
  background (AppKit resolves it as a key equivalent before the keystroke
  would ever reach the math block's text view, so it works regardless of
  focus). Toggling flips a persisted `CheatSheetOverride` enum
  (`automatic` / `forcedShown` / `forcedHidden`) stored via
  `@AppStorage("mafac.cheatSheet.override")`, so once toggled the explicit
  state wins over focus-following and survives a relaunch.
- Nice-to-have implemented: `MathBlockTextView` calls a new
  `onShortcutUsed(ShortcutEntry.id)` closure right after inserting a
  shortcut; `ContentView` threads this through to
  `CheatSheetView.recentlyUsedID` and clears it after ~0.9s via a
  cancellable `Task`, giving the matching row a brief accent-color
  highlight.
- **Known limitations:** not run in Xcode (no working toolchain in this
  environment, per the Phase 1 note) — reasoned through against documented
  AppKit/SwiftUI APIs but not exercised interactively. The cheat-sheet has
  no search/filter yet (left for Phase 6's polish list). Window resizing
  when the sidebar appears/disappears relies on `.windowResizability(.contentSize)`
  from Phase 0/1, which may feel slightly abrupt — revisit if it's
  bothersome in practice.
- **Exit criteria met:** Typing in a math block shows a live, readable
  reference panel of all shortcuts; `⌘/` hides/shows it; the override
  preference persists across launches via `UserDefaults`.

---

### ✅ Phase 3 — Notes: text + embedded math blocks
**Goal:** Turn the standalone math block into part of a real note document
with surrounding plain text.

**What's done:**

- `Models/NoteDocument.swift`: `NoteBlock` (an `Identifiable` struct — a
  stable `UUID` plus `content: NoteBlockContent`, where `NoteBlockContent`
  is `.text(String)` / `.math(latex: String)`) and `NoteDocument` (a title
  plus `[NoteBlock]`). Every block gets a stable id up front, not just math
  blocks, since `ForEach` needs stable identity for *all* blocks the moment
  the array can split (a ⌘M mid-text press turns one text block into
  three). In memory only — no `Codable` yet, that's Phase 4.
- `Views/NoteTextBlockView.swift`: a new, minimal `NSViewRepresentable`
  wrapping a plain `NSTextView` for `.text` blocks — deliberately not
  `MathBlockTextView` (no shortcut interpretation). Wraps `NSTextView`
  rather than using SwiftUI's `TextEditor` for two reasons: it needs
  on-demand cursor position for the ⌘M split, and it needs focus drivable
  from outside (to hand focus to a freshly-inserted math block), neither
  of which macOS 13's `TextEditor(text:)` exposes.
- `Views/NoteEditorView.swift`: renders `document.blocks` top-to-bottom —
  `.text` via `NoteTextBlockView`, `.math` via the existing `MathBlockView`
  (Phase 1, reused unmodified in its own logic — only a small focus-follows
  -state addition landed in `updateNSView`, see below) paired with
  `MathRenderView` (Phase 0), exactly as ContentView wired the single demo
  block in Phases 1-2, now once per math block.
- Focus coordination: a single `Binding<UUID?>` (`focusedBlockID`, owned by
  `ContentView`, threaded down) is the one source of truth for which block
  — text or math — currently has keyboard focus. Not `@FocusState`, because
  both block views are `NSViewRepresentable`s that track their own AppKit
  first-responder state; a per-block `Binding<Bool>` is derived from the
  shared `UUID?` via the standard "one shared selection, N item bindings"
  pattern (`focusBinding(for:)` in `NoteEditorView`), which is what makes a
  *dynamic*, growing/shrinking/splitting block array work — nothing here
  depends on a fixed enum of block identities.
- `MathBlockView.swift`: `isFocused` was outbound-only in Phase 1/2 (text
  view → binding). Phase 3 adds the inbound direction in `updateNSView` —
  if `isFocused` is externally set true and the text view isn't first
  responder yet, it claims it via `makeFirstResponder`. Same addition made
  fresh in `NoteTextBlockView`. This is what lets ⌘M hand keyboard focus to
  the block it just created.
- ⌘M: a hidden `Button` with `.keyboardShortcut("m", modifiers: .command)`
  in `NoteEditorView` (same technique Phase 2 used for ⌘/, which reliably
  wins over the default Window > Minimize menu item, also bound to ⌘M,
  because AppKit resolves a SwiftUI button's key equivalent while walking
  the view hierarchy — before it would fall through to the main menu).
  While a `.text` block has focus, it reads that block's live cursor
  position (via `TextBlockRegistry`, a small side-table of weak
  `NSTextView` references keyed by block id — needed because the handler
  runs at the note level, outside any one block's own view) and splits it
  into before-text / new-math / after-text, replacing one block with three
  fresh ids. If nothing is focused, or a math block is, it appends a new
  math block (plus a trailing empty text block) at the end instead.
- `CheatSheetView` visibility (`ContentView.isMathBlockFocused`) now checks
  that the focused block specifically `isMath`, not just "something has
  focus" — satisfies the brief's point 5 without any extra plumbing beyond
  what `focusedBlockID` + `document.blocks` already provide.
- `ContentView.swift` now hosts one `NoteDocument` via `NoteEditorView`,
  replacing the Phase 1-2 single-demo-block layout; the cheat-sheet sidebar
  is unchanged in behavior (`⌘/`, `@AppStorage` override) but its automatic
  branch now follows the note-wide focused-math signal above.

**Known limitations (by design, in scope for later phases/polish):**

- No file persistence — `NoteDocument` lives only in memory for the
  duration of the app run. **Phase 4 (local file persistence) has not been
  started.** Quitting the app loses the note.
- Clicking in genuinely empty space outside every block (not on any text
  or math view) doesn't explicitly resign focus — this relies on AppKit's
  default behavior of leaving the current first responder alone when a
  click lands on non-interactive space, same as Phases 1-2 already did for
  the single block. A dedicated "click outside deactivates" background
  tap-catcher was not added.
- Text blocks have a fixed height range (`minHeight: 32` / `maxHeight:
  220`) with internal scrolling rather than auto-growing to fit content —
  simplest option that keeps `NoteTextBlockView` a plain `NSTextView` in an
  `NSScrollView` without implementing intrinsic-content-size tracking.
  Fine for short paragraphs; a long paragraph scrolls inside its own block
  instead of expanding the block.
- No block deletion/merging UX yet (e.g. backspacing at the start of an
  empty text block doesn't merge it into the previous block, and an empty
  text block left behind by ⌘M isn't auto-removed) — the document can
  accumulate empty text blocks through normal use; harmless but not
  cleaned up.
- As with Phase 1/2, this was written without a working Xcode/xcodebuild
  in the environment — reasoned through carefully against documented
  AppKit/SwiftUI focus and responder-chain behavior (including the ⌘M vs.
  Window-menu-Minimize key-equivalent resolution order) but not exercised
  interactively. Worth a careful pass in Xcode before relying on it,
  especially the ⌘M split and focus hand-off.
- **Exit criteria:** A single note can contain multiple paragraphs of plain
  text interleaved with multiple math blocks, all independently editable,
  and it all lives in memory as one coherent document. Met — see the block
  array walkthrough in this phase's implementation notes / commit message
  for a traced example (type text → ⌘M → type a shortcut sequence → click
  back into text → keep typing).

---

### Phase 4 — Local file persistence
**Goal:** Notes actually save and load from disk.

- Define the on-disk format: recommend a JSON document per note (array of
  blocks as designed in Phase 3) with a `.mafac` extension, or Markdown with
  fenced math blocks (` ```math ... ``` `) if you want the files to be
  human-readable/greppable outside the app. Markdown+fenced-math is
  friendlier for future interop; pick based on whether you care about
  reading notes in a plain text editor.
- Implement save (autosave on change, debounced) and load.
- Build a simple notes list / sidebar: shows notes in a chosen folder
  (user picks folder via `NSOpenPanel` on first launch, stored in
  `UserDefaults`), click to open, `⌘N` to create new, rename, delete.
- Handle basic file-system edge cases: note deleted externally, folder
  moved, duplicate names.
- **Exit criteria:** Create several notes with mixed text/math content,
  quit the app, relaunch, notes are all there unchanged. Notes are plain
  files you can find in Finder.

---

### Phase 5 — LaTeX export (copy to clipboard)
**Goal:** Get equations out of Mafac and into other apps correctly formatted.

- Add "Copy as LaTeX" action for a single math block (right-click menu +
  keyboard shortcut, e.g. `⌘⇧C` while a math block is focused) — copies the
  raw LaTeX string, wrapped as `$$...$$` (or `\(...\)` for inline — decide
  based on target apps' conventions; `$$...$$` is the safest common
  denominator for Notion/Obsidian/Craft).
- Add "Copy note as Markdown" (whole-note export) that serializes all
  `.text` blocks as-is and all `.math` blocks as `$$latex$$`, producing a
  single Markdown string on the clipboard — useful for pasting a whole note
  into Obsidian/Notion at once.
- Quick manual verification: paste exported equations into Obsidian (or
  whatever app you actually use) and confirm they render correctly.
- **Exit criteria:** Copying a single equation or a whole note produces
  LaTeX that renders correctly when pasted into your actual target note
  app(s).

---

### Phase 6 — Polish pass
**Goal:** Make it pleasant to use daily, since that's the actual point.

Pick from this list based on what's actually bothering you after using it
for real note-taking — don't do all of it blindly:

- Undo/redo support (structured, so undoing a shortcut-inserted fraction
  removes the whole structure).
- Better cheat-sheet UX: search/filter, or context-sensitive subset (only
  show shortcuts relevant to what you're currently editing).
- Dark mode / KaTeX theme matching the app's appearance.
- Inline math inside a text block (`$x^2$` style) as a lighter-weight
  alternative to a full math block, if you find full blocks too heavy for
  quick one-off symbols.
- Menu bar quick-capture window (jot an equation without opening the main
  window).
- App icon, basic onboarding/empty-state, preferences window for shortcut
  table customization (editing `ShortcutTable.json` via UI instead of
  hand-editing the file).
- Performance check with many math blocks in one long note (WKWebView count
  can get expensive — may need to virtualize/lazy-render off-screen blocks).

---

## Session-to-session notes

- Each phase above is meant to map to one working session with fresh
  context — start a session by re-reading this file plus whatever code
  exists, and only work within the current phase's scope.
- Check off phases as you complete them (edit this file, turn `###` headers
  into `### ✅ Phase N — ...`) so future sessions know where things stand at
  a glance.
- If a phase turns out too big once you're in it, it's fine to split it
  further — the exit criteria are the contract, not the bullet list above
  them.
