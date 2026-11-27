import Foundation
import CoreGraphics
import Testing
@testable import LecternCore

/// Answers each request with a closure, so a fixture can quote the real message IDs it was sent.
actor ScriptedProvider: AIProvider {
    nonisolated let backend = AIBackend.claudeCLI
    private let script: @Sendable (AIRequest) async throws -> AIResponse
    private(set) var requests: [AIRequest] = []
    init(_ script: @escaping @Sendable (AIRequest) async throws -> AIResponse) { self.script = script }
    func execute(_ request: AIRequest, onEvent: @escaping @Sendable (AIEvent) -> Void) async throws -> AIResponse {
        requests.append(request)
        return try await script(request)
    }
}

private func encode<T: Encodable>(_ value: T) throws -> String { String(decoding: try JSONEncoder().encode(value), as: UTF8.self) }

@Suite struct ChatDistillationTests {
    private func fixture(pages: Int = 2, cards: [Card] = []) async throws -> (LibraryStore, Module, Lecture, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lectern-distil-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.pdf")
        var box = CGRect(x: 0, y: 0, width: 400, height: 300)
        let context = try #require(CGContext(source as CFURL, mediaBox: &box, nil))
        for _ in 0..<pages { context.beginPDFPage(nil); context.endPDFPage() }
        context.closePDF()
        let store = LibraryStore(rootURL: root.appendingPathComponent("library"))
        let module = try await store.createModule(name: "Distil")
        let lecture = try await store.createLecture(Lecture(moduleID: module.id, name: "Distil", pageCount: pages, cards: cards), sourceURL: source)
        return (store, module, lecture, root)
    }

    @Test func pointsWaitUntilTheStudentReactsAndKeepOnlyVerifiedOnes() async throws {
        let (store, module, lecture, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = ScriptedProvider { request in
            if request.kind == .chat { return chatAnswerStatic() }
            let saved = try await store.loadLecture(moduleID: module.id, lectureID: lecture.id)
            let messages = saved.currentChat.messages
            // First pass: one exchange only, the discussion is still open.
            guard messages.count >= 4 else { return AIResponse(content: try encode(ChatDistillation(summary: "", closedThroughMessageID: nil, learningPoints: []))) }
            let restatement = messages[2], confirmation = messages[3]
            let good = ChatDistillation.Point(text: "Variance is the average squared distance from the mean.", pages: [1], kind: "ownWords",
                evidence: [.init(messageID: restatement.id.uuidString, quote: "So the variance is the squared deviations on average")],
                front: "What is variance?", back: "The average squared deviation from the mean.", endMessageID: confirmation.id.uuidString)
            var invented = good; invented.text = "An invented insight"; invented.evidence = [.init(messageID: restatement.id.uuidString, quote: "I never said this")]
            var long = good; long.text = Array(repeating: "word", count: 31).joined(separator: " ")
            var otherSlide = good; otherSlide.text = "Unread slide"; otherSlide.pages = [2]
            return AIResponse(content: try encode(ChatDistillation(summary: "", closedThroughMessageID: confirmation.id.uuidString, learningPoints: [good, invented, long, otherSlide])))
        }
        let runner = JobRunner(store: store, providers: [provider])
        _ = try await runner.chat(moduleID: module.id, lectureID: lecture.id, question: "I don't get variance", contextRefs: [.slide(1)])
        await runner.waitUntilIdle()
        var saved = try await store.loadLecture(moduleID: module.id, lectureID: lecture.id)
        #expect(saved.learningPoints.isEmpty)
        #expect(saved.currentChat.pointCursor == 0)

        _ = try await runner.chat(moduleID: module.id, lectureID: lecture.id, question: "So the variance is the squared deviations on average?", contextRefs: [.slide(1)])
        await runner.waitUntilIdle()
        saved = try await store.loadLecture(moduleID: module.id, lectureID: lecture.id)
        #expect(saved.learningPoints.map(\.text) == ["Variance is the average squared distance from the mean."])
        let point = try #require(saved.learningPoints.first)
        #expect(point.kind == .ownWords); #expect(point.isPendingDraft); #expect(point.draft?.front == "What is variance?")
        #expect(point.episodeEndMessageID == saved.currentChat.messages[3].id)
        #expect(saved.currentChat.pointCursor == 4)
        let prompt = try #require(await provider.requests.last?.prompt)
        #expect(prompt.contains("Zero points is the default"))
        #expect(await provider.requests.last?.outputSchemaOverride == AIOutputSchema.chatDistillation)
    }

    @Test func reviewChatNeverMakesPointsButSuggestsACardAfterTheExplanationLanded() async throws {
        let card = Card(sourcePages: [1], front: "When is payment in default?", back: "When it is late.")
        let (store, module, lecture, root) = try await fixture(cards: [card])
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = ScriptedProvider { request in
            if request.kind == .chat { return AIResponse(content: #"{"message":"Due means owed now; default means late and the legal conditions are met.","edits":[],"newCards":[]}"#) }
            #expect(request.outputSchemaOverride == AIOutputSchema.reviewDistillation)
            #expect(request.prompt.contains("DISCUSSED CARDS"))
            let saved = try await store.loadLecture(moduleID: module.id, lectureID: lecture.id)
            let current = try #require(saved.cards.first)
            let suggestion = ReviewDistillation.Suggestion(reason: "The due/default difference made this click.", cardID: current.id.uuidString,
                baseRevisionID: current.currentRevisionID?.uuidString, front: "What is the difference between due and in default?", back: "Due: owed now. Default: late, and the legal conditions are met.", sourceSlides: [1])
            return AIResponse(content: try encode(ReviewDistillation(summary: "", suggestion: suggestion)))
        }
        let runner = JobRunner(store: store, providers: [provider])
        // A single question can't show a reaction yet: no background pass.
        _ = try await runner.chat(moduleID: module.id, lectureID: lecture.id, question: "What is payment default?", contextRefs: [.card(card.id), .slide(1)], allowsCardCreation: true)
        await runner.waitUntilIdle()
        #expect(await provider.requests.map(\.kind) == [.chat])
        _ = try await runner.chat(moduleID: module.id, lectureID: lecture.id, question: "Okay so due is owed now and default is late, got it", contextRefs: [.card(card.id), .slide(1)], allowsCardCreation: true)
        await runner.waitUntilIdle()
        var saved = try await store.loadLecture(moduleID: module.id, lectureID: lecture.id)
        #expect(saved.learningPoints.isEmpty)
        let message = try #require(saved.currentChat.messages.last)
        let suggestion = try #require(message.suggestion)
        #expect(suggestion.isEdit); #expect(suggestion.state == .pending)
        #expect(saved.cards.first?.front == card.front)

        try LectureReducer.reduce(&saved, action: .resolveCardSuggestion(chatID: saved.currentChat.id, messageID: message.id, apply: true))
        #expect(saved.cards.first?.front == "What is the difference between due and in default?")
        #expect(saved.cards.first?.verdict == .unreviewed)
        #expect(saved.currentChat.messages.last?.suggestion?.state == .applied)
        #expect(throws: (any Error).self) { try LectureReducer.reduce(&saved, action: .resolveCardSuggestion(chatID: saved.currentChat.id, messageID: message.id, apply: true)) }
    }

    @Test func clickingAnAnswerEndsItsDiscussion() async throws {
        let (store, module, lecture, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = ScriptedProvider { request in
            if request.kind == .chat { return chatAnswerStatic() }
            let saved = try await store.loadLecture(moduleID: module.id, lectureID: lecture.id)
            let messages = saved.currentChat.messages
            guard let answer = messages.last, answer.clicked else { return AIResponse(content: try encode(ChatDistillation(summary: "", learningPoints: []))) }
            #expect(request.prompt.contains("marked answer \(answer.id.uuidString) as clicked"))
            let point = ChatDistillation.Point(text: "Variance averages squared deviations.", pages: [1], kind: "understood",
                evidence: [.init(messageID: answer.id.uuidString, quote: "average squared deviation")], front: "Q", back: "A", endMessageID: answer.id.uuidString)
            return AIResponse(content: try encode(ChatDistillation(summary: "", closedThroughMessageID: answer.id.uuidString, learningPoints: [point])))
        }
        let runner = JobRunner(store: store, providers: [provider])
        _ = try await runner.chat(moduleID: module.id, lectureID: lecture.id, question: "What is variance?", contextRefs: [.slide(1)])
        await runner.waitUntilIdle()
        let answer = try #require(try await store.loadLecture(moduleID: module.id, lectureID: lecture.id).currentChat.messages.last)
        try await runner.setChatAnswerClicked(moduleID: module.id, lectureID: lecture.id, messageID: answer.id, clicked: true)
        await runner.waitUntilIdle()
        let saved = try await store.loadLecture(moduleID: module.id, lectureID: lecture.id)
        #expect(saved.currentChat.messages.last?.clicked == true)
        #expect(saved.learningPoints.map(\.text) == ["Variance averages squared deviations."])
    }

    @Test func draftsBecomeCardsAndGenerateKeepsThem() throws {
        let existing = Card(sourcePages: [1], front: "Old?", back: "Old.", origin: .generated(jobID: UUID()), allowedSourcePages: [1])
        var lecture = Lecture(moduleID: UUID(), name: "L", pageCount: 2, cards: [existing])
        var add = LearningPoint(text: "New insight", pages: [1]); add.draft = LearningPointDraft(front: "New?", back: "New.")
        var improve = LearningPoint(text: "Better", pages: [1]); improve.draft = LearningPointDraft(front: "Better?", back: "Better.", replacesCardID: existing.id)
        var waiting = LearningPoint(text: "Waiting", pages: [2]); waiting.draft = LearningPointDraft(front: "Waiting?", back: "Waiting.")
        lecture.learningPoints = [add, improve, waiting]

        try LectureReducer.reduce(&lecture, action: .acceptLearningPointDraft(pointID: add.id, front: "New?", back: "New."))
        try LectureReducer.reduce(&lecture, action: .acceptLearningPointDraft(pointID: improve.id, front: "Better?", back: "Better."))
        #expect(lecture.cards.count == 2)
        let added = try #require(lecture.cards.last)
        #expect(added.learningPointID == add.id); #expect(lecture.learningPoints[0].cardIDs == [added.id]); #expect(!lecture.learningPoints[0].isPendingDraft)
        #expect(lecture.cards[0].front == "Better?"); #expect(lecture.cards[0].history.count == 2)

        // Replacing every card brings chat-made cards back as drafts, plus the draft still waiting.
        let drafts = PromptBuilder.chatCardDrafts(lecture: lecture, pages: [1, 2], includeLinkedDrafts: true)
        #expect(Set(drafts.map(\.point)) == [add.id, improve.id, waiting.id])
        #expect(PromptBuilder.chatCardDrafts(lecture: lecture, pages: [1, 2], includeLinkedDrafts: false).map(\.point) == [waiting.id])
        let prompt = try PromptBuilder.build(kind: .generate, rules: "", module: Module(name: "M"), lecture: lecture, pages: [1, 2], existingFronts: [], includeLinkedDrafts: true)
        #expect(prompt.contains("CHAT CARD DRAFTS")); #expect(prompt.contains(waiting.id.uuidString))
        #expect(!prompt.contains("\"text\":\"New insight\""))

        try LectureReducer.reduce(&lecture, action: .skipLearningPoint(pointID: waiting.id))
        #expect(!lecture.learningPoints[2].included)
        #expect(PromptBuilder.chatCardDrafts(lecture: lecture, pages: [2], includeLinkedDrafts: true).isEmpty)
    }

    @Test func generateLinksDraftCardsAndAddsAnyTheModelDropped() async throws {
        let (store, module, lecture, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var kept = LearningPoint(text: "Kept", pages: [1]); kept.draft = LearningPointDraft(front: "Kept?", back: "Kept.")
        var dropped = LearningPoint(text: "Dropped by model", pages: [2]); dropped.draft = LearningPointDraft(front: "Dropped?", back: "Dropped.")
        let points = [kept, dropped], keptID = kept.id
        _ = try await store.updateLecture(moduleID: module.id, lectureID: lecture.id) { $0.learningPoints = points }
        let provider = ScriptedProvider { request in
            #expect(request.prompt.contains("CHAT CARD DRAFTS"))
            #expect(AIOutputSchema.json(for: .generate)?.contains("\"point\"") == true)
            return AIResponse(content: try encode(GeneratedCards(cards: [
                WireCard(front: "Kept, tightened?", back: "Kept.", sourceSlides: [1], point: keptID.uuidString),
                WireCard(front: "Slide card?", back: "Slide.", sourceSlides: [1])
            ], skipped: [])))
        }
        let runner = JobRunner(store: store, providers: [provider])
        _ = try await runner.generate(moduleID: module.id, lectureID: lecture.id, createNewSet: true)
        await runner.waitUntilIdle()
        let saved = try await store.loadLecture(moduleID: module.id, lectureID: lecture.id)
        #expect(saved.cards.count == 3)
        let keptCard = try #require(saved.cards.first { $0.learningPointID == kept.id })
        #expect(keptCard.front == "Kept, tightened?")
        let droppedCard = try #require(saved.cards.first { $0.learningPointID == dropped.id })
        #expect(droppedCard.front == "Dropped?"); #expect(droppedCard.sourcePages == [2])
        #expect(saved.learningPoints.allSatisfy { !$0.isPendingDraft && ($0.cardIDs ?? []).count == 1 })
    }

    @Test func quotesMustAppearInTheMessage() {
        #expect(ChatDistillationRules.quote("so the variance is", appearsIn: "So the **variance** is the squared deviations?"))
        #expect(ChatDistillationRules.quote("I don't … get it", appearsIn: "I don't really get it"))
        #expect(!ChatDistillationRules.quote("I understand it now", appearsIn: "I don't get it"))
        #expect(!ChatDistillationRules.quote("a", appearsIn: "a"))
    }
}

private func chatAnswerStatic() -> AIResponse {
    var answer = AIResponse(content: #"{"message":"Variance is the average squared deviation [S1]","edits":[]}"#); answer.read = [.slide(1)]; return answer
}
