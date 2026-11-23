import Foundation
import Testing
@testable import LecternCore

struct StudySchedulerTests {
    private struct ReferenceFixtures: Decodable {
        struct Sequence: Decodable {
            struct Review: Decodable {
                let minute: Double
                let grade: StudyRating
                let stability: Double
                let difficulty: Double
                let state: StudyMemoryState.Phase
                let dueSeconds: Double
            }

            let name: String
            let reviews: [Review]
        }

        let startUnixSeconds: Double
        let sequences: [Sequence]
    }

    @Test func matchesPinnedPythonReference() throws {
        let url = try #require(Bundle.module.url(
            forResource: "fsrs-6-parity", withExtension: "json", subdirectory: "Fixtures"
        ))
        let fixtures = try JSONDecoder().decode(ReferenceFixtures.self, from: Data(contentsOf: url))
        let start = Date(timeIntervalSince1970: fixtures.startUnixSeconds)
        for sequence in fixtures.sequences {
            var previous: StudyMemoryState?
            for (index, expected) in sequence.reviews.enumerated() {
                let time = start.addingTimeInterval(expected.minute * 60)
                let actual = try StudyScheduler.review(previous, rating: expected.grade, at: time)
                #expect(abs(actual.stability - expected.stability) < 1e-9, "\(sequence.name) [\(index)] stability")
                #expect(abs(actual.difficulty - expected.difficulty) < 1e-9, "\(sequence.name) [\(index)] difficulty")
                #expect(actual.due == start.addingTimeInterval(expected.dueSeconds), "\(sequence.name) [\(index)] due")
                #expect(actual.phase == expected.state, "\(sequence.name) [\(index)] phase")
                #expect(actual.lastReview == time)
                #expect(actual.reps == index + 1)
                previous = actual
            }
        }
    }

    @Test func sessionRetryKeepsLapseAndDemotionUsesTheSameTransition() throws {
        let start = Date(timeIntervalSince1970: 1_767_311_880)
        let first = try StudyScheduler.review(nil, rating: .good, at: start)
        let miss = try StudyScheduler.demote(first, at: first.due)
        #expect(miss == (try StudyScheduler.review(first, rating: .again, at: first.due)))
        #expect(miss.phase == .relearning)
        #expect(miss.lapses == 1)
        let retry = first.due.addingTimeInterval(30)
        let missedAgain = try StudyScheduler.review(miss, rating: .again, at: retry)
        let passed = try StudyScheduler.review(missedAgain, rating: .good, at: retry.addingTimeInterval(30))
        #expect(missedAgain.lapses == 1)
        #expect(passed.lapses == 1)
        #expect(passed.reps == 4)
        #expect(passed.phase == .review)
        #expect(throws: StudyScheduleError.reviewBeforeLastReview) {
            try StudyScheduler.review(passed, rating: .good, at: start)
        }
    }

    @Test func queueUsesModuleEligibilityDueDatesSiblingSpacingAndSharedBudget() throws {
        let module = Module(name: "Accounting")
        let now = Date(timeIntervalSince1970: 1_767_311_880)
        let parent = UUID()
        let sibling1 = Card(front: "Sibling 1", back: "A", verdict: .good, origin: .splitFrom(cardID: parent))
        let sibling2 = Card(front: "Sibling 2", back: "A", verdict: .good, origin: .splitFrom(cardID: parent))
        let other = Card(front: "Other lecture", back: "A", verdict: .good)
        let new = Card(front: "New", back: "A", verdict: .good)
        let extraNew = Card(front: "Extra new", back: "A", verdict: .good)
        let future = Card(front: "Later", back: "A", verdict: .good)
        let unreviewed = Card(front: "Unreviewed", back: "A")
        let superseded = Card(front: "Replaced", back: "A", verdict: .good, supersededBy: [new.id])
        var archived = Lecture(moduleID: module.id, name: "Archived", cards: [extraNew])
        archived.archivedAt = now
        let lectures = [
            archived,
            Lecture(moduleID: module.id, name: "One", cards: [sibling1, sibling2, new, unreviewed, superseded]),
            Lecture(moduleID: module.id, name: "Two", cards: [other, extraNew, future])
        ]
        let memory = try [
            sibling1.id: StudyScheduler.review(nil, rating: .good, at: now.addingTimeInterval(-300_000)),
            sibling2.id: StudyScheduler.review(nil, rating: .good, at: now.addingTimeInterval(-250_000)),
            other.id: StudyScheduler.review(nil, rating: .good, at: now.addingTimeInterval(-200_000)),
            future.id: StudyScheduler.review(nil, rating: .good, at: now)
        ]
        let queue = StudyQueue.build(module: module, lectures: lectures, memory: memory, introducedToday: 19, now: now)
        #expect(queue.due == [sibling1.id, other.id, sibling2.id])
        #expect(queue.new == [new.id])
        let capped = StudyQueue.build(module: module, lectures: lectures, memory: memory, introducedToday: 20, now: now)
        #expect(capped.due == queue.due)
        #expect(capped.new.isEmpty)
    }

    @Test func preStudyLibraryOpensWithoutSidecarsOrLectureChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lectern-study-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(rootURL: root)
        let module = try await store.createModule(name: "Legacy")
        let card = Card(front: "Question", back: "Answer", verdict: .good)
        let lecture = try await store.createLecture(Lecture(moduleID: module.id, name: "Imported", cards: [card]))
        let moduleDirectory = store.moduleDirectory(module.id)
        let lectureURL = store.lectureDirectory(module.id, lecture.id).appendingPathComponent("lecture.json")
        let before = try Data(contentsOf: lectureURL)

        let reopened = LibraryStore(rootURL: root)
        let reopenedModule = try await reopened.loadModule(moduleID: module.id)
        let lectures = try await reopened.lectures(in: module.id)
        let queue = StudyQueue.build(module: reopenedModule, lectures: lectures, memory: [:], introducedToday: 0, now: Date())
        #expect(queue.new == [card.id])
        #expect(queue.due.isEmpty)
        #expect(try Data(contentsOf: lectureURL) == before)
        #expect(!FileManager.default.fileExists(atPath: moduleDirectory.appendingPathComponent("study.json").path))
        #expect(!FileManager.default.fileExists(atPath: moduleDirectory.appendingPathComponent("reviews.jsonl").path))
    }

    @Test func studyTimingRepeatsFirstCorrectAndRepeatsAgainAfterALearningMiss() throws {
        let cardID = UUID()
        let now = Date(timeIntervalSince1970: 1_767_311_880)
        var configuration = StudyConfiguration()
        configuration.newRetryMinutes = 2
        configuration.establishedRetryMinutes = 5
        configuration.maximumInterval = .days(1)
        func rate(_ state: StudyMemoryState?, _ rating: StudyRating, _ at: Date) throws -> StudyMemoryState {
            try StudyScheduler.review(state, rating: rating, at: at, configuration: configuration, cardID: cardID)
        }

        let first = try rate(nil, .good, now)
        #expect(first.phase == .learning)
        #expect(first.due == now.addingTimeInterval(600))
        let missedLearning = try rate(first, .again, first.due)
        #expect(missedLearning.due == first.due.addingTimeInterval(120))
        #expect(missedLearning.lapses == 0)
        let retryTime = first.due.addingTimeInterval(30)
        let correctRetry = try rate(missedLearning, .good, retryTime)
        #expect(correctRetry.due == retryTime.addingTimeInterval(600))
        let graduated = try rate(correctRetry, .good, correctRetry.due)
        #expect(graduated.phase == .review)
        #expect(graduated.due == correctRetry.due.addingTimeInterval(86_400))
        let lapse = try rate(graduated, .again, graduated.due)
        #expect(lapse.phase == .relearning)
        #expect(lapse.due == graduated.due.addingTimeInterval(300))
        let relearned = try rate(lapse, .good, graduated.due.addingTimeInterval(45))
        #expect(relearned.phase == .review)
        #expect(relearned.lapses == 1)
    }

    @Test func studyPlanUsesSourceSpacingBeforeSpendingCapsAndKeepsDueCardsForContinuation() throws {
        let now = Date(timeIntervalSince1970: 1_767_311_880)
        let module = Module(name: "One")
        let due = Card(sourcePages: [1], front: "Due", back: "Answer", verdict: .good)
        let sibling = Card(sourcePages: [1], front: "Related", back: "Answer", verdict: .good)
        let separate = Card(sourcePages: [2], front: "Different", back: "Answer", verdict: .good)
        let lecture = Lecture(moduleID: module.id, name: "Example", cards: [due, sibling, separate])
        let state = try StudyScheduler.review(nil, rating: .good, at: now.addingTimeInterval(-300_000))
        var overrides = StudyOverrides()
        overrides.newCardLimit = 1
        let firstDeck = StudyDeck(module: module, lectures: [lecture], memory: [due.id: state],
                                  overrides: overrides, introducedToday: 0)
        let secondModule = Module(name: "Two")
        let another = Card(front: "Another module", back: "Answer", verdict: .good)
        let secondDeck = StudyDeck(module: secondModule, lectures: [
            Lecture(moduleID: secondModule.id, name: "Other", cards: [another])
        ], memory: [:], overrides: .init(), introducedToday: 0)
        var prefs = StudyPreferences()
        prefs.overallNewLimit = 1
        let catalog = StudyCatalog(decks: [firstDeck, secondDeck], preferences: prefs)
        var opts = StudySessionOptions()
        opts.stop = .cards(1)
        let plan = catalog.plan(options: opts, now: now)
        #expect(plan.cards.map(\.id) == [due.id, separate.id])
        #expect(plan.startingCount == 1)
        #expect(plan.dueRemaining == 0)
        opts.cardTypes = .solve
        #expect(catalog.plan(options: opts, now: now).cards.isEmpty)
        #expect(catalog.plan(options: opts, now: now).dueRemaining == 1)
    }
}
