import Foundation
import CoreGraphics
import Testing
@testable import LecternCore

private func encodeGeneration<T: Encodable>(_ value: T) throws -> String {
    String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
}

private actor PausedGenerationProvider: AIProvider {
    nonisolated let backend = AIBackend.claudeCLI
    private var requestWaiter: CheckedContinuation<AIRequest, Never>?
    private var responseWaiter: CheckedContinuation<AIResponse, Never>?
    private var requested: AIRequest?
    private var pendingResponse: AIResponse?

    func execute(_ request: AIRequest, onEvent: @escaping @Sendable (AIEvent) -> Void) async throws -> AIResponse {
        requested = request
        requestWaiter?.resume(returning: request)
        requestWaiter = nil
        return await withCheckedContinuation { continuation in
            if let pendingResponse {
                self.pendingResponse = nil
                continuation.resume(returning: pendingResponse)
            } else {
                responseWaiter = continuation
            }
        }
    }

    func nextRequest() async -> AIRequest {
        if let requested { return requested }
        return await withCheckedContinuation { requestWaiter = $0 }
    }

    func respond(_ response: AIResponse) {
        if let responseWaiter {
            self.responseWaiter = nil
            responseWaiter.resume(returning: response)
        } else {
            pendingResponse = response
        }
    }
}

@Suite struct LearningPointGenerationRegressionTests {
    private func fixture(pageCount: Int = 1, cards: [Card] = [], learningPoints: [LearningPoint] = []) async throws -> (LibraryStore, Module, Lecture, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lectern-generation-regression-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.pdf")
        var box = CGRect(x: 0, y: 0, width: 400, height: 300)
        let context = try #require(CGContext(source as CFURL, mediaBox: &box, nil))
        for _ in 0..<pageCount { context.beginPDFPage(nil); context.endPDFPage() }
        context.closePDF()
        let store = LibraryStore(rootURL: root.appendingPathComponent("library"))
        let module = try await store.createModule(name: "Generation regression")
        var lecture = Lecture(moduleID: module.id, name: "Generation regression", pageCount: pageCount, cards: cards)
        lecture.learningPoints = learningPoints
        lecture = try await store.createLecture(lecture, sourceURL: source)
        return (store, module, lecture, root)
    }

    @Test func duplicateExplicitPointIDProducesOnlyOneLinkedCard() async throws {
        var point = LearningPoint(text: "Variance is a mean squared deviation.", pages: [1])
        point.draft = LearningPointDraft(front: "What is variance?", back: "The mean squared deviation.")
        let (store, module, lecture, root) = try await fixture(learningPoints: [point])
        defer { try? FileManager.default.removeItem(at: root) }
        let response = AIResponse(content: try encodeGeneration(GeneratedCards(cards: [
            WireCard(front: "What is variance?", back: "The mean squared deviation.", sourceSlides: [1], point: point.id.uuidString),
            WireCard(front: "Variance?", back: "Another copy.", sourceSlides: [1], point: point.id.uuidString)
        ])))
        let runner = JobRunner(store: store, providers: [FakeAIProvider(responses: [response])])

        _ = try await runner.generate(moduleID: module.id, lectureID: lecture.id, createNewSet: true)
        await runner.waitUntilIdle()

        let saved = try await store.loadLecture(moduleID: module.id, lectureID: lecture.id)
        #expect(saved.cards.count == 1)
        #expect(saved.cards[0].learningPointID == point.id)
        #expect(saved.learningPoints[0].cardIDs == [saved.cards[0].id])
    }

    @Test func exactAndNormalizedNullLabelsDoNotDuplicateFallbackDraft() async throws {
        var point = LearningPoint(text: "A tested concept.", pages: [1])
        point.draft = LearningPointDraft(front: "What is variance?", back: "Mean squared deviation.")
        let (store, module, lecture, root) = try await fixture(learningPoints: [point])
        defer { try? FileManager.default.removeItem(at: root) }
        let response = AIResponse(content: try encodeGeneration(GeneratedCards(cards: [
            WireCard(front: "What is variance?", back: "Mean squared deviation.", sourceSlides: [1]),
            WireCard(front: "  WHAT   IS variance?  ", back: "mean squared deviation.", sourceSlides: [1]),
            WireCard(front: "A distinct slide question?", back: "Its answer.", sourceSlides: [1]),
            WireCard(front: "a DISTINCT slide question?", back: "  its answer. ", sourceSlides: [1])
        ])))
        let runner = JobRunner(store: store, providers: [FakeAIProvider(responses: [response])])

        _ = try await runner.generate(moduleID: module.id, lectureID: lecture.id, createNewSet: true)
        await runner.waitUntilIdle()

        let saved = try await store.loadLecture(moduleID: module.id, lectureID: lecture.id)
        #expect(saved.cards.count == 2)
        #expect(saved.cards.filter { $0.learningPointID == point.id }.count == 1)
        #expect(saved.cards.filter { $0.learningPointID == nil }.count == 1)
    }

    @Test func splitDescendantsStayInTheirSetAndCanGuideASecondSet() async throws {
        var point = LearningPoint(text: "A concept from chat.", pages: [1], reviewed: true)
        point.draft = LearningPointDraft(front: "Original?", back: "Original answer.")
        var parent = Card(sourcePages: [1], front: "Current parent?", back: "Current parent answer.",
                          origin: .generated(jobID: UUID()), allowedSourcePages: [1])
        parent.learningPointID = point.id
        point.cardIDs = [parent.id]
        var proposal = Proposal(jobID: UUID(), baseRevisionID: parent.currentRevisionID!, rationale: "Split concept",
                                allowedSourcePages: [1])
        proposal.cards = [CardDraft(front: "Descendant A?", back: "Answer A.", sourcePages: [1]),
                          CardDraft(front: "Descendant B?", back: "Answer B.", sourcePages: [1])]
        parent.proposal = proposal
        var lecture = Lecture(moduleID: UUID(), name: "Split", pageCount: 1, cards: [parent])
        lecture.learningPoints = [point]

        try LectureReducer.reduce(&lecture, action: .acceptProposal(cardID: parent.id, approve: false))

        let children = lecture.cards.filter { !$0.isSuperseded }
        #expect(children.count == 2)
        #expect(children.allSatisfy { $0.learningPointID == point.id })
        #expect(children.allSatisfy { lecture.cardGenerationIDs[$0.id] == lecture.cardGenerationIDs[parent.id] })
        #expect(lecture.learningPoints[0].cardIDs == children.map(\.id))
        let drafts = PromptBuilder.chatCardDrafts(lecture: lecture, pages: [1], includeLinkedDrafts: true)
        #expect(drafts.map(\.point) == [point.id, point.id])
        #expect(Set(drafts.map(\.wirePointID)) == Set(children.map(\.id)))
        #expect(Set(drafts.map(\.front)) == Set(["Descendant A?", "Descendant B?"]))

        let (store, module, storedLecture, root) = try await fixture(cards: lecture.cards, learningPoints: lecture.learningPoints)
        defer { try? FileManager.default.removeItem(at: root) }
        let childA = try #require(children.first { $0.front == "Descendant A?" })
        let output = AIResponse(content: try encodeGeneration(GeneratedCards(cards: [
            WireCard(front: "Alternative A?", back: childA.back, sourceSlides: [1], point: childA.id.uuidString)
        ])))
        let runner = JobRunner(store: store, providers: [FakeAIProvider(responses: [output])])

        let newID = try await runner.generate(moduleID: module.id, lectureID: storedLecture.id, createNewSet: true)
        await runner.waitUntilIdle()

        let saved = try await store.loadLecture(moduleID: module.id, lectureID: storedLecture.id)
        #expect(Array(saved.cards.prefix(lecture.cards.count)).map(\.id) == lecture.cards.map(\.id))
        #expect(Set(saved.learningPoints[0].cardIDs ?? []).count == 3)
        #expect(saved.cards.allSatisfy { $0.learningPointID == point.id })
        #expect(saved.cards.filter { saved.cardGenerationIDs[$0.id] == newID }.map(\.front) == ["Alternative A?"])
    }

    @Test func generationWithNoCardsKeepsPendingEditSuggestions() throws {
        let card = Card(sourcePages: [1], front: "Old?", back: "Old answer.")
        let job = Job(kind: .generate, pages: [1])
        var lecture = Lecture(moduleID: UUID(), name: "Suggestion", pageCount: 1, cards: [card], jobs: [job])
        var message = ChatMessage(role: .assistant, text: "A suggestion")
        message.suggestion = CardSuggestion(reason: "Clarified", cardID: card.id,
            baseRevisionID: card.currentRevisionID, front: "New?", back: "New answer.", sourcePages: [1])
        lecture.currentChat.messages = [message]

        try LectureReducer.reduce(&lecture, action: .landGeneration(jobID: job.id, cards: [], skipped: [], usage: nil))

        #expect(lecture.cards == [card])
        #expect(lecture.currentChat.messages[0].suggestion?.state == .pending)
        try LectureReducer.reduce(&lecture, action: .resolveCardSuggestion(chatID: lecture.currentChat.id,
            messageID: message.id, apply: true))
        #expect(lecture.cards.first?.front == "New?")
    }

    @Test func inFlightGenerationDoesNotConsumeAChangedDraft() async throws {
        var point = LearningPoint(text: "A changing concept.", pages: [1])
        point.draft = LearningPointDraft(front: "Old draft?", back: "Old answer.")
        let (store, module, lecture, root) = try await fixture(learningPoints: [point])
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = PausedGenerationProvider()
        let runner = JobRunner(store: store, providers: [provider])

        _ = try await runner.generate(moduleID: module.id, lectureID: lecture.id, createNewSet: true)
        let request = await provider.nextRequest()
        #expect(request.prompt.contains("Old draft?"))
        _ = try await store.updateLecture(moduleID: module.id, lectureID: lecture.id) { current in
            current.learningPoints[0].draft = LearningPointDraft(front: "New draft?", back: "New answer.")
        }
        await provider.respond(AIResponse(content: try encodeGeneration(GeneratedCards(cards: [
            WireCard(front: "Old draft?", back: "Old answer.", sourceSlides: [1], point: point.id.uuidString)
        ]))))
        await runner.waitUntilIdle()

        let saved = try await store.loadLecture(moduleID: module.id, lectureID: lecture.id)
        #expect(saved.cards.isEmpty)
        #expect(saved.learningPoints[0].draft?.front == "New draft?")
        #expect(saved.learningPoints[0].isPendingDraft)
        #expect(saved.learningPoints[0].cardIDs == nil)
    }

    @Test func inFlightGenerationPreservesLatestEditedLinkedDescendant() async throws {
        var point = LearningPoint(text: "A linked concept.", pages: [1], reviewed: true)
        point.draft = LearningPointDraft(front: "Original card?", back: "Original answer.")
        var linkedCard = Card(sourcePages: [1], front: "Original card?", back: "Original answer.",
                              origin: .generated(jobID: UUID()), allowedSourcePages: [1])
        linkedCard.learningPointID = point.id
        point.cardIDs = [linkedCard.id]
        let card = linkedCard
        let (store, module, lecture, root) = try await fixture(cards: [card], learningPoints: [point])
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = PausedGenerationProvider()
        let runner = JobRunner(store: store, providers: [provider])

        _ = try await runner.generate(moduleID: module.id, lectureID: lecture.id, createNewSet: true)
        let request = await provider.nextRequest()
        #expect(request.prompt.contains("Original card?"))
        _ = try await store.updateLecture(moduleID: module.id, lectureID: lecture.id) { current in
            try LectureReducer.reduce(&current, action: .commitEdit(cardID: card.id,
                front: "Latest card?", back: "Latest answer.", sourcePages: [1]))
        }
        await provider.respond(AIResponse(content: try encodeGeneration(GeneratedCards(cards: [
            WireCard(front: "Original card?", back: "Original answer.", sourceSlides: [1], point: card.id.uuidString)
        ]))))
        await runner.waitUntilIdle()

        let saved = try await store.loadLecture(moduleID: module.id, lectureID: lecture.id)
        #expect(saved.cards.count == 1)
        #expect(saved.cards[0].id == card.id)
        #expect(saved.cards[0].front == "Latest card?")
        #expect(saved.cards[0].back == "Latest answer.")
        #expect(saved.cards[0].learningPointID == point.id)
        #expect(saved.learningPoints[0].cardIDs == [saved.cards[0].id])
    }

    @Test func inFlightGenerationPreservesLatestLinkedSourcePages() async throws {
        var point = LearningPoint(text: "A linked concept.", pages: [1, 2], reviewed: true)
        point.draft = LearningPointDraft(front: "Original card?", back: "Original answer.")
        var linkedCard = Card(sourcePages: [1], front: "Original card?", back: "Original answer.",
                              origin: .generated(jobID: UUID()), allowedSourcePages: [1, 2])
        linkedCard.learningPointID = point.id
        point.cardIDs = [linkedCard.id]
        let card = linkedCard
        let (store, module, lecture, root) = try await fixture(pageCount: 2, cards: [card], learningPoints: [point])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(PromptBuilder.chatCardDrafts(lecture: lecture, pages: [1, 2], includeLinkedDrafts: true).first?.pages == [1])
        let provider = PausedGenerationProvider()
        let runner = JobRunner(store: store, providers: [provider])

        _ = try await runner.generate(moduleID: module.id, lectureID: lecture.id, createNewSet: true)
        let request = await provider.nextRequest()
        #expect(request.prompt.contains("Original card?"))
        _ = try await store.updateLecture(moduleID: module.id, lectureID: lecture.id) { current in
            try LectureReducer.reduce(&current, action: .commitEdit(cardID: card.id,
                front: "Original card?", back: "Original answer.", sourcePages: [2]))
        }
        await provider.respond(AIResponse(content: try encodeGeneration(GeneratedCards(cards: [
            WireCard(front: "Original card?", back: "Original answer.", sourceSlides: [1], point: card.id.uuidString)
        ]))))
        await runner.waitUntilIdle()

        let saved = try await store.loadLecture(moduleID: module.id, lectureID: lecture.id)
        #expect(saved.cards.count == 1)
        #expect(saved.cards[0].id == card.id)
        #expect(saved.cards[0].sourcePages == [2])
        #expect(saved.cards[0].learningPointID == point.id)
        #expect(saved.learningPoints[0].cardIDs == [saved.cards[0].id])
    }
}
