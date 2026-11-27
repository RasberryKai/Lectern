import AppKit
import SwiftUI

struct SolveOrderingView<Row: View>: View {
    let items: [String]
    let onMove: (Int, Int) -> Void
    @ViewBuilder let row: (String, Int, Bool) -> Row

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focusedItem: String?
    @GestureState private var pointerIsDown = false
    @State private var coordinateSpace = UUID()
    @State private var anchors: [String]
    @State private var heights: [String: CGFloat] = [:]
    @State private var drag: Drag?
    @State private var ignorePointer = false
    @State private var viewport = OrderingViewport()

    private let spacing: CGFloat = 8
    private var settling: Animation? { reduceMotion ? nil : .easeOut(duration: 0.18) }

    init(items: [String], onMove: @escaping (Int, Int) -> Void,
         @ViewBuilder row: @escaping (String, Int, Bool) -> Row) {
        self.items = items
        self.onMove = onMove
        self.row = row
        _anchors = State(initialValue: items)
    }

    var body: some View {
        let anchoredItems = Set(anchors) == Set(items) ? anchors : items
        let anchorTops = tops(in: anchoredItems)
        let projected = projectedItems
        let projectedTops = tops(in: projected)
        VStack(alignment: .leading, spacing: spacing) {
            // Keep each row's layout position fixed. Its visual offset can then animate
            // through the drop without a second layout change when the answer is saved.
            ForEach(anchoredItems, id: \.self) { item in
                let position = projected.firstIndex(of: item) ?? 0
                let isLifted = drag?.item == item
                let currentTop = isLifted ? drag?.top : projectedTops[item]
                let shift = (currentTop ?? 0) - (anchorTops[item] ?? 0)
                row(item, position, isLifted)
                    .animation(settling, value: isLifted)
                    .contentShape(Rectangle())
                    .pointerStyle(isLifted ? .grabActive : .grabIdle)
                    .gesture(pointerDrag(item))
                    .onTapGesture { focusedItem = item }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { heights[item] = $0 }
                    .focusable(interactions: .edit)
                    .focused($focusedItem, equals: item)
                    .onKeyPress(keys: [.upArrow, .downArrow], phases: [.down, .repeat]) { press in
                        let modifiers = press.modifiers.intersection([.command, .option, .control, .shift])
                        guard modifiers == .option else { return .ignored }
                        move(item, by: press.key == .upArrow ? -1 : 1)
                        return .handled
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilitySortPriority(Double(items.count - position))
                    .offset(y: shift)
                    .animation(isLifted ? nil : settling, value: shift)
                    .zIndex(isLifted ? 1 : 0)
            }
        }
        .background(alignment: .top) {
            if let drag, let height = heights[drag.item], let top = projectedTops[drag.item] {
                let shape = RoundedRectangle(cornerRadius: 10)
                shape.fill(Theme.aiWash)
                    .overlay(shape.strokeBorder(Theme.ai.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    .frame(height: height)
                    .offset(y: top)
                    .animation(settling, value: top)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .coordinateSpace(.named(coordinateSpace))
        .background { OrderingViewportProbe(viewport: viewport).allowsHitTesting(false).accessibilityHidden(true) }
        .task(id: drag?.item) {
            while drag != nil, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(16))
                guard !Task.isCancelled, let drag, let pointerY = viewport.scrollAtPointer() else { continue }
                self.drag = projectedDrag(for: drag.item, grabOffset: drag.grabOffset, pointerY: pointerY)
            }
        }
        .onChange(of: items) {
            if Set(anchors) != Set(items) { anchors = items }
            if drag != nil { cancelPointerDrag() }
        }
        .onChange(of: pointerIsDown) { _, isDown in
            guard !isDown else { return }
            if drag != nil { finishDrag() }
            ignorePointer = false
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { notification in
            SolveOrderingDragCancellation.cancel(in: notification.object as? NSWindow)
        }
        .onDisappear { finishDrag() }
    }

    private var projectedItems: [String] {
        guard let drag, items.indices.contains(drag.destination),
              let source = items.firstIndex(of: drag.item) else { return items }
        var projected = items
        projected.remove(at: source)
        projected.insert(drag.item, at: drag.destination)
        return projected
    }

    private func tops(in order: [String]) -> [String: CGFloat] {
        var top: CGFloat = 0
        var result: [String: CGFloat] = [:]
        for item in order {
            result[item] = top
            top += (heights[item] ?? 0) + spacing
        }
        return result
    }

    private func pointerDrag(_ item: String) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(coordinateSpace))
            .updating($pointerIsDown) { _, isDown, _ in isDown = true }
            .onChanged { value in
                guard !ignorePointer, let next = pointerPosition(for: item, value: value) else { return }
                if drag == nil {
                    SolveOrderingDragCancellation.begin(in: viewport.view?.window, id: coordinateSpace) { cancelPointerDrag() }
                }
                drag = next
            }
            .onEnded { value in
                defer {
                    finishDrag()
                    ignorePointer = false
                }
                guard !ignorePointer, !pointerReleasedOutsideWindow, drag?.item == item,
                      let source = items.firstIndex(of: item),
                      let final = pointerPosition(for: item, value: value),
                      source != final.destination else { return }
                onMove(source, final.destination)
            }
    }

    private var pointerReleasedOutsideWindow: Bool {
        guard let event = NSApp.currentEvent, event.type == .leftMouseUp, let window = event.window else { return false }
        return !window.frame.contains(window.convertPoint(toScreen: event.locationInWindow))
    }

    private func pointerPosition(for item: String, value: DragGesture.Value) -> Drag? {
        guard items.count > 1, items.allSatisfy({ heights[$0] != nil }),
              let origin = tops(in: items)[item] else { return nil }
        let grabOffset = drag?.grabOffset ?? value.startLocation.y - origin
        return projectedDrag(for: item, grabOffset: grabOffset, pointerY: value.location.y)
    }

    private func projectedDrag(for item: String, grabOffset: CGFloat, pointerY: CGFloat) -> Drag {
        var slots: [CGFloat] = [0]
        for neighbor in items where neighbor != item {
            slots.append(slots[slots.count - 1] + (heights[neighbor] ?? 0) + spacing)
        }
        let top = min(max(0, pointerY - grabOffset), slots[slots.count - 1])
        // Each slot is a possible resting top for the dragged row. Use their
        // midpoints as boundaries so multiline rows sort at a consistent threshold.
        let destination = slots.indices.min { abs(slots[$0] - top) < abs(slots[$1] - top) } ?? 0
        return Drag(item: item, grabOffset: grabOffset, top: top, destination: destination)
    }

    private func move(_ item: String, by amount: Int) {
        guard drag == nil, let source = items.firstIndex(of: item), items.indices.contains(source + amount) else { return }
        onMove(source, source + amount)
    }

    private func cancelPointerDrag() {
        ignorePointer = true
        finishDrag()
    }

    private func finishDrag() {
        drag = nil
        SolveOrderingDragCancellation.end(id: coordinateSpace)
    }

    private struct Drag {
        let item: String
        let grabOffset: CGFloat
        let top: CGFloat
        let destination: Int
    }
}

private final class OrderingViewport {
    weak var view: NSView?

    /// Scroll the enclosing Study or Review viewport, then return the pointer's Y in the order list.
    func scrollAtPointer() -> CGFloat? {
        guard let view, let window = view.window, let scrollView = view.enclosingScrollView else { return nil }
        let screenPoint = NSEvent.mouseLocation
        guard window.frame.contains(screenPoint) else { return nil }
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        let clip = scrollView.contentView
        let point = clip.convert(windowPoint, from: nil)
        guard clip.bounds.contains(point) else { return nil }

        let distanceFromTop = clip.isFlipped ? point.y - clip.bounds.minY : clip.bounds.maxY - point.y
        let distanceFromBottom = clip.bounds.height - distanceFromTop
        let edge: CGFloat = min(38, clip.bounds.height / 3)
        let speed = 10 * (max(0, edge - distanceFromBottom) - max(0, edge - distanceFromTop)) / edge
        guard speed != 0 else { return nil }

        let bounds = clip.bounds
        let nextBounds = clip.constrainBoundsRect(bounds.offsetBy(dx: 0, dy: clip.isFlipped ? speed : -speed))
        guard nextBounds.origin != bounds.origin else { return nil }
        clip.scroll(to: nextBounds.origin)
        scrollView.reflectScrolledClipView(clip)
        return view.convert(windowPoint, from: nil).y
    }
}

private struct OrderingViewportProbe: NSViewRepresentable {
    let viewport: OrderingViewport

    func makeNSView(context: Context) -> NSView { View() }
    func updateNSView(_ nsView: NSView, context: Context) { viewport.view = nsView }

    private final class View: NSView {
        override var isFlipped: Bool { true }
    }
}

/// Study and Review route Escape here before handling their window shortcuts.
enum SolveOrderingDragCancellation {
    private static weak var window: NSWindow?
    private static var active: (id: UUID, cancel: () -> Void)?

    static func begin(in window: NSWindow?, id: UUID, cancel: @escaping () -> Void) {
        active?.cancel()
        self.window = window
        active = (id, cancel)
    }

    static func end(id: UUID) {
        guard active?.id == id else { return }
        active = nil
        window = nil
    }

    @discardableResult
    static func cancel(in window: NSWindow?) -> Bool {
        guard let window, Self.window === window, let active else { return false }
        active.cancel()
        return true
    }
}
