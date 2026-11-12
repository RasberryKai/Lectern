import AppKit
import Observation
import PDFKit
import SwiftUI

/// A single source page, rendered by PDFKit so magnification preserves PDF detail.
struct ZoomableSlideView: View {
    let sourceURL: URL
    let pageIndex: Int
    @State private var zoom = SlideZoomController()

    var body: some View {
        VStack(spacing: 8) {
            SlidePDFView(sourceURL: sourceURL, pageIndex: pageIndex, controller: zoom)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .overlay {
                    if zoom.failed {
                        Label("Slide \(pageIndex + 1) unavailable", systemImage: "exclamationmark.triangle")
                            .font(Theme.caption).foregroundStyle(Theme.quiet)
                    }
                }
            HStack(spacing: 10) {
                Button { zoom.view?.zoom(by: 1 / 1.25) } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                .accessibilityLabel("Zoom out")
                .disabled(!zoom.available || zoom.factor <= 1.001)
                Text("\(Int((zoom.factor * 100).rounded()))%")
                    .monospacedDigit().frame(minWidth: 42)
                    .accessibilityLabel("Zoom: \(Int((zoom.factor * 100).rounded())) percent of fitted slide")
                Button { zoom.view?.zoom(by: 1.25) } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                .accessibilityLabel("Zoom in")
                .disabled(!zoom.available || zoom.factor >= 5.999)
                Divider().frame(height: 14)
                Button("Fit") { zoom.view?.fit() }
                    .accessibilityLabel("Fit slide to view")
                    .disabled(!zoom.available)
            }
            .buttonStyle(.plain)
            .font(Theme.small).foregroundStyle(Theme.quiet)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Theme.inset, in: Capsule())
            .help("Pinch to zoom. Scroll to move around the enlarged slide. 100% fits the whole slide.")
        }
    }
}

@Observable @MainActor final class SlideZoomController {
    var factor: CGFloat = 1
    var available = false
    var failed = false
    @ObservationIgnored weak var view: ZoomablePDFView?
}

private struct SlidePDFView: NSViewRepresentable {
    let sourceURL: URL
    let pageIndex: Int
    let controller: SlideZoomController

    func makeNSView(context: Context) -> ZoomablePDFView {
        let view = ZoomablePDFView()
        controller.view = view
        view.onZoomChange = { [weak controller] factor, available, failed in
            // PDFKit can notify during SwiftUI layout/update; publish after that pass.
            Task { @MainActor in
                controller?.factor = factor
                controller?.available = available
                controller?.failed = failed
            }
        }
        return view
    }

    func updateNSView(_ view: ZoomablePDFView, context: Context) {
        view.load(sourceURL: sourceURL, pageIndex: pageIndex)
    }
}

@MainActor final class ZoomablePDFView: PDFView {
    var onZoomChange: ((CGFloat, Bool, Bool) -> Void)?
    private var sourceURL: URL?
    private var sourceDocument: PDFDocument?
    private var pageIndex: Int?
    private var fittedScale: CGFloat = 0
    private var relativeZoom: CGFloat = 1
    private var viewportSize: CGSize = .zero
    private var adjustingScale = false
    private let fittedPreview = SlidePreviewImageView()
    private var previews: [Int: NSImage] = [:]
    private var prefetchTask: Task<Void, Never>?
    private weak var observedScrollView: NSScrollView?
    private var magnificationObservation: NSKeyValueObservation?

    init() {
        super.init(frame: .zero)
        autoScales = false
        displayMode = .singlePage
        displayBox = .cropBox
        displaysPageBreaks = false
        pageShadowsEnabled = false
        backgroundColor = .clear
        fittedPreview.imageScaling = .scaleProportionallyUpOrDown
        addSubview(fittedPreview)
        NotificationCenter.default.addObserver(self, selector: #selector(scaleChanged), name: .PDFViewScaleChanged, object: self)
        NotificationCenter.default.addObserver(self, selector: #selector(updatePreview), name: .PDFViewSelectionChanged, object: self)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func load(sourceURL: URL, pageIndex: Int) {
        guard self.sourceURL != sourceURL || self.pageIndex != pageIndex else { return }
        prefetchTask?.cancel()
        if self.sourceURL != sourceURL {
            self.sourceURL = sourceURL
            sourceDocument = PDFDocument(url: sourceURL)
            previews.removeAll()
        }
        self.pageIndex = pageIndex
        fittedScale = 0
        relativeZoom = 1
        viewportSize = .zero
        // Isolate the page: scrolling while zoomed must never navigate to another slide.
        if pageIndex >= 0, let page = sourceDocument?.page(at: pageIndex)?.copy() as? PDFPage {
            let singlePage = PDFDocument()
            singlePage.insert(page, at: 0)
            document = singlePage
            // PDFKit tiles arrive asynchronously after replacing the document. Keep an
            // already rendered image above them at Fit, including on the very first frame.
            let image = previews[pageIndex] ?? page.thumbnail(of: CGSize(width: 2240, height: 2240), for: .cropBox)
            previews[pageIndex] = image
            fittedPreview.image = image
            prefetchNeighbors(sourceURL: sourceURL, pageIndex: pageIndex)
        } else {
            document = nil
            fittedPreview.image = nil
        }
        addSubview(fittedPreview, positioned: .above, relativeTo: nil)
        fittedPreview.isHidden = false
        fittedPreview.frame = bounds
        setAccessibilityLabel("Slide \(pageIndex + 1)")
        needsLayout = true
        reportZoom()
    }

    override func layout() {
        super.layout()
        observeMagnification()
        if fittedScale > 0 { updatePreview() }
        else { fittedPreview.frame = bounds }
        guard !adjustingScale, document != nil, bounds.width > 0, bounds.height > 0,
              viewportSize != bounds.size || fittedScale == 0 else { return }
        viewportSize = bounds.size
        adjustingScale = true
        let fitScale = scaleFactorForSizeToFit
        if fitScale.isFinite && fitScale > 0 {
            fittedScale = fitScale
            minScaleFactor = fitScale
            maxScaleFactor = fitScale * 6
            scaleFactor = fitScale * relativeZoom
        }
        adjustingScale = false
        updatePreview()
        reportZoom()
    }

    func zoom(by multiplier: CGFloat) {
        guard fittedScale > 0 else { return }
        scaleFactor = min(maxScaleFactor, max(minScaleFactor, scaleFactor * multiplier))
    }

    func fit() {
        guard fittedScale > 0 else { return }
        scaleFactor = fittedScale
        if let page = document?.page(at: 0) { go(to: page) }
    }

    @objc private func scaleChanged() {
        guard !adjustingScale, fittedScale > 0 else { return }
        relativeZoom = min(6, max(1, scaleFactor / fittedScale))
        updatePreview()
        reportZoom()
    }

    private func observeMagnification() {
        let scrollView = documentView?.enclosingScrollView
        guard observedScrollView !== scrollView else { return }
        observedScrollView = scrollView
        // Native pinch/smart zoom can change the scroll view's magnification
        // without PDFKit posting PDFViewScaleChanged. Both paths use the same scale.
        magnificationObservation = scrollView?.observe(\.magnification) { [weak self] _, _ in
            // AppKit magnification changes, like PDFView's scale notifications,
            // are delivered synchronously on the UI thread.
            MainActor.assumeIsolated { self?.scaleChanged() }
        }
    }

    @objc private func updatePreview() {
        fittedPreview.isHidden = relativeZoom > 1.001 || currentSelection != nil
        if let page = document?.page(at: 0) {
            fittedPreview.frame = convert(page.bounds(for: .cropBox), from: page)
        }
    }

    private func prefetchNeighbors(sourceURL: URL, pageIndex: Int) {
        let neighbors = [pageIndex + 1, pageIndex - 1, pageIndex + 2, pageIndex - 2]
            .filter { $0 >= 0 && $0 < (sourceDocument?.pageCount ?? 0) }
        let retained = Set(neighbors + [pageIndex])
        previews = previews.filter { retained.contains($0.key) }
        prefetchTask = Task { [weak self] in
            for index in neighbors {
                guard let self, !Task.isCancelled else { return }
                guard self.previews[index] == nil else { continue }
                do {
                    let preview = try await PDFThumbnailProvider.shared.thumbnail(
                        sourceURL: sourceURL, pageIndex: index, width: 1120)
                    guard !Task.isCancelled else { return }
                    self.previews[index] = preview.image
                } catch { }
            }
        }
    }

    private func reportZoom() {
        onZoomChange?(relativeZoom, document != nil && fittedScale > 0, document == nil)
    }
}

/// Let the underlying PDF view receive pinch, scroll and selection events.
private final class SlidePreviewImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
