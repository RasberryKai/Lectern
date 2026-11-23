import Foundation

/*
 FSRS-6 memory transitions adapted from Py-FSRS v6.3.2.

 MIT License

 Copyright (c) 2022 Open Spaced Repetition

 Permission is hereby granted, free of charge, to any person obtaining a copy
 of this software and associated documentation files (the "Software"), to deal
 in the Software without restriction, including without limitation the rights
 to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 copies of the Software, and to permit persons to whom the Software is
 furnished to do so, subject to the following conditions:

 The above copyright notice and this permission notice shall be included in all
 copies or substantial portions of the Software.

 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 SOFTWARE.
 */

public enum StudyRating: Int, Codable, Sendable {
    case again = 1
    case good = 3
}

public struct StudyMemoryState: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable {
        case learning, review, relearning
    }

    public let stability: Double
    public let difficulty: Double
    public let due: Date
    public let lastReview: Date
    public let reps: Int
    public let lapses: Int
    public let phase: Phase
    /// Distinguishes the post-correct learning step from the post-miss delay.
    public let awaitingLearningRepeat: Bool?

    init(stability: Double, difficulty: Double, due: Date, lastReview: Date, reps: Int,
         lapses: Int, phase: Phase, awaitingLearningRepeat: Bool? = nil) {
        self.stability = stability
        self.difficulty = difficulty
        self.due = due
        self.lastReview = lastReview
        self.reps = reps
        self.lapses = lapses
        self.phase = phase
        self.awaitingLearningRepeat = awaitingLearningRepeat
    }

    func changingDue(to date: Date) -> Self {
        Self(stability: stability, difficulty: difficulty, due: date, lastReview: lastReview,
             reps: reps, lapses: lapses, phase: phase, awaitingLearningRepeat: awaitingLearningRepeat)
    }
}

public enum StudyScheduleError: Error, Equatable, Sendable {
    case reviewBeforeLastReview
}

/// FSRS-6 with the Py-FSRS 6.3.2 defaults and Lectern's two ratings.
/// Parity is measured with one learning step, one relearning step and fuzzing disabled.
public enum StudyScheduler {
    public static let model = "FSRS-6"
    public static let desiredRetention = 0.90

    private static let weights = [
        0.212, 1.2931, 2.3065, 8.2956, 6.4133, 0.8334, 3.0194,
        0.001, 1.8722, 0.1666, 0.796, 1.4835, 0.0614, 0.2629,
        1.6483, 0.6014, 1.8729, 0.5425, 0.0912, 0.0658, 0.1542
    ]
    private static let secondsPerDay = 86_400.0
    private static let minimumStability = 0.001
    private static let decay = -weights[20]
    private static let factor = pow(0.9, 1 / decay) - 1

    /// A nil previous state represents a new card. Early reviews are allowed for session retries.
    public static func review(
        _ previous: StudyMemoryState?, rating: StudyRating, at date: Date
    ) throws -> StudyMemoryState {
        var reference = StudyConfiguration()
        reference.flipFirstCorrect = .startSpacedReviews
        return try review(previous, rating: rating, at: date, configuration: reference, cardID: nil)
    }

    public static func review(
        _ previous: StudyMemoryState?, rating: StudyRating, at date: Date,
        configuration: StudyConfiguration, cardID: UUID?
    ) throws -> StudyMemoryState {
        let stability: Double
        let difficulty: Double
        if let previous {
            let elapsed = date.timeIntervalSince(previous.lastReview)
            guard elapsed >= 0 else { throw StudyScheduleError.reviewBeforeLastReview }
            stability = updatedStability(previous, rating: rating, days: floor(elapsed / secondsPerDay))
            let change = -weights[6] * Double(rating.rawValue - 3)
            let damped = previous.difficulty + (10 - previous.difficulty) * change / 9
            difficulty = boundedDifficulty(weights[7] * initialDifficulty(4) + (1 - weights[7]) * damped)
        } else {
            stability = weights[rating.rawValue - 1]
            difficulty = boundedDifficulty(initialDifficulty(rating.rawValue))
        }

        let phase: StudyMemoryState.Phase
        let delay: TimeInterval
        let reps = (previous?.reps ?? 0) + 1
        var awaitingLearningRepeat: Bool?
        switch (rating, previous?.phase) {
        case (.again, nil), (.again, .learning):
            phase = .learning
            delay = TimeInterval(configuration.newRetryMinutes) * 60
        case (.again, .review), (.again, .relearning):
            phase = .relearning
            delay = TimeInterval(configuration.establishedRetryMinutes) * 60
        case (.good, _):
            let isLearning = previous == nil || previous?.phase == .learning
            if isLearning, previous?.awaitingLearningRepeat != true,
               case .repeatAfter(let minutes) = configuration.flipFirstCorrect {
                phase = .learning
                delay = TimeInterval(minutes) * 60
                awaitingLearningRepeat = true
            } else {
                phase = .review
                delay = reviewDelay(stability, configuration: configuration, cardID: cardID, reps: reps)
            }
        }

        let isLapse = rating == .again && previous?.phase == .review
        return StudyMemoryState(
            stability: stability, difficulty: difficulty,
            due: date.addingTimeInterval(delay), lastReview: date,
            reps: reps, lapses: (previous?.lapses ?? 0) + (isLapse ? 1 : 0),
            phase: phase, awaitingLearningRepeat: awaitingLearningRepeat
        )
    }

    /// Recompute the due date from the last committed review, preserving memory and its phase.
    public static func reschedule(
        _ state: StudyMemoryState, configuration: StudyConfiguration, cardID: UUID
    ) -> StudyMemoryState {
        let delay: TimeInterval
        switch state.phase {
        case .review:
            delay = reviewDelay(state.stability, configuration: configuration, cardID: cardID, reps: state.reps)
        case .relearning:
            delay = TimeInterval(configuration.establishedRetryMinutes) * 60
        case .learning:
            if state.awaitingLearningRepeat == true {
                switch configuration.flipFirstCorrect {
                case .repeatAfter(let minutes): delay = TimeInterval(minutes) * 60
                case .startSpacedReviews:
                    delay = reviewDelay(state.stability, configuration: configuration, cardID: cardID, reps: state.reps)
                    return StudyMemoryState(stability: state.stability, difficulty: state.difficulty,
                        due: state.lastReview.addingTimeInterval(delay), lastReview: state.lastReview,
                        reps: state.reps, lapses: state.lapses, phase: .review)
                }
            } else {
                delay = TimeInterval(configuration.newRetryMinutes) * 60
            }
        }
        return state.changingDue(to: state.lastReview.addingTimeInterval(delay))
    }

    private static func reviewDelay(_ stability: Double, configuration: StudyConfiguration,
                                    cardID: UUID?, reps: Int) -> TimeInterval {
        let retention = Double(configuration.desiredRetention) / 100
        let interval = stability / factor * (pow(retention, 1 / decay) - 1)
        let maximum = Double(configuration.maximumInterval.maximumDays)
        let days = min(maximum, max(1, interval.rounded(.toNearestOrEven)))
        guard configuration.spreadReviewDates, let cardID, days >= 3 else { return days * secondsPerDay }

        let spread = 1 + 0.15 * min(days - 2.5, 4.5)
            + 0.10 * max(0, min(days - 7, 13)) + 0.05 * max(0, days - 20)
        let lower = Int(max(2, (days - spread).rounded(.toNearestOrEven)))
        let upper = Int(min(maximum, (days + spread).rounded(.toNearestOrEven)))
        // A persisted grade replays to the same interval across launches and Swift versions.
        let seed = withUnsafeBytes(of: cardID.uuid) { bytes in
            bytes.reduce(UInt64(reps)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
        }
        return TimeInterval(lower + Int(seed % UInt64(upper - lower + 1))) * secondsPerDay
    }

    /// The pure transition used when the future exam debrief records an Again event.
    public static func demote(_ previous: StudyMemoryState, at date: Date) throws -> StudyMemoryState {
        try review(previous, rating: .again, at: date)
    }

    private static func initialDifficulty(_ rating: Int) -> Double {
        weights[4] - exp(weights[5] * Double(rating - 1)) + 1
    }

    private static func boundedDifficulty(_ difficulty: Double) -> Double {
        min(10, max(1, difficulty))
    }

    private static func updatedStability(_ state: StudyMemoryState, rating: StudyRating, days: Double) -> Double {
        let stability = state.stability
        if days == 0 {
            let multiplier = exp(weights[17] * (Double(rating.rawValue - 3) + weights[18]))
                * pow(stability, -weights[19])
            return max(minimumStability, stability * (rating == .good ? max(1, multiplier) : multiplier))
        }

        let retrievability = pow(1 + factor * days / stability, decay)
        if rating == .again {
            let afterForgetting = weights[11] * pow(state.difficulty, -weights[12])
                * (pow(stability + 1, weights[13]) - 1) * exp((1 - retrievability) * weights[14])
            let ceiling = stability / exp(weights[17] * weights[18])
            return max(minimumStability, min(afterForgetting, ceiling))
        }

        let gain = exp(weights[8]) * (11 - state.difficulty) * pow(stability, -weights[9])
            * (exp((1 - retrievability) * weights[10]) - 1)
        return max(minimumStability, stability * (1 + gain))
    }
}
