import Foundation
import Darwin
import Testing
@testable import LecternCore

@Suite(.serialized)
struct ProviderTests {
    @Test func cliEnvironmentAddsPDFToolsToFinderPathWithoutChangingPrecedence() throws {
        let environment = ClaudeCLIProvider.sanitizedEnvironment(inheriting: [
            "PATH": "/custom/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "ANTHROPIC_API_KEY": "test-only-secret",
            "CLAUDE_CODE_OAUTH_TOKEN": "test-only-token",
            "HOME": "/test/home"
        ])
        #expect(environment["PATH"] == "/custom/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin")
        #expect(environment["ANTHROPIC_API_KEY"] == nil)
        #expect(environment["CLAUDE_CODE_OAUTH_TOKEN"] == nil)
        #expect(environment["HOME"] == "/test/home")
        #expect(environment["CLAUDE_CODE_SAFE_MODE"] == "1")
        for path in [nil, "", ":/opt/homebrew/bin:/opt/homebrew/bin:"] as [String?] {
            let result = ClaudeCLIProvider.sanitizedEnvironment(inheriting: path.map { ["PATH": $0] } ?? [:])
            #expect(result["PATH"] == "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
        }
    }

    @Test func cliUsesPrivateStdinAndParsesStructuredEnvelope() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cli = try fakeCLI(in: root, body: #"""
        if [ "$1" = "auth" ]; then
          printf '%s\n' '{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","subscriptionType":"max"}'
          exit 0
        fi
        count=$(wc -c | tr -d '[:space:]')
        printf '{"type":"result","subtype":"success","is_error":false,"result":"ok","structured_output":{"promptBytes":%s},"usage":{"input_tokens":11,"output_tokens":7},"total_cost_usd":0.12}\n' "$count"
        """#)
        let prompt = String(repeating: "ä", count: 100_000)
        let request = AIRequest(jobID: UUID(), kind: .generate, model: "opus", prompt: prompt,
                                pdf: nil, workingDirectory: root, systemPrompt: "Private app instructions.")
        let provider = ClaudeCLIProvider(executableURL: cli, timeout: 3)
        let response = try await provider.execute(request, onEvent: { _ in })
        #expect(response.content == #"{"promptBytes":200000}"#)
        #expect(response.usage.inputTokens == 11)
        #expect(response.usage.outputTokens == 7)
        #expect(response.usage.costUSD == 0.12)
    }

    @Test func subscriptionGateRejectsConsoleOAuthAndUnknownBillingProfiles() throws {
        try ClaudeCLIProvider.validateSubscriptionStatus(["loggedIn": true, "authMethod": "claude.ai", "apiProvider": "firstParty", "subscriptionType": "max"])
        for status: [String: Any] in [
            ["loggedIn": true, "authMethod": "oauth_token", "apiProvider": "firstParty"],
            ["loggedIn": true, "authMethod": "claude.ai", "apiProvider": "firstParty"],
            ["loggedIn": true, "authMethod": "api_key", "apiProvider": "firstParty", "subscriptionType": "max"],
            ["loggedIn": true, "authMethod": "claude.ai", "apiProvider": "bedrock", "subscriptionType": "max"]
        ] { #expect(throws: AIError.self) { try ClaudeCLIProvider.validateSubscriptionStatus(status) } }
    }

    @Test func cliAskStreamsTextAndReadsFinalResult() throws {
        let event = #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Hello"}}}"#
        let result = #"{"type":"result","subtype":"success","result":"Hello [slide 1]","usage":{"input_tokens":4,"output_tokens":2}}"#
        let data = Data((event + "\n" + result + "\n").utf8)
        let response = try ClaudeCLIProvider.parseStreamResult(data)
        #expect(response.content == "Hello [slide 1]")
        #expect(response.usage.inputTokens == 4)
    }

    @Test func cliNonzeroStreamExitPreservesProviderErrorAndLimitCategory() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cli = try fakeCLI(in: root, body: #"""
        if [ "$1" = "auth" ]; then
          printf '%s\n' '{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","subscriptionType":"pro"}'
          exit 0
        fi
        cat > /dev/null
        printf '%s\n' '{"type":"system","subtype":"init"}'
        printf '%s\n' '{"type":"result","subtype":"error_during_execution","is_error":true,"result":"","errors":["You have hit your limit. Try again after 8pm."]}'
        exit 1
        """#)
        var request = AIRequest(jobID: UUID(), kind: .chat, model: "opus", prompt: "Give a simple example.",
                                pdf: nil, workingDirectory: root)
        request.chatSnapshot = ChatSnapshot(slides: [], cards: [], initialRefs: [])
        try Data("[]".utf8).write(to: root.appendingPathComponent("cards.json"))
        do {
            _ = try await ClaudeCLIProvider(executableURL: cli, timeout: 3).execute(request, onEvent: { _ in })
            Issue.record("Expected a provider limit error")
        } catch let error as AIError {
            #expect(error == .limit("You have hit your limit. Try again after 8pm."))
        }
    }

    @Test func cliFailureDetailsHandleEnvelopesStreamsAndFallbacks() throws {
        let fallback = "Claude Code exited with status 1."
        let samples: [(String, String, String)] = [
            (#"{"type":"result","is_error":true,"result":"Session expired"}"#, "stderr noise", "Session expired"),
            (#"{"type":"result","result":"  ","errors":["", "Provider unavailable"]}"#, "", "Provider unavailable"),
            ("{\"type\":\"system\"}\n{\"type\":\"result\",\"errors\":[\"Connection reset\"]}\n", "", "Connection reset"),
            ("{\"type\":\"system\"}\n{\"type\":\"error\",\"error\":{\"message\":\"Authentication failed\"}}", "", "Authentication failed"),
            (#"{"type":"assistant","error":"rate_limit","message":{"content":[{"type":"text","text":"You've hit your limit"}]}}"#, "", "You've hit your limit"),
            (#"{"type":"result","result":"","errors":[]}"#, " CLI crashed \n", "CLI crashed"),
            (#"{"type":"result","subtype":"error_max_structured_output_retries"}"#, "", "Claude Code reported an error (error_max_structured_output_retries)."),
            ("invalid JSON", "", fallback)
        ]
        for (stdout, stderr, expected) in samples {
            #expect(ClaudeCLIProvider.message(from: Data(stdout.utf8), stderr: Data(stderr.utf8), fallback: fallback) == expected)
        }
        #expect(ClaudeCLIProvider.message(from: Data(), stderr: Data(String(repeating: "x", count: 2_000).utf8), fallback: fallback).count == 1_024)
    }

    @Test func cliParsersPreserveErrorsArrayWhenResultIsEmpty() throws {
        let result = Data(#"{"type":"result","subtype":"error_during_execution","is_error":true,"result":"","errors":["Provider unavailable"]}"#.utf8)
        for parse in [ClaudeCLIProvider.parseStructuredResult, ClaudeCLIProvider.parseStreamResult] {
            do {
                _ = try parse(result)
                Issue.record("Expected the provider error")
            } catch let error as AIError {
                #expect(error == .transport("Provider unavailable"))
            }
        }
    }

    @Test func cliAcceptsCompletedStructuredToolButRejectsIncompleteCalls() throws {
        let payload = #"{"learningPoints":[{"text":"Profit is revenue minus expenses.","pages":[1]}]}"#
        let success = Data("""
        {"type":"result","subtype":"success","is_error":false,"stop_reason":"tool_use","structured_output":\(payload)}
        """.utf8)
        let response = try ClaudeCLIProvider.parseStructuredResult(success)
        let points = try JSONDecoder().decode(DistilledPoints.self, from: Data(response.content.utf8))
        #expect(points.learningPoints.count == 1)
        #expect(points.learningPoints.first?.pages == [1])

        let incomplete = Data(#"{"type":"result","subtype":"success","is_error":false,"stop_reason":"tool_use"}"#.utf8)
        #expect(throws: AIError.self) { try ClaudeCLIProvider.parseStructuredResult(incomplete) }
        #expect(throws: AIError.self) { try ClaudeCLIProvider.parseStreamResult(success) }
        for reason in ["refusal", "max_tokens", "model_context_window_exceeded", "pause_turn"] {
            let stopped = Data("""
            {"type":"result","subtype":"success","is_error":false,"stop_reason":"\(reason)","structured_output":\(payload)}
            """.utf8)
            #expect(throws: AIError.self) { try ClaudeCLIProvider.parseStructuredResult(stopped) }
        }
    }

    @Test func cliArgumentsIsolateCustomizationsAndScopeRead() throws {
        let root = URL(fileURLWithPath: "/tmp/Lectern Job")
        let pdf = root.appendingPathComponent("input.pdf")
        let structured = try ClaudeCLIProvider.arguments(
            for: AIRequest(jobID: UUID(), kind: .generate, model: "opus", prompt: "p", pdf: nil, workingDirectory: root),
            model: "opus", pdfURL: pdf)
        #expect(structured.contains("--safe-mode"))
        #expect(structured.contains("--no-session-persistence"))
        #expect(structured.contains("--no-chrome"))
        #expect(structured.contains("--disable-slash-commands"))
        #expect(structured.contains("--permission-mode"))
        #expect(structured.contains("dontAsk"))
        #expect(structured.contains("--system-prompt"))
        let systemPromptIndex = try #require(structured.firstIndex(of: "--system-prompt"))
        let systemPrompt = structured[systemPromptIndex + 1]
        #expect(systemPrompt.hasPrefix(PromptBuilder.systemPrompt))
        #expect(systemPrompt == PromptBuilder.systemPrompt)
        #expect(!systemPrompt.contains(root.path))
        let input = try ClaudeCLIProvider.inputPrompt(for: AIRequest(jobID: UUID(), kind: .generate,
            model: "opus", prompt: "reusable context", pdf: nil, workingDirectory: root), pdfURL: pdf)
        #expect(input.hasPrefix("reusable context\n\nSOURCE PDF:"))
        #expect(input.contains(#""/tmp/Lectern Job/input.pdf""#))
        #expect(input.contains("use Read with that exact file_path"))
        #expect(structured.contains("--tools"))
        #expect(structured.contains("Read"))
        #expect(structured.contains("Read(//tmp/Lectern Job/input.pdf)"))
        #expect(structured.contains("--json-schema"))
        #expect(!structured.contains("--bare"))
        #expect(!structured.contains("--append-system-prompt"))
        #expect(!structured.contains("--mcp-config"))
        #expect(!structured.contains("--plugin-dir"))
        #expect(!structured.contains("--add-dir"))

        let ask = try ClaudeCLIProvider.arguments(
            for: AIRequest(jobID: UUID(), kind: .ask, model: "opus", prompt: "q", pdf: nil, workingDirectory: root),
            model: "opus", pdfURL: nil)
        #expect(ask.contains("stream-json"))
        #expect(ask.contains("--include-partial-messages"))
        #expect(ask.contains(""))
        let askPromptIndex = try #require(ask.firstIndex(of: "--system-prompt"))
        #expect(ask[askPromptIndex + 1] == PromptBuilder.systemPrompt(for: .ask))
    }

    @Test func cliPDFPathsChangeOnlyTheInputSuffixAndDistilUsesLowEffort() throws {
        let first = AIRequest(jobID: UUID(), kind: .distil, model: "sonnet", prompt: "Reusable context",
            pdf: nil, workingDirectory: URL(fileURLWithPath: "/tmp/first job"))
        var second = first
        second.workingDirectory = URL(fileURLWithPath: "/tmp/second job")
        let firstPDF = first.workingDirectory.appendingPathComponent("input.pdf")
        let secondPDF = second.workingDirectory.appendingPathComponent("input.pdf")
        let a = try ClaudeCLIProvider.arguments(for: first, model: first.model, pdfURL: firstPDF)
        let b = try ClaudeCLIProvider.arguments(for: second, model: second.model, pdfURL: secondPDF)
        let index = try #require(a.firstIndex(of: "--system-prompt"))
        #expect(a[index + 1] == b[index + 1])
        #expect(!a[index + 1].contains("/tmp/"))
        #expect(ClaudeCLIProvider.effort(for: .distil) == "low")
        let inputA = try ClaudeCLIProvider.inputPrompt(for: first, pdfURL: firstPDF)
        let inputB = try ClaudeCLIProvider.inputPrompt(for: second, pdfURL: secondPDF)
        #expect(inputA.hasPrefix(first.prompt))
        #expect(inputB.hasPrefix(first.prompt))
        #expect(inputA.contains(firstPDF.path))
        #expect(inputB.contains(secondPDF.path))
        #expect(try ClaudeCLIProvider.inputPrompt(for: first, pdfURL: nil) == first.prompt)
    }

    @Test func cliRejectsUnGroundedAnswersAndCardsAfterDeniedPDFRead() throws {
        let envelope = #"{"type":"result","subtype":"success","is_error":false,"result":"I cannot see the slides.","structured_output":{"cards":[],"skipped":[]},"permission_denials":[{"tool_name":"Read","tool_input":{"file_path":"/input.pdf"}}]}"#
        let data = Data(envelope.utf8)
        #expect(throws: AIError.self) { try ClaudeCLIProvider.parseStreamResult(data) }
        #expect(throws: AIError.self) { try ClaudeCLIProvider.parseStructuredResult(data) }
    }

    @Test func cliCancellationSendsInterruptAndReapsFakeProcess() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pidURL = root.appendingPathComponent("pid")
        let cli = try fakeCLI(in: root, body: #"""
        if [ "$1" = "auth" ]; then
          printf '%s\n' '{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","subscriptionType":"max"}'
          exit 0
        fi
        trap 'printf caught > interrupt; exit 130' INT TERM
        printf '%s' "$$" > pid
        while :; do sleep 0.02; done
        """#)

        let request = AIRequest(jobID: UUID(), kind: .generate, model: "opus", prompt: "test",
                                pdf: nil, workingDirectory: root)
        let provider = ClaudeCLIProvider(executableURL: cli, timeout: 20)
        let startup = ProviderStartupRecorder()
        let task = Task {
            do { return try await provider.execute(request, onEvent: { _ in }) }
            catch { startup.record(error.localizedDescription); throw error }
        }
        try await waitUntil { FileManager.default.fileExists(atPath: pidURL.path) || startup.failure != nil }
        guard FileManager.default.fileExists(atPath: pidURL.path) else {
            task.cancel()
            _ = try await task.value
            throw AIError.configuration("Fake CLI never started: \(startup.failure ?? "startup deadline")")
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("interrupt").path))
        let pid = try #require(Int32(String(contentsOf: pidURL, encoding: .utf8)))
        #expect(kill(pid, 0) == -1)
    }

    @Test func cancellingDuringAuthNeverStartsInference() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let pidURL = root.appendingPathComponent("authpid")
        // Auth runs in its own private directory; use explicit fixture-owned paths for observation.
        let cli = try fakeCLI(in: root, body: """
        if [ "$1" = "auth" ]; then
          trap 'exit 130' INT TERM
          printf '%s' "$$" > '\(pidURL.path)'
          while :; do sleep 0.02; done
        fi
        printf started > '\(root.appendingPathComponent("inference").path)'
        """)
        let request = AIRequest(jobID: UUID(), kind: .generate, model: "opus", prompt: "test", pdf: nil, workingDirectory: root)
        let task = Task { try await ClaudeCLIProvider(executableURL: cli).execute(request, onEvent: { _ in }) }
        try await waitUntil { FileManager.default.fileExists(atPath: pidURL.path) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        let pid = try #require(Int32(String(contentsOf: pidURL, encoding: .utf8)))
        #expect(kill(pid, 0) == -1)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("inference").path))
    }

    @Test func messagesRequestUsesBearerPDFAndSanitizedStructuredSchema() throws {
        let prompt = "TASK: generate\n\nGLOBAL CARD RULES\n" + String(repeating: "stable context ", count: 200) +
            "\n\nINCLUDED LEARNING POINTS\n[]"
        let systemPrompt = "Test-only system instructions."
        let pdf = Data("%PDF-fixture".utf8)
        let request = try MessagesAPIProvider.makeURLRequest(prompt: prompt, kind: .revise, pdf: pdf,
                                                             systemPrompt: systemPrompt,
                                                             apiKey: "test-only-key", model: "claude-opus-5-5",
                                                             apiVersion: "2026-10-21",
                                                             endpoint: URL(string: "https://api.example.test/v1/messages")!,
                                                             maxOutputTokens: 30_000)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-only-key")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2026-10-21")
        let bodyData = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        #expect(body["model"] as? String == "claude-opus-5-5")
        #expect((body["system"] as? [[String: Any]])?.first?["text"] as? String == systemPrompt)
        #expect(body["max_tokens"] as? Int == 8_192)
        let messages = try #require(body["messages"] as? [[String: Any]])
        let content = try #require(messages.first?["content"] as? [[String: Any]])
        #expect(content.contains { $0["cache_control"] != nil })
        #expect(content.contains { (($0["source"] as? [String: Any])?["data"] as? String) == pdf.base64EncodedString() })
        let outputConfig = try #require(body["output_config"] as? [String: Any])
        let format = try #require(outputConfig["format"] as? [String: Any])
        let schema = try #require(format["schema"] as? [String: Any])
        let properties = try #require(schema["properties"] as? [String: Any])
        let cards = try #require(properties["cards"] as? [String: Any])
        #expect(cards["maxItems"] == nil)
        #expect(cards["minItems"] == nil)
        #expect(MessagesAPIProvider.effort(for: .generate) == "high")
        #expect(MessagesAPIProvider.effort(for: .distil) == "low")
    }

    @Test func chatUsesStructuredNonStreamingPayloadInBothProviders() throws {
        let prompt = "TASK: chat\n\nSTUDENT QUESTION:\n\"Edit the supplied card\""
        let request = try MessagesAPIProvider.makeURLRequest(prompt: prompt, kind: .chat, pdf: nil,
            apiKey: "test-only-key", model: "claude-opus-5-5", apiVersion: "2026-10-21",
            endpoint: URL(string: "https://api.example.test/v1/messages")!, maxOutputTokens: 128_000)
        let bodyData = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        #expect(body["stream"] as? Bool == false)
        #expect(body["max_tokens"] as? Int == 32_768)
        #expect((body["output_config"] as? [String: Any])?["format"] != nil)
        #expect(MessagesAPIProvider.effort(for: .chat) == "medium")

        let cli = try ClaudeCLIProvider.arguments(for: AIRequest(jobID: UUID(), kind: .chat,
            model: "opus", prompt: prompt, pdf: nil, workingDirectory: URL(fileURLWithPath: "/tmp/chat")),
            model: "opus", pdfURL: nil)
        #expect(cli.contains("--json-schema"))
        #expect(!cli.contains("stream-json"))
        #expect(ClaudeCLIProvider.effort(for: .chat) == "medium")
    }

    @Test func messagesRejectsRefusalsAndTruncatedResponses() {
        let refusal = Data(#"{"type":"message","stop_reason":"refusal","content":[{"type":"refusal","refusal":"Cannot answer."}]}"#.utf8)
        #expect(throws: AIError.self) { try MessagesAPIProvider.parseMessageResponse(refusal) }
        let truncated = Data(#"{"type":"message","stop_reason":"max_tokens","content":[{"type":"text","text":"partial"}]}"#.utf8)
        #expect(throws: AIError.self) { try MessagesAPIProvider.parseMessageResponse(truncated) }
    }

    @Test func messagesAPIHandlesSSEAndUnauthorizedResponsesOffline() async throws {
        let sse = """
        event: content_block_delta
        data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Answer"}}

        event: message_stop
        data: {"type":"message_stop"}

        """
        let session = URLSessionStub.makeSession(status: 200, body: Data(sse.utf8))
        let provider = MessagesAPIProvider(apiKey: { "test-only-key" }, session: session,
                                           endpoint: URL(string: "https://api.example.test/v1/messages")!)
        let request = AIRequest(jobID: UUID(), kind: .ask, model: "claude-opus-5-5", prompt: "Question",
                                pdf: nil, workingDirectory: FileManager.default.temporaryDirectory)
        let eventRecorder = ProviderEventRecorder()
        let response = try await provider.execute(request) { event in eventRecorder.append(event) }
        #expect(response.content == "Answer")
        #expect(eventRecorder.text == "Answer")
        #expect(URLSessionStub.state.lastRequest()?.value(forHTTPHeaderField: "Authorization") == "Bearer test-only-key")

        let unauthorizedSession = URLSessionStub.makeSession(status: 401,
            body: Data(#"{"error":{"type":"authentication_error","message":"invalid test key"}}"#.utf8))
        let unauthorizedProvider = MessagesAPIProvider(apiKey: { "test-only-key" }, session: unauthorizedSession,
                                                       endpoint: URL(string: "https://api.example.test/v1/messages")!)
        await #expect(throws: AIError.self) {
            _ = try await unauthorizedProvider.execute(request) { _ in }
        }
    }

    @Test func chatContextRejectsSymlinksAndNeverReadsAnAmbientPDF() throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let request = try chatRequest(in: root)
        let context = ChatProviderContext(request: request, snapshot: request.chatSnapshot!)
        #expect(throws: AIError.self) { try context.file("../outside.txt") }
        let png = root.appendingPathComponent("slides/007.png")
        try FileManager.default.removeItem(at: png)
        try FileManager.default.createSymbolicLink(at: png, withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        #expect(throws: AIError.self) { try context.image(page: 7) }
    }

    @Test func cliChatScopesFilesAndTracesOnlyCompletedReads() throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let request = try chatRequest(in: root)
        let arguments = try ClaudeCLIProvider.arguments(for: request, model: "opus", pdfURL: nil)
        #expect(arguments.contains("stream-json")); #expect(arguments.contains("--json-schema"))
        #expect(!arguments.contains { $0.contains("input.pdf") })
        let path = try ChatProviderContext(request: request, snapshot: request.chatSnapshot!).file("slides/007.png").path
        let events: [[String: Any]] = [
            ["type": "assistant", "message": ["content": [["type": "tool_use", "id": "r1", "name": "Read", "input": ["file_path": path]]]]],
            ["type": "user", "message": ["content": [["type": "tool_result", "tool_use_id": "r1", "content": "image"]]]],
            ["type": "result", "subtype": "success", "stop_reason": "tool_use", "structured_output": ["message": "Answer", "edits": [], "quiz": []]]
        ]
        let data = try events.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n")
        let result = try ClaudeCLIProvider.parseChatStream(Data(data.utf8), request: request, snapshot: request.chatSnapshot!, onEvent: { _ in })
        #expect(result.read == [.slide(7)])
        let noReads = try JSONSerialization.data(withJSONObject: events.last!)
        let empty = try ClaudeCLIProvider.parseChatStream(noReads, request: request, snapshot: request.chatSnapshot!, onEvent: { _ in })
        #expect(empty.read.isEmpty)
    }

    @Test(arguments: [false, true])
    func cliChatImageEchoesDoNotExhaustResponseLimitOrHideReadErrors(readFails: Bool) async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var request = try chatRequest(in: root)
        request.chatSnapshot!.initialRefs = [.slide(7)]
        let image = String(repeating: "A", count: 9 * 1_024 * 1_024)
        let fixture = root.appendingPathComponent("stream.jsonl")
        var stream = Data()
        for index in 0..<2 {
            let events: [[String: Any]] = [
                ["type": "assistant", "message": ["content": [["type": "tool_use", "id": "r\(index)", "name": "Read", "input": ["file_path": "slides/007.png"]]]]],
                ["type": "user", "tool_use_result": ["base64": image], "message": ["content": [
                    ["type": "tool_result", "tool_use_id": "r\(index)", "is_error": readFails,
                     "content": [["type": "image", "source": ["type": "base64", "data": image]]]]
                ]]]
            ]
            for event in events {
                stream.append(try JSONSerialization.data(withJSONObject: event))
                stream.append(10)
            }
        }
        // No trailing newline: the final event still needs to be parsed.
        stream.append(Data(#"{"type":"result","subtype":"success","stop_reason":"tool_use","structured_output":{"message":"Answer","edits":[],"quiz":[]}}"#.utf8))
        try stream.write(to: fixture)
        let cli = try fakeCLI(in: root, body: #"""
        if [ "$1" = "auth" ]; then
          printf '%s\n' '{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","subscriptionType":"max"}'
          exit 0
        fi
        cat > /dev/null
        cat stream.jsonl
        """#)
        do {
            let response = try await ClaudeCLIProvider(executableURL: cli, timeout: 15).execute(request, onEvent: { _ in })
            #expect(!readFails)
            #expect(response.read == [.slide(7)])
            #expect(response.content.contains("Answer"))
        } catch let error as AIError {
            guard readFails, case .configuration(let message) = error else { throw error }
            #expect(message.contains("could not read"))
        }
        let logs = try #require(FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("ai-logs"), includingPropertiesForKeys: nil).first)
        let retained = try Data(contentsOf: logs.appendingPathComponent("cli-stdout.txt"))
        #expect(retained.count < 10_000)
        #expect(!String(decoding: retained, as: UTF8.self).contains(String(image.prefix(100))))
    }

    @Test func cliAskStillRejectsAnOversizedAnswer() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = root.appendingPathComponent("stream.jsonl")
        let event: [String: Any] = ["type": "result", "subtype": "success", "result": String(repeating: "A", count: 17 * 1_024 * 1_024)]
        try JSONSerialization.data(withJSONObject: event).write(to: fixture)
        let cli = try fakeCLI(in: root, body: #"""
        if [ "$1" = "auth" ]; then
          printf '%s\n' '{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","subscriptionType":"max"}'
          exit 0
        fi
        cat > /dev/null
        cat stream.jsonl
        """#)
        let request = AIRequest(jobID: UUID(), kind: .ask, model: "opus", prompt: "Question", pdf: nil, workingDirectory: root)
        do {
            _ = try await ClaudeCLIProvider(executableURL: cli, timeout: 15).execute(request, onEvent: { _ in })
            Issue.record("Expected the answer limit to remain enforced.")
        } catch let error as AIError {
            guard case .limit = error else { throw error }
        }
    }

    @Test func cliSingleCardContextReadsOnlyThatCardAndReportsItHonestly() throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        var request = try chatRequest(in: root)
        let card = Card(front: "Focused question", back: "Focused answer")
        request.chatSnapshot!.cards = [card]
        request.chatSnapshot!.initialRefs = [.card(card.id)]
        try FileManager.default.createDirectory(at: root.appendingPathComponent("cards"), withIntermediateDirectories: true)
        let relative = "cards/\(card.id.uuidString).json"
        try JSONEncoder().encode(card).write(to: root.appendingPathComponent(relative))
        let prompt = try ClaudeCLIProvider.inputPrompt(for: request, pdfURL: nil)
        let required = prompt.components(separatedBy: "Before answering, Read these attached context files: ").last!.components(separatedBy: ". Look up").first!
        #expect(required.contains(card.id.uuidString))
        #expect(!required.contains("cards.json"))
        let events: [[String: Any]] = [
            ["type": "assistant", "message": ["content": [["type": "tool_use", "id": "focused", "name": "Read", "input": ["file_path": root.appendingPathComponent(relative).path]]]]],
            ["type": "user", "message": ["content": [["type": "tool_result", "tool_use_id": "focused", "content": "focused card"]]]],
            ["type": "result", "subtype": "success", "stop_reason": "end_turn", "structured_output": ["message": "Answer", "edits": [], "quiz": []]]
        ]
        let data = try events.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n")
        let response = try ClaudeCLIProvider.parseChatStream(Data(data.utf8), request: request, snapshot: request.chatSnapshot!, onEvent: { _ in })
        #expect(response.read == [.card(card.id)])
        #expect(!response.searchedLecture)
    }

    @Test func structuredChatPreviewDecodesOnlyMessageAndEscapes() {
        var preview = ChatMessageStream()
        #expect(preview.append(#"{"message":"Hello "#) == "Hello ")
        #expect(preview.append(#"world\n[S7]","edits":[],"quiz":[]}"#) == "world\n[S7]")
    }

    @Test func messagesChatRunsLookupLoopWithImagesAndSummedUsage() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        var request = try chatRequest(in: root)
        request.chatSnapshot!.initialRefs = []
        let card = Card(sourcePages: [7], front: "Front", back: "Back")
        request.chatSnapshot!.cards = [card]
        let edit = ChatCardEdit(cardID: card.id, baseRevisionID: card.currentRevisionID!, front: "Changed", back: "Changed back")
        let editJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(edit))
        let first = sseChat(blocks: [
            ["type": "tool_use", "id": "t1", "name": "read_slides", "input": ["pages": [7]]],
            ["type": "tool_use", "id": "t2", "name": "get_cards", "input": ["ids": ["C1"]]],
            ["type": "tool_use", "id": "t3", "name": "edit_cards", "input": ["edits": [editJSON]]]
        ], stop: "tool_use", input: 10, output: 3)
        let reply = #"{"message":"Look at [S7].","edits":[],"quiz":[]}"#
        let second = sseChat(blocks: [["type": "text", "text": reply]], stop: "end_turn", input: 20, output: 9)
        let session = URLSessionStub.makeSession(status: 200, body: first)
        URLSessionStub.state.enqueue(second)
        let provider = MessagesAPIProvider(apiKey: { "fixture" }, session: session, endpoint: URL(string: "https://api.example.test/v1/messages")!)
        let result = try await provider.execute(request, onEvent: { _ in })
        #expect(result.read == [.slide(7), .card(card.id)]); #expect(result.searchedLecture)
        #expect(try JSONDecoder().decode(ChatReply.self, from: Data(result.content.utf8)).edits == [edit])
        #expect(result.usage.inputTokens == 30); #expect(result.usage.outputTokens == 12)
        let body = try #require(URLSessionStub.state.lastRequest()?.httpBody)
        let object = try JSONSerialization.jsonObject(with: body)
        let json = String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]), as: UTF8.self)
        #expect(json.contains("image/png")); #expect(json.contains("tool_result")); #expect(!json.contains("application/pdf"))
        #expect(json.contains(card.id.uuidString)); #expect(json.contains(card.currentRevisionID!.uuidString))
        #expect(!json.contains("history"))
    }

    @Test(arguments: [false, true]) func messagesChatRereadingAttachedContextDoesNotClaimLectureSearch(allCards: Bool) async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        var request = try chatRequest(in: root)
        let card = Card(sourcePages: [7], front: "Front", back: "Back")
        request.chatSnapshot!.cards = [card]
        request.chatSnapshot!.initialRefs = allCards ? [.allCards, .slide(7)] : [.card(card.id)]
        let first = sseChat(blocks: [
            ["type": "tool_use", "id": "t1", "name": "read_slides", "input": ["pages": [7]]],
            ["type": "tool_use", "id": "t2", "name": "get_cards", "input": ["ids": [card.id.uuidString]]]
        ], stop: "tool_use", input: 10, output: 3)
        let second = sseChat(blocks: [["type": "text", "text": #"{"message":"Answer","edits":[],"quiz":[]}"#]], stop: "end_turn", input: 20, output: 9)
        let session = URLSessionStub.makeSession(status: 200, body: first)
        URLSessionStub.state.enqueue(second)
        let provider = MessagesAPIProvider(apiKey: { "fixture" }, session: session, endpoint: URL(string: "https://api.example.test/v1/messages")!)
        let result = try await provider.execute(request, onEvent: { _ in })
        #expect(result.read.contains(.card(card.id)))
        #expect(result.read.contains(.slide(7)))
        #expect(!result.searchedLecture)
    }

    @Test func settingsCodableClampsLimitsAndHasNoCredentialField() throws {
        let settings = AISettings(backend: .messagesAPI, cliModel: "opus", messagesAPIModel: "claude-opus-5-5",
                                  claudeCLIPath: "/test/claude", maxOutputTokens: 999_999)
        let encoded = try JSONEncoder().encode(settings)
        let loaded = try JSONDecoder().decode(AISettings.self, from: encoded)
        #expect(loaded.maxOutputTokens == 128_000)
        #expect(loaded.messagesAPIModel == "claude-opus-5-5")
        #expect(!String(decoding: encoded, as: UTF8.self).lowercased().contains("apikey"))
    }
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("lectern-provider-tests-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func fakeCLI(in directory: URL, body: String) throws -> URL {
    let url = directory.appendingPathComponent("fake-claude")
    let script = "#!/bin/sh\nset -eu\n" + body + "\n"
    try Data(script.utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    return url
}

private final class ProviderEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var content = ""
    var text: String { lock.lock(); defer { lock.unlock() }; return content }
    func append(_ event: AIEvent) {
        lock.lock(); defer { lock.unlock() }
        if case .text(let value) = event { content += value }
    }
}

private final class ProviderStartupRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    var failure: String? { lock.withLock { value } }
    func record(_ failure: String) { lock.withLock { value = failure } }
}

private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(12)
    while !condition() && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    #expect(condition())
}

private final class URLSessionStubState: @unchecked Sendable {
    static let shared = URLSessionStubState()
    private let lock = NSLock()
    private var status = 200
    private var body = Data()
    private var queued: [Data] = []
    private var request: URLRequest?
    private var stopped = false

    func configure(status: Int, body: Data) {
        lock.lock(); defer { lock.unlock() }
        self.status = status; self.body = body; request = nil; stopped = false; queued = []
    }
    func snapshot() -> (Int, Data) {
        lock.lock(); defer { lock.unlock() }
        let current = body
        if !queued.isEmpty { body = queued.removeFirst() }
        return (status, current)
    }
    func enqueue(_ data: Data) { lock.withLock { queued.append(data) } }
    func capture(_ request: URLRequest) {
        var captured = request
        if captured.httpBody == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count)) }
            captured.httpBody = data
        }
        lock.withLock { self.request = captured }
    }
    func lastRequest() -> URLRequest? { lock.lock(); defer { lock.unlock() }; return request }
    func markStopped() { lock.lock(); stopped = true; lock.unlock() }
    func isStopped() -> Bool { lock.lock(); defer { lock.unlock() }; return stopped }
}

private enum URLSessionStub {
    static var state: URLSessionStubState { .shared }
    static func makeSession(status: Int, body: Data) -> URLSession {
        state.configure(status: status, body: body)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class StubURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "api.example.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        URLSessionStub.state.capture(request)
        let (status, body) = URLSessionStub.state.snapshot()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["content-type": "application/json"] )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { URLSessionStub.state.markStopped() }
}

private func chatRequest(in root: URL) throws -> AIRequest {
    try FileManager.default.createDirectory(at: root.appendingPathComponent("slides"), withIntermediateDirectories: true)
    try Data("PNG fixture".utf8).write(to: root.appendingPathComponent("slides/007.png"))
    try Data("Slide seven".utf8).write(to: root.appendingPathComponent("slides/007.txt"))
    try Data("[]".utf8).write(to: root.appendingPathComponent("cards.json"))
    try Data("ambient PDF must not be used".utf8).write(to: root.appendingPathComponent("input.pdf"))
    var request = AIRequest(jobID: UUID(), kind: .chat, model: "opus", prompt: "Question", pdf: Data("ignored PDF".utf8), workingDirectory: root)
    request.chatSnapshot = ChatSnapshot(slides: [ChatSlide(page: 7, text: "Slide seven", note: "Note", imagePath: "slides/007.png")], cards: [], initialRefs: [])
    return request
}

private func sseChat(blocks: [[String: Any]], stop: String, input: Int, output: Int) -> Data {
    var events: [[String: Any]] = [["type": "message_start", "message": ["usage": ["input_tokens": input]]]]
    for (index, block) in blocks.enumerated() { events.append(["type": "content_block_start", "index": index, "content_block": block]); events.append(["type": "content_block_stop", "index": index]) }
    events.append(["type": "message_delta", "delta": ["stop_reason": stop], "usage": ["output_tokens": output]])
    events.append(["type": "message_stop"])
    return Data(events.map { "data: " + String(decoding: try! JSONSerialization.data(withJSONObject: $0), as: UTF8.self) + "\n\n" }.joined().utf8)
}
