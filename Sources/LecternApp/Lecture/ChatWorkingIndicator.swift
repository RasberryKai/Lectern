import LecternCore
import SwiftUI

/// Shown in the Ask pane until the first answer paragraph lands: the Lectern mark draws itself,
/// a bold line says what the AI is doing now and a grey line what it just finished.
struct ChatWorkingIndicator: View {
    let doing: String
    let done: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Group {
                if reduceMotion { LogoMark().fill(Theme.ai) } else { DrawingLogoMark() }
            }
            .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 4) {
                Text(doing)
                    .font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.ink)
                    .id(doing).transition(.opacity)
                if let done {
                    Label(done, systemImage: "checkmark")
                        .font(.system(size: 10.5)).foregroundStyle(Theme.faint)
                        .id(done).transition(.opacity)
                }
            }
            .padding(.top, 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: doing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(done.map { "\(doing), \($0)" } ?? doing)
    }
}

/// The mark traces its outline, fills, then wipes away, on a 2.2 s loop.
private struct DrawingLogoMark: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.2) / 2.2
            let phase = Self.phase(t)
            ZStack {
                LogoMark().fill(Theme.ai.opacity(phase.fill))
                LogoMark().trim(from: phase.from, to: phase.to)
                    .stroke(Theme.ai, style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
            }
        }
        .accessibilityHidden(true)
    }

    private static func phase(_ t: Double) -> (from: Double, to: Double, fill: Double) {
        func ease(_ x: Double) -> Double { x * x * (3 - 2 * x) }
        switch t {
        case ..<0.55: return (0, ease(t / 0.55), 0)
        case ..<0.70: return (0, 1, ease((t - 0.55) / 0.15))
        case ..<0.88: return (0, 1, 1)
        default: let x = ease((t - 0.88) / 0.12); return (x, 1, 1 - x)
        }
    }
}

extension LectureWindowModel {
    /// Plain-language hints for a running chat: what it is doing now, and the step it just finished.
    func chatWorkingHint(_ progress: JobProgress?) -> (doing: String, done: String?) {
        guard let progress else { return ("Thinking about your question", nil) }
        if progress.stage == "Queued" { return ("Waiting for a free slot", nil) }
        let steps = progress.activity
        guard let current = steps.last else { return ("Thinking about your question", nil) }
        let hasRead = steps.dropLast().contains { if case .reading = $0 { true } else { false } }
        let previous = steps.count > 1 ? steps[steps.count - 2] : nil
        return (activityLabel(current, finished: false, afterReading: hasRead), previous.map { activityLabel($0, finished: true, afterReading: false) })
    }

    private func activityLabel(_ step: JobActivity, finished: Bool, afterReading: Bool) -> String {
        switch step {
        case .thinking: finished ? "Thought it through" : (afterReading ? "Putting the answer together" : "Thinking about your question")
        case .images: finished ? "Looked at your images" : "Looking at your images"
        case .reading(.slide(let page)): (finished ? "Read slide " : "Reading slide ") + "\(page)"
        case .reading(.card(let id)): (finished ? "Read " : "Reading ") + (cardNumbers[id].map { "card \($0)" } ?? "a deleted card")
        case .reading(.allSlides): finished ? "Searched the slides" : "Searching the slides"
        case .reading(.allCards): finished ? "Searched your cards" : "Searching your cards"
        }
    }
}
