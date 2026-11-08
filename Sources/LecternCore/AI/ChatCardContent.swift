import Foundation

/// Model-facing content only. The complete Card remains in the local frozen snapshot.
struct ChatCardContent: Codable, Equatable, Sendable {
    let number: Int
    let front: String
    let back: String
    let sourcePages: [Int]
    let mathInterpretations: [String: MathInterpretation]?
    let cardID: UUID?
    let baseRevisionID: UUID?

    init(_ card: Card, number: Int, includeEditIDs: Bool = false) {
        self.number = number
        front = card.front
        back = card.back
        sourcePages = card.sourcePages
        mathInterpretations = card.mathInterpretations.isEmpty ? nil : card.mathInterpretations
        cardID = includeEditIDs ? card.id : nil
        baseRevisionID = includeEditIDs ? card.currentRevisionID : nil
    }

    static func deck(_ cards: [Card]) -> [Self] {
        cards.enumerated().map { Self($0.element, number: $0.offset + 1) }
    }
}

enum ChatContextJSON {
    static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}

extension ChatSnapshot {
    /// Legacy retry assets keep UUID filenames; new jobs use short displayed card numbers.
    func cardPath(at index: Int) -> String {
        cardContextVersion == 1 ? "cards/C\(index + 1).json" : "cards/\(cards[index].id.uuidString).json"
    }

    func cardPath(for id: UUID) -> String? {
        cards.firstIndex(where: { $0.id == id }).map { cardPath(at: $0) }
    }
}
