import Foundation

/// Frozen, on-demand view of the complete case pool for one solve card.
struct ChatSolveCaseLookup: Codable, Equatable, Sendable {
    struct Case: Codable, Equatable, Sendable {
        let caseID: UUID
        let baseContentHash: String
        let isSample: Bool
        let retired: Bool
        let editable: Bool
        let content: SolveCaseContent
    }

    let number: Int
    let cardID: UUID
    let baseRevisionID: UUID?
    let cases: [Case]

    init(card: Card, number: Int) {
        self.number = number
        cardID = card.id
        baseRevisionID = card.currentRevisionID
        cases = (card.solve?.cases ?? []).enumerated().map { index, item in
            Case(caseID: item.id,
                 baseContentHash: ChatSolveCaseEdit.contentHash(item.content),
                 isSample: index == 0,
                 retired: item.retired,
                 editable: !item.retired,
                 content: item.content)
        }
    }
}
