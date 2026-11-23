import Foundation

public struct StudyQueue: Equatable, Sendable {
    public static let defaultNewCardLimit = 20

    public let due: [UUID]
    public let new: [UUID]

    /// Supply lectures in module order and count first grades already committed on the study day.
    public static func build(
        module: Module, lectures: [Lecture], memory: [UUID: StudyMemoryState],
        introducedToday: Int, now: Date, newCardLimit: Int = defaultNewCardLimit
    ) -> StudyQueue {
        guard !module.isArchived else { return StudyQueue(due: [], new: []) }
        let cards = lectures
            .filter { $0.moduleID == module.id && !$0.isArchived }
            .flatMap(\.cards)
            .filter { $0.verdict == .good && !$0.isSuperseded }
        let due = cards.compactMap { card -> (card: Card, date: Date)? in
            guard let date = memory[card.id]?.due, date <= now else { return nil }
            return (card, date)
        }.sorted { $0.date < $1.date }.map(\.card)
        let remaining = max(0, max(0, newCardLimit) - max(0, introducedToday))
        let new = cards.filter { memory[$0.id] == nil }

        let orderedDue = spaced(due, after: nil, limit: due.count)
        let orderedNew = spaced(new, after: orderedDue.last, limit: remaining)
        return StudyQueue(due: orderedDue.map(\.id), new: orderedNew.map(\.id))
    }

    private static func siblingGroup(_ card: Card) -> UUID? {
        guard case let .splitFrom(parentID) = card.origin else { return nil }
        return parentID
    }

    private static func spaced(_ cards: [Card], after preceding: Card?, limit: Int) -> [Card] {
        var remaining = cards
        var ordered: [Card] = []
        var previousGroup = preceding.flatMap(siblingGroup)
        while !remaining.isEmpty && ordered.count < limit {
            let nextIndex = previousGroup.flatMap { group in
                remaining.firstIndex { siblingGroup($0) != group }
            } ?? remaining.startIndex
            let card = remaining.remove(at: nextIndex)
            ordered.append(card)
            previousGroup = siblingGroup(card)
        }
        return ordered
    }
}
