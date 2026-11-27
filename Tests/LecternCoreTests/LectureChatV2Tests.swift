import Foundation
import CoreGraphics
import Testing
@testable import LecternCore

private actor V2Gate: AIProvider {
    nonisolated let backend = AIBackend.claudeCLI
    var started = false
    var released = false
    let reply: AIResponse
    init(_ reply: AIResponse) { self.reply = reply }
    func execute(_ request: AIRequest, onEvent: @escaping @Sendable (AIEvent) -> Void) async throws -> AIResponse {
        if request.kind == .distil { return AIResponse(content: "{\"learningPoints\":[],\"summary\":\"\"}") }
        started = true; onEvent(.text("Partial explanation"))
        while !released { try await Task.sleep(for: .milliseconds(5)) }
        return reply
    }
    func release() { released = true }
}
@Suite struct LectureChatV2Tests {
    @Test(arguments: 0..<8)
    func learningPointsAreLimitedToSlideConversations(scenario: Int) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lectern-point-scope-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.pdf")
        var box = CGRect(x: 0, y: 0, width: 400, height: 300)
        let context = try #require(CGContext(source as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil); context.endPDFPage(); context.closePDF()
        let store = LibraryStore(rootURL: root.appendingPathComponent("library"))
        let module = try await store.createModule(name: "Scope")
        let card = Card(sourcePages: [1], front: "Question", back: "Answer")
        var lecture = Lecture(moduleID: module.id, name: "Scope", pageCount: 1, cards: [card])
        let needsSummary = scenario == 7
        if needsSummary {
            lecture.currentChat.messages = (0..<24).map {
                ChatMessage(role: $0.isMultiple(of: 2) ? .user : .assistant, text: "Earlier message \($0)")
            }
        }
        lecture = try await store.createLecture(lecture, sourceURL: source)
        let refs: [ContextRef]
        switch scenario {
        case 0: refs = [.slide(1)]
        case 1: refs = [.allSlides]
        case 2: refs = [.card(card.id)]
        case 3: refs = [.allCards]
        case 4, 7: refs = [.card(card.id), .slide(1)]
        case 5: refs = [.slide(1)] // Review with only a pinned slide.
        default: refs = [] // Review with screen following disabled.
        }
        let allowsCardCreation = scenario == 5 || scenario == 6
        let extractsPoints = scenario < 2
        let runsDistillation = extractsPoints || needsSummary
        var answer = AIResponse(content: #"{"message":"Explanation [S1]","edits":[]}"#)
        answer.read = [.slide(1)]
        // The distillation closes the discussion with a point that quotes the student; only slide conversations may keep it.
        let reply = answer, lectureID = lecture.id
        let provider = ScriptedProvider { request in
            if request.kind == .chat { return reply }
            let saved = try await store.loadLecture(moduleID: module.id, lectureID: lectureID)
            let messages = saved.currentChat.messages
            let last = messages.last!
            let point = ChatDistillation.Point(text: "A grounded insight", pages: [1], kind: "understood",
                evidence: [.init(messageID: last.id.uuidString, quote: "Explanation")], front: "Q?", back: "A.", endMessageID: last.id.uuidString)
            return AIResponse(content: String(decoding: try JSONEncoder().encode(ChatDistillation(summary: "Older discussion", closedThroughMessageID: last.id.uuidString, learningPoints: [point])), as: UTF8.self))
        }
        let runner = JobRunner(store: store, providers: [provider])
        let jobID = try await runner.chat(moduleID: module.id, lectureID: lecture.id, question: "Explain this",
            contextRefs: refs, allowsCardCreation: allowsCardCreation)
        await runner.waitUntilIdle()
        if extractsPoints {
            // An initial question is not evidence. A click provides the positive reaction.
            let initial = try await store.loadLecture(moduleID: module.id, lectureID: lecture.id)
            #expect(initial.learningPoints.isEmpty)
            #expect(await provider.requests.map(\.kind) == [.chat])
            let answerID = try #require(initial.currentChat.messages.last(where: { $0.role == .assistant })?.id)
            try await runner.setChatAnswerClicked(moduleID: module.id, lectureID: lecture.id, messageID: answerID, clicked: true)
            await runner.waitUntilIdle()
        }
        let saved = try await store.loadLecture(moduleID: module.id, lectureID: lecture.id)
        #expect(saved.jobs.first(where: { $0.id == jobID })?.state == .succeeded)
        #expect(saved.learningPoints.map(\.text) == (extractsPoints ? ["A grounded insight"] : []))
        #expect(saved.learningPoints.first?.draft?.front == (extractsPoints ? "Q?" : nil))
        let requests = await provider.requests
        #expect(requests.map(\.kind) == (runsDistillation ? [.chat, .distil] : [.chat]))
        #expect(saved.jobs.allSatisfy { $0.state == .succeeded })
        if needsSummary {
            #expect(saved.currentChat.summary == "Older discussion")
            #expect(saved.currentChat.summarizedMessageCount == 6)
            #expect(requests.last?.prompt.contains("extraction is disabled") == true)
        }
    }

    @Test func learningPointsSavedBeforeTheDrawerDecodeAsReviewed() throws {
        let fresh = LearningPoint(text: "New", pages: [1])
        #expect(!fresh.reviewed)
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(fresh)) as! [String: Any]
        #expect(try JSONDecoder().decode(LearningPoint.self, from: JSONSerialization.data(withJSONObject: object)).reviewed == false)
        object.removeValue(forKey: "reviewed")
        #expect(try JSONDecoder().decode(LearningPoint.self, from: JSONSerialization.data(withJSONObject: object)).reviewed)
    }
    func fixture() async throws -> (LibraryStore, Module, Lecture, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lectern-v2-\(UUID())")
        let store = LibraryStore(rootURL: root); let module = try await store.createModule(name: "V2")
        let cards = (1...4).map { Card(front: "Question \($0)", back: "Answer \($0)") }
        let lecture = try await store.createLecture(Lecture(moduleID: module.id, name: "Test", cards: cards))
        return (store, module, try await store.loadLecture(moduleID: module.id, lectureID: lecture.id), root)
    }
    func response(_ cards: [Card], count: Int) throws -> AIResponse {
        let edits = cards.prefix(count).map { ChatCardEdit(cardID: $0.id, baseRevisionID: $0.currentRevisionID!, front: $0.front, back: "Revised") }
        return AIResponse(content: String(decoding: try JSONEncoder().encode(ChatReply(message: "Edited.", edits: edits)), as: UTF8.self))
    }
    @Test func migratesChronologicallyWithStableIdentityAndSlideStamps() throws {
        let old = ChatMessage(role: .assistant, text: "Earlier", at: Date(timeIntervalSince1970: 1))
        let newer = ChatMessage(role: .user, text: "Later", at: Date(timeIntervalSince1970: 2))
        let lecture = Lecture(moduleID: UUID(), name: "Old", pageCount: 2, threads: [SlideThread(anchorPage: 2, messages: [newer]), SlideThread(anchorPage: 1, messages: [old])])
        let data = try JSONEncoder().encode(lecture)
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]; object.removeValue(forKey: "currentChat"); object.removeValue(forKey: "learningPoints"); object.removeValue(forKey: "archivedChats")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let first = try JSONDecoder().decode(Lecture.self, from: legacy); let second = try JSONDecoder().decode(Lecture.self, from: legacy)
        #expect(first.currentChat.id == second.currentChat.id)
        #expect(first.currentChat.messages.map(\.text) == ["Earlier", "Later"])
        #expect(first.currentChat.messages[0].context == [.slide(1)])
    }
    @Test @MainActor func savesDraftAndArchivesResumesWithoutLosingLearningPoints() async throws {
        let (store, module, lecture, root) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try await store.updateLecture(moduleID: module.id, lectureID: lecture.id) { $0.learningPoints = [LearningPoint(text: "Keep this", pages: [])] }
        let runner = JobRunner(store: store, providers: []); let session = LectureSession(lecture: lecture, store: store, runner: runner)
        try await session.setChatDraft("Unsent"); let original = session.lecture.currentChat.id
        try await session.newChat(); #expect(session.lecture.archivedChats.first?.draft == "Unsent")
        try await session.openChat(id: original); #expect(session.lecture.currentChat.draft == "Unsent"); #expect(session.lecture.learningPoints.count == 1)
    }
    @Test @MainActor func optimisticMessageIdentitySurvivesCommitAndRepeatedSubmission() async throws {
        let (store, _, lecture, root) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let gate = V2Gate(try response(lecture.cards, count: 0))
        let runner = JobRunner(store: store, providers: [gate])
        let session = LectureSession(lecture: lecture, store: store, runner: runner)
        let messageID = UUID()
        let jobID = try await session.chat(question: "Explain", contextRefs: [.card(lecture.cards[0].id)], messageID: messageID)
        #expect(session.lecture.currentChat.messages.map(\.id) == [messageID])
        #expect(session.lecture.currentChat.messages.first?.editJobID == jobID)
        // A send whose commit succeeded but refresh failed must reuse its existing job.
        let repeatedID = try await session.chat(question: "Explain", contextRefs: [.card(lecture.cards[0].id)], messageID: messageID)
        #expect(repeatedID == jobID)
        #expect(session.lecture.currentChat.messages.filter { $0.role == .user }.count == 1)
        #expect(session.lecture.jobs.filter { $0.kind == .chat }.count == 1)
        await gate.release(); await runner.waitUntilIdle(); try await session.refresh()
        let completedID = try await session.chat(question: "Explain", contextRefs: [], messageID: messageID)
        #expect(completedID == jobID)
        #expect(session.lecture.currentChat.messages.filter { $0.role == .user }.map(\.id) == [messageID])
        #expect(session.lecture.jobs.filter { $0.kind == .chat }.count == 1)
    }
    @Test @MainActor func failedPreparationCanReuseOptimisticMessageIdentity() async throws {
        let (store, _, lecture, root) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let gate = V2Gate(try response(lecture.cards, count: 0))
        let runner = JobRunner(store: store, providers: [gate])
        let session = LectureSession(lecture: lecture, store: store, runner: runner)
        let messageID = UUID()
        await #expect(throws: AIError.self) {
            try await session.chat(question: "Explain", contextRefs: [.slide(999)], messageID: messageID)
        }
        #expect(session.lecture.currentChat.messages.isEmpty)
        #expect(session.lecture.jobs.isEmpty)
        _ = try await session.chat(question: "Explain", contextRefs: [], messageID: messageID)
        #expect(session.lecture.currentChat.messages.map(\.id) == [messageID])
        await gate.release(); await runner.waitUntilIdle()
    }
    @Test @MainActor func reviewFollowUpAddsAnUnreviewedCardAndLinksItWithoutRepeatingOnRetry() async throws {
        let (store, module, lecture, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await store.updateLecture(moduleID: module.id, lectureID: lecture.id) {
            $0.currentChat.messages = [ChatMessage(role: .assistant, text: "The deck is missing a card about the median.")]
        }
        let reply = ChatReply(message: "Here is a card about the median.", newCards: [
            .init(front: " What is the median? ", back: "The middle value of the ordered data.", sourceSlides: [])
        ])
        let response = AIResponse(content: String(decoding: try JSONEncoder().encode(reply), as: UTF8.self))
        let provider = FakeAIProvider(responses: [response, AIResponse(content: #"{"learningPoints":[],"summary":""}"#)])
        let runner = JobRunner(store: store, providers: [provider])
        let session = LectureSession(lecture: lecture, store: store, runner: runner)

        _ = try await session.chat(question: "yeah add one", contextRefs: [], allowsCardCreation: true)
        await runner.waitUntilIdle()
        try await session.refresh()

        let card = try #require(session.lecture.cards.last)
        let answer = try #require(session.lecture.currentChat.messages.last)
        #expect(session.lecture.cards.dropLast().elementsEqual(lecture.cards))
        #expect(card.front == "What is the median?")
        #expect(card.back == "The middle value of the ordered data.")
        #expect(card.verdict == .unreviewed)
        #expect(card.history.first?.author == .ai)
        #expect(answer.createdCardIDs == [card.id])
        #expect(session.lecture.issues(for: card).isEmpty)
        let requests = await provider.requests
        let request = try #require(requests.first)
        #expect(request.prompt.contains("missing a card about the median"))
        #expect(request.systemPrompt.contains("yeah add one"))
        let schema = try #require(request.outputSchema)
        let object = try #require(JSONSerialization.jsonObject(with: Data(schema.utf8)) as? [String: Any])
        #expect((object["required"] as? [String])?.contains("newCards") == true)
        #expect((object["properties"] as? [String: Any])?["newCards"] != nil)

        await #expect(throws: AIError.self) { try await session.retryChat(messageID: answer.id) }
        try await session.refresh()
        #expect(session.lecture.cards.count == lecture.cards.count + 1)
        #expect(session.lecture.currentChat.messages.last == answer)
    }

    @Test(arguments: [false, true])
    @MainActor func rejectsOutOfScopeOrInvalidCardCreationWithoutSavingAnyCards(allowsCreation: Bool) async throws {
        let (store, _, lecture, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let reply = ChatReply(message: "Two cards", newCards: [
            .init(front: "Valid question", back: "Valid answer", sourceSlides: []),
            .init(front: "Invalid source", back: "Another answer", sourceSlides: [999])
        ])
        let response = AIResponse(content: String(decoding: try JSONEncoder().encode(reply), as: UTF8.self))
        let provider = FakeAIProvider(responses: [response])
        let runner = JobRunner(store: store, providers: [provider])
        let session = LectureSession(lecture: lecture, store: store, runner: runner)

        let jobID = try await session.chat(question: "Add two cards", contextRefs: [], allowsCardCreation: allowsCreation)
        await runner.waitUntilIdle()
        try await session.refresh()

        let job = try #require(session.lecture.jobs.first(where: { $0.id == jobID }))
        #expect(job.state == .failed)
        let reason = allowsCreation ? "invalid source slides" : "only be added from Review"
        #expect(job.error?.contains(reason) == true)
        #expect(session.lecture.cards == lecture.cards)
        #expect(session.lecture.currentChat.messages.allSatisfy { $0.role == .user })
    }

    @Test @MainActor func bulkWaitsForApprovalAndConflictKeepsAnswer() async throws {
        let (store, module, lecture, root) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let provider = FakeAIProvider(responses: [try response(lecture.cards, count: 4), AIResponse(content: "{\"learningPoints\":[]}")])
        let runner = JobRunner(store: store, providers: [provider]); let session = LectureSession(lecture: lecture, store: store, runner: runner)
        _ = try await session.chat(question: "Rewrite all", contextRefs: [.allCards]); await runner.waitUntilIdle(); try await session.refresh()
        #expect(session.lecture.cards == lecture.cards); #expect(session.lecture.currentChat.messages.last?.text == "Edited.")
        #expect(session.lecture.jobs.last(where: { $0.kind == .chat })?.chatEditDisposition == .proposed)
        try await session.resolveChatEdits(messageID: session.lecture.currentChat.messages.last!.id, apply: true)
        #expect(session.lecture.cards.allSatisfy { $0.back == "Revised" && $0.verdict == .unreviewed })
        #expect(session.lecture.canUndoChatEdits(jobID: session.lecture.jobs.last(where: { $0.kind == .chat })!.id))
        let requests = await provider.requests
        let directory = requests[0].workingDirectory
        let oneCard = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("cards/C1.json"))) as! [String: Any]
        #expect(oneCard["cardID"] as? String == lecture.cards[0].id.uuidString); #expect(oneCard["baseRevisionID"] as? String == lecture.cards[0].currentRevisionID?.uuidString)
        #expect(requests[0].pdf == nil); #expect(requests[0].chatSnapshot?.initialRefs == [.allCards])
    }

    @Test(arguments: ["format", "key", "invalidKey", "missingExercise"])
    @MainActor func sidebarRevisesSolveCardsInPlaceAndValidatesTheAnswerKey(change: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lectern-chat-solve-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(rootURL: root)
        let module = try await store.createModule(name: "Accounting")
        let pdf = root.appendingPathComponent("Source.pdf")
        var box = CGRect(x: 0, y: 0, width: 300, height: 200)
        let context = try #require(CGContext(pdf as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil); context.endPDFPage(); context.closePDF()

        let sample = SolveCaseContent(
            prompt: "Revenue is 2400000 and costs are 1000000 and 300000. Calculate profit.",
            fields: [SolveField(prompt: "Profit", input: SolveInput(kind: .number, answers: ["1100000"]))],
            explanation: "Subtract both costs from revenue."
        )
        let draft = SolveDraft(skill: "Calculate profit", reason: "Apply the formula", variation: "Vary the costs", sample: sample)
        var card = Card(sourcePages: [1], front: sample.prompt, back: sample.explanation, verdict: .good)
        try card.setSolveDraft(draft)
        card.history[0].solve = draft
        var variant = sample
        variant.prompt = "Calculate profit if revenue is 3,000,000 and costs are 1,200,000."
        variant.fields[0].input?.answers = ["1800000"]
        card.solve?.cases.append(SolveCase(content: variant))
        let created = try await store.createLecture(
            Lecture(moduleID: module.id, name: "Profit", pageCount: 1, cards: [card]), sourceURL: pdf)
        let lecture = try await store.loadLecture(moduleID: module.id, lectureID: created.id)
        let original = try #require(lecture.cards.first)

        var revised = draft
        let question: String
        switch change {
        case "format":
            question = "Add thousands separators to the numbers in the question."
            revised.sample.prompt = "Revenue is 2,400,000 and costs are 1,000,000 and 300,000. Calculate profit."
        case "key":
            question = "Accept a tolerance of one in the answer."
            revised.sample.fields[0].input?.tolerance = 1
        default:
            question = "Revise the answer key."
            revised.sample.fields[0].input?.answers = []
        }
        let edit = ChatCardEdit(cardID: original.id, baseRevisionID: try #require(original.currentRevisionID),
                                front: revised.sample.prompt, back: revised.sample.explanation,
                                solve: change == "missingExercise" ? nil : revised)
        let reply = ChatReply(message: "Here is the requested revision.", edits: [edit])
        let provider = FakeAIProvider(responses: [AIResponse(content: String(decoding: try JSONEncoder().encode(reply), as: UTF8.self))])
        let runner = JobRunner(store: store, providers: [provider])
        let session = LectureSession(lecture: lecture, store: store, runner: runner)
        let jobID = try await session.chat(question: question, contextRefs: [.card(original.id)], allowsCardCreation: true)
        await runner.waitUntilIdle()
        try await session.refresh()
        let request = try #require(await provider.requests.first)
        let schema = try #require(request.outputSchema)
        let contract = try #require(JSONSerialization.jsonObject(with: Data(schema.utf8)) as? [String: Any])
        let properties = try #require(contract["properties"] as? [String: Any])
        let edits = try #require(properties["edits"] as? [String: Any])
        let item = try #require(edits["items"] as? [String: Any])
        #expect((item["required"] as? [String])?.contains("solve") == true)
        #expect((contract["$defs"] as? [String: Any])?["solveDraft"] != nil)
        #expect(request.prompt.contains(schema))
        #expect(request.prompt.contains(original.id.uuidString))
        #expect(!request.systemPrompt.contains("Request revision"))

        let saved = try #require(session.lecture.cards.first)
        let job = try #require(session.lecture.jobs.first(where: { $0.id == jobID }))
        if change == "invalidKey" || change == "missingExercise" {
            #expect(job.state == .failed)
            #expect(saved == original)
            return
        }
        #expect(job.chatEditDisposition == .applied)
        #expect(saved.id == original.id)
        #expect(saved.sourcePages == original.sourcePages)
        #expect(saved.verdict == .unreviewed)
        #expect(saved.front == revised.sample.prompt)
        #expect(saved.solve?.draft == revised)
        #expect(saved.history.last?.solve == revised)
        #expect(saved.currentRevisionID != original.currentRevisionID)
        let answer = change == "key" ? "1100001" : "1100000"
        #expect(SolveChecker.check(try #require(saved.solve?.draft.sample), answers: [.text(answer)]).fields[0].status == .correct)

        #expect(session.lecture.canUndoChatEdits(jobID: jobID))
        try await session.dispatch(.undoChatEdits(jobID: jobID))
        let undone = try #require(session.lecture.cards.first)
        #expect(undone.solve == original.solve)
        #expect(undone.front == original.front)
        #expect(undone.verdict == .good)
    }

    @Test @MainActor func deletionRequestsWaitForIndividualOrBatchApproval() async throws {
        let (store, module, lecture, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let cards = lecture.cards
        let reply = ChatReply(message: "Review the proposed deletions.", deletions: cards.map {
            ChatCardDeletion(cardID: $0.id, baseRevisionID: $0.currentRevisionID!)
        })
        let provider = FakeAIProvider(responses: [AIResponse(content: String(decoding: try JSONEncoder().encode(reply), as: UTF8.self))])
        let runner = JobRunner(store: store, providers: [provider])
        let session = LectureSession(lecture: lecture, store: store, runner: runner)
        var preferences = lecture.viewPreferences
        preferences.selectedCardID = cards[0].id
        try await session.dispatch(.setViewPreferences(preferences))

        _ = try await session.chat(question: "Delete these cards", contextRefs: [.allCards])
        await runner.waitUntilIdle()
        try await session.refresh()
        let answer = try #require(session.lecture.currentChat.messages.last)
        let chatID = session.lecture.currentChat.id
        #expect(session.lecture.cards == cards)
        #expect(answer.deletionRequests?.map(\.front) == cards.map(\.front))
        #expect(answer.deletionRequests?.map(\.state) == [.pending, .pending, .pending, .pending])
        let schema = try #require(await provider.requests.first?.outputSchema)
        let object = try #require(JSONSerialization.jsonObject(with: Data(schema.utf8)) as? [String: Any])
        #expect((object["required"] as? [String])?.contains("deletions") == true)

        try await session.newChat()
        try await session.openChat(id: chatID)
        try await session.dispatch(.resolveChatDeletions(chatID: chatID, messageID: answer.id, cardIDs: [cards[0].id], delete: true))
        #expect(session.lecture.cards.filter { !$0.isSuperseded }.map(\.id) == cards.dropFirst().map(\.id))
        #expect(session.lecture.viewPreferences.selectedCardID == nil)
        let jobID = try #require(answer.editJobID)
        #expect(session.lecture.jobs.first { $0.id == jobID }?.chatCitationCardIDs == cards.map(\.id))
        #expect(session.lecture.chatCitationCardID(number: 1, jobID: jobID) == nil)
        #expect(session.lecture.chatCitationCardID(number: 2, jobID: jobID) == cards[1].id)
        #expect(session.lecture.chatCitationCardID(number: 1, jobID: nil) == cards[1].id)

        var olderLecture = session.lecture
        let jobIndex = try #require(olderLecture.jobs.firstIndex { $0.id == jobID })
        olderLecture.jobs[jobIndex].chatCitationCardIDs = nil
        #expect(olderLecture.chatCitationCardID(number: 1, jobID: jobID) == nil)
        #expect(olderLecture.chatCitationCardID(number: 2, jobID: jobID) == cards[1].id)

        try await session.dispatch(.resolveChatDeletions(chatID: chatID, messageID: answer.id, cardIDs: [cards[1].id], delete: false))
        try await session.dispatch(.resolveChatDeletions(chatID: chatID, messageID: answer.id, cardIDs: [cards[2].id, cards[3].id], delete: true))
        await #expect(throws: AIError.self) { try await session.retryChat(messageID: answer.id) }
        let saved = try await store.loadLecture(moduleID: module.id, lectureID: lecture.id)
        #expect(saved.currentChat.messages.last?.deletionRequests?.map(\.state) == [.deleted, .kept, .deleted, .deleted])
        #expect(saved.cards.filter { !$0.isSuperseded } == [cards[1]])
        #expect(saved.cards[0].history == cards[0].history)
    }

    @Test @MainActor func staleDeletionCannotRemoveAnyCardInItsBatch() async throws {
        let (store, _, lecture, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let targets = Array(lecture.cards.prefix(2))
        let reply = ChatReply(message: "Review the proposed deletions.", deletions: targets.map {
            ChatCardDeletion(cardID: $0.id, baseRevisionID: $0.currentRevisionID!)
        })
        let provider = FakeAIProvider(responses: [AIResponse(content: String(decoding: try JSONEncoder().encode(reply), as: UTF8.self))])
        let runner = JobRunner(store: store, providers: [provider])
        let session = LectureSession(lecture: lecture, store: store, runner: runner)
        _ = try await session.chat(question: "Delete two cards", contextRefs: [.allCards])
        await runner.waitUntilIdle()
        try await session.refresh()
        let answer = try #require(session.lecture.currentChat.messages.last)
        let chatID = session.lecture.currentChat.id
        try await session.dispatch(.commitEdit(cardID: targets[1].id, front: "Changed", back: targets[1].back, sourcePages: []))
        await #expect(throws: LectureError.self) {
            try await session.dispatch(.resolveChatDeletions(chatID: chatID, messageID: answer.id, cardIDs: Set(targets.map(\.id)), delete: true))
        }
        await #expect(throws: LectureError.self) {
            try await session.dispatch(.resolveChatDeletions(chatID: chatID, messageID: answer.id, cardIDs: [lecture.cards[2].id], delete: true))
        }
        #expect(session.lecture.cards.allSatisfy { !$0.isSuperseded })
        #expect(session.lecture.currentChat.messages.last?.deletionRequests?.map(\.state) == [.pending, .pending])
        try await session.dispatch(.resolveChatDeletions(chatID: chatID, messageID: answer.id, cardIDs: [targets[0].id], delete: true))
        #expect(session.lecture.cards[0].isSuperseded)
        #expect(!session.lecture.cards[1].isSuperseded)
    }

    @Test @MainActor func deletionProposalRejectsCardOutsideFrozenSnapshot() async throws {
        let (store, _, lecture, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let reply = ChatReply(message: "Review the proposed deletion.", deletions: [.init(cardID: UUID(), baseRevisionID: UUID())])
        let provider = FakeAIProvider(responses: [AIResponse(content: String(decoding: try JSONEncoder().encode(reply), as: UTF8.self))])
        let runner = JobRunner(store: store, providers: [provider])
        let session = LectureSession(lecture: lecture, store: store, runner: runner)
        let jobID = try await session.chat(question: "Delete the first card", contextRefs: [.allCards])
        await runner.waitUntilIdle()
        try await session.refresh()
        #expect(session.lecture.jobs.first(where: { $0.id == jobID })?.state == .failed)
        #expect(session.lecture.currentChat.messages.allSatisfy { $0.deletionRequests == nil })
        #expect(session.lecture.cards == lecture.cards)
    }

    @Test @MainActor func concurrentChangesBecomePendingAndForceApplyIsExplicit() async throws {
        let (store, module, lecture, root) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let gate = V2Gate(try response(lecture.cards, count: 1)); let runner = JobRunner(store: store, providers: [gate]); let session = LectureSession(lecture: lecture, store: store, runner: runner)
        _ = try await session.chat(question: "Rewrite first", contextRefs: [.card(lecture.cards[0].id)])
        while !(await gate.started) { try await Task.sleep(for: .milliseconds(5)) }
        try await session.dispatch(.commitEdit(cardID: lecture.cards[0].id, front: "My edit", back: "Mine", sourcePages: []))
        await gate.release(); await runner.waitUntilIdle(); try await session.refresh()
        #expect(session.lecture.cards[0].back == "Mine"); #expect(session.lecture.currentChat.messages.last?.text == "Edited.")
        #expect(session.lecture.currentChat.messages.last?.conflictingCardIDs == [lecture.cards[0].id])
        try await session.resolveChatEdits(messageID: session.lecture.currentChat.messages.last!.id, apply: true, force: true)
        #expect(session.lecture.cards[0].back == "Revised")
    }
    @Test @MainActor func stopKeepsPartialAndRetryUsesFrozenContextAndReplacesAnswer() async throws {
        let (store, _, lecture, root) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let gate = V2Gate(try response(lecture.cards, count: 0)); let runner = JobRunner(store: store, providers: [gate]); let session = LectureSession(lecture: lecture, store: store, runner: runner)
        _ = try await session.chat(question: "Explain", contextRefs: [.card(lecture.cards[0].id)])
        while !(await gate.started) { try await Task.sleep(for: .milliseconds(5)) }
        try await Task.sleep(for: .milliseconds(20)); try await session.stopChat(); await runner.waitUntilIdle(); try await session.refresh()
        #expect(session.lecture.currentChat.messages.last?.stopped == true); #expect(session.lecture.currentChat.messages.last?.text == "Partial explanation")
        let answer = session.lecture.currentChat.messages.last!; await gate.release()
        try await session.retryChat(messageID: answer.id); await runner.waitUntilIdle(); try await session.refresh()
        #expect(session.lecture.currentChat.messages.count == 2); #expect(session.lecture.currentChat.messages.last?.text == "Edited.")
        #expect(session.lecture.currentChat.messages.last?.context == [.card(lecture.cards[0].id)])
    }
    @Test func promptIncludesOnlyCurrentLastTenTurnsAndSummary() throws {
        var lecture = Lecture(moduleID: UUID(), name: "History")
        lecture.currentChat.messages = (0..<24).map { ChatMessage(role: $0.isMultiple(of: 2) ? .user : .assistant, text: "turn-marker-\($0)-end") }
        lecture.currentChat.summary = "Remember older discussion"
        lecture.archivedChats = [LectureChat(messages: [ChatMessage(role: .user, text: "PRIVATE OLD CHAT")])]
        let snapshot = ChatSnapshot(slides: [], cards: [], initialRefs: [])
        let prompt = try JobRunner.chatPrompt(lecture: lecture, question: "Now", snapshot: snapshot)
        #expect(!prompt.contains("turn-marker-0-end")); #expect(prompt.contains("turn-marker-4-end")); #expect(prompt.contains("Remember older discussion")); #expect(!prompt.contains("PRIVATE OLD CHAT"))
    }

    @Test @MainActor func backgroundRevisionLogsIntoItsArchivedChat() async throws {
        let (store, _, lecture, root) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let revised = RevisedCards(cards: [WireCard(front: "Revised question", back: "Revised answer", sourceSlides: [])], rationale: "Made it clearer.")
        let gate = V2Gate(AIResponse(content: String(decoding: try JSONEncoder().encode(revised), as: UTF8.self)))
        let runner = JobRunner(store: store, providers: [gate]); let session = LectureSession(lecture: lecture, store: store, runner: runner)
        _ = try await session.revise(cardID: lecture.cards[0].id, feedback: "Clarify this")
        while !(await gate.started) { try await Task.sleep(for: .milliseconds(5)) }
        try await session.refresh(); let originalID = session.lecture.currentChat.id
        try await session.newChat(); await gate.release(); await runner.waitUntilIdle(); try await session.refresh()
        #expect(session.lecture.currentChat.messages.isEmpty)
        #expect(session.lecture.archivedChats.first(where: { $0.id == originalID })?.messages.map(\.text) == ["Clarify this", "Made it clearer."])
        #expect(session.lecture.cards[0].proposal?.state == .ready)
    }

    @Test func reviewChatRendersNativePNGAndSavesOnlyValidSourceLinks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lectern-v2-pdf-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.pdf"); var box = CGRect(x: 0, y: 0, width: 400, height: 300)
        let context = try #require(CGContext(source as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil); context.setFillColor(CGColor(gray: 0.4, alpha: 1)); context.fill(CGRect(x: 20, y: 20, width: 50, height: 50)); context.endPDFPage(); context.closePDF()
        let store = LibraryStore(rootURL: root.appendingPathComponent("library")); let module = try await store.createModule(name: "PDF")
        let lecture = try await store.createLecture(Lecture(moduleID: module.id, name: "PDF", pageCount: 1, slides: [SlideState(pageIndex: 0, note: "Important note")]), sourceURL: source)
        let provider = FakeAIProvider(responses: [AIResponse(content: #"{"message":"New card","edits":[],"newCards":[{"front":"Question","back":"Answer","sourceSlides":[1,1]}]}"#), AIResponse(content: "{\"learningPoints\":[],\"summary\":\"\"}")])
        let runner = JobRunner(store: store, providers: [provider]); let jobID = try await runner.chat(moduleID: module.id, lectureID: lecture.id, question: "Add a card for this slide", contextRefs: [.slide(1)], allowsCardCreation: true)
        await runner.waitUntilIdle(); let requests = await provider.requests
        #expect(requests[0].pdf == nil); #expect(requests[0].chatSnapshot?.slides.first?.note == "Important note")
        let saved = try await store.loadLecture(moduleID: module.id, lectureID: lecture.id)
        #expect(saved.cards.first?.sourcePages == [1])
        #expect(saved.currentChat.messages.last?.createdCardIDs == saved.cards.map(\.id))
        let directory = store.jobDirectory(moduleID: module.id, lectureID: lecture.id, jobID: jobID)
        let bytes = try Data(contentsOf: directory.appendingPathComponent("slides/001.png"))
        #expect(Array(bytes.prefix(8)) == [137,80,78,71,13,10,26,10]); #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("input.pdf").path))
    }

    @Test func unreadablePDFThrowsTypedError() throws {
        let lecture = Lecture(moduleID: UUID(), name: "Missing source", pageCount: 1)
        let missing = URL(fileURLWithPath: "/private/tmp/missing-\(UUID()).pdf")
        #expect(throws: AIError.slideRead("The lecture PDF could not be opened. Restore its source file and try again.")) {
            try JobRunner.chatSnapshot(lecture: lecture, refs: [.slide(1)], source: missing, directory: FileManager.default.temporaryDirectory)
        }
    }

    @Test @MainActor func mutatedSnapshotAssetRejectsRetryBeforeChangingAnswerOrCards() async throws {
        let (store, _, lecture, root) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let provider = FakeAIProvider(responses: [try response(lecture.cards, count: 1), AIResponse(content: "{\"learningPoints\":[],\"summary\":\"\"}")])
        let runner = JobRunner(store: store, providers: [provider]); let session = LectureSession(lecture: lecture, store: store, runner: runner)
        let id = try await session.chat(question: "Rewrite first", contextRefs: [.card(lecture.cards[0].id)])
        await runner.waitUntilIdle(); try await session.refresh()
        let before = session.lecture; let calls = await provider.requests.count
        let requests = await provider.requests
        let cardFile = requests[0].workingDirectory.appendingPathComponent("cards/C1.json")
        try Data("tampered context".utf8).write(to: cardFile)
        await #expect(throws: AIError.self) { try await session.retryChat(messageID: before.currentChat.messages.last!.id) }
        try await session.refresh()
        #expect(session.lecture.currentChat.messages == before.currentChat.messages)
        #expect(session.lecture.cards == before.cards)
        #expect(session.lecture.canUndoChatEdits(jobID: id))
        #expect(await provider.requests.count == calls)
    }
    @Test func providerRejectsMutatedPNGBytesAndOldSnapshotStillDecodes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lectern-v2-assets-\(UUID())")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("slides"), withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("original image bytes".utf8); let image = root.appendingPathComponent("slides/001.png")
        try bytes.write(to: image)
        var snapshot = ChatSnapshot(slides: [ChatSlide(page: 1, text: "Frozen text", note: "", imagePath: "slides/001.png")], cards: [], initialRefs: [.slide(1)])
        let oldData = try JSONEncoder().encode(snapshot)
        #expect(try JSONDecoder().decode(ChatSnapshot.self, from: oldData).assetHashes == nil)
        snapshot.assetHashes = ["slides/001.png": PromptBuilder.hash(bytes)]
        let request = AIRequest(jobID: UUID(), kind: .chat, model: "opus", prompt: "", pdf: nil, workingDirectory: root)
        let context = ChatProviderContext(request: request, snapshot: snapshot)
        #expect(try context.data("slides/001.png") == bytes)
        try Data("mutated image bytes".utf8).write(to: image)
        #expect(throws: AIError.self) { try context.image(page: 1) }
    }
    @Test @MainActor func delayedDraftSaveCannotOverwriteNewChatDraft() async throws {
        let (store, _, lecture, root) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let runner = JobRunner(store: store, providers: []); let session = LectureSession(lecture: lecture, store: store, runner: runner)
        let previousID = session.lecture.currentChat.id
        try await session.setChatDraft("Old draft"); try await session.newChat()
        try await session.setChatDraft("New draft")
        try await session.setChatDraft("Late old draft", chatID: previousID)
        #expect(session.lecture.currentChat.draft == "New draft")
    }

}
