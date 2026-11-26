import Foundation

public enum SolveInputFormat: String, Codable, Sendable, CaseIterable {
    case decimalPoint, decimalComma, fraction, percent, isoDate, dayMonthYear, monthDayYear

    public var label: String {
        switch self {
        case .decimalPoint: "1,234.56"
        case .decimalComma: "1.234,56"
        case .fraction: "a/b"
        case .percent: "%"
        case .isoDate: "YYYY-MM-DD"
        case .dayMonthYear: "DD.MM.YYYY"
        case .monthDayYear: "MM/DD/YYYY"
        }
    }

    var isDate: Bool { [.isoDate, .dayMonthYear, .monthDayYear].contains(self) }
}

public struct SolveInput: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable { case number, date, term, option }
    public var kind: Kind
    public var answers: [String]
    public var formats: [SolveInputFormat]? = nil
    public var unit: String? = nil
    public var tolerance: Double? = nil
    public var decimalPlaces: Int? = nil
    public var language: String? = nil
    public var ignoreCase: Bool? = nil
    public var articles: [String]? = nil
    public var allowTypo: Bool? = nil
    public var tonesMatter: Bool? = nil

    public init(kind: Kind, answers: [String], formats: [SolveInputFormat]? = nil, tolerance: Double? = nil) {
        self.kind = kind
        self.answers = answers
        self.formats = formats
        self.tolerance = tolerance
    }

    public var acceptedFormats: [SolveInputFormat] {
        formats ?? (kind == .date ? [.isoDate] : kind == .number ? [.decimalPoint] : [])
    }

    public var instructions: String {
        var parts = acceptedFormats.map(\.label)
        if let unit { parts.insert(unit, at: 0) }
        if let decimalPlaces {
            let value = acceptedFormats.contains(.percent) ? " the decimal value" : ""
            parts.append("Round\(value) to \(decimalPlaces) decimal places")
        }
        if let tolerance, tolerance > 0 { parts.append("±\(tolerance)") }
        if tonesMatter == true { parts.append("Pinyin tones required") }
        if acceptedFormats.contains(.decimalPoint), acceptedFormats.contains(.decimalComma) {
            parts.append("A single separator is the decimal mark")
        }
        return parts.joined(separator: " · ")
    }
}

public struct SolveOption: Codable, Equatable, Sendable {
    public var label: String
    public var reason: String
}

public struct SolveChoice: Codable, Equatable, Sendable {
    public var options: [SolveOption]
    public var correct: [String]
    public var multiple: Bool
    public var noneReason: String?
    public var shuffle: Bool
}

public struct SolveOrder: Codable, Equatable, Sendable {
    public var items: [String]
    public var sequences: [[String]]
}

public struct SolveGrid: Codable, Equatable, Sendable {
    public var columns: [String]
    public var rows: [[SolveInput]]
    public var rowLabels: [String]?
    public var options: [String]
    public var rowOrderMatters: Bool
    public var shuffle: Bool
}

public struct SolveField: Codable, Equatable, Sendable {
    public var prompt: String
    public var input: SolveInput? = nil
    public var choice: SolveChoice? = nil
    public var order: SolveOrder? = nil
    public var grid: SolveGrid? = nil
}

public struct SolveVariance: Codable, Equatable, Sendable {
    public var outcomes: [Int]
    public var weights: [Int]

    var isValid: Bool {
        (2...8).contains(outcomes.count) && outcomes.count == weights.count &&
            Set(outcomes).count == outcomes.count && outcomes.allSatisfy { (-100...100).contains($0) } &&
            weights.allSatisfy { (1...100).contains($0) }
    }

    var exercise: SolveCaseContent {
        let total = Double(weights.reduce(0, +))
        let rows = zip(outcomes, weights)
        let mean = rows.reduce(0.0) { $0 + Double($1.0 * $1.1) } / total
        let secondMoment = rows.reduce(0.0) { $0 + Double($1.0 * $1.0 * $1.1) } / total
        let variance = max(0, secondMoment - mean * mean)
        let table = rows.map { "| \($0) | \($1)/\(Int(total)) |" }.joined(separator: "\n")
        let fields = zip(["E(X)", "E(X²)", "Var(X)"], [mean, secondMoment, variance]).map { prompt, answer in
            SolveField(prompt: prompt, input: SolveInput(kind: .number, answers: [String(answer)],
                       formats: [.decimalPoint, .decimalComma, .fraction], tolerance: 0.0005))
        }
        let shown = [mean, secondMoment, variance].map { String(format: "%.6f", $0) }
        return SolveCaseContent(
            prompt: "For the distribution below, calculate the three requested quantities. Give an exact fraction or round to at least three decimal places.\n\n| x | P(X = x) |\n| --- | --- |\n\(table)",
            fields: fields,
            explanation: "Multiply each outcome by its probability and add to get E(X) ≈ \(shown[0]). Repeat with each outcome squared to get E(X²) ≈ \(shown[1]). Subtract E(X)² from E(X²) to get Var(X) ≈ \(shown[2]).",
            variance: self
        )
    }
}

public struct SolveCaseContent: Codable, Equatable, Sendable {
    public var prompt: String
    public var fields: [SolveField]
    public var explanation: String
    public var variance: SolveVariance?

    public var checkedContent: Self? {
        if let variance { return variance.isValid ? variance.exercise : nil }
        guard !prompt.solveTrimmed.isEmpty, !explanation.solveTrimmed.isEmpty,
              (1...8).contains(fields.count), fields.allSatisfy(\.isValid) else { return nil }
        return self
    }

    /// The key is deliberately excluded so rewording a solution cannot make a repeated case eligible.
    var signature: String {
        if let variance, variance.isValid {
            let total = variance.weights.reduce(0, +)
            return zip(variance.outcomes, variance.weights).sorted { $0.0 < $1.0 }
                .map { "\($0):\(Double($1) / Double(total))" }.joined(separator: "|")
        }
        var fieldText = [prompt]
        for field in fields {
            fieldText.append(field.prompt)
            fieldText.append(contentsOf: field.choice?.options.map(\.label).sorted() ?? [])
            fieldText.append(contentsOf: field.order?.items.sorted() ?? [])
            fieldText.append(contentsOf: field.grid?.rowLabels ?? [])
            fieldText.append(contentsOf: field.grid?.options.sorted() ?? [])
        }
        return fieldText.joined(separator: " ").lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

public struct SolveCase: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID = UUID()
    public var content: SolveCaseContent
    public var retired = false
}

public struct SolveDraft: Codable, Equatable, Sendable {
    public var skill: String
    public var reason: String
    public var variation: String
    public var sample: SolveCaseContent

    var validated: Self? {
        guard [skill, reason, variation].allSatisfy({ !$0.solveTrimmed.isEmpty }),
              let sample = sample.checkedContent else { return nil }
        var draft = self
        draft.sample = sample
        return draft
    }
}

public struct SolveCard: Codable, Equatable, Sendable {
    public static let refillThreshold = 2
    public static let poolTarget = 5

    public var draft: SolveDraft
    public var cases: [SolveCase]

    init(draft: SolveDraft) {
        self.draft = draft
        cases = [SolveCase(content: draft.sample)]
    }

    public var activeCases: [SolveCase] { cases.filter { !$0.retired } }

    /// Retired content stays in the deduplication set so refill cannot bring it back.
    mutating func append(_ contents: [SolveCaseContent]) -> Int {
        var signatures = Set(cases.map { $0.content.signature })
        let fresh = contents.compactMap(\.checkedContent).filter { signatures.insert($0.signature).inserted }
        cases.append(contentsOf: fresh.map { SolveCase(content: $0) })
        return fresh.count
    }

    public func varianceVariants(count: Int) -> [SolveCaseContent] {
        guard count > 0, let sample = draft.sample.variance, sample.isValid else { return [] }
        let orderedIndices = sample.outcomes.indices.sorted { sample.outcomes[$0] < sample.outcomes[$1] }
        let minimum = sample.outcomes[orderedIndices[0]]
        let maximum = sample.outcomes[orderedIndices[orderedIndices.count - 1]]
        let jitter = min(8, max(2, (maximum - minimum) / 8))
        var known = Set(cases.map { $0.content.signature })
        var contents: [SolveCaseContent] = []
        for _ in 0..<200 where contents.count < count {
            let offset = Int.random(in: max(-8, -100 - minimum)...min(8, 100 - maximum))
            let shifted = sample.outcomes.map { $0 + offset }
            var outcomes = shifted
            var lowerBound = -100
            for (position, index) in orderedIndices.enumerated() {
                let upperBound = position + 1 < orderedIndices.count ? shifted[orderedIndices[position + 1]] - 1 : 100
                let baseline = shifted[index]
                outcomes[index] = Int.random(in: max(lowerBound, baseline - jitter)...min(upperBound, baseline + jitter))
                lowerBound = outcomes[index] + 1
            }

            var weights = sample.weights
            let index = Int.random(in: weights.indices)
            let original = weights[index]
            let step = min(6, max(2, original / 10))
            let candidates = (max(1, original - step)...min(100, original + step)).filter { $0 != original }
            weights[index] = candidates[Int.random(in: candidates.indices)]
            let variant = SolveVariance(outcomes: outcomes, weights: weights).exercise
            if known.insert(variant.signature).inserted { contents.append(variant) }
        }
        return contents
    }
}

extension String {
    var solveTrimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

private extension SolveField {
    var isValid: Bool {
        guard !prompt.solveTrimmed.isEmpty,
              [input != nil, choice != nil, order != nil, grid != nil].filter({ $0 }).count == 1 else { return false }
        if let input { return input.kind != .option && input.isValid(options: []) }
        if let choice {
            let labels = choice.options.map(\.label)
            return (2...12).contains(labels.count) && labels.solveUnique &&
                choice.options.allSatisfy { !$0.reason.solveTrimmed.isEmpty } &&
                Set(choice.correct).isSubset(of: Set(labels)) && Set(choice.correct).count == choice.correct.count &&
                (choice.multiple || choice.correct.count == 1 || choice.correct.isEmpty && choice.noneReason != nil) &&
                (!choice.correct.isEmpty || choice.noneReason != nil) &&
                (choice.noneReason.map { !$0.solveTrimmed.isEmpty && !labels.contains("None of these") } ?? true)
        }
        if let order {
            return (2...12).contains(order.items.count) && order.items.solveUnique &&
                !order.sequences.isEmpty && order.sequences.allSatisfy {
                    $0.count == order.items.count && Set($0) == Set(order.items)
                }
        }
        guard let grid, (1...6).contains(grid.columns.count), grid.columns.solveUnique,
              (1...12).contains(grid.rows.count), grid.options.count <= 24, grid.options.solveUnique,
              grid.rows.allSatisfy({ $0.count == grid.columns.count && $0.allSatisfy { $0.isValid(options: grid.options) } })
        else { return false }
        if let labels = grid.rowLabels {
            return labels.count == grid.rows.count && labels.solveUnique && grid.rowOrderMatters
        }
        // Grid controls need the same input type in each column.
        return grid.columns.indices.allSatisfy { column in
            let first = grid.rows[0][column]
            return grid.rows.allSatisfy { $0[column].hasSameFormat(as: first) }
        }
    }
}

private extension Array where Element == String {
    var solveUnique: Bool { Set(self).count == count && allSatisfy { !$0.solveTrimmed.isEmpty } }
}

extension SolveInput {
    func hasSameFormat(as other: Self) -> Bool {
        var lhs = self, rhs = other
        lhs.answers = []; rhs.answers = []
        return lhs == rhs
    }

    func isValid(options: [String]) -> Bool {
        let formats = acceptedFormats
        guard !answers.isEmpty, answers.count <= 24,
              answers.allSatisfy({ !$0.solveTrimmed.isEmpty && $0.count <= 140 }),
              tolerance.map({ $0.isFinite && $0 >= 0 }) ?? true,
              decimalPlaces.map({ (0...9).contains($0) }) ?? true else { return false }
        switch kind {
        case .number:
            return !formats.isEmpty &&
                formats.allSatisfy { !$0.isDate } && answers.allSatisfy { SolveChecker.keyNumber($0) != nil }
        case .date:
            return !formats.isEmpty && formats.allSatisfy(\.isDate) &&
                answers.allSatisfy { SolveChecker.date($0, format: .isoDate) != nil }
        case .term:
            return answers.allSatisfy { !SolveChecker.normalizedTerm($0, for: self).isEmpty }
        case .option:
            return Set(answers).isSubset(of: Set(options))
        }
    }
}
