import CoreGraphics
import Foundation
import Testing
@testable import LecternCore

@Suite struct ChatSolveReplacementTests {
    enum Decision: CaseIterable { case replace, dismiss, editFirst }

    @Test(arguments: Decision.allCases)
    @MainActor func replacingAFlipCardRequiresASeparateDecision(_ decision: Decision) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lectern-chat-replacement-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pdf = root.appendingPathComponent("Source.pdf")
        var box = CGRect(x: 0, y: 0, width: 300, height: 200)
        let pdfContext = try #require(CGContext(pdf as CFURL, mediaBox: &box, nil))
        pdfContext.beginPDFPage(nil); pdfContext.endPDFPage(); pdfContext.closePDF()

        let library = root.appendingPathComponent("Library")
        let store = LibraryStore(rootURL: library)
        let module = try await store.createModule(name: "Accounting")
        let initialCard = Card(sourcePages: [1], front: "What are the uses of four common margins?",
                               back: "Each margin answers a different analytical question.", verdict: .good)
        let lecture = try await store.createLecture(Lecture(moduleID: module.id, name: "Margins", pageCount: 1,
            cards: [initialCard]), sourceURL: pdf)
        let persisted = try await store.loadLecture(moduleID: module.id, lectureID: lecture.id)
        let original = try #require(persisted.cards.first)
        let sample = SolveCaseContent(prompt: "Which margin measures operating profit after depreciation?",
            fields: [SolveField(prompt: "Select the margin", choice: SolveChoice(options: [
                SolveOption(label: "EBIT", reason: "Includes depreciation"),
                SolveOption(label: "EBITDA", reason: "Excludes depreciation")
            ], correct: ["EBIT"], multiple: false, shuffle: true))], explanation: "Use EBIT margin.")
        let draft = SolveDraft(skill: "Select the appropriate margin", reason: "Practice applying the metrics",
                               variation: "Vary the analyst's goal", sample: sample)
        let edit = ChatCardEdit(cardID: original.id, baseRevisionID: try #require(original.currentRevisionID),
                               front: "Preview", back: "Preview answer", solve: draft)
        let provider = ScriptedProvider { request in
            #expect(request.outputSchema?.contains("solveDraft") == true)
            #expect(request.prompt.contains("explicitly asks to turn an existing flip card into a solve card"))
            let reply = ChatReply(message: "Here's a practice question for [C1].", edits: [edit])
            return AIResponse(content: String(decoding: try JSONEncoder().encode(reply), as: UTF8.self))
        }
        let runner = JobRunner(store: store, providers: [provider])
        let jobID = try await runner.chat(moduleID: module.id, lectureID: lecture.id,
            question: "Turn this into a solve card.", contextRefs: [.card(original.id)])
        await runner.waitUntilIdle()
        let pendingLecture = try await store.loadLecture(moduleID: module.id, lectureID: lecture.id)
        let message = try #require(pendingLecture.currentChat.messages.last)
        #expect(message.role == .assistant)
        #expect(message.pendingEdits.first?.replacesFlipCard == true)
        #expect(message.pendingEdits.first?.solve?.sample == sample)
        #expect(pendingLecture.jobs.first(where: { $0.id == jobID })?.chatEditDisposition == .proposed)
        #expect(pendingLecture.cards == [original])

        let session = LectureSession(lecture: pendingLecture, store: store, runner: runner)
        switch decision {
        case .replace:
            let studyCard = try #require(try await store.studyCatalog().decks.first?.approvedCards.first)
            let originalMemory = try await store.gradeStudyCard(studyCard, rating: .good, eventID: UUID(), now: Date(),
                answeringTime: 1, permitEarly: false, extraNewPerModule: 0)
            var automaticAttempt = pendingLecture
            let jobIndex = try #require(automaticAttempt.jobs.firstIndex(where: { $0.id == jobID }))
            automaticAttempt.jobs[jobIndex].state = .running
            #expect(throws: LectureError.self) {
                try LectureReducer.reduce(&automaticAttempt, action: .applyChatEdits(jobID: jobID, edits: message.pendingEdits))
            }
            #expect(automaticAttempt.cards == [original])
            try await session.resolveChatEdits(messageID: message.id, apply: true)
            let reopened = LibraryStore(rootURL: library)
            let saved = try await reopened.loadLecture(moduleID: module.id, lectureID: lecture.id)
            let replacement = try #require(saved.cards.first)
            #expect(saved.cards.count == 1)
            #expect(replacement.id == original.id)
            #expect(replacement.sourcePages == original.sourcePages)
            #expect(replacement.history.starts(with: original.history))
            #expect(replacement.solve?.draft == draft)
            #expect(replacement.verdict == .good)
            #expect(replacement.studyScheduleID == replacement.currentRevisionID)
            #expect(try await reopened.studyCatalog().decks.first?.memory[original.id] == nil)
            #expect(saved.jobs.first(where: { $0.id == jobID })?.chatEditDisposition == .applied)
            await #expect(throws: AIError.self) {
                try await runner.retryLectureChat(moduleID: module.id, lectureID: lecture.id, jobID: jobID)
            }
            try await session.dispatch(.undoChatEdits(jobID: jobID))
            let restored = try #require(session.lecture.cards.first)
            #expect(restored.solve == nil)
            #expect(restored.studyScheduleID == nil)
            #expect(restored.id == original.id && restored.front == original.front && restored.back == original.back)
            #expect(restored.verdict == original.verdict)
            #expect(try await reopened.studyCatalog().decks.first?.memory[original.id] == originalMemory)
        case .dismiss:
            try await session.resolveChatEdits(messageID: message.id, apply: false)
            #expect(session.lecture.cards == [original])
            #expect(session.lecture.jobs.first(where: { $0.id == jobID })?.chatEditDisposition == .dismissed)
        case .editFirst:
            try await session.dispatch(.commitEdit(cardID: original.id, front: "My edited question",
                back: original.back, sourcePages: original.sourcePages))
            for force in [false, true] {
                await #expect(throws: LectureError.self) {
                    try await session.resolveChatEdits(messageID: message.id, apply: true, force: force)
                }
            }
            await #expect(throws: AIError.self) {
                try await runner.retryLectureChat(moduleID: module.id, lectureID: lecture.id, jobID: jobID)
            }
            #expect(await provider.requests.count == 1)
            #expect(session.lecture.cards.first?.front == "My edited question")
            #expect(session.lecture.cards.first?.solve == nil)
        }
    }
}
