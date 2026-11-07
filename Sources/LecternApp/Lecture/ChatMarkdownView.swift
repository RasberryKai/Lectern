import AppKit
import SwiftUI
import WebKit

/// Block Markdown is rendered locally; HTML and image syntax are deliberately literal.
struct ChatMarkdownView: View {
    let text: String
    var streaming = false
    var onCitation: (String, Int) -> Void = { _, _ in }
    var onHoverCitation: (Int?) -> Void = { _ in }
    @State private var height: CGFloat = 28
    var body: some View {
        ChatMarkdownWeb(html: ChatMarkdown.html(streaming ? ChatMarkdown.finishedBlocks(text) : text), height: $height,
                        onCitation: onCitation, onHoverCitation: onHoverCitation)
            .frame(height: max(28, height))
            .accessibilityLabel(text)
    }
}

private struct ChatMarkdownWeb: NSViewRepresentable {
    @Environment(\.colorScheme) private var scheme
    let html: String
    @Binding var height: CGFloat
    let onCitation: (String, Int) -> Void
    let onHoverCitation: (Int?) -> Void
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
        let key = "\(scheme)\(html)"
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
            if let type = body["type"] as? String, let n = body["number"] as? Int { parent.onCitation(type, n) }
            if body["hover"] != nil { parent.onHoverCitation(body["hover"] as? Int) }
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
        mjx-container{max-width:100%}mjx-container[display=true] svg{max-width:100%;height:auto}#status{color:#9b722f;font-size:11px}
        </style><script>
        function post(o){window.webkit.messageHandlers.chat.postMessage(o)}
        window.MathJax={loader:{paths:{tex:'[mathjax]/input/tex/extensions',fonts:'[mathjax]/fonts','@mathjax':'[mathjax]/fonts'}},tex:{inlineMath:{'[+]':[['$','$']]},processEscapes:true,processEnvironments:false},svg:{fontPath:'[mathjax]/fonts/%%FONT%%-font',fontCache:'local'},startup:{typeset:false}};
        </script><script src="./tex-svg.js"></script></head><body><div id="content"><main>\(html)</main><div id="status"></div></div><script>
        const content=document.getElementById('content');
        function resize(){post({height:Math.ceil(content.getBoundingClientRect().height)+1})}
        new ResizeObserver(resize).observe(content);requestAnimationFrame(resize);
        document.querySelectorAll('.cite').forEach(e=>{e.onclick=()=>post({type:e.dataset.type,number:Number(e.dataset.n)});if(e.dataset.type==='S'){e.onmouseenter=()=>post({hover:Number(e.dataset.n)});e.onmouseleave=()=>post({hover:false})}});
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
        var result = replacing(source, #"`([^`]+)`|\$\$[\s\S]+?\$\$|\$[^$\n]+?\$|!\[[^\]]*\]\([^)]*\)"#) { m, s in
            let raw = s.substring(with: m.range)
            if raw.hasPrefix("`") { return token("<code>\(escape(String(raw.dropFirst().dropLast())))</code>") }
            return token(escape(raw))
        }
        result = escape(result)
        result = replacing(result, #"\[([^\]]+)\]\((https?://[^\s)]+|mailto:[^\s)]+)\)"#) { m,s in token("<a href=\"\(s.substring(with:m.range(at:2)))\">\(s.substring(with:m.range(at:1)))</a>") }
        result = replacing(result, #"\[([SC])(\d+)(?:[–-](\d+))?\]"#) { m,s in
            let kind = s.substring(with:m.range(at:1)); let start = Int(s.substring(with:m.range(at:2))) ?? 0
            let end = m.range(at:3).location == NSNotFound ? start : Int(s.substring(with:m.range(at:3))) ?? start
            guard start > 0, end >= start, end - start < 100 else { return s.substring(with:m.range) }
            return token((start...end).map { "<button class=\"cite\" data-type=\"\(kind)\" data-n=\"\($0)\">\(kind == "S" ? "Slide" : "Card") \($0)</button>" }.joined())
        }
        result = replacing(result, #"\*\*(.+?)\*\*|__(.+?)__"#) { m,s in "<strong>\(s.substring(with:m.range(at:m.range(at:1).location == NSNotFound ? 2 : 1)))</strong>" }
        result = replacing(result, #"(?<!\*)\*([^*]+)\*(?!\*)|(?<!_)_([^_]+)_(?!_)"#) { m,s in "<em>\(s.substring(with:m.range(at:m.range(at:1).location == NSNotFound ? 2 : 1)))</em>" }
        for (index, value) in tokens.enumerated().reversed() { result = result.replacingOccurrences(of: "\u{E000}\(index)\u{E001}", with: value) }
        return result
    }
    static func html(_ source: String) -> String {
        let lines = source.components(separatedBy: .newlines)
        var index = 0, blocks: [String] = []
        func cells(_ line: String) -> [String] {
            var parts = line.trimmingCharacters(in:.whitespaces).components(separatedBy:"|")
            if parts.first?.isEmpty == true { parts.removeFirst() }; if parts.last?.isEmpty == true { parts.removeLast() }
            return parts.map { $0.trimmingCharacters(in:.whitespaces) }
        }
        while index < lines.count {
            let line = lines[index], trimmed = line.trimmingCharacters(in:.whitespaces)
            if trimmed.isEmpty { index += 1; continue }
            if trimmed.hasPrefix("```") {
                index += 1; var code: [String] = []
                while index < lines.count && !lines[index].trimmingCharacters(in:.whitespaces).hasPrefix("```") { code.append(lines[index]); index += 1 }
                blocks.append("<pre><code>\(escape(code.joined(separator:"\n")))</code></pre>"); index += 1; continue
            }
            if index + 1 < lines.count, line.contains("|"), cells(lines[index + 1]).allSatisfy({ $0.range(of:#"^:?-{3,}:?$"#,options:.regularExpression) != nil }), !cells(lines[index + 1]).isEmpty {
                let head = cells(line).map { "<th>\(inline($0))</th>" }.joined(); index += 2
                var rows: [String] = []
                while index < lines.count && lines[index].contains("|") && !lines[index].isEmpty { rows.append("<tr>" + cells(lines[index]).map { "<td>\(inline($0))</td>" }.joined() + "</tr>"); index += 1 }
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
