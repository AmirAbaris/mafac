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

### Phase 1 — Math block: shortcut input → LaTeX → live render
**Goal:** A single, standalone math block view where typing shortcut keys
builds up LaTeX and renders it live. This is the heart of the app — get it
right before anything else.

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

### Phase 2 — Shortcut cheat-sheet overlay
**Goal:** The actual "memorization aid" UI — visible reference of what each
key does while a math block is focused.

- Build a cheat-sheet panel (sidebar, floating palette, or bottom drawer —
  pick one; sidebar is simplest to keep persistent) that lists shortcut key
  → symbol from `ShortcutTable`, grouped sensibly (basic operators, Greek
  letters, structures, relations, etc).
- Show/hide logic: visible by default when any math block has focus, hidden
  when focus leaves all math blocks (or make it a manual toggle — decide
  based on how it feels once built).
- Keyboard shortcut to toggle visibility (e.g. `⌘/`), plus a persisted user
  preference so their choice sticks across launches.
- Optional nice-to-have if time allows: highlight the row in the cheat-sheet
  briefly when that shortcut is used, reinforcing the key→symbol link.
- **Exit criteria:** Typing in a math block shows a live, readable reference
  panel of all shortcuts; toggling hides/shows it; preference persists.

---

### Phase 3 — Notes: text + embedded math blocks
**Goal:** Turn the standalone math block into part of a real note document
with surrounding plain text.

- Build `NoteEditorView`: a text editor (SwiftUI `TextEditor` or custom
  `NSTextView`) that supports inserting a math block inline at the cursor
  (e.g. via a `⌘M` shortcut or a `/math` slash command).
- Decide and implement the underlying document model: likely an ordered
  array of blocks (`.text(String)` / `.math(latex: String)`), rather than
  trying to inline WKWebViews inside a single NSTextView's text storage
  (much simpler to reason about and render).
- Render each `.text` block as normal editable text and each `.math` block
  as the `MathBlockView` from Phase 1, laid out top-to-bottom in the note.
- Basic note-level UI: click to focus a text region and type normally,
  click into a math block to enter shortcut-mode editing, click outside to
  exit.
- **Exit criteria:** A single note can contain multiple paragraphs of plain
  text interleaved with multiple math blocks, all independently editable,
  and it all lives in memory as one coherent document.

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
