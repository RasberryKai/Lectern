// Isolated fixtures only; no saved chats, model requests or lecture library access.
import AppKit
import SwiftUI
import WebKit

@MainActor @Observable private final class CitationState {
    var citation: ChatCitation?
    var events: [ChatCitation?] = []
    var clicked: ChatCitation?
}

private struct FixtureView: View {
    let state: CitationState
    let text: String
    var body: some View {
        ChatMarkdownView(text: text, onCitation: { state.clicked = ChatCitation(kind: $0, number: $1) }, onHoverCitation: {
            state.citation = $0
            state.events.append($0)
        })
        .popover(isPresented: Binding(get: { state.citation != nil }, set: { if !$0 { state.citation = nil } })) {
            Text(state.citation?.kind == "C" ? "Card preview" : "Slide preview").padding(20).allowsHitTesting(false)
        }
        .padding(16).frame(width: 500)
    }
}

@main struct ChatMarkdownCheck {
    @MainActor static func main() {
        let app = NSApplication.shared
        let state = CitationState()
        let markdown = """
        | Situation | Annual interest rate |
        | --- | --- |
        | Ordinary statutory interest under general civil law | **4%** |
        | Ordinary statutory interest where the transaction is commercial for both parties | **5%**, claimable from the due date under §353 HGB |
        | **Payment default**, with no consumer involved | **Basic rate + 9 percentage points** |
        | General default-interest rule | **Basic rate + 5 percentage points** | [S48]

        Compare [C12] with [S48].
        """
        let host = NSHostingView(rootView: FixtureView(state: state, text: markdown))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        Task { @MainActor in
            var failures = 0
            func check(_ name: String, _ passed: Bool) {
                print("\(name): \(passed ? "PASS" : "FAIL")")
                if !passed { failures += 1 }
            }
            @MainActor func findWebView(_ view: NSView) -> WKWebView? {
                if let web = view as? WKWebView { return web }
                return view.subviews.compactMap { findWebView($0) }.first
            }
            func settle() async { try? await Task.sleep(for: .milliseconds(160)) }
            do {
                var web: WKWebView?
                for _ in 0..<50 {
                    await settle()
                    if let candidate = findWebView(host),
                       (try? await candidate.evaluateJavaScript("document.querySelectorAll('.cite').length")) as? Int == 3 {
                        web = candidate; break
                    }
                }
                guard let web else { fatalError("Markdown WebKit view did not load") }
                let layout = try await web.evaluateJavaScript("""
                (()=>{const table=document.querySelector('table');return {
                    columns:[...table.rows].map(r=>r.cells.length),
                    citationInCell:!!table.rows[4].cells[1].querySelector('.cite'),
                    fillsWidth:Math.abs(table.rows[0].getBoundingClientRect().width-table.getBoundingClientRect().width)<2,
                    noHorizontalOverflow:document.body.scrollWidth<=document.body.clientWidth+1
                }})()
                """) as! [String: Any]
                check("Table rows keep their two header columns", layout["columns"] as? [Int] == [2, 2, 2, 2, 2])
                check("Trailing slide citation stays inside the value cell", layout["citationInCell"] as? Bool == true)
                check("Header fills the table width", layout["fillsWidth"] as? Bool == true)
                check("Table fits the chat width", layout["noHorizontalOverflow"] as? Bool == true)
                let escaped = ChatMarkdown.html("| A | B |\n| --- | --- |\n| x\\|y | [C12] |")
                check("Escaped pipes stay in their cell", escaped.contains("<td>x|y</td>") && escaped.components(separatedBy: "<td>").count == 3)
                let short = ChatMarkdown.html("| A | B |\n| --- | --- |\n| only one |")
                check("Short rows retain empty cells", short.contains("<td>only one</td><td></td>"))
                check("Invalid citation numbers are rejected", ChatCitation(kind: "S", number: 0) == nil && ChatCitation(kind: "X", number: 1) == nil)
                let baselineWindows = app.windows.filter(\.isVisible).count
                for kind in ["S", "C"] {
                    let number = kind == "S" ? 48 : 12
                    _ = try await web.evaluateJavaScript("document.querySelector('[data-type=\"\(kind)\"]').dispatchEvent(new MouseEvent('mouseenter'))")
                    await settle()
                    check("\(kind) hover shows the correct preview", state.citation == ChatCitation(kind: kind, number: number))
                    check("\(kind) preview window appears", app.windows.filter(\.isVisible).count > baselineWindows)
                    _ = try await web.evaluateJavaScript("document.querySelector('[data-type=\"\(kind)\"]').dispatchEvent(new MouseEvent('mouseleave'))")
                    await settle()
                    check("\(kind) mouse leave dismisses preview", state.citation == nil && state.events.last! == nil)
                    check("\(kind) preview window closes", app.windows.filter(\.isVisible).count == baselineWindows)
                }
                _ = try await web.evaluateJavaScript("document.querySelector('[data-type=\"C\"]').click()")
                await settle()
                check("Card click retains navigation", state.clicked == ChatCitation(kind: "C", number: 12))
                // Regression: JS false used to bridge to integer zero and leave a slide-0 preview open.
                _ = try await web.evaluateJavaScript("window.webkit.messageHandlers.chat.postMessage({hover:false});null")
                await settle()
                check("Legacy false hover cannot become slide zero", state.citation == nil)
                if CommandLine.arguments.count > 1 {
                    let image = try await web.takeSnapshot(configuration: nil)
                    if let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) {
                        try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
                    }
                }
            } catch { print("FAIL: \(error)"); failures += 1 }
            window.close()
            exit(failures == 0 ? 0 : 1)
        }
        app.run()
    }
}
