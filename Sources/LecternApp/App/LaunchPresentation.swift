import AppKit
import SwiftUI

enum LaunchPhase {
    case covered, revealing, finished
}

extension EnvironmentValues {
    @Entry var launchPhase: LaunchPhase = .finished
}

struct LaunchDestination: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

extension View {
    /// Reveal the real controls, preserving their layout and accessibility identities.
    func launchEntrance(row: Int? = nil) -> some View {
        modifier(LaunchEntrance(row: row))
    }
}

private struct LaunchEntrance: ViewModifier {
    @Environment(\.launchPhase) private var phase
    @Environment(\.accessibilityReduceMotion) private var reduced
    let row: Int?

    func body(content: Content) -> some View {
        let hidden = phase == .covered && !reduced
        let delay = row.map { 0.18 + Double(min($0, 9)) * 0.035 } ?? 0.26
        content
            .opacity(hidden ? 0 : 1)
            .offset(x: hidden && row != nil ? -12 : 0, y: hidden && row == nil ? 14 : 0)
            .animation(phase == .revealing && !reduced
                ? .timingCurve(0.22, 1, 0.36, 1, duration: row == nil ? 0.5 : 0.38).delay(delay)
                : nil, value: phase)
    }
}

struct LaunchPresentation: View {
    let libraryPhase: AppModel.Phase
    @Binding var finished: Bool
    @Environment(\.accessibilityReduceMotion) private var reduced
    @State private var start = ContinuousClock.now
    @State private var handoff: ContinuousClock.Instant?

    private var phase: LaunchPhase {
        finished ? .finished : handoff == nil ? .covered : .revealing
    }

    var body: some View {
        LibraryWindow()
            .environment(\.launchPhase, phase)
            .accessibilityHidden(phase == .covered)
            .allowsHitTesting(phase != .covered)
            .overlayPreferenceValue(LaunchDestination.self) { anchor in
                if !finished {
                    GeometryReader { geometry in
                        let target = anchor.map { geometry[$0] }
                        TimelineView(.animation) { _ in
                            let now = ContinuousClock.now
                            LaunchFrame(elapsed: seconds(start.duration(to: now)),
                                        exitElapsed: handoff.map { seconds($0.duration(to: now)) },
                                        target: target, size: geometry.size, reduced: reduced)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Opening your library")
                        .accessibilityHidden(handoff != nil)
                    }
                    .background(LaunchInputMonitor { finished = true })
                    .allowsHitTesting(false)
                }
            }
            .task(id: libraryPhase) {
                guard !finished, libraryPhase != .loading else { return }
                if case .failed = libraryPhase { finished = true; return }
                do {
                    if !reduced { try await Task.sleep(until: start.advanced(by: .milliseconds(700)), clock: .continuous) }
                    guard !finished else { return }
                    handoff = .now
                    try await Task.sleep(for: .milliseconds(reduced ? 250 : 900))
                    finished = true
                } catch { /* The window closed or the library phase changed. */ }
            }
            .onDisappear { finished = true }
    }

    private func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) * 1e-18
    }
}

private struct LaunchFrame: View {
    let elapsed: Double
    let exitElapsed: Double?
    let target: CGRect?
    let size: CGSize
    let reduced: Bool

    private func unit(_ value: Double) -> Double { min(1, max(0, value)) }
    private func smooth(_ value: Double) -> Double {
        let t = unit(value)
        return t * t * (3 - 2 * t)
    }
    private func easeOut(_ value: Double) -> Double { 1 - pow(1 - unit(value), 3) }

    var body: some View {
        let exit = unit((exitElapsed ?? 0) / (reduced ? 0.25 : 0.65))
        let fly = !reduced && target != nil
        let travel = fly ? (exit < 0.5 ? 4 * pow(exit, 3) : 1 - pow(2 - 2 * exit, 3) / 2) : 0
        let center = CGPoint(x: size.width / 2, y: size.height / 2 - 16)
        let destination = target.map { CGPoint(x: $0.midX, y: $0.midY) } ?? center
        let word = reduced ? 1 : easeOut((elapsed - 0.30) / 0.40)
        ZStack(alignment: .topLeading) {
            Theme.canvasGrid(horizontalOffset: target == nil ? 0 : LibraryWindow.sidebarWidth + 1)
                .ignoresSafeArea(edges: .top)
                .opacity(1 - (reduced ? exit : smooth(exit / 0.75)))
            Text("Opening your library…")
                .font(Theme.body).foregroundStyle(Theme.quiet)
                .position(x: center.x, y: center.y + 60)
                .opacity(smooth((elapsed - 1.30) / 0.30) * (1 - unit(exit * 3)))
            let scale = 2.4 - 1.4 * travel
            HStack(spacing: 8 * scale) {
                mark(exit: exit).frame(width: 23 * scale * 1.05, height: 23 * scale * 1.05)
                Text("Lectern").font(Theme.serif(23 * scale)).foregroundStyle(Theme.ink)
                    .offset(x: -6 * (1 - word))
                    .mask(alignment: .leading) {
                        GeometryReader { bounds in
                            Rectangle().frame(width: bounds.size.width * word)
                        }
                    }
                    .opacity(smooth(word * 1.5))
            }
            .fixedSize()
            .position(x: center.x + (destination.x - center.x) * travel,
                      y: center.y + (destination.y - center.y) * travel)
            .opacity(fly ? 1 : 1 - exit)
        }
    }

    private func mark(exit: Double) -> some View {
        let stamp = unit((elapsed - 0.45) / 0.6)
        let glint = max(0, elapsed - 0.90).truncatingRemainder(dividingBy: 1.4) / 1.4
        let stroke = StrokeStyle(lineWidth: 0.85, lineCap: .round, lineJoin: .round)
        return ZStack {
            if !reduced {
                Circle().stroke(Theme.accent, lineWidth: 1)
                    .scaleEffect(1 + 1.9 * easeOut(stamp))
                    .opacity(elapsed >= 0.45 ? 0.5 * (1 - stamp) : 0)
            }
            LogoMark().fill(Theme.accent).opacity(reduced ? 1 : smooth((elapsed - 0.33) / 0.22))
            if !reduced {
                LogoMark().trim(from: 0, to: smooth(elapsed / 0.45)).stroke(Theme.accent, style: stroke)
                    .opacity(1 - smooth((elapsed - 0.55) / 0.15))
                ZStack {
                    LogoMark().trim(from: glint, to: min(1, glint + 0.18)).stroke(Theme.launchGlint, style: stroke)
                    LogoMark().trim(from: 0, to: max(0, glint - 0.82)).stroke(Theme.launchGlint, style: stroke)
                }
                .opacity(smooth((elapsed - 0.9) / 0.3) * (1 - unit(exit * 4)))
            }
        }
    }
}

/// Observe the window's input without stealing keyboard focus or consuming the first click.
private struct LaunchInputMonitor: NSViewRepresentable {
    let skip: () -> Void

    final class MonitorView: NSView {
        var monitor: Any?
        var skip: (() -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] event in
                if let self, let window = self.window, event.window === window { self.skip?() }
                return event
            }
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.skip = skip
        return view
    }
    func updateNSView(_ view: MonitorView, context: Context) { view.skip = skip }
}
