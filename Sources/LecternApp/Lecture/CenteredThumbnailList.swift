import SwiftUI

/// Centers navigation targets using their rendered frames, including slides whose
/// aspect ratios change after loading. Manual scrolling remains free to browse.
struct CenteredThumbnailList<Content: View>: View {
    let pageIndices: [Int]
    let focusedPageIndex: Int?
    @ViewBuilder let content: (Int) -> Content

    @State private var scrollPosition = ScrollPosition()
    @State private var scrollOffset: CGFloat = 0
    @State private var maximumScrollOffset: CGFloat = 0
    @State private var scrollPhase = ScrollPhase.idle
    @State private var focusedGeometry: ThumbnailGeometry?
    @State private var keepsFocusCentered = true
    @State private var positioningID: UUID?

    var body: some View {
        ScrollViewReader { proxy in
            GeometryReader { viewport in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(pageIndices, id: \.self) { pageIndex in
                            let isFocused = pageIndex == focusedPageIndex
                            content(pageIndex)
                                .onGeometryChange(for: ThumbnailGeometry?.self) { geometry in
                                    guard isFocused else { return nil }
                                    return ThumbnailGeometry(pageIndex: pageIndex, frame: geometry.frame(in: .named("thumbnailViewport")))
                                } action: { geometry in
                                    if let geometry { focusedGeometry = geometry }
                                }
                                // Symmetric row spacing keeps the scroll target's
                                // center aligned with the thumbnail's center.
                                .padding(.vertical, 6)
                                .id(pageIndex)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                }
                .coordinateSpace(name: "thumbnailViewport")
                .scrollPosition($scrollPosition)
                .onScrollGeometryChange(for: ThumbnailScrollMetrics.self) { geometry in
                    ThumbnailScrollMetrics(
                        offset: geometry.contentOffset.y,
                        maximumOffset: max(0, geometry.contentSize.height - geometry.containerSize.height)
                    )
                } action: { _, metrics in
                    scrollOffset = metrics.offset
                    maximumScrollOffset = metrics.maximumOffset
                }
                .onScrollPhaseChange { _, phase in
                    scrollPhase = phase
                    if phase == .tracking || phase == .interacting || phase == .decelerating {
                        keepsFocusCentered = false
                    }
                }
                .task(id: NavigationRequest(pageIndices: pageIndices, focusedPageIndex: focusedPageIndex, viewportSize: viewport.size, hasScrollableContent: maximumScrollOffset > 0)) {
                    guard let focusedPageIndex, pageIndices.contains(focusedPageIndex) else { return }
                    keepsFocusCentered = true
                    await Task.yield()
                    if focusedGeometry?.pageIndex != focusedPageIndex {
                        // Let the lazy stack register distant targets on opening.
                        try? await Task.sleep(for: .milliseconds(32))
                    }
                    guard !Task.isCancelled else { return }
                    animatePosition {
                        // Anchor the animation to the slide itself. Pixel targets
                        // drift when the lazy stack lays out earlier rows on upward moves.
                        proxy.scrollTo(focusedPageIndex, anchor: .center)
                    }
                }
                .task(id: CenteringRequest(
                    focusedPageIndex: focusedPageIndex,
                    geometry: focusedGeometry,
                    scrollOffset: scrollOffset,
                    maximumScrollOffset: maximumScrollOffset,
                    viewportHeight: viewport.size.height,
                    enabled: keepsFocusCentered && scrollPhase == .idle && positioningID == nil
                )) {
                    // Let the active transition finish before adjusting lazy
                    // layout estimates; corrections must not fight its frames.
                    guard keepsFocusCentered, scrollPhase == .idle, positioningID == nil,
                          let focusedGeometry,
                          focusedGeometry.pageIndex == focusedPageIndex,
                          pageIndices.contains(focusedGeometry.pageIndex) else { return }
                    let target = min(maximumScrollOffset, max(0,
                        scrollOffset + focusedGeometry.frame.midY - viewport.size.height / 2
                    ))
                    // At either end, keep the list against its natural boundary.
                    guard abs(target - scrollOffset) > 0.5 else { return }
                    // Frame and offset updates arrive separately at animation end.
                    // Wait for a stable layout before starting another transition.
                    try? await Task.sleep(for: .milliseconds(32))
                    guard !Task.isCancelled else { return }
                    animatePosition {
                        scrollPosition.scrollTo(y: target)
                    }
                }
            }
        }
    }

    private func animatePosition(_ update: () -> Void) {
        let id = UUID()
        positioningID = id
        withAnimation(.easeOut(duration: 0.15), completionCriteria: .removed) {
            update()
        } completion: {
            if positioningID == id { positioningID = nil }
        }
    }
}

nonisolated private struct ThumbnailGeometry: Hashable {
    let pageIndex: Int
    let frame: CGRect
}

nonisolated private struct NavigationRequest: Hashable {
    let pageIndices: [Int]
    let focusedPageIndex: Int?
    let viewportSize: CGSize
    let hasScrollableContent: Bool
}

nonisolated private struct CenteringRequest: Hashable {
    let focusedPageIndex: Int?
    let geometry: ThumbnailGeometry?
    let scrollOffset: CGFloat
    let maximumScrollOffset: CGFloat
    let viewportHeight: CGFloat
    let enabled: Bool
}

nonisolated private struct ThumbnailScrollMetrics: Equatable {
    let offset: CGFloat
    let maximumOffset: CGFloat
}
