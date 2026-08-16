//
//  ShortcutTable.swift
//  Mafac
//
//  Codable model for Resources/ShortcutTable.json — the data-driven mapping
//  of trigger key(s) to LaTeX snippets used inside a math block. Phase 0
//  only defines and loads this table; nothing consumes it yet (that's
//  Phase 1's keystroke interpreter).
//

import Foundation

/// How many "holes" (tab-stops for the cursor) a shortcut's inserted LaTeX
/// snippet has, and therefore how focus should behave right after insertion.
///
/// - `none`: the snippet is a complete leaf (e.g. `\pi`) — cursor lands
///   immediately after it.
/// - `single`: one hole to fill in (e.g. `\sqrt{}`, `^{}`) — cursor lands
///   inside the braces.
/// - `double`: two holes filled in sequence via Tab (e.g. `\frac{}{}`,
///   `\sum_{}^{}`) — cursor starts in the first, Tab moves to the second.
enum HoleBehavior: String, Codable, CaseIterable {
    case none
    case single
    case double
}

/// Which tier a shortcut belongs to, per the plan's two-tier design:
/// tier 1 is a single keypress while a math block has focus; tier 2 is a
/// `;`-prefixed leader sequence for the longer tail of less-common symbols
/// once the ~26 single keys on the keyboard run out.
enum ShortcutTier: Int, Codable {
    case primary = 1
    case leader = 2
}

/// One row of the shortcut table: a trigger key (or leader sequence) mapped
/// to the LaTeX it inserts, how it should be displayed in the cheat-sheet,
/// and how the cursor should behave afterward.
struct ShortcutEntry: Codable, Identifiable, Hashable {
    /// Stable identifier, also used as the JSON key name (e.g. "root",
    /// "fraction"). Not shown to the user.
    let id: String

    /// The key the user presses while a math block is focused. Tier-1
    /// entries are a single character (e.g. `"r"`, `"^"`); tier-2 entries
    /// are a two-character leader sequence (e.g. `";f"`).
    let trigger: String

    /// 1 = direct keypress, 2 = `;`-prefixed leader sequence.
    let tier: ShortcutTier

    /// Grouping used by the cheat-sheet overlay (Phase 2): operator,
    /// relation, structure, greek, calculus, constant, logic, ...
    let category: String

    /// The raw LaTeX inserted into the math block's source string. Holes
    /// are represented as empty `{}` groups, e.g. `"\\frac{}{}"`.
    let latex: String

    /// The glyph or short mock-rendering shown in the cheat-sheet overlay,
    /// e.g. "√", "≤", "a/b" for fraction.
    let symbol: String

    /// Cursor-hole behavior after insertion.
    let holeBehavior: HoleBehavior

    /// Short human-readable explanation of why this key was chosen —
    /// surfaced in the cheat-sheet / preferences UI to help memorization.
    let mnemonic: String
}

/// Top-level container matching ShortcutTable.json's shape, allowing the
/// file format to carry a version number for future migrations.
struct ShortcutTable: Codable {
    let version: Int
    let entries: [ShortcutEntry]
}

enum ShortcutTableError: Error {
    case resourceNotFound(String)
}

extension ShortcutTable {
    /// Loads and decodes `ShortcutTable.json` from the app bundle.
    ///
    /// - Parameter bundle: defaults to `.main`; pass a different bundle in
    ///   tests/previews if needed.
    static func loadFromBundle(_ bundle: Bundle = .main) throws -> ShortcutTable {
        guard let url = bundle.url(forResource: "ShortcutTable", withExtension: "json") else {
            throw ShortcutTableError.resourceNotFound("ShortcutTable.json")
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(ShortcutTable.self, from: data)
    }

    /// Convenience lookup, keyed by trigger string (e.g. "r" or ";f").
    /// Phase 1's keystroke interpreter will use something like this.
    func entry(forTrigger trigger: String) -> ShortcutEntry? {
        entries.first { $0.trigger == trigger }
    }
}
