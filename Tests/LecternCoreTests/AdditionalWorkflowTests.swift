import Foundation
import PDFKit
import Testing
@testable import LecternCore

@Suite struct AdditionalWorkflowTests {
    @Test func legacySourcelessSplitChildrenCanBeReviewed() throws {
        let module = Module(name: "Imported")
        let card = Card(front: "Combined?", back: "Two concepts")
        var lecture = Lecture(moduleID: module.id, name: "Legacy", cards: [card])
        let job = Job(kind: .revise, pages: [], targetCardID: card.id, baseRevisionID: card.currentRevisionID)
        try LectureReducer.reduce(&lecture, action: .startJob(job))
        try LectureReducer.reduce(&lecture, action: .landProposal(jobID: job.id,
            cards: [CardDraft(front: "First?", back: "First."), CardDraft(front: "Second?", back: "Second.")], rationale: "Split concepts.", usage: nil))
        try LectureReducer.reduce(&lecture, action: .acceptProposal(cardID: card.id, approve: true))
        #expect(lecture.cards.dropFirst().allSatisfy { $0.verdict == .unreviewed })
        try LectureReducer.reduce(&lecture, action: .setVerdict(cardID: lecture.cards[1].id, .good))
        #expect(lecture.cards[1].verdict == .good)
    }
    @Test func moduleBackupRestoresOrderPDFAndSourcelessLectureAtomically() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lectern-module-backup-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(rootURL: root.appendingPathComponent("source"))
        let module = try await store.createModule(name: "M", instructions: "Interpretation.")
        let pdf = PDFDocument(); pdf.insert(PDFPage(), at: 0)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.pdf"); #expect(pdf.write(to: source))
        let first = try await store.importPDF(from: source, moduleID: module.id)
        let second = try await store.createLecture(Lecture(moduleID: module.id, name: "Legacy", cards: [Card(front: "Q", back: "A")]))
        var reordered = module; reordered.lectureIDs = [second.id, first.id]; try await store.updateModule(reordered)
        let output = root.appendingPathComponent("module.json")
        try await store.exportModuleBackup(moduleID: module.id, to: output)
        let restored = LibraryStore(rootURL: root.appendingPathComponent("restored"))
        let result = try await restored.restoreModuleBackup(from: output)
        #expect(result.lectureIDs == reordered.lectureIDs)
        #expect(try await restored.lectures(in: module.id).map(\.id) == reordered.lectureIDs)
        #expect(PDFDocument(url: restored.sourceURL(moduleID: module.id, lectureID: first.id))?.pageCount == 1)
        await #expect(throws: LibraryError.self) { try await restored.restoreModuleBackup(from: output) }
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: output)) as? [String: Any])
        var lectures = try #require(object["lectures"] as? [[String: Any]])
        for i in lectures.indices { lectures[i].removeValue(forKey: "sourcePDF") }
        object["lectures"] = lectures
        let broken = root.appendingPathComponent("broken.json"); try JSONSerialization.data(withJSONObject: object).write(to: broken)
        let rejected = LibraryStore(rootURL: root.appendingPathComponent("rejected"))
        await #expect(throws: LibraryError.self) { try await rejected.restoreModuleBackup(from: broken) }
        #expect(try await rejected.modules().isEmpty)
    }
    @Test func changedTextNeverReusesAnOldAmbiguousMathDecision() throws {
        let card = Card(front: "Amount?", back: "Value $hello world$", mathInterpretations: ["$hello world$": .keepAsText])
        var lecture = Lecture(moduleID: UUID(), name: "L", cards: [card])
        try LectureReducer.reduce(&lecture, action: .commitEdit(cardID: card.id, front: "Variable?", back: "Value $hello world$", sourcePages: []))
        #expect(lecture.cards[0].mathInterpretations.isEmpty)
        #expect(lecture.issues(for: lecture.cards[0]).contains { $0.kind == .unresolvedMath })
        try LectureReducer.reduce(&lecture, action: .setMathInterpretation(cardID: card.id, span: "$hello world$", .keepAsText))
        try LectureReducer.reduce(&lecture, action: .restoreOriginal(cardID: card.id))
        #expect(lecture.cards[0].mathInterpretations.isEmpty)
        let job = Job(kind: .revise, pages: [], targetCardID: card.id, baseRevisionID: lecture.cards[0].currentRevisionID)
        try LectureReducer.reduce(&lecture, action: .startJob(job))
        try LectureReducer.reduce(&lecture, action: .setMathInterpretation(cardID: card.id, span: "$hello world$", .keepAsText))
        try LectureReducer.reduce(&lecture, action: .landProposal(jobID: job.id, cards: [CardDraft(front: "Meaning?", back: "Value $hello world$")], rationale: "Clarify", usage: nil))
        try LectureReducer.reduce(&lecture, action: .acceptProposal(cardID: card.id, approve: false))
        #expect(lecture.cards[0].mathInterpretations.isEmpty)
    }
    @Test func pricingSeparatesReportedEstimatedAndUnknownCosts() {
        let usage = AIUsage(inputTokens: 1000, outputTokens: 100, cacheCreationInputTokens: 200, cacheReadInputTokens: 300)
        #expect(abs((APIPricing.estimatedUSD(usage: usage, model: "claude-opus-5-5") ?? 0) - 0.00506) < 0.00000001)
        let jobs = [
            Job(kind: .ask, pages: [1], backend: .messagesAPI, state: .succeeded, usage: usage, model: "claude-opus-5-5"),
            Job(kind: .ask, pages: [1], backend: .messagesAPI, state: .succeeded, usage: AIUsage(costUSD: 0.03)),
            Job(kind: .ask, pages: [1], backend: .messagesAPI, state: .failed),
            Job(kind: .ask, pages: [1], backend: .claudeCLI, state: .succeeded, usage: AIUsage(costUSD: 999))
        ]
        let summary = APIPricing.summarize(jobs)
        #expect(summary.reportedUSD == 0.03); #expect(summary.unpricedJobs == 1)
        #expect(abs(summary.totalUSD - 0.03506) < 0.00000001)
    }
    @Test func snapshotsExpireForAllTerminalJobsAndRetryExplainsExpiry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lectern-expiry-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(rootURL: root)
        let module = try await store.createModule(name: "M")
        let jobs = [JobState.succeeded, .failed, .cancelled, .interrupted].map { state in Job(kind: .revise, pages: [], state: state, startedAt: .distantPast, finishedAt: .distantPast) }
        let lecture = try await store.createLecture(Lecture(moduleID: module.id, name: "L", jobs: jobs))
        for job in jobs {
            let directory = store.jobDirectory(moduleID: module.id, lectureID: lecture.id, jobID: job.id)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("private snapshot".utf8).write(to: directory.appendingPathComponent("input.pdf"))
        }
        let runner = JobRunner(store: store, providers: [FakeAIProvider(responses: [])])
        try await runner.cleanSnapshots()
        #expect(jobs.allSatisfy { !FileManager.default.fileExists(atPath: store.jobDirectory(moduleID: module.id, lectureID: lecture.id, jobID: $0.id).path) })
        do { try await runner.retry(moduleID: module.id, lectureID: lecture.id, jobID: jobs[1].id); Issue.record("Expired retry should fail") }
        catch { #expect(error.localizedDescription.contains("expired")) }
    }
}
