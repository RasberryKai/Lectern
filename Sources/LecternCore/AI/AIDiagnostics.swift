import Foundation
import CryptoKit

/// A task-local trace joins transport diagnostics to validation and persistence.
/// Logging is best-effort: a full disk must not turn a saved answer into a failure.
enum AIDiagnostics {
    @TaskLocal static var current: AIInteractionTrace?

    static func withTrace<T>(request: AIRequest, backend: AIBackend,
                             isolation: isolated (any Actor)? = #isolation,
                             operation: (AIInteractionTrace) async throws -> T) async throws -> T {
        if let current, current.jobID == request.jobID { return try await operation(current) }
        let trace = AIInteractionTrace(request: request, backend: backend)
        return try await $current.withValue(trace) {
            do {
                let result = try await operation(trace)
                trace.finish(status: "succeeded")
                return result
            } catch {
                trace.finish(status: error is CancellationError || Task.isCancelled ? "cancelled" : "failed", error: error)
                throw error
            }
        }
    }
}

/// One immutable attempt directory per execution; retrying never destroys evidence.
/// Files are owner-only and bounded. Binary attachments remain in the frozen job.
final class AIInteractionTrace: @unchecked Sendable {
    let jobID: UUID
    let directory: URL
    private let lock = NSRecursiveLock()
    private let startedAt = Date()
    private var summary: [String: Any]
    private var secrets: [String]
    private var fileSizes: [String: Int] = [:]
    private var pending: [String: Data] = [:]
    private var truncated = Set<String>()
    private var totalBytes = 0
    private var httpCount = 0
    private var available = false
    private var warned = false
    private let fileLimit: Int
    private let totalLimit: Int

    init(request: AIRequest, backend: AIBackend, fileLimit: Int = 16 * 1_024 * 1_024,
         totalLimit: Int = 64 * 1_024 * 1_024) {
        jobID = request.jobID
        self.fileLimit = fileLimit
        self.totalLimit = totalLimit
        secrets = ProcessInfo.processInfo.environment.compactMap { key, value in
            Self.isSecretKey(key) && value.count >= 4 ? value : nil
        }
        let root: URL
        if FileManager.default.fileExists(atPath: request.workingDirectory.path) {
            root = request.workingDirectory.appendingPathComponent("ai-logs", isDirectory: true)
        } else {
            root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Lectern/AI/\(request.jobID)", isDirectory: true)
        }
        let stamp = ISO8601DateFormatter().string(from: startedAt).replacingOccurrences(of: ":", with: "-")
        directory = root.appendingPathComponent("\(stamp)-\(UUID().uuidString)", isDirectory: true)
        summary = ["schemaVersion": 1, "jobID": request.jobID.uuidString, "attemptID": directory.lastPathComponent,
                   "backend": backend.rawValue, "kind": request.kind.rawValue, "requestedModel": request.model,
                   "workingDirectory": request.workingDirectory.path, "startedAt": Self.timestamp(startedAt),
                   "status": "running", "phase": "preflight", "logDirectory": directory.path,
                   "osVersion": ProcessInfo.processInfo.operatingSystemVersionString,
                   "appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development",
                   "appBuild": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
                   "appExecutable": Bundle.main.executableURL?.path ?? "unknown",
                   "processID": ProcessInfo.processInfo.processIdentifier]
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            available = true
        } catch { warn(error) }
        persistSummary()
        writeJSON("request.json", ["jobID": request.jobID.uuidString, "kind": request.kind.rawValue,
                                  "model": request.model, "systemPrompt": request.systemPrompt, "prompt": request.prompt,
                                  "workingDirectory": request.workingDirectory.path,
                                  "pdfBytes": request.pdf?.count ?? 0,
                                  "pdfSHA256": request.pdf.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } ?? "",
                                  "chatSnapshot": request.chatSnapshot.flatMap { try? JSONEncoder().encode($0) }
                                    .flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? NSNull()])
        record("interaction_started")
    }

    func registerSecret(_ secret: String) {
        lock.lock(); defer { lock.unlock() }
        if !secret.isEmpty { secrets.append(secret) }
    }

    func phase(_ phase: String) {
        lock.lock(); defer { lock.unlock() }
        summary["phase"] = phase
        persistSummary()
        record("phase", ["name": phase])
    }

    func record(_ event: String, _ fields: [String: Any] = [:]) {
        lock.lock(); defer { lock.unlock() }
        var object = fields
        object["event"] = event
        object["timestamp"] = Self.timestamp(Date())
        object["elapsedMilliseconds"] = Int(Date().timeIntervalSince(startedAt) * 1_000)
        guard let data = try? JSONSerialization.data(withJSONObject: sanitize(object), options: [.sortedKeys, .fragmentsAllowed]) else { return }
        append("events.jsonl", data: data + Data([0x0A]))
    }

    func event(_ event: AIEvent) {
        switch event {
        case .stage(let value): record("stage", ["value": value])
        case .read(let ref): record("context_read", ["reference": String(describing: ref)])
        case .text(let text): appendBytes("preview.txt", Data(text.utf8))
        }
    }

    func response(_ response: AIResponse) {
        if let data = try? JSONEncoder().encode(response), let json = try? JSONSerialization.jsonObject(with: data) {
            writeJSON("response.json", json)
        }
        record("provider_succeeded")
    }

    func failure(_ error: Error, event: String, fields: [String: Any] = [:]) {
        lock.lock(); defer { lock.unlock() }
        var fields = fields
        fields["error"] = errorDetails(error)
        fields["phase"] = summary["phase"]
        if summary["failurePhase"] == nil { summary["failurePhase"] = summary["phase"] }
        persistSummary()
        record(event, fields)
    }

    func writeJSON(_ filename: String, _ value: Any) {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? JSONSerialization.data(withJSONObject: sanitize(value), options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]) else { return }
        writeText(filename, String(decoding: data, as: UTF8.self))
    }

    func writeText(_ filename: String, _ text: String) {
        lock.lock(); defer { lock.unlock() }
        append(filename, data: Data(redact(text).utf8))
    }

    /// Buffer until newline so credentials split across pipe callbacks are redacted together.
    /// Oversized unterminated lines are dropped and explicitly marked, never unbounded in memory.
    func appendBytes(_ filename: String, _ bytes: Data) {
        lock.lock(); defer { lock.unlock() }
        pending[filename, default: Data()].append(bytes)
        guard var buffer = pending[filename] else { return }
        if let newline = buffer.lastIndex(of: 0x0A) {
            writeText(filename, String(decoding: buffer[...newline], as: UTF8.self))
            buffer.removeSubrange(...newline)
        }
        if buffer.count > fileLimit {
            markTruncated(filename)
            buffer.removeAll()
        }
        pending[filename] = buffer
    }

    func flush(_ filename: String) {
        lock.lock(); defer { lock.unlock() }
        if let bytes = pending.removeValue(forKey: filename), !bytes.isEmpty {
            writeText(filename, String(decoding: bytes, as: UTF8.self))
        }
    }

    func httpRequest(_ request: URLRequest) -> String {
        lock.lock(); defer { lock.unlock() }
        httpCount += 1
        let prefix = String(format: "http-%02d", httpCount)
        // Never serialize all headers: URLRequest contains the API key.
        let headers = ["anthropic-version", "anthropic-beta", "content-type", "accept"].reduce(into: [String: String]()) {
            if let value = request.value(forHTTPHeaderField: $1) { $0[$1] = value }
        }
        var url = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        url?.user = nil; url?.password = nil; url?.query = nil; url?.fragment = nil
        writeJSON(prefix + "-request.json", ["url": url?.string ?? "", "method": request.httpMethod ?? "POST",
                   "headers": headers, "bodyBytes": request.httpBody?.count ?? 0,
                   "body": request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? NSNull()])
        record("http_request", ["round": prefix, "bodyBytes": request.httpBody?.count ?? 0])
        return prefix
    }

    func httpResponse(_ response: URLResponse, prefix: String) {
        let http = response as? HTTPURLResponse
        let headers = ["request-id", "x-request-id", "retry-after", "content-type", "anthropic-ratelimit-requests-remaining", "anthropic-ratelimit-tokens-remaining"].reduce(into: [String: String]()) {
            if let value = http?.value(forHTTPHeaderField: $1) { $0[$1] = value }
        }
        writeJSON(prefix + "-response.json", ["status": http?.statusCode ?? 0, "headers": headers])
        record("http_response", ["round": prefix, "status": http?.statusCode ?? 0, "headers": headers])
    }

    func finish(status: String, error: Error? = nil) {
        lock.lock(); defer { lock.unlock() }
        for filename in Array(pending.keys) { flush(filename) }
        summary["status"] = status
        summary["finishedAt"] = Self.timestamp(Date())
        summary["durationMilliseconds"] = Int(Date().timeIntervalSince(startedAt) * 1_000)
        if let error {
            if summary["failurePhase"] == nil { summary["failurePhase"] = summary["phase"] }
            summary["error"] = sanitize(errorDetails(error))
        }
        record("interaction_finished", ["status": status, "phase": summary["phase"] ?? "unknown"])
        persistSummary()
    }

    private func errorDetails(_ error: Error, depth: Int = 0) -> [String: Any] {
        let nsError = error as NSError
        var detail: [String: Any] = ["type": String(reflecting: type(of: error)), "description": boundedDetail(error.localizedDescription),
                                   "debugDescription": boundedDetail(String(reflecting: error)), "domain": nsError.domain, "code": nsError.code]
        if let decoding = error as? DecodingError {
            let context: DecodingError.Context?
            switch decoding {
            case .dataCorrupted(let c), .keyNotFound(_, let c), .typeMismatch(_, let c), .valueNotFound(_, let c): context = c
            @unknown default: context = nil
            }
            detail["codingPath"] = context?.codingPath.map(\.stringValue)
            detail["decodingDescription"] = context.map { boundedDetail($0.debugDescription) }
        }
        if depth < 3, let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            detail["underlyingError"] = errorDetails(underlying, depth: depth + 1)
        }
        return detail
    }

    private func boundedDetail(_ text: String) -> String {
        let text = redact(text)
        return text.count > 8_192 ? String(text.prefix(8_192)) + " [detail truncated; inspect transport artifacts]" : text
    }

    private func persistSummary() {
        guard available else { return }
        summary["truncatedFiles"] = truncated.sorted()
        do {
            let data = try JSONSerialization.data(withJSONObject: sanitize(summary), options: [.prettyPrinted, .sortedKeys])
            let url = directory.appendingPathComponent("summary.json")
            try data.write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { warn(error) }
    }

    private func append(_ filename: String, data: Data) {
        guard available, !truncated.contains(filename) else { return }
        // Large prompts/streams must not crowd out the eventual exit/status evidence.
        let metadata = filename == "events.jsonl" || filename.hasSuffix("-exit.json") ||
            (filename.hasPrefix("http-") && filename.hasSuffix("-response.json")) || filename.hasSuffix("-stderr-tail.txt")
        let reserve = min(1_024 * 1_024, totalLimit / 4)
        let budget = metadata ? totalLimit : totalLimit - reserve
        let limit = metadata ? min(fileLimit, 128 * 1_024) : fileLimit
        let capacity = min(limit - (fileSizes[filename] ?? 0), budget - totalBytes)
        guard capacity > 0 else { markTruncated(filename); return }
        let bytes = data.prefix(capacity)
        let url = directory.appendingPathComponent(filename)
        do {
            if !FileManager.default.fileExists(atPath: url.path) {
                guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: bytes)
            totalBytes += bytes.count
            fileSizes[filename, default: 0] += bytes.count
            if bytes.count < data.count { markTruncated(filename) }
        } catch { warn(error) }
    }

    private func markTruncated(_ filename: String) {
        truncated.insert(filename)
        persistSummary()
    }

    private func sanitize(_ value: Any) -> Any {
        if let object = value as? [String: Any] {
            return object.mapValuesWithKeys { key, value in
                if Self.isSecretKey(key) { return "[REDACTED]" }
                if key == "data", let base64 = value as? String, object["type"] as? String == "base64" {
                    return "[binary omitted; \(base64.utf8.count) base64 bytes]"
                }
                return sanitize(value)
            }
        }
        if let array = value as? [Any] { return array.map(sanitize) }
        if let string = value as? String { return redact(string) }
        return value
    }

    private static func isSecretKey(_ key: String) -> Bool {
        let key = key.lowercased().filter { $0.isLetter || $0.isNumber }
        return key.hasSuffix("token") || ["apikey", "authorization", "password", "secret", "credential", "privatekey", "cookie"].contains { key.contains($0) }
    }

    private static let credentialKeyPattern = #"(?:[A-Za-z0-9_-]*(?:api[_-]?key|authorization|password|secret|credential|private[_-]?key|cookie)[A-Za-z0-9_-]*|[A-Za-z0-9_-]*token)"#

    private func redact(_ text: String) -> String {
        var result = text
        for secret in secrets.sorted(by: { $0.count > $1.count }) { result = result.replacingOccurrences(of: secret, with: "[REDACTED]") }
        // Raw stdout/SSE can itself contain credential-shaped JSON fields.
        if let regex = try? NSRegularExpression(pattern: #"(?i)(""# + Self.credentialKeyPattern + #""\s*:\s*")(?:\\.|[^"\\])*(")"#) {
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "$1[REDACTED]$2")
        }
        for pattern in [#"sk-ant-[A-Za-z0-9_-]+"#, #"(?i)Bearer\s+[A-Za-z0-9._~+/=-]+"#,
                        #"(?i)(?<![A-Za-z0-9_-])("# + Self.credentialKeyPattern + #"\s*[=:]\s*)[^\s,;\"}]+"#] {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "[REDACTED]")
            }
        }
        return result
    }

    private func warn(_ error: Error) {
        guard !warned else { return }; warned = true
        FileHandle.standardError.write(Data("Lectern AI diagnostics unavailable at \(directory.path): \(error.localizedDescription)\n".utf8))
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

private extension Dictionary where Key == String, Value == Any {
    func mapValuesWithKeys(_ transform: (String, Any) -> Any) -> [String: Any] {
        Dictionary(uniqueKeysWithValues: map { ($0.key, transform($0.key, $0.value)) })
    }
}
