import Foundation
import Testing
@testable import LecternCore

private actor ChatEditGate: AIProvider {
    nonisolated let backend = AIBackend.claudeCLI
    let response: AIResponse
    var started = false
    var released = false
    var calls = 0
    init(_ response: AIResponse) { self.response = response }
    func execute(_ request: AIRequest, onEvent: @escaping @Sendable (AIEvent) -> Void) async throws -> AIResponse {
        started = true
        calls += 1
        while !released { try await Task.sleep(for: .milliseconds(5)) }
        return response
    }
    func release() { released = true }
}

@Suite struct ChatEditingTests {
    private func setup() async throws -> (LibraryStore, Module, Lecture, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lectern-chat-edits-\(UUID())")
        let store = LibraryStore(rootURL: root)
        let module = try await store.createModule(name: "Chat test")
        let cards = [Card(front: "First?", back: "Long first answer", verdict: .good),
                     Card(front: "Second?", back: "Long second answer"),
                     Card(front: "Untouched?", back: "Leave alone")]
        let lecture = try await store.createLecture(Lecture(moduleID: module.id, name: "Cards", cards: cards))
        return (store, module, try await store.loadLecture(moduleID: module.id, lectureID: lecture.id), root)
    }
    private func response(_ edits: [ChatCardEdit], message: String = "Updated the requested cards.") throws -> AIResponse {
        AIResponse(content: String(decoding: try JSONEncoder().encode(ChatReply(message: message, edits: edits)), as: UTF8.self))
    }
    private func edit(_ card: Card, back: String) -> ChatCardEdit {
        ChatCardEdit(cardID: card.id, baseRevisionID: card.currentRevisionID!, front: card.front, back: back)
    }

    @Test func appliesBatchInPlaceAndPersistsUndoWithoutReplacingOtherCards() async throws {
        let (store, module, before, root) = try await setup()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = FakeAIProvider(responses: [try response([edit(before.cards[0], back: "First"), edit(before.cards[1], back: "Second")])])
        let runner = JobRunner(store: store, providers: [provider])
        let id = try await runner.chat(moduleID: module.id, lectureID: before.id, anchorPage: 0,
            context: .none, question: "Shorten the first two answers", flashcardContext: .all)
        await runner.waitUntilIdle()
        let after = try await store.loadLecture(moduleID: module.id, lectureID: before.id)
        #expect(after.cards.map(\.id) == before.cards.map(\.id))
        #expect(after.cards.map(\.back) == ["First", "Second", "Leave alone"])
        #expect(after.cards[0].verdict == .unreviewed)
        #expect(after.cards[0].history.last?.author == .ai)
        #expect(after.cards[2] == before.cards[2])
        #expect(after.threads[0].messages.last?.editJobID == id)
        #expect(after.canUndoChatEdits(jobID: id))
        var controller = LectureController(lecture: before)
        try controller.receive(after)
        let undone = try await store.updateLecture(moduleID: module.id, lectureID: before.id) {
            try LectureReducer.reduce(&$0, action: .undoChatEdits(jobID: id))
        }
        #expect(undone.cards.map(\.back) == before.cards.map(\.back))
        #expect(undone.cards[0].verdict == .good)
        #expect(undone.cards[0].history.count == 3)
        #expect(!undone.canUndoChatEdits(jobID: id))
        #expect(undone.jobs.last?.chatEditsUndoneAt != nil)
    }

    @Test func ordinaryQuestionDoesNotChangeCards() async throws {
        let (store, module, before, root) = try await setup()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = FakeAIProvider(responses: [try response([], message: "Here is the explanation.")])
        let runner = JobRunner(store: store, providers: [provider])
        _ = try await runner.chat(moduleID: module.id, lectureID: before.id, anchorPage: 0,
            context: .none, question: "Explain the first card", flashcardContext: .all)
        await runner.waitUntilIdle()
        let after = try await store.loadLecture(moduleID: module.id, lectureID: before.id)
        #expect(after.cards == before.cards)
        #expect(after.threads[0].messages.last?.text == "Here is the explanation.")
        #expect(after.threads[0].messages.last?.editJobID == nil)
        #expect(after.jobs.last?.state == .succeeded)
    }

    @Test(arguments: ["scope", "revision", "empty", "duplicate", "noCards"])
    func invalidBatchNeverPartiallyEditsCards(failure: String) async throws {
        let (store, module, before, root) = try await setup()
        defer { try? FileManager.default.removeItem(at: root) }
        let good = edit(before.cards[0], back: "Should not land")
        var bad = edit(before.cards[1], back: "Invalid second edit")
        if failure == "revision" { bad.baseRevisionID = UUID() }
        if failure == "empty" { bad.back = "  " }
        let edits = failure == "duplicate" ? [good, good] : [good, bad]
        let provider = FakeAIProvider(responses: [try response(edits)])
        let runner = JobRunner(store: store, providers: [provider])
        let context: FlashcardContext = failure == "scope" ? .current : failure == "noCards" ? .none : .all
        _ = try await runner.chat(moduleID: module.id, lectureID: before.id, anchorPage: 0,
            context: .none, question: "Change these answers", cardID: before.cards[0].id, flashcardContext: context)
        await runner.waitUntilIdle()
        let after = try await store.loadLecture(moduleID: module.id, lectureID: before.id)
        #expect(after.cards == before.cards)
        #expect(after.jobs.last?.state == .failed)
        #expect(after.threads[0].messages.count == 1) // No success reply is saved for a rejected edit.
    }

    @Test func concurrentManualChangeRejectsWholeChatBatch() async throws {
        let (store, module, before, root) = try await setup()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = ChatEditGate(try response([edit(before.cards[0], back: "AI first"), edit(before.cards[1], back: "AI second")]))
        let runner = JobRunner(store: store, providers: [provider])
        _ = try await runner.chat(moduleID: module.id, lectureID: before.id, anchorPage: 0,
            context: .none, question: "Rewrite both", flashcardContext: .all)
        for _ in 0..<100 { if await provider.started { break }; try await Task.sleep(for: .milliseconds(5)) }
        #expect(await provider.started)
        _ = try await store.updateLecture(moduleID: module.id, lectureID: before.id) {
            try LectureReducer.reduce(&$0, action: .commitEdit(cardID: before.cards[1].id,
                front: before.cards[1].front, back: "My newer answer", sourcePages: []))
        }
        await provider.release()
        await runner.waitUntilIdle()
        let after = try await store.loadLecture(moduleID: module.id, lectureID: before.id)
        #expect(after.cards[0] == before.cards[0])
        #expect(after.cards[1].back == "My newer answer")
        #expect(after.jobs.last?.state == .failed)
    }

    @Test(arguments: ["text", "verdict", "math"])
    func undoNeverOverwritesALaterManualEdit(change: String) async throws {
        let (store, module, before, root) = try await setup()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = FakeAIProvider(responses: [try response([edit(before.cards[0], back: "AI answer")])])
        let runner = JobRunner(store: store, providers: [provider])
        let id = try await runner.chat(moduleID: module.id, lectureID: before.id, anchorPage: 0,
            context: .none, question: "Rewrite this", cardID: before.cards[0].id, flashcardContext: .current)
        await runner.waitUntilIdle()
        _ = try await store.updateLecture(moduleID: module.id, lectureID: before.id) {
            let action: LectureAction = switch change {
            case "verdict": .setVerdict(cardID: before.cards[0].id, .needsAdjustment)
            case "math": .setMathInterpretation(cardID: before.cards[0].id, span: "$test$", .keepAsText)
            default: .commitEdit(cardID: before.cards[0].id, front: before.cards[0].front, back: "Manual answer", sourcePages: [])
            }
            try LectureReducer.reduce(&$0, action: action)
        }
        let edited = try await store.loadLecture(moduleID: module.id, lectureID: before.id)
        #expect(!edited.canUndoChatEdits(jobID: id))
        await #expect(throws: LectureError.self) {
            _ = try await store.updateLecture(moduleID: module.id, lectureID: before.id) {
                try LectureReducer.reduce(&$0, action: .undoChatEdits(jobID: id))
            }
        }
        #expect(try await store.loadLecture(moduleID: module.id, lectureID: before.id).cards == edited.cards)
    }

    @Test(arguments: ["verdict", "math"])
    func concurrentMetadataChangeRejectsChatAndStaleRetryWithoutAnotherProviderCall(change: String) async throws {
        let (store, module, before, root) = try await setup()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = ChatEditGate(try response([edit(before.cards[0], back: "AI answer")]))
        let runner = JobRunner(store: store, providers: [provider])
        let id = try await runner.chat(moduleID: module.id, lectureID: before.id, anchorPage: 0,
            context: .none, question: "Rewrite this", cardID: before.cards[0].id, flashcardContext: .current)
        for _ in 0..<100 { if await provider.started { break }; try await Task.sleep(for: .milliseconds(5)) }
        #expect(await provider.started)
        _ = try await store.updateLecture(moduleID: module.id, lectureID: before.id) {
            let action: LectureAction = change == "verdict"
                ? .setVerdict(cardID: before.cards[0].id, .needsAdjustment)
                : .setMathInterpretation(cardID: before.cards[0].id, span: "$test$", .keepAsText)
            try LectureReducer.reduce(&$0, action: action)
        }
        let expected = try await store.loadLecture(moduleID: module.id, lectureID: before.id)
        await provider.release()
        await runner.waitUntilIdle()
        let failed = try await store.loadLecture(moduleID: module.id, lectureID: before.id)
        #expect(failed.cards == expected.cards)
        #expect(failed.jobs.last?.state == .failed)
        #expect(failed.jobs.last?.error?.contains("changed while chat was working") == true)
        await #expect(throws: AIError.self) { try await runner.retry(moduleID: module.id, lectureID: before.id, jobID: id) }
        #expect(await provider.calls == 1)
    }
}
