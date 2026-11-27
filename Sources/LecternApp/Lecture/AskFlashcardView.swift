import LecternCore
import SwiftUI

struct AskFlashcardView: View {
    let review: AskFlashcardReview
    let answerReady: Bool
    let reveal: () -> Void
    let grade: (StudyRating) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("While it thinks · flashcard")
                    Spacer(minLength: 0)
                    Text("from \(review.entry.lectureName)").lineLimit(1)
                }
                .font(Theme.caption)
                .foregroundStyle(Theme.quiet)
                .accessibilityElement(children: .combine)

                RenderedCardText(text: review.entry.card.front, size: 17, emphasized: true)
                    .accessibilityLabel(review.entry.card.front)

                if review.revealed {
                    Divider()
                    RenderedCardText(text: review.entry.card.back, size: 13, emphasized: false)
                        .accessibilityLabel(review.entry.card.back)
                    gradeActions
                } else {
                    Button(action: reveal) {
                        HStack(spacing: 7) {
                            Text("Show answer")
                            ShortcutKey(text: "Space").accessibilityHidden(true)
                        }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .clipShape(Capsule())
                    .overlay(Capsule().strokeBorder(Theme.borderStrong).allowsHitTesting(false))
                }
            }
            .padding(15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.borderStrong).allowsHitTesting(false))

            if answerReady { readyLine }
        }
    }

    @ViewBuilder private var gradeActions: some View {
        if review.isSaving {
            ProgressView("Saving review…").controlSize(.small)
        } else if let error = review.saveError, let submitted = review.grade {
            Text(error).font(Theme.small).foregroundStyle(Theme.bad)
            Button("Retry saving grade") { grade(submitted.rating) }
                .buttonStyle(SecondaryButtonStyle())
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { gradeButtons }
                VStack(alignment: .leading, spacing: 8) { gradeButtons }
            }
        }
    }

    @ViewBuilder private var gradeButtons: some View {
        gradeButton("Got it", rating: .good, key: "1", color: Theme.good)
        gradeButton("Missed", rating: .again, key: "2", color: Theme.bad)
    }

    private func gradeButton(_ title: String, rating: StudyRating, key: String, color: Color) -> some View {
        Button { grade(rating) } label: {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 7, height: 7).accessibilityHidden(true)
                Text(title).fixedSize()
                ShortcutKey(text: key).accessibilityHidden(true)
            }
        }
        .buttonStyle(SecondaryButtonStyle())
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(Theme.borderStrong).allowsHitTesting(false))
    }

    private var readyLine: some View {
        HStack(spacing: 8) {
            Label("Answer ready", systemImage: "lock")
                .font(Theme.body.weight(.semibold))
                .fixedSize()
            Spacer(minLength: 0)
            Text("Finish the card · Esc skips it")
                .font(Theme.caption)
                .foregroundStyle(Theme.quiet)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.borderStrong, style: StrokeStyle(dash: [3, 2])))
        .accessibilityElement(children: .combine)
    }
}
