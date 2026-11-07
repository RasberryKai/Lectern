import XCTest
@testable import LecternCore

final class DomainReducerTests: XCTestCase {
    func testInvalidSourcesRetainedAndApprovalBlocked() throws {
        let job = Job(kind: .generate, pages: [1])
        var lecture = Lecture(moduleID: UUID(), name: "L", pageCount: 3, jobs: [job])
        try LectureReducer.reduce(&lecture, action: .landGeneration(jobID: job.id, cards: [CardDraft(front: "Q", back: "A", sourcePages: [0, 2, 99])], skipped: [], usage: nil))
        XCTAssertEqual(lecture.cards[0].sourcePages, [0, 2, 99])
        XCTAssertEqual(lecture.jobs[0].state, .succeeded)
        XCTAssertTrue(lecture.issues(for: lecture.cards[0]).contains { $0.kind == .invalidSource })
        XCTAssertThrowsError(try LectureReducer.reduce(&lecture, action: .setVerdict(cardID: lecture.cards[0].id, .good)))
        XCTAssertEqual(lecture.cards[0].verdict, .unreviewed)
    }
    func testHistoryEditsStaleProposalAndUndoPreserveAsyncJobs() throws {
        let card = Card(sourcePages: [1], front: "Q", back: "A", verdict: .good)
        let job = Job(kind: .revise, pages: [1], targetCardID: card.id, baseRevisionID: card.currentRevisionID)
        var controller = LectureController(lecture: Lecture(moduleID: UUID(), name: "L", pageCount: 1, cards: [card], jobs: [job]))
        try controller.dispatch(.commitEdit(cardID: card.id, front: "Manual Q", back: "A", sourcePages: [1]))
        XCTAssertEqual(controller.lecture.cards[0].verdict, .unreviewed)
        try controller.dispatch(.landProposal(jobID: job.id, cards: [CardDraft(front: "AI Q", back: "A", sourcePages: [1])], rationale: "Fix", usage: nil))
        XCTAssertTrue(controller.lecture.cards[0].proposalIsStale)
        controller.undo()
        XCTAssertEqual(controller.lecture.cards[0].front, "Q")
        XCTAssertEqual(controller.lecture.cards[0].history.count, 3)
        XCTAssertEqual(controller.lecture.jobs[0].state, .succeeded)
        XCTAssertNotNil(controller.lecture.cards[0].proposal)
    }
    func testSplitNeverApprovesChildrenAndCoverageExcludesSupersededAndBad() throws {
        var card = Card(sourcePages: [1], front: "Q", back: "A")
        card.proposal = Proposal(jobID: UUID(), baseRevisionID: card.currentRevisionID!, cards: [CardDraft(front: "Q1", back: "A1", sourcePages: [1]), CardDraft(front: "Q2", back: "A2", sourcePages: [1])])
        var lecture = Lecture(moduleID: UUID(), name: "L", pageCount: 2, cards: [card])
        try LectureReducer.reduce(&lecture, action: .acceptProposal(cardID: card.id, approve: true))
        XCTAssertTrue(lecture.cards[0].isSuperseded)
        XCTAssertEqual(lecture.cards.dropFirst().map(\.verdict), [.unreviewed, .unreviewed])
        XCTAssertEqual(lecture.coverage(page: 1), 2)
        try LectureReducer.reduce(&lecture, action: .setVerdict(cardID: lecture.cards[1].id, .bad))
        XCTAssertEqual(lecture.coverage(page: 1), 1)
        XCTAssertEqual(lecture.uncoveredSelectedPages, [2])
    }
    func testExportStableIdentityEscapingAndChangedRevisions() throws {
        let card = Card(sourcePages: [1], front: "<Q>\n$x$", back: "A", verdict: .good)
        var lecture = Lecture(moduleID: UUID(), name: "Lecture 1", pageCount: 1, cards: [card])
        let first = try AnkiExporter.export(lecture: lecture, moduleName: "Module A")
        XCTAssertFalse(first.text.contains("#guid column:"))
        XCTAssertTrue(first.text.contains("#notetype:Lectern"))
        XCTAssertTrue(first.text.contains("#columns:LecternID\tFront\tBack\tTags"))
        XCTAssertEqual(first.entries, [ExportEntry(lectureID: lecture.id, cardID: card.id, revisionID: card.currentRevisionID!)])
        XCTAssertTrue(first.text.contains(card.id.uuidString))
        XCTAssertTrue(first.text.contains("&lt;Q&gt;<br>\\(x\\)"))
        XCTAssertTrue(first.text.contains("Module_A::Lecture_1"))
        try LectureReducer.reduce(&lecture, action: .markExported(cardIDs: first.cardIDs))
        XCTAssertTrue(try AnkiExporter.export(lecture: lecture, moduleName: "M").cardIDs.isEmpty)
        try LectureReducer.reduce(&lecture, action: .commitEdit(cardID: card.id, front: "New", back: "A", sourcePages: [1]))
        XCTAssertTrue(lecture.cards[0].changedSinceExport)
        try LectureReducer.reduce(&lecture, action: .setVerdict(cardID: card.id, .good))
        XCTAssertEqual(try AnkiExporter.export(lecture: lecture, moduleName: "M").cardIDs, [card.id])
    }
    func testWordDiffReconstructsBothSides() {
        let before = "What is\nold?", after = "What is new?"
        let tokens = WordDiff.compare(before, after)
        XCTAssertEqual(tokens.filter { $0.kind != .inserted }.map(\.text).joined(), before)
        XCTAssertEqual(tokens.filter { $0.kind != .removed }.map(\.text).joined(), after)
    }
    func testProposalScopeAndInvalidSizeAreEnforced() throws {
        let card = Card(sourcePages: [1], front: "Q", back: "A", origin: .generated(jobID: UUID()), allowedSourcePages: [1, 2])
        let job = Job(kind: .revise, pages: [1], targetCardID: card.id, baseRevisionID: card.currentRevisionID)
        var lecture = Lecture(moduleID: UUID(), name: "L", pageCount: 2, cards: [card], jobs: [job])
        XCTAssertThrowsError(try LectureReducer.reduce(&lecture, action: .landProposal(jobID: job.id, cards: [], rationale: "", usage: nil)))
        XCTAssertEqual(lecture.jobs[0].state, .running)
        try LectureReducer.reduce(&lecture, action: .landProposal(jobID: job.id, cards: [CardDraft(front: "New", back: "A", sourcePages: [2])], rationale: "", usage: nil))
        try LectureReducer.reduce(&lecture, action: .acceptProposal(cardID: card.id, approve: false))
        XCTAssertEqual(lecture.cards[0].sourcePages, [2])
        XCTAssertEqual(lecture.cards[0].allowedSourcePages, [1])
        XCTAssertTrue(lecture.issues(for: lecture.cards[0]).contains { $0.kind == .invalidSource })
        XCTAssertThrowsError(try LectureReducer.reduce(&lecture, action: .setVerdict(cardID: card.id, .good)))
    }
    func testGeneratedMissingSourcesBlockedButManualImportAllowed() throws {
        let generated = Card(front: "Q", back: "A", origin: .generated(jobID: UUID()))
        let manual = Card(front: "Q", back: "A")
        let lecture = Lecture(moduleID: UUID(), name: "L", pageCount: 1, cards: [generated, manual])
        XCTAssertFalse(lecture.issues(for: generated).isEmpty)
        XCTAssertTrue(lecture.issues(for: manual).isEmpty)
    }
    func testCompoundExportIdentityAndCapturedRevisionSurviveAsyncEdit() throws {
        let card = Card(front: "Q", back: "A", verdict: .good)
        var one = Lecture(moduleID: UUID(), name: "One", cards: [card])
        let two = Lecture(moduleID: one.moduleID, name: "Two", cards: [card])
        let result = try AnkiExporter.export(lectures: [one, two], moduleName: "Module")
        XCTAssertEqual(result.entries.count, 2)
        XCTAssertNotEqual(result.entries[0].lecternID, result.entries[1].lecternID)
        try LectureReducer.reduce(&one, action: .commitEdit(cardID: card.id, front: "Updated", back: "A", sourcePages: []))
        try LectureReducer.reduce(&one, action: .markExportEntries(result.entries))
        XCTAssertEqual(one.cards[0].exported?.revisionID, card.currentRevisionID)
        XCTAssertTrue(one.cards[0].changedSinceExport)
        XCTAssertEqual(one.cards[0].verdict, .unreviewed)
    }
    func testControllerReceivePreservesUndoAndRejectsStaleSnapshots() throws {
        let card = Card(front: "Q", back: "A")
        let date = Date(timeIntervalSince1970: 100)
        let original = Lecture(moduleID: UUID(), name: "L", createdAt: date, cards: [card])
        var controller = LectureController(lecture: original)
        try controller.dispatch(.setFeedback(cardID: card.id, "Feedback"), now: date.addingTimeInterval(1))
        var latest = controller.lecture
        latest.jobs.append(Job(kind: .revise, pages: [], startedAt: date))
        latest.updatedAt = date.addingTimeInterval(2)
        try controller.receive(latest)
        XCTAssertTrue(controller.canUndo)
        controller.undo(now: date.addingTimeInterval(3))
        XCTAssertEqual(controller.lecture.cards[0].feedback, "")
        XCTAssertEqual(controller.lecture.jobs.count, 1)
        XCTAssertThrowsError(try controller.receive(original))
        var wrong = latest
        wrong.id = UUID()
        XCTAssertThrowsError(try controller.receive(wrong))
    }
    func testUndoKeepsIncomingNoteWhileRevertingSelection() throws {
        let date = Date(timeIntervalSince1970: 100)
        var controller = LectureController(lecture: Lecture(moduleID: UUID(), name: "L", pageCount: 1, createdAt: date))
        try controller.dispatch(.setSlideSelection(pageIndex: 0, false), now: date.addingTimeInterval(1))
        var latest = controller.lecture
        latest.slides[0].note = "Incoming note"
        latest.updatedAt = date.addingTimeInterval(2)
        try controller.receive(latest)
        controller.undo()
        XCTAssertTrue(controller.lecture.slides[0].isSelected)
        XCTAssertEqual(controller.lecture.slides[0].note, "Incoming note")
    }
    func testLectureMetadataValidationRejectsBadFocusSelectionAndJobPages() throws {
        var lecture = Lecture(moduleID: UUID(), name: "L", pageCount: 2)
        lecture.viewPreferences.focusedPageIndex = 2
        XCTAssertThrowsError(try lecture.validated())
        lecture.viewPreferences.focusedPageIndex = nil
        lecture.viewPreferences.selectedCardID = UUID()
        XCTAssertThrowsError(try lecture.validated())
        lecture.viewPreferences.selectedCardID = nil
        for kind in [JobKind.generate, .ask, .distil] {
            lecture.jobs = [Job(kind: kind, pages: [])]
            if kind == .generate { XCTAssertThrowsError(try lecture.validated()) }
            else { XCTAssertNoThrow(try lecture.validated()) } // Chat may include flashcards without slides.
            lecture.jobs = [Job(kind: kind, pages: [0, 3])]
            XCTAssertThrowsError(try lecture.validated())
        }
        lecture.jobs = [Job(kind: .revise, pages: [])]
        XCTAssertNoThrow(try lecture.validated())
    }
    func testUndoRestoresScopeWhenProposalTextIsIdentical() throws {
        var card = Card(sourcePages: [1], front: "Q", back: "A", allowedSourcePages: [1, 2])
        card.proposal = Proposal(jobID: UUID(), baseRevisionID: card.currentRevisionID!, cards: [CardDraft(front: "Q", back: "A", sourcePages: [1])], allowedSourcePages: [1])
        var controller = LectureController(lecture: Lecture(moduleID: UUID(), name: "L", pageCount: 2, cards: [card]))
        try controller.dispatch(.acceptProposal(cardID: card.id, approve: false))
        XCTAssertEqual(controller.lecture.cards[0].allowedSourcePages, [1])
        controller.undo()
        XCTAssertEqual(controller.lecture.cards[0].allowedSourcePages, [1, 2])
        XCTAssertEqual(controller.lecture.cards[0].history.count, 2)
    }
    func testRepairedProposalClearsLegacySyntaxIssueAndCanBeApproved() throws {
        var card = Card(front: "Malformed original", back: "", issue: CardIssue(kind: .importSyntax, message: "Missing separator"))
        card.proposal = Proposal(jobID: UUID(), baseRevisionID: card.currentRevisionID!, cards: [CardDraft(front: "Repaired Q", back: "Repaired A")])
        var lecture = Lecture(moduleID: UUID(), name: "L", cards: [card])
        try LectureReducer.reduce(&lecture, action: .acceptProposal(cardID: card.id, approve: true))
        XCTAssertNil(lecture.cards[0].issue)
        XCTAssertEqual(lecture.cards[0].verdict, .good)
        XCTAssertEqual(lecture.cards[0].history.first?.front, "Malformed original")
        XCTAssertEqual(lecture.cards[0].history.first?.back, "")
    }
    func testUndoLimitedTo50() throws {
        let card = Card(front: "Q", back: "A")
        var controller = LectureController(lecture: Lecture(moduleID: UUID(), name: "L", cards: [card]))
        for i in 0..<55 { try controller.dispatch(.setFeedback(cardID: card.id, "\(i)")) }
        for _ in 0..<50 { controller.undo() }
        XCTAssertFalse(controller.canUndo)
        XCTAssertEqual(controller.lecture.cards[0].feedback, "4")
    }
}
