import AppKit
#if SWIFT_PACKAGE
import LecternCore
#endif
import SwiftUI
import WebKit

enum ChatCitation: Equatable {
    case slide(Int)
    case card(Int)

    init?(kind: String, number: Int) {
        guard number > 0 else { return nil }
        switch kind {
        case "S": self = .slide(number)
        case "C": self = .card(number)
        default: return nil
        }
    }
}

/// Block Markdown is rendered locally; HTML and image syntax are deliberately literal.
struct ChatMarkdownView: View {
    let text: String
    var streaming = false
    let onCitation: (ChatCitation) -> Void
    @State private var height: CGFloat = 28
    var body: some View {
        ChatMarkdownWeb(html: ChatMarkdown.html(streaming ? ChatMarkdown.finishedBlocks(text) : text), streaming: streaming, height: $height,
                        onCitation: onCitation)
            .frame(height: max(28, height))
            .accessibilityLabel(text)
    }
}

private struct ChatMarkdownWeb: NSViewRepresentable {
    @Environment(\.colorScheme) private var scheme
    let html: String
    var streaming = false
    @Binding var height: CGFloat
    let onCitation: (ChatCitation) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(context.coordinator, name: "chat")
        let view = ChatResponseWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        view.underPageBackgroundColor = .clear
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.parent = self
        let key = "\(scheme)\(streaming)\(html)"
        guard context.coordinator.key != key else { return }
        context.coordinator.key = key
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        view.loadHTMLString(document, baseURL: bundle.resourceURL?.appendingPathComponent("MathJax", isDirectory: true))
    }
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "chat")
    }
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var parent: ChatMarkdownWeb
        var key = ""
        init(_ parent: ChatMarkdownWeb) { self.parent = parent }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any] else { return }
            if let height = body["height"] as? Double, height.isFinite {
                let measured = max(28, CGFloat(height))
                if abs(parent.height - measured) > 0.5 { parent.height = measured }
            }
            if let kind = body["type"] as? String, let number = body["number"] as? Int,
               let citation = ChatCitation(kind: kind, number: number) {
                parent.onCitation(citation)
            }
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = navigationAction.request.url else { return .cancel }
            if navigationAction.navigationType == .linkActivated {
                if ["https", "http", "mailto"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }
                return .cancel
            }
            return url.isFileURL || url.scheme == "about" ? .allow : .cancel
        }
    }
    private var document: String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline' 'self' file:; style-src 'unsafe-inline'; img-src 'none'; font-src 'none'; connect-src 'none'; object-src 'none'">
        <style>
        :root{color-scheme:\(scheme == .dark ? "dark" : "light")}
        html,body{margin:0;padding:0;overflow:hidden}
        body{margin:0;background:transparent;color:CanvasText;font:13.5px/1.55 -apple-system;overflow-wrap:anywhere}
        #content{display:flow-root;width:100%;min-width:0}
        p{margin:0 0 10px}h4{font-size:14px;margin:15px 0 6px}ul,ol{padding-left:23px;margin:6px 0 12px}li>ul,li>ol{margin:2px 0}
        blockquote{margin:10px 0;padding:5px 12px;border-left:3px solid #8ba0b3;color:\(scheme == .dark ? "#c0bbb0" : "#666258")}
        code{font:12px ui-monospace,monospace;background:\(scheme == .dark ? "#34312b" : "#eeece6");padding:2px 4px;border-radius:4px}pre{white-space:pre-wrap;overflow-wrap:anywhere;padding:10px;background:\(scheme == .dark ? "#292722" : "#f0eee8");border-radius:7px}pre code{padding:0;background:none}
        .table{border:1px solid \(scheme == .dark ? "#49443a" : "#dedacf");border-radius:8px;margin:10px 0}table{border-collapse:collapse;width:100%;table-layout:fixed;font-size:12.5px;overflow-wrap:anywhere;word-break:normal}th{background:\(scheme == .dark ? "#33342f" : "#e9ede7");font-weight:600}td,th{padding:7px 9px;text-align:left;border-bottom:1px solid \(scheme == .dark ? "#423e36" : "#e5e1d7")}
        a{color:\(scheme == .dark ? "#9dc3eb" : "#2f5d8c")}button.cite{font:11px -apple-system;cursor:pointer;color:\(scheme == .dark ? "#bbd4eb" : "#2f5d8c");background:\(scheme == .dark ? "#293847" : "#e7eef5");border:0;border-radius:4px;padding:2px 5px;vertical-align:baseline;margin:0 2px}
        main.streaming>:is(p,h4):last-child::after,main.streaming>blockquote:last-child>p:last-child::after,main.streaming>:is(ul,ol):last-child>li:last-child:not(:has(>ul,>ol))::after,main.streaming>:is(ul,ol):last-child>li:last-child>:is(ul,ol):last-child>li:last-child::after{content:'';display:inline-block;width:7px;height:14px;margin-left:3px;border-radius:2px;background:\(scheme == .dark ? "#8db4dd" : "#2f5d8c");vertical-align:-2px;animation:caret 1s ease-in-out infinite}
        @keyframes caret{0%,100%{opacity:.25}50%{opacity:1}}@media (prefers-reduced-motion: reduce){main.streaming *::after{animation:none!important;opacity:.7}}
        mjx-container{max-width:100%}mjx-container[display=true] svg{max-width:100%;height:auto}#status{color:#9b722f;font-size:11px}
        </style><script>
        function post(o){window.webkit.messageHandlers.chat.postMessage(o)}
        window.MathJax={loader:{paths:{tex:'[mathjax]/input/tex/extensions',fonts:'[mathjax]/fonts','@mathjax':'[mathjax]/fonts'}},tex:{inlineMath:{'[+]':[['$','$']]},processEscapes:true,processEnvironments:false},svg:{fontPath:'[mathjax]/fonts/%%FONT%%-font',fontCache:'local'},startup:{typeset:false}};
        </script><script src="./tex-svg.js"></script></head><body><div id="content"><main\(streaming ? " class='streaming'" : "")>\(html)</main><div id="status"></div></div><script>
        const content=document.getElementById('content');
        function resize(){post({height:Math.ceil(content.getBoundingClientRect().height)+1})}
        new ResizeObserver(resize).observe(content);requestAnimationFrame(resize);
        document.querySelectorAll('.cite').forEach(e=>{
            e.onclick=()=>post({type:e.dataset.type,number:Number(e.dataset.n)});
        });
        if(window.MathJax.startup)window.MathJax.startup.promise.then(()=>window.MathJax.typesetPromise()).then(resize).catch(()=>{document.getElementById('status').textContent='Math could not be rendered; source is shown.';resize()});
        </script></body></html>
        """
    }
}

/// WebKit renders each response at its full height; the transcript owns scrolling.
private final class ChatResponseWebView: WKWebView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        if NSApp.currentEvent?.type == .scrollWheel { return self }
        return super.hitTest(point)
    }

    override func scrollWheel(with event: NSEvent) {
        var ancestor = superview
        while let view = ancestor {
            if let scroll = view as? NSScrollView {
                scroll.scrollWheel(with: event)
                return
            }
            ancestor = view.superview
        }
        nextResponder?.scrollWheel(with: event)
    }
}

nonisolated enum ChatMarkdown {
    static func finishedBlocks(_ text: String) -> String {
        guard let range = text.range(of: "\n\n", options: .backwards) else { return "" }
        let prefix = String(text[..<range.lowerBound])
        return prefix.components(separatedBy: "```").count.isMultiple(of: 2) ? String(prefix.prefix(upTo: prefix.range(of: "```", options: .backwards)!.lowerBound)) : prefix
    }
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
    static func replacing(_ source: String, _ pattern: String, _ replacement: (NSTextCheckingResult, NSString) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return source }
        let string = source as NSString
        var output = source
        for match in regex.matches(in: source, range: NSRange(location: 0, length: string.length)).reversed() {
            guard let range = Range(match.range, in: output) else { continue }
            output.replaceSubrange(range, with: replacement(match, string))
        }
        return output
    }
    static func inline(_ source: String) -> String {
        var tokens: [String] = []
        func token(_ value: String) -> String { tokens.append(value); return "\u{E000}\(tokens.count - 1)\u{E001}" }
        var result = replacing(source, ChatCitationMarkup.literalPattern) { m, s in
            let raw = s.substring(with: m.range)
            if raw.hasPrefix("`") { return token("<code>\(escape(String(raw.dropFirst().dropLast())))</code>") }
            return token(escape(raw))
        }
        result = escape(result)
        result = replacing(result, #"\[([^\]]+)\]\((https?://[^\s)]+|mailto:[^\s)]+)\)"#) { m,s in token("<a href=\"\(s.substring(with:m.range(at:2)))\">\(s.substring(with:m.range(at:1)))</a>") }
        result = replacing(result, ChatCitationMarkup.citationPattern) { m,s in
            guard let buttons = citationButtons(s.substring(with: m.range(at: 1))) else { return s.substring(with: m.range) }
            return token(buttons)
        }
        result = replacing(result, #"\*\*(.+?)\*\*|__(.+?)__"#) { m,s in "<strong>\(s.substring(with:m.range(at:m.range(at:1).location == NSNotFound ? 2 : 1)))</strong>" }
        result = replacing(result, #"(?<!\*)\*([^*]+)\*(?!\*)|(?<!_)_([^_]+)_(?!_)"#) { m,s in "<em>\(s.substring(with:m.range(at:m.range(at:1).location == NSNotFound ? 2 : 1)))</em>" }
        for (index, value) in tokens.enumerated().reversed() { result = result.replacingOccurrences(of: "\u{E000}\(index)\u{E001}", with: value) }
        return result
    }

    private static func citationButtons(_ source: String) -> String? {
        ChatCitationMarkup.targets(in: source)?.map { kind, number in
            "<button class=\"cite\" data-type=\"\(kind)\" data-n=\"\(number)\">\(kind == "S" ? "Slide" : "Card") \(number)</button>"
        }.joined()
    }

    static func html(_ source: String) -> String {
        let lines = source.components(separatedBy: .newlines)
        var index = 0, blocks: [String] = []
        func cells(_ line: String) -> [String] {
            var literals: [String] = []
            let protected = replacing(line, ChatCitationMarkup.literalPattern) { match, text in
                literals.append(text.substring(with: match.range))
                return "\u{E000}\(literals.count - 1)\u{E001}"
            }
            var parts = [""]
            var escaped = false
            for character in protected.trimmingCharacters(in: .whitespaces) {
                if character == "|", !escaped { parts.append("") }
                else {
                    if character == "|", escaped { parts[parts.count - 1].removeLast() }
                    parts[parts.count - 1].append(character)
                }
                escaped = character == "\\" && !escaped
            }
            if parts.first?.isEmpty == true { parts.removeFirst() }; if parts.last?.isEmpty == true { parts.removeLast() }
            return parts.map { part in
                var cell = part.trimmingCharacters(in: .whitespaces)
                for (index, literal) in literals.enumerated().reversed() {
                    cell = cell.replacingOccurrences(of: "\u{E000}\(index)\u{E001}", with: literal)
                }
                return cell
            }
        }
        while index < lines.count {
            let line = lines[index], trimmed = line.trimmingCharacters(in:.whitespaces)
            if trimmed.isEmpty { index += 1; continue }
            if trimmed.hasPrefix("```") {
                index += 1; var code: [String] = []
                while index < lines.count && !lines[index].trimmingCharacters(in:.whitespaces).hasPrefix("```") { code.append(lines[index]); index += 1 }
                blocks.append("<pre><code>\(escape(code.joined(separator:"\n")))</code></pre>"); index += 1; continue
            }
            if index + 1 < lines.count, line.contains("|"), !cells(line).isEmpty, cells(lines[index + 1]).allSatisfy({ $0.range(of:#"^:?-{3,}:?$"#,options:.regularExpression) != nil }), !cells(lines[index + 1]).isEmpty {
                let headers = cells(line)
                let head = headers.map { "<th>\(inline($0))</th>" }.joined(); index += 2
                var rows: [String] = []
                while index < lines.count && lines[index].contains("|") && !lines[index].isEmpty {
                    var row = cells(lines[index])
                    // A citation after the final pipe still belongs to the last column.
                    // Keep every row aligned to its headers without dropping that citation.
                    if row.count > headers.count {
                        row = Array(row.prefix(headers.count - 1)) + [row.dropFirst(headers.count - 1).joined(separator: " ")]
                    }
                    row += Array(repeating: "", count: max(0, headers.count - row.count))
                    rows.append("<tr>" + row.map { "<td>\(inline($0))</td>" }.joined() + "</tr>")
                    index += 1
                }
                blocks.append("<div class=\"table\"><table><thead><tr>\(head)</tr></thead><tbody>\(rows.joined())</tbody></table></div>"); continue
            }
            if trimmed.hasPrefix(">") {
                var quotes: [String] = []
                while index < lines.count && lines[index].trimmingCharacters(in:.whitespaces).hasPrefix(">") { quotes.append(String(lines[index].trimmingCharacters(in:.whitespaces).dropFirst())); index += 1 }
                blocks.append("<blockquote>\(html(quotes.joined(separator:"\n")))</blockquote>"); continue
            }
            if trimmed.range(of:#"^#{1,6}\s"#,options:.regularExpression) != nil {
                blocks.append("<h4>\(inline(trimmed.replacingOccurrences(of:#"^#{1,6}\s+"#,with:"",options:.regularExpression)))</h4>"); index += 1; continue
            }
            if trimmed.range(of:#"^(?:[-+*]|\d+[.)])\s+"#,options:.regularExpression) != nil {
                let ordered = trimmed.first?.isNumber == true, tag = ordered ? "ol" : "ul"
                var items: [String] = []
                while index < lines.count {
                    let item = lines[index].trimmingCharacters(in:.whitespaces)
                    guard item.range(of:#"^(?:[-+*]|\d+[.)])\s+"#,options:.regularExpression) != nil else { break }
                    let content = item.replacingOccurrences(of:#"^(?:[-+*]|\d+[.)])\s+"#,with:"",options:.regularExpression)
                    index += 1; var nested: [String] = []
                    while index < lines.count && (lines[index].hasPrefix("  ") || lines[index].hasPrefix("\t")) { nested.append(String(lines[index].dropFirst(2))); index += 1 }
                    items.append("<li>\(inline(content))\(html(nested.joined(separator:"\n")))</li>")
                }
                blocks.append("<\(tag)>\(items.joined())</\(tag)>"); continue
            }
            var paragraph = [line]; index += 1
            while index < lines.count && !lines[index].trimmingCharacters(in:.whitespaces).isEmpty && lines[index].range(of:#"^\s*(?:#|>|```|[-+*] |\d+[.)] )"#,options:.regularExpression) == nil {
                if index + 1 < lines.count && lines[index].contains("|") && lines[index + 1].contains("---") { break }
                paragraph.append(lines[index]); index += 1
            }
            blocks.append("<p>\(inline(paragraph.joined(separator:"\n")))</p>")
        }
        return blocks.joined(separator:"\n")
    }
}
