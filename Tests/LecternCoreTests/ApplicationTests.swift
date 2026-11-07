import Foundation
import Testing
@testable import LecternCore

@MainActor @Suite struct ApplicationTests {
    private func setup() async throws -> (LibraryStore, Module, Lecture, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lectern-app-tests-\(UUID())")
        let store = LibraryStore(rootURL: root)
        let module = try await store.createModule(name: "Module")
        let card = Card(front: "Question", back: "Answer", verdict: .good)
        let lecture = try await store.createLecture(Lecture(moduleID: module.id, name: "Lecture", cards: [card]))
        return (store, module, lecture, root)
    }
    @Test func closeBeforeDebouncePersistsFinalTextAndOneRevision() async throws {
        let (store, module, lecture, root) = try await setup(); defer { try? FileManager.default.removeItem(at: root) }
        let session = LectureSession(lecture: lecture, store: store, runner: JobRunner(store: store, providers: []))
        let card = lecture.cards[0]
        for value in ["N", "Ne", "New answer"] { session.stageCardEdit(cardID: card.id, front: card.front, back: value, sourcePages: []) }
        try await session.closeAndFlush()
        let saved = try await store.loadLecture(moduleID: module.id, lectureID: lecture.id)
        #expect(saved.cards[0].back == "New answer"); #expect(saved.cards[0].history.count == 2)
        #expect(saved.cards[0].verdict == .unreviewed); #expect(session.isClosed)
    }
    @Test func droppedSessionIsRetainedUntilScheduledSaveCompletes() async throws {
        let (store, module, lecture, root) = try await setup(); defer { try? FileManager.default.removeItem(at: root) }
        var session: LectureSession? = LectureSession(lecture: lecture, store: store, runner: JobRunner(store: store, providers: []))
        weak var weakSession = session
        session?.stageCardEdit(cardID: lecture.cards[0].id, front: "Persist me", back: "Final", sourcePages: [])
        session = nil
        #expect(weakSession != nil)
        weakSession = nil
        // Bounded polling exercises lifecycle rather than relying on an exact timer firing time.
        var saved: Lecture?
        for _ in 0..<100 {
            saved = try await store.loadLecture(moduleID: module.id, lectureID: lecture.id)
            if saved?.cards[0].front == "Persist me" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(saved?.cards[0].front == "Persist me")
    }
    @Test func rapidActionsSerializeAndUndoPersistsWithoutLosingOtherFields() async throws {
        let (store, module, lecture, root) = try await setup(); defer { try? FileManager.default.removeItem(at: root) }
        let session = LectureSession(lecture: lecture, store: store, runner: JobRunner(store: store, providers: []))
        async let first: Void = session.dispatch(.setFeedback(cardID: lecture.cards[0].id, "Feedback"))
        async let second: Void = session.dispatch(.setVerdict(cardID: lecture.cards[0].id, .needsAdjustment))
        _ = try await (first, second)
        #expect(session.lecture.cards[0].feedback == "Feedback"); #expect(session.lecture.cards[0].verdict == .needsAdjustment)
        try await session.undo()
        let saved = try await store.loadLecture(moduleID: module.id, lectureID: lecture.id)
        // Concurrent actions can acquire the session gate in either order.
        // Undo must revert exactly the last action and preserve the other one.
        #expect((saved.cards[0].feedback == "Feedback" && saved.cards[0].verdict == .good)
            || (saved.cards[0].feedback.isEmpty && saved.cards[0].verdict == .needsAdjustment))
    }
    @Test func failedExportPlacementNeverMarksCardsAndSuccessfulExportMarksCapturedRevision() async throws {
        let (store, module, lecture, root) = try await setup(); defer { try? FileManager.default.removeItem(at: root) }
        let service = LibraryService(store: store, runner: JobRunner(store: store, providers: []))
        let invalid = root.deletingLastPathComponent().appendingPathComponent("missing-\(UUID())/cards.txt")
        await #expect(throws: (any Error).self) { try await service.exportAnki(moduleID: module.id, to: invalid) }
        #expect(try await store.loadLecture(moduleID: module.id, lectureID: lecture.id).cards[0].exported == nil)
        let output = root.deletingLastPathComponent().appendingPathComponent("export-\(UUID()).txt")
        defer { try? FileManager.default.removeItem(at: output) }
        let exported = try await service.exportAnki(moduleID: module.id, to: output)
        #expect(exported.entries.count == 1)
        let saved = try await store.loadLecture(moduleID: module.id, lectureID: lecture.id)
        #expect(saved.cards[0].exported?.revisionID == lecture.cards[0].currentRevisionID)
        #expect(try String(contentsOf: output, encoding: .utf8).contains("#columns:LecternID"))
    }
}
