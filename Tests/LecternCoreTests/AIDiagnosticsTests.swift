import Foundation
import Testing
@testable import LecternCore

struct AIDiagnosticsTests {
    @Test func exitOneKeepsInvocationFullErrorAndPrivateFiles() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let cli = try cli(in: root, output: """
        printf '%s\\n' '{"type":"system","subtype":"init","session_id":"session-example"}'
        printf '%s\\n' '{"type":"result","is_error":true,"errors":["provider unavailable"]}'
        printf '%s' '\(String(repeating: "detail ", count: 400))' >&2
        exit 1
        """)
        let request = request(in: root)
        do {
            _ = try await ClaudeCLIProvider(executableURL: cli).execute(request, onEvent: { _ in })
            Issue.record("Expected CLI failure")
        } catch let error as AIError { #expect(error == .transport("provider unavailable")) }
        let attempt = try #require(attempts(in: root).first)
        let summary = try json(attempt, "summary.json")
        #expect(summary["status"] as? String == "failed")
        #expect(summary["phase"] as? String == "cli_execution")
        #expect(summary["jobID"] as? String == request.jobID.uuidString)
        #expect(try json(attempt, "cli-exit.json")["terminationStatus"] as? Int == 1)
        #expect(try json(attempt, "cli-auth-exit.json")["terminationStatus"] as? Int == 0)
        #expect(try text(attempt, "cli-stderr.txt").count == 2_800)
        #expect(try text(attempt, "cli-stdout.txt").contains("session-example"))
        #expect(try text(attempt, "cli-stdin.txt") == request.prompt)
        #expect(try text(attempt, "cli-invocation.json").contains(request.systemPrompt))
        #expect(try text(attempt, "events.jsonl").contains("process_exited"))
        let mode = try FileManager.default.attributesOfItem(atPath: attempt.path)[.posixPermissions] as? Int
        #expect(mode == 0o700)
        for file in try FileManager.default.contentsOfDirectory(at: attempt, includingPropertiesForKeys: nil) {
            #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)
        }
    }

    @Test func malformedOutputAndRepeatedExecutionsRetainSeparateEvidence() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let cli = try cli(in: root, output: "printf '%s\\n' 'not-json'")
        let request = request(in: root)
        for _ in 0..<2 {
            await #expect(throws: AIError.self) {
                try await ClaudeCLIProvider(executableURL: cli).execute(request, onEvent: { _ in })
            }
        }
        let attempts = try attempts(in: root)
        #expect(attempts.count == 2)
        for attempt in attempts {
            #expect(try json(attempt, "summary.json")["phase"] as? String == "cli_parsing_response")
            #expect(try text(attempt, "cli-stdout.txt") == "not-json\n")
            #expect(try json(attempt, "cli-exit.json")["terminationStatus"] as? Int == 0)
        }
    }

    @Test func missingExecutableStillRecordsPreflightFailure() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        await #expect(throws: AIError.self) {
            try await ClaudeCLIProvider(executableURL: root.appendingPathComponent("missing")).execute(request(in: root), onEvent: { _ in })
        }
        let attempt = try #require(attempts(in: root).first)
        #expect(try json(attempt, "summary.json")["status"] as? String == "failed")
        #expect(try json(attempt, "summary.json")["phase"] as? String == "cli_preflight")
    }

    @Test func timeoutPreservesPartialOutputAndTerminationFlags() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let cli = try cli(in: root, output: """
        printf '%s\\n' '{"type":"system","subtype":"init"}'
        exec /bin/sleep 30
        """)
        await #expect(throws: AIError.self) {
            try await ClaudeCLIProvider(executableURL: cli, timeout: 1).execute(request(in: root), onEvent: { _ in })
        }
        let attempt = try #require(attempts(in: root).first)
        #expect(try json(attempt, "cli-exit.json")["timedOut"] as? Bool == true)
        #expect(try text(attempt, "cli-stdout.txt").contains("init"))
        #expect(try json(attempt, "summary.json")["status"] as? String == "failed")
    }

    @Test func redactsCredentialsAcrossChunksAndOmitsBinaryData() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let trace = AIInteractionTrace(request: request(in: root), backend: .messagesAPI)
        trace.registerSecret("test-secret-value")
        trace.appendBytes("raw.txt", Data("test-secret-".utf8))
        trace.appendBytes("raw.txt", Data("value sk-ant-example123\nAuthorization=opaque-token\nBearer opaque-token\n".utf8))
        trace.appendBytes("raw.txt", Data(#"{"accessToken":"unknown-credential","token":"another-credential"}"#.utf8))
        trace.appendBytes("raw.txt", Data("\n{\"cookie\":\"cookie-value\",\"credentials\":\"credential-value\",\"private_key\":\"key-value\"}\nCookie=session-cookie\nprivate_key=private-key-value\n".utf8))
        trace.appendBytes("raw.txt", Data(#"{"password":"escaped\"quoted-value"}"#.utf8))
        trace.writeJSON("payload.json", ["x-api-key": "opaque-token", "source": ["type": "base64", "media_type": "image/png", "data": "binary-content"]])
        trace.finish(status: "failed", error: AIError.transport("test-secret-value"))
        let contents = try FileManager.default.contentsOfDirectory(at: trace.directory, includingPropertiesForKeys: nil).map {
            try String(contentsOf: $0, encoding: .utf8)
        }.joined()
        for secret in ["test-secret-value", "sk-ant-example123", "opaque-token", "binary-content", "unknown-credential", "another-credential", "cookie-value", "credential-value", "key-value", "session-cookie", "private-key-value", "quoted-value"] {
            #expect(!contents.contains(secret))
        }
        #expect(contents.contains("[REDACTED]"))
        #expect(contents.contains("binary omitted"))
    }

    @Test func boundedArtifactsReportTruncationAndKeepFinalSummary() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let trace = AIInteractionTrace(request: request(in: root), backend: .claudeCLI, fileLimit: 1_024, totalLimit: 4_096)
        trace.writeText("large.txt", String(repeating: "a", count: 4_000))
        trace.writeText("large.txt", "should not grow")
        trace.writeText("more.txt", String(repeating: "b", count: 4_000))
        trace.writeText("last.txt", String(repeating: "c", count: 4_000))
        trace.writeJSON("cli-exit.json", ["terminationStatus": 1])
        trace.finish(status: "failed", error: AIError.invalidResponse("bad payload"))
        #expect(try Data(contentsOf: trace.directory.appendingPathComponent("large.txt")).count <= 1_024)
        let summary = try json(trace.directory, "summary.json")
        #expect((summary["truncatedFiles"] as? [String])?.contains("large.txt") == true)
        #expect(summary["status"] as? String == "failed")
        #expect(try json(trace.directory, "cli-exit.json")["terminationStatus"] as? Int == 1)
    }

    @Test func logWriteFailureDoesNotChangeProviderResult() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("block log directory".utf8).write(to: root.appendingPathComponent("ai-logs"))
        let cli = try cli(in: root, output: #"printf '%s\n' '{"type":"result","structured_output":{"cards":[]}}'"#)
        let response = try await ClaudeCLIProvider(executableURL: cli).execute(request(in: root), onEvent: { _ in })
        #expect(response.content == #"{"cards":[]}"#)
    }

    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("LecternDiagnosticsTests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func request(in root: URL) -> AIRequest {
        AIRequest(jobID: UUID(), kind: .generate, model: "opus", prompt: "Study prompt", pdf: nil, workingDirectory: root, systemPrompt: "Study instructions")
    }
    private func cli(in root: URL, output: String) throws -> URL {
        let path = root.appendingPathComponent("fake-claude")
        let script = """
        #!/bin/sh
        if [ "$1" = "auth" ]; then
          printf '%s\\n' '{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","subscriptionType":"max"}'
          exit 0
        fi
        cat > /dev/null
        \(output)
        """
        try Data(script.utf8).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
        return path
    }
    private func attempts(in root: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("ai-logs"), includingPropertiesForKeys: nil)
    }
    private func json(_ directory: URL, _ name: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent(name))) as? [String: Any])
    }
    private func text(_ directory: URL, _ name: String) throws -> String {
        try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
    }
}
