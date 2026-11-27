import Foundation
import CoreGraphics
import Testing
@testable import LecternCore

struct SolveStudyPersistenceTests {
    @Test func approvalEnablesRefillAndPresentationStaysSpentAcrossUndoAndReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Lectern-Solve-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(rootURL: root)
        let module = try await store.createModule(name: "Statistics")
        let pdf = root.appendingPathComponent("Variance.pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 300, height: 200)
        let context = try #require(CGContext(pdf as CFURL, mediaBox: &mediaBox, nil))
        context.beginPDFPage(nil)
        context.endPDFPage()
        context.closePDF()
        let lecture = try await store.importPDF(from: pdf, moduleID: module.id)
        let flip = Card(sourcePages: [1], front: "How do you calculate variance?", back: "E(X²) − E(X)²", verdict: .good)
        let sample = SolveVariance(outcomes: [0, 2], weights: [1, 1]).exercise
        let draft = SolveDraft(skill: "Calculate variance", reason: "Apply the formula", variation: "Vary the distribution", sample: sample)
        let draftID = UUID()
        let variant = SolveVariance(outcomes: [0, 4], weights: [1, 1]).exercise
        _ = try await store.updateLecture(moduleID: module.id, lectureID: lecture.id) { latest in
            latest.cards = [flip]
            var job = Job(id: draftID, kind: .generate, pages: [1])
            job.state = .running
            try LectureReducer.reduce(&latest, action: .startJob(job))
            try LectureReducer.reduce(&latest, action: .landGeneration(jobID: draftID,
                cards: [CardDraft(front: sample.prompt, back: sample.explanation, sourcePages: [1], solve: draft)],
                skipped: [], usage: nil))
        }
        let generated = try await store.loadLecture(moduleID: module.id, lectureID: lecture.id)
        let solve = try #require(generated.cards.last)
        #expect(solve.solve?.activeCases.count == 1)
        #expect(solve.verdict == .unreviewed)
        let beforeApproval = StudyCard(moduleID: module.id, lectureID: lecture.id, lectureName: lecture.name,
                                       moduleName: module.name, card: solve, memory: nil)
        #expect(try await store.solveRefillCandidate(beforeApproval) == nil)
        #expect(try await store.appendSolveCases([variant], to: beforeApproval) == 0)
        _ = try await store.updateLecture(moduleID: module.id, lectureID: lecture.id) { latest in
            try LectureReducer.reduce(&latest, action: .setVerdict(cardID: solve.id, .good))
        }

        let at = Date(timeIntervalSince1970: 1_767_312_000)
        let catalog = try await store.studyCatalog(now: at)
        let first = try #require(catalog.decks.first?.approvedCards.last)
        #expect(first.id == solve.id && first.availableSolveCases.count == 1)
        #expect(try await store.appendSolveCases([variant, sample, variant], to: first) == 1)
        var options = StudySessionOptions()
        options.cardTypes = .flip
        #expect(catalog.plan(options: options, now: at).cards.map(\.id) == [flip.id])
        options.cardTypes = .solve
        #expect(catalog.plan(options: options, now: at).cards.map(\.id) == [solve.id])

        let presentationID = UUID()
        let exercise = try #require(try await store.presentSolveCase(first, presentationID: presentationID, now: at))
        #expect(try await store.presentSolveCase(first, presentationID: presentationID, now: at)?.id == exercise.id)
        await #expect(throws: LibraryError.self) {
            try await store.gradeStudyCard(first, rating: .good, eventID: UUID(), now: at,
                                           answeringTime: 1, permitEarly: false, extraNewPerModule: 0)
        }
        let gradeID = UUID()
        // An incorrect but valid response can be self-rated Good.
        let response = StudySolveResponse(presentationID: presentationID, caseID: exercise.id, answers: [.text("1"), .text("2"), .text("2")])
        let recorded = try await store.gradeStudyCard(first, rating: .good, eventID: gradeID, now: at,
                                                      answeringTime: 1, permitEarly: false, extraNewPerModule: 0, solveResponse: response)
        #expect(recorded.phase == .review)
        try await store.undoStudyGrade(moduleID: module.id, eventID: gradeID)
        try FileManager.default.removeItem(at: store.moduleDirectory(module.id).appendingPathComponent("study.json"))

        let reopened = LibraryStore(rootURL: root)
        let replayed = try await reopened.studyCatalog(now: at)
        let entry = try #require(replayed.decks.first?.approvedCards.last)
        #expect(entry.memory == nil)
        #expect(entry.seenSolveCaseIDs == [exercise.id])
        let rerecorded = try await reopened.gradeStudyCard(entry, rating: .again, eventID: UUID(), now: at,
                                                        answeringTime: 1, permitEarly: false, extraNewPerModule: 0, solveResponse: response)
        #expect(rerecorded.phase == .learning)
        #expect(try await reopened.askFlashcard(moduleID: module.id, lectureID: lecture.id, sourcePage: 1,
                                                now: rerecorded.due)?.id == flip.id)
        let retry = try #require(try await reopened.studyCatalog(now: at).decks.first?.approvedCards.last)
        let next = try #require(try await reopened.presentSolveCase(retry, presentationID: UUID(), now: at))
        #expect(next.id != exercise.id && next.content == variant)
        #expect(try await reopened.presentSolveCase(retry, presentationID: UUID(), now: at) == nil)
        _ = try await reopened.retireSolveCase(retry, caseID: next.id)
        #expect(try await reopened.appendSolveCases([variant], to: retry) == 0)
        let deferred = try await reopened.studyCatalog(now: rerecorded.due)
        #expect(deferred.plan(options: options, now: rerecorded.due).cards.isEmpty)
        #expect(deferred.plan(options: options, now: rerecorded.due).deferredSolveCount == 1)
        #expect(deferred.decks.first?.memory[solve.id] == rerecorded)
    }

    @Test func applyingSolveProposalKeepsTheFlipAndExportsTheWorkedSample() throws {
        let flip = Card(sourcePages: [1], front: "Variance formula", back: "E(X²) − E(X)²", verdict: .good)
        let sample = SolveVariance(outcomes: [0, 4], weights: [1, 1]).exercise
        let draft = SolveDraft(skill: "Calculate variance", reason: "Practice calculation", variation: "New probabilities", sample: sample)
        var lecture = Lecture(moduleID: UUID(), name: "Statistics", pageCount: 1, cards: [flip])
        let proposal = Proposal(jobID: UUID(), baseRevisionID: try #require(flip.currentRevisionID),
                                cards: [CardDraft(front: sample.prompt, back: sample.explanation, sourcePages: [1], solve: draft)])
        lecture.cards[0].proposal = proposal
        try LectureReducer.reduce(&lecture, action: .acceptProposal(cardID: flip.id, approve: true))
        #expect(lecture.cards.first == flip)
        let solve = try #require(lecture.cards.last)
        #expect(solve.id != flip.id && solve.solve?.draft == draft)
        let exported = try AnkiExporter.export(lecture: lecture, moduleName: "Math")
        #expect(exported.cardIDs == [flip.id, solve.id])
        #expect(exported.text.contains("Var(X)"))
        #expect(exported.text.contains("4.0"))
    }
}
