import XCTest
@testable import LecternCore

final class ReviewCompatibilityTests: XCTestCase {
    func testLegacyNeedsWorkReturnsToReviewWithoutLosingContent() throws {
        var legacy = Card(front: "Question", back: "Answer", verdict: .needsAdjustment)
        legacy.feedback = "Keep this feedback"
        var lecture = Lecture(moduleID: UUID(), name: "Legacy", cards: [legacy])
        lecture.viewPreferences.reviewFilter = .needsAdjustment

        let restored = try JSONDecoder().decode(Lecture.self, from: JSONEncoder().encode(lecture))
        XCTAssertEqual(restored.viewPreferences.reviewFilter, .unreviewed)
        XCTAssertEqual(restored.visibleCards.map(\.id), [legacy.id])
        XCTAssertEqual(restored.cards[0].feedback, legacy.feedback)
        XCTAssertEqual(restored.cards[0].history, legacy.history)
        XCTAssertEqual(restored.cards[0].verdict, .needsAdjustment)
    }

    func testReviewQueueIncludesLegacyNeedsWorkButExcludesGoodBadAndSuperseded() {
        let unreviewed = Card(front: "New", back: "Answer")
        let legacy = Card(front: "Legacy", back: "Answer", verdict: .needsAdjustment)
        var hidden = Card(front: "Hidden", back: "Answer", verdict: .needsAdjustment)
        hidden.supersededBy = []
        var lecture = Lecture(moduleID: UUID(), name: "Review", cards: [
            unreviewed, legacy, hidden,
            Card(front: "Good", back: "Answer", verdict: .good),
            Card(front: "Bad", back: "Answer", verdict: .bad)
        ])
        lecture.viewPreferences.reviewFilter = .unreviewed
        XCTAssertEqual(Set(lecture.visibleCards.map(\.id)), Set([unreviewed.id, legacy.id]))
    }
}
