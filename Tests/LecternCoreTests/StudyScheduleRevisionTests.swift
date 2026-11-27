import Foundation
import CoreGraphics
import Testing
@testable import LecternCore

struct StudyScheduleRevisionTests {
    private let start = Date(timeIntervalSince1970: 1_767_312_000)
    private let utc = TimeZone(secondsFromGMT: 0)!

    @Test func confirmedSolveRevisionGetsFreshScheduleAndKeepsFlipHistory() async throws {
        let fixture = try await makeFixture(newCardLimit: 1)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let flip = try #require(try await fixture.store.studyCatalog(now: start, timeZone: utc)
            .decks.first?.approvedCards.first)
        let flipGradeID = UUID()
        let flipMemory = try await grade(.good, flip, id: flipGradeID, at: start, in: fixture.store)
        #expect(try await fixture.store.studyCatalog(now: start, timeZone: utc).introducedToday == 1)

        let solve = try await convert(flip, in: fixture.store)
        #expect(solve.id == flip.id)
        #expect(solve.card.history.count == flip.card.history.count + 1)
        #expect(solve.card.studyScheduleID == solve.card.currentRevisionID)
        #expect(solve.memory == nil)

        // The old session cannot spend or grade its stale flip attempt after conversion.
        await #expect(throws: LibraryError.self) {
            try await fixture.store.presentSolveCase(flip, presentationID: UUID(), now: start, timeZone: utc)
        }
        await #expect(throws: LibraryError.self) {
            try await grade(.again, flip, at: start, in: fixture.store)
        }

        let firstPresentation = UUID()
        let exercise = try #require(try await fixture.store.presentSolveCase(
            solve, presentationID: firstPresentation, now: start, timeZone: utc))
        let firstResponse = response(for: exercise, presentationID: firstPresentation)
        // The replacement is unseen and spends the module's one new-card allowance.
        await #expect(throws: LibraryError.self) {
            try await grade(.good, solve, at: start, in: fixture.store, response: firstResponse)
        }
        #expect(try await fixture.store.studyCatalog(now: start, timeZone: utc).introducedToday == 1)

        let tomorrow = start.addingTimeInterval(86_400)
        let current = try #require(try await fixture.store.studyCatalog(now: tomorrow, timeZone: utc)
            .decks.first?.approvedCards.first)
        #expect(current.id == flip.id && current.memory == nil)
        let secondPresentation = UUID()
        let secondExercise = try #require(try await fixture.store.presentSolveCase(
            current, presentationID: secondPresentation, now: tomorrow, timeZone: utc))
        let solveGradeID = UUID()
        let solveMemory = try await grade(.good, current, id: solveGradeID, at: tomorrow, in: fixture.store,
                                          response: response(for: secondExercise, presentationID: secondPresentation))
        #expect(solveMemory.reps == 1)
        #expect(try await fixture.store.studyCatalog(now: tomorrow, timeZone: utc).introducedToday == 1)
        #expect(try await fixture.store.studyCatalog(now: tomorrow, timeZone: utc)
            .decks.first?.memory[flip.id] == solveMemory)

        var journal = try StudyJournal(directory: fixture.store.moduleDirectory(fixture.module.id))
        #expect(journal.state.memory(for: flip.id, studyScheduleID: nil) == flipMemory)
        #expect(journal.state.memory(for: flip.id, studyScheduleID: solve.card.studyScheduleID) == solveMemory)

        // Undo buttons left over from the flip session cannot mutate that inactive projection.
        await #expect(throws: LibraryError.self) {
            try await fixture.store.undoStudyGrade(moduleID: fixture.module.id, eventID: flipGradeID)
        }
        #expect(try await fixture.store.studyCatalog(now: tomorrow, timeZone: utc)
            .decks.first?.memory[flip.id] == solveMemory)

        try await fixture.store.undoStudyGrade(moduleID: fixture.module.id, eventID: solveGradeID)
        #expect(try await fixture.store.studyCatalog(now: tomorrow, timeZone: utc)
            .decks.first?.memory[flip.id] == nil)
        #expect(try await fixture.store.studyCatalog(now: tomorrow, timeZone: utc).introducedToday == 0)
        journal = try StudyJournal(directory: fixture.store.moduleDirectory(fixture.module.id))
        #expect(journal.state.memory(for: flip.id, studyScheduleID: nil) == flipMemory)
        #expect(journal.state.memory(for: flip.id, studyScheduleID: solve.card.studyScheduleID) == nil)
    }

    @Test func rescheduleUsesTheActiveSolveScheduleAndReplaysAfterCacheLoss() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var preferences = StudyPreferences()
        preferences.defaults.solveFirstCorrect = .repeatAfter(10)
        try await fixture.store.saveStudyPreferences(preferences)

        let flip = try #require(try await fixture.store.studyCatalog(now: start, timeZone: utc)
            .decks.first?.approvedCards.first)
        let solve = try await convert(flip, in: fixture.store)
        let presentationID = UUID()
        let exercise = try #require(try await fixture.store.presentSolveCase(
            solve, presentationID: presentationID, now: start, timeZone: utc))
        let gradeID = UUID()
        let first = try await grade(.good, solve, id: gradeID, at: start, in: fixture.store,
                                    response: response(for: exercise, presentationID: presentationID))
        #expect(first.awaitingLearningRepeat == true)
        #expect(first.due == start.addingTimeInterval(600))

        var overrides = StudyOverrides()
        overrides.solveFirstCorrect = .repeatAfter(20)
        try await fixture.store.saveStudyOverrides(moduleID: fixture.module.id, overrides)
        let preview = try await fixture.store.previewStudyReschedule(moduleID: fixture.module.id)
        #expect(preview.count == 1)
        try await fixture.store.applyStudyReschedule(preview)

        let rescheduled = try #require(try await fixture.store.studyCatalog(now: start, timeZone: utc)
            .decks.first?.approvedCards.first?.memory)
        #expect(rescheduled.due == start.addingTimeInterval(1_200))
        let journalURL = fixture.store.moduleDirectory(fixture.module.id).appendingPathComponent(StudyJournal.journalName)
        let lines = try Data(contentsOf: journalURL).split(separator: 0x0a)
        let events = try lines.map { try JSONSerialization.jsonObject(with: Data($0)) as! [String: Any] }
        #expect(events.contains { ($0["schemaVersion"] as? Int) == 2 })

        // The JSONL journal is authoritative; a reschedule event keeps its card-to-schedule key.
        try FileManager.default.removeItem(at: fixture.store.moduleDirectory(fixture.module.id)
            .appendingPathComponent(StudyJournal.snapshotName))
        let reopened = LibraryStore(rootURL: fixture.store.rootURL)
        let restored = try #require(try await reopened.studyCatalog(now: start, timeZone: utc)
            .decks.first?.approvedCards.first?.memory)
        #expect(restored == rescheduled)
        await #expect(throws: LibraryError.self) {
            try await reopened.undoStudyGrade(moduleID: fixture.module.id, eventID: gradeID)
        }
    }

    @Test func legacyScheduleEventsAndOldSnapshotAreReplayed() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lectern-study-legacy-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let cardID = UUID()
        var configuration = StudyConfiguration()
        let grade = StudyJournalEvent(id: UUID(), cardID: cardID, at: start,
                                      studyDay: StudyCatalog.studyDay(at: start, timeZone: utc), source: .study,
                                      payload: .grade(rating: .good, answeringTime: 1, configuration: configuration))
        configuration.flipFirstCorrect = .repeatAfter(20)
        let reschedule = StudyJournalEvent(id: UUID(), cardID: nil, at: start,
                                           studyDay: StudyCatalog.studyDay(at: start, timeZone: utc), source: .reschedule,
                                           payload: .reschedule(configuration: configuration, cardIDs: [cardID]))
        var data = try legacyLine(grade)
        data.append(try legacyLine(reschedule))
        let journalURL = root.appendingPathComponent(StudyJournal.journalName)
        try data.write(to: journalURL)

        let expected = try #require(StudyJournal.replay(data).memory(for: cardID, studyScheduleID: nil))
        #expect(expected.due == start.addingTimeInterval(1_200))

        var journal = try StudyJournal(directory: root)
        let cacheURL = root.appendingPathComponent(StudyJournal.snapshotName)
        var cache = try JSONSerialization.jsonObject(with: Data(contentsOf: cacheURL)) as! [String: Any]
        cache["schemaVersion"] = 1
        var state = cache["state"] as! [String: Any]
        state["scheduleMemory"] = []
        cache["state"] = state
        try JSONSerialization.data(withJSONObject: cache, options: [.sortedKeys]).write(to: cacheURL)

        journal = try StudyJournal(directory: root)
        #expect(journal.state.memory(for: cardID, studyScheduleID: nil) == expected)
        #expect(journal.state.introductions[StudyCatalog.studyDay(at: start, timeZone: utc)] == 1)
    }

    private struct Fixture {
        let root: URL
        let store: LibraryStore
        let module: Module
        let lecture: Lecture
    }

    private func makeFixture(newCardLimit: Int? = nil) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lectern-study-revision-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let pdf = root.appendingPathComponent("Source.pdf")
        var box = CGRect(x: 0, y: 0, width: 300, height: 200)
        let context = try #require(CGContext(pdf as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.endPDFPage()
        context.closePDF()
        let store = LibraryStore(rootURL: root.appendingPathComponent("Library"))
        let module = try await store.createModule(name: "Statistics")
        if let newCardLimit { try await store.setStudyNewCardLimit(moduleID: module.id, limit: newCardLimit) }
        let flip = Card(sourcePages: [1], front: "How do you calculate variance?", back: "E(X²) − E(X)²", verdict: .good)
        let lecture = try await store.createLecture(Lecture(moduleID: module.id, name: "First lecture", pageCount: 1,
                                                             cards: [flip]), sourceURL: pdf)
        return Fixture(root: root, store: store, module: module, lecture: lecture)
    }

    private func convert(_ entry: StudyCard, in store: LibraryStore) async throws -> StudyCard {
        let sample = SolveCaseContent(prompt: "Put the closing stages in order.", fields: [
            SolveField(prompt: "Closing stages", order: SolveOrder(items: ["Adjust", "Close", "Verify"],
                                                                     sequences: [["Adjust", "Close", "Verify"]]))
        ], explanation: "Adjust the balances, close temporary accounts, then verify the post-closing balances.")
        let draft = SolveDraft(skill: "Closing sequence", reason: "Recall the steps", variation: "Shuffle the steps",
                               sample: sample)
        _ = try await store.updateLecture(moduleID: entry.moduleID, lectureID: entry.lectureID) { lecture in
            guard let index = lecture.cards.firstIndex(where: { $0.id == entry.id }) else {
                throw LectureError.missingCard(entry.id)
            }
            var card = lecture.cards[index]
            try card.setSolveDraft(draft)
            card.verdict = .unreviewed
            var revision = CardRevision(front: card.front, back: card.back, author: .user, reason: "Confirmed solve replacement")
            revision.solve = draft
            card.history.append(revision)
            card.solveStudyScheduleID = revision.id
            lecture.cards[index] = card
            try LectureReducer.reduce(&lecture, action: .setVerdict(cardID: entry.id, .good))
        }
        return try #require(try await store.studyCatalog(now: start, timeZone: utc)
            .decks.first(where: { $0.id == entry.moduleID })?.approvedCards.first(where: { $0.id == entry.id }))
    }

    private func grade(_ rating: StudyRating, _ entry: StudyCard, id: UUID = UUID(), at: Date,
                       in store: LibraryStore, response: StudySolveResponse? = nil) async throws -> StudyMemoryState {
        try await store.gradeStudyCard(entry, rating: rating, eventID: id, now: at, answeringTime: 1,
                                       permitEarly: false, extraNewPerModule: 0, timeZone: utc,
                                       solveResponse: response)
    }

    private func response(for exercise: SolveCase, presentationID: UUID) -> StudySolveResponse {
        StudySolveResponse(presentationID: presentationID, caseID: exercise.id,
                           answers: [.order(["Adjust", "Close", "Verify"])])
    }

    private func legacyLine(_ event: StudyJournalEvent) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(event)
        var object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        object.removeValue(forKey: "studyScheduleID")
        if var payload = object["payload"] as? [String: Any], var reschedule = payload["reschedule"] as? [String: Any] {
            reschedule.removeValue(forKey: "scheduleIDs")
            payload["reschedule"] = reschedule
            object["payload"] = payload
        }
        var line = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        line.append(0x0a)
        return line
    }
}
