// Isolated rendering check for the production thumbnail list. No library data is read or written.
import AppKit
import Observation
import SwiftUI

@Observable @MainActor final class Model {
    var focusedPageIndex: Int? = 50
    var prepareFilter = Filter.all
    var scale: CGFloat = 1
    var filteredSlides: [Slide] {
        let pages = prepareFilter == .all ? Array(0..<100) : [0, 50, 99]
        return pages.map { Slide(pageIndex: $0) }
    }
}
enum Filter { case all, selected, noCards }
struct Slide: Identifiable { let pageIndex: Int; var id: Int { pageIndex } }
struct SlideCell: View {
    let model: Model
    let slide: Slide
    let width: CGFloat
    let sourceURL: URL
    @State private var loaded = false
    var body: some View {
        Rectangle().fill(.white)
            .frame(height: (loaded ? CGFloat(100 + (slide.pageIndex % 3) * 35) : 150) * model.scale)
            .overlay(Rectangle().strokeBorder(model.focusedPageIndex == slide.pageIndex ? Color.black : Color.clear, lineWidth: 3))
            .task { try? await Task.sleep(for: .milliseconds(30)); loaded = true }
    }
}
struct Sidebar: View {
    var model: Model
    var body: some View {
        CenteredThumbnailList(pageIndices: model.filteredSlides.map(\.pageIndex), focusedPageIndex: model.focusedPageIndex) { page in
            SlideCell(model: model, slide: Slide(pageIndex: page), width: 250, sourceURL: URL(fileURLWithPath: "/tmp/unused.pdf"))
        }
    }
}
@main struct CenteringCheck {
    @MainActor static func main() {
        let app = NSApplication.shared
        let model = Model()
        let host = NSHostingView(rootView: Sidebar(model: model).preferredColorScheme(.light))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 210, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        Task { @MainActor in
            var failures = 0
            @MainActor func check(_ name: String, _ view: NSView) async {
                try? await Task.sleep(for: .milliseconds(1100))
                view.layoutSubtreeIfNeeded()
                let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let scale = CGFloat(bitmap.pixelsWide) / view.bounds.width
                let rows = (0..<bitmap.pixelsHigh).filter { y in
                    let c = bitmap.colorAt(x: Int(11 * scale), y: y)!.usingColorSpace(.sRGB)!
                    return c.alphaComponent > 0.9 && max(c.redComponent, c.greenComponent, c.blueComponent) < 0.4
                }
                let midpoint = rows.first.flatMap { first in rows.last.map { CGFloat(first + $0) / 2 } } ?? -9999
                let delta = midpoint / scale - view.bounds.height / 2
                let scroll = scrollView(in: view)!
                let offset = scroll.contentView.bounds.minY
                let maximum = max(0, (scroll.documentView?.bounds.height ?? 0) - scroll.contentView.bounds.height)
                let clampedAtTop = delta < 0 && abs(offset) <= 1
                let clampedAtBottom = delta > 0 && abs(offset - maximum) <= 1
                var passed = !rows.isEmpty && (abs(delta) <= 1 || clampedAtTop || clampedAtBottom)
                if model.focusedPageIndex == model.filteredSlides.first?.pageIndex {
                    passed = passed && abs(CGFloat(rows.first ?? -9999) / scale - 10) <= 1
                }
                if maximum > 1 && model.focusedPageIndex == model.filteredSlides.last?.pageIndex {
                    passed = passed && abs(CGFloat((rows.last ?? -9999) + 1) / scale - (view.bounds.height - 10)) <= 1
                }
                print("\(name): \(passed ? "PASS" : "FAIL"), offset \(offset)/\(maximum), center delta \(delta) pt")
                if !passed { failures += 1 }
            }
            try? await Task.sleep(for: .milliseconds(700))
            await check("initial saved focus", host)
            @MainActor func scrollView(in view: NSView) -> NSScrollView? {
                if let scroll = view as? NSScrollView { return scroll }
                return view.subviews.compactMap { scrollView(in: $0) }.first
            }
            model.focusedPageIndex = 55
            await check("animation start", host)
            if let scroll = scrollView(in: host) {
                for page in [56, 57, 56, 55, 54, 53, 52, 51, 50, 49, 48, 47, 46, 45] {
                    var offsets = [scroll.contentView.bounds.minY]
                    model.focusedPageIndex = page
                    for _ in 0..<45 {
                        try? await Task.sleep(for: .milliseconds(8))
                        offsets.append(scroll.contentView.bounds.minY)
                    }
                    let deltas = zip(offsets, offsets.dropFirst()).map { $1 - $0 }
                    let direction: CGFloat = offsets.last! >= offsets.first! ? 1 : -1
                    let backwards = deltas.filter { $0 * direction < -1 }
                    let largest = deltas.map { abs($0) }.max() ?? 0
                    let distance = abs(offsets.last! - offsets.first!)
                    let distinct = Set(offsets.map { ($0 * 2).rounded() }).count
                    print("Slide \(page + 1): \(distinct) positions, largest step \(largest) pt, reversals \(backwards.count)")
                    if distinct < 4 || largest > max(40, distance * 0.5) || !backwards.isEmpty { failures += 1 }
                }
                await check("upward landing", host)
                for page in [46, 45, 44, 43, 42] {
                    model.focusedPageIndex = page
                    try? await Task.sleep(for: .milliseconds(35))
                }
                await check("interrupted upward navigation", host)
            } else { failures += 1 }
            for page in [0, 1, 50, 99, 98, 0] {
                model.focusedPageIndex = page
                await check("page \(page)", host)
            }
            for page in 0..<100 { model.focusedPageIndex = page }
            await check("rapid navigation", host)
            window.setContentSize(NSSize(width: 300, height: 850))
            await check("resized window", host)
            model.scale = 1.4
            await check("changed image sizes", host)
            model.prepareFilter = .selected
            await check("filtered", host)
            let reopened = NSHostingView(rootView: Sidebar(model: model).preferredColorScheme(.light))
            window.contentView = reopened
            await check("reopened sidebar", reopened)
            window.close()
            print("Failures: \(failures)")
            exit(failures == 0 ? 0 : 1)
        }
        app.run()
    }
}
