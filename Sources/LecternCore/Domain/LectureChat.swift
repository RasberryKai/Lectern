import Foundation

public enum ContextRef: Codable, Equatable, Hashable, Sendable {
    case slide(Int), card(UUID), allSlides, allCards
}

extension Lecture {
    public func chatCitationCardID(number: Int, jobID: UUID?) -> UUID? {
        guard number > 0 else { return nil }
        let job = jobID.flatMap { id in jobs.first { $0.id == id && $0.isLectureChat == true } }
        let index = number - 1
        if let citedCards = job?.chatCitationCardIDs ?? job?.chatCardVersions?.map(\.cardID) {
            guard citedCards.indices.contains(index) else { return nil }
            let id = citedCards[index]
            return cards.contains { $0.id == id && !$0.isSuperseded } ? id : nil
        }
        return cards.lazy.filter { !$0.isSuperseded }.dropFirst(index).first?.id
    }
}

public struct ChatContext: Equatable, Sendable {
    public var followsScreen: Bool
    public var pins: [ContextRef]
    public init(followsScreen: Bool = true, pins: [ContextRef] = []) { self.followsScreen = followsScreen; self.pins = pins }
}
public struct QuizItem: Codable, Equatable, Identifiable, Sendable {
    public var question: String
    public var answer: String
    public var id: String { question }
    public init(question: String, answer: String) { self.question = question; self.answer = answer }
}
public struct LectureChat: Codable, Equatable, Identifiable, Sendable {
    private enum CodingKeys: String, CodingKey { case id, title, messages, summary, summarizedMessageCount, pointCursor, processedClickedAnswerIDs, draft, draftAttachments, createdAt, updatedAt }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); title = try c.decode(String.self, forKey: .title)
        messages = try c.decode([ChatMessage].self, forKey: .messages); summary = try c.decode(String.self, forKey: .summary)
        summarizedMessageCount = try c.decodeIfPresent(Int.self, forKey: .summarizedMessageCount)
        pointCursor = try c.decodeIfPresent(Int.self, forKey: .pointCursor)
        processedClickedAnswerIDs = try c.decodeIfPresent([UUID].self, forKey: .processedClickedAnswerIDs) ?? []
        draft = try c.decode(String.self, forKey: .draft); draftAttachments = try c.decodeIfPresent([ChatAttachment].self, forKey: .draftAttachments) ?? []
        createdAt = try c.decode(Date.self, forKey: .createdAt); updatedAt = try c.decode(Date.self, forKey: .updatedAt)
    }

    public var id: UUID
    public var title: String
    public var messages: [ChatMessage]
    public var summary: String
    public var summarizedMessageCount: Int? = nil
    /// Messages before this index have been judged for learning points. Nil on chats from before
    /// per-concept extraction: their history is never re-extracted.
    public var pointCursor: Int? = nil
    /// Clicked-answer requests already handled, including requests that correctly produced no point.
    /// Missing from older files; decodes as empty for compatibility.
    public var processedClickedAnswerIDs: [UUID] = []
    public var draft: String
    public var draftAttachments: [ChatAttachment]
    public var createdAt: Date
    public var updatedAt: Date
    public init(id: UUID = UUID(), title: String = "New chat", messages: [ChatMessage] = [], summary: String = "", draft: String = "", draftAttachments: [ChatAttachment] = [], createdAt: Date = Date(), updatedAt: Date? = nil) {
        self.id = id; self.title = title; self.messages = messages; self.summary = summary; self.draft = draft; self.draftAttachments = draftAttachments; self.createdAt = createdAt; self.updatedAt = updatedAt ?? createdAt
    }
    public static func migrating(_ threads: [SlideThread]) -> LectureChat {
        let messages = threads.flatMap { thread in thread.messages.map { message in
            var next = message; if next.context.isEmpty, thread.anchorPage > 0 { next.context = [.slide(thread.anchorPage)] }; return next
        }}.sorted { $0.at < $1.at }
        return LectureChat(title: messages.first(where: { $0.role == .user }).map { title(for: $0.text) } ?? "New chat", messages: messages, createdAt: messages.first?.at ?? Date(), updatedAt: messages.last?.at)
    }
    public static func title(for question: String) -> String { question.split(whereSeparator: \.isWhitespace).prefix(6).joined(separator: " ") }
}




public enum ChatEditDisposition: String, Codable, Sendable { case proposed, applied, dismissed }

public struct ChatDeletionRequest: Codable, Equatable, Identifiable, Sendable {
    public enum State: String, Codable, Sendable { case pending, deleted, kept }

    public let version: ChatCardVersion
    public let front: String
    public let back: String
    public internal(set) var state: State = .pending
    public var id: UUID { version.cardID }

    init(version: ChatCardVersion, card: Card) {
        self.version = version
        self.front = card.front
        self.back = card.back
    }
}

public struct ChatAttachment: Codable, Equatable, Identifiable, Sendable {
    public static let maximumImageBytes = 5 * 1_024 * 1_024
    public static let maximumSelectionBytes = 10 * 1_024 * 1_024
    public var id: UUID
    public var filename: String
    public var mediaType: String
    public var byteCount: Int
    public var sha256: String
    public var relativePath: String { "chat-attachments/\(id.uuidString).\(mediaType == "image/jpeg" ? "jpg" : "png")" }
    public init(id: UUID = UUID(), filename: String, mediaType: String, byteCount: Int, sha256: String) {
        self.id = id; self.filename = filename; self.mediaType = mediaType; self.byteCount = byteCount; self.sha256 = sha256
    }
    public static func validateSelection(_ attachments: [ChatAttachment]) throws {
        guard Set(attachments.map(\.id)).count == attachments.count else { throw LibraryError.invalid("An image is attached more than once.") }
        var total = 0
        for image in attachments {
            guard ["image/png", "image/jpeg"].contains(image.mediaType), image.byteCount > 0, image.byteCount <= maximumImageBytes,
                  image.sha256.count == 64, image.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw LibraryError.invalid("Images must be PNG or JPEG, at most 5 MiB each, with valid attachment metadata.")
            }
            total += image.byteCount
        }
        guard total <= maximumSelectionBytes else { throw LibraryError.invalid("Attached images must total at most 10 MiB per message.") }
    }
}
