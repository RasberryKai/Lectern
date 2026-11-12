// Isolated check: generated PDFs only; no lecture/library data is accessed.
import AppKit
import PDFKit
import SwiftUI

// Only the design tokens needed to compile the production viewer in isolation.
@MainActor enum Theme {
    static let caption = Font.system(size: 11)
    static let small = Font.system(size: 12)
    static let quiet = Color.secondary
    static let inset = Color.gray.opacity(0.1)
}

@MainActor private final class CheckPageView: NSView {
    var color = NSColor.white
    var label = ""

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        bounds.fill()
        (label as NSString).draw(at: NSPoint(x: 40, y: 80), withAttributes: [
            .font: NSFont.systemFont(ofSize: 24), .foregroundColor: NSColor.black
        ])
    }
}

@main struct SlideZoomCheck {
    @MainActor static func main() {
        let app = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("slides.pdf")
        let document = PDFDocument()
        let colors: [NSColor] = [.white, .yellow, .cyan, .magenta, .green, .orange]
        for (index, color) in colors.enumerated() {
            let size = index == 1 ? NSSize(width: 540, height: 960) : NSSize(width: 960, height: 540)
            let content = CheckPageView(frame: NSRect(origin: .zero, size: size))
            content.color = color
            content.label = "Slide \(index + 1) — zoom check"
            let rendered = PDFDocument(data: content.dataWithPDF(inside: content.bounds))!
            let page = rendered.page(at: 0)!.copy() as! PDFPage
            if index == 1 { page.rotation = 90 }
            document.insert(page, at: index)
        }
        document.write(to: source)
        let host = NSHostingView(rootView: ZoomableSlideView(sourceURL: source, pageIndex: 0))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)

        Task { @MainActor in
            var failures = 0
            func check(_ name: String, _ passed: Bool) {
                print("\(name): \(passed ? "PASS" : "FAIL")")
                if !passed { failures += 1 }
            }
            @MainActor func settle() async {
                try? await Task.sleep(for: .milliseconds(150))
                host.layoutSubtreeIfNeeded()
            }
            @MainActor func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
                if let match = view as? T { return match }
                return view.subviews.compactMap { find(type, in: $0) }.first
            }
            @MainActor func capture(_ name: String) {
                guard CommandLine.arguments.count > 1,
                      let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let url = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("\(name).png")
                try! bitmap.representation(using: .png, properties: [:])!.write(to: url)
            }
            await settle()
            guard let viewer = find(ZoomablePDFView.self, in: host) else { fatalError("PDF viewer was not mounted") }
            guard let preview = viewer.subviews.compactMap({ $0 as? NSImageView }).first else {
                fatalError("Fitted slide preview was not mounted")
            }
            @MainActor func centerColor() -> NSColor? {
                guard let bitmap = viewer.bitmapImageRepForCachingDisplay(in: viewer.bounds) else { return nil }
                viewer.cacheDisplay(in: viewer.bounds, to: bitmap)
                return bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB)
            }
            // Use the settled fitted view as the reference, so display color
            // management cannot turn a correct first frame into a false failure.
            var referenceColors: [Int: NSColor] = [:]
            for index in colors.indices {
                host.rootView = ZoomableSlideView(sourceURL: source, pageIndex: index)
                await settle()
                referenceColors[index] = centerColor()
            }
            @MainActor func displaysPage(_ index: Int) -> Bool {
                guard let actual = centerColor(), let expected = referenceColors[index] else { return false }
                return abs(actual.redComponent - expected.redComponent) < 0.05
                    && abs(actual.greenComponent - expected.greenComponent) < 0.05
                    && abs(actual.blueComponent - expected.blueComponent) < 0.05
            }
            host.rootView = ZoomableSlideView(sourceURL: source, pageIndex: 0)
            await settle()
            // Fetch the same shared-cache entry: navigation must reuse this exact image,
            // rather than doing a fresh synchronous render when the next slide is selected.
            let next = try! await PDFThumbnailProvider.shared.thumbnail(sourceURL: source, pageIndex: 1, width: 1120)
            await settle()
            var factor: CGFloat = 0
            var available = false
            var failed = false
            let originalCallback = viewer.onZoomChange
            viewer.onZoomChange = { newFactor, newAvailable, newFailed in
                factor = newFactor; available = newAvailable; failed = newFailed
                originalCallback?(newFactor, newAvailable, newFailed)
            }
            viewer.fit()
            check("initial page fits", viewer.scaleFactor > 0 && abs(viewer.scaleFactor - viewer.minScaleFactor) < 0.001)
            check("single page is isolated", viewer.document?.pageCount == 1)
            capture("slide-fit")
            if let scroll = viewer.documentView?.enclosingScrollView {
                let fittedScale = viewer.scaleFactor
                let center = NSPoint(x: scroll.contentView.bounds.midX, y: scroll.contentView.bounds.midY)
                scroll.setMagnification(fittedScale * 1.5, centeredAt: center)
                check("pinch immediately hides the fitted preview", preview.isHidden)
                await settle()
                check("pinch hides the fitted preview", preview.isHidden)
                check("pinch updates reported percentage", abs(factor - 1.5) < 0.01)
                capture("slide-pinch")
                viewer.zoom(by: 1.25)
                await settle()
                check("zoom button continues from pinch scale", abs(factor - 1.875) < 0.01)
                scroll.setMagnification(fittedScale, centeredAt: center)
                await settle()
                check("pinching back to Fit restores preview and percentage", !preview.isHidden && abs(factor - 1) < 0.01)
                scroll.setMagnification(fittedScale * 2, centeredAt: center)
                window.setContentSize(NSSize(width: 900, height: 620))
                await settle()
                check("resize preserves pinched zoom and hides preview", preview.isHidden && abs(factor - 2) < 0.01)
                viewer.fit()
                await settle()
                check("Fit resets native pinch magnification", abs(scroll.magnification - viewer.minScaleFactor) < 0.01 && !preview.isHidden && abs(factor - 1) < 0.01)
            } else { check("native pinch scroll view exists", false) }
            viewer.zoom(by: 2)
            await settle()
            check("zoom controls and reported percentage", available && abs(factor - 2) < 0.01)
            check("zoom reveals native PDF detail", preview.isHidden)
            capture("slide-zoom")
            if let scroll = find(NSScrollView.self, in: viewer), let content = scroll.documentView {
                check("zoomed page can scroll", content.bounds.width > scroll.contentView.bounds.width)
                scroll.contentView.scroll(to: NSPoint(x: 100, y: 80))
                scroll.reflectScrolledClipView(scroll.contentView)
                check("panning moves viewport", scroll.contentView.bounds.minX > 0)
            } else { check("native scroll view exists", false) }
            viewer.scaleFactor = viewer.minScaleFactor * 3
            await settle()
            check("native magnification updates controls", abs(factor - 3) < 0.01)
            viewer.zoom(by: 100)
            check("maximum zoom is bounded", abs(viewer.scaleFactor / viewer.minScaleFactor - 6) < 0.01)
            viewer.zoom(by: 0.001)
            check("minimum zoom fits the slide", abs(viewer.scaleFactor / viewer.minScaleFactor - 1) < 0.01)
            viewer.zoom(by: 2)
            window.setContentSize(NSSize(width: 1000, height: 650))
            await settle()
            check("resize preserves relative zoom", abs(viewer.scaleFactor / viewer.minScaleFactor - 2) < 0.01)
            viewer.fit()
            await settle()
            check("Fit resets zoom and pan", abs(factor - 1) < 0.01 && abs(viewer.scaleFactor - viewer.scaleFactorForSizeToFit) < 0.01)
            check("Fit restores the ready image", !preview.isHidden && displaysPage(0))
            let selection = viewer.document!.page(at: 0)!.selection(for: NSRange(location: 0, length: 5))!
            viewer.setCurrentSelection(selection, animate: false)
            await settle()
            check("native selection remains visible at Fit", preview.isHidden)
            viewer.clearSelection()
            check("clearing selection restores the ready image", !preview.isHidden)
            if let scroll = viewer.documentView?.enclosingScrollView {
                scroll.magnification = viewer.minScaleFactor * 2
            }
            host.rootView = ZoomableSlideView(sourceURL: source, pageIndex: 1)
            host.layoutSubtreeIfNeeded()
            check("next slide is visible before PDFKit tiles settle", !preview.isHidden && displaysPage(1))
            capture("slide-next-immediate")
            check("next slide uses its preloaded image", preview.image === next.image)
            await settle()
            check("new slide resets zoom", abs(viewer.scaleFactor / viewer.minScaleFactor - 1) < 0.01)
            check("rotated page is retained", viewer.document?.page(at: 0)?.rotation == 90)
            check("native navigation cannot leave focused slide", !viewer.canGoToNextPage && !viewer.canGoToPreviousPage)
            // No settling between loads: both cached neighbors and a cold distant jump
            // must have the correct slide in the very first drawable frame.
            for index in [0, 5, 4, 3, 2, 1, 0] {
                viewer.load(sourceURL: source, pageIndex: index)
                viewer.layoutSubtreeIfNeeded()
                check("immediate navigation to slide \(index + 1)", !preview.isHidden && displaysPage(index))
            }
            let otherSource = directory.appendingPathComponent("other.pdf")
            let otherDocument = PDFDocument()
            otherDocument.insert(document.page(at: 4)!.copy() as! PDFPage, at: 0)
            otherDocument.write(to: otherSource)
            viewer.load(sourceURL: otherSource, pageIndex: 0)
            viewer.layoutSubtreeIfNeeded()
            check("source change discards old previews", displaysPage(4))
            host.rootView = ZoomableSlideView(sourceURL: source, pageIndex: 99)
            await settle()
            check("invalid page clears old slide and disables zoom", viewer.document == nil && failed && !available)
            host.rootView = ZoomableSlideView(sourceURL: source, pageIndex: 0)
            await settle()
            check("valid page recovers", viewer.document != nil && available && !failed)
            window.close()
            try? FileManager.default.removeItem(at: directory)
            print("Failures: \(failures)")
            exit(failures == 0 ? 0 : 1)
        }
        app.run()
    }
}
