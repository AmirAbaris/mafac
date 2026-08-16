//
//  CheatSheetView.swift
//  Mafac
//
//  Phase 2: the "memorization aid" sidebar — a live reference of every
//  entry in ShortcutTable.json (trigger key -> symbol -> mnemonic),
//  grouped by the entries' `category` field. Purely presentational: it
//  takes a ShortcutTable and an optional "recently used" entry id and
//  renders a scrollable, grouped list. Show/hide and focus-tracking
//  logic live in ContentView, not here, so this view stays a simple,
//  reusable/previewable component.
//

import SwiftUI

struct CheatSheetView: View {
    let shortcutTable: ShortcutTable

    /// `ShortcutEntry.id` of the most recently used shortcut, if any —
    /// its row is briefly highlighted. ContentView clears this after a
    /// short delay; this view just reflects whatever it's given.
    var recentlyUsedID: String? = nil

    /// Preferred display order for known categories from
    /// Resources/ShortcutTable.json; anything else (future categories)
    /// is appended afterward, alphabetically, rather than dropped.
    private static let categoryOrder: [String] = [
        "structure", "calculus", "operator", "relation", "constant", "greek", "logic"
    ]

    private static let categoryTitles: [String: String] = [
        "structure": "Structures",
        "calculus": "Calculus",
        "operator": "Operators",
        "relation": "Relations",
        "constant": "Constants",
        "greek": "Greek Letters",
        "logic": "Logic"
    ]

    private var groupedCategories: [(key: String, entries: [ShortcutEntry])] {
        let grouped = Dictionary(grouping: shortcutTable.entries, by: { $0.category })
        let known = Self.categoryOrder.filter { grouped[$0] != nil }
        let unknown = grouped.keys.filter { !Self.categoryOrder.contains($0) }.sorted()
        return (known + unknown).compactMap { key in
            guard let entries = grouped[key] else { return nil }
            // Tier 1 (single-key) entries before tier 2 (leader-sequence)
            // entries, alphabetical by trigger within each tier.
            let sorted = entries.sorted { lhs, rhs in
                if lhs.tier != rhs.tier { return lhs.tier.rawValue < rhs.tier.rawValue }
                return lhs.trigger < rhs.trigger
            }
            return (key, sorted)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Shortcuts")
                    .font(.headline)
                Spacer()
                Text("⌘/")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 8)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(groupedCategories, id: \.key) { group in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(Self.categoryTitles[group.key] ?? group.key.capitalized)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 14)

                            VStack(spacing: 1) {
                                ForEach(group.entries) { entry in
                                    CheatSheetRow(entry: entry, isHighlighted: entry.id == recentlyUsedID)
                                }
                            }
                        }
                    }
                }
                .padding(.top, 10)
                .padding(.bottom, 14)
            }
        }
        .frame(minWidth: 230, idealWidth: 260, maxWidth: 320, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

private struct CheatSheetRow: View {
    let entry: ShortcutEntry
    var isHighlighted: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            KeycapView(text: entry.trigger)

            Text(entry.symbol)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 32, alignment: .center)
                .foregroundStyle(.primary)

            Text(entry.mnemonic)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHighlighted ? Color.accentColor.opacity(0.25) : Color.clear)
        )
        .padding(.horizontal, 6)
        .animation(.easeOut(duration: 0.25), value: isHighlighted)
    }
}

private struct KeycapView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .foregroundStyle(.primary)
            .frame(minWidth: 24, minHeight: 18)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.gray.opacity(0.4), lineWidth: 1)
            )
    }
}

#Preview {
    let table = (try? ShortcutTable.loadFromBundle()) ?? ShortcutTable(version: 1, entries: [])
    return CheatSheetView(shortcutTable: table)
        .frame(height: 560)
}
