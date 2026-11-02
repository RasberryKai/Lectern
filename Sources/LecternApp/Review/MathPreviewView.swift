import AppKit
import SwiftUI
import WebKit

/// Ported from Flashcard Reviewer. A compact, offline TeX preview for card text. The caller's source is never
/// rewritten; dollar signs that do not look like math are escaped only in the
/// private preview copy passed to MathJax.
struct MathPreviewView: View {
    private let analysis: MathPreviewAnalysis
    @State private var contentHeight: CGFloat = 30

    init(text: String) {
        analysis = MathPreviewAnalysis(text: text)
    }

    var body: some View {
        if analysis.shouldShow {
            VStack(alignment: .leading, spacing: 4) {
                MathPreviewWebView(
                    previewText: analysis.previewText,
                    contentHeight: $contentHeight
                )
                .frame(height: max(contentHeight, 30))
                .accessibilityLabel("Rendered math preview")

                if let warning = analysis.warning {
                    Text(warning)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(Theme.inset, in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Theme.border, lineWidth: 1)
            }
        }
    }
}

private struct MathPreviewWebView: NSViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme
    let previewText: String
    @Binding var contentHeight: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(contentHeight: $contentHeight)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.add(context.coordinator, name: "contentHeight")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.underPageBackgroundColor = .clear
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.load(previewText, colorScheme: colorScheme, in: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.contentHeight = $contentHeight
        context.coordinator.load(previewText, colorScheme: colorScheme, in: webView)
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var contentHeight: Binding<CGFloat>
        private var loadedText: String?
        private var loadedColorScheme: ColorScheme?

        init(contentHeight: Binding<CGFloat>) {
            self.contentHeight = contentHeight
        }

        func load(_ text: String, colorScheme: ColorScheme, in webView: WKWebView) {
            guard loadedText != text || loadedColorScheme != colorScheme else { return }
            loadedText = text
            loadedColorScheme = colorScheme
            contentHeight.wrappedValue = 30

            let encodedSource = Data(text.utf8).base64EncodedString()
            let html = Self.html(encodedSource: encodedSource, colorScheme: colorScheme)
#if SWIFT_PACKAGE
            let resourceBundle = Bundle.module
#else
            let resourceBundle = Bundle.main
#endif
            let mathJaxDirectory = resourceBundle.resourceURL?
                .appendingPathComponent("MathJax", isDirectory: true)
            webView.loadHTMLString(html, baseURL: mathJaxDirectory)
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == "contentHeight", let number = message.body as? NSNumber else { return }
            let height = min(max(CGFloat(truncating: number), 30), 8_000)
            contentHeight.wrappedValue = height
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            let url = navigationAction.request.url
            return url?.isFileURL == true || url?.scheme == "about" ? .allow : .cancel
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            showLoadFailure(in: webView)
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: Error
        ) {
            showLoadFailure(in: webView)
        }

        private func showLoadFailure(in webView: WKWebView) {
            webView.evaluateJavaScript(
                "window.showMathStatus && window.showMathStatus('The bundled math preview could not be loaded.')"
            )
        }

        private static func html(encodedSource: String, colorScheme: ColorScheme) -> String {
            """
            <!doctype html>
            <html lang="en">
            <head>
              <meta charset="utf-8">
              <meta name="viewport" content="width=device-width, initial-scale=1">
              <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline' 'self' file:; style-src 'unsafe-inline'; img-src data:; font-src 'none'; connect-src 'none'; object-src 'none'; form-action 'none'; base-uri 'none'">
              <style>
                :root { color-scheme: \(colorScheme == .dark ? "dark" : "light"); }
                html, body { margin: 0; padding: 0; background: transparent; }
                body { color: CanvasText; font: 14px/1.48 -apple-system, BlinkMacSystemFont, sans-serif; overflow-wrap: anywhere; }
                #content { white-space: pre-wrap; overflow-wrap: anywhere; }
                mjx-container { max-width: 100%; }
                mjx-container[display="true"] { overflow-x: auto; overflow-y: hidden; }
                #status { display: none; margin-top: 5px; padding: 4px 7px; border-radius: 4px; background: #fff1d6; color: #714500; font: 12px/1.35 -apple-system, BlinkMacSystemFont, sans-serif; }
                \(colorScheme == .dark ? "#status { background: #493916; color: #ffe2a0; }" : "")
              </style>
              <script>
                window.__mathJaxErrors = [];
                window.showMathStatus = function(message) {
                  const status = document.getElementById('status');
                  status.textContent = message;
                  status.style.display = 'block';
                  window.reportPreviewHeight();
                };
                window.MathJax = {
                  loader: {
                    paths: {
                      tex: '[mathjax]/input/tex/extensions',
                      fonts: '[mathjax]/fonts',
                      '@mathjax': '[mathjax]/fonts'
                    },
                    failed(error) {
                      const detail = error && error.message ? error.message : 'A local math component is missing.';
                      window.showMathStatus('Math preview load error: ' + detail);
                    }
                  },
                  tex: {
                    inlineMath: {'[+]': [['$', '$']]},
                    processEscapes: true,
                    processEnvironments: false,
                    formatError(jax, error) {
                      window.__mathJaxErrors.push(String(error && error.message || 'TeX could not be parsed.'));
                      return jax.formatError(error);
                    }
                  },
                  svg: {
                    fontPath: '[mathjax]/fonts/%%FONT%%-font',
                    fontCache: 'local'
                  },
                  startup: { typeset: false }
                };
              </script>
              <script src="./tex-svg.js" onerror="window.showMathStatus('The bundled MathJax runtime could not be loaded.')"></script>
            </head>
            <body>
              <div id="content"></div>
              <div id="status" role="status" aria-live="polite"></div>
              <script>
                window.reportPreviewHeight = function() {
                  const height = Math.ceil(document.documentElement.scrollHeight);
                  if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.contentHeight) {
                    window.webkit.messageHandlers.contentHeight.postMessage(Math.max(30, height));
                  }
                };
                const encoded = '\(encodedSource)';
                const binary = atob(encoded);
                const bytes = Uint8Array.from(binary, character => character.charCodeAt(0));
                document.getElementById('content').textContent = new TextDecoder().decode(bytes);
                new ResizeObserver(window.reportPreviewHeight).observe(document.body);
                window.MathJax.startup.promise
                  .then(() => window.MathJax.typesetPromise([document.getElementById('content')]))
                  .then(() => {
                    if (window.__mathJaxErrors.length) {
                      const detail = Array.from(new Set(window.__mathJaxErrors)).join('; ');
                      window.showMathStatus('Math parse warning: ' + detail);
                    }
                    window.reportPreviewHeight();
                  })
                  .catch(error => {
                    const detail = error && error.message ? error.message : 'TeX could not be rendered.';
                    window.showMathStatus('Math preview error: ' + detail);
                  });
              </script>
            </body>
            </html>
            """
        }
    }
}

private struct MathPreviewAnalysis {
    let previewText: String
    let shouldShow: Bool
    let warning: String?

    init(text: String) {
        let characters = Array(text)
        var recognizedDollarDelimiters = Set<Int>()
        var messages = Set<String>()
        var foundMath = false
        var foundAmbiguousDollarPair = false
        var index = 0

        while index < characters.count {
            if characters[index] == "\\", !Self.isEscaped(index, in: characters), index + 1 < characters.count {
                let next = characters[index + 1]
                if next == "(" || next == "[" {
                    let closing: Character = next == "(" ? ")" : "]"
                    if let closeIndex = Self.findClosingBackslash(closing, from: index + 2, in: characters) {
                        foundMath = true
                        index = closeIndex + 2
                    } else {
                        messages.insert("A TeX math delimiter is missing its closing partner; the source is still shown as text.")
                        index += 2
                    }
                    continue
                }

                if next == ")" || next == "]" {
                    messages.insert("A TeX math closing delimiter has no matching opener; the source is still shown as text.")
                    index += 2
                    continue
                }
            }

            if characters[index] == "$", !Self.isEscaped(index, in: characters) {
                if index + 1 < characters.count, characters[index + 1] == "$" {
                    if let closeIndex = Self.findUnescapedDoubleDollar(from: index + 2, in: characters) {
                        if closeIndex == index + 2 {
                            messages.insert("An empty display-math pair was kept as text.")
                        } else {
                            foundMath = true
                            recognizedDollarDelimiters.formUnion([index, index + 1, closeIndex, closeIndex + 1])
                        }
                        index = closeIndex + 2
                    } else {
                        messages.insert("A $$ display delimiter is missing its closing partner; the source is still shown as text.")
                        index += 2
                    }
                    continue
                }

                if (index == 0 || characters[index - 1] != "$"),
                   index + 1 < characters.count,
                   characters[index + 1] != "$",
                   let closeIndex = Self.findUnescapedSingleDollar(from: index + 1, in: characters) {
                    let candidate = String(characters[(index + 1)..<closeIndex])
                    if !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       Self.looksLikeInlineMath(candidate) {
                        foundMath = true
                        recognizedDollarDelimiters.formUnion([index, closeIndex])
                    } else {
                        foundAmbiguousDollarPair = true
                    }
                    index = closeIndex + 1
                    continue
                }
            }

            index += 1
        }

        var previewCharacters = characters
        for position in characters.indices where characters[position] == "$" {
            guard !recognizedDollarDelimiters.contains(position), !Self.isEscaped(position, in: characters) else { continue }
            previewCharacters.insert("\\", at: position + (previewCharacters.count - characters.count))
        }

        if foundAmbiguousDollarPair {
            messages.insert("A dollar-delimited span looked like text or currency, so the preview kept it literal.")
        }

        previewText = String(previewCharacters)
        shouldShow = foundMath || !messages.isEmpty
        warning = messages.sorted().joined(separator: " ").nilIfEmpty
    }

    private static func findClosingBackslash(_ close: Character, from start: Int, in characters: [Character]) -> Int? {
        guard start < characters.count else { return nil }
        for index in start..<(characters.count - 1) {
            if characters[index] == "\\", characters[index + 1] == close, !isEscaped(index, in: characters) {
                return index
            }
        }
        return nil
    }

    private static func findUnescapedDoubleDollar(from start: Int, in characters: [Character]) -> Int? {
        guard start < characters.count else { return nil }
        var index = start
        while index + 1 < characters.count {
            if characters[index] == "$", characters[index + 1] == "$", !isEscaped(index, in: characters) {
                return index
            }
            index += 1
        }
        return nil
    }

    private static func findUnescapedSingleDollar(from start: Int, in characters: [Character]) -> Int? {
        guard start < characters.count else { return nil }
        var index = start
        while index < characters.count {
            if characters[index] == "$", !isEscaped(index, in: characters),
               (index == 0 || characters[index - 1] != "$"),
               (index + 1 == characters.count || characters[index + 1] != "$") {
                return index
            }
            index += 1
        }
        return nil
    }

    private static func isEscaped(_ index: Int, in characters: [Character]) -> Bool {
        guard index > 0 else { return false }
        var cursor = index - 1
        var backslashCount = 0
        while cursor >= 0, characters[cursor] == "\\" {
            backslashCount += 1
            cursor -= 1
        }
        return backslashCount.isMultiple(of: 2) == false
    }

    private static func looksLikeInlineMath(_ source: String) -> Bool {
        if source.contains("\\") { return true }
        if source.contains(where: { "=+−-*/^_<>≤≥×÷≈∼∝±".contains($0) }) { return true }

        let bareVariable = source.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "()[]{}")))
        let scalars = bareVariable.unicodeScalars
        return scalars.count == 1 && scalars.allSatisfy(CharacterSet.letters.contains)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
