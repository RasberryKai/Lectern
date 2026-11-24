import Foundation

public enum StudyScope: Hashable, Sendable {
    case all
    case module(UUID)
    case lectures(moduleID: UUID, lectureIDs: Set<UUID>)

    public var moduleID: UUID? {
        switch self {
        case .all: nil
        case .module(let id), .lectures(let id, _): id
        }
    }

    func includes(_ entry: StudyCard) -> Bool {
        if let moduleID, entry.moduleID != moduleID { return false }
        if case .lectures(_, let lectureIDs) = self { return lectureIDs.contains(entry.lectureID) }
        return true
    }
}

public struct StudyCard: Identifiable, Equatable, Sendable {
    public let moduleID: UUID
    public let lectureID: UUID
    public let lectureName: String
    public let moduleName: String
    public var card: Card
    public var memory: StudyMemoryState?
    public var id: UUID { card.id }

    public init(moduleID: UUID, lectureID: UUID, lectureName: String, moduleName: String,
                card: Card, memory: StudyMemoryState?) {
        self.moduleID = moduleID
        self.lectureID = lectureID
        self.lectureName = lectureName
        self.moduleName = moduleName
        self.card = card
        self.memory = memory
    }

    public func isRelated(to other: StudyCard) -> Bool {
        guard isFromSameLecture(as: other) else { return false }
        if case .splitFrom(let left) = card.origin, case .splitFrom(let right) = other.card.origin, left == right {
            return true
        }
        return card.sourcePages.contains { other.card.sourcePages.contains($0) }
    }

    fileprivate func isFromSameLecture(as other: StudyCard) -> Bool {
        moduleID == other.moduleID && lectureID == other.lectureID
    }
}

public struct StudyDeck: Identifiable, Equatable, Sendable {
    public let module: Module
    public let lectures: [Lecture]
    public let memory: [UUID: StudyMemoryState]
    public let overrides: StudyOverrides
    public let introducedToday: Int
    public var id: UUID { module.id }

    public init(module: Module, lectures: [Lecture], memory: [UUID: StudyMemoryState],
                overrides: StudyOverrides, introducedToday: Int) {
        self.module = module
        self.lectures = lectures
        self.memory = memory
        self.overrides = overrides
        self.introducedToday = introducedToday
    }

    public var approvedCards: [StudyCard] {
        guard !module.isArchived else { return [] }
        return lectures.filter { !$0.isArchived && $0.moduleID == id }.flatMap { lecture in
            lecture.cards.filter { $0.verdict == .good && !$0.isSuperseded }.map { card in
                StudyCard(moduleID: id, lectureID: lecture.id, lectureName: lecture.name, moduleName: module.name,
                          card: card, memory: memory[card.id])
            }
        }
    }

    public var approvedCount: Int { approvedCards.count }
    public var seenCount: Int { approvedCards.filter { $0.memory != nil }.count }

    public func neededPerDay(now: Date = Date(), timeZone: TimeZone = .current) -> Int? {
        guard let exam = module.examDate else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let daysUntil = calendar.dateComponents([.day], from: calendar.startOfDay(for: now),
                                                to: calendar.startOfDay(for: exam.date(in: timeZone))).day ?? 0
        guard daysUntil >= 0 else { return nil }
        let unseen = approvedCards.filter { $0.memory == nil }.count
        return Int(ceil(Double(unseen) / Double(daysUntil + 1)))
    }
}

public struct StudyPlan: Sendable {
    public let cards: [StudyCard]
    public let dueCount: Int
    public let startingCount: Int
    public let nextDue: Date?
    public let approvedCount: Int
    public let totalUnseen: Int
    public let dueRemaining: Int
}

public struct StudyCatalog: Equatable, Sendable {
    public let decks: [StudyDeck]
    public let preferences: StudyPreferences
    public let introducedToday: Int

    public init(decks: [StudyDeck] = [], preferences: StudyPreferences = .init(), introducedToday: Int = 0) {
        self.decks = decks
        self.preferences = preferences
        self.introducedToday = introducedToday
    }

    public func configuration(moduleID: UUID?) -> StudyConfiguration {
        decks.first { $0.id == moduleID }?.overrides.applying(to: preferences.defaults) ?? preferences.defaults
    }

    public static func studyDay(at date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    public static func remainingNewCards(limit: Int, introduced: Int, extra: Int) -> Int {
        let (sum, overflow) = max(0, limit).addingReportingOverflow(max(0, extra))
        return max(0, (overflow ? Int.max : sum) - max(0, introduced))
    }

    public func plan(scope: StudyScope = .all, options: StudySessionOptions? = nil,
                     includeFuture: Bool = false, extraNewPerModule: Int = 0,
                     limitNewInSession: Int? = nil, shuffleSeed: UInt64 = 0,
                     now: Date = Date()) -> StudyPlan {
        let options = options ?? configuration(moduleID: scope.moduleID).session
        let scopedDecks = decks.filter { scope.moduleID == nil || $0.id == scope.moduleID }
        let scoped = scopedDecks.flatMap(\.approvedCards).filter(scope.includes)
        let due = scoped.filter { $0.memory.map { $0.due <= now } ?? false }
            .sorted { ($0.memory?.due ?? now, $0.id.uuidString) < ($1.memory?.due ?? now, $1.id.uuidString) }
        let future = scoped.filter { $0.memory.map { $0.due > now } ?? false }
            .sorted { ($0.memory?.due ?? now, $0.id.uuidString) < ($1.memory?.due ?? now, $1.id.uuidString) }
        let unseen = scoped.filter { $0.memory == nil }
        let overall = preferences.overallNewLimit.map {
            Self.remainingNewCards(limit: $0, introduced: introducedToday, extra: extraNewPerModule)
        } ?? Int.max
        let budgets = Dictionary(uniqueKeysWithValues: scopedDecks.map { deck in
            let limit = deck.overrides.newCardLimit ?? preferences.defaults.newCardLimit
            return (deck.id, Self.remainingNewCards(limit: limit, introduced: deck.introducedToday, extra: extraNewPerModule))
        })
        let limit = options.cardTypes == .solve ? 0 : min(overall, max(0, limitNewInSession ?? Int.max))
        let new = limit > 0 ? Self.orderNew(unseen.filter { budgets[$0.moduleID, default: 0] > 0 },
                                            by: options.newCardOrder, seed: shuffleSeed) : []
        let ordered = Self.order(due: options.cardTypes == .solve ? [] : due,
                                 new: new,
                                 future: includeFuture && options.cardTypes != .solve ? future : [],
                                 newLimit: limit, moduleBudgets: budgets, options: options)
        let count = options.estimatedCount(for: ordered.count)
        let coveredDue = ordered.prefix(count).filter { $0.memory.map { $0.due <= now } ?? false }.count
        return StudyPlan(cards: ordered, dueCount: due.count, startingCount: count, nextDue: future.first?.memory?.due,
                         approvedCount: scoped.count, totalUnseen: unseen.count, dueRemaining: due.count - coveredDue)
    }

    private static func orderNew(_ cards: [StudyCard], by order: StudyNewCardOrder, seed: UInt64) -> [StudyCard] {
        var cards = cards
        var generator = StudyShuffleGenerator(state: seed)
        switch order {
        case .sequential:
            break
        case .shuffleWithinLecture:
            var start = cards.startIndex
            while start < cards.endIndex {
                let first = cards[start]
                let end = cards[(start + 1)...].firstIndex { !$0.isFromSameLecture(as: first) } ?? cards.endIndex
                cards[start..<end].shuffle(using: &generator)
                start = end
            }
        case .shuffleAcrossSelection:
            cards.shuffle(using: &generator)
        }
        return cards
    }

    private static func order(due: [StudyCard], new: [StudyCard], future: [StudyCard], newLimit: Int,
                              moduleBudgets: [UUID: Int], options: StudySessionOptions) -> [StudyCard] {
        func take(_ pending: inout [StudyCard], after last: StudyCard?, withinFirstLecture: Bool = false) -> StudyCard? {
            guard let first = pending.first else { return nil }
            if options.spaceRelatedCards, let last,
               let alternate = pending.firstIndex(where: { !$0.isRelated(to: last) }),
               !withinFirstLecture || pending[alternate].isFromSameLecture(as: first) {
                return pending.remove(at: alternate)
            }
            return pending.removeFirst()
        }

        var due = due
        var new = new
        var future = future
        var remainingNew = newLimit
        var budgets = moduleBudgets
        var ordered: [StudyCard] = []
        var preferNew = false
        func takeNew() -> StudyCard? {
            guard remainingNew > 0,
                  let next = take(&new, after: ordered.last, withinFirstLecture: options.newCardOrder == .shuffleWithinLecture)
            else { return nil }
            remainingNew -= 1
            budgets[next.moduleID, default: 0] -= 1
            if budgets[next.moduleID] == 0 { new.removeAll { $0.moduleID == next.moduleID } }
            return next
        }
        while !due.isEmpty || (!new.isEmpty && remainingNew > 0) {
            let next: StudyCard?
            if options.queueOrder == .mixed && preferNew {
                next = takeNew() ?? take(&due, after: ordered.last)
            } else {
                next = take(&due, after: ordered.last) ?? takeNew()
            }
            if let next {
                ordered.append(next)
                preferNew = next.memory != nil
            }
        }
        while let next = take(&future, after: ordered.last) { ordered.append(next) }
        return ordered
    }
}

private struct StudyShuffleGenerator: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        // SplitMix64
        state &+= 0x9e3779b97f4a7c15
        var value = state
        value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
        value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
        return value ^ (value >> 31)
    }
}
