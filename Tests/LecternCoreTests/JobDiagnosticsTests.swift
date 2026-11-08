import Foundation
import Testing
@testable import LecternCore

private actor DiagnosticsFixtureProvider: AIProvider {
    nonisolated let backend = AIBackend.claudeCLI
    private var responses: [AIResponse]

    init(responses: [AIResponse]) { self.responses = responses }

    func execute(_ request: AIRequest, onEvent: @escaping @Sendable (AIEvent) -> Void) async throws -> AIResponse {
        try Task.checkCancellation()
        onEvent(.stage("Fixture provider started"))
        guard !responses.isEmpty else { throw AIError.configuration("No diagnostics fixture response remains.") }
        return responses.removeFirst()
    }
}

@Suite struct JobDiagnosticsTests {
    private func fixture() async throws -> (LibraryStore, Module, Lecture, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lectern-job-diagnostics-\(UUID())")
        let store = LibraryStore(rootURL: root.appendingPathComponent("library"))
        let module = try await store.createModule(name: "Diagnostics")
        let lecture = try await store.createLecture(Lecture(moduleID: module.id, name: "Empty lecture"))
        return (store, module, lecture, root)
    }

    private func attempts(store: LibraryStore, moduleID: UUID, lectureID: UUID, jobID: UUID) throws -> [(URL, [String: Any])] {
        let root = store.jobDirectory(moduleID: moduleID, lectureID: lectureID, jobID: jobID).appendingPathComponent("ai-logs", isDirectory: true)
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { directory in
                let data = try Data(contentsOf: directory.appendingPathComponent("summary.json"))
                let summary = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
                return (directory, summary)
            }
    }

    private func linksToTrace(_ message: String?, directory: URL) -> Bool {
        guard let message, let marker = message.range(of: "AI diagnostics: "),
              let path = message[marker.upperBound...].split(separator: "\n").first else { return false }
        // macOS exposes the same temporary directory through /var and /private/var.
        return URL(fileURLWithPath: String(path)).resolvingSymlinksInPath().path == directory.resolvingSymlinksInPath().path
    }

    @Test func malformedProviderResponseIsCapturedWithDecodeContextAndJobLogPath() async throws {
        let (store, module, lecture, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = JobRunner(store: store, providers: [DiagnosticsFixtureProvider(responses: [AIResponse(content: "not JSON")])])

        let jobID = try await runner.chat(moduleID: module.id, lectureID: lecture.id, question: "Explain this", contextRefs: [])
        await runner.waitUntilIdle()

        let saved = try await store.loadLecture(moduleID: module.id, lectureID: lecture.id)
        let job = try #require(saved.jobs.first(where: { $0.id == jobID }))
        #expect(job.state == .failed)
        let logs = try attempts(store: store, moduleID: module.id, lectureID: lecture.id, jobID: jobID)
        let summary = try #require(logs.first?.1)
        #expect(summary["status"] as? String == "failed")
        #expect(summary["failurePhase"] as? String == "response_validation")
        let error = try #require(summary["error"] as? [String: Any])
        #expect(error["codingPath"] is [String])
        #expect(error["debugDescription"] as? String != nil)
        let response = try String(contentsOf: logs[0].0.appendingPathComponent("runner-response.json"), encoding: .utf8)
        #expect(response.contains("not JSON"))
        #expect(linksToTrace(job.error, directory: logs[0].0))
    }

    @Test func retryCreatesANewAttemptAndKeepsTheFailedTrace() async throws {
        let (store, module, lecture, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let chatReply = try String(decoding: JSONEncoder().encode(ChatReply(message: "Answer")), as: UTF8.self)
        let provider = DiagnosticsFixtureProvider(responses: [
            AIResponse(content: "not JSON"),
            AIResponse(content: chatReply),
            AIResponse(content: #"{"learningPoints":[],"summary":""}"#)
        ])
        let runner = JobRunner(store: store, providers: [provider])

        let jobID = try await runner.chat(moduleID: module.id, lectureID: lecture.id, question: "Explain this", contextRefs: [])
        await runner.waitUntilIdle()
        try await runner.retry(moduleID: module.id, lectureID: lecture.id, jobID: jobID)
        await runner.waitUntilIdle()

        let logs = try attempts(store: store, moduleID: module.id, lectureID: lecture.id, jobID: jobID)
        #expect(logs.count == 2)
        let statuses = logs.compactMap { $0.1["status"] as? String }.sorted()
        #expect(statuses == ["failed", "succeeded"])
        #expect(logs[0].0 != logs[1].0)
        let saved = try await store.loadLecture(moduleID: module.id, lectureID: lecture.id)
        #expect(saved.jobs.first(where: { $0.id == jobID })?.state == .succeeded)
    }

    @Test func backgroundLectureChatDistilFailureHasItsOwnTraceAndParentLink() async throws {
        let (store, module, lecture, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let chatReply = try String(decoding: JSONEncoder().encode(ChatReply(message: "Answer")), as: UTF8.self)
        let provider = DiagnosticsFixtureProvider(responses: [
            AIResponse(content: chatReply),
            AIResponse(content: "not JSON")
        ])
        let runner = JobRunner(store: store, providers: [provider])

        let parentID = try await runner.chat(moduleID: module.id, lectureID: lecture.id, question: "Explain this", contextRefs: [])
        await runner.waitUntilIdle()

        let saved = try await store.loadLecture(moduleID: module.id, lectureID: lecture.id)
        #expect(saved.jobs.first(where: { $0.id == parentID })?.state == .succeeded)
        let distil = try #require(saved.jobs.first(where: { $0.id != parentID && $0.kind == .distil }))
        #expect(distil.state == .failed)
        let logs = try attempts(store: store, moduleID: module.id, lectureID: lecture.id, jobID: distil.id)
        let summary = try #require(logs.first?.1)
        #expect(summary["status"] as? String == "failed")
        #expect(summary["failurePhase"] as? String == "response_validation")
        let events = try String(contentsOf: logs[0].0.appendingPathComponent("events.jsonl"), encoding: .utf8)
        #expect(events.contains(parentID.uuidString))
        #expect(linksToTrace(distil.error, directory: logs[0].0))
        let progress = await runner.currentProgress()
        #expect(linksToTrace(progress.first(where: { $0.jobID == parentID })?.warning, directory: logs[0].0))
    }
}
