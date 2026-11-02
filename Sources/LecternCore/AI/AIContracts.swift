import Foundation

public enum AIEvent: Equatable, Sendable {
    case stage(String)
    case text(String)
}

public struct AIRequest: Codable, Equatable, Sendable {
    public var jobID: UUID
    public var kind: JobKind
    public var model: String
    public var prompt: String
    public var systemPrompt: String
    public var pdf: Data?
    public var workingDirectory: URL
    public init(jobID: UUID, kind: JobKind, model: String, prompt: String, pdf: Data?, workingDirectory: URL, systemPrompt: String = PromptBuilder.systemPrompt) {
        self.jobID = jobID; self.kind = kind; self.model = model; self.prompt = prompt; self.systemPrompt = systemPrompt
        self.pdf = pdf; self.workingDirectory = workingDirectory
    }
}

public struct AIResponse: Codable, Equatable, Sendable {
    /// Schema payload for structured calls; plain text for Ask.
    public var content: String
    public var usage: AIUsage
    public init(content: String, usage: AIUsage = AIUsage()) { self.content = content; self.usage = usage }
}

public protocol AIProvider: Sendable {
    var backend: AIBackend { get }
    func execute(_ request: AIRequest, onEvent: @escaping @Sendable (AIEvent) -> Void) async throws -> AIResponse
}

public enum AIError: Error, LocalizedError, Equatable, Sendable {
    case configuration(String), transport(String), invalidResponse(String), refusal(String), limit(String)
    public var errorDescription: String? {
        switch self {
        case .configuration(let s), .transport(let s), .invalidResponse(let s), .refusal(let s), .limit(let s): s
        }
    }
}

public struct GeneratedCards: Codable, Equatable, Sendable {
    public var cards: [WireCard]
    public var skipped: [SkippedSlide]
    public init(cards: [WireCard], skipped: [SkippedSlide] = []) { self.cards = cards; self.skipped = skipped }
}
public struct RevisedCards: Codable, Equatable, Sendable {
    public var cards: [WireCard]
    public var rationale: String
    public init(cards: [WireCard], rationale: String) { self.cards = cards; self.rationale = rationale }
}
public struct WireCard: Codable, Equatable, Sendable {
    public var front: String
    public var back: String
    public var sourceSlides: [Int]
    public var flag: String?
    public init(front: String, back: String, sourceSlides: [Int], flag: String? = nil) {
        self.front = front; self.back = back; self.sourceSlides = sourceSlides; self.flag = flag
    }
    public var draft: CardDraft { CardDraft(front: front, back: back, sourcePages: sourceSlides, flag: flag) }
}
public struct DistilledPoints: Codable, Equatable, Sendable {
    public struct Point: Codable, Equatable, Sendable {
        public var text: String
        public var pages: [Int]
        public init(text: String, pages: [Int]) { self.text = text; self.pages = pages }
    }
    public var learningPoints: [Point]
    public init(learningPoints: [Point]) { self.learningPoints = learningPoints }
}

public enum AIOutputSchema {
    public static func json(for kind: JobKind) -> String? {
        switch kind {
        case .ask: return nil
        case .generate:
            return #"{"type":"object","additionalProperties":false,"required":["cards","skipped"],"properties":{"cards":{"type":"array","items":CARD},"skipped":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["slide","reason"],"properties":{"slide":{"type":"integer"},"reason":{"type":"string"}}}}}}"#.replacingOccurrences(of: "CARD", with: card)
        case .revise:
            return #"{"type":"object","additionalProperties":false,"required":["cards","rationale"],"properties":{"cards":{"type":"array","minItems":1,"maxItems":3,"items":CARD},"rationale":{"type":"string"}}}"#.replacingOccurrences(of: "CARD", with: card)
        case .distil:
            return #"{"type":"object","additionalProperties":false,"required":["learningPoints"],"properties":{"learningPoints":{"type":"array","maxItems":3,"items":{"type":"object","additionalProperties":false,"required":["text","pages"],"properties":{"text":{"type":"string"},"pages":{"type":"array","items":{"type":"integer"}}}}}}}"#
        }
    }
    private static let card = #"{"type":"object","additionalProperties":false,"required":["front","back","sourceSlides","flag"],"properties":{"front":{"type":"string"},"back":{"type":"string"},"sourceSlides":{"type":"array","items":{"type":"integer"}},"flag":{"type":["string","null"]}}}"#
}

/// Deterministic offline provider for frontend previews and integration tests.
public actor FakeAIProvider: AIProvider {
    public nonisolated let backend: AIBackend
    private var responses: [AIResponse]
    private(set) public var requests: [AIRequest] = []
    public init(responses: [AIResponse], backend: AIBackend = .claudeCLI) { self.responses = responses; self.backend = backend }
    public func execute(_ request: AIRequest, onEvent: @escaping @Sendable (AIEvent) -> Void) async throws -> AIResponse {
        try Task.checkCancellation(); requests.append(request)
        guard !responses.isEmpty else { throw AIError.configuration("Fake provider has no response fixture left.") }
        let response = responses.removeFirst()
        onEvent(.stage("Writing"))
        if request.kind == .ask { onEvent(.text(response.content)) }
        return response
    }
}
