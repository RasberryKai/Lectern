import Foundation

public enum ContextRef: Codable, Equatable, Hashable, Sendable {
    case slide(Int), card(UUID), allSlides, allCards
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
    private enum CodingKeys: String, CodingKey { case id, title, messages, summary, summarizedMessageCount, draft, draftAttachments, createdAt, updatedAt }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); title = try c.decode(String.self, forKey: .title)
        messages = try c.decode([ChatMessage].self, forKey: .messages); summary = try c.decode(String.self, forKey: .summary)
        summarizedMessageCount = try c.decodeIfPresent(Int.self, forKey: .summarizedMessageCount)
        draft = try c.decode(String.self, forKey: .draft); draftAttachments = try c.decodeIfPresent([ChatAttachment].self, forKey: .draftAttachments) ?? []
        createdAt = try c.decode(Date.self, forKey: .createdAt); updatedAt = try c.decode(Date.self, forKey: .updatedAt)
    }

    public var id: UUID
    public var title: String
    public var messages: [ChatMessage]
    public var summary: String
    public var summarizedMessageCount: Int? = nil
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
