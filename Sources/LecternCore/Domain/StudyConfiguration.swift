import Foundation

public enum StudyFirstCorrect: Codable, Equatable, Sendable {
    case startSpacedReviews
    case repeatAfter(Int)
}

public enum StudyIntervalLimit: Codable, Equatable, Sendable {
    case automatic
    case days(Int)

    var maximumDays: Int {
        switch self {
        case .automatic: 36_500
        case .days(let days): days
        }
    }
}

public enum StudyCardTypes: String, Codable, CaseIterable, Sendable {
    case all, flip, solve
}

public enum StudyQueueOrder: String, Codable, CaseIterable, Sendable {
    case dueFirst, mixed
}

public enum StudyNewCardOrder: String, Codable, CaseIterable, Sendable {
    case sequential, shuffleWithinLecture, shuffleAcrossSelection
}

public enum StudyStop: Codable, Equatable, Sendable {
    case complete
    case cards(Int)
    case minutes(Int)
}

public struct StudySessionOptions: Codable, Equatable, Sendable {
    public var cardTypes: StudyCardTypes = .all
    public var queueOrder: StudyQueueOrder = .dueFirst
    public var newCardOrder: StudyNewCardOrder = .sequential
    public var spaceRelatedCards = true
    public var stop: StudyStop = .complete

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case cardTypes, queueOrder, newCardOrder, spaceRelatedCards, stop
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        cardTypes = try values.decode(StudyCardTypes.self, forKey: .cardTypes)
        queueOrder = try values.decode(StudyQueueOrder.self, forKey: .queueOrder)
        newCardOrder = try values.decodeIfPresent(StudyNewCardOrder.self, forKey: .newCardOrder) ?? .sequential
        spaceRelatedCards = try values.decode(Bool.self, forKey: .spaceRelatedCards)
        stop = try values.decode(StudyStop.self, forKey: .stop)
    }

    func validated() throws {
        switch stop {
        case .cards(let count), .minutes(let count):
            guard count > 0 else { throw LibraryError.invalid("Enter a positive session limit.") }
        case .complete: break
        }
    }

    func estimatedCount(for count: Int) -> Int {
        switch stop {
        case .complete: count
        case .cards(let limit): min(count, limit)
        case .minutes(let limit): Int(min(Double(count), ceil(Double(limit) * 60 / 16)))
        }
    }
}

public struct StudyConfiguration: Codable, Equatable, Sendable {
    public var newCardLimit = 20
    public var desiredRetention = 90
    public var flipFirstCorrect: StudyFirstCorrect = .repeatAfter(10)
    public var solveFirstCorrect: StudyFirstCorrect = .startSpacedReviews
    public var retryAfterMiss = true
    public var newRetryMinutes = 1
    public var establishedRetryMinutes = 10
    public var maximumInterval: StudyIntervalLimit = .automatic
    public var spreadReviewDates = false
    public var session = StudySessionOptions()

    public init() {}

    public func validated() throws {
        guard newCardLimit >= 0 else { throw LibraryError.invalid("New cards per day must be zero or more.") }
        guard (80...97).contains(desiredRetention) else { throw LibraryError.invalid("Desired retention must be between 80% and 97%.") }
        guard [newRetryMinutes, establishedRetryMinutes].allSatisfy((1...60).contains) else {
            throw LibraryError.invalid("Retry delays must be between 1 and 60 minutes.")
        }
        for step in [flipFirstCorrect, solveFirstCorrect] {
            if case .repeatAfter(let minutes) = step, !(1...60).contains(minutes) {
                throw LibraryError.invalid("Learning steps must be between 1 and 60 minutes.")
            }
        }
        guard (1...36_500).contains(maximumInterval.maximumDays) else {
            throw LibraryError.invalid("The maximum review interval must be between 1 and 36,500 days.")
        }
        try session.validated()
    }
}

public struct StudyPreferences: Codable, Equatable, Sendable {
    public var defaults = StudyConfiguration()
    public var overallNewLimit: Int?

    public init() {}

    public func validated() throws {
        if let overallNewLimit, overallNewLimit < 0 {
            throw LibraryError.invalid("The overall limit must be zero or more.")
        }
        try defaults.validated()
    }
}

public struct StudyOverrides: Codable, Equatable, Sendable {
    public var newCardLimit: Int?
    public var desiredRetention: Int?
    public var flipFirstCorrect: StudyFirstCorrect?
    public var solveFirstCorrect: StudyFirstCorrect?
    public var retryAfterMiss: Bool?
    public var newRetryMinutes: Int?
    public var establishedRetryMinutes: Int?
    public var maximumInterval: StudyIntervalLimit?
    public var spreadReviewDates: Bool?
    public var cardTypes: StudyCardTypes?
    public var queueOrder: StudyQueueOrder?
    public var newCardOrder: StudyNewCardOrder?
    public var spaceRelatedCards: Bool?
    public var stop: StudyStop?

    public init() {}

    public func applying(to defaults: StudyConfiguration) -> StudyConfiguration {
        var result = defaults
        result.newCardLimit = newCardLimit ?? defaults.newCardLimit
        result.desiredRetention = desiredRetention ?? defaults.desiredRetention
        result.flipFirstCorrect = flipFirstCorrect ?? defaults.flipFirstCorrect
        result.solveFirstCorrect = solveFirstCorrect ?? defaults.solveFirstCorrect
        result.retryAfterMiss = retryAfterMiss ?? defaults.retryAfterMiss
        result.newRetryMinutes = newRetryMinutes ?? defaults.newRetryMinutes
        result.establishedRetryMinutes = establishedRetryMinutes ?? defaults.establishedRetryMinutes
        result.maximumInterval = maximumInterval ?? defaults.maximumInterval
        result.spreadReviewDates = spreadReviewDates ?? defaults.spreadReviewDates
        result.session.cardTypes = cardTypes ?? defaults.session.cardTypes
        result.session.queueOrder = queueOrder ?? defaults.session.queueOrder
        result.session.newCardOrder = newCardOrder ?? defaults.session.newCardOrder
        result.session.spaceRelatedCards = spaceRelatedCards ?? defaults.session.spaceRelatedCards
        result.session.stop = stop ?? defaults.session.stop
        return result
    }
}
