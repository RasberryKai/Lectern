import Foundation

/// Direct Messages API provider. It takes API credentials only from Keychain (or
/// an explicitly injected test/application closure) and never reads the CLI login.
public struct MessagesAPIProvider: AIProvider {
    public let backend: AIBackend = .messagesAPI

    private let apiKeyProvider: @Sendable () throws -> String
    private let session: URLSession
    private let model: String
    private let apiVersion: String
    private let endpoint: URL
    private let maxOutputTokens: Int
    private let maximumRequestBytes = 128 * 1_024 * 1_024

    public init(settings: AISettings = .default,
                keychain: KeychainStore = KeychainStore(),
                session: URLSession = .shared,
                endpoint: URL = URL(string: "https://api.anthropic.com/v1/messages")!) {
        let keychain = keychain
        self.init(apiKey: {
            guard let key = try keychain.loadAPIKey() else {
                throw AIError.configuration("Add an Anthropic API key in Lectern settings to use the Messages API.")
            }
            return key
        },
                  model: settings.messagesAPIModel,
                  apiVersion: settings.messagesAPIVersion,
                  maxOutputTokens: settings.maxOutputTokens,
                  session: session,
                  endpoint: endpoint)
    }

    public init(apiKey: @escaping @Sendable () throws -> String,
                model: String = AISettings.defaultMessagesAPIModel,
                apiVersion: String = AISettings.defaultAPIVersion,
                maxOutputTokens: Int = 32_768,
                session: URLSession = .shared,
                endpoint: URL = URL(string: "https://api.anthropic.com/v1/messages")!) {
        self.apiKeyProvider = apiKey
        self.model = model
        self.apiVersion = apiVersion
        self.maxOutputTokens = min(max(maxOutputTokens, 256), 128_000)
        self.session = session
        self.endpoint = endpoint
    }

    public func execute(_ request: AIRequest, onEvent: @escaping @Sendable (AIEvent) -> Void) async throws -> AIResponse {
        let recordsEvents = AIDiagnostics.current?.jobID != request.jobID
        return try await AIDiagnostics.withTrace(request: request, backend: backend) { _ in
            let trace = AIDiagnostics.current
            let forwardEvent: @Sendable (AIEvent) -> Void = { event in
                if recordsEvents { trace?.event(event) }
                onEvent(event)
            }
            trace?.phase("preflight")
            try Task.checkCancellation()
            let suppliedAPIKey = try apiKeyProvider()
            // Register the exact secret before constructing/logging an HTTP request.
            trace?.registerSecret(suppliedAPIKey)
            let apiKey = suppliedAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            trace?.registerSecret(apiKey)
            guard !apiKey.isEmpty else {
                throw AIError.configuration("Add an Anthropic API key in Lectern settings to use the Messages API.")
            }

            let response: AIResponse
            if request.kind == .chat, let snapshot = request.chatSnapshot {
                response = try await executeChat(request, snapshot: snapshot, apiKey: apiKey, onEvent: forwardEvent)
            } else {
                let pdf = try Self.pdfData(for: request)
                if let pdf, pdf.count > 96 * 1_024 * 1_024 {
                    throw AIError.limit("The PDF is too large for an inline Messages API request. Reduce its size or selected pages.")
                }

                let effectiveModel = request.model.hasPrefix("claude-") ? request.model : model
                let urlRequest = try Self.makeURLRequest(
                    prompt: request.prompt,
                    kind: request.kind,
                    pdf: pdf,
                    systemPrompt: request.systemPrompt,
                    apiKey: apiKey,
                    model: effectiveModel,
                    apiVersion: apiVersion,
                    endpoint: endpoint,
                    maxOutputTokens: maxOutputTokens
                )
                guard let bodySize = urlRequest.httpBody?.count, bodySize <= maximumRequestBytes else {
                    throw AIError.limit("The Messages API request exceeds Anthropic's 128 MB request limit.")
                }

                try Task.checkCancellation()
                trace?.phase("sending")
                forwardEvent(.stage("Sending"))
                if request.kind == .ask {
                    response = try await executeStreaming(urlRequest, onEvent: forwardEvent)
                } else {
                    response = try await executeNonStreaming(urlRequest, onEvent: forwardEvent)
                }
            }

            trace?.response(response)
            return response
        }
    }

    private func executeNonStreaming(_ request: URLRequest,
                                     onEvent: @escaping @Sendable (AIEvent) -> Void) async throws -> AIResponse {
        let trace = AIDiagnostics.current
        let prefix = trace?.httpRequest(request)
        do {
            try Task.checkCancellation()
            let (data, response) = try await session.data(for: request)
            trace?.httpResponse(response, prefix: prefix ?? "http-unknown")
            let status = (response as? HTTPURLResponse)?.statusCode
            let bodySuffix = status.map { (200..<300).contains($0) } == true ? "json" : "error.txt"
            trace?.writeText((prefix ?? "http-unknown") + "-body." + bodySuffix, String(decoding: data, as: UTF8.self))
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else {
                throw AIError.transport("The Messages API returned a non-HTTP response.")
            }
            guard (200..<300).contains(http.statusCode) else {
                trace?.phase("parsing")
                throw Self.httpError(status: http.statusCode, body: data, retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
            }
            trace?.phase("parsing")
            onEvent(.stage("Writing"))
            return try Self.parseMessageResponse(data)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as AIError {
            trace?.failure(error, event: "http_round_error", fields: ["round": prefix ?? ""])
            throw error
        } catch {
            if Task.isCancelled { throw CancellationError() }
            trace?.failure(error, event: "http_transport_error", fields: ["round": prefix ?? ""])
            throw AIError.transport("Messages API request failed: \(error.localizedDescription)")
        }
    }

    private func executeChat(_ request: AIRequest, snapshot: ChatSnapshot, apiKey: String,
                             onEvent: @escaping @Sendable (AIEvent) -> Void) async throws -> AIResponse {
        let trace = AIDiagnostics.current
        let context = ChatProviderContext(request: request, snapshot: snapshot)
        let initial = try context.initialContent()
        var read = initial.refs
        for ref in read { onEvent(.read(ref)) }
        var messages: [[String: Any]] = [["role": "user", "content": initial.blocks]]
        var total = AIUsage()
        var proposed: [ChatCardEdit] = []
        var searched = false
        for _ in 0..<16 {
            try Task.checkCancellation()
            var urlRequest = try Self.makeURLRequest(prompt: request.prompt, kind: .chat, pdf: nil,
                systemPrompt: request.systemPrompt, apiKey: apiKey,
                model: request.model.hasPrefix("claude-") ? request.model : model,
                apiVersion: apiVersion, endpoint: endpoint, maxOutputTokens: maxOutputTokens)
            var body = try JSONSerialization.jsonObject(with: urlRequest.httpBody!) as! [String: Any]
            body["messages"] = messages
            body["stream"] = true
            body["tools"] = Self.chatTools
            urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
            urlRequest.setValue("text/event-stream", forHTTPHeaderField: "accept")
            guard urlRequest.httpBody!.count <= maximumRequestBytes else { throw AIError.limit("The chat exceeds the Messages API request limit.") }
            let round = try await chatRound(urlRequest, onEvent: onEvent)
            trace?.phase("parsing")
            total.inputTokens += round.usage.inputTokens; total.outputTokens += round.usage.outputTokens
            total.cacheCreationInputTokens = (total.cacheCreationInputTokens ?? 0) + (round.usage.cacheCreationInputTokens ?? 0)
            total.cacheReadInputTokens = (total.cacheReadInputTokens ?? 0) + (round.usage.cacheReadInputTokens ?? 0)
            let blocks = round.blocks
            let tools = blocks.filter { $0["type"] as? String == "tool_use" }
            if tools.isEmpty {
                let text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
                try Self.validateStopReason(round.stopReason, response: text)
                var reply: ChatReply
                do { reply = try JSONDecoder().decode(ChatReply.self, from: Data(text.utf8)) }
                catch { throw AIError.invalidResponse("Claude returned invalid structured chat JSON.") }
                // Tool calls propose changes; JobRunner validates/apply rules against frozen revisions.
                for edit in proposed { reply.edits.removeAll { $0.cardID == edit.cardID }; reply.edits.append(edit) }
                var response = AIResponse(content: String(decoding: try JSONEncoder().encode(reply), as: UTF8.self), usage: total)
                response.read = read; response.searchedLecture = searched
                return response
            }
            guard round.stopReason == "tool_use" else { throw AIError.invalidResponse("Claude returned unfinished chat tool calls.") }
            messages.append(["role": "assistant", "content": blocks])
            var results: [[String: Any]] = []
            trace?.phase("tool_execution")
            for tool in tools {
                try Task.checkCancellation()
                guard let id = tool["id"] as? String, let name = tool["name"] as? String,
                      let input = tool["input"] as? [String: Any] else { throw AIError.invalidResponse("Malformed chat tool call.") }
                var content: [[String: Any]]
                switch name {
                case "read_slides":
                    guard let pages = input["pages"] as? [Int], !pages.isEmpty, pages.count <= 100 else { throw AIError.invalidResponse("read_slides requires 1–100 page numbers.") }
                    onEvent(.stage("Reading slides…")); content = try context.slides(pages)
                    for page in pages { let ref = ContextRef.slide(page); if !read.contains(ref) { read.append(ref) }; onEvent(.read(ref)) }
                    if pages.contains(where: { !initial.refs.contains(.slide($0)) }) { searched = true }
                case "get_cards":
                    guard let strings = input["ids"] as? [String] else { throw AIError.invalidResponse("get_cards requires an array of card references, such as [\"C12\"].") }
                    let ids = try context.cardIDs(strings)
                    content = [["type": "text", "text": try context.cards(ids)]]
                    for id in ids { let ref = ContextRef.card(id); if !read.contains(ref) { read.append(ref) }; onEvent(.read(ref)) }
                    if !initial.refs.contains(.allCards), ids.contains(where: { !initial.refs.contains(.card($0)) }) { searched = true }
                case "read_images":
                    guard let strings = input["ids"] as? [String], !strings.isEmpty, strings.count <= 4,
                          strings.allSatisfy({ UUID(uuidString: $0) != nil }) else { throw AIError.invalidResponse("read_images requires 1–4 valid uploaded image IDs.") }
                    onEvent(.stage("Reading uploaded images…"))
                    content = try context.uploadedImages(strings.compactMap(UUID.init(uuidString:)))
                case "edit_cards":
                    guard let edits = input["edits"], JSONSerialization.isValidJSONObject(edits) else { throw AIError.invalidResponse("edit_cards requires edits.") }
                    let decoded = try JSONDecoder().decode([ChatCardEdit].self, from: JSONSerialization.data(withJSONObject: edits))
                    guard !decoded.isEmpty, decoded.allSatisfy({ edit in snapshot.cards.contains { $0.id == edit.cardID && $0.currentRevisionID == edit.baseRevisionID } }) else { throw AIError.invalidResponse("Card edit does not match the frozen card revision.") }
                    proposed += decoded
                    content = [["type": "text", "text": "Changes proposed for review. Do not repeat card contents in the answer."]]
                default: throw AIError.invalidResponse("Unknown chat tool: \(name).")
                }
                results.append(["type": "tool_result", "tool_use_id": id, "content": content])
            }
            messages.append(["role": "user", "content": results])
        }
        throw AIError.limit("Claude reached the chat lookup limit. Ask a more focused question.")
    }

    private static var chatTools: [[String: Any]] {
        let array: (String, [String: Any]) -> [String: Any] = { key, items in
            ["type": "object", "additionalProperties": false, "required": [key], "properties": [key: ["type": "array", "items": items]]]
        }
        let edit = ["type": "object", "additionalProperties": false, "required": ["cardID", "baseRevisionID", "front", "back"],
                    "properties": Dictionary(uniqueKeysWithValues: ["cardID", "baseRevisionID", "front", "back"].map { ($0, ["type": "string"]) })] as [String: Any]
        return [
            ["name": "read_slides", "description": "Read frozen lecture slide PNGs and extracted text.", "input_schema": array("pages", ["type": "integer"])],
            ["name": "read_images", "description": "Read uploaded images from the frozen image index by UUID, including prior-turn uploads.", "input_schema": array("ids", ["type": "string"])],
            ["name": "get_cards", "description": "Read current frozen cards and exact edit IDs by displayed reference (for example C12) or UUID. Supports the entire deck, including more than 100 cards.", "input_schema": array("ids", ["type": "string"])],
            ["name": "edit_cards", "description": "Propose edits using each card's frozen base revision ID. Does not modify cards.", "input_schema": array("edits", edit)]
        ]
    }

    private func chatRound(_ request: URLRequest, onEvent: @escaping @Sendable (AIEvent) -> Void) async throws
        -> (blocks: [[String: Any]], usage: AIUsage, stopReason: String?) {
        let trace = AIDiagnostics.current
        trace?.phase("sending")
        let prefix = trace?.httpRequest(request) ?? "http-unknown"
        let sseFilename = prefix + "-body.sse"
        defer { trace?.flush(sseFilename) }
        do {
            onEvent(.stage("Sending"))
            let (bytes, response) = try await session.bytes(for: request)
            trace?.httpResponse(response, prefix: prefix)
            guard let http = response as? HTTPURLResponse else { throw AIError.transport("Non-HTTP chat response.") }
            guard (200..<300).contains(http.statusCode) else {
                trace?.phase("parsing")
                var body = Data()
                defer { trace?.writeText(prefix + "-body.error.txt", String(decoding: body, as: UTF8.self)) }
                do {
                    try Task.checkCancellation()
                    for try await byte in bytes {
                        if body.count >= 1_048_576 { break }
                        body.append(byte)
                    }
                } catch {
                    if Task.isCancelled { throw CancellationError() }
                    trace?.failure(error, event: "http_error_body_read_error", fields: ["round": prefix])
                    throw error
                }
                let error = Self.httpError(status: http.statusCode, body: body, retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
                throw error
            }
            var blocks: [Int: [String: Any]] = [:], partialInputs: [Int: String] = [:]
            var usage = AIUsage(), stop: String?, stopped = false, size = 0
            var preview = ChatMessageStream()
            trace?.phase("parsing")
            for try await line in bytes.lines {
                try Task.checkCancellation(); size += line.utf8.count
                trace?.appendBytes(sseFilename, Data((line + "\n").utf8))
                guard size <= 16 * 1_024 * 1_024 else { throw AIError.limit("Chat response exceeded 16 MB.") }
                guard line.hasPrefix("data:"), let event = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(5).utf8)) as? [String: Any], let type = event["type"] as? String else { continue }
                let index = event["index"] as? Int ?? 0
                switch type {
                case "message_start": usage = Self.usage(from: (event["message"] as? [String: Any])?["usage"] as? [String: Any] ?? [:])
                case "content_block_start": blocks[index] = event["content_block"] as? [String: Any]
                case "content_block_delta":
                    let delta = event["delta"] as? [String: Any] ?? [:]
                    if let text = delta["text"] as? String {
                        blocks[index, default: ["type": "text"]]["text"] = (blocks[index]?["text"] as? String ?? "") + text
                        let visible = preview.append(text); if !visible.isEmpty { onEvent(.text(visible)) }
                    }
                    if let json = delta["partial_json"] as? String { partialInputs[index, default: ""] += json }
                case "content_block_stop":
                    if let input = partialInputs[index] { blocks[index]?["input"] = try JSONSerialization.jsonObject(with: Data(input.utf8)) }
                case "message_delta":
                    usage = Self.usage(from: event["usage"] as? [String: Any] ?? [:], previous: usage)
                    stop = (event["delta"] as? [String: Any])?["stop_reason"] as? String
                case "message_stop": stopped = true
                case "error":
                    let error = event["error"] as? [String: Any] ?? [:]
                    throw Self.httpError(status: (error["type"] as? String ?? "").contains("rate_limit") ? 429 : 500, body: try JSONSerialization.data(withJSONObject: ["error": error]))
                default: break
                }
            }
            guard stopped else { throw AIError.transport("Chat stream ended before message_stop.") }
            return (blocks.keys.sorted().compactMap { blocks[$0] }, usage, stop)
        } catch is CancellationError {
            trace?.record("http_round_cancelled", ["round": prefix])
            throw CancellationError()
        } catch let error as AIError {
            trace?.failure(error, event: "http_round_error", fields: ["round": prefix])
            throw error
        } catch {
            if Task.isCancelled { throw CancellationError() }
            trace?.failure(error, event: "http_round_error", fields: ["round": prefix])
            throw AIError.transport("Chat request failed: \(error.localizedDescription)")
        }
    }

    /// Request builder is internal so tests can inspect the exact payload without network access.
    static func makeURLRequest(prompt: String,
                               kind: JobKind,
                               pdf: Data?,
                               systemPrompt: String = PromptBuilder.systemPrompt,
                               apiKey: String,
                               model: String,
                               apiVersion: String,
                               endpoint: URL,
                               maxOutputTokens: Int) throws -> URLRequest {
        var content: [[String: Any]] = []
        let segments = cachedPromptSegments(prompt)
        if let segments {
            content.append([
                "type": "text",
                "text": segments.stable,
                "cache_control": ["type": "ephemeral"]
            ])
            content.append(["type": "text", "text": segments.dynamic])
        } else {
            content.append(["type": "text", "text": prompt])
        }
        if let pdf {
            content.append([
                "type": "document",
                "source": [
                    "type": "base64",
                    "media_type": "application/pdf",
                    "data": pdf.base64EncodedString()
                ]
            ])
        }

        var body: [String: Any] = [
            "model": model,
            "max_tokens": outputLimit(for: kind, configured: maxOutputTokens),
            "system": [["type": "text", "text": systemPrompt]],
            "messages": [["role": "user", "content": content]],
            "stream": kind == .ask
        ]
        if let schemaText = AIOutputSchema.json(for: kind) {
            let schemaData = Data(schemaText.utf8)
            let rawSchema = try JSONSerialization.jsonObject(with: schemaData)
            body["output_config"] = [
                "format": ["type": "json_schema", "schema": sanitizedSchema(rawSchema)],
                "effort": effort(for: kind)
            ]
        } else {
            body["output_config"] = ["effort": effort(for: kind)]
        }

        let bodyData = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .fragmentsAllowed])
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 1_200
        request.httpBody = bodyData
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        if kind == .ask { request.setValue("text/event-stream", forHTTPHeaderField: "accept") }
        return request
    }

    static func outputLimit(for kind: JobKind, configured: Int) -> Int {
        let cap: Int
        switch kind {
        case .generate, .chat: cap = 32_768
        case .revise: cap = 8_192
        case .ask: cap = 8_192
        case .distil: cap = 2_048
        }
        return min(max(configured, 256), cap)
    }

    static func effort(for kind: JobKind) -> String {
        switch kind {
        case .generate: "high"
        case .revise, .ask, .chat: "medium"
        case .distil: "low"
        }
    }

    private static func pdfData(for request: AIRequest) throws -> Data? {
        if let pdf = request.pdf { return pdf }
        let snapshotURL = request.workingDirectory.appendingPathComponent("input.pdf", isDirectory: false)
        guard FileManager.default.fileExists(atPath: snapshotURL.path) else { return nil }
        do { return try Data(contentsOf: snapshotURL) }
        catch {
            AIDiagnostics.current?.failure(error, event: "pdf_read_error", fields: ["path": snapshotURL.path])
            throw AIError.configuration("The job PDF could not be read: \(error.localizedDescription)")
        }
    }

    private static func cachedPromptSegments(_ prompt: String) -> (stable: String, dynamic: String)? {
        let marker = "\n\nINCLUDED LEARNING POINTS"
        guard let range = prompt.range(of: marker) else { return nil }
        let stable = String(prompt[..<range.lowerBound])
        let dynamic = String(prompt[range.lowerBound...])
        // Opus 5.5 needs 512 tokens before a cache breakpoint is useful.
        guard stable.utf8.count >= 2_048 else { return nil }
        return (stable, dynamic)
    }

    /// The Messages API supports only a subset of JSON Schema array constraints.
    /// Cardinality is checked again by JobRunner before data is committed.
    private static func sanitizedSchema(_ schema: Any) -> Any {
        if let object = schema as? [String: Any] {
            var copy: [String: Any] = [:]
            for (key, value) in object {
                // Anthropic's structured-output subset ignores or rejects
                // numeric constraints; JobRunner validates all cardinality.
                if key == "maxItems" || key == "minItems" { continue }
                copy[key] = sanitizedSchema(value)
            }
            return copy
        }
        if let array = schema as? [Any] { return array.map(sanitizedSchema) }
        return schema
    }

    private func executeStreaming(_ request: URLRequest, onEvent: @escaping @Sendable (AIEvent) -> Void) async throws -> AIResponse {
        let trace = AIDiagnostics.current
        let prefix = trace?.httpRequest(request) ?? "http-unknown"
        let sseFilename = prefix + "-body.sse"
        defer { trace?.flush(sseFilename) }
        trace?.phase("sending")
        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do { try Task.checkCancellation(); (bytes, response) = try await session.bytes(for: request) }
        catch {
            if Task.isCancelled { throw CancellationError() }
            trace?.failure(error, event: "http_transport_error", fields: ["round": prefix])
            throw AIError.transport("Messages API stream could not start: \(error.localizedDescription)")
        }
        trace?.httpResponse(response, prefix: prefix)
        guard let http = response as? HTTPURLResponse else {
            throw AIError.transport("The Messages API returned a non-HTTP response.")
        }
        if !(200..<300).contains(http.statusCode) {
            trace?.phase("parsing")
            var body = Data()
            defer { trace?.writeText(prefix + "-body.error.txt", String(decoding: body, as: UTF8.self)) }
            do {
                try Task.checkCancellation()
                for try await byte in bytes {
                    if body.count >= 1_048_576 { break }
                    body.append(byte)
                }
            } catch {
                if Task.isCancelled { throw CancellationError() }
                trace?.failure(error, event: "http_error_body_read_error", fields: ["round": prefix])
                throw error
            }
            let error = Self.httpError(status: http.statusCode, body: body, retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
            trace?.failure(error, event: "http_round_error", fields: ["round": prefix])
            throw error
        }

        trace?.phase("parsing")
        onEvent(.stage("Writing"))
        var dataLines: [String] = []
        var responseText = ""
        var usage = AIUsage()
        var sawMessageStop = false
        var stopReason: String?
        var totalBytes = 0

        func processEventData() throws {
            guard !dataLines.isEmpty else { return }
            let payload = Data(dataLines.joined(separator: "\n").utf8)
            dataLines.removeAll(keepingCapacity: true)
            guard let event = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
                  let type = event["type"] as? String else { return }
            if type == "error" {
                let errorObject = event["error"] as? [String: Any]
                let message = errorObject?["message"] as? String ?? "Messages API stream failed."
                let errorType = errorObject?["type"] as? String ?? ""
                if errorType.contains("rate_limit") || errorType.contains("overloaded") {
                    throw AIError.limit(message)
                }
                throw AIError.transport(message)
            }
            if type == "message_start", let message = event["message"] as? [String: Any],
               let usageObject = message["usage"] as? [String: Any] {
                usage = Self.usage(from: usageObject, previous: usage)
            } else if type == "message_delta", let usageObject = event["usage"] as? [String: Any] {
                usage = Self.usage(from: usageObject, previous: usage)
                let delta = event["delta"] as? [String: Any]
                if let reason = delta?["stop_reason"] as? String { stopReason = reason }
            } else if type == "message_delta",
                      let reason = (event["delta"] as? [String: Any])?["stop_reason"] as? String {
                stopReason = reason
            } else if type == "content_block_delta",
                      let delta = event["delta"] as? [String: Any],
                      delta["type"] as? String == "text_delta",
                      let text = delta["text"] as? String {
                responseText += text
                onEvent(.text(text))
            } else if type == "message_stop" {
                sawMessageStop = true
            }
        }

        do {
            for try await line in bytes.lines {
                trace?.appendBytes(sseFilename, Data((line + "\n").utf8))
                try Task.checkCancellation()
                totalBytes += line.utf8.count + 1
                guard totalBytes <= 16 * 1_024 * 1_024 else {
                    throw AIError.limit("Messages API stream exceeded Lectern's 16 MB response limit.")
                }
                if line.isEmpty {
                    try processEventData()
                } else if line.hasPrefix("data:") {
                    var value = String(line.dropFirst(5))
                    if value.first == " " { value.removeFirst() }
                    if value != "[DONE]" {
                        dataLines.append(value)
                        // Anthropic emits one JSON object per data line. Process
                        // it immediately because URLSession.AsyncBytes.lines may
                        // omit empty SSE separator lines on some Foundation builds.
                        try processEventData()
                    }
                }
            }
            try processEventData()
        } catch is CancellationError {
            trace?.record("http_round_cancelled", ["round": prefix])
            throw CancellationError()
        } catch let error as AIError {
            trace?.failure(error, event: "http_round_error", fields: ["round": prefix])
            throw error
        } catch {
            if Task.isCancelled { throw CancellationError() }
            trace?.failure(error, event: "http_round_error", fields: ["round": prefix])
            throw AIError.transport("Messages API stream ended unexpectedly: \(error.localizedDescription)")
        }

        guard sawMessageStop else { throw AIError.transport("Messages API stream ended before message_stop.") }
        try Self.validateStopReason(stopReason, response: responseText)
        guard !responseText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIError.invalidResponse("Claude returned an empty answer.")
        }
        return AIResponse(content: responseText, usage: usage)
    }

    static func parseMessageResponse(_ data: Data) throws -> AIResponse {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIError.invalidResponse("Messages API returned invalid JSON.")
        }
        if let apiError = object["error"] as? [String: Any] {
            let message = apiError["message"] as? String ?? "Messages API request failed."
            let type = apiError["type"] as? String ?? ""
            if type.contains("rate_limit") || type.contains("overloaded") { throw AIError.limit(message) }
            throw AIError.transport(message)
        }

        let blocks = object["content"] as? [[String: Any]] ?? []
        let refusal = blocks.first(where: { $0["type"] as? String == "refusal" })?["refusal"] as? String
        if object["stop_reason"] as? String == "refusal" || refusal != nil {
            throw AIError.refusal(refusal ?? blocks.compactMap { $0["text"] as? String }.joined())
        }
        try validateStopReason(object["stop_reason"] as? String,
                               response: blocks.compactMap { $0["text"] as? String }.joined())
        let text = blocks.compactMap { block -> String? in
            guard block["type"] as? String == "text" else { return nil }
            return block["text"] as? String
        }.joined()
        guard !text.isEmpty else { throw AIError.invalidResponse("Messages API response contained no text block.") }
        let usageObject = object["usage"] as? [String: Any] ?? [:]
        return AIResponse(content: text, usage: usage(from: usageObject))
    }

    static func textDelta(fromStreamData data: Data) -> String? {
        guard let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              event["type"] as? String == "content_block_delta",
              let delta = event["delta"] as? [String: Any],
              delta["type"] as? String == "text_delta" else { return nil }
        return delta["text"] as? String
    }

    private static func usage(from object: [String: Any], previous: AIUsage = AIUsage()) -> AIUsage {
        let input = int(object["input_tokens"] ?? object["inputTokens"])
        let cacheCreation = int(object["cache_creation_input_tokens"] ?? object["cacheCreationInputTokens"])
        let cacheRead = int(object["cache_read_input_tokens"] ?? object["cacheReadInputTokens"])
        let output = int(object["output_tokens"] ?? object["outputTokens"])
        let totalInput = input + cacheCreation + cacheRead
        return AIUsage(inputTokens: max(previous.inputTokens, totalInput),
                       outputTokens: max(previous.outputTokens, output),
                       costUSD: number(object["total_cost_usd"] ?? object["costUSD"]) ?? previous.costUSD,
                       cacheCreationInputTokens: object["cache_creation_input_tokens"] == nil ? previous.cacheCreationInputTokens : cacheCreation,
                       cacheReadInputTokens: object["cache_read_input_tokens"] == nil ? previous.cacheReadInputTokens : cacheRead)
    }

    private static func int(_ value: Any?) -> Int {
        if let number = value as? NSNumber { return max(0, number.intValue) }
        if let string = value as? String, let number = Int(string) { return max(0, number) }
        return 0
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private static func httpError(status: Int, body: Data, retryAfter: String? = nil) -> AIError {
        let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        let errorObject = object?["error"] as? [String: Any]
        let message = errorObject?["message"] as? String ?? String(decoding: body.prefix(1_024), as: UTF8.self)
        let type = errorObject?["type"] as? String ?? ""
        if status == 429 || status == 529 || type.contains("rate_limit") || type.contains("overloaded") {
            return .limit((message.isEmpty ? "Messages API rate or capacity limit reached (HTTP \(status))." : message) + (retryAfter.map { " Retry after: \($0)." } ?? ""))
        }
        if status == 401 || status == 403 { return .configuration(message.isEmpty ? "Check your Anthropic API key in Settings." : message) }
        return .transport(message.isEmpty ? "Messages API returned HTTP \(status)." : message)
    }

    private static func validateStopReason(_ reason: String?, response: String) throws {
        switch reason {
        case nil, "end_turn", "stop_sequence": return
        case "refusal": throw AIError.refusal(response.isEmpty ? "Claude declined the request." : response)
        case "max_tokens", "model_context_window_exceeded", "pause_turn":
            throw AIError.limit(response.isEmpty ? "Claude stopped before completing the response (\(reason!))." : response)
        case "tool_use": throw AIError.invalidResponse("Claude requested a tool although Lectern supplied none.")
        default: throw AIError.invalidResponse("Claude returned an unsupported stop reason: \(reason!).")
        }
    }
}
