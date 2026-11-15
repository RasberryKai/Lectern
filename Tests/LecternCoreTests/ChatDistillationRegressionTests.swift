import Foundation
import CoreGraphics
import Testing
@testable import LecternCore

@Suite(.serialized) struct ChatDistillationRegressionTests {
    private func fixture(pages: Int = 1) async throws -> (LibraryStore, Module, Lecture, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lectern-distil-regression-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.pdf")
        var box = CGRect(x: 0, y: 0, width: 400, height: 300)
        let context = try #require(CGContext(source as CFURL, mediaBox: &box, nil))
        for _ in 0..<pages { context.beginPDFPage(nil); context.endPDFPage() }
        context.closePDF()
        let store = LibraryStore(rootURL: root.appendingPathComponent("library"))
        let module = try await store.createModule(name: "Distillation regression")
        let lecture = try await store.createLecture(Lecture(moduleID: module.id, name: "Regression", pageCount: pages), sourceURL: source)
        return (store, module, lecture, root)
    }

    private func encoded<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }

    private func lectureAnswer() -> AIResponse {
        var response = AIResponse(content: #"{"message":"Variance is the average squared deviation.","edits":[]}"#)
        response.read = [.slide(1)]
        return response
    }

    @Test func firstPrepareAnswerTracksBeforeItCanBeLeftAndAbandonedAnswerAddsNoPoint() async throws {
        let (store, module, lecture, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = DistillationGate()
        var oldJobs: [Job] = []
        var oldMessages: [ChatMessage] = []
        for index in 0..<10 {
            let oldJob = Job(kind: .chat, pages: [1], state: .succeeded, threadID: lecture.currentChat.id)
            for role in [MessageRole.user, .assistant] {
                var message = ChatMessage(role: role, text: "Old turn \(index)")
                message.editJobID = oldJob.id; message.context = [.slide(1)]
                oldMessages.append(message)
            }
            oldJobs.append(oldJob)
        }
        _ = try await store.updateLecture(moduleID: module.id, lectureID: lecture.id) { [oldJobs, oldMessages] latest in
            latest.jobs = oldJobs; latest.currentChat.messages = oldMessages
        }
        let provider = ScriptedProvider { request in
            if request.kind == .chat { return lectureAnswer() }
            if request.diagnosticContext?["purpose"] == "summary" {
                await gate.block()
                return AIResponse(content: #"{"summary":"Older turns retained."}"#)
            }
            #expect(request.diagnosticContext?["trigger"] == "newChat")
            let saved = try await store.loadLecture(moduleID: module.id, lectureID: lecture.id)
            let user = try #require(saved.currentChat.messages.last(where: { $0.role == .user }))
            let answer = try #require(saved.currentChat.messages.last(where: { $0.role == .assistant }))
            let abandoned = ChatDistillation.Point(text: "Variance averages squared deviations.", pages: [1], kind: "understood",
                evidence: [.init(messageID: user.id.uuidString, quote: "What is variance?")],
                front: "What is variance?", back: "The average squared deviation.", endMessageID: answer.id.uuidString)
            return AIResponse(content: try encoded(ChatDistillation(summary: "", closedThroughMessageID: answer.id.uuidString, learningPoints: [abandoned])))
        }
        let runner = JobRunner(store: store, providers: [provider])
        _ = try await runner.chat(moduleID: module.id, lectureID: lecture.id, question: "What is variance?", contextRefs: [.slide(1)])
        let immediatelySaved = try await store.loadLecture(moduleID: module.id, lectureID: lecture.id)
        #expect(immediatelySaved.currentChat.pointCursor == 20)
        await gate.waitUntilBlocked()
        #expect(await provider.requests.map(\.kind) == [.chat, .distil])
        try await runner.endChatDiscussions(moduleID: module.id, lectureID: lecture.id, chatID: lecture.currentChat.id, reason: .newChat)
        await gate.release()
        await runner.waitUntilIdle()
        let saved = try await store.loadLecture(moduleID: module.id, lectureID: lecture.id)
        #expect(saved.currentChat.pointCursor == 22)
        #expect(saved.learningPoints.isEmpty)
        #expect(await provider.requests.map(\.kind) == [.chat, .distil, .distil])
        let distillation = try #require(await provider.requests.last)
        #expect(distillation.diagnosticContext?["feature"] == "learningPointsV2")
        #expect(distillation.prompt.contains("abandoned or unreacted answers get no point"))
    }

    @Test func nilCursorLegacyChatIsNotReextractedOnExit() async throws {
        let (store, module, lecture, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let job = Job(kind: .chat, pages: [1], state: .succeeded, threadID: lecture.currentChat.id)
        var trackedJob = job; trackedJob.isLectureChat = true
        var user = ChatMessage(role: .user, text: "What is variance?"); user.editJobID = job.id; user.context = [.slide(1)]
        var answer = ChatMessage(role: .assistant, text: "Variance is the average squared deviation."); answer.editJobID = job.id; answer.context = [.slide(1)]
        _ = try await store.updateLecture(moduleID: module.id, lectureID: lecture.id) { [trackedJob, user, answer] in $0.jobs = [trackedJob]; $0.currentChat.messages = [user, answer] }
        let provider = ScriptedProvider { _ in AIResponse(content: #"{"summary":"","closedThroughMessageID":null,"learningPoints":[]}"#) }
        let runner = JobRunner(store: store, providers: [provider])
        try await runner.endChatDiscussions(moduleID: module.id, lectureID: lecture.id, chatID: lecture.currentChat.id, reason: .newChat)
        await runner.waitUntilIdle()
        let saved = try await store.loadLecture(moduleID: module.id, lectureID: lecture.id)
        #expect(saved.currentChat.pointCursor == nil)
        #expect(await provider.requests.isEmpty)
    }

    @Test func historicalClickRunsOnceWithoutMovingForwardCursor() async throws {
        let (store, module, lecture, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var job = Job(kind: .chat, pages: [1], state: .succeeded, threadID: lecture.currentChat.id)
        job.isLectureChat = true
        var user = ChatMessage(role: .user, text: "What is variance?"); user.editJobID = job.id; user.context = [.slide(1)]
        var answer = ChatMessage(role: .assistant, text: "Variance is the average squared deviation."); answer.editJobID = job.id; answer.context = [.slide(1)]
        let answerID = answer.id
        _ = try await store.updateLecture(moduleID: module.id, lectureID: lecture.id) { [job, user, answer] latest in
            latest.jobs = [job]; latest.currentChat.messages = [user, answer]; latest.currentChat.pointCursor = 2
        }
        let provider = ScriptedProvider { request in
            #expect(request.diagnosticContext?["trigger"] == "clicked")
            #expect(request.prompt.contains(answerID.uuidString))
            let point = ChatDistillation.Point(text: "Variance is average squared deviation.", pages: [1], kind: "understood",
                evidence: [.init(messageID: answerID.uuidString, quote: "average squared deviation")],
                front: "What is variance?", back: "Average squared deviation.", endMessageID: answerID.uuidString)
            return AIResponse(content: try encoded(ChatDistillation(summary: "", closedThroughMessageID: answerID.uuidString, learningPoints: [point])))
        }
        let runner = JobRunner(store: store, providers: [provider])
        try await runner.setChatAnswerClicked(moduleID: module.id, lectureID: lecture.id, messageID: answerID, clicked: true)
        await runner.waitUntilIdle()
        var saved = try await store.loadLecture(moduleID: module.id, lectureID: lecture.id)
        #expect(saved.currentChat.messages.last?.clicked == true)
        #expect(saved.currentChat.pointCursor == 2)
        #expect(saved.learningPoints.count == 1)
        #expect(saved.currentChat.processedClickedAnswerIDs == [answerID])

        try await runner.setChatAnswerClicked(moduleID: module.id, lectureID: lecture.id, messageID: answerID, clicked: false)
        try await runner.setChatAnswerClicked(moduleID: module.id, lectureID: lecture.id, messageID: answerID, clicked: true)
        await runner.waitUntilIdle()
        saved = try await store.loadLecture(moduleID: module.id, lectureID: lecture.id)
        #expect(saved.learningPoints.count == 1)
        #expect(await provider.requests.count == 1)
    }

    @Test func exitUsesCapturedBoundaryAndIncludesTheWholeUnjudgedRange() async throws {
        let (store, module, lecture, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var jobs: [Job] = []
        var messages: [ChatMessage] = []
        for index in 0..<20 {
            var job = Job(kind: .chat, pages: [1], state: .succeeded, threadID: lecture.currentChat.id); job.isLectureChat = true
            for role in [MessageRole.user, .assistant] {
                var message = ChatMessage(role: role, text: "Concept \(index)")
                message.editJobID = job.id; message.context = [.slide(1)]
                messages.append(message)
            }
            jobs.append(job)
        }
        let firstMessageID = messages[0].id, boundaryID = messages[39].id
        _ = try await store.updateLecture(moduleID: module.id, lectureID: lecture.id) { [jobs, messages] latest in
            latest.jobs = jobs; latest.currentChat.messages = messages; latest.currentChat.pointCursor = 0
        }
        let provider = ScriptedProvider { request in
            #expect(request.diagnosticContext?["trigger"] == "switchChat")
            #expect(request.prompt.contains(firstMessageID.uuidString))
            #expect(request.prompt.contains(boundaryID.uuidString))
            #expect(request.prompt.contains("Concept 0"))
            #expect(request.prompt.contains("Concept 19"))
            return AIResponse(content: #"{"summary":"","closedThroughMessageID":null,"learningPoints":[]}"#)
        }
        let runner = JobRunner(store: store, providers: [provider])
        try await runner.endChatDiscussions(moduleID: module.id, lectureID: lecture.id, chatID: lecture.currentChat.id, reason: .switchChat)

        var laterJob = Job(kind: .chat, pages: [1], state: .succeeded, threadID: lecture.currentChat.id); laterJob.isLectureChat = true
        var laterUser = ChatMessage(role: .user, text: "A later question"); laterUser.editJobID = laterJob.id; laterUser.context = [.slide(1)]
        var laterAnswer = ChatMessage(role: .assistant, text: "A later answer"); laterAnswer.editJobID = laterJob.id; laterAnswer.context = [.slide(1)]
        let laterUserID = laterUser.id
        _ = try await store.updateLecture(moduleID: module.id, lectureID: lecture.id) { [laterJob, laterUser, laterAnswer] latest in
            latest.jobs.append(laterJob); latest.currentChat.messages.append(contentsOf: [laterUser, laterAnswer])
        }
        await runner.waitUntilIdle()
        let saved = try await store.loadLecture(moduleID: module.id, lectureID: lecture.id)
        #expect(saved.currentChat.messages.count == 42)
        #expect(saved.currentChat.pointCursor == 40)
        #expect(!(try #require(await provider.requests.first)).prompt.contains(laterUserID.uuidString))
    }

    @Test func lateConcurrentLandingsRecheckSlideCapAndNormalizedDuplicates() throws {
        var lecture = Lecture(moduleID: UUID(), name: "L", pageCount: 2)
        lecture.learningPoints = [LearningPoint(text: "Existing one", pages: [1]), LearningPoint(text: "Existing two", pages: [1])]
        let answer = ChatMessage(role: .assistant, text: "Variance is an average squared deviation.")
        let reaction = ChatMessage(role: .user, text: "So variance averages squared deviations, right?")
        let window = [answer, reaction]
        func decision(_ text: String, pages: [Int] = [1], mergeID: UUID? = nil, against snapshot: Lecture) -> JobRunner.PointDecision {
            let wire = ChatDistillation.Point(text: text, pages: pages, kind: "ownWords",
                evidence: [.init(messageID: reaction.id.uuidString, quote: "variance averages squared deviations")],
                front: "What is variance?", back: "Average squared deviation.", mergesPointID: mergeID?.uuidString,
                endMessageID: reaction.id.uuidString)
            return JobRunner.validatedPoints(.init(closedThroughMessageID: reaction.id.uuidString, learningPoints: [wire]),
                                             lecture: snapshot, window: window, readPages: [1, 2], closeAll: false,
                                             cursorEnd: 2, messages: window)
        }

        let first = decision("First distinct insight", against: lecture)
        let second = decision("Second distinct insight", against: lecture)
        _ = JobRunner.apply(first, to: &lecture, chatID: lecture.currentChat.id)
        let secondOutcome = JobRunner.apply(second, to: &lecture, chatID: lecture.currentChat.id)
        #expect(lecture.learningPoints.filter { $0.included && $0.pages.contains(1) }.count == 3)
        #expect(secondOutcome.added == 0)
        #expect(secondOutcome.rejected == 1)

        var noPoints = Lecture(moduleID: UUID(), name: "L", pageCount: 2)
        let stale = decision("Normalized duplicate", against: noPoints)
        noPoints.learningPoints = [LearningPoint(text: "normalized duplicate", pages: [1])]
        let duplicateOutcome = JobRunner.apply(stale, to: &noPoints, chatID: noPoints.currentChat.id)
        #expect(noPoints.learningPoints.count == 1)
        #expect(duplicateOutcome.rejected == 1)

        var mergeBase = Lecture(moduleID: UUID(), name: "L", pageCount: 2)
        mergeBase.learningPoints = (0..<2).map { LearningPoint(text: "Slide one point \($0)", pages: [1]) }
        let mergeTarget = LearningPoint(text: "A different slide point", pages: [2])
        mergeBase.learningPoints.append(mergeTarget)
        let merge = decision("A merged insight", pages: [1], mergeID: mergeTarget.id, against: mergeBase)
        mergeBase.learningPoints.append(LearningPoint(text: "Concurrent slide one point", pages: [1]))
        let mergeOutcome = JobRunner.apply(merge, to: &mergeBase, chatID: mergeBase.currentChat.id)
        #expect(mergeBase.learningPoints.first(where: { $0.id == mergeTarget.id })?.pages == [2])
        #expect(mergeOutcome.merged == 0)
        #expect(mergeOutcome.rejected == 1)
    }

    @Test func queuedClickRetractedBeforeExecutionDoesNotCallProvider() async throws {
        let (store, module, lecture, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var job = Job(kind: .chat, pages: [1], state: .succeeded, threadID: lecture.currentChat.id)
        job.isLectureChat = true
        var user = ChatMessage(role: .user, text: "What is variance?")
        user.editJobID = job.id; user.context = [.slide(1)]
        var answer = ChatMessage(role: .assistant, text: "Variance is the average squared deviation.")
        answer.editJobID = job.id; answer.context = [.slide(1)]
        _ = try await store.updateLecture(moduleID: module.id, lectureID: lecture.id) { [job, user, answer] latest in
            latest.jobs = [job]; latest.currentChat.messages = [user, answer]; latest.currentChat.pointCursor = 2
        }
        let provider = ScriptedProvider { _ in
            Issue.record("A retracted click must not invoke AI")
            return AIResponse(content: "{}")
        }
        let runner = JobRunner(store: store, providers: [provider])
        // This represents a previously queued click after the user has cleared its flag.
        await runner.runChatDistillation(.init(moduleID: module.id, lectureID: lecture.id,
            chatID: lecture.currentChat.id, backend: .claudeCLI, model: "opus", trigger: .clicked(messageID: answer.id)), distilID: UUID())
        #expect(await provider.requests.isEmpty)
        let saved = try await store.loadLecture(moduleID: module.id, lectureID: lecture.id)
        #expect(saved.learningPoints.isEmpty)
        #expect(saved.currentChat.processedClickedAnswerIDs.isEmpty)
        let records = try await store.usageRecords(moduleID: module.id, lectureID: lecture.id)
        #expect(records.last?.details["reason"] == "clickRetracted")
    }

    @Test func failedAndCancelledChatJobsCannotSupplyPointEvidence() {
        let chatID = UUID()
        for state in [JobState.failed, .cancelled, .running] {
            var job = Job(kind: .chat, pages: [1], state: state, threadID: chatID); job.isLectureChat = true
            var user = ChatMessage(role: .user, text: "What is variance?"); user.editJobID = job.id; user.context = [.slide(1)]
            let lecture = Lecture(moduleID: UUID(), name: "L", pageCount: 1, jobs: [job])
            #expect(!ChatDistillationRules.isPrepare(user, in: lecture))
        }
        var succeeded = Job(kind: .chat, pages: [1], state: .succeeded, threadID: chatID); succeeded.isLectureChat = true
        var user = ChatMessage(role: .user, text: "What is variance?"); user.editJobID = succeeded.id; user.context = [.slide(1)]
        #expect(ChatDistillationRules.isPrepare(user, in: Lecture(moduleID: UUID(), name: "L", pageCount: 1, jobs: [succeeded])))
    }
}

private actor DistillationGate {
    private var isBlocked = false
    private var blockedWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func block() async {
        isBlocked = true
        blockedWaiter?.resume(); blockedWaiter = nil
        await withCheckedContinuation { releaseWaiter = $0 }
    }
    func waitUntilBlocked() async {
        if isBlocked { return }
        await withCheckedContinuation { blockedWaiter = $0 }
    }
    func release() { releaseWaiter?.resume(); releaseWaiter = nil }
}
