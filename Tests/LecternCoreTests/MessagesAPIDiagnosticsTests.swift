import Foundation
import Testing
@testable import LecternCore

@Suite(.serialized)
struct MessagesAPIDiagnosticsTests {
    @Test func httpFailureRecordsRequestIDBodyAndNeverWritesAPIKey() async throws {
        let root = try diagnosticsTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let apiKey = "sk-ant-diagnostics-secret-123"
        let body = #"{"error":{"type":"authentication_error","message":"invalid API key"}}"#
        let session = DiagnosticsURLProtocol.makeSession(
            status: 401,
            headers: ["content-type": "application/json", "request-id": "req_diagnostic_123"],
            body: Data(body.utf8)
        )
        let provider = MessagesAPIProvider(apiKey: { apiKey }, session: session,
                                           endpoint: URL(string: "https://diagnostics.example.test/v1/messages")!)
        let request = AIRequest(jobID: UUID(), kind: .generate, model: "claude-opus-5-5", prompt: "Diagnose this request",
                                pdf: nil, workingDirectory: root)

        do {
            _ = try await provider.execute(request, onEvent: { _ in })
            Issue.record("Expected the HTTP 401 to fail")
        } catch { }

        let files = try diagnosticFiles(in: root)
        let responseLog = try #require(files["http-01-response.json"])
        let errorBodyLog = try #require(files["http-01-body.error.txt"])
        #expect(responseLog.contains("req_diagnostic_123"))
        #expect(responseLog.contains("401"))
        #expect(errorBodyLog.contains("invalid API key"))
        let summaryText = try #require(files["summary.json"])
        let summary = try #require(JSONSerialization.jsonObject(with: Data(summaryText.utf8)) as? [String: Any])
        #expect(summary["status"] as? String == "failed")
        #expect(summary["error"] != nil)
        #expect(files.values.allSatisfy { !$0.contains(apiKey) })
        #expect(files["http-01-request.json"]?.contains("authorization") == false)
    }

    @Test func malformedResponseKeepsRedactedRawBodyAndFailureSummary() async throws {
        let root = try diagnosticsTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let apiKey = "sk-ant-malformed-secret-456"
        let body = "not-json response mentioning \(apiKey)"
        let session = DiagnosticsURLProtocol.makeSession(
            status: 200,
            headers: ["content-type": "application/json", "request-id": "req_malformed_456"],
            body: Data(body.utf8)
        )
        let provider = MessagesAPIProvider(apiKey: { apiKey }, session: session,
                                           endpoint: URL(string: "https://diagnostics.example.test/v1/messages")!)
        let request = AIRequest(jobID: UUID(), kind: .generate, model: "claude-opus-5-5", prompt: "Return malformed JSON",
                                pdf: nil, workingDirectory: root)

        do {
            _ = try await provider.execute(request, onEvent: { _ in })
            Issue.record("Expected malformed JSON to fail")
        } catch { }

        let files = try diagnosticFiles(in: root)
        let rawBody = try #require(files["http-01-body.json"])
        #expect(rawBody.contains("not-json response"))
        #expect(rawBody.contains("[REDACTED]"))
        let summaryText = try #require(files["summary.json"])
        let summary = try #require(JSONSerialization.jsonObject(with: Data(summaryText.utf8)) as? [String: Any])
        #expect(summary["status"] as? String == "failed")
        #expect(files.values.allSatisfy { !$0.contains(apiKey) })
    }

    @Test func askStreamWritesRawSSEAndFinalParsedResponse() async throws {
        let root = try diagnosticsTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sse = """
        event: content_block_delta
        data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Answer"}}

        event: message_stop
        data: {"type":"message_stop"}

        """
        let session = DiagnosticsURLProtocol.makeSession(
            status: 200,
            headers: ["content-type": "text/event-stream", "request-id": "req_stream_789"],
            body: Data(sse.utf8)
        )
        let provider = MessagesAPIProvider(apiKey: { "sk-ant-stream-secret-789" }, session: session,
                                           endpoint: URL(string: "https://diagnostics.example.test/v1/messages")!)
        let request = AIRequest(jobID: UUID(), kind: .ask, model: "claude-opus-5-5", prompt: "Question",
                                pdf: nil, workingDirectory: root)

        let response = try await provider.execute(request, onEvent: { _ in })

        let files = try diagnosticFiles(in: root)
        #expect(response.content == "Answer")
        #expect(files["http-01-body.sse"]?.contains("content_block_delta") == true)
        #expect(files["response.json"]?.contains("Answer") == true)
        #expect(files["http-01-response.json"]?.contains("req_stream_789") == true)
        #expect(files.values.allSatisfy { !$0.contains("sk-ant-stream-secret-789") })
    }
}

private func diagnosticsTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("lectern-messages-diagnostics-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func diagnosticFiles(in root: URL) throws -> [String: String] {
    let logRoot = root.appendingPathComponent("ai-logs", isDirectory: true)
    let attempts = try FileManager.default.contentsOfDirectory(at: logRoot, includingPropertiesForKeys: nil)
    let attempt = try #require(attempts.first)
    let urls = try FileManager.default.contentsOfDirectory(at: attempt, includingPropertiesForKeys: nil)
    return Dictionary(uniqueKeysWithValues: try urls.map { url in
        (url.lastPathComponent, try String(contentsOf: url, encoding: .utf8))
    })
}

private final class DiagnosticsURLProtocolState: @unchecked Sendable {
    static let shared = DiagnosticsURLProtocolState()
    private let lock = NSLock()
    private var status = 200
    private var headers: [String: String] = [:]
    private var body = Data()

    func configure(status: Int, headers: [String: String], body: Data) {
        lock.lock(); defer { lock.unlock() }
        self.status = status
        self.headers = headers
        self.body = body
    }

    func snapshot() -> (Int, [String: String], Data) {
        lock.lock(); defer { lock.unlock() }
        return (status, headers, body)
    }
}

private enum DiagnosticsURLProtocol {
    static func makeSession(status: Int, headers: [String: String], body: Data) -> URLSession {
        DiagnosticsURLProtocolState.shared.configure(status: status, headers: headers, body: body)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DiagnosticsStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class DiagnosticsStubURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "diagnostics.example.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (status, headers, body) = DiagnosticsURLProtocolState.shared.snapshot()
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() { }
}
