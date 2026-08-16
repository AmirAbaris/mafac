//
//  ContentView.swift
//  Mafac
//
//  Phase 1: one standalone math block, wired end-to-end — click in, type
//  shortcut keys per Resources/ShortcutTable.json (handled by
//  MathBlockView/MathBlockTextView), and watch it render live via
//  MathRenderView (the Phase 0 KaTeX/WKWebView pipeline, unchanged and
//  still reusable on its own).
//
//  Phase 2: adds the CheatSheetView sidebar. Visibility follows the math
//  block's focus by default (shown while focused, hidden otherwise), with
//  a ⌘/ shortcut that forces it into an explicit shown/hidden state,
//  persisted via @AppStorage so the override survives a relaunch.
//

import SwiftUI

/// Persisted cheat-sheet visibility mode. `automatic` is the default —
/// follow `isMathBlockFocused`. Pressing ⌘/ flips into whichever forced
/// state is the opposite of what's currently on screen, and that forced
/// state sticks (across focus changes and app relaunches) until ⌘/ is
/// pressed again.
private enum CheatSheetOverride: Int {
    case automatic = 0
    case forcedShown = 1
    case forcedHidden = 2
}

struct ContentView: View {
    /// The math block's current LaTeX, pushed here (debounced) by
    /// MathBlockView every time the user edits the block.
    @State private var latex: String = ""

    /// Whether the math block currently has keyboard focus, kept in sync
    /// by MathBlockView's coordinator (see MathBlockView.swift).
    @State private var isMathBlockFocused: Bool = false

    /// `ShortcutEntry.id` of the most recently used shortcut, for the
    /// cheat-sheet's brief highlight. Cleared automatically after a short
    /// delay by `flashRecentlyUsed`.
    @State private var recentlyUsedShortcutID: String? = nil
    @State private var highlightResetTask: Task<Void, Never>? = nil

    /// Persisted across launches. Raw `Int` (rather than the enum
    /// directly) because `@AppStorage` needs a primitive/`RawRepresentable`
    /// UserDefaults-compatible type; we translate via `cheatSheetOverride`.
    @AppStorage("mafac.cheatSheet.override") private var overrideRawValue: Int = CheatSheetOverride.automatic.rawValue

    private let shortcutTable: ShortcutTable? = {
        try? ShortcutTable.loadFromBundle()
    }()

    private var cheatSheetOverride: CheatSheetOverride {
        CheatSheetOverride(rawValue: overrideRawValue) ?? .automatic
    }

    /// The cheat-sheet's actual on-screen visibility right now, combining
    /// the persisted override with live focus state.
    private var isCheatSheetVisible: Bool {
        switch cheatSheetOverride {
        case .automatic: return isMathBlockFocused
        case .forcedShown: return true
        case .forcedHidden: return false
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Mafac")
                    .font(.largeTitle.bold())

                Text("Click into the math block and type shortcut keys (e.g. r → √, f → fraction, p → π, i → ∫, ^ / _ → super/subscript). Anything not in the table types literally. ⌘/ toggles the shortcut reference.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let shortcutTable {
                    Text("MATH BLOCK")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    MathBlockView(
                        shortcutTable: shortcutTable,
                        onLatexChange: { newLatex in latex = newLatex },
                        onShortcutUsed: { id in flashRecentlyUsed(id) },
                        isFocused: $isMathBlockFocused
                    )
                    .frame(minWidth: 480, minHeight: 90)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                    )

                    Text("RENDERED")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    MathRenderView(latex: latex)
                        .frame(minWidth: 480, minHeight: 160)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                        )
                } else {
                    Text("Failed to load ShortcutTable.json from the app bundle.")
                        .foregroundStyle(.red)
                }
            }
            .padding(24)
            .frame(minWidth: 560, minHeight: 460)

            if isCheatSheetVisible, let shortcutTable {
                Divider()
                CheatSheetView(shortcutTable: shortcutTable, recentlyUsedID: recentlyUsedShortcutID)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: isCheatSheetVisible)
        // Hidden button is the standard SwiftUI trick for a
        // window-scoped keyboard shortcut that isn't tied to any visible
        // control: AppKit resolves ⌘/ as this button's key equivalent
        // before an ordinary keystroke would reach the math block's text
        // view, so it works regardless of what has focus. `.hidden()`
        // keeps it invisible while `.background` keeps it from affecting
        // layout (it's sized to match its container).
        .background(
            Button("Toggle Cheat Sheet") {
                toggleCheatSheet()
            }
            .keyboardShortcut("/", modifiers: .command)
            .hidden()
        )
    }

    private func toggleCheatSheet() {
        // Force into whichever state is the opposite of what's visible
        // right now, and persist it — from then on the override wins
        // over automatic focus-following until toggled again.
        overrideRawValue = isCheatSheetVisible
            ? CheatSheetOverride.forcedHidden.rawValue
            : CheatSheetOverride.forcedShown.rawValue
    }

    private func flashRecentlyUsed(_ id: String) {
        highlightResetTask?.cancel()
        recentlyUsedShortcutID = id
        highlightResetTask = Task {
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled else { return }
            recentlyUsedShortcutID = nil
        }
    }
}

#Preview {
    ContentView()
}
