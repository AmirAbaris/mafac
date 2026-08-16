//
//  MathRenderView.swift
//  Mafac
//
//  Phase 0: bare KaTeX render surface. Wraps a WKWebView that loads a
//  minimal local HTML shell referencing the (not-yet-downloaded) KaTeX
//  distribution under Resources/katex/, and exposes a `latex` string that
//  gets pushed into the page via a JS call whenever it changes.
//
//  This intentionally does nothing clever yet: no debouncing, no error
//  surface beyond a console log, no bridging equation edits back out of
//  the web view. Phase 1 builds the actual math block on top of this.
//

import SwiftUI
@preconcurrency import WebKit

struct MathRenderView: NSViewRepresentable {
    /// The LaTeX source to render, e.g. `"x = \\frac{-b \\pm \\sqrt{b^2-4ac}}{2a}"`.
    var latex: String

    /// Whether to render in KaTeX's "display" (block, centered) mode vs.
    /// inline mode. Defaults to display for the Phase 0 test equation.
    var displayMode: Bool = true

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // No need for JS -> Swift messaging yet; Phase 1 may add a
        // WKScriptMessageHandler here if the math block needs the web view
        // to report anything back (e.g. rendered glyph metrics).
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        context.coordinator.pendingLatex = latex
        context.coordinator.pendingDisplayMode = displayMode

        if let shellURL = Bundle.main.url(
            forResource: "katex-shell",
            withExtension: "html",
            subdirectory: "katex"
        ) {
            webView.loadFileURL(shellURL, allowingReadAccessTo: shellURL.deletingLastPathComponent())
        } else {
            // KaTeX assets haven't been dropped in yet (see
            // Resources/katex/README.txt). Load an inline placeholder so
            // the view still shows something meaningful instead of blank.
            webView.loadHTMLString(Coordinator.missingAssetsHTML, baseURL: nil)
        }

        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.pendingLatex = latex
        context.coordinator.pendingDisplayMode = displayMode
        context.coordinator.renderIfReady()
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var webView: WKWebView?
        var pendingLatex: String = ""
        var pendingDisplayMode: Bool = true
        private var pageLoaded = false

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            pageLoaded = true
            renderIfReady()
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            print("MathRenderView: navigation failed — \(error.localizedDescription)")
        }

        func renderIfReady() {
            guard pageLoaded, let webView else { return }
            let js = Self.renderCallJS(latex: pendingLatex, displayMode: pendingDisplayMode)
            webView.evaluateJavaScript(js) { _, error in
                if let error {
                    print("MathRenderView: renderMath JS call failed — \(error.localizedDescription)")
                }
            }
        }

        /// Builds the JS call to the `renderMath` function defined in
        /// katex-shell.html, JSON-encoding the LaTeX string so embedded
        /// backslashes/quotes survive the trip into JS untouched.
        static func renderCallJS(latex: String, displayMode: Bool) -> String {
            let payload = (try? JSONEncoder().encode([latex])).flatMap {
                String(data: $0, encoding: .utf8)
            } ?? "[\"\"]"
            // payload is a JSON array literal like ["x = \\frac{1}{2}"];
            // pull the single element back out for the call.
            let jsonLatexArray = payload
            return """
            (function() {
              var args = \(jsonLatexArray);
              if (typeof renderMath === 'function') {
                renderMath(args[0], \(displayMode));
              }
            })();
            """
        }

        static let missingAssetsHTML = """
        <html>
        <body style="font: -apple-system-body; color: #888; display: flex; align-items: center; justify-content: center; height: 100vh; margin: 0;">
          <div style="text-align: center; padding: 16px;">
            KaTeX assets not found.<br/>
            Add katex.min.js / katex.min.css / fonts to Resources/katex/<br/>
            — see Resources/katex/README.txt.
          </div>
        </body>
        </html>
        """
    }
}

#Preview {
    MathRenderView(latex: #"x = \frac{-b \pm \sqrt{b^2-4ac}}{2a}"#)
        .frame(width: 480, height: 160)
}
