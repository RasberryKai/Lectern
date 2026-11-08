import Foundation

public enum AIEvent: Equatable, Sendable {
    case stage(String)
    case text(String)
    case read(ContextRef)
}

public struct AIRequest: Codable, Equatable, Sendable {
    public var jobID: UUID
    public var kind: JobKind
    public var model: String
    public var prompt: String
    public var systemPrompt: String
    public var chatSnapshot: ChatSnapshot? = nil
    public var pdf: Data?
    public var workingDirectory: URL
    public init(jobID: UUID, kind: JobKind, model: String, prompt: String, pdf: Data?, workingDirectory: URL, systemPrompt: String? = nil) {
        self.jobID = jobID; self.kind = kind; self.model = model; self.prompt = prompt; self.systemPrompt = systemPrompt ?? PromptBuilder.systemPrompt(for: kind)
        self.pdf = pdf; self.workingDirectory = workingDirectory
    }
}

public struct AIResponse: Codable, Equatable, Sendable {
    /// Schema payload for structured calls; plain text for Ask.
    public var read: [ContextRef] = []
    public var searchedLecture: Bool = false
    public var content: String
    public var usage: AIUsage
    public init(content: String, usage: AIUsage = AIUsage()) { self.content = content; self.usage = usage }
}

public protocol AIProvider: Sendable {
    var backend: AIBackend { get }
    func execute(_ request: AIRequest, onEvent: @escaping @Sendable (AIEvent) -> Void) async throws -> AIResponse
}

public enum AIError: Error, LocalizedError, Equatable, Sendable {
    case slideRead(String), configuration(String), transport(String), invalidResponse(String), refusal(String), limit(String)
    public var errorDescription: String? {
        switch self {
        case .slideRead(let s), .configuration(let s), .transport(let s), .invalidResponse(let s), .refusal(let s), .limit(let s): s
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
    public var summary: String? = nil
    public var learningPoints: [Point]
    public init(learningPoints: [Point]) { self.learningPoints = learningPoints }
}

public struct ChatCardEdit: Codable, Equatable, Sendable {
    public var cardID: UUID
    public var baseRevisionID: UUID
    public var front: String
    public var back: String

    public init(cardID: UUID, baseRevisionID: UUID, front: String, back: String) {
        self.cardID = cardID
        self.baseRevisionID = baseRevisionID
        self.front = front
        self.back = back
    }
}

public struct ChatReply: Codable, Equatable, Sendable {
    public var quiz: [QuizItem]? = nil
    public var message: String
    public var edits: [ChatCardEdit]

    public init(message: String, edits: [ChatCardEdit] = []) {
        self.message = message
        self.edits = edits
    }
}

public enum AIOutputSchema {
    public static func json(for kind: JobKind) -> String? {
        switch kind {
        case .ask: return nil
        case .chat:
            return #"{"type":"object","additionalProperties":false,"required":["message","edits","quiz"],"properties":{"quiz":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["question","answer"],"properties":{"question":{"type":"string"},"answer":{"type":"string"}}}},"message":{"type":"string"},"edits":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["cardID","baseRevisionID","front","back"],"properties":{"cardID":{"type":"string","format":"uuid"},"baseRevisionID":{"type":"string","format":"uuid"},"front":{"type":"string"},"back":{"type":"string"}}}}}}"#
        case .generate:
            return #"{"type":"object","additionalProperties":false,"required":["cards","skipped"],"properties":{"cards":{"type":"array","items":CARD},"skipped":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["slide","reason"],"properties":{"slide":{"type":"integer"},"reason":{"type":"string"}}}}}}"#.replacingOccurrences(of: "CARD", with: card)
        case .revise:
            return #"{"type":"object","additionalProperties":false,"required":["cards","rationale"],"properties":{"cards":{"type":"array","minItems":1,"maxItems":3,"items":CARD},"rationale":{"type":"string"}}}"#.replacingOccurrences(of: "CARD", with: card)
        case .distil:
            return #"{"type":"object","additionalProperties":false,"required":["learningPoints","summary"],"properties":{"summary":{"type":"string"},"learningPoints":{"type":"array","maxItems":3,"items":{"type":"object","additionalProperties":false,"required":["text","pages"],"properties":{"text":{"type":"string"},"pages":{"type":"array","items":{"type":"integer"}}}}}}}"#
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

public struct ChatSlide: Codable, Equatable, Sendable {
    public var page: Int
    public var text: String
    public var note: String
    public var imagePath: String?
    public init(page: Int, text: String, note: String, imagePath: String?) { self.page = page; self.text = text; self.note = note; self.imagePath = imagePath }
}
public struct ChatSnapshot: Codable, Equatable, Sendable {
    /// Nil preserves the original model payload and asset paths for frozen retries.
    public var cardContextVersion: Int? = nil
    /// SHA-256 digests of every frozen file. Nil on snapshots written before asset verification.
    public var assetHashes: [String: String]? = nil
    /// Upload metadata only; image bytes live in immutable, hash-verified job assets.
    public var images: [ChatSnapshotImage]? = nil
    public var slides: [ChatSlide]
    public var cards: [Card]
    public var initialRefs: [ContextRef]
    public init(slides: [ChatSlide], cards: [Card], initialRefs: [ContextRef]) { self.slides = slides; self.cards = cards; self.initialRefs = initialRefs }
}

public struct ChatSnapshotImage: Codable, Equatable, Sendable {
    public var attachment: ChatAttachment
    public var messageID: UUID
    public var isCurrent: Bool
    public var relativePath: String { "attachments/" + URL(fileURLWithPath: attachment.relativePath).lastPathComponent }
    public init(attachment: ChatAttachment, messageID: UUID, isCurrent: Bool) {
        self.attachment = attachment; self.messageID = messageID; self.isCurrent = isCurrent
    }
}
