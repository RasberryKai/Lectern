import XCTest
@testable import LecternCore

final class DashboardTests: XCTestCase {
    private let utc = TimeZone(secondsFromGMT: 0)!
    private var now: Date { ISO8601DateFormatter().date(from: "2026-03-28T12:00:00Z")! }

    private func snapshot(_ lectures: [Lecture], planned: Int? = nil, exam: ExamDate? = nil) -> DashboardSnapshot {
        let module = Module(id: lectures.first?.moduleID ?? UUID(), name: "Module", lectureIDs: lectures.map(\.id), plannedLectureCount: planned, examDate: exam)
        return DashboardBuilder.build(modules: [module], lectures: lectures, now: now, timeZone: utc)
    }

    private func progress(_ lecture: Lecture) -> LectureProgress { snapshot([lecture]).modules[0].lectures[0] }

    private func approved(exported: Bool = false, pages: [Int] = []) -> Card {
        var card = Card(sourcePages: pages, front: "Question", back: "Answer", verdict: .good)
        if exported { card.exported = ExportMark(revisionID: card.currentRevisionID!, date: now) }
        return card
    }

    func testManualStatusPersistsAndAutomaticCanBeRestored() throws {
        var lecture = Lecture(moduleID: UUID(), name: "L", cards: [Card(front: "Q", back: "A")])
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let legacy = try decoder.decode(Lecture.self, from: encoder.encode(lecture))
        XCTAssertNil(legacy.progressOverride)
        XCTAssertEqual(progress(legacy).status, .toReview)

        lecture.progressOverride = .done
        lecture = try decoder.decode(Lecture.self, from: encoder.encode(lecture))
        let manual = snapshot([lecture], planned: 2)
        XCTAssertEqual(manual.totals.doneLectureCount, 1)
        XCTAssertEqual(manual.totals.reviewCardCount, 1)
        XCTAssertEqual(manual.modules[0].slots.map(\.status), [.done, .notImported])
        XCTAssertEqual(manual.modules[0].nextUp.count, 1)
        XCTAssertEqual(manual.modules[0].nextUp.first, .importLecture(moduleID: lecture.moduleID, slotID: manual.modules[0].slots[1].id))

        lecture.progressOverride = nil
        XCTAssertEqual(snapshot([lecture]).modules[0].nextUp, [.review(lectureID: lecture.id, cardCount: 1)])
    }

    func testReviewUnionCountsEachCardOnceAndAllProposalStates() {
        var cards = [Card(front: "Q", back: "A"), Card(front: "Q", back: "A", verdict: .needsAdjustment), approved(), Card(front: "Q", back: "A", verdict: .bad)]
        let states: [ProposalState] = [.pending, .ready, .failed, .ready]
        for i in cards.indices {
            cards[i].proposal = Proposal(jobID: UUID(), baseRevisionID: cards[i].currentRevisionID!, state: states[i])
        }
        var invalid = approved(); invalid.front = ""
        cards.append(invalid)
        var hidden = Card(front: "Q", back: "A", supersededBy: [])
        hidden.proposal = Proposal(jobID: UUID(), baseRevisionID: hidden.currentRevisionID!)
        cards.append(hidden)
        let result = progress(Lecture(moduleID: UUID(), name: "L", cards: cards))
        XCTAssertEqual(result.status, .toReview)
        XCTAssertEqual(result.reviewCardCount, 5)
        XCTAssertEqual(result.proposalCount, 4)
        XCTAssertEqual(result.readyExportCount, 1)
    }

    func testFlagsDoNotUndoApprovalAndBadIsResolved() {
        var card = approved(exported: true); card.flag = "Check wording"
        let rejected = Card(front: "", back: "", verdict: .bad)
        let result = progress(Lecture(moduleID: UUID(), name: "Legacy", cards: [card, rejected]))
        XCTAssertEqual(result.status, .done)
        XCTAssertEqual(result.reviewCardCount, 0)
        XCTAssertEqual(result.readyExportCount, 0)
    }

    func testNoVacuousDoneAndPreparationReasons() {
        let empty = Lecture(moduleID: UUID(), name: "No source")
        XCTAssertEqual(progress(empty).status, .preparing)
        XCTAssertEqual(progress(empty).preparationReasons, [.addCards])
        var pdf = Lecture(moduleID: UUID(), name: "PDF", pageCount: 2)
        XCTAssertEqual(progress(pdf).preparationReasons, [.generateMissingCoverage(pages: [1, 2])])
        pdf.slides = pdf.slides.map { SlideState(pageIndex: $0.pageIndex, isSelected: false) }
        pdf.cards = [approved(exported: true, pages: [1])]
        XCTAssertEqual(progress(pdf).status, .preparing)
        XCTAssertEqual(progress(pdf).preparationReasons, [.selectSlides])
        var onlyHidden = approved(exported: true); onlyHidden.supersededBy = []
        XCTAssertEqual(progress(Lecture(moduleID: UUID(), name: "Hidden", cards: [onlyHidden])).status, .preparing)
    }

    func testCoverageUsesOneBasedPagesAndExcludesBadAndSuperseded() {
        var hidden = approved(exported: true, pages: [2]); hidden.supersededBy = [UUID()]
        let bad = Card(sourcePages: [3], front: "Q", back: "A", verdict: .bad)
        let lecture = Lecture(moduleID: UUID(), name: "L", pageCount: 3, cards: [approved(exported: true, pages: [1]), hidden, bad])
        let result = progress(lecture)
        XCTAssertEqual(result.selectedPageCount, 3)
        XCTAssertEqual(result.coveredSelectedPageCount, 1)
        XCTAssertEqual(result.status, .preparing)
        XCTAssertEqual(result.preparationReasons, [.generateMissingCoverage(pages: [2, 3])])
    }

    func testStatusPrecedenceAndRunningJobs() {
        let job = Job(kind: .ask, pages: [1])
        var lecture = Lecture(moduleID: UUID(), name: "L", pageCount: 2, cards: [Card(sourcePages: [1], front: "Q", back: "A")], jobs: [job])
        XCTAssertEqual(progress(lecture).status, .toReview)
        lecture.cards[0].verdict = .good
        XCTAssertEqual(progress(lecture).status, .preparing)
        lecture.cards[0].sourcePages = [1, 2]
        XCTAssertEqual(progress(lecture).preparationReasons, [.waitingForJobs(jobIDs: [job.id])])
        lecture.jobs[0].state = .succeeded
        XCTAssertEqual(progress(lecture).status, .toExport)
        lecture.cards[0].exported = ExportMark(revisionID: lecture.cards[0].currentRevisionID!)
        XCTAssertEqual(progress(lecture).status, .done)
        lecture.jobs[0].state = .running
        XCTAssertEqual(progress(lecture).status, .preparing)
    }

    func testExportCountsMatchExistingAnkiRuleAndChangedIsSubset() throws {
        let fresh = approved()
        let unchanged = approved(exported: true)
        var changed = approved(exported: true)
        changed.history.append(CardRevision(front: changed.front, back: changed.back, at: now))
        let rejected = Card(front: "Q", back: "A", verdict: .bad)
        var hidden = approved(); hidden.supersededBy = []
        let lecture = Lecture(moduleID: UUID(), name: "L", cards: [fresh, unchanged, changed, rejected, hidden])
        let result = progress(lecture)
        XCTAssertEqual(result.readyExportCount, 2)
        XCTAssertEqual(result.changedExportCount, 1)
        XCTAssertEqual(result.readyExportCount, try AnkiExporter.export(lecture: lecture, moduleName: "Module").entries.count)
        var invalid = approved(); invalid.sourcePages = [9]
        let invalidResult = progress(Lecture(moduleID: UUID(), name: "L", cards: [invalid]))
        XCTAssertEqual(invalidResult.status, .toReview)
        XCTAssertEqual(invalidResult.readyExportCount, 0)
    }

    func testProgressMovesBackwardAndForwardImmediately() throws {
        var lecture = Lecture(moduleID: UUID(), name: "L", pageCount: 2, cards: [approved(exported: true, pages: [1])])
        XCTAssertEqual(progress(lecture).status, .preparing)
        try LectureReducer.reduce(&lecture, action: .setSlideSelection(pageIndex: 1, false), now: now)
        XCTAssertEqual(progress(lecture).status, .done)
        try LectureReducer.reduce(&lecture, action: .setVerdict(cardID: lecture.cards[0].id, .needsAdjustment), now: now)
        XCTAssertEqual(progress(lecture).status, .toReview)
        try LectureReducer.reduce(&lecture, action: .setVerdict(cardID: lecture.cards[0].id, .good), now: now)
        XCTAssertEqual(progress(lecture).status, .done)
        try LectureReducer.reduce(&lecture, action: .commitEdit(cardID: lecture.cards[0].id, front: "New question", back: "Answer", sourcePages: [1]), now: now)
        XCTAssertEqual(progress(lecture).status, .toReview)
        try LectureReducer.reduce(&lecture, action: .setVerdict(cardID: lecture.cards[0].id, .good), now: now)
        XCTAssertEqual(progress(lecture).status, .toExport)
        try LectureReducer.reduce(&lecture, action: .markExported(cardIDs: [lecture.cards[0].id]), now: now)
        XCTAssertEqual(progress(lecture).status, .done)
        try LectureReducer.reduce(&lecture, action: .updateNote(pageIndex: 0, "Remember this"), now: now)
        XCTAssertEqual(progress(lecture).status, .done)
        try LectureReducer.reduce(&lecture, action: .setSlideSelection(pageIndex: 1, true), now: now)
        XCTAssertEqual(progress(lecture).status, .preparing)
    }

    func testSplitChildrenNeedReviewAndSupersededParentDoesNotCount() throws {
        var parent = approved(exported: true, pages: [1])
        parent.proposal = Proposal(jobID: UUID(), baseRevisionID: parent.currentRevisionID!, cards: [CardDraft(front: "One", back: "A", sourcePages: [1]), CardDraft(front: "Two", back: "B", sourcePages: [1])])
        var lecture = Lecture(moduleID: UUID(), name: "L", pageCount: 1, cards: [parent])
        XCTAssertEqual(progress(lecture).reviewCardCount, 1)
        try LectureReducer.reduce(&lecture, action: .acceptProposal(cardID: parent.id, approve: true), now: now)
        let result = progress(lecture)
        XCTAssertEqual(result.status, .toReview)
        XCTAssertEqual(result.reviewCardCount, 2)
        XCTAssertEqual(result.proposalCount, 0)
        XCTAssertEqual(result.coveredSelectedPageCount, 1)
        XCTAssertEqual(result.changedExportCount, 0)
    }

    func testModuleAndLectureOrderSlotsAndGlobalTotalsExcludeArchive() {
        let firstID = UUID(), secondID = UUID(), archivedID = UUID()
        let done = Lecture(moduleID: firstID, name: "Done", cards: [approved(exported: true)])
        var proposed = Card(front: "Q", back: "A", verdict: .needsAdjustment)
        proposed.proposal = Proposal(jobID: UUID(), baseRevisionID: proposed.currentRevisionID!)
        let review = Lecture(moduleID: firstID, name: "Review", cards: [proposed])
        var changed = approved(exported: true); changed.history.append(CardRevision(front: "Q", back: "A", at: now))
        let export = Lecture(moduleID: secondID, name: "Export", cards: [approved(), changed])
        let ignored = Lecture(moduleID: archivedID, name: "Archived", cards: [Card(front: "Q", back: "A")])
        let modules = [Module(id: secondID, name: "Second", lectureIDs: [export.id], plannedLectureCount: 2),
                       Module(id: archivedID, name: "Archived", lectureIDs: [ignored.id], plannedLectureCount: 20, archivedAt: now),
                       Module(id: firstID, name: "First", lectureIDs: [review.id, done.id], plannedLectureCount: 4)]
        let result = DashboardBuilder.build(modules: modules, lectures: [done, export, ignored, review], now: now, timeZone: utc)
        XCTAssertEqual(result.modules.map(\.id), [secondID, firstID])
        XCTAssertEqual(result.modules[1].lectures.map(\.lectureID), [review.id, done.id])
        XCTAssertEqual(result.modules[1].slots.map(\.status), [.toReview, .done, .notImported, .notImported])
        XCTAssertEqual(result.modules[1].statusCounts[.done], 1)
        XCTAssertEqual(result.modules[1].statusCounts[.preparing], 0)
        XCTAssertEqual(result.archivedModules, [modules[1]])
        XCTAssertEqual(result.archivedModuleCount, 1)
        XCTAssertEqual(result.totals.plannedLectureCount, 6)
        XCTAssertEqual(result.totals.doneLectureCount, 1)
        XCTAssertEqual(result.totals.reviewCardCount, 1)
        XCTAssertEqual(result.totals.reviewLectureCount, 1)
        XCTAssertEqual(result.totals.proposalCount, 1)
        XCTAssertEqual(result.totals.readyExportCount, 2)
        XCTAssertEqual(result.totals.changedExportCount, 1)
        XCTAssertEqual(result.totals.notImportedCount, 3)
        XCTAssertEqual(result.totals.remainingLectureCount, 5)
    }

    func testSlotsRemainStableWhenFilledAndTooSmallPlanIsTolerated() {
        var module = Module(name: "M", plannedLectureCount: 2)
        let before = DashboardBuilder.build(modules: [module], lectures: [], now: now, timeZone: utc).modules[0]
        let lecture = Lecture(moduleID: module.id, name: "L")
        module.lectureIDs = [lecture.id]
        let after = DashboardBuilder.build(modules: [module], lectures: [lecture], now: now, timeZone: utc).modules[0]
        XCTAssertEqual(before.slots.map(\.id), after.slots.map(\.id))
        XCTAssertEqual(after.slots.map(\.id.index), [1, 2])
        XCTAssertEqual(after.slots[0].lectureID, lecture.id)
        module.plannedLectureCount = 0
        let undersized = DashboardBuilder.build(modules: [module], lectures: [lecture], now: now, timeZone: utc).modules[0]
        XCTAssertEqual(undersized.slots.count, 1)
        XCTAssertEqual(undersized.totals.plannedLectureCount, 1)
    }

    func testSameLectureUUIDAcrossModulesDoesNotCrossWireProgress() {
        let lectureID = UUID(), activeID = UUID(), archivedID = UUID()
        let active = Lecture(id: lectureID, moduleID: activeID, name: "Active", cards: [approved(exported: true)])
        let archived = Lecture(id: lectureID, moduleID: archivedID, name: "Archived", cards: [Card(front: "Q", back: "A")])
        let modules = [Module(id: activeID, name: "Active", lectureIDs: [lectureID]),
                       Module(id: archivedID, name: "Archived", lectureIDs: [lectureID], archivedAt: now)]
        let result = DashboardBuilder.build(modules: modules, lectures: [active, archived], now: now, timeZone: utc)
        XCTAssertEqual(result.modules[0].lectures[0].name, "Active")
        XCTAssertEqual(result.modules[0].lectures[0].status, .done)
        XCTAssertEqual(result.totals.doneLectureCount, 1)
        XCTAssertEqual(result.totals.reviewCardCount, 0)
    }

    func testUnboundedStandalonePlanIsCappedAndNegativePlanDoesNotTrap() {
        let excessive = Module(name: "Huge", plannedLectureCount: Int.max)
        let negative = Module(name: "Negative", plannedLectureCount: -1)
        let result = DashboardBuilder.build(modules: [excessive, negative], lectures: [], now: now, timeZone: utc)
        XCTAssertEqual(result.modules[0].slots.count, Module.maximumPlannedLectureCount)
        XCTAssertEqual(result.modules[1].slots.count, 0)
    }

    func testNextUpOrderCapAndExportIncludesAllEligibleLectures() {
        let moduleID = UUID()
        let review = Lecture(moduleID: moduleID, name: "Review", cards: [Card(front: "Q", back: "A"), approved()])
        let export = Lecture(moduleID: moduleID, name: "Export", cards: [approved()])
        let preparing = Lecture(moduleID: moduleID, name: "Prepare", pageCount: 1)
        let result = snapshot([review, export, preparing], planned: 4).modules[0]
        XCTAssertEqual(result.nextUp, [.review(lectureID: review.id, cardCount: 1),
                                       .export(moduleID: moduleID, lectureIDs: [review.id, export.id], cardCount: 2, changedCardCount: 0),
                                       .prepare(lectureID: preparing.id, reasons: [.generateMissingCoverage(pages: [1])])])
        let importOnly = snapshot([], planned: 2).modules[0]
        XCTAssertEqual(importOnly.nextUp, [.importLecture(moduleID: importOnly.id, slotID: importOnly.slots[0].id)])
        let completed = snapshot([Lecture(moduleID: moduleID, name: "Done", cards: [approved(exported: true)])]).modules[0]
        XCTAssertTrue(completed.nextUp.isEmpty)
    }

    func testPaceStatesAndExactFractionalWeeks() throws {
        let lecture = Lecture(moduleID: UUID(), name: "L")
        XCTAssertEqual(snapshot([lecture], planned: 3).modules[0].pace, .noExam)
        let future = try ExamDate(year: 2026, month: 4, day: 7)
        XCTAssertEqual(snapshot([lecture], planned: 3, exam: future).modules[0].pace, .future(daysRemaining: 10, lecturesPerWeek: 2.1))
        XCTAssertEqual(snapshot([lecture], exam: try ExamDate(year: 2026, month: 3, day: 28)).modules[0].pace, .dueToday)
        XCTAssertEqual(snapshot([lecture], exam: try ExamDate(year: 2026, month: 3, day: 25)).modules[0].pace, .overdue(daysOverdue: 3))
        let done = Lecture(moduleID: UUID(), name: "Done", cards: [approved(exported: true)])
        XCTAssertEqual(snapshot([done], exam: try ExamDate(year: 2020, month: 1, day: 1)).modules[0].pace, .complete)
    }

    func testPaceUsesLocalCalendarAcrossDSTAndMidnight() throws {
        let berlin = TimeZone(identifier: "Europe/Berlin")!
        let module = Module(name: "M", plannedLectureCount: 2, examDate: try ExamDate(year: 2026, month: 3, day: 30))
        let beforeDST = ISO8601DateFormatter().date(from: "2026-03-28T23:30:00Z")!
        let local = DashboardBuilder.build(modules: [module], lectures: [], now: beforeDST, timeZone: berlin)
        let universal = DashboardBuilder.build(modules: [module], lectures: [], now: beforeDST, timeZone: utc)
        XCTAssertEqual(local.modules[0].pace, .future(daysRemaining: 1, lecturesPerWeek: 14))
        XCTAssertEqual(universal.modules[0].pace, .future(daysRemaining: 2, lecturesPerWeek: 7))
        let localExamDay = ISO8601DateFormatter().date(from: "2026-03-29T22:01:00Z")!
        XCTAssertEqual(DashboardBuilder.build(modules: [module], lectures: [], now: localExamDay, timeZone: berlin).modules[0].pace, .dueToday)
        XCTAssertEqual(module.archivedAt, nil)
    }
}
