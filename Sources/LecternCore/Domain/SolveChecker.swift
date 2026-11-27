import Foundation

public enum SolveAnswer: Codable, Equatable, Sendable {
    case text(String)
    case choice(Set<String>, none: Bool)
    case order([String])
    case grid([[String]])
}

public enum SolveFeedbackStatus: Equatable, Sendable {
    case correct, incorrect, invalid
}

public struct SolveCheckResult: Equatable, Sendable {
    public var fields: [SolveFieldFeedback]
    public var hasInvalidInput: Bool { fields.contains { $0.status == .invalid } }
    public var isCorrect: Bool { !fields.isEmpty && fields.allSatisfy { $0.status == .correct } }
}

public struct SolveFieldFeedback: Equatable, Sendable {
    public var status: SolveFeedbackStatus
    public var message: String? = nil
    public var expected: String? = nil
    public var cells: [[SolveCellFeedback]] = []
    public var options: [SolveOptionFeedback] = []
    public var expectedOrder: [String] = []
}

public struct SolveCellFeedback: Equatable, Sendable {
    public var status: SolveFeedbackStatus
    public var message: String? = nil
    public var expected: String? = nil
}

public struct SolveOptionFeedback: Equatable, Sendable {
    public var label: String
    public var selected: Bool
    public var correct: Bool
    public var reason: String
}

public enum SolveChecker {
    public static func check(_ content: SolveCaseContent, answers: [SolveAnswer]) -> SolveCheckResult {
        guard let content = content.checkedContent else {
            return SolveCheckResult(fields: [.init(status: .invalid, message: "This exercise has an invalid answer key.")])
        }
        var fields = content.fields.enumerated().map { index, field in
            check(field, answer: index < answers.count ? answers[index] : nil)
        }
        if answers.count > fields.count {
            fields[fields.count - 1] = .init(status: .invalid, message: "Remove the extra answers.")
        }
        if content.variance != nil {
            addVarianceFeedback(to: &fields, for: content.fields, answers: answers)
        }
        return SolveCheckResult(fields: fields)
    }

    private static func check(_ field: SolveField, answer: SolveAnswer?) -> SolveFieldFeedback {
        if let input = field.input {
            guard case .text(let text) = answer else { return .init(status: .invalid, message: "Enter an answer.") }
            let feedback = check(input, text: text, inGrid: false)
            return .init(status: feedback.status, message: feedback.message, expected: feedback.expected)
        }
        if let choice = field.choice {
            guard case .choice(let selection, let none) = answer else {
                return .init(status: .invalid, message: "Select an answer.")
            }
            return check(choice, selection: selection, none: none)
        }
        if let order = field.order {
            guard case .order(let items) = answer, items.count == order.items.count, Set(items) == Set(order.items) else {
                return .init(status: .invalid, message: "Arrange all the items once.")
            }
            let correct = order.sequences.contains(items)
            return .init(status: correct ? .correct : .incorrect,
                         expectedOrder: correct ? items : order.sequences.first ?? [])
        }
        guard let grid = field.grid, case .grid(let rows) = answer else {
            return .init(status: .invalid, message: "Fill in the table.")
        }
        return check(grid, rows: rows)
    }

    private static func check(_ choice: SolveChoice, selection: Set<String>, none: Bool) -> SolveFieldFeedback {
        guard !selection.isEmpty || none else { return .init(status: .invalid, message: "Select an answer.") }
        guard !none || selection.isEmpty && choice.noneReason != nil else {
            return .init(status: .invalid, message: "Select None of these by itself.")
        }
        guard selection.isSubset(of: Set(choice.options.map(\.label))), choice.multiple || selection.count <= 1 else {
            return .init(status: .invalid, message: choice.multiple ? "Use the options provided." : "Select one answer.")
        }

        let correct = Set(choice.correct)
        var options = choice.options.map {
            SolveOptionFeedback(label: $0.label, selected: selection.contains($0.label),
                                correct: correct.contains($0.label), reason: $0.reason)
        }
        if let reason = choice.noneReason {
            options.append(.init(label: "None of these", selected: none, correct: correct.isEmpty, reason: reason))
        }
        let matches = none ? correct.isEmpty : selection == correct
        return .init(status: matches ? .correct : .incorrect, options: options)
    }

    private static func check(_ grid: SolveGrid, rows: [[String]]) -> SolveFieldFeedback {
        guard rows.count <= grid.rows.count, rows.allSatisfy({ $0.count <= grid.columns.count }) else {
            return .init(status: .invalid, message: "Use the rows and columns provided.")
        }
        let answers = grid.rows.indices.map { row in row < rows.count ? rows[row] : [] }
        func compare(_ submitted: [String], to expected: [SolveInput]) -> [SolveCellFeedback] {
            expected.enumerated().map { index, input in
                check(input, text: index < submitted.count ? submitted[index] : "", inGrid: true, options: grid.options)
            }
        }

        let cells: [[SolveCellFeedback]]
        if grid.rowOrderMatters {
            cells = zip(answers, grid.rows).map { compare($0, to: $1) }
        } else {
            let comparisons = answers.map { row in grid.rows.map { compare(row, to: $0) } }
            let assignment = assignRows(comparisons, columns: grid.columns.count)
            cells = assignment.enumerated().map { row, key in comparisons[row][key] }
        }

        let missingRows = answers.count(where: { $0.allSatisfy { $0.solveTrimmed.isEmpty } })
        let invalid = cells.joined().contains { $0.status == .invalid }
        let correct = cells.joined().allSatisfy { $0.status == .correct }
        let missingMessage = missingRows == 1 ? "One row is missing." : "\(missingRows) rows are missing."
        return .init(status: invalid ? .invalid : correct ? .correct : .incorrect,
                     message: missingRows > 0 ? missingMessage : nil, cells: cells)
    }

    /// Each key row can be used once. Prefer whole matches, then find the most informative cell feedback.
    private static func assignRows(_ comparisons: [[[SolveCellFeedback]]], columns: Int) -> [Int] {
        let count = comparisons.count
        let wholeRowWeight = count * columns + 1
        let scores = comparisons.map { keys in
            keys.map { cells in
                let correct = cells.count(where: { $0.status == .correct })
                return correct == columns ? correct + wholeRowWeight : correct
            }
        }
        let allUsed = (1 << count) - 1
        var bestScores = Array(repeating: 0, count: allUsed + 1)
        var bestKeys = Array(repeating: 0, count: allUsed)
        for used in (0..<allUsed).reversed() {
            let row = used.nonzeroBitCount
            var best = -1
            for key in 0..<count where used & (1 << key) == 0 {
                let score = scores[row][key] + bestScores[used | (1 << key)]
                if score > best {
                    best = score
                    bestKeys[used] = key
                }
            }
            bestScores[used] = best
        }
        var used = 0
        return (0..<count).map { _ in
            let key = bestKeys[used]
            used |= 1 << key
            return key
        }
    }

    private static func check(_ input: SolveInput, text rawText: String, inGrid: Bool,
                              options: [String] = []) -> SolveCellFeedback {
        let text = rawText.solveTrimmed
        let expected = displayedAnswers(for: input).joined(separator: " or ")
        guard !text.isEmpty else {
            return .init(status: inGrid ? .incorrect : .invalid, message: "Enter an answer.",
                         expected: inGrid ? expected : nil)
        }
        guard input.kind == .option || text.count <= 140 else {
            return .init(status: .invalid, message: "Enter a shorter answer.")
        }

        let correct: Bool
        switch input.kind {
        case .number:
            guard let value = number(text, for: input) else {
                let formats = input.acceptedFormats.map(\.label).joined(separator: ", ")
                let fractionHint = input.acceptedFormats.contains(.fraction) && text.contains("/")
                    ? " Use integers and a nonzero denominator for fractions." : ""
                return .init(status: .invalid, message: "Use an accepted number format (\(formats)).\(fractionHint)")
            }
            let keys = input.answers.compactMap(keyNumber)
            correct = keys.contains { matches(value, $0, input: input) }
            if !correct, value != 0, keys.contains(where: { matches(-value, $0, input: input) }) {
                return .init(status: .incorrect, message: "The sign is reversed.", expected: expected)
            }
        case .date:
            let values = input.acceptedFormats.compactMap { date(text, format: $0) }
            guard !values.isEmpty else {
                let formats = input.acceptedFormats.map(\.label).joined(separator: ", ")
                return .init(status: .invalid, message: "Enter a real calendar date (\(formats)).")
            }
            correct = values.contains { input.answers.contains($0) }
        case .term:
            let value = normalizedTerm(text, for: input)
            let aliases = Set(input.answers.map { normalizedTerm($0, for: input) })
            if aliases.contains(value) { return .init(status: .correct, expected: expected) }
            if input.allowTypo == true, !usesPinyin(input),
               aliases.count(where: { oneCharacterApart(value, $0, input: input) }) == 1 {
                return .init(status: .correct, message: "Accepted a one-character typo.", expected: expected)
            }
            correct = false
        case .option:
            guard options.contains(rawText) else { return .init(status: .invalid, message: "Choose an option from the list.") }
            correct = input.answers.contains(rawText)
        }
        return .init(status: correct ? .correct : .incorrect, expected: expected)
    }
}

extension SolveChecker {
    static func normalizedTerm(_ text: String, for input: SolveInput) -> String {
        let locale = Locale(identifier: input.language ?? "en_US_POSIX")
        func normalize(_ text: String) -> String {
            let text = text.precomposedStringWithCanonicalMapping.replacingOccurrences(of: "’", with: "'")
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return input.ignoreCase == false ? text : text.lowercased(with: locale)
        }
        var value = normalize(text)
        for article in (input.articles ?? []).map(normalize).sorted(by: { $0.count > $1.count }) where !article.isEmpty {
            let prefix = article.hasSuffix("'") ? article : article + " "
            if value.hasPrefix(prefix) {
                value = String(value.dropFirst(prefix.count)).solveTrimmed
                break
            }
        }
        return usesPinyin(input) ? normalizedPinyin(value, tonesMatter: input.tonesMatter ?? true) : value
    }

    private static func usesPinyin(_ input: SolveInput) -> Bool {
        let language = input.language?.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first
        return language == "zh" || language == "cmn" || (language == nil && input.tonesMatter != nil)
    }

    private static let pinyinToneMarks: [Unicode.Scalar] = ["\u{0304}", "\u{0301}", "\u{030C}", "\u{0300}"]

    private static func normalizedPinyin(_ value: String, tonesMatter: Bool) -> String {
        let pinyin = value.replacingOccurrences(of: "u:", with: "ü").replacingOccurrences(of: "U:", with: "Ü")
            .replacingOccurrences(of: "v", with: "ü").replacingOccurrences(of: "V", with: "Ü")
        let romanized = pinyin.decomposedStringWithCanonicalMapping
        guard romanized.unicodeScalars.allSatisfy({ scalar in
            (65...90).contains(scalar.value) || (97...122).contains(scalar.value) || (48...53).contains(scalar.value) ||
                [" ", "'", "-", "\u{0308}"].contains(scalar) || pinyinToneMarks.contains(scalar)
        }) else { return value }

        var syllables: [String] = []
        for word in pinyin.split(whereSeparator: { $0 == " " || $0 == "'" || $0 == "-" }) {
            var letters: [Character] = []
            for character in word {
                if let tone = character.wholeNumberValue {
                    guard !letters.isEmpty, let syllable = markedSyllable(letters, tone: tone) else { return value }
                    syllables.append(syllable)
                    letters.removeAll()
                } else {
                    letters.append(character)
                }
            }
            if !letters.isEmpty { syllables.append(String(letters)) }
        }
        let normalized = syllables.joined(separator: " ").decomposedStringWithCanonicalMapping
        if tonesMatter { return normalized.precomposedStringWithCanonicalMapping }
        let scalars = normalized.unicodeScalars.filter { !pinyinToneMarks.contains($0) }
        return String(scalars).precomposedStringWithCanonicalMapping
    }

    private static func markedSyllable(_ letters: [Character], tone: Int) -> String? {
        guard !String(letters).decomposedStringWithCanonicalMapping.unicodeScalars.contains(where: {
            pinyinToneMarks.contains($0)
        }) else { return nil }
        if tone == 0 || tone == 5 { return String(letters) }
        let lower = letters.map { $0.lowercased() }
        let position = lower.firstIndex(of: "a") ?? lower.firstIndex(of: "e")
            ?? (lower.joined().contains("ou") ? lower.firstIndex(of: "o") : nil)
            ?? lower.lastIndex(where: { ["i", "o", "u", "ü"].contains($0) })
            ?? lower.lastIndex(where: { $0 == "m" || $0 == "n" })
        guard let position else { return nil }
        var marked = letters.map(String.init)
        marked[position].unicodeScalars.append(pinyinToneMarks[tone - 1])
        return marked.joined()
    }

    private static func oneCharacterApart(_ value: String, _ key: String, input: SolveInput) -> Bool {
        if input.ignoreCase == false {
            let locale = Locale(identifier: input.language ?? "en_US_POSIX")
            if value.lowercased(with: locale) == key.lowercased(with: locale) { return false }
        }
        let first = Array(value), second = Array(key)
        if first.count == second.count {
            return zip(first, second).count(where: { $0 != $1 }) == 1
        }
        let (shorter, longer) = first.count < second.count ? (first, second) : (second, first)
        guard longer.count == shorter.count + 1,
              let mismatch = shorter.indices.first(where: { shorter[$0] != longer[$0] }) else {
            return longer.count == shorter.count + 1
        }
        return shorter[mismatch...].elementsEqual(longer[(mismatch + 1)...])
    }
}

extension SolveChecker {
    private static let decimalLocale = Locale(identifier: "en_US_POSIX")

    static func keyNumber(_ text: String) -> Decimal? {
        let text = text.solveTrimmed
        return text.contains("/") ? fraction(text) : canonicalDecimal(text)
    }

    private static func number(_ text: String, for input: SolveInput) -> Decimal? {
        var text = text
        if let unit = input.unit?.solveTrimmed, !unit.isEmpty, unit != "%", text.hasSuffix(unit) {
            text = String(text.dropLast(unit.count)).solveTrimmed
        }
        text = text.replacingOccurrences(of: "−", with: "-")
        let formats = input.acceptedFormats
        if text.contains("/") { return formats.contains(.fraction) ? fraction(text) : nil }

        let percent = text.hasSuffix("%")
        if percent {
            guard formats.contains(.percent) else { return nil }
            text = String(text.dropLast()).solveTrimmed
        }
        let point = formats.contains(.decimalPoint)
        let comma = formats.contains(.decimalComma)
        guard point || comma || percent else { return nil }
        let pointValue = point || !comma ? localizedDecimal(text, decimal: ".", grouping: ",") : nil
        let commaValue = comma ? localizedDecimal(text, decimal: ",", grouping: ".") : nil
        // When both conventions are offered, a single mark is read as a decimal separator.
        // Two different separators make the displayed grouping conventions unambiguous.
        let value = text.contains(",") ? commaValue ?? pointValue : pointValue ?? commaValue
        guard let value else { return nil }
        return percent ? divide(value, by: 100) : value
    }

    private static func localizedDecimal(_ text: String, decimal: String, grouping: String) -> Decimal? {
        let decimalMark = NSRegularExpression.escapedPattern(for: decimal)
        let groupMark = NSRegularExpression.escapedPattern(for: grouping)
        let digits = "(?:[0-9]+|[1-9][0-9]{0,2}(?:\(groupMark)[0-9]{3})+)"
        let pattern = "\\A[+-]?(?:\(digits)(?:\(decimalMark)[0-9]+)?|\(decimalMark)[0-9]+)\\z"
        guard text.range(of: pattern, options: .regularExpression) != nil else { return nil }
        let canonical = text.replacingOccurrences(of: grouping, with: "").replacingOccurrences(of: decimal, with: ".")
        return canonicalDecimal(canonical)
    }

    private static func canonicalDecimal(_ text: String) -> Decimal? {
        let text = text.replacingOccurrences(of: "−", with: "-")
        guard text.range(of: #"\A[+-]?(?:[0-9]+(?:\.[0-9]+)?|\.[0-9]+)\z"#, options: .regularExpression) != nil,
              text.filter(\.isNumber).drop(while: { $0 == "0" }).count <= 38,
              let value = Decimal(string: text, locale: decimalLocale), !value.isNaN else { return nil }
        return value
    }

    private static func fraction(_ text: String) -> Decimal? {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false).map { String($0).solveTrimmed }
        guard parts.count == 2, !parts.contains(where: { $0.contains(".") }),
              let numerator = canonicalDecimal(parts[0]), let denominator = canonicalDecimal(parts[1]), denominator != 0
        else { return nil }
        return divide(numerator, by: denominator)
    }

    private static func divide(_ numerator: Decimal, by denominator: Decimal) -> Decimal? {
        var lhs = numerator, rhs = denominator, value = Decimal()
        let error = NSDecimalDivide(&value, &lhs, &rhs, .plain)
        return error == .noError || error == .lossOfPrecision ? value : nil
    }

    private static func matches(_ value: Decimal, _ key: Decimal, input: SolveInput) -> Bool {
        if (value < 0 && key > 0) || (value > 0 && key < 0) { return false }
        let submitted = rounded(value, places: input.decimalPlaces)
        let expected = rounded(key, places: input.decimalPlaces)
        if submitted == expected { return true }
        guard let tolerance = input.tolerance, tolerance > 0,
              let limit = Decimal(string: String(tolerance), locale: decimalLocale), !limit.isNaN else { return false }
        let difference = abs(submitted - expected)
        return !difference.isNaN && difference <= limit
    }

    private static func rounded(_ value: Decimal, places: Int?) -> Decimal {
        guard let places else { return value }
        var original = value, result = Decimal()
        NSDecimalRound(&result, &original, places, .plain)
        return result
    }

    static func date(_ text: String, format: SolveInputFormat) -> String? {
        let pattern: String
        let separator: Character
        let indices: (year: Int, month: Int, day: Int)
        switch format {
        case .isoDate:
            pattern = #"\A[0-9]{4}-[0-9]{2}-[0-9]{2}\z"#
            separator = "-"
            indices = (0, 1, 2)
        case .dayMonthYear:
            pattern = #"\A[0-9]{2}\.[0-9]{2}\.[0-9]{4}\z"#
            separator = "."
            indices = (2, 1, 0)
        case .monthDayYear:
            pattern = #"\A[0-9]{2}/[0-9]{2}/[0-9]{4}\z"#
            separator = "/"
            indices = (2, 0, 1)
        default:
            return nil
        }
        guard text.range(of: pattern, options: .regularExpression) != nil else { return nil }
        let parts = text.split(separator: separator)
        guard let year = Int(parts[indices.year]), (1...9999).contains(year),
              let month = Int(parts[indices.month]), (1...12).contains(month),
              let day = Int(parts[indices.day]) else { return nil }
        let leap = year.isMultiple(of: 4) && (!year.isMultiple(of: 100) || year.isMultiple(of: 400))
        let monthLengths = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard (1...monthLengths[month - 1]).contains(day) else { return nil }
        return "\(parts[indices.year])-\(parts[indices.month])-\(parts[indices.day])"
    }

    public static func displayedAnswers(for input: SolveInput) -> [String] {
        let answers = input.answers.map { answer in
            switch input.kind {
            case .number:
                guard let value = keyNumber(answer), let format = input.acceptedFormats.first else { return answer }
                return formattedNumber(value, key: answer, format: format, input: input)
            case .date:
                let parts = answer.split(separator: "-")
                guard parts.count == 3 else { return answer }
                switch input.acceptedFormats.first {
                case .dayMonthYear: return "\(parts[2]).\(parts[1]).\(parts[0])"
                case .monthDayYear: return "\(parts[1])/\(parts[2])/\(parts[0])"
                default: return answer
                }
            case .term, .option:
                return answer
            }
        }
        var seen = Set<String>()
        return answers.filter { seen.insert($0).inserted }
    }

    public static func varianceMistakeMessages(for content: SolveCaseContent) -> [String] {
        content.variance == nil ? [] : VarianceMistake.allCases.map(\.rawValue)
    }

    private enum VarianceMistake: String, CaseIterable {
        case squaredMeanAsSecondMoment = "This matches the square of your E(X). Square each outcome before weighting it to find E(X²)."
        case unsquaredMean = "This matches your E(X²) minus E(X). Square E(X) before subtracting it."
        case squaredMeanAsVariance = "This matches E(X)². Subtract it from E(X²) to find the variance."
    }

    private static func formattedNumber(_ value: Decimal, key: String, format: SolveInputFormat, input: SolveInput) -> String {
        var rounded = rounded(value, places: input.decimalPlaces)
        var rendered = NSDecimalString(&rounded, decimalLocale)
        switch format {
        case .decimalComma:
            rendered = rendered.replacingOccurrences(of: ".", with: ",")
        case .percent:
            var percent = rounded * 100
            if !percent.isNaN {
                rendered = NSDecimalString(&percent, decimalLocale)
                if !input.acceptedFormats.contains(.decimalPoint), input.acceptedFormats.contains(.decimalComma) {
                    rendered = rendered.replacingOccurrences(of: ".", with: ",")
                }
                rendered += "%"
            }
        case .fraction:
            if key.contains("/"), input.decimalPlaces == nil {
                rendered = key
            } else {
                let parts = rendered.split(separator: ".")
                if parts.count == 2 {
                    let sign = rendered.hasPrefix("-") ? "-" : ""
                    let digits = (parts[0] + parts[1]).drop(while: { $0 == "-" || $0 == "0" })
                    rendered = "\(sign)\(digits)/1\(String(repeating: "0", count: parts[1].count))"
                } else {
                    rendered += "/1"
                }
            }
        default:
            break
        }
        guard let unit = input.unit?.solveTrimmed, !unit.isEmpty, unit != "%" else { return rendered }
        return "\(rendered) \(unit)"
    }

    private static func addVarianceFeedback(to feedback: inout [SolveFieldFeedback], for fields: [SolveField],
                                            answers: [SolveAnswer]) {
        guard answers.count == 3, let meanInput = fields[0].input, let momentInput = fields[1].input,
              let varianceInput = fields[2].input, let meanKey = meanInput.answers.first.flatMap(keyNumber) else { return }
        func submitted(_ index: Int, input: SolveInput) -> Decimal? {
            guard case .text(let text) = answers[index] else { return nil }
            return number(text.solveTrimmed, for: input)
        }
        let learnerMean = submitted(0, input: meanInput)
        let learnerMoment = submitted(1, input: momentInput)
        if feedback[1].status == .incorrect, feedback[1].message == nil, let learnerMoment,
           let learnerMean, matches(learnerMoment, learnerMean * learnerMean, input: momentInput) {
            feedback[1].message = VarianceMistake.squaredMeanAsSecondMoment.rawValue
        }
        if feedback[2].status == .incorrect, feedback[2].message == nil, let learnerVariance = submitted(2, input: varianceInput),
           let learnerMoment, let learnerMean, matches(learnerVariance, learnerMoment - learnerMean, input: varianceInput),
           !matches(learnerVariance, learnerMoment - learnerMean * learnerMean, input: varianceInput) {
            feedback[2].message = VarianceMistake.unsquaredMean.rawValue
        } else if feedback[2].status == .incorrect, feedback[2].message == nil,
                  let learnerVariance = submitted(2, input: varianceInput),
                  matches(learnerVariance, meanKey * meanKey, input: varianceInput) {
            feedback[2].message = VarianceMistake.squaredMeanAsVariance.rawValue
        }
    }
}
