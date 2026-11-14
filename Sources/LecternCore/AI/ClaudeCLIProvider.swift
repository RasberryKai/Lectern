import Foundation
import Darwin

/// Uses an already-installed Claude Code CLI. `--safe-mode` preserves its
/// first-party subscription login while disabling user/project customizations.
public struct ClaudeCLIProvider: AIProvider {
    public let backend: AIBackend = .claudeCLI

    private let executableURL: URL
    private let defaultModel: String
    private let timeout: TimeInterval
    private let maximumOutputBytes = 16 * 1_024 * 1_024
    private let maximumErrorBytes = 64 * 1_024

    public init(executableURL: URL? = nil,
                settings: AISettings = .default,
                timeout: TimeInterval = 1_200) {
        self.executableURL = executableURL ?? Self.resolveExecutable(configuredPath: settings.claudeCLIPath)
        self.defaultModel = settings.cliModel
        self.timeout = max(1, timeout)
    }

    public func execute(_ request: AIRequest, onEvent: @escaping @Sendable (AIEvent) -> Void) async throws -> AIResponse {
        let recordsEvents = AIDiagnostics.current?.jobID != request.jobID
        return try await AIDiagnostics.withTrace(request: request, backend: backend) { trace in
            let forwardEvent: @Sendable (AIEvent) -> Void = { event in
                if recordsEvents { trace.event(event) }
                onEvent(event)
            }
            let response = try await executeTraced(request, trace: trace, onEvent: forwardEvent)
            trace.response(response)
            return response
        }
    }

    private func executeTraced(_ request: AIRequest, trace: AIInteractionTrace,
                               onEvent: @escaping @Sendable (AIEvent) -> Void) async throws -> AIResponse {
        trace.phase("cli_preflight")
        try Task.checkCancellation()
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw AIError.configuration("Claude Code CLI was not found at \(executableURL.path). Install it or set its path in AI settings.")
        }

        trace.phase("cli_authentication")
        try await Self.requireSubscriptionLogin(executableURL: executableURL)
        trace.phase("cli_preparing_input")
        try Task.checkCancellation()
        let pdfURL = request.chatSnapshot == nil ? Self.pdfURL(for: request) : nil
        let pdfSize = request.pdf?.count ?? (pdfURL.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int } ?? 0)
        trace.record("cli_input_selected", ["pdfPath": pdfURL?.path ?? "", "pdfBytes": pdfSize,
                                            "chatContext": request.chatSnapshot != nil])
        if pdfURL != nil, pdfSize > 96 * 1_024 * 1_024 {
            throw AIError.limit("The PDF is too large for a CLI job. Reduce its size or selected pages.")
        }
        if let pdfURL, !pdfURL.isFileURL {
            throw AIError.configuration("The job PDF must be a local file.")
        }

        let inputDirectory = request.workingDirectory.standardizedFileURL
        guard FileManager.default.fileExists(atPath: inputDirectory.path) else {
            throw AIError.configuration("The job working directory does not exist.")
        }
        if let pdfURL {
            let expected = inputDirectory.appendingPathComponent("input.pdf").standardizedFileURL
            guard pdfURL.standardizedFileURL == expected,
                  FileManager.default.fileExists(atPath: expected.path) else {
                throw AIError.configuration("The CLI may read only the job's scoped input.pdf.")
            }
        }

        let promptDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LecternPrompt-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: promptDirectory,
                                                    withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            throw AIError.configuration("Could not create a private prompt file: \(error.localizedDescription)")
        }
        defer { try? FileManager.default.removeItem(at: promptDirectory) }
        let promptURL = promptDirectory.appendingPathComponent("prompt.txt")
        do {
            let input = try Self.inputPrompt(for: request, pdfURL: pdfURL)
            trace.writeText("cli-stdin.txt", input)
            try Data(input.utf8).write(to: promptURL, options: .atomic)
        } catch {
            throw AIError.configuration("Could not write the private prompt file: \(error.localizedDescription)")
        }

        let arguments = try Self.arguments(for: request,
                                           model: request.model.isEmpty ? defaultModel : request.model,
                                           pdfURL: pdfURL)
        onEvent(.stage("Starting Claude"))
        let preview = ChatPreviewEmitter(onEvent: onEvent)
        let tracker = request.chatSnapshot.map { ChatCLIReadTracker(context: ChatProviderContext(request: request, snapshot: $0), onEvent: onEvent) }
        let invocation = CLIInvocation(executableURL: executableURL,
                                       arguments: arguments,
                                       workingDirectory: inputDirectory,
                                       promptURL: promptURL,
                                       streaming: request.kind == .ask || request.chatSnapshot != nil,
                                       outputLimit: maximumOutputBytes,
                                       errorLimit: maximumErrorBytes,
                                       timeout: timeout,
                                       onText: { text in if request.chatSnapshot == nil { onEvent(.text(text)) } else { preview.append(text) } },
                                       onLine: { tracker?.receive($0) })
        trace.phase("cli_execution")
        let result = try await withTaskCancellationHandler {
            try await invocation.run()
        } onCancel: {
            invocation.cancel()
        }
        try Task.checkCancellation()
        if result.wasCancelled { throw CancellationError() }
        if result.timedOut { throw AIError.limit("Claude Code exceeded the \(Int(timeout)) second time limit.") }
        if result.outputExceeded { throw AIError.limit("Claude Code output exceeded Lectern's 16 MB response limit.") }
        guard result.terminationStatus == 0 else {
            let message = Self.message(from: result.stdout, stderr: result.stderr,
                                       fallback: "Claude Code exited with status \(result.terminationStatus).")
            if Self.looksLikeLimit(message) { throw AIError.limit(message) }
            throw AIError.transport(message)
        }

        trace.phase("cli_parsing_response")
        onEvent(.stage("Writing"))
        if let snapshot = request.chatSnapshot {
            return try Self.parseChatStream(result.stdout, request: request, snapshot: snapshot, emitFinalText: !preview.emitted, onEvent: onEvent)
        }
        if request.kind == .ask {
            let response = try Self.parseStreamResult(result.stdout)
            if !result.emittedText { onEvent(.text(response.content)) }
            return response
        }
        return try Self.parseStructuredResult(result.stdout)
    }

    /// Read-only status check used to ensure the CLI is authenticated through a
    /// Claude subscription/OAuth login, not a paid API-key or third-party route.
    static func requireSubscriptionLogin(executableURL: URL) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LecternAuth-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let invocation = CLIInvocation(executableURL: executableURL, arguments: ["auth", "status"],
            workingDirectory: directory, promptURL: URL(fileURLWithPath: "/dev/null"), streaming: false,
            outputLimit: 64 * 1_024, errorLimit: 64 * 1_024, timeout: 10, onText: { _ in }, diagnosticPrefix: "cli-auth")
        let result = try await withTaskCancellationHandler {
            try await invocation.run()
        } onCancel: { invocation.cancel() }
        try Task.checkCancellation()
        if result.wasCancelled { throw CancellationError() }
        if result.timedOut { throw AIError.transport("Claude Code sign-in status check timed out.") }
        guard result.terminationStatus == 0, !result.outputExceeded,
              let status = try? JSONSerialization.jsonObject(with: result.stdout) as? [String: Any] else {
            throw AIError.configuration("Sign in to Claude Code with your Claude subscription before using Lectern's CLI provider.")
        }
        try validateSubscriptionStatus(status)
    }

    static func validateSubscriptionStatus(_ status: [String: Any]) throws {
        let method = (status["authMethod"] as? String ?? "").lowercased()
        let provider = (status["apiProvider"] as? String ?? "").lowercased()
        let plan = (status["subscriptionType"] as? String ?? "").lowercased()
        // Console OAuth is keyless but API-billed. OAuth alone does not prove subscription billing.
        guard status["loggedIn"] as? Bool == true, method == "claude.ai",
              ["firstparty", "first-party"].contains(provider), ["pro", "max", "ultra", "team", "enterprise"].contains(plan) else {
            throw AIError.configuration("Lectern could not verify a Claude subscription profile. Sign in to Claude Code with your Claude account. Console OAuth/API-key profiles are billed separately and are not allowed by the subscription backend.")
        }
    }

    /// Keep the job-specific path after reusable study context, never in the system prompt.
    static func inputPrompt(for request: AIRequest, pdfURL: URL?) throws -> String {
        if let snapshot = request.chatSnapshot {
            let context = ChatProviderContext(request: request, snapshot: snapshot)
            let root = request.workingDirectory.standardizedFileURL.resolvingSymlinksInPath()
            let inlineSlides = context.hasVerifiedInlineSlides
            var required = snapshot.initialRefs.flatMap { ref -> [String] in
                switch ref {
                case .slide(let page): return [String(format: "slides/%03d.png", page), String(format: "slides/%03d.txt", page)]
                case .card(let id): return [snapshot.cardPath(for: id)].compactMap { $0 } + (snapshot.cards.first(where: { $0.id == id })?.sourcePages.flatMap { [String(format: "slides/%03d.png", $0), String(format: "slides/%03d.txt", $0)] } ?? [])
                case .allCards: return context.hasVerifiedInlineDeck ? [] : ["cards.json"]
                case .allSlides:
                    return snapshot.slides.flatMap { slide -> [String] in
                        let hasText = !slide.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        if !hasText { return [String(format: "slides/%03d.png", slide.page)] }
                        return inlineSlides ? [] : [String(format: "slides/%03d.txt", slide.page)]
                    }
                }
            }
            required += (snapshot.images ?? []).filter(\.isCurrent).map(\.relativePath)
            for path in context.allowedFiles { _ = try context.file(path) }
            let paths = required.map { root.appendingPathComponent($0).path }
            let cardPath = snapshot.cardContextVersion == 1 ? "cards/C12.json (displayed card number)" : "cards/<UUID>.json"
            return request.prompt + "\n\nFROZEN CHAT FILES: Read only files in " + root.path +
                ". Slides are slides/007.png and slides/007.txt (three-digit original page number); individual cards are " + cardPath + " and the full deck is cards.json. All slides text supplied in FROZEN ATTACHED CONTEXT is already available; do not reread those text files. Pages without extracted text require reading their PNG images. Read the full deck only when the question needs it or All cards is attached. Never read a PDF or any other filesystem location. Before answering, Read these attached context files: " +
                String(decoding: try JSONEncoder().encode(Array(Set(paths)).sorted()), as: UTF8.self) +
                ". Look up other frozen slides/cards or indexed prior uploaded images only when needed. Return strict chat JSON including message, edits and quiz. Card edits are proposals in edits, using the frozen base revision ID."
        }
        guard let pdfURL else { return request.prompt }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let path = String(decoding: try encoder.encode(pdfURL.standardizedFileURL.path), as: UTF8.self)
        return request.prompt + "\n\nSOURCE PDF: The current request's slide snapshot is at this absolute path: \(path). Before answering, use Read with that exact file_path. Do not resolve input.pdf against the filesystem root. Read this snapshot even if an earlier thread message says the PDF was inaccessible. PDF page positions are distinct from the original source slide labels printed on the pages."
    }

    static func arguments(for request: AIRequest, model: String, pdfURL: URL?) throws -> [String] {
        var arguments = [
            "-p",
            "--safe-mode",
            "--no-session-persistence",
            "--no-chrome",
            "--disable-slash-commands",
            "--permission-mode", "dontAsk",
            "--system-prompt", request.systemPrompt,
            "--model", model,
            "--effort", effort(for: request.kind),
            "--tools", pdfURL == nil && request.chatSnapshot == nil ? "" : "Read"
        ]
        if let snapshot = request.chatSnapshot {
            let context = ChatProviderContext(request: request, snapshot: snapshot)
            for relative in context.allowedFiles {
                let path = try context.file(relative).path
                // Permission patterns must remain exact, even for unusual job directory names.
                guard !path.contains(where: { "*?[]()\n\r".contains($0) }) else { throw AIError.configuration("The chat job path contains CLI permission pattern characters.") }
                arguments += ["--allowedTools", "Read(/" + path + ")"]
            }
            arguments += ["--output-format", "stream-json", "--verbose", "--include-partial-messages", "--json-schema", request.outputSchema!]
            return arguments
        }
        if let pdfURL {
            let path = String(pdfURL.standardizedFileURL.path.dropFirst())
            arguments += ["--allowedTools", "Read(//\(path))"]
        }
        if request.kind == .ask {
            arguments += ["--output-format", "stream-json", "--verbose", "--include-partial-messages"]
        } else {
            guard let schema = request.outputSchema else {
                throw AIError.configuration("No output schema is available for this structured CLI job.")
            }
            arguments += ["--output-format", "json", "--json-schema", schema]
        }
        return arguments
    }

    static func parseChatStream(_ data: Data, request: AIRequest, snapshot: ChatSnapshot,
                                emitFinalText: Bool = true, onEvent: @escaping @Sendable (AIEvent) -> Void) throws -> AIResponse {
        let context = ChatProviderContext(request: request, snapshot: snapshot)
        var pending: [String: String] = [:], read: [ContextRef] = [], final: [String: Any]?
        var completedFiles = Set<String>()
        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            guard let event = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if event["type"] as? String == "result" { final = event }
            let message = event["message"] as? [String: Any] ?? [:]
            for block in message["content"] as? [[String: Any]] ?? [] {
                if block["type"] as? String == "tool_use", block["name"] as? String == "Read",
                   let id = block["id"] as? String, let input = block["input"] as? [String: Any], let path = input["file_path"] as? String {
                    let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : request.workingDirectory.appendingPathComponent(path)
                    let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
                    let matching = context.allowedFiles.first { request.workingDirectory.appendingPathComponent($0).standardizedFileURL.resolvingSymlinksInPath() == canonical }
                    guard let matching, try context.file(matching) == canonical else { throw AIError.configuration("Claude attempted to read outside its frozen chat context.") }
                    pending[id] = matching
                }
                if block["type"] as? String == "tool_result", block["is_error"] as? Bool != true,
                   let id = block["tool_use_id"] as? String, let path = pending.removeValue(forKey: id) {
                    completedFiles.insert(path)
                    if let ref = context.reference(for: path), !read.contains(ref) { read.append(ref); onEvent(.read(ref)) }
                } else if block["type"] as? String == "tool_result", block["is_error"] as? Bool == true {
                    throw AIError.configuration("Claude could not read a frozen chat context file. Retry the request.")
                }
            }
        }
        // Provider failures (including usage limits) explain why no reads occurred.
        // Report them before checking whether a successful answer used its context.
        guard let final else { throw AIError.invalidResponse("Claude chat stream ended without a result.") }
        var response = try parseStructuredResult(JSONSerialization.data(withJSONObject: final))
        if snapshot.initialRefs.contains(.allCards), context.hasVerifiedInlineDeck, !read.contains(.allCards) {
            // Supplied context is evidence too, as with initial Messages API attachments.
            read.append(.allCards); onEvent(.read(.allCards))
        }
        if snapshot.initialRefs.contains(.allSlides), context.hasVerifiedInlineSlides {
            for slide in snapshot.slides where !slide.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let ref = ContextRef.slide(slide.page)
                if !read.contains(ref) { read.append(ref); onEvent(.read(ref)) }
            }
        }
        for image in (snapshot.images ?? []).filter(\.isCurrent) {
            guard completedFiles.contains(image.relativePath) else { throw AIError.invalidResponse("Claude did not read the uploaded image. Retry the request.") }
        }
        for ref in snapshot.initialRefs {
            let complete: Bool
            switch ref {
            case .slide(let page): complete = read.contains(.slide(page))
            case .card(let id): complete = read.contains(.card(id)) || read.contains(.allCards)
            case .allCards: complete = read.contains(.allCards) || (!snapshot.cards.isEmpty && snapshot.cards.allSatisfy { read.contains(.card($0.id)) })
            case .allSlides:
                complete = snapshot.slides.allSatisfy { slide in
                    if slide.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return completedFiles.contains(String(format: "slides/%03d.png", slide.page))
                    }
                    return read.contains(.slide(slide.page))
                }
            }
            guard complete else { throw AIError.slideRead("Claude did not read the attached chat context. Retry the request.") }
        }
        response.read = read
        let initial = Set(snapshot.initialRefs.flatMap { ref -> [ContextRef] in
            switch ref {
            case .card(let id): return [.card(id)] + (snapshot.cards.first(where: { $0.id == id })?.sourcePages.map(ContextRef.slide) ?? [])
            case .allSlides: return snapshot.slides.map { .slide($0.page) }
            case .allCards: return [.allCards] + snapshot.cards.map { .card($0.id) }
            default: return [ref]
            }
        })
        response.searchedLecture = read.contains { !initial.contains($0) }
        let reply = try JSONDecoder().decode(ChatReply.self, from: Data(response.content.utf8))
        if emitFinalText { onEvent(.text(reply.message)) }
        return response
    }

    static func parseStructuredResult(_ data: Data) throws -> AIResponse {
        guard data.count <= 16 * 1_024 * 1_024,
              let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIError.invalidResponse("Claude Code returned an invalid JSON response envelope.")
        }
        try validateFileAccess(envelope)
        if envelope["is_error"] as? Bool == true || (envelope["subtype"] as? String)?.hasPrefix("error") == true {
            let text = message(from: data, stderr: Data(), fallback: "Claude Code reported an error.")
            if envelope["subtype"] as? String == "error_max_turns" { throw AIError.limit(text) }
            if looksLikeLimit(text) { throw AIError.limit(text) }
            throw AIError.transport(text)
        }
        // --json-schema finishes through the CLI's structured-output tool.
        // Only a successful envelope with a payload proves that tool completed.
        let completedStructuredTool = envelope["subtype"] as? String == "success" &&
            envelope["stop_reason"] as? String == "tool_use" && envelope["structured_output"] != nil
        if !completedStructuredTool {
            try validateStopReason(envelope["stop_reason"] as? String,
                                   response: envelope["result"] as? String ?? "")
        }
        guard let structured = envelope["structured_output"] else {
            let result = envelope["result"] as? String ?? ""
            if looksLikeLimit(result) { throw AIError.limit(result) }
            throw AIError.invalidResponse("Claude Code did not include structured_output in its JSON response.")
        }
        let content: String
        if let string = structured as? String {
            content = string
        } else if JSONSerialization.isValidJSONObject(structured),
                  let data = try? JSONSerialization.data(withJSONObject: structured, options: [.sortedKeys, .fragmentsAllowed]),
                  let string = String(data: data, encoding: .utf8) {
            content = string
        } else {
            throw AIError.invalidResponse("Claude Code returned a malformed structured_output value.")
        }
        return AIResponse(content: content, usage: usage(from: envelope))
    }

    static func parseStreamResult(_ data: Data) throws -> AIResponse {
        guard data.count <= 16 * 1_024 * 1_024 else {
            throw AIError.limit("Claude Code stream exceeded Lectern's 16 MB response limit.")
        }
        let lines = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
        var finalResult: [String: Any]?
        for line in lines {
            guard let lineData = String(line).data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }
            if event["type"] as? String == "result" { finalResult = event }
        }
        guard let envelope = finalResult else {
            throw AIError.invalidResponse("Claude Code stream ended without a result event.")
        }
        try validateFileAccess(envelope)
        if envelope["is_error"] as? Bool == true || (envelope["subtype"] as? String)?.hasPrefix("error") == true {
            let text = message(from: data, stderr: Data(), fallback: "Claude Code reported an error.")
            if looksLikeLimit(text) { throw AIError.limit(text) }
            throw AIError.transport(text)
        }
        try validateStopReason(envelope["stop_reason"] as? String,
                               response: envelope["result"] as? String ?? "")
        guard let text = envelope["result"] as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIError.invalidResponse("Claude Code returned an empty Ask response.")
        }
        return AIResponse(content: text, usage: usage(from: envelope))
    }

    private static func validateFileAccess(_ envelope: [String: Any]) throws {
        let denials = envelope["permission_denials"] as? [[String: Any]] ?? []
        if denials.contains(where: { $0["tool_name"] as? String == "Read" }) {
            throw AIError.configuration("Claude could not read the slide PDF because file access was denied. Retry the request. If it persists, check the Claude CLI permissions; no answer was saved.")
        }
    }

    static func usage(from envelope: [String: Any]) -> AIUsage {
        let usage = envelope["usage"] as? [String: Any] ?? [:]
        var input = integer(usage["input_tokens"] ?? usage["inputTokens"] ?? envelope["input_tokens"])
        var output = integer(usage["output_tokens"] ?? usage["outputTokens"] ?? envelope["output_tokens"])
        var creation = integer(usage["cache_creation_input_tokens"] ?? usage["cacheCreationInputTokens"])
        var cached = integer(usage["cache_read_input_tokens"] ?? usage["cacheReadInputTokens"])
        if usage.isEmpty, let models = envelope["modelUsage"] as? [String: [String: Any]] {
            for item in models.values {
                input += integer(item["inputTokens"] ?? item["input_tokens"])
                output += integer(item["outputTokens"] ?? item["output_tokens"])
                creation += integer(item["cacheCreationInputTokens"] ?? item["cache_creation_input_tokens"])
                cached += integer(item["cacheReadInputTokens"] ?? item["cache_read_input_tokens"])
            }
        }
        return AIUsage(inputTokens: input + creation + cached, outputTokens: output,
                       costUSD: number(envelope["total_cost_usd"] ?? usage["total_cost_usd"]),
                       cacheCreationInputTokens: creation, cacheReadInputTokens: cached)
    }

    static func effort(for kind: JobKind) -> String {
        switch kind {
        case .generate: "high"
        case .revise, .ask, .chat: "medium"
        case .distil: "low"
        }
    }

    public static func resolveExecutable(configuredPath: String? = nil) -> URL {
        if let configuredPath, !configuredPath.isEmpty {
            return URL(fileURLWithPath: (configuredPath as NSString).expandingTildeInPath)
        }
        for path in [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/claude").path, "/opt/homebrew/bin/claude", "/usr/local/bin/claude"] where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        for directory in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            let path = String(directory) + "/claude"
            if FileManager.default.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }
        return URL(fileURLWithPath: "/opt/homebrew/bin/claude")
    }

    private static func pdfURL(for request: AIRequest) -> URL? {
        let path = request.workingDirectory.appendingPathComponent("input.pdf", isDirectory: false)
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        return path
    }

    static func sanitizedEnvironment(inheriting inherited: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = inherited
        for key in Array(environment.keys) {
            if key.hasPrefix("ANTHROPIC_") || key.hasPrefix("CLAUDE_CODE_USE_") ||
                key.hasPrefix("AWS_") || key.hasPrefix("GOOGLE_") ||
                key.hasPrefix("AZURE_") || key.hasPrefix("VERTEX_") || key == "CLAUDE_CODE_OAUTH_TOKEN" {
                environment.removeValue(forKey: key)
            }
        }
        // Finder-launched apps usually omit Homebrew from PATH. Claude's PDF
        // reader invokes pdftoppm by name, even when Claude itself was located
        // through an absolute path. Preserve configured precedence and add the
        // standard Apple Silicon/Intel Homebrew and system tool directories.
        let directories = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var seen = Set<String>()
        environment["PATH"] = directories.filter { seen.insert($0).inserted }.joined(separator: ":")
        environment["CLAUDE_CODE_SAFE_MODE"] = "1"
        return environment
    }

    static func message(from stdout: Data, stderr: Data, fallback: String) -> String {
        func detail(_ value: Any?) -> String? {
            guard let text = value as? String else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : String(trimmed.prefix(1_024))
        }
        let events: [[String: Any]]
        if let envelope = try? JSONSerialization.jsonObject(with: stdout) as? [String: Any] {
            events = [envelope]
        } else {
            // Chat/Ask stdout is newline-delimited JSON, even on a nonzero exit.
            events = String(decoding: stdout, as: UTF8.self).split(whereSeparator: \.isNewline).compactMap {
                try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
            }
        }
        let result = events.last { $0["type"] as? String == "result" } ?? (events.count == 1 ? events.first : nil)
        if let result {
            if let text = detail(result["result"]) { return text }
            for error in result["errors"] as? [String] ?? [] {
                if let text = detail(error) { return text }
            }
        }
        // Some CLI failures end with an error event, without a result envelope.
        for event in events.reversed() where event["type"] as? String == "error" || event["error"] != nil {
            if let text = detail((event["error"] as? [String: Any])?["message"]) ?? detail(event["message"]) { return text }
            let content = (event["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            for block in content where block["type"] as? String == "text" {
                if let text = detail(block["text"]) { return text }
            }
        }
        if let text = detail(String(decoding: stderr, as: UTF8.self)) { return text }
        if let subtype = result?["subtype"] as? String, subtype.hasPrefix("error") {
            if subtype == "error_max_turns" { return "Claude Code reached its turn limit." }
            return "Claude Code reported an error (\(subtype))."
        }
        return fallback
    }

    private static func looksLikeLimit(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("rate limit") || lower.contains("overloaded") ||
            lower.contains("usage limit") || lower.contains("weekly limit") ||
            lower.contains("hit your limit") || lower.contains("reached your limit") || lower.contains("capacity")
    }

    private static func validateStopReason(_ reason: String?, response: String) throws {
        switch reason {
        case nil, "end_turn", "stop_sequence": return
        case "refusal": throw AIError.refusal(response.isEmpty ? "Claude declined the request." : response)
        case "max_tokens", "model_context_window_exceeded", "pause_turn":
            throw AIError.limit(response.isEmpty ? "Claude stopped before completing the response (\(reason!))." : response)
        case "tool_use": throw AIError.invalidResponse("Claude requested a tool after the scoped tool call ended.")
        default: throw AIError.invalidResponse("Claude returned an unsupported stop reason: \(reason!).")
        }
    }

    private static func integer(_ value: Any?) -> Int {
        if let number = value as? NSNumber { return max(0, number.intValue) }
        if let string = value as? String, let value = Int(string) { return max(0, value) }
        return 0
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return max(0, number.doubleValue) }
        if let string = value as? String, let number = Double(string) { return max(0, number) }
        return nil
    }
}

private struct CLIProcessResult: Sendable {
    var terminationStatus: Int32
    var stdout: Data
    var stderr: Data
    var wasCancelled: Bool
    var timedOut: Bool
    var outputExceeded: Bool
    var emittedText: Bool
}

/// Owns one child process and drains both output pipes immediately. The CLI gets
/// no API-key environment variables, and all process termination is idempotent.
private final class CLIInvocation: @unchecked Sendable {
    private let process = Process()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let lock = NSLock()
    private let streaming: Bool
    private let outputLimit: Int
    private let errorLimit: Int
    private let timeout: TimeInterval
    private let onText: @Sendable (String) -> Void
    private let onLine: @Sendable (Data) -> Void
    private let trace: AIInteractionTrace?
    private let diagnosticPrefix: String
    private var stdout = Data()
    private var stderr = Data()
    private var partialLine = Data()
    // Read tool results echo base64 slide images. Bound each wire event separately
    // from the retained response, so lecture inputs do not exhaust the answer cap.
    private let maximumStreamLineBytes = 32 * 1_024 * 1_024
    private var continuation: CheckedContinuation<Void, Never>?
    private var didTerminate = false
    private var cancelled = false
    private var timedOut = false
    private var outputExceeded = false
    private var emittedText = false
    private var outputReadClosed = false
    private var errorReadClosed = false

    init(executableURL: URL,
         arguments: [String],
         workingDirectory: URL,
         promptURL: URL,
         streaming: Bool,
         outputLimit: Int,
         errorLimit: Int,
         timeout: TimeInterval,
         onText: @escaping @Sendable (String) -> Void,
         onLine: @escaping @Sendable (Data) -> Void = { _ in },
         diagnosticPrefix: String = "cli") {
        self.trace = AIDiagnostics.current
        self.diagnosticPrefix = diagnosticPrefix
        self.streaming = streaming
        self.outputLimit = outputLimit
        self.errorLimit = errorLimit
        self.timeout = timeout
        self.onText = onText
        self.onLine = onLine
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.environment = ClaudeCLIProvider.sanitizedEnvironment()
        trace?.writeJSON(diagnosticPrefix + "-invocation.json", [
            "executable": executableURL.path,
            "resolvedExecutable": executableURL.resolvingSymlinksInPath().path,
            "arguments": arguments,
            "workingDirectory": workingDirectory.path,
            "timeoutSeconds": timeout,
            "outputLimitBytes": outputLimit,
            "stderrTailLimitBytes": errorLimit,
            "PATH": process.environment?["PATH"] ?? "",
            "safeMode": process.environment?["CLAUDE_CODE_SAFE_MODE"] ?? "",
            "streaming": streaming
        ])
        process.standardInput = FileHandle(forReadingAtPath: promptURL.path) ?? FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.terminationHandler = { [weak self] _ in self?.terminated() }
    }

    func run() async throws -> CLIProcessResult {
        if Task.isCancelled { throw CancellationError() }
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let bytes = handle.availableData
            if bytes.isEmpty { self?.closedOutput(); return }
            self?.receiveOutput(bytes)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let bytes = handle.availableData
            if bytes.isEmpty { self?.closedError(); return }
            self?.receiveError(bytes)
        }
        do {
            try process.run()
            trace?.record("process_started", ["process": diagnosticPrefix, "pid": process.processIdentifier])
        }
        catch {
            trace?.failure(error, event: "process_launch_failed", fields: ["process": diagnosticPrefix])
            throw AIError.configuration("Claude Code could not start: \(error.localizedDescription)")
        }
        if Task.isCancelled { cancel() }

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.timeoutReached()
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if didTerminate { lock.unlock(); continuation.resume() }
            else { self.continuation = continuation; lock.unlock() }
        }

        // Process termination closes the parent's pipe endpoints. Handlers can
        // still have one final callback queued, so synchronize before snapshot.
        waitForPipesToDrain(until: Date().addingTimeInterval(2))
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        let result = snapshotResult()
        trace?.flush(diagnosticPrefix + "-stdout.txt")
        trace?.flush(diagnosticPrefix + "-stderr.txt")
        if result.stderr.count == errorLimit {
            // Keep the final error even when noisy stderr exhausted the raw log cap.
            trace?.writeText(diagnosticPrefix + "-stderr-tail.txt", String(decoding: result.stderr, as: UTF8.self))
        }
        trace?.writeJSON(diagnosticPrefix + "-exit.json", [
            "pid": process.processIdentifier,
            "terminationStatus": result.terminationStatus,
            "terminationReason": process.terminationReason == .exit ? "exit" : "signal",
            "cancelled": result.wasCancelled, "timedOut": result.timedOut,
            "outputExceeded": result.outputExceeded,
            "retainedStdoutBytes": result.stdout.count, "retainedStderrBytes": result.stderr.count,
            "pipesDrained": pipesDrained()
        ])
        trace?.record("process_exited", ["process": diagnosticPrefix, "terminationStatus": result.terminationStatus,
                                         "timedOut": result.timedOut, "cancelled": result.wasCancelled])
        return result
    }

    func cancel() { stop(asTimeout: false, outputLimit: false) }

    private func timeoutReached() { stop(asTimeout: true, outputLimit: false) }

    private func stop(asTimeout: Bool, outputLimit: Bool) {
        lock.lock()
        if didTerminate { lock.unlock(); return }
        cancelled = cancelled || (!asTimeout && !outputLimit)
        timedOut = timedOut || asTimeout
        outputExceeded = outputExceeded || outputLimit
        let pid = process.processIdentifier
        lock.unlock()

        guard pid > 0 else { return }
        _ = kill(pid, SIGINT)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.isRunning else { return }
            _ = kill(pid, SIGTERM)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, self.isRunning else { return }
                _ = kill(pid, SIGKILL)
            }
        }
    }

    private var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return !didTerminate
    }

    private func snapshotResult() -> CLIProcessResult {
        lock.lock(); defer { lock.unlock() }
        if streaming, !outputExceeded, !partialLine.isEmpty {
            let line = Self.compactToolResult(partialLine)
            if retainOutput(line) {
                trace?.appendBytes(diagnosticPrefix + "-stdout.txt", line)
                emitTextDelta(from: line)
            } else {
                outputExceeded = true
            }
            partialLine.removeAll()
        }
        return CLIProcessResult(terminationStatus: process.terminationStatus,
                                stdout: stdout,
                                stderr: stderr,
                                wasCancelled: cancelled,
                                timedOut: timedOut,
                                outputExceeded: outputExceeded,
                                emittedText: emittedText)
    }

    private func pipesDrained() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return outputReadClosed && errorReadClosed
    }

    private func waitForPipesToDrain(until deadline: Date) {
        while Date() < deadline {
            if pipesDrained() { return }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    private func terminated() {
        lock.lock()
        didTerminate = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }

    private func receiveOutput(_ bytes: Data) {
        lock.lock(); defer { lock.unlock() }
        guard !outputExceeded else { return }
        guard streaming else {
            trace?.appendBytes(diagnosticPrefix + "-stdout.txt", bytes)
            if !retainOutput(bytes) { stopForOutputLimit() }
            return
        }
        var start = bytes.startIndex
        while start < bytes.endIndex {
            let newline = bytes[start...].firstIndex(of: 0x0A)
            let end = newline ?? bytes.endIndex
            guard partialLine.count + bytes.distance(from: start, to: end) <= maximumStreamLineBytes else {
                stopForOutputLimit()
                return
            }
            partialLine.append(bytes[start..<end])
            guard let newline else { return }
            let line = Self.compactToolResult(partialLine)
            partialLine.removeAll(keepingCapacity: true)
            guard retainOutput(line + Data([0x0A])) else {
                stopForOutputLimit()
                return
            }
            trace?.appendBytes(diagnosticPrefix + "-stdout.txt", line + Data([0x0A]))
            emitTextDelta(from: line)
            start = bytes.index(after: newline)
        }
    }

    private func retainOutput(_ bytes: Data) -> Bool {
        guard stdout.count + bytes.count <= outputLimit else { return false }
        stdout.append(bytes)
        return true
    }

    // Caller holds lock; stop acquires it itself.
    private func stopForOutputLimit() {
        outputExceeded = true
        lock.unlock()
        stop(asTimeout: false, outputLimit: true)
        lock.lock()
    }

    private static func compactToolResult(_ line: Data) -> Data {
        guard var event = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              event["type"] as? String == "user",
              var message = event["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else { return line }
        // Read tracking needs the tool ID and success flag, never echoed file data.
        message["content"] = content.map { block -> [String: Any] in
            guard block["type"] as? String == "tool_result" else { return block }
            var result = block
            result["content"] = "[tool result content omitted]"
            return result
        }
        event["message"] = message
        event.removeValue(forKey: "tool_use_result")
        event.removeValue(forKey: "tool_result_meta")
        return (try? JSONSerialization.data(withJSONObject: event)) ?? line
    }

    private func emitTextDelta(from line: Data) {
        onLine(line)
        guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = message["type"] as? String else { return }
        let event = type == "stream_event" ? message["event"] as? [String: Any] : message
        guard let event, event["type"] as? String == "content_block_delta",
              let delta = event["delta"] as? [String: Any],
              delta["type"] as? String == "text_delta",
              let text = delta["text"] as? String else { return }
        emittedText = true
        onText(text)
    }

    private func receiveError(_ bytes: Data) {
        trace?.appendBytes(diagnosticPrefix + "-stderr.txt", bytes)
        lock.lock(); defer { lock.unlock() }
        stderr.append(bytes)
        if stderr.count > errorLimit { stderr.removeFirst(stderr.count - errorLimit) }
    }

    private func closedOutput() {
        lock.lock(); defer { lock.unlock() }
        outputReadClosed = true
    }

    private func closedError() { lock.lock(); errorReadClosed = true; lock.unlock() }
}
