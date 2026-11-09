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

    @Test func snapshotRendersNativePNGAndNeverAttachesPDF() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lectern-v2-pdf-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.pdf"); var box = CGRect(x: 0, y: 0, width: 400, height: 300)
        let context = try #require(CGContext(source as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil); context.setFillColor(CGColor(gray: 0.4, alpha: 1)); context.fill(CGRect(x: 20, y: 20, width: 50, height: 50)); context.endPDFPage(); context.closePDF()
        let store = LibraryStore(rootURL: root.appendingPathComponent("library")); let module = try await store.createModule(name: "PDF")
        let lecture = try await store.createLecture(Lecture(moduleID: module.id, name: "PDF", pageCount: 1, slides: [SlideState(pageIndex: 0, note: "Important note")]), sourceURL: source)
        let provider = FakeAIProvider(responses: [AIResponse(content: "{\"message\":\"Explained [S1].\",\"edits\":[]}"), AIResponse(content: "{\"learningPoints\":[],\"summary\":\"\"}")])
        let runner = JobRunner(store: store, providers: [provider]); let jobID = try await runner.chat(moduleID: module.id, lectureID: lecture.id, question: "Explain this", contextRefs: [.slide(1)])
        await runner.waitUntilIdle(); let requests = await provider.requests
        #expect(requests[0].pdf == nil); #expect(requests[0].chatSnapshot?.slides.first?.note == "Important note")
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
