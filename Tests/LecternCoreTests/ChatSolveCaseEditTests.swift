import CoreGraphics
import Foundation
import Testing
@testable import LecternCore

@Suite struct ChatSolveCaseEditTests {
    private func content(_ prompt: String, answer: String, explanation: String) -> SolveCaseContent {
        SolveCaseContent(prompt: prompt, fields: [
            SolveField(prompt: "Profit", input: SolveInput(kind: .number, answers: [answer]))
        ], explanation: explanation)
    }

    private func fixture() async throws -> (LibraryStore, Module, Lecture, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lectern-solve-case-edits-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let pdf = root.appendingPathComponent("Source.pdf")
        var box = CGRect(x: 0, y: 0, width: 300, height: 200)
        let context = try #require(CGContext(pdf as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil); context.endPDFPage(); context.closePDF()

        let store = LibraryStore(rootURL: root.appendingPathComponent("Library"))
        let module = try await store.createModule(name: "Accounting")
        let sample = content("Revenue is 90 and costs are 20. Calculate profit.", answer: "70", explanation: "Subtract costs from revenue.")
        let draft = SolveDraft(skill: "Calculate profit", reason: "Apply the profit formula", variation: "Change the values", sample: sample)
        var card = Card(sourcePages: [1], front: sample.prompt, back: sample.explanation, verdict: .good,
                        mathInterpretations: ["$x$": .keepAsText])
        try card.setSolveDraft(draft)
        card.history[0].solve = draft
        card.solve?.cases.append(SolveCase(content: content("Revenue is 120 and costs are 30. Calculate profit.", answer: "90", explanation: "Subtract 30 from 120.")))
        card.solve?.cases.append(SolveCase(content: content("Revenue is 100 and costs are 25. Calculate profit.", answer: "75", explanation: "Subtract 25 from 100.")))
        let lecture = Lecture(moduleID: module.id, name: "Profit", pageCount: 1,
                              slides: [SlideState(pageIndex: 0)], cards: [card])
        let created = try await store.createLecture(lecture, sourceURL: pdf)
        return (store, module, try await store.loadLecture(moduleID: module.id, lectureID: created.id), root)
    }

    private func edit(_ card: Card, cases: [ChatSolveCaseEdit]) -> ChatCardEdit {
        ChatCardEdit(cardID: card.id, baseRevisionID: card.currentRevisionID!,
                     front: "model must not set the parent front", back: "model must not set the parent back",
                     caseEdits: cases)
    }

    @MainActor
    private func pending(_ store: LibraryStore, lecture: Lecture, edits: [ChatCardEdit]) async throws -> (UUID, LectureSession) {
        let jobID = UUID()
        var job = Job(id: jobID, kind: .chat, pages: [1], state: .succeeded, threadID: lecture.currentChat.id)
        job.chatEdits = edits
        job.chatEditDisposition = .proposed
        job.chatCardVersions = edits.compactMap { edit in
            lecture.cards.first(where: { $0.id == edit.cardID }).map {
                ChatCardVersion(cardID: $0.id, revisionID: $0.currentRevisionID!, verdict: $0.verdict,
                                mathInterpretations: $0.mathInterpretations)
            }
        }
        job.finishedAt = Date()
        var message = ChatMessage(role: .assistant, text: "A replacement is ready for review.")
        message.editJobID = jobID
        message.pendingEdits = edits
        let savedJob = job
        let savedMessage = message
        _ = try await store.updateLecture(moduleID: lecture.moduleID, lectureID: lecture.id) { latest in
            latest.jobs.append(savedJob)
            latest.currentChat.messages.append(savedMessage)
        }
        let latest = try await store.loadLecture(moduleID: lecture.moduleID, lectureID: lecture.id)
        return (message.id, LectureSession(lecture: latest, store: store, runner: JobRunner(store: store, providers: [])))
    }

    @Test @MainActor func sampleCaseProposalWaitsForApprovalThenAppliesAndUndoesWithJournalIdentity() async throws {
        let (store, module, before, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try #require(before.cards.first)
        let originalSolve = try #require(original.solve)
        let oldSample = try #require(originalSolve.cases.first)
        let presentationID = UUID()
        let studyCard = try #require(try await store.studyCatalog().decks.first?.approvedCards.first)
        #expect(try await store.presentSolveCase(studyCard, presentationID: presentationID)?.id == oldSample.id)

        let revised = content("Revenue is 105 and costs are 35. Calculate profit.", answer: "70", explanation: "Subtract 35 from 105.")
        let proposal = edit(original, cases: [ChatSolveCaseEdit(caseID: oldSample.id,
            baseContentHash: ChatSolveCaseEdit.contentHash(oldSample.content), content: revised)])
        let (messageID, session) = try await pending(store, lecture: before, edits: [proposal])

        #expect(session.lecture.cards.first?.solve == original.solve)
        #expect(session.lecture.currentChat.messages.last?.pendingEdits == [proposal])
        #expect(session.lecture.jobs.last?.chatEditDisposition == .proposed)

        try await session.resolveChatEdits(messageID: messageID, apply: true)
        let reopened = LibraryStore(rootURL: root.appendingPathComponent("Library"))
        let applied = try await reopened.loadLecture(moduleID: module.id, lectureID: before.id)
        let saved = try #require(applied.cards.first)
        let savedSolve = try #require(saved.solve)
        #expect(saved.verdict == .good)
        #expect(saved.mathInterpretations == original.mathInterpretations)
        #expect(saved.front == revised.prompt)
        #expect(saved.back == revised.explanation)
        #expect(savedSolve.draft == SolveDraft(skill: originalSolve.draft.skill, reason: originalSolve.draft.reason,
            variation: originalSolve.draft.variation, sample: revised))
        #expect(savedSolve.cases[0].id != oldSample.id)
        #expect(savedSolve.cases[0].content == revised)
        #expect(savedSolve.cases.last(where: { $0.id == oldSample.id }) == SolveCase(id: oldSample.id, content: oldSample.content, retired: true))
        #expect(savedSolve.cases.filter { $0.id != oldSample.id && $0.id != savedSolve.cases[0].id } == Array(originalSolve.cases.dropFirst()))
        let afterCatalog = try await reopened.studyCatalog()
        let afterStudyCard = try #require(afterCatalog.decks.first?.approvedCards.first)
        #expect(afterStudyCard.seenSolveCaseIDs.contains(oldSample.id))
        #expect(afterStudyCard.availableSolveCases.contains(where: { $0.id == savedSolve.cases[0].id }))
        #expect(applied.jobs.last?.chatEditDisposition == .applied)
        let newSampleID = savedSolve.cases[0].id
        #expect(try await reopened.presentSolveCase(afterStudyCard, presentationID: UUID())?.id == newSampleID)

        try await session.dispatch(.undoChatEdits(jobID: try #require(applied.jobs.last?.id)))
        let undone = try await reopened.loadLecture(moduleID: module.id, lectureID: before.id)
        let restored = try #require(undone.cards.first)
        let restoredSolve = try #require(restored.solve)
        #expect(restoredSolve.draft == originalSolve.draft)
        #expect(restoredSolve.activeCases == originalSolve.activeCases)
        #expect(restoredSolve.cases.first(where: { $0.id == newSampleID })?.content == revised)
        #expect(restoredSolve.cases.first(where: { $0.id == newSampleID })?.retired == true)
        #expect(restored.front == original.front)
        #expect(restored.back == original.back)
        #expect(restored.verdict == original.verdict)
        #expect(restored.mathInterpretations == original.mathInterpretations)
        #expect(undone.jobs.last?.chatEditsUndoneAt != nil)
        let afterUndoCard = try #require(try await reopened.studyCatalog().decks.first?.approvedCards.first)
        #expect(afterUndoCard.seenSolveCaseIDs.isSuperset(of: [oldSample.id, newSampleID]))
    }

    @Test @MainActor func multipleCasesOnOneCardReplaceOnlyTargetsAndKeepUnrelatedPool() async throws {
        let (store, _, before, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let card = try #require(before.cards.first)
        let cases = try #require(card.solve?.cases)
        let revisedFirst = content("Revenue is 140 and costs are 40. Calculate profit.", answer: "100", explanation: "Subtract 40 from 140.")
        let revisedSecond = content("Revenue is 200 and costs are 70. Calculate profit.", answer: "130", explanation: "Subtract 70 from 200.")
        let edits = [
            ChatSolveCaseEdit(caseID: cases[1].id, baseContentHash: ChatSolveCaseEdit.contentHash(cases[1].content), content: revisedFirst),
            ChatSolveCaseEdit(caseID: cases[2].id, baseContentHash: ChatSolveCaseEdit.contentHash(cases[2].content), content: revisedSecond)
        ]
        let (messageID, session) = try await pending(store, lecture: before, edits: [edit(card, cases: edits)])
        #expect(session.lecture.cards.first?.solve == card.solve)
        try await session.resolveChatEdits(messageID: messageID, apply: true)
        let changed = try #require(session.lecture.cards.first?.solve)
        #expect(changed.draft == card.solve?.draft)
        #expect(changed.cases[0] == cases[0])
        #expect(changed.cases[1].id != cases[1].id)
        #expect(changed.cases[1].content == revisedFirst)
        #expect(changed.cases[2].id != cases[2].id)
        #expect(changed.cases[2].content == revisedSecond)
        #expect(changed.cases[3] == cases[1].retiredCase)
        #expect(changed.cases[4] == cases[2].retiredCase)
        #expect(session.lecture.cards.first?.verdict == card.verdict)
        #expect(session.lecture.cards.first?.mathInterpretations == card.mathInterpretations)
    }

    @Test @MainActor func generatedCaseEditsStayPendingAndFrozenLookupAssetsAreVerified() async throws {
        let (store, module, before, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let card = try #require(before.cards.first)
        let target = try #require(card.solve?.cases.dropFirst().first)
        let revised = content("Revenue is 170 and costs are 60. Calculate profit.", answer: "110", explanation: "Subtract 60 from 170.")
        let edit = ChatSolveCaseEdit(caseID: target.id, baseContentHash: ChatSolveCaseEdit.contentHash(target.content), content: revised)
        let reply = ChatReply(message: "I prepared the requested variation.", edits: [
            ChatCardEdit(cardID: card.id, baseRevisionID: card.currentRevisionID!, front: "", back: "", caseEdits: [edit])
        ])
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(reply)) as? [String: Any])
        var responseEdits = try #require(object["edits"] as? [[String: Any]])
        responseEdits[0]["solve"] = NSNull()
        responseEdits[0]["caseEdits"] = [["caseID": edit.caseID.uuidString,
            "baseContentHash": edit.baseContentHash,
            "content": try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(edit.content)) as? [String: Any])]]
        object["edits"] = responseEdits
        object["quiz"] = []
        object["deletions"] = []
        let provider = FakeAIProvider(responses: [AIResponse(content: String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self))])
        let runner = JobRunner(store: store, providers: [provider])
        let jobID = try await runner.chat(moduleID: module.id, lectureID: before.id, question: "Edit this variation's answer key.",
                                          contextRefs: [.card(card.id)])
        await runner.waitUntilIdle()

        let after = try await store.loadLecture(moduleID: module.id, lectureID: before.id)
        let saved = try #require(after.cards.first)
        let job = try #require(after.jobs.first(where: { $0.id == jobID }))
        let message = try #require(after.currentChat.messages.last(where: { $0.editJobID == jobID }))
        #expect(saved == card)
        #expect(job.chatEditDisposition == .proposed)
        #expect(message.pendingEdits.count == 1)
        #expect(message.pendingEdits[0].caseEdits?.first?.caseID == target.id)

        let request = try #require(await provider.requests.first)
        let snapshot = try #require(request.chatSnapshot)
        #expect(snapshot.solveCaseContextVersion == 1)
        let casePath = snapshot.solveCasePath(at: 0)
        let context = ChatProviderContext(request: request, snapshot: snapshot)
        try context.verifyAssets()
        #expect(snapshot.assetHashes?[casePath] == PromptBuilder.hash(try context.data(casePath)))
        let lookup = try JSONDecoder().decode(ChatSolveCaseLookup.self, from: context.data(casePath))
        #expect(lookup.cases.first(where: { $0.caseID == target.id })?.baseContentHash == edit.baseContentHash)
        #expect(!request.prompt.contains(target.content.prompt))
        #expect(!String(decoding: try context.data("cards.json"), as: UTF8.self).contains(target.content.prompt))
        #expect(request.prompt.contains("get_solve_cases"))
        #expect(request.outputSchema?.contains("caseEdits") == true)
        #expect(module.id == after.moduleID)
    }

    @Test(arguments: ["staleHash", "retired", "revision"])
    @MainActor func forceApplyNeverRebasesChangedOrRetiredCases(change: String) async throws {
        let (store, module, before, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let card = try #require(before.cards.first)
        let target = try #require(card.solve?.cases.dropFirst().first)
        let proposalContent = content("Revenue is 160 and costs are 60. Calculate profit.", answer: "100", explanation: "Subtract 60 from 160.")
        let proposal = edit(card, cases: [ChatSolveCaseEdit(caseID: target.id,
            baseContentHash: ChatSolveCaseEdit.contentHash(target.content), content: proposalContent)])
        let (messageID, session) = try await pending(store, lecture: before, edits: [proposal])
        let concurrentContent = content("Revenue is 155 and costs are 55. Calculate profit.", answer: "100", explanation: "Subtract 55 from 155.")
        _ = try await store.updateLecture(moduleID: module.id, lectureID: before.id) { latest in
            guard let index = latest.cards[0].solve?.cases.firstIndex(where: { $0.id == target.id }) else { return }
            if change == "retired" {
                latest.cards[0].solve?.cases[index].retired = true
            } else if change == "staleHash" {
                latest.cards[0].solve?.cases[index].content = concurrentContent
            } else {
                latest.cards[0].history.append(CardRevision(front: latest.cards[0].front,
                    back: latest.cards[0].back, author: .user, reason: "Concurrent edit"))
            }
        }

        await #expect(throws: LectureError.self) {
            try await session.resolveChatEdits(messageID: messageID, apply: true, force: true)
        }
        let latest = try await store.loadLecture(moduleID: module.id, lectureID: before.id)
        let savedCase = try #require(latest.cards[0].solve?.cases.first(where: { $0.id == target.id }))
        #expect(savedCase.retired == (change == "retired"))
        #expect(savedCase.content == (change == "staleHash" ? concurrentContent : target.content))
        #expect(latest.jobs.last?.chatEditDisposition == .proposed)
        #expect(latest.cards[0].solve?.cases.contains(where: { $0.content == proposalContent }) == false)
    }

    @Test func duplicateInvalidAndMixedCaseContractsAreRejected() async throws {
        let (_, _, lecture, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let card = try #require(lecture.cards.first)
        let target = try #require(card.solve?.cases.first)
        let good = ChatSolveCaseEdit(caseID: target.id, baseContentHash: ChatSolveCaseEdit.contentHash(target.content), content: target.content)
        #expect(edit(card, cases: [good, good]).validated(for: card) == nil)
        let invalid = content("Unanswered", answer: "", explanation: "Still unanswered")
        #expect(edit(card, cases: [ChatSolveCaseEdit(caseID: target.id,
            baseContentHash: ChatSolveCaseEdit.contentHash(target.content), content: invalid)]).validated(for: card) == nil)
        #expect(ChatCardEdit(cardID: card.id, baseRevisionID: card.currentRevisionID!, front: card.front,
            back: card.back, solve: card.solve?.draft, caseEdits: [good]).validated(for: card) == nil)
        #expect(edit(card, cases: []).validated(for: card) == nil)

        let orderContent = SolveCaseContent(prompt: "Put the steps in order.", fields: [
            SolveField(prompt: "Order", order: SolveOrder(items: ["A", "B"], sequences: [["A", "B"]]))
        ], explanation: "A comes before B.")
        let orderDraft = SolveDraft(skill: "Order steps", reason: "Use the process", variation: "", sample: orderContent)
        var orderCard = Card(front: orderContent.prompt, back: orderContent.explanation)
        try orderCard.setSolveDraft(orderDraft)
        let orderCase = try #require(orderCard.solve?.cases.first)
        let invalidSampleEdit = ChatSolveCaseEdit(caseID: orderCase.id,
            baseContentHash: ChatSolveCaseEdit.contentHash(orderCase.content),
            content: content("Calculate profit", answer: "2", explanation: "Subtract costs."))
        #expect(ChatCardEdit(cardID: orderCard.id, baseRevisionID: orderCard.currentRevisionID!,
            front: "", back: "", caseEdits: [invalidSampleEdit]).validated(for: orderCard) == nil)
    }

    @Test func schemaAndLegacyDecodingRemainCompatible() throws {
        let snapshot = try JSONDecoder().decode(ChatSnapshot.self, from: Data(#"{"slides":[],"cards":[],"initialRefs":[]}"#.utf8))
        #expect(snapshot.solveCaseContextVersion == nil)
        let legacyEdit = try JSONDecoder().decode(ChatCardEdit.self, from: Data(#"{"cardID":"00000000-0000-0000-0000-000000000001","baseRevisionID":"00000000-0000-0000-0000-000000000002","front":"Q","back":"A"}"#.utf8))
        #expect(legacyEdit.caseEdits == nil)
        let schema = try #require(AIOutputSchema.json(for: .chat, allowsSolveCardEdits: true, allowsSolveCaseEdits: true))
        let object = try #require(JSONSerialization.jsonObject(with: Data(schema.utf8)) as? [String: Any])
        let definitions = try #require(object["$defs"] as? [String: Any])
        #expect(definitions["case"] != nil)
        let properties = try #require(object["properties"] as? [String: Any])
        let edits = try #require(properties["edits"] as? [String: Any])
        let item = try #require(edits["items"] as? [String: Any])
        #expect((item["required"] as? [String])?.contains("caseEdits") == true)
        let editProperties = try #require(item["properties"] as? [String: Any])
        #expect(editProperties["caseEdits"] != nil)
        #expect(AIOutputSchema.json(for: .chat, allowsSolveCardEdits: true)?.contains("caseEdits") == false)
    }
}

private extension SolveCase {
    var retiredCase: SolveCase {
        var value = self
        value.retired = true
        return value
    }
}
