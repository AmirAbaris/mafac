//
//  LaTeXInlineRenderer.swift
//  Mafac
//
//  Turns the small, known vocabulary of LaTeX that ShortcutTable.json's
//  entries can produce into a typeset NSAttributedString — real ∫/√/π
//  glyphs, superscripts/subscripts with actual baseline shifts, rather
//  than the raw "\int_{}^{}" source text.
//
//  This is NOT a general LaTeX engine. It only needs to handle what the
//  shortcut system can generate (see ShortcutTable.json): zero-argument
//  symbol commands (\pi, \leq, ...), the two commands that take their own
//  brace groups (\frac{}{}, \sqrt{}), and the two postfix operators that
//  apply to whatever precedes them (_{}, ^{}). Fractions render as
//  "numerator⁄denominator" (inline slash, not a stacked bar) and roots as
//  "√(...)" — real 2D stacked layout would need a custom-drawn
//  NSTextAttachment per structure, out of scope for v1. Everything else
//  (plain characters, unrecognized commands) passes through literally so
//  nothing is ever silently dropped.
//

import AppKit

enum LaTeXInlineRenderer {

    /// One-to-one symbol substitutions for zero-argument commands —
    /// mirrors ShortcutTable.json's `symbol` field for every entry whose
    /// `latex` is a bare `\name` with no brace groups.
    private static let symbolMap: [String: String] = [
        "pi": "π", "infty": "∞", "leq": "≤", "geq": "≥", "to": "→", "neq": "≠",
        "pm": "±", "times": "×", "div": "÷", "approx": "≈", "in": "∈",
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "theta": "θ",
        "lambda": "λ", "mu": "μ", "omega": "ω", "forall": "∀", "exists": "∃",
        "int": "∫", "sum": "Σ", "prod": "∏"
    ]

    /// Renders `latex` (as produced by MathBlockTextView, hole
    /// placeholders "▢" included verbatim) into an attributed string using
    /// `font`/`color` as the base style.
    static func render(_ latex: String, font: NSFont, color: NSColor) -> NSAttributedString {
        var chars = Array(latex)
        var index = 0
        return renderExpr(&chars, &index, font: font, color: color)
    }

    private static func renderExpr(_ chars: inout [Character], _ index: inout Int, font: NSFont, color: NSColor) -> NSMutableAttributedString {
        let result = NSMutableAttributedString()
        let baseAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]

        while index < chars.count {
            let c = chars[index]
            if c == "}" {
                break // caller (consumeGroup) consumes the matching brace
            } else if c == "\\" {
                index += 1
                var name = ""
                while index < chars.count, chars[index].isLetter {
                    name.append(chars[index])
                    index += 1
                }
                switch name {
                case "frac":
                    let numerator = consumeGroup(&chars, &index, font: font, color: color)
                    let denominator = consumeGroup(&chars, &index, font: font, color: color)
                    result.append(numerator)
                    result.append(NSAttributedString(string: "\u{2044}", attributes: baseAttrs))
                    result.append(denominator)
                case "sqrt":
                    let inner = consumeGroup(&chars, &index, font: font, color: color)
                    result.append(NSAttributedString(string: "\u{221A}(", attributes: baseAttrs))
                    result.append(inner)
                    result.append(NSAttributedString(string: ")", attributes: baseAttrs))
                default:
                    let symbol = symbolMap[name] ?? ("\\" + name)
                    result.append(NSAttributedString(string: symbol, attributes: baseAttrs))
                }
            } else if c == "_" {
                index += 1
                result.append(scriptGroup(&chars, &index, font: font, color: color, superscript: false))
            } else if c == "^" {
                index += 1
                result.append(scriptGroup(&chars, &index, font: font, color: color, superscript: true))
            } else {
                result.append(NSAttributedString(string: String(c), attributes: baseAttrs))
                index += 1
            }
        }
        return result
    }

    /// Consumes a `{...}` group starting at `chars[index]` (which must be
    /// "{") and renders its contents recursively. Returns empty if there's
    /// no group there (malformed input — never expected from the shortcut
    /// system, but this keeps the renderer from ever crashing on it).
    private static func consumeGroup(_ chars: inout [Character], _ index: inout Int, font: NSFont, color: NSColor) -> NSAttributedString {
        guard index < chars.count, chars[index] == "{" else { return NSAttributedString() }
        index += 1
        let inner = renderExpr(&chars, &index, font: font, color: color)
        if index < chars.count, chars[index] == "}" {
            index += 1
        }
        return inner
    }

    /// Renders a `_{...}`/`^{...}` group at a smaller size, shifted off
    /// the baseline — real subscript/superscript styling rather than a
    /// literal underscore/caret character.
    private static func scriptGroup(_ chars: inout [Character], _ index: inout Int, font: NSFont, color: NSColor, superscript: Bool) -> NSAttributedString {
        let smallFont = NSFont(descriptor: font.fontDescriptor, size: font.pointSize * 0.68) ?? font
        let group = NSMutableAttributedString(attributedString: consumeGroup(&chars, &index, font: smallFont, color: color))
        let offset = superscript ? font.pointSize * 0.32 : -font.pointSize * 0.22
        group.addAttribute(.baselineOffset, value: offset, range: NSRange(location: 0, length: group.length))
        return group
    }
}
