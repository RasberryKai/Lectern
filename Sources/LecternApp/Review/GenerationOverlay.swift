import LecternCore
import SwiftUI

/// Covers Review while a Generate runs, so the cards about to be replaced aren't reviewed,
/// and fades away to reveal the new cards when the job lands.
struct GenerationOverlay: View {
    let model: LectureWindowModel
    let job: Job

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            GenerationAnimation()
            VStack(spacing: 8) {
                Text("Writing your cards").font(Theme.serif(28))
                TimelineView(.periodic(from: job.startedAt, by: 1)) { context in
                    Text(detail(now: context.date))
                        .font(Theme.body).foregroundStyle(Theme.quiet).monospacedDigit()
                }
                Text(status).font(Theme.small).foregroundStyle(Theme.faint)
                if job.replacesExistingCards == true, !model.activeCards.isEmpty {
                    Text("Replaces your \(Format.count(model.activeCards.count, "current card")) when it finishes.")
                        .font(Theme.small).foregroundStyle(Theme.faint)
                }
                if let warning = model.progress(job.id)?.warning {
                    Text(warning).font(Theme.small).foregroundStyle(Theme.amber).frame(maxWidth: 420)
                }
            }
            .multilineTextAlignment(.center)
            .padding(.top, 30)
            HStack(spacing: 16) {
                Button("Back to Prepare") { model.setMode(.prepare) }
                    .buttonStyle(LinkButtonStyle(color: Theme.quiet))
                    .help("⌘1 · Generation keeps running")
                Button("Cancel") { Task { await model.cancel(job.id) } }
                    .buttonStyle(SecondaryButtonStyle())
            }
            .padding(.top, 22)
            Spacer(minLength: 24)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Generating cards")
    }

    private func detail(now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(job.startedAt)))
        let elapsed = "\(seconds / 60):" + String(format: "%02d", seconds % 60)
        return "From \(Format.count(job.pages.count, "slide")) · \(job.backend.displayName) · \(elapsed)"
    }

    /// Honest stage wording; the CLI backend doesn't stream generate output, so there's no card count.
    private var status: String {
        switch model.progress(job.id)?.stage ?? "Queued" {
        case "Queued": "Waiting for a free slot"
        case "Sending": "Sending your slides and notes"
        case "Starting Claude", "Starting Codex": "\(job.backend.assistantName) is reading your slides"
        case "Writing", "Checking": "Checking the new cards"
        case let other: other
        }
    }
}

// MARK: - Animation

/// A card is written line by line, stamped with the Lectern mark, and dealt onto the pile.
/// The stamp fades as the card lands, so pile cards stay plain and the loop has no seam.
/// Pure function of time, so Reduce Motion simply freezes it on a finished card.
private struct GenerationAnimation: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let period: Double = 3.2

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            scene(phase: reduceMotion ? 0.8 : CGFloat(t.truncatingRemainder(dividingBy: Self.period) / Self.period))
        }
        .frame(width: 280, height: 200)
        .accessibilityHidden(true)
    }

    @ViewBuilder private func scene(phase p: CGFloat) -> some View {
        let deal = ease(seg(p, 0.84, 1))
        ZStack {
            // The pile shifts back one slot while the finished card lands on top; slots look
            // identical, so the loop has no seam.
            ForEach((0..<3).reversed(), id: \.self) { slot in
                SketchCard(lines: [1, 1, 1, 1, 1], divider: 1, stamp: 0)
                    .pose(.lerp(Pose.slot(slot), Pose.slot(slot + 1), deal))
            }
            let enter = ease(seg(p, 0, 0.1))
            SketchCard(lines: [ease(seg(p, 0.10, 0.24)), ease(seg(p, 0.22, 0.32)),
                               ease(seg(p, 0.40, 0.52)), ease(seg(p, 0.50, 0.62)), ease(seg(p, 0.60, 0.70))],
                       divider: ease(seg(p, 0.32, 0.40)),
                       stamp: overshoot(seg(p, 0.72, 0.79)) * (1 - deal))
                .pose(.lerp(Pose(y: 10 * (1 - enter), scale: 0.97 + 0.03 * enter, opacity: enter), .slot(0), deal))
        }
        .offset(y: 14)
    }

    private func seg(_ p: CGFloat, _ a: CGFloat, _ b: CGFloat) -> CGFloat { min(max((p - a) / (b - a), 0), 1) }
    private func ease(_ x: CGFloat) -> CGFloat { x * x * (3 - 2 * x) }
    private func overshoot(_ x: CGFloat) -> CGFloat {
        let c: CGFloat = 1.9, u = x - 1
        return 1 + (c + 1) * u * u * u + c * u * u
    }
}

private struct Pose {
    var x: CGFloat = 0, y: CGFloat = 0, angle: Double = 0, scale: CGFloat = 1, opacity: Double = 1

    static func slot(_ index: Int) -> Pose {
        switch index {
        case 0: Pose(x: -14, y: -10, angle: -6, scale: 0.95)
        case 1: Pose(x: 16, y: -18, angle: 5, scale: 0.91)
        case 2: Pose(x: -22, y: -25, angle: -10, scale: 0.87)
        default: Pose(x: 0, y: -34, angle: 0, scale: 0.84, opacity: 0)
        }
    }

    static func lerp(_ a: Pose, _ b: Pose, _ t: CGFloat) -> Pose {
        Pose(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t, angle: a.angle + (b.angle - a.angle) * Double(t),
             scale: a.scale + (b.scale - a.scale) * t, opacity: a.opacity + (b.opacity - a.opacity) * Double(t))
    }
}

private extension View {
    func pose(_ pose: Pose) -> some View {
        scaleEffect(pose.scale).rotationEffect(.degrees(pose.angle)).offset(x: pose.x, y: pose.y).opacity(pose.opacity)
    }
}

/// A flashcard drawn as ink: question lines, a rule, answer lines, and the mark as approval stamp.
private struct SketchCard: View {
    /// Draw progress 0...1 for two question lines then three answer lines.
    let lines: [CGFloat]
    let divider: CGFloat
    let stamp: CGFloat

    private static let widths: [CGFloat] = [118, 78, 140, 132, 92]

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 12).fill(Theme.surface)
            RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border, lineWidth: 1)
            VStack(alignment: .leading, spacing: 7) {
                line(0, height: 6, color: Theme.ink.opacity(0.72))
                line(1, height: 6, color: Theme.ink.opacity(0.72))
                Rectangle().fill(Theme.borderStrong)
                    .frame(width: 148 * divider, height: 1)
                    .frame(width: 148, alignment: .leading)
                    .padding(.vertical, 3)
                line(2, height: 5, color: Theme.accent.opacity(0.5))
                line(3, height: 5, color: Theme.accent.opacity(0.5))
                line(4, height: 5, color: Theme.accent.opacity(0.5))
            }
            .padding(16)
            LogoMark().fill(Theme.accent)
                .frame(width: 24, height: 24)
                .scaleEffect(0.4 + 0.6 * stamp)
                .opacity(Double(min(stamp, 1)))
                .offset(x: 146, y: 10)
        }
        .frame(width: 184, height: 116)
        .compositingGroup()
        .shadow(color: .black.opacity(0.07), radius: 10, y: 4)
    }

    private func line(_ index: Int, height: CGFloat, color: Color) -> some View {
        let width = Self.widths[index]
        return Capsule().fill(color)
            .frame(width: width * lines[index], height: height)
            .frame(width: width, alignment: .leading)
    }
}
