import Foundation
import CoreGraphics
import Testing
@testable import LecternCore

@Suite struct CodexProviderTests {
    @Test func structuredGenerateRecordsJSONRPCDiagnostics() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = try fixture(in: root, mode: "success")
        let job = try jobDirectory(in: root)
        let pdfURL = root.appendingPathComponent("one-page.pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 240, height: 180)
        let pdfContext = try #require(CGContext(pdfURL as CFURL, mediaBox: &mediaBox, nil))
        pdfContext.beginPDFPage(nil)
        pdfContext.setFillColor(CGColor(gray: 0.5, alpha: 1))
        pdfContext.fill(CGRect(x: 10, y: 10, width: 80, height: 60))
        pdfContext.endPDFPage()
        pdfContext.closePDF()
        let provider = CodexCLIProvider(executableURL: executable,
            settings: AISettings(codexModel: "gpt-fixture"), timeout: 5, codexHomeURL: root.appendingPathComponent("codex-home"))
        let request = AIRequest(jobID: UUID(), kind: .generate, model: "gpt-fixture",
            prompt: "Generate one card.", pdf: try Data(contentsOf: pdfURL), workingDirectory: job)

        let response = try await provider.execute(request, onEvent: { _ in })
        let output = try JSONDecoder().decode(GeneratedCards.self, from: Data(response.content.utf8))
        #expect(output.cards.first?.front == "Fixture question")
        #expect(response.usage.inputTokens == 12)
        let logs = try traceDirectory(in: job)
        #expect(FileManager.default.fileExists(atPath: logs.appendingPathComponent("codex-invocation.json").path))
        let sent = try String(contentsOf: logs.appendingPathComponent("codex-rpc-sent.jsonl"), encoding: .utf8)
        let received = try String(contentsOf: logs.appendingPathComponent("codex-rpc-received.jsonl"), encoding: .utf8)
        #expect(sent.contains("thread/start"))
        #expect(sent.contains("outputSchema"))
        #expect(sent.contains("[image data omitted;"))
        #expect(!sent.contains("data:image/png;base64,"))
        #expect(received.contains("turn/completed"))
        let requestLog = try String(contentsOf: root.appendingPathComponent("success/requests.jsonl"), encoding: .utf8)
        #expect(requestLog.contains(root.appendingPathComponent("codex-home").path))
        #expect(requestLog.contains("gpt-fixture"))
        #expect(requestLog.contains("Snapshot PDF page 1."))
        #expect(requestLog.contains("data:image/png;base64,"))
    }

    @Test func rejectsAPIKeyAccountWithoutFallingBack() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = try fixture(in: root, mode: "apiKey")
        let provider = makeProvider(executable: executable, root: root)
        do {
            _ = try await provider.execute(makeRequest(root: root), onEvent: { _ in })
            Issue.record("Expected a ChatGPT account requirement.")
        } catch let error as AIError {
            guard case .configuration(let message) = error else { Issue.record("Wrong Codex account error: \(error)"); return }
            #expect(message.contains("API-key accounts are not used"))
        }
    }

    @Test func largeInputAndToolEchoesDoNotConsumeResponseLimits() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = try fixture(in: root, mode: "largeEchoes")
        let request = try makeRequest(root: root)
        let response = try await CodexCLIProvider(executableURL: executable, timeout: 30,
            codexHomeURL: root.appendingPathComponent("home")).execute(request, onEvent: { _ in })
        #expect(try JSONDecoder().decode(GeneratedCards.self, from: Data(response.content.utf8)).cards.first?.front == "Fixture question")
        let logs = try traceDirectory(in: request.workingDirectory)
        let exit = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: logs.appendingPathComponent("codex-exit.json"))) as? [String: Any])
        #expect((exit["receivedBytes"] as? Int ?? 0) > 64 * 1_024 * 1_024)
        #expect((exit["retainedBytes"] as? Int ?? Int.max) < 10_000)
        let received = try Data(contentsOf: logs.appendingPathComponent("codex-rpc-received.jsonl"))
        #expect(received.count < 10_000)
        #expect(!String(decoding: received, as: UTF8.self).contains("data:image/png;base64,"))
    }

    @Test(arguments: ["oversizedAnswer", "oversizedRequest", "oversizedEOF"])
    func largeAnswersAndServerRequestsStillFail(mode: String) async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = try fixture(in: root, mode: mode)
        do {
            _ = try await CodexCLIProvider(executableURL: executable, timeout: 30,
                codexHomeURL: root.appendingPathComponent("home")).execute(makeRequest(root: root), onEvent: { _ in })
            Issue.record("Expected the semantic message limit to remain enforced.")
        } catch let error as AIError {
            guard case .limit(let message) = error else { throw error }
            #expect(message.contains("response message exceeded 16 MiB"))
        }
    }

    @Test func turnQuotaFailureRemainsLimitWhenProcessExitsSuccessfully() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = try fixture(in: root, mode: "quota")
        do {
            _ = try await makeProvider(executable: executable, root: root).execute(makeRequest(root: root), onEvent: { _ in })
            Issue.record("Expected Codex quota failure.")
        } catch let error as AIError {
            guard case .limit(let message) = error else { Issue.record("Wrong Codex quota error: \(error)"); return }
            #expect(message.lowercased().contains("quota limit"))
        }
    }

    @Test func successfulProcessExitWithoutTurnCompletionFails() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = try fixture(in: root, mode: "missingCompletion")
        do {
            _ = try await makeProvider(executable: executable, root: root).execute(makeRequest(root: root), onEvent: { _ in })
            Issue.record("Expected missing turn completion to fail.")
        } catch let error as AIError {
            guard case .transport(let message) = error else { Issue.record("Wrong incomplete-turn error: \(error)"); return }
            #expect(message.contains("Codex disconnected"))
        }
    }

    @Test func commentaryDeltasNeverReachChatPreviewOrFinalAnswer() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = try fixture(in: root, mode: "commentary")
        let request = try makeRequest(root: root, kind: .chat)
        let events = AIEventRecorder()

        let response = try await makeProvider(executable: executable, root: root).execute(request) { events.append($0) }
        let reply = try JSONDecoder().decode(ChatReply.self, from: Data(response.content.utf8))
        #expect(reply.message == "The public answer.")
        #expect(!events.text.contains("private planning"))
        #expect(events.text.contains("The public answer."))
    }

    @Test func timeoutAndCancellationStopTheChildProcess() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = try fixture(in: root, mode: "hang")
        let timeoutRequest = try makeRequest(root: root)
        do {
            _ = try await CodexCLIProvider(executableURL: executable, timeout: 0.15,
                codexHomeURL: root.appendingPathComponent("timeout-home")).execute(timeoutRequest, onEvent: { _ in })
            Issue.record("Expected Codex timeout.")
        } catch let error as AIError {
            guard case .limit(let message) = error else { Issue.record("Wrong Codex timeout error: \(error)"); return }
            #expect(message.contains("time limit"))
        }
        #expect(try codexProcessExited(in: traceDirectory(in: timeoutRequest.workingDirectory)))

        let cancellationExecutable = try fixture(in: root, mode: "cancel")
        let provider = CodexCLIProvider(executableURL: cancellationExecutable, timeout: 20,
            codexHomeURL: root.appendingPathComponent("cancel-home"))
        let cancellationRequest = try makeRequest(root: root)
        let task = Task { try await provider.execute(cancellationRequest, onEvent: { _ in }) }
        let received = root.appendingPathComponent("cancel/requests.jsonl")
        var reachedTurnStart = false
        for _ in 0..<200 {
            if let text = try? String(contentsOf: received, encoding: .utf8), text.contains("turn/start") {
                reachedTurnStart = true
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(reachedTurnStart)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try codexProcessExited(in: traceDirectory(in: cancellationRequest.workingDirectory)))
    }

    @Test func chatToolRoundTripUsesVerifiedFrozenSlideAndAttachmentBytes() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = try fixture(in: root, mode: "toolRoundTrip")
        let job = try jobDirectory(in: root)
        let slides = job.appendingPathComponent("slides")
        let attachments = job.appendingPathComponent("attachments")
        try FileManager.default.createDirectory(at: slides, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true)
        let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j2ioAAAAASUVORK5CYII="))
        let slidePNG = slides.appendingPathComponent("001.png")
        let slideText = slides.appendingPathComponent("001.txt")
        let cardsJSON = job.appendingPathComponent("cards.json")
        let attachmentID = UUID()
        let attachment = ChatAttachment(id: attachmentID, filename: "diagram.png", mediaType: "image/png",
            byteCount: png.count, sha256: PromptBuilder.hash(png))
        let attachmentURL = attachments.appendingPathComponent("\(attachmentID.uuidString).png")
        try png.write(to: slidePNG); try Data("frozen slide sentinel".utf8).write(to: slideText)
        try Data("[]".utf8).write(to: cardsJSON); try png.write(to: attachmentURL)
        var snapshot = ChatSnapshot(slides: [ChatSlide(page: 1, text: "frozen slide sentinel", note: "fixture note", imagePath: "slides/001.png")],
            cards: [], initialRefs: [.slide(1)])
        snapshot.images = [ChatSnapshotImage(attachment: attachment, messageID: UUID(), isCurrent: true)]
        snapshot.assetHashes = [
            "attachments/\(attachmentID.uuidString).png": PromptBuilder.hash(png),
            "cards.json": PromptBuilder.hash(try Data(contentsOf: cardsJSON)),
            "slides/001.png": PromptBuilder.hash(png),
            "slides/001.txt": PromptBuilder.hash(try Data(contentsOf: slideText))
        ]
        var request = AIRequest(jobID: UUID(), kind: .chat, model: "gpt-fixture", prompt: "Fixture prompt.", pdf: nil, workingDirectory: job)
        request.chatSnapshot = snapshot
        request.systemPrompt = "Only answer from frozen context."

        let response = try await makeProvider(executable: executable, root: root).execute(request, onEvent: { _ in })
        let reply = try JSONDecoder().decode(ChatReply.self, from: Data(response.content.utf8))
        #expect(reply.message == "Read the frozen material.")
        #expect(response.searchedLecture)
        #expect(response.read.contains(.slide(1)))
        let requestLog = try String(contentsOf: root.appendingPathComponent("toolRoundTrip/requests.jsonl"), encoding: .utf8)
        #expect(requestLog.contains("frozen slide sentinel"))
        #expect(requestLog.contains("inputImage"))
        #expect(requestLog.contains(attachmentID.uuidString))
        #expect(requestLog.contains(png.base64EncodedString()))
    }

    @Test(arguments: ["largeDeck", "retryCardLookup"])
    func bulkCardLookupReturnsEveryRevisionAndCanRecover(mode: String) async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = try fixture(in: root, mode: mode)
        var request = try makeRequest(root: root, kind: .chat)
        let cards = (1...129).map { Card(front: "Term \($0)", back: "Definition \($0)") }
        var snapshot = ChatSnapshot(slides: [], cards: cards, initialRefs: [.allCards])
        snapshot.cardContextVersion = 1
        var hashes: [String: String] = [:]
        try FileManager.default.createDirectory(at: request.workingDirectory.appendingPathComponent("cards"), withIntermediateDirectories: true)
        func write<T: Encodable>(_ value: T, path: String) throws {
            let data = try JSONEncoder().encode(value)
            try data.write(to: request.workingDirectory.appendingPathComponent(path))
            hashes[path] = PromptBuilder.hash(data)
        }
        try write(ChatCardContent.deck(cards), path: "cards.json")
        for index in cards.indices {
            try write(ChatCardContent(cards[index], number: index + 1, includeEditIDs: true), path: snapshot.cardPath(at: index))
        }
        snapshot.assetHashes = hashes
        request.chatSnapshot = snapshot

        let response = try await makeProvider(executable: executable, root: root).execute(request, onEvent: { _ in })
        let reply = try JSONDecoder().decode(ChatReply.self, from: Data(response.content.utf8))
        #expect(reply.edits.count == cards.count)
        #expect(response.read == [.allCards] + cards.map { .card($0.id) })
        for (edit, card) in zip(reply.edits, cards) {
            #expect(edit.cardID == card.id)
            #expect(edit.baseRevisionID == card.currentRevisionID)
            #expect(edit.front == card.back)
            #expect(edit.back == card.front)
        }
        let log = try String(contentsOf: root.appendingPathComponent("\(mode)/requests.jsonl"), encoding: .utf8)
        #expect(log.contains("\"success\":true"))
        if mode == "retryCardLookup" {
            #expect(log.components(separatedBy: "\"success\":false").count == 4)
            #expect(log.contains("Unknown card C999"))
        }
    }
}

private func makeProvider(executable: URL, root: URL) -> CodexCLIProvider {
    CodexCLIProvider(executableURL: executable, settings: AISettings(codexModel: "gpt-fixture"), timeout: 5,
        codexHomeURL: root.appendingPathComponent("\(executable.deletingLastPathComponent().lastPathComponent)-home"))
}

private func makeRequest(root: URL, kind: JobKind = .generate) throws -> AIRequest {
    let job = try jobDirectory(in: root)
    return AIRequest(jobID: UUID(), kind: kind, model: "gpt-fixture", prompt: "Fixture prompt.",
        pdf: nil, workingDirectory: job)
}

private func jobDirectory(in root: URL) throws -> URL {
    let job = root.appendingPathComponent("job-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: job, withIntermediateDirectories: true)
    return job
}

private func temporaryRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("lectern-codex-provider-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func traceDirectory(in job: URL) throws -> URL {
    let root = job.appendingPathComponent("ai-logs")
    return try #require(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first)
}

private func codexProcessExited(in logs: URL) throws -> Bool {
    let data = try Data(contentsOf: logs.appendingPathComponent("codex-exit.json"))
    return (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["exited"] as? Bool == true
}

private final class AIEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var textValue = ""
    var text: String { lock.lock(); defer { lock.unlock() }; return textValue }
    func append(_ event: AIEvent) {
        guard case .text(let value) = event else { return }
        lock.lock(); defer { lock.unlock() }
        textValue += value
    }
}

private func fixture(in root: URL, mode: String) throws -> URL {
    let directory = root.appendingPathComponent(mode, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let executable = directory.appendingPathComponent("codex-fixture")
    let source = #"""
    #!/usr/bin/env python3
    import json, os, sys, time
    mode = "MODE_PLACEHOLDER"
    record = os.path.join(os.path.dirname(sys.argv[0]), "requests.jsonl")
    with open(record, "a", encoding="utf-8") as output:
        output.write("CODEX_HOME=" + os.environ.get("CODEX_HOME", "") + "\n")
    def send(value):
        sys.stdout.write(json.dumps(value, separators=(",", ":")) + "\n")
        sys.stdout.flush()
    def read():
        line = sys.stdin.readline()
        if not line:
            return None
        value = json.loads(line)
        with open(record, "a", encoding="utf-8") as output:
            output.write(json.dumps(value, separators=(",", ":")) + "\n")
        return value
    while True:
        message = read()
        if message is None:
            break
        method = message.get("method")
        request_id = message.get("id")
        params = message.get("params", {})
        if method == "initialize":
            send({"id": request_id, "result": {}})
        elif method == "account/read":
            kind = "apiKey" if mode == "apiKey" else "chatgpt"
            send({"id": request_id, "result": {"account": {"type": kind, "planType": "plus"}}})
        elif method == "thread/start":
            send({"id": request_id, "result": {"thread": {"id": "thread-fixture"}, "model": params.get("model")}})
        elif method == "turn/start":
            send({"id": request_id, "result": {"turn": {"id": "turn-fixture"}}})
            if mode in ("largeEchoes", "oversizedAnswer", "oversizedRequest", "oversizedEOF"):
                image = "data:image/png;base64," + "A" * (17 * 1024 * 1024)
                user = {"id": "user-1", "type": "userMessage", "content": [{"type": "image", "url": image}]}
                if mode == "largeEchoes":
                    for lifecycle in ("item/started", "item/completed"):
                        send({"method": lifecycle, "params": {"threadId": "thread-fixture", "item": user}})
                    send({"method": "item/completed", "params": {"item": {"type": "dynamicToolCall", "contentItems": [{"type": "inputImage", "imageUrl": image}], "success": True}}})
                elif mode == "oversizedRequest":
                    # Requests must never be compacted, even with echo-like method names.
                    send({"id": 9002, "method": "item/completed", "params": {"item": user}})
                    break
                else:
                    oversized = {"method": "item/completed", "params": {"item": {"type": "agentMessage", "phase": "final_answer", "text": image}}}
                    if mode == "oversizedEOF":
                        sys.stdout.write(json.dumps(oversized, separators=(",", ":")))
                        sys.stdout.flush()
                    else:
                        send(oversized)
                    break
            if mode in ("hang", "cancel"):
                time.sleep(30)
                break
            if mode == "missingCompletion":
                break
            if mode == "toolRoundTrip":
                send({"id": 9001, "method": "item/tool/call", "params": {
                    "threadId": "thread-fixture", "turnId": "turn-fixture", "tool": "read_slides", "arguments": {"pages": [1]}}})
                tool_result = read()
                if tool_result is None or "contentItems" not in tool_result.get("result", {}):
                    sys.exit(9)
            if mode in ("largeDeck", "retryCardLookup"):
                if mode == "retryCardLookup":
                    for index, arguments in enumerate(({"ids": []}, {"ids": ["C999"]}, {"ids": True})):
                        send({"id": 8000 + index, "method": "item/tool/call", "params": {
                            "tool": "get_cards", "arguments": arguments}})
                        rejected = read()
                        if rejected is None or rejected.get("result", {}).get("success") is not False:
                            sys.exit(10)
                # Read the 129-card deck, then check duplicate displayed/UUID aliases.
                refs = ["C" + str(index) for index in range(1, 130)]
                send({"id": 9001, "method": "item/tool/call", "params": {
                    "tool": "get_cards", "arguments": {"ids": refs}}})
                tool_result = read()
                if tool_result is None or tool_result.get("result", {}).get("success") is not True:
                    sys.exit(11)
                cards = json.loads(tool_result["result"]["contentItems"][0]["text"])
                send({"id": 9002, "method": "item/tool/call", "params": {
                    "tool": "get_cards", "arguments": {"ids": ["C1", "C1", cards[0]["cardID"]]}}})
                duplicate_result = read()
                if len(json.loads(duplicate_result["result"]["contentItems"][0]["text"])) != 3:
                    sys.exit(12)
            text = "{\"cards\":[{\"front\":\"Fixture question\",\"back\":\"Fixture answer\",\"sourceSlides\":[1],\"flag\":null}],\"skipped\":[]}"
            if mode in ("largeDeck", "retryCardLookup"):
                text = json.dumps({"message": "Flipped the cards.", "quiz": [], "edits": [
                    {"cardID": card["cardID"], "baseRevisionID": card["baseRevisionID"],
                     "front": card["back"], "back": card["front"]} for card in cards]})
            if mode == "toolRoundTrip":
                text = "{\"message\":\"Read the frozen material.\",\"edits\":[],\"quiz\":[]}"
            if mode == "commentary":
                private_text = json.dumps({"message": "private planning", "edits": [], "quiz": []})
                text = json.dumps({"message": "The public answer.", "edits": [], "quiz": []})
                send({"method": "item/started", "params": {"threadId": "thread-fixture", "turnId": "turn-fixture", "item": {"id": "commentary-1", "type": "agentMessage", "phase": "commentary"}}})
                send({"method": "item/agentMessage/delta", "params": {"threadId": "thread-fixture", "turnId": "turn-fixture", "itemId": "commentary-1", "delta": private_text}})
                send({"method": "item/completed", "params": {"threadId": "thread-fixture", "turnId": "turn-fixture", "item": {"id": "commentary-1", "type": "agentMessage", "phase": "commentary", "text": private_text}}})
                send({"method": "item/started", "params": {"threadId": "thread-fixture", "turnId": "turn-fixture", "item": {"id": "final-1", "type": "agentMessage", "phase": "final_answer"}}})
                send({"method": "item/agentMessage/delta", "params": {"threadId": "thread-fixture", "turnId": "turn-fixture", "itemId": "final-1", "delta": text}})
            if mode == "quota":
                send({"method": "turn/completed", "params": {"threadId": "thread-fixture", "turnId": "turn-fixture", "turn": {"id": "turn-fixture", "status": "failed", "error": {"message": "Quota limit reached."}}}})
                break
            if mode == "toolRoundTrip":
                with open(record, "a", encoding="utf-8") as output:
                    output.write("TOOL_RESULT=" + json.dumps(tool_result, separators=(",", ":")) + "\n")
            send({"method": "thread/tokenUsage/updated", "params": {"threadId": "thread-fixture", "turnId": "turn-fixture", "tokenUsage": {"total": {"inputTokens": 12, "outputTokens": 7}}}})
            send({"method": "item/completed", "params": {"threadId": "thread-fixture", "turnId": "turn-fixture", "item": {"type": "agentMessage", "phase": "final_answer", "text": text}}})
            final = {"method": "turn/completed", "params": {"threadId": "thread-fixture", "turnId": "turn-fixture", "turn": {"id": "turn-fixture", "status": "completed"}}}
            if mode == "largeEchoes":
                final["params"]["turn"]["items"] = [user]
                # Completion status and trailing frames must survive EOF without newline.
                sys.stdout.write(json.dumps(final, separators=(",", ":")))
                sys.stdout.flush()
            else:
                send(final)
            break
    """#.replacingOccurrences(of: "MODE_PLACEHOLDER", with: mode)
    try Data(source.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    return executable
}
