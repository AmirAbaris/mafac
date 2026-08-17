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
//  apply to whatever precedes them (_{}, ^{}). Fractions are stacked
//  properly — numerator over denominator with a rule between them, drawn
//  as a FractionAttachment (below) and composed recursively, so nested
//  fractions work. Roots still render as "√(...)"; a real radical with an
//  overbar would need the same attachment treatment. Everything else
//  (plain characters, unrecognized commands) passes through literally so
//  nothing is ever silently dropped.
//

import AppKit

enum LaTeXInlineRenderer {

    /// Commands the renderer lays out structurally in `renderExpr` rather
    /// than replacing with a single glyph — their `symbol` field in the
    /// table is a cheat-sheet mock-up ("a/b"), not a substitution.
    private static let structuralCommands: Set<String> = ["frac", "sqrt"]

    /// One-to-one symbol substitutions for zero-argument commands, derived
    /// from ShortcutTable.json's `symbol` field so that adding a row to the
    /// table is all it takes to make that symbol render — a hand-maintained
    /// copy here would silently fall through to literal "\rho" text for any
    /// entry someone forgot to mirror.
    ///
    /// Falls back to the built-in table below if the bundle resource can't
    /// be loaded, so rendering degrades to "the symbols we shipped with"
    /// rather than to raw LaTeX source everywhere.
    private static let symbolMap: [String: String] = {
        guard let table = try? ShortcutTable.loadFromBundle() else { return fallbackSymbolMap }
        var map = fallbackSymbolMap
        for entry in table.entries {
            guard entry.latex.hasPrefix("\\") else { continue }
            let name = String(entry.latex.dropFirst().prefix { $0.isLetter })
            guard !name.isEmpty, !structuralCommands.contains(name) else { continue }
            map[name] = entry.symbol
        }
        return map
    }()

    private static let fallbackSymbolMap: [String: String] = [
        "pi": "π", "infty": "∞", "leq": "≤", "geq": "≥", "to": "→", "neq": "≠",
        "pm": "±", "times": "×", "div": "÷", "approx": "≈", "in": "∈",
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "theta": "θ",
        "lambda": "λ", "mu": "μ", "omega": "ω", "forall": "∀", "exists": "∃",
        "int": "∫", "sum": "Σ", "prod": "∏", "rho": "ρ", "partial": "∂"
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
                // A single space after a control word is LaTeX's command
                // terminator, not content: "\partial y" is ∂y, not "∂ y".
                // Absorb it so the space MathBoxTextView inserts to keep
                // "\partial" and "y" from merging doesn't show up as a gap
                // in the typeset output.
                if index < chars.count, chars[index] == " " {
                    index += 1
                }
                switch name {
                case "frac":
                    let numerator = consumeGroup(&chars, &index, font: font, color: color)
                    let denominator = consumeGroup(&chars, &index, font: font, color: color)
                    let stacked = FractionAttachment(
                        numerator: numerator,
                        denominator: denominator,
                        font: font,
                        color: color
                    )
                    result.append(NSAttributedString(attachment: stacked))
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

    /// A `\frac{}{}` drawn the way it's written by hand: numerator over
    /// denominator, separated by a horizontal rule, as one inline glyph.
    ///
    /// Both halves arrive already rendered, so this composes recursively —
    /// a fraction inside a fraction, or a `\partial` inside either half,
    /// is just an attributed string that gets measured and drawn here.
    ///
    /// The rule is centred on the font's *math axis* (about half the
    /// x-height above the baseline) rather than on the baseline itself.
    /// That is what makes a fraction sit visually level with an adjacent
    /// "=" instead of riding high or sinking into the following text.
    private final class FractionAttachment: NSTextAttachment {
        init(numerator: NSAttributedString, denominator: NSAttributedString, font: NSFont, color: NSColor) {
            super.init(data: nil, ofType: nil)

            let numeratorSize = numerator.size()
            let denominatorSize = denominator.size()
            // Proportional to point size so the fraction keeps its
            // proportions at any font size.
            let ruleThickness = max(1, (font.pointSize * 0.055).rounded())
            let verticalGap = font.pointSize * 0.16
            let sidePadding = font.pointSize * 0.14

            // Clamped so an unfilled "\frac{}{}" (both halves empty, zero
            // width) can't ask for a degenerate zero-width NSImage.
            let width = max(numeratorSize.width, denominatorSize.width, font.pointSize * 0.6) + sidePadding * 2
            let height = numeratorSize.height + verticalGap + ruleThickness + verticalGap + denominatorSize.height
            let ruleBottom = denominatorSize.height + verticalGap

            image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
                numerator.draw(at: NSPoint(
                    x: (width - numeratorSize.width) / 2,
                    y: ruleBottom + ruleThickness + verticalGap
                ))
                denominator.draw(at: NSPoint(x: (width - denominatorSize.width) / 2, y: 0))
                color.setFill()
                NSBezierPath(rect: NSRect(
                    x: sidePadding * 0.5,
                    y: ruleBottom,
                    width: width - sidePadding,
                    height: ruleThickness
                )).fill()
                return true
            }

            let mathAxis = font.xHeight * 0.5
            let ruleCentreFromBottom = ruleBottom + ruleThickness / 2
            bounds = CGRect(x: 0, y: mathAxis - ruleCentreFromBottom, width: width, height: height)
        }

        required init?(coder: NSCoder) {
            fatalError("FractionAttachment does not support NSCoding")
        }
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
