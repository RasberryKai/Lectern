import Foundation

public struct APICostSummary: Equatable, Sendable {
    public var reportedUSD: Double = 0
    public var estimatedUSD: Double = 0
    public var unpricedJobs: Int = 0
    public var inputTokens: Int = 0
    public var outputTokens: Int = 0
    public init() {}
    public var totalUSD: Double { reportedUSD + estimatedUSD }
}
public enum APIPricing {
    /// Published rates verified 2026-11-02; an estimate, never an invoice or CLI subscription cost.
    public static func estimatedUSD(usage: AIUsage, model: String) -> Double? {
        guard model == "claude-opus-5-5" else { return nil }
        let creation = max(0, usage.cacheCreationInputTokens ?? 0)
        let read = max(0, usage.cacheReadInputTokens ?? 0)
        let regular = max(0, usage.inputTokens - creation - read)
        return (Double(regular) * 4 + Double(creation) * 5 + Double(read) * 0.20 + Double(max(0, usage.outputTokens)) * 20) / 1_000_000
    }
    public static func summarize(_ jobs: [Job]) -> APICostSummary {
        var result = APICostSummary()
        for job in jobs where job.backend == .messagesAPI {
            guard let usage = job.usage else {
                if job.state != .running { result.unpricedJobs += 1 }; continue
            }
            result.inputTokens += usage.inputTokens; result.outputTokens += usage.outputTokens
            if let cost = usage.costUSD, cost.isFinite, cost >= 0 { result.reportedUSD += cost }
            else if let cost = estimatedUSD(usage: usage, model: job.model) { result.estimatedUSD += cost }
            else { result.unpricedJobs += 1 }
        }
        return result
    }
}
