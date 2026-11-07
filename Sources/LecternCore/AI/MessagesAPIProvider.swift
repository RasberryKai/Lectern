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
        try Task.checkCancellation()
        let apiKey = try apiKeyProvider().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else { throw AIError.configuration("Add an Anthropic API key in Lectern settings to use the Messages API.") }

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
        onEvent(.stage("Sending"))
        if request.kind == .ask {
            return try await executeStreaming(urlRequest, onEvent: onEvent)
        }

        do {
            try Task.checkCancellation()
            let (data, response) = try await session.data(for: urlRequest)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else {
                throw AIError.transport("The Messages API returned a non-HTTP response.")
            }
            guard (200..<300).contains(http.statusCode) else {
                throw Self.httpError(status: http.statusCode, body: data)
            }
            onEvent(.stage("Writing"))
            return try Self.parseMessageResponse(data)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as AIError {
            throw error
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw AIError.transport("Messages API request failed: \(error.localizedDescription)")
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
        catch { throw AIError.configuration("The job PDF could not be read: \(error.localizedDescription)") }
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
        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do { try Task.checkCancellation(); (bytes, response) = try await session.bytes(for: request) }
        catch {
            if Task.isCancelled { throw CancellationError() }
            throw AIError.transport("Messages API stream could not start: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw AIError.transport("The Messages API returned a non-HTTP response.")
        }
        if !(200..<300).contains(http.statusCode) {
            var lines: [String] = []
            var size = 0
            for try await line in bytes.lines {
                try Task.checkCancellation()
                size += line.utf8.count
                guard size <= 1_048_576 else { break }
                lines.append(line)
            }
            throw Self.httpError(status: http.statusCode, body: Data(lines.joined(separator: "\n").utf8))
        }

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
            throw CancellationError()
        } catch let error as AIError {
            throw error
        } catch {
            if Task.isCancelled { throw CancellationError() }
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

    private static func httpError(status: Int, body: Data) -> AIError {
        let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        let errorObject = object?["error"] as? [String: Any]
        let message = errorObject?["message"] as? String ?? String(decoding: body.prefix(1_024), as: UTF8.self)
        let type = errorObject?["type"] as? String ?? ""
        if status == 429 || status == 529 || type.contains("rate_limit") || type.contains("overloaded") {
            return .limit(message.isEmpty ? "Messages API rate or capacity limit reached (HTTP \(status))." : message)
        }
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
