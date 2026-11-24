import Foundation

public struct ExamOverview: Equatable, Sendable {
    public struct Row: Equatable, Identifiable, Sendable {
        public let module: Module
        public let daysUntilExam: Int?
        public let metrics: Metrics
        public var id: UUID { module.id }
    }

    public struct Metrics: Equatable, Sendable {
        public let lectures: Progress
        public let cards: Progress?
        public let lecturesPerWeek: Pace?
        public let cardsPerDay: Pace?
    }

    public struct Progress: Equatable, Sendable {
        public let completed: Int
        public let total: Int
        public let isEstimate: Bool
    }

    public struct Pace: Equatable, Sendable {
        public let needed: Int
        public let isBehind: Bool
    }

    public let rows: [Row]
    public let totals: Metrics

    public init(dashboard: DashboardSnapshot, study: StudyCatalog, now: Date, timeZone: TimeZone = .current) {
        let decks = Dictionary(uniqueKeysWithValues: study.decks.map { ($0.id, $0) })
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let weekAgo = calendar.date(byAdding: .day, value: -7, to: now) ?? now

        rows = dashboard.modules.compactMap { progress -> Row? in
            let days = progress.module.examDate?.daysRemaining(from: now, timeZone: timeZone)
            guard days.map({ $0 >= 0 }) ?? true else { return nil }
            let deck = decks[progress.id]
            let limit = deck?.overrides.newCardLimit ?? study.preferences.defaults.newCardLimit
            return Row(
                module: progress.module, daysUntilExam: days,
                metrics: Self.metrics(for: progress, deck: deck, days: days, now: now, weekAgo: weekAgo, newCardLimit: limit)
            )
        }.sorted { ($0.daysUntilExam ?? .max) < ($1.daysUntilExam ?? .max) }

        let metrics = rows.map(\.metrics)
        totals = Metrics(
            lectures: Self.sum(metrics.map(\.lectures)),
            cards: Self.totalProgress(metrics.compactMap(\.cards)),
            lecturesPerWeek: Self.totalPace(metrics.compactMap(\.lecturesPerWeek)),
            cardsPerDay: Self.totalPace(metrics.compactMap(\.cardsPerDay))
        )
    }

    private static func metrics(for progress: ModuleProgress, deck: StudyDeck?, days: Int?,
                                now: Date, weekAgo: Date, newCardLimit: Int) -> Metrics {
        let lectures = Progress(completed: progress.cardMakingDoneCount, total: progress.totals.plannedLectureCount, isEstimate: false)
        let cards = cardProgress(lectures: lectures, deck: deck)
        let finishedLastWeek = progress.lectures.count { lecture in
            guard lecture.status.cardMakingStatus == .done, let date = lecture.cardMakingCompletedAt else { return false }
            return (weekAgo...now).contains(date)
        }
        let lecturesPerWeek = pace(remaining: lectures.total - lectures.completed, days: days, period: 7, current: finishedLastWeek)
        // Until at least one lecture is done, the card count is real but the remaining workload is unknown.
        let cardsPerDay = lectures.completed > 0 ? cards.flatMap {
            pace(remaining: $0.total - $0.completed, days: days, period: 1, current: newCardLimit)
        } : nil
        return Metrics(lectures: lectures, cards: cards, lecturesPerWeek: lecturesPerWeek, cardsPerDay: cardsPerDay)
    }

    private static func cardProgress(lectures: Progress, deck: StudyDeck?) -> Progress? {
        guard let deck else { return nil }
        var count = 0
        var seen = 0
        for lecture in deck.lectures where !lecture.isArchived && lecture.moduleID == deck.id {
            for card in lecture.cards where !card.isSuperseded && (card.verdict != .bad || card.proposal != nil) {
                count += 1
                if deck.memory[card.id] != nil { seen += 1 }
            }
        }
        guard count > 0 else { return nil }
        let isEstimate = lectures.completed > 0 && lectures.completed < lectures.total
        let total = isEstimate ? Int((Double(count) / Double(lectures.completed) * Double(lectures.total)).rounded()) : count
        return Progress(completed: seen, total: total, isEstimate: isEstimate)
    }

    private static func pace(remaining: Int, days: Int?, period: Int, current: Int) -> Pace? {
        guard let days, remaining > 0 else { return nil }
        let finishDays = days - 3
        let needed = finishDays > 0 ? Int(ceil(Double(remaining) * Double(period) / Double(finishDays))) : remaining
        return Pace(needed: needed, isBehind: needed > current)
    }

    private static func sum(_ progress: [Progress]) -> Progress {
        Progress(completed: progress.reduce(0) { $0 + $1.completed }, total: progress.reduce(0) { $0 + $1.total },
                 isEstimate: progress.contains(where: \.isEstimate))
    }

    private static func totalProgress(_ progress: [Progress]) -> Progress? {
        progress.isEmpty ? nil : sum(progress)
    }

    private static func totalPace(_ paces: [Pace]) -> Pace? {
        paces.isEmpty ? nil : Pace(needed: paces.reduce(0) { $0 + $1.needed }, isBehind: false)
    }
}
