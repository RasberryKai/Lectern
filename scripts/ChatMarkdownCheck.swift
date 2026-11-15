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
        .padding(16).frame(width: 660)
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
        // The probability table and range syntax reproduce the reported rendering failures.
        let mathMarkdown = #"""

        | Concept | What it tells you | How to calculate it |
        |---|---|---|
        | **Probability function** \(f(x)\) | Probability of exactly \(x\) | \(f(x)=P(X=x)\); all probabilities sum to 1. [S70] |
        | **Cumulative distribution function** \(F(x)\) | Probability of getting \(x\) **or less** | \(F(x)=P(X\le x)=\sum_{x_i\le x}f(x_i)\). [S73] |
        | **Mean / expected value** \(\mu\) | The probability-weighted average | \(\mu=E(X)=\sum_i x_i f(x_i)\). [S77] |
        | **Variance** \(\sigma^2\) | How spread out outcomes are around the mean | \(\operatorname{Var}(X)=\sum_i (x_i-\mu)^2f(x_i)\). [S79] |
        | **Standard deviation** \(\sigma\) | Spread in the **same units as X** | \(\sigma=\sqrt{\operatorname{Var}(X)}\). [S65] |

        **Useful shortcut:** \(\operatorname{Var}(X)=E(X^2)-[E(X)]^2\). [S79–S80]

        | Math with pipes | Other delimiters |
        | --- | --- |
        | \(P(X=x|Y=y)\) | $x_i + y_i$ |
        | \(\|x_i\|\) | $$\sum_i x_i$$ |
        | `x|y` | \[\sum_i x_i\] |

        Grouped citations: [S70, S73, S77–S79]; [C12–C13]; [S79-80]; [S79—S80]; [S70, 73–74]; [S70; C12].

        Literal code: `[S79–S80] \(x_i + y_i\)`
        """#
        let host = NSHostingView(rootView: FixtureView(state: state, text: markdown + "\n" + mathMarkdown))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(45))
            print("FAIL: Markdown check timed out")
            exit(1)
        }
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
                       (try? await candidate.evaluateJavaScript("document.readyState === 'complete' && !!window.MathJax?.startup?.document")) as? Bool == true {
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
                for _ in 0..<50 {
                    if (try await web.evaluateJavaScript("document.querySelectorAll('mjx-container').length")) as? Int == 18 { break }
                    await settle()
                }
                let math = try await web.evaluateJavaScript("""
                (()=>{
                    const tables=document.querySelectorAll('table');
                    return {
                        rowMath:[...tables[1].tBodies[0].rows].map(r=>r.querySelectorAll('mjx-container').length),
                        intactFormula:tables[1].rows[2].cells[2].querySelectorAll('em').length===0,
                        pipeColumns:[...tables[2].rows].map(r=>r.cells.length),
                        literalPipe:tables[2].rows[3].cells[0].querySelector('code')?.textContent==='x|y',
                        pipeMath:tables[2].querySelectorAll('mjx-container').length,
                        mathErrors:document.querySelectorAll('[data-mjx-error],merror').length,
                        buttons:[...document.querySelectorAll('.cite')].map(e=>e.dataset.type+e.dataset.n),
                        literalCode:[...document.querySelectorAll('code')].some(e=>e.textContent.includes('[S79–S80]') && !e.querySelector('.cite,mjx-container'))
                    };
                })()
                """) as! [String: Any]
                check("Every formula in the reported table is typeset", math["rowMath"] as? [Int] == [3, 3, 2, 2, 2])
                check("TeX subscripts are not converted to Markdown emphasis", math["intactFormula"] as? Bool == true)
                check("Pipes inside math and code preserve table columns and content", math["pipeColumns"] as? [Int] == [2, 2, 2, 2] && math["literalPipe"] as? Bool == true)
                check("All math delimiters typeset inside table cells", math["pipeMath"] as? Int == 5)
                check("MathJax reports no formula errors", math["mathErrors"] as? Int == 0)
                check("Ranges and grouped citations expand to individual targets", math["buttons"] as? [String] == [
                    "S48", "C12", "S48", "S70", "S73", "S77", "S79", "S65", "S79", "S80",
                    "S70", "S73", "S77", "S78", "S79", "C12", "C13", "S79", "S80", "S79", "S80", "S70", "S73", "S74", "S70", "C12"
                ])
                check("Code keeps citation and math source literal", math["literalCode"] as? Bool == true)
                for invalid in ["[S0]", "[S80–S79]", "[S1–S101]", "[S1–C2]", "[S999999999999999999999]"] {
                    check("Invalid range stays literal: \(invalid)", ChatMarkdown.inline(invalid) == invalid)
                }
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
                _ = try await web.evaluateJavaScript("[...document.querySelectorAll('p')].find(p=>p.textContent.startsWith('Useful shortcut:')).querySelector('[data-type=\"S\"][data-n=\"80\"]')?.click()")
                await settle()
                check("Range endpoint retains slide navigation", state.clicked == ChatCitation(kind: "S", number: 80))
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
