//
//  ContentView.swift
//  Mafac
//
//  Phase 0: just proves the KaTeX/WKWebView pipeline works end-to-end by
//  rendering one hardcoded equation. Nothing here is wired to the shortcut
//  table yet — that starts in Phase 1.
//

import SwiftUI

struct ContentView: View {
    /// Hardcoded per Phase 0 exit criteria: the quadratic formula.
    private let testEquation = #"x = \frac{-b \pm \sqrt{b^2-4ac}}{2a}"#

    var body: some View {
        VStack(spacing: 16) {
            Text("Mafac")
                .font(.largeTitle.bold())

            Text("Phase 0 — KaTeX render pipeline check")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            MathRenderView(latex: testEquation)
                .frame(minWidth: 480, minHeight: 160)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                )
        }
        .padding(24)
        .frame(minWidth: 560, minHeight: 320)
    }
}

#Preview {
    ContentView()
}
