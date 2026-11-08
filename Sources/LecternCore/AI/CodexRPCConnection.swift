import Darwin
import Foundation

/// One app-server per attempt: no shared model state or conversations can leak
/// between concurrent jobs. The single async consumer drives a bidirectional pipe.
final class CodexRPCConnection: @unchecked Sendable {
    private let process = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()
    private let stderr = Pipe()
    private let lock = NSRecursiveLock()
    private let writeLock = NSLock()
    private let executable: URL
    private let directory: URL
    private let codexHome: URL
    private let timeout: TimeInterval
    private let trace: AIInteractionTrace?
    private let stream: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private var iterator: AsyncThrowingStream<Data, Error>.Iterator
    private var backlog: [[String: Any]] = []
    private var buffer = Data()
    private var stderrTail = Data()
    private var receivedBytes = 0
    private var nextID = 0
    private var started = false
    private var exited = false
    private var outputClosed = false
    private var stopping = false
    private var cancelled = false
    private var timeoutItem: DispatchWorkItem?
    private let byteLimit = 64 * 1_024 * 1_024
    private let lineLimit = 16 * 1_024 * 1_024

    static var defaultHome: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lectern/Codex", isDirectory: true)
    }

    init(executable: URL, directory: URL, timeout: TimeInterval, trace: AIInteractionTrace?, codexHome: URL? = nil) {
        self.executable = executable
        self.directory = directory
        self.timeout = timeout
        self.trace = trace
        self.codexHome = codexHome ?? Self.defaultHome
        let pair = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .bufferingOldest(512))
        stream = pair.stream
        continuation = pair.continuation
        iterator = pair.stream.makeAsyncIterator()
    }

    func start() throws {
        try Task.checkCancellation()
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw AIError.configuration("Codex was not found at \(executable.path). Install Codex or choose its executable in AI settings.")
        }
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        process.executableURL = executable
        process.currentDirectoryURL = directory
        let overrides = ["model_provider=\"openai\"", "forced_login_method=\"chatgpt\"", "features.shell_tool=false",
                         "features.view_image=false", "features.apps=false", "features.multi_agent=false", "features.hooks=false",
                         "features.memories=false", "features.remote_plugin=false", "web_search=\"disabled\"",
                         "project_doc_max_bytes=0", "history.persistence=\"none\"", "notify=[]", "mcp_servers={}"]
        process.arguments = ["app-server", "--listen", "stdio://"] + overrides.flatMap { ["-c", $0] }
        // The engine owns this isolated login profile. Never inherit API credentials,
        // provider overrides, personal Codex configuration, or an alternate CODEX_HOME.
        let inherited = ProcessInfo.processInfo.environment
        let allowed = ["HOME", "USER", "LOGNAME", "PATH", "TMPDIR", "LANG", "LC_ALL", "SHELL", "SSL_CERT_FILE", "SSL_CERT_DIR"]
        var environment = Dictionary(uniqueKeysWithValues: allowed.compactMap { key in inherited[key].map { (key, $0) } })
        environment["CODEX_HOME"] = codexHome.path
        process.environment = environment
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { self?.endOutput() } else { self?.receive(data) }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            self?.receiveStderr(data)
        }
        process.terminationHandler = { [weak self] _ in self?.didExit() }
        trace?.writeJSON("codex-invocation.json", ["executable": executable.path,
            "resolvedExecutable": executable.resolvingSymlinksInPath().path,
            "arguments": process.arguments ?? [], "workingDirectory": directory.path,
            "codexHome": codexHome.path, "timeoutSeconds": timeout])
        do {
            try process.run()
            lock.withLock { started = true }
            trace?.record("process_started", ["process": "codex", "pid": process.processIdentifier])
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            continuation.finish(throwing: AIError.configuration("Codex could not start: \(error.localizedDescription)"))
            throw AIError.configuration("Codex could not start: \(error.localizedDescription)")
        }
        let timer = DispatchWorkItem { [weak self] in
            self?.fail(AIError.limit("Codex exceeded the \(Int(self?.timeout ?? 0)) second time limit."), reason: "timeout")
        }
        lock.withLock { timeoutItem = timer }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timer)
        if Task.isCancelled || lock.withLock({ cancelled }) { cancel() }
    }

    func initialize() async throws {
        _ = try await call("initialize", ["clientInfo": ["name": "lectern", "title": "Lectern", "version": "1.0"],
                                          "capabilities": ["experimentalApi": true]])
        try send(["method": "initialized"])
    }

    func sendRequest(_ method: String, _ params: [String: Any]) throws -> Int {
        let id = lock.withLock { nextID += 1; return nextID }
        try send(["id": id, "method": method, "params": params])
        return id
    }

    func call(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        let id = try sendRequest(method, params)
        var early: [[String: Any]] = []
        defer { backlog.insert(contentsOf: early, at: 0) }
        while let message = try await next() {
            if message["id"] as? Int == id, message["method"] == nil {
                try Self.checkError(message)
                return message["result"] as? [String: Any] ?? [:]
            }
            // A startup approval or unsupported request must not stall indefinitely.
            if let incomingID = message["id"], message["method"] != nil {
                try send(["id": incomingID, "error": ["code": -32601, "message": "Unsupported operation in Lectern."]])
            } else {
                guard early.count < 256 else { throw AIError.limit("Codex sent too many messages before replying.") }
                early.append(message)
            }
        }
        throw AIError.transport("Codex closed before replying to \(method).")
    }

    static func checkError(_ message: [String: Any]) throws {
        if let error = message["error"] as? [String: Any] {
            throw CodexCLIProvider.codexError(error["message"] as? String ?? "Codex rejected the request.")
        }
    }

    func send(_ message: [String: Any]) throws {
        try Task.checkCancellation()
        let data = try JSONSerialization.data(withJSONObject: message, options: [.sortedKeys, .withoutEscapingSlashes]) + Data([10])
        // Parse before logging: image data URLs and credential fields are stripped by
        // the shared trace's structured sanitizer, never dumped as raw stdin bytes.
        trace?.writeJSONLine("codex-rpc-sent.jsonl", message)
        try writeLock.withLock {
            guard lock.withLock({ started && !exited && !stopping }) else { throw AIError.transport("Codex is no longer connected.") }
            do { try stdin.fileHandleForWriting.write(contentsOf: data) }
            catch { throw AIError.transport("Could not send a request to Codex: \(error.localizedDescription)") }
        }
    }

    /// Only the interaction's single driver calls next/call; pipe callbacks only yield Data.
    func next() async throws -> [String: Any]? {
        try Task.checkCancellation()
        if !backlog.isEmpty { return backlog.removeFirst() }
        let pendingLine = try await iterator.next()
        // Cancellation may finish the stream by returning nil rather than throwing.
        try Task.checkCancellation()
        guard let line = pendingLine else { return nil }
        guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
            trace?.writeText("codex-malformed-output.txt", String(decoding: line, as: UTF8.self))
            throw AIError.invalidResponse("Codex sent an invalid JSON-RPC message.")
        }
        trace?.writeJSONLine("codex-rpc-received.jsonl", message)
        return message
    }

    func cancel() {
        lock.withLock { cancelled = true }
        fail(CancellationError(), reason: "cancelled")
    }

    func shutdown() async {
        lock.withLock { timeoutItem?.cancel(); timeoutItem = nil }
        stop()
        // Cleanup must also wait when the caller is cancelled. Sleeping in that
        // cancelled task would return immediately and close the trace before exit.
        await Task.detached { [self] in
            for _ in 0..<100 {
                if lock.withLock({ !started || (exited && outputClosed) }) { break }
                try? await Task.sleep(for: .milliseconds(10))
            }
            let pid = lock.withLock { started && !exited ? process.processIdentifier : 0 }
            if pid > 0 {
                _ = kill(pid, SIGKILL)
                for _ in 0..<50 {
                    if lock.withLock({ exited && outputClosed }) { break }
                    try? await Task.sleep(for: .milliseconds(10))
                }
            }
        }.value
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        trace?.flush("codex-stderr.txt")
        trace?.writeJSON("codex-exit.json", lock.withLock {
            ["pid": started ? process.processIdentifier : 0, "exited": exited, "outputClosed": outputClosed,
             "terminationStatus": exited ? process.terminationStatus : -1, "cancelled": cancelled,
             "receivedBytes": receivedBytes] as [String: Any]
        })
        continuation.finish()
    }

    private func stop() {
        let pid: Int32 = lock.withLock {
            stopping = true
            return started && !exited ? process.processIdentifier : 0
        }
        if pid > 0 { _ = kill(pid, SIGTERM) }
        try? stdin.fileHandleForWriting.close()
    }

    private func fail(_ error: Error, reason: String) {
        trace?.record("codex_connection_stopped", ["reason": reason])
        continuation.finish(throwing: error)
        stop()
    }

    private func receive(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        receivedBytes += data.count
        guard receivedBytes <= byteLimit else { fail(AIError.limit("Codex output exceeded the 64 MiB interaction limit."), reason: "output_limit"); return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
            guard line.count <= lineLimit else { fail(AIError.limit("A Codex message exceeded 16 MiB."), reason: "message_limit"); return }
            if !line.isEmpty {
                if case .dropped = continuation.yield(line) {
                    fail(AIError.limit("Codex output exceeded the pending message limit."), reason: "queue_limit"); return
                }
            }
        }
        if buffer.count > lineLimit { fail(AIError.limit("A Codex message exceeded 16 MiB."), reason: "message_limit") }
    }

    private func endOutput() {
        lock.lock(); defer { lock.unlock() }
        outputClosed = true
        if !buffer.isEmpty { continuation.yield(buffer); buffer.removeAll() }
        finishIfClosed()
    }

    private func receiveStderr(_ data: Data) {
        lock.withLock {
            trace?.appendBytes("codex-stderr.txt", data)
            stderrTail.append(data)
            if stderrTail.count > 16_384 { stderrTail.removeFirst(stderrTail.count - 16_384) }
        }
    }

    private func didExit() {
        lock.withLock {
            exited = true
            trace?.record("process_exited", ["process": "codex", "terminationStatus": process.terminationStatus])
            finishIfClosed()
        }
    }

    private func finishIfClosed() {
        guard exited, outputClosed else { return }
        if stopping { continuation.finish(); return }
        // A normal process exit is still not proof that a model turn completed.
        let detail = String(decoding: stderrTail, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        continuation.finish(throwing: AIError.transport("Codex disconnected (exit \(process.terminationStatus))." + (detail.isEmpty ? "" : " \(detail)")))
    }
}
