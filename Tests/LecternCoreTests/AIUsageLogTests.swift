import Foundation
import Synchronization
import Testing
@testable import LecternCore

@Suite(.serialized) struct AIUsageLogTests {
    private func fixture() throws -> (URL, AIRequest) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lectern-usage-\(UUID())")
        let id = UUID(), directory = root.appendingPathComponent("jobs/\(id)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: root.appendingPathComponent("lecture.json"))
        var request = AIRequest(jobID: id, kind: .distil, model: "sonnet", prompt: "Study data", pdf: nil, workingDirectory: directory)
        request.diagnosticContext = ["feature": "learningPointsV2", "purpose": "preparePoints", "trigger": "clicked"]
        return (root, request)
    }

    @Test func failedValidationRetainsUsageAndCountersInOneDurableAttempt() async throws {
        let (root, request) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        do {
            try await AIDiagnostics.withTrace(request: request, backend: .claudeCLI) { trace in
                trace.registerSecret("super-secret-study-key")
                trace.providerCallStarted()
                trace.setMetadata(["pointsRejected": 2, "privateValue": "super-secret-study-key"])
                trace.recordUsage(AIUsage(inputTokens: 123, outputTokens: 45, cacheReadInputTokens: 100))
                throw AIError.invalidResponse("Invalid evidence")
            }
        } catch { }
        let records = try AIUsageLedger.read(from: root.appendingPathComponent("ai-usage.jsonl"))
        #expect(records.count == 1)
        let record = try #require(records.first)
        #expect(record.status == "failed"); #expect(record.providerCalls == 1)
        #expect(record.usage?.inputTokens == 123); #expect(record.usage?.outputTokens == 45)
        #expect(record.context["trigger"] == "clicked")
        #expect(record.details["pointsRejected"] == "2")
        #expect(!String(decoding: try Data(contentsOf: root.appendingPathComponent("ai-usage.jsonl")), as: UTF8.self).contains("super-secret-study-key"))
        let summary = AIUsageSummary.summarize(records: records, learningPointsOnly: true)
        #expect(summary.attempts == 1); #expect(summary.failed == 1); #expect(summary.pointsRejected == 2)
    }

    @Test func skippedChecksAreNotCallsAndUnreportedCallsAreUnknown() async throws {
        let (root, request) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        AIDiagnostics.recordSkipped(jobID: UUID(), backend: .claudeCLI, kind: .distil, model: "sonnet", workingDirectory: request.workingDirectory, context: request.diagnosticContext!, reason: "awaiting_student_reaction")
        try await AIDiagnostics.withTrace(request: request, backend: .claudeCLI) { trace in
            trace.providerCallStarted()
            trace.response(AIResponse(content: "{}"))
        }
        let records = try AIUsageLedger.read(from: root.appendingPathComponent("ai-usage.jsonl"))
        let summary = AIUsageSummary.summarize(records: records)
        #expect(summary.skipped == 1); #expect(summary.attempts == 1)
        #expect(summary.providerCalls == 1); #expect(summary.missingUsage == 1); #expect(summary.inputTokens == 0)
    }

    @Test func partialUsageReplacesWithinRoundsAndAddsAcrossRounds() async throws {
        let (root, request) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try await AIDiagnostics.withTrace(request: request, backend: .messagesAPI) { trace in
            trace.recordUsage(AIUsage(inputTokens: 100, outputTokens: 1), round: "http-01")
            trace.recordUsage(AIUsage(inputTokens: 100, outputTokens: 5), round: "http-01")
            trace.recordUsage(AIUsage(inputTokens: 120, outputTokens: 7), round: "http-02")
        }
        let records = try AIUsageLedger.read(from: root.appendingPathComponent("ai-usage.jsonl"))
        #expect(records.first?.usage?.inputTokens == 220); #expect(records.first?.usage?.outputTokens == 12)
    }

    @Test func partialMultiCallUsageRemainsUnknownAndUnpriced() async throws {
        let (root, request) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        do {
            try await AIDiagnostics.withTrace(request: request, backend: .messagesAPI) { trace in
                trace.providerCallStarted()
                trace.recordUsage(AIUsage(inputTokens: 100, outputTokens: 5), round: "http-01", reported: true)
                trace.providerCallStarted()
                throw AIError.transport("Second round failed before usage")
            }
        } catch { }
        let records = try AIUsageLedger.read(from: root.appendingPathComponent("ai-usage.jsonl"))
        let summary = AIUsageSummary.summarize(records: records)
        #expect(summary.providerCalls == 2); #expect(summary.inputTokens == 100)
        #expect(summary.missingUsage == 1)
        #expect(records.first?.usageReportedCalls == 1)
        #expect(APIPricing.summarize([], records: records).unpricedJobs == 1)
    }

    @Test func explicitlyReportedZeroIsKnownAndSkippedMetadataIsRedacted() async throws {
        let (root, request) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try await AIDiagnostics.withTrace(request: request, backend: .claudeCLI) { trace in
            trace.providerCallStarted()
            trace.recordUsage(AIUsage(), reported: true)
            trace.response(AIResponse(content: "{}"))
        }
        AIDiagnostics.recordSkipped(jobID: UUID(), backend: .claudeCLI, kind: .distil, model: "sonnet",
            workingDirectory: request.workingDirectory, context: ["apiKey": "sensitive-test-key"], reason: "Bearer sensitive-test-token")
        let url = root.appendingPathComponent("ai-usage.jsonl")
        let records = try AIUsageLedger.read(from: url)
        #expect(AIUsageSummary.summarize(records: records).missingUsage == 0)
        #expect(records.first { $0.status == "succeeded" }?.usage == AIUsage())
        let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        #expect(!text.contains("sensitive-test-key")); #expect(!text.contains("sensitive-test-token"))
    }

    @Test func truncatedRecordDoesNotHideLaterRecordsAndRetriesAreCountedOnce() throws {
        let (root, request) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("ai-usage.jsonl")
        try Data("{\"unfinished\":".utf8).write(to: url)
        let a = AIUsageAttempt(jobID: request.jobID, backend: .messagesAPI, model: "unknown-model", kind: .distil, status: "failed", providerCalls: 1, usage: AIUsage(inputTokens: 10, outputTokens: 2))
        var b = a; b.id = UUID().uuidString; b.status = "succeeded"; b.usage = AIUsage(inputTokens: 20, outputTokens: 3)
        try AIUsageLedger.append(a, workingDirectory: request.workingDirectory); try AIUsageLedger.append(b, workingDirectory: request.workingDirectory)
        let records = try AIUsageLedger.read(from: url); #expect(records.count == 2)
        var job = Job(id: request.jobID, kind: .distil, pages: [], backend: .messagesAPI); job.usage = b.usage
        let summary = AIUsageSummary.summarize(records: records + records, legacyJobs: [job])
        #expect(summary.attempts == 2); #expect(summary.providerCalls == 2)
        #expect(summary.inputTokens == 30); #expect(summary.outputTokens == 5)
        let cost = APIPricing.summarize([job], records: records)
        #expect(cost.inputTokens == 30); #expect(cost.unpricedJobs == 2)
    }

    @Test func claudeNonzeroExitRetainsReportedUsage() async throws {
        let (root, request) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let cli = root.appendingPathComponent("fake-claude")
        let script = #"""
        #!/bin/sh
        if [ "$1" = "auth" ]; then
          printf '%s\n' '{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","subscriptionType":"max"}'
          exit 0
        fi
        cat > /dev/null
        printf '%s\n' '{"type":"result","is_error":true,"errors":["provider failed"],"usage":{"input_tokens":80,"output_tokens":9}}'
        exit 1
        """#
        try Data(script.utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        do { _ = try await ClaudeCLIProvider(executableURL: cli).execute(request) { _ in }; Issue.record("Expected failure") } catch { }
        let records = try AIUsageLedger.read(from: root.appendingPathComponent("ai-usage.jsonl"))
        #expect(records.first?.status == "failed")
        #expect(records.first?.providerCalls == 1)
        #expect(records.first?.usage?.inputTokens == 80)
        #expect(records.first?.usage?.outputTokens == 9)
        #expect(AIUsageSummary.summarize(records: records).missingUsage == 0)
    }

    @Test func messagesAPISendsPrepareAndReviewSchemasAndKeepsUsageOnTruncation() async throws {
        let (root, request) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [UsageAuditURLProtocol.self]
        let provider = MessagesAPIProvider(apiKey: { "fake-test-key" }, session: URLSession(configuration: config), endpoint: URL(string: "https://usage.example.test/v1/messages")!)
        for schemaText in [AIOutputSchema.chatDistillation, AIOutputSchema.reviewDistillation] {
            var input = request; input.jobID = UUID(); input.outputSchemaOverride = schemaText
            _ = try await provider.execute(input) { _ in }
            let data = try #require(UsageAuditURLProtocol.body.withLock { $0 })
            let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let output = try #require(body["output_config"] as? [String: Any]), format = try #require(output["format"] as? [String: Any])
            let schema = try #require(format["schema"] as? [String: Any]), props = try #require(schema["properties"] as? [String: Any])
            if schemaText == AIOutputSchema.reviewDistillation { #expect(props["suggestion"] != nil); #expect(props["learningPoints"] == nil) }
            else { #expect(props["closedThroughMessageID"] != nil) }
        }
        UsageAuditURLProtocol.truncated.withLock { $0 = true }; defer { UsageAuditURLProtocol.truncated.withLock { $0 = false } }
        do { _ = try await provider.execute(request) { _ in }; Issue.record("Expected a truncated response error") } catch { }
        let records = try AIUsageLedger.read(from: root.appendingPathComponent("ai-usage.jsonl"))
        let failed = try #require(records.first { $0.status == "failed" })
        #expect(failed.usage?.inputTokens == 50); #expect(failed.usage?.outputTokens == 20)
    }
}

private final class UsageAuditURLProtocol: URLProtocol {
    static let body = Mutex<Data?>(nil)
    static let truncated = Mutex(false)
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "usage.example.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var captured = request.httpBody
        if captured == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }; var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(contentsOf: buffer.prefix(n)) }; captured = data
        }
        Self.body.withLock { $0 = captured }
        let stop = Self.truncated.withLock { $0 } ? "max_tokens" : "end_turn"
        let data = Data("{\"content\":[{\"type\":\"text\",\"text\":\"{}\"}],\"stop_reason\":\"\(stop)\",\"usage\":{\"input_tokens\":50,\"output_tokens\":20}}".utf8)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["content-type":"application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
