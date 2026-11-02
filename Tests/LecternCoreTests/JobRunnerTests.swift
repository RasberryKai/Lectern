import Foundation
import PDFKit
import CoreGraphics
import Testing
@testable import LecternCore

private actor GateProvider: AIProvider {
    nonisolated let backend = AIBackend.claudeCLI
    var calls = 0
    var maximum = 0
    var active = 0
    var released = false
    func execute(_ request: AIRequest, onEvent: @escaping @Sendable (AIEvent) -> Void) async throws -> AIResponse {
        calls += 1; active += 1; maximum = max(maximum, active)
        defer { active -= 1 }
        while !released { try await Task.sleep(for: .milliseconds(5)) }
        try Task.checkCancellation()
        return AIResponse(content: #"{"cards":[{"front":"Why?","back":"Because.","sourceSlides":[1],"flag":null}],"skipped":[]}"#)
    }
    func release() { released = true }
    func count() -> Int { calls }
}

private actor PreparationGateExporter: PDFSnapshotExporting {
    var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    func export(_ plan: PDFExportPlan, to destinationURL: URL) async throws -> PDFExportResult {
        started = true
        await withCheckedContinuation { continuation = $0 }
        // Deliberately ignore caller cancellation to exercise the runner's post-export checkpoint.
        try FileManager.default.copyItem(at: plan.sourceURL, to: destinationURL)
        return PDFExportResult(destinationURL: destinationURL, outputPageCount: 2)
    }
    func release() { continuation?.resume(); continuation = nil }
}
private actor RetriedAskProvider: AIProvider {
    nonisolated let backend = AIBackend.claudeCLI
    private var attempts = 0
    func execute(_ request: AIRequest, onEvent: @escaping @Sendable (AIEvent) -> Void) async throws -> AIResponse {
        if request.kind == .distil { return AIResponse(content: #"{"learningPoints":[]}"#) }
        attempts += 1
        if attempts == 1 {
            onEvent(.text("old partial")); try await Task.sleep(for: .milliseconds(20))
            throw AIError.transport("fixture stream interrupted")
        }
        onEvent(.text("new answer")); try await Task.sleep(for: .milliseconds(20))
        return AIResponse(content: "new answer")
    }
}

@Suite struct JobRunnerTests {
    private func setup() async throws -> (LibraryStore, Module, Lecture, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lectern-job-tests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let pdf = root.appendingPathComponent("test.pdf")
        var box = CGRect(x: 0, y: 0, width: 400, height: 300)
        let context = try #require(CGContext(pdf as CFURL, mediaBox: &box, nil))
        for _ in 0..<2 { context.beginPDFPage(nil); context.setFillColor(CGColor(gray: 0.5, alpha: 1)); context.fill(CGRect(x: 10, y: 10, width: 50, height: 50)); context.endPDFPage() }
        context.closePDF()
        let store = LibraryStore(rootURL: root.appendingPathComponent("library"))
        let module = try await store.createModule(name: "Statistics", instructions: "Test interpretations.")
        let lecture = try await store.importPDF(from: pdf, moduleID: module.id)
        return (store, module, lecture, root)
    }
    @Test func cancellingDuringSnapshotPreparationNeverQueuesOrCallsProvider() async throws {
        let (store, module, lecture, root) = try await setup(); defer { try? FileManager.default.removeItem(at: root) }
        let gate = PreparationGateExporter(); let provider = FakeAIProvider(responses: [])
        let runner = JobRunner(store: store, providers: [provider], pdfExporter: gate)
        let task = Task { try await runner.generate(moduleID: module.id, lectureID: lecture.id) }
        for _ in 0..<100 { if await gate.started { break }; try await Task.sleep(for: .milliseconds(5)) }
        #expect(await gate.started)
        task.cancel(); await gate.release()
        await #expect(throws: CancellationError.self) { try await task.value }
        await runner.waitUntilIdle()
        #expect(await provider.requests.isEmpty)
        #expect(try await store.loadLecture(moduleID: module.id, lectureID: lecture.id).jobs.isEmpty)
        let directory = store.sourceURL(moduleID: module.id, lectureID: lecture.id).deletingLastPathComponent().appendingPathComponent("jobs")
        #expect(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).isEmpty)
    }
    @Test func archiveRacingSnapshotPreparationPreventsInferenceAndCleansSnapshot() async throws {
        let (store, module, lecture, root) = try await setup(); defer { try? FileManager.default.removeItem(at: root) }
        let gate = PreparationGateExporter(); let provider = FakeAIProvider(responses: [])
        let runner = JobRunner(store: store, providers: [provider], pdfExporter: gate)
        let task = Task { try await runner.generate(moduleID: module.id, lectureID: lecture.id) }
        for _ in 0..<100 { if await gate.started { break }; try await Task.sleep(for: .milliseconds(5)) }
        #expect(await gate.started)
        _ = try await store.setModuleArchived(moduleID: module.id, archived: true)
        await gate.release()
        await #expect(throws: LibraryError.self) { try await task.value }
        await runner.waitUntilIdle()
        #expect(await provider.requests.isEmpty)
        #expect(try await store.loadLecture(moduleID: module.id, lectureID: lecture.id).jobs.isEmpty)
        let directory = store.jobDirectory(moduleID: module.id, lectureID: lecture.id, jobID: UUID()).deletingLastPathComponent()
        #expect(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).isEmpty)
    }
    @Test func retryClearsPartialAskTextFromPreviousAttempt() async throws {
        let (store, module, lecture, root) = try await setup(); defer { try? FileManager.default.removeItem(at: root) }
        let runner = JobRunner(store: store, providers: [RetriedAskProvider()])
        let id = try await runner.ask(moduleID: module.id, lectureID: lecture.id, anchorPage: 1, question: "Why?")
        await runner.waitUntilIdle()
        #expect(await runner.currentProgress().first(where: { $0.jobID == id })?.streamedText == "old partial")
        try await runner.retry(moduleID: module.id, lectureID: lecture.id, jobID: id); await runner.waitUntilIdle()
        #expect(await runner.currentProgress().first(where: { $0.jobID == id })?.streamedText == "new answer")
    }
    @Test func proposeUpdatesSkipsExistingProposalsAndRecordsConsumedPoints() async throws {
        let (store, module, lecture, root) = try await setup(); defer { try? FileManager.default.removeItem(at: root) }
        let first = Card(sourcePages: [1], front: "First?", back: "One.")
        var second = Card(sourcePages: [1], front: "Second?", back: "Two.")
        second.proposal = Proposal(jobID: UUID(), baseRevisionID: second.currentRevisionID!, cards: [CardDraft(front: "Existing?", back: "Proposal.", sourcePages: [1])])
        let point = LearningPoint(text: "Test the interpretation.", pages: [1])
        let frozenSecond = second
        _ = try await store.updateLecture(moduleID: module.id, lectureID: lecture.id) { value in
            value.cards = [first, frozenSecond]; value.threads = [SlideThread(anchorPage: 1, learningPoints: [point])]
        }
        let fake = FakeAIProvider(responses: [AIResponse(content: #"{"cards":[{"front":"Interpret?","back":"Interpretation.","sourceSlides":[1],"flag":null}],"rationale":"Uses point."}"#)])
        let runner = JobRunner(store: store, providers: [fake])
        let result = try await runner.proposeUpdates(moduleID: module.id, lectureID: lecture.id, page: 1)
        await runner.waitUntilIdle()
        #expect(result.jobIDs.count == 1); #expect(result.skippedCardIDs == [second.id]); #expect(result.failures.isEmpty)
        let saved = try await store.loadLecture(moduleID: module.id, lectureID: lecture.id)
        #expect(saved.threads[0].learningPoints[0].usedBy == result.jobIDs)
        #expect(saved.cards[1].proposal == second.proposal)
    }

    @Test func generationSnapshotPreservesEditsAndDoesNotSwitchModeOrApprove() async throws {
        let (store, module, lecture, root) = try await setup(); defer { try? FileManager.default.removeItem(at: root) }
        let provider = GateProvider()
        let jobs = JobRunner(store: store, providers: [provider])
        let id = try await jobs.generate(moduleID: module.id, lectureID: lecture.id)
        _ = try await store.updateLecture(moduleID: module.id, lectureID: lecture.id) { value in value.slides[0].note = "Edited while generating" }
        await provider.release(); await jobs.waitUntilIdle()
        let saved = try await store.loadLecture(moduleID: module.id, lectureID: lecture.id)
        #expect(saved.cards.count == 1); #expect(saved.cards[0].verdict == .unreviewed)
        #expect(saved.jobs.first?.id == id); #expect(saved.jobs.first?.state == .succeeded)
        #expect(saved.slides[0].note == "Edited while generating"); #expect(saved.viewPreferences.mode == .prepare)
        #expect(saved.skippedSlides.contains { $0.slide == 2 })
        let snapshot = try String(contentsOf: store.jobDirectory(moduleID: module.id, lectureID: lecture.id, jobID: id).appendingPathComponent("snapshot.json"), encoding: .utf8)
        #expect(!snapshot.contains("Edited while generating"))
    }
    @Test func cancelCannotLandAndRetryReusesOneJob() async throws {
        let (store, module, lecture, root) = try await setup(); defer { try? FileManager.default.removeItem(at: root) }
        let gate = GateProvider(); let runner = JobRunner(store: store, providers: [gate])
        let id = try await runner.generate(moduleID: module.id, lectureID: lecture.id)
        try await runner.cancel(moduleID: module.id, lectureID: lecture.id, jobID: id)
        await runner.waitUntilIdle()
        var saved = try await store.loadLecture(moduleID: module.id, lectureID: lecture.id)
        #expect(saved.cards.isEmpty); #expect(saved.jobs[0].state == .cancelled)
        await gate.release(); try await runner.retry(moduleID: module.id, lectureID: lecture.id, jobID: id); await runner.waitUntilIdle()
        saved = try await store.loadLecture(moduleID: module.id, lectureID: lecture.id)
        #expect(saved.jobs.count == 1); #expect(saved.jobs[0].state == .succeeded); #expect(saved.cards.count == 1)
        await #expect(throws: (any Error).self) { try await runner.retry(moduleID: module.id, lectureID: lecture.id, jobID: id) }
        try await runner.cancel(moduleID: module.id, lectureID: lecture.id, jobID: id)
        #expect(try await store.loadLecture(moduleID: module.id, lectureID: lecture.id).jobs[0].state == .succeeded)
    }
    @Test func concurrentRetryStartsOnlyOneProviderCall() async throws {
        let (store, module, lecture, root) = try await setup(); defer { try? FileManager.default.removeItem(at: root) }
        let gate = GateProvider(); let runner = JobRunner(store: store, providers: [gate])
        let id = try await runner.generate(moduleID: module.id, lectureID: lecture.id)
        try await runner.cancel(moduleID: module.id, lectureID: lecture.id, jobID: id); await runner.waitUntilIdle()
        let before = await gate.count()
        let outcomes = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<2 { group.addTask {
                do { try await runner.retry(moduleID: module.id, lectureID: lecture.id, jobID: id); return true }
                catch { return false }
            } }
            var result: [Bool] = []; for await outcome in group { result.append(outcome) }; return result
        }
        #expect(outcomes.filter { $0 }.count == 1)
        await gate.release(); await runner.waitUntilIdle()
        #expect(await gate.count() == before + 1)
        #expect(try await store.loadLecture(moduleID: module.id, lectureID: lecture.id).cards.count == 1)
    }
    @Test func malformedResponseFailsAtomicallyAndRecoveryMarksRunningInterrupted() async throws {
        let (store, module, lecture, root) = try await setup(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeAIProvider(responses: [AIResponse(content: "not json")])
        let jobs = JobRunner(store: store, providers: [fake])
        _ = try await jobs.generate(moduleID: module.id, lectureID: lecture.id); await jobs.waitUntilIdle()
        var saved = try await store.loadLecture(moduleID: module.id, lectureID: lecture.id)
        #expect(saved.cards.isEmpty); #expect(saved.jobs[0].state == .failed)
        _ = try await store.updateLecture(moduleID: module.id, lectureID: lecture.id) { value in value.jobs.append(Job(kind: .generate, pages: [1])) }
        let freshRunner = JobRunner(store: store, providers: [fake]); #expect(try await freshRunner.recoverInterruptedJobs() == 1)
        saved = try await store.loadLecture(moduleID: module.id, lectureID: lecture.id)
        #expect(saved.jobs[1].state == .interrupted)
    }
    @Test func askSharesThreadThenDistilsWithoutAutoCreatingCards() async throws {
        let (store, module, lecture, root) = try await setup(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeAIProvider(responses: [AIResponse(content: "It adds uncertainty [slide 1]."), AIResponse(content: #"{"learningPoints":[{"text":"Estimated variance adds uncertainty.","pages":[1]}]}"#)])
        let jobs = JobRunner(store: store, providers: [fake])
        _ = try await jobs.ask(moduleID: module.id, lectureID: lecture.id, anchorPage: 1, question: "Why thicker tails?")
        await jobs.waitUntilIdle()
        let saved = try await store.loadLecture(moduleID: module.id, lectureID: lecture.id)
        #expect(saved.cards.isEmpty); #expect(saved.threads.count == 1); #expect(saved.threads[0].messages.count == 2)
        #expect(saved.threads[0].messages[1].citedPages == [1]); #expect(saved.threads[0].learningPoints.count == 1)
        #expect(saved.jobs.count == 2); #expect(saved.jobs.allSatisfy { $0.state == .succeeded })
        let extraction = try #require(saved.jobs.first { $0.kind == .distil })
        #expect(extraction.model == "sonnet")
        let requests = await fake.requests
        #expect(requests.map(\.model) == ["opus", "sonnet"])
        #expect(!requests[0].prompt.contains("GLOBAL CARD RULES"))
        #expect(!requests[1].prompt.contains("GLOBAL CARD RULES"))
    }
    @Test func cardAskExtractsPointsButRevisionDoesNotAndAPIDistilAlwaysUsesSonnet() async throws {
        let (store, module, lecture, root) = try await setup(); defer { try? FileManager.default.removeItem(at: root) }
        let card = Card(sourcePages: [1], front: "Why?", back: "Because.")
        _ = try await store.updateLecture(moduleID: module.id, lectureID: lecture.id) { $0.cards = [card] }
        let fake = FakeAIProvider(responses: [
            AIResponse(content: "Explanation [slide 1]."),
            AIResponse(content: #"{"learningPoints":[]}"#),
            AIResponse(content: #"{"cards":[{"front":"Clearer?","back":"Yes.","sourceSlides":[1],"flag":null}],"rationale":"Clarified."}"#),
            AIResponse(content: #"{"learningPoints":[]}"#)
        ], backend: .messagesAPI)
        let runner = JobRunner(store: store, providers: [fake])
        _ = try await runner.ask(moduleID: module.id, lectureID: lecture.id, anchorPage: 1,
            question: "Explain this card", cardID: card.id, backend: .messagesAPI)
        await runner.waitUntilIdle()
        _ = try await runner.revise(moduleID: module.id, lectureID: lecture.id, cardID: card.id,
            feedback: "Clarify", backend: .messagesAPI)
        await runner.waitUntilIdle()
        let requests = await fake.requests
        #expect(requests.map(\.kind) == [.ask, .distil, .revise])
        #expect(requests[1].model == "claude-sonnet-5-5")
        #expect(requests[0].prompt.contains("CURRENT CARD"))
        #expect(!requests[0].prompt.contains("GLOBAL CARD RULES"))
        #expect(requests[2].prompt.contains("GLOBAL CARD RULES"))
        _ = try await runner.distil(moduleID: module.id, lectureID: lecture.id, anchorPage: 1,
            backend: .messagesAPI, model: "claude-opus-5-5")
        await runner.waitUntilIdle()
        #expect(await fake.requests.last?.model == "claude-sonnet-5-5")
    }

    @Test func revisionBasesProposalOnSnapshotAfterManualEdit() async throws {
        let (store, module, lecture, root) = try await setup(); defer { try? FileManager.default.removeItem(at: root) }
        let card = Card(sourcePages: [1], front: "Original front", back: "Original back")
        _ = try await store.updateLecture(moduleID: module.id, lectureID: lecture.id) { $0.cards = [card] }
        let fake = FakeAIProvider(responses: [AIResponse(content: #"{"cards":[{"front":"Better front","back":"Better back","sourceSlides":[1],"flag":null}],"rationale":"Clarified."}"#)])
        let jobs = JobRunner(store: store, providers: [fake])
        _ = try await jobs.revise(moduleID: module.id, lectureID: lecture.id, cardID: card.id, feedback: "Simplify")
        // Whether the provider has landed yet or not, subsequent manual edits must be retained.
        _ = try await store.updateLecture(moduleID: module.id, lectureID: lecture.id) { value in
            try LectureReducer.reduce(&value, action: .commitEdit(cardID: card.id, front: "Manual front", back: "Manual back", sourcePages: [1]))
        }
        await jobs.waitUntilIdle()
        let saved = try await store.loadLecture(moduleID: module.id, lectureID: lecture.id)
        #expect(saved.cards[0].front == "Manual front"); #expect(saved.cards[0].proposalIsStale)
        #expect(saved.cards[0].proposal?.cards[0].front == "Better front")
    }
    @Test func globalConcurrencyIsThreeAndOnlyOneGeneratePerLecture() async throws {
        let (store, module, lecture, root) = try await setup(); defer { try? FileManager.default.removeItem(at: root) }
        let gate = GateProvider()
        let runner = JobRunner(store: store, providers: [gate])
        _ = try await runner.generate(moduleID: module.id, lectureID: lecture.id)
        await #expect(throws: (any Error).self) { try await runner.generate(moduleID: module.id, lectureID: lecture.id) }
        let jobFolders = try FileManager.default.contentsOfDirectory(at: store.sourceURL(moduleID: module.id, lectureID: lecture.id).deletingLastPathComponent().appendingPathComponent("jobs"), includingPropertiesForKeys: nil)
        #expect(jobFolders.count == 1) // Rejected preparation must not retain an orphan PDF/prompt.
        for i in 1...4 {
            let next = try await store.createLecture(Lecture(moduleID: module.id, name: "Lecture \(i)", sourceFilename: "source.pdf", pageCount: 2), sourceURL: store.sourceURL(moduleID: module.id, lectureID: lecture.id))
            _ = try await runner.generate(moduleID: module.id, lectureID: next.id)
        }
        #expect(await gate.count() <= 3)
        await gate.release(); await runner.waitUntilIdle()
        #expect(await gate.maximum <= 3); #expect(await gate.count() == 5)
    }
}
