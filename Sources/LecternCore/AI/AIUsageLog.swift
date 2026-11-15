import Foundation
import Darwin

/// Small durable accounting records survive cleanup of large transport traces.
/// Usage is optional: unavailable usage must never be presented as a free call.
public struct AIUsageAttempt: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var jobID: UUID
    public var backend: AIBackend
    public var model: String
    public var kind: JobKind
    public var status: String
    public var startedAt: Date
    public var finishedAt: Date?
    public var providerCalls: Int
    public var usage: AIUsage?
    public var usageReportedCalls: Int? = nil
    public var hasIncompleteUsage: Bool {
        if let usageReportedCalls { return usageReportedCalls < providerCalls }
        return providerCalls > 0 && usage == nil
    }
    public var context: [String: String]
    public var details: [String: String]

    public init(id: String = UUID().uuidString, jobID: UUID, backend: AIBackend, model: String, kind: JobKind,
                status: String = "running", startedAt: Date = Date(), finishedAt: Date? = nil,
                providerCalls: Int = 0, usage: AIUsage? = nil, context: [String: String] = [:], details: [String: String] = [:]) {
        self.id = id; self.jobID = jobID; self.backend = backend; self.model = model; self.kind = kind
        self.status = status; self.startedAt = startedAt; self.finishedAt = finishedAt
        self.providerCalls = providerCalls; self.usage = usage; self.context = context; self.details = details
    }
}

public enum AIUsageLedger {
    static func url(for workingDirectory: URL) -> URL? {
        let jobs = workingDirectory.deletingLastPathComponent()
        guard jobs.lastPathComponent == "jobs", UUID(uuidString: workingDirectory.lastPathComponent) != nil else { return nil }
        return jobs.deletingLastPathComponent().appendingPathComponent("ai-usage.jsonl")
    }

    static func append(_ record: AIUsageAttempt, workingDirectory: URL) throws {
        guard let url = url(for: workingDirectory) else { return }
        // Do not recreate a lecture deleted while its provider was running.
        guard FileManager.default.fileExists(atPath: url.deletingLastPathComponent().appendingPathComponent("lecture.json").path) else { return }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(record) + Data([10])
        let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { flock(fd, LOCK_UN) }
        // A crash may leave a partial final line. Delimit it before appending so later records remain readable.
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        try handle.write(contentsOf: Data([10]))
        try handle.write(contentsOf: data)
    }

    public static func read(from url: URL) throws -> [AIUsageAttempt] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        guard flock(handle.fileDescriptor, LOCK_SH) == 0 else { throw CocoaError(.fileReadUnknown) }
        defer { flock(handle.fileDescriptor, LOCK_UN) }
        let data = try handle.readToEnd() ?? Data()
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var latest: [String: AIUsageAttempt] = [:]
        for line in data.split(separator: 10) {
            if let record = try? decoder.decode(AIUsageAttempt.self, from: Data(line)) { latest[record.id] = record }
        }
        return latest.values.sorted { $0.startedAt < $1.startedAt }
    }
}

extension LibraryStore {
    public func usageRecords(moduleID: UUID, lectureID: UUID) throws -> [AIUsageAttempt] {
        try AIUsageLedger.read(from: lectureDirectory(moduleID, lectureID).appendingPathComponent("ai-usage.jsonl"))
    }
}

public struct AIUsageSummary: Sendable {
    public var attempts = 0
    public var providerCalls = 0
    public var skipped = 0
    public var failed = 0
    public var missingUsage = 0
    public var inputTokens = 0
    public var outputTokens = 0
    public var cacheReadTokens = 0
    public var cacheWriteTokens = 0
    public var pointsAdded = 0
    public var pointsMerged = 0
    public var pointsRejected = 0

    /// Attempts (including retries) take precedence over the single latest usage on a historical job.
    public static func summarize(records: [AIUsageAttempt], legacyJobs: [Job] = [], learningPointsOnly: Bool = false,
                                 backend: AIBackend? = nil) -> AIUsageSummary {
        var result = AIUsageSummary()
        let recordedJobs = Set(records.map(\.jobID))
        // Callers may combine records from several sources; never count an attempt twice.
        let unique = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last }).values
        func include(_ usage: AIUsage?) {
            guard let usage else { result.missingUsage += 1; return }
            result.inputTokens += usage.inputTokens; result.outputTokens += usage.outputTokens
            result.cacheReadTokens += usage.cacheReadInputTokens ?? 0
            result.cacheWriteTokens += usage.cacheCreationInputTokens ?? 0
        }
        for record in unique where (backend == nil || record.backend == backend) && (!learningPointsOnly || record.context["feature"] == "learningPointsV2") {
            if record.status == "skipped" { result.skipped += 1; continue }
            result.attempts += 1; result.providerCalls += record.providerCalls
            if ["failed", "cancelled", "interrupted"].contains(record.status) { result.failed += 1 }
            // Preflight failures with no invocation are known zero calls; running records may have unreported work.
            if record.providerCalls > 0 || record.status == "running" || record.usage != nil {
                include(record.usage)
                if record.usage != nil && record.hasIncompleteUsage { result.missingUsage += 1 }
            }
            result.pointsAdded += Int(record.details["pointsAdded"] ?? "") ?? 0
            result.pointsMerged += Int(record.details["pointsMerged"] ?? "") ?? 0
            result.pointsRejected += Int(record.details["pointsRejected"] ?? "") ?? 0
        }
        for job in legacyJobs where !recordedJobs.contains(job.id) && (backend == nil || job.backend == backend) && !learningPointsOnly {
            result.attempts += 1
            // Historical jobs lack a transport counter. Their existence is an attempt, not proof of a billable call.
            if job.usage != nil { result.providerCalls += 1 }
            if [.failed, .cancelled, .interrupted].contains(job.state) { result.failed += 1 }
            include(job.usage)
        }
        return result
    }
}
