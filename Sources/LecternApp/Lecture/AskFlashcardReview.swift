import AppKit
import LecternCore

struct AskFlashcardReview {
    struct Grade {
        let rating: StudyRating
        let answeredAt: Date
        let answeringTime: TimeInterval
    }

    let turn: AskTurn
    let entry: StudyCard
    let shownAt = ContinuousClock.now
    var revealed = false
    var grade: Grade?
    var isSaving = false
    var saveError: String?
    var questionID: UUID { turn.questionID }
}

struct AskFlashcardReceipt {
    let lectureName: String
    let rating: StudyRating

    var summary: String { "Card from \(lectureName) · \(rating == .good ? "Got it" : "Missed")" }
}

extension LectureWindowModel {
    var askFlashcardJobID: UUID? {
        askFlashcard.flatMap { askJob(for: $0.turn)?.id }
    }

    var currentAskFlashcard: AskFlashcardReview? {
        guard app.adhdModeEnabled, !readOnly, let review = askFlashcard, review.turn.chatID == displayedChat.id else { return nil }
        guard let job = askJob(for: review.turn) else {
            return pendingChatMessage?.message.id == review.questionID ? review : nil
        }
        guard !hasEndedAsk(progress(job.id)), job.state == .running || job.state == .succeeded else { return nil }
        return review
    }

    func beginAskFlashcard(turn: AskTurn, sourcePage: Int?) async {
        guard let entry = try? await app.store.askFlashcard(moduleID: ref.moduleID, lectureID: ref.lectureID, sourcePage: sourcePage),
              app.adhdModeEnabled, !readOnly else { return }
        askFlashcard = AskFlashcardReview(turn: turn, entry: entry)
    }

    func revealAskFlashcard() {
        guard currentAskFlashcard != nil else { return }
        askFlashcard?.revealed = true
    }

    func gradeAskFlashcard(_ rating: StudyRating) async {
        guard let review = currentAskFlashcard, review.revealed, !review.isSaving,
              review.grade == nil || review.grade?.rating == rating else { return }
        let elapsed = review.shownAt.duration(to: .now).components
        let grade = review.grade ?? AskFlashcardReview.Grade(
            rating: rating, answeredAt: Date(),
            answeringTime: Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        )
        askFlashcard?.grade = grade
        askFlashcard?.isSaving = true
        askFlashcard?.saveError = nil
        do {
            _ = try await app.store.gradeStudyCard(
                review.entry, rating: grade.rating, eventID: review.questionID, now: grade.answeredAt,
                answeringTime: grade.answeringTime, permitEarly: true, extraNewPerModule: 0
            )
            askFlashcardReceipts[review.questionID] = AskFlashcardReceipt(lectureName: review.entry.lectureName, rating: rating)
            if askFlashcard?.questionID == review.questionID { askFlashcard = nil }
            await app.refreshStudy()
        } catch {
            guard askFlashcard?.questionID == review.questionID else { return }
            if error is LibraryError || error is StudyScheduleError {
                askFlashcard = nil
                errorMessage = "Couldn’t save the flashcard review. \(Self.describe(error))"
            } else {
                // Keep the event and rating together so retrying an uncertain save cannot grade twice.
                askFlashcard?.isSaving = false
                askFlashcard?.saveError = Self.describe(error)
            }
        }
    }

    func handleAskFlashcardKey(_ event: NSEvent) -> Bool {
        guard Key.modifiers(event).isEmpty, let review = currentAskFlashcard else { return false }
        if event.keyCode == Key.escape {
            if !event.isARepeat, !review.isSaving { askFlashcard = nil }
            return true
        }
        guard chatDraft.isEmpty, chatDraftAttachments.isEmpty else { return false }
        if event.keyCode == Key.space {
            if !event.isARepeat, !review.revealed { revealAskFlashcard() }
            return true
        }
        guard review.revealed else { return false }
        let rating: StudyRating
        switch Key.letter(event) {
        case "1": rating = .good
        case "2": rating = .again
        default: return false
        }
        if !event.isARepeat { Task { await gradeAskFlashcard(rating) } }
        return true
    }
}
