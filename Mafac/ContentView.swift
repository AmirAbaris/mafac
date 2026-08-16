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

import SwiftUI

struct ContentView: View {
    /// The math block's current LaTeX, pushed here (debounced) by
    /// MathBlockView every time the user edits the block.
    @State private var latex: String = ""

    private let shortcutTable: ShortcutTable? = {
        try? ShortcutTable.loadFromBundle()
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Mafac")
                .font(.largeTitle.bold())

            Text("Phase 1 — click into the math block and type shortcut keys (e.g. r → √, f → fraction, p → π, i → ∫, ^ / _ → super/subscript). Anything not in the table types literally.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let shortcutTable {
                Text("MATH BLOCK")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                MathBlockView(shortcutTable: shortcutTable) { newLatex in
                    latex = newLatex
                }
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
    }
}

#Preview {
    ContentView()
}
