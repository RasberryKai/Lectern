import Foundation
import Testing
@testable import LecternCore

@Suite struct SolveCheckerTests {
    private func check(_ field: SolveField, answer: SolveAnswer) -> SolveFieldFeedback {
        let exercise = SolveCaseContent(prompt: "Exercise", fields: [field], explanation: "Solution")
        return SolveChecker.check(exercise, answers: [answer]).fields[0]
    }

    private func check(_ input: SolveInput, _ answer: String) -> SolveFieldFeedback {
        check(SolveField(prompt: "Answer", input: input), answer: .text(answer))
    }

    @Test func probabilityAcceptsEquivalentFormsWithinTolerance() {
        let input = SolveInput(kind: .number, answers: ["5/36"],
                               formats: [.decimalPoint, .decimalComma, .fraction, .percent], tolerance: 0.0005)
        for value in ["5/36", "10 / 72", "0.139", "0,139", "13.9%", "13,9 %"] {
            #expect(check(input, value).status == .correct)
        }
        #expect(check(input, "0.140").status == .incorrect)
        #expect(check(input, "5/0").status == .invalid)
        #expect(check(input, "5/36/2").status == .invalid)
        #expect(check(input, "13.9 percent").status == .invalid)
    }

    @Test func numberUsesDisplayedGroupingAndReportsReversedSign() {
        var input = SolveInput(kind: .number, answers: ["-1234.56"], formats: [.decimalComma])
        input.unit = "EUR"
        #expect(check(input, "−1.234,56 EUR").status == .correct)
        #expect(check(input, "+1.234,56").message == "The sign is reversed.")
        #expect(check(input, "-1,234.56").status == .invalid)
        #expect(check(input, "-1.23,456").status == .invalid)
        #expect(check(input, "-1234,56 USD").status == .invalid)
        #expect(check(input, "1234,56").expected == "-1234,56 EUR")

        input.formats = [.decimalPoint, .decimalComma]
        input.answers = ["1.234"]
        #expect(check(input, "1.234").status == .correct)
        #expect(check(input, "1,234").status == .correct)
        #expect(check(input, "1,234.00").status == .incorrect)
        #expect(input.instructions.contains("A single separator is the decimal mark"))

        var smallAmount = SolveInput(kind: .number, answers: ["0.01"], tolerance: 0.05)
        smallAmount.decimalPlaces = 1
        #expect(check(smallAmount, "-0.01").message == "The sign is reversed.")
    }

    @Test func standalonePercentAndFractionFormatsAndRoundingAreSupported() {
        let percent = SolveInput(kind: .number, answers: ["0.125"], formats: [.percent])
        #expect(check(percent, "12.5%").status == .correct)
        #expect(check(percent, "0.125").status == .invalid)
        #expect(check(percent, "10%").expected == "12.5%")

        let fraction = SolveInput(kind: .number, answers: ["0.5"], formats: [.fraction])
        #expect(check(fraction, "1/2").status == .correct)
        #expect(check(fraction, "0.5").status == .invalid)

        var rounded = SolveInput(kind: .number, answers: ["-1.235"])
        rounded.decimalPlaces = 2
        #expect(check(rounded, "-1.24").status == .correct)
        #expect(check(rounded, "-1.23").status == .incorrect)
        #expect(check(rounded, "-1.23").expected == "-1.24")
    }

    @Test func exactDatesRejectRolloverAndInvalidLeapDays() {
        let input = SolveInput(kind: .date, answers: ["2024-02-29"], formats: [.dayMonthYear, .monthDayYear, .isoDate])
        for value in ["29.02.2024", "02/29/2024", "2024-02-29"] {
            #expect(check(input, value).status == .correct)
        }
        for value in ["00.01.2028", "31.04.2024", "02/29/1900", "2024-02-30", "2023-02-29", "0000-01-01", "2024-2-29"] {
            #expect(check(input, value).status == .invalid)
        }
        #expect(check(input, "02/29/2000").status == .incorrect)
        #expect(check(input, "2024-03-01").expected == "29.02.2024")
    }

    @Test func termsHonorAliasesArticlesLocaleAndUnambiguousTypos() {
        var term = SolveInput(kind: .term, answers: ["l’arbre", "arbuste"])
        term.language = "fr"
        term.articles = ["l'", "un"]
        term.allowTypo = true
        #expect(check(term, "UN ARBRE").status == .correct)
        #expect(check(term, "arbust").message == "Accepted a one-character typo.")
        term.answers = ["cat", "mat"]
        #expect(check(term, "bat").status == .incorrect)

        term.language = "tr"
        term.answers = ["ışık"]
        #expect(check(term, "IŞIK").status == .correct)
        term.ignoreCase = false
        #expect(check(term, "IŞIK").status == .incorrect)
        term.language = "de"
        term.tonesMatter = false
        term.answers = ["Varianz"]
        term.ignoreCase = true
        #expect(check(term, "Variant").message == "Accepted a one-character typo.")
        term.ignoreCase = false
        #expect(check(term, "varianz").status == .incorrect)
    }

    @Test func pinyinNormalizesNumberedTonesAndPreservesHanziAndUmlauts() {
        var term = SolveInput(kind: .term, answers: ["你好", "nǐ hǎo"])
        term.language = "zh-Hans"
        term.tonesMatter = true
        term.allowTypo = true
        for value in ["你好", "Ni3 Hao3", "Ni3hao3"] {
            #expect(check(term, value).status == .correct)
        }
        #expect(check(term, "ni hao").status == .incorrect)
        #expect(check(term, "ni4 hao3").status == .incorrect)
        #expect(check(term, "你们").status == .incorrect)
        term.tonesMatter = false
        #expect(check(term, "ni hao").status == .correct)
        term.answers = ["lǜ"]
        #expect(check(term, "lv4").status == .correct)
        #expect(check(term, "lu").status == .incorrect)
    }

    @Test func choiceReportsOmissionsDistractorsAndExclusiveNone() {
        var choice = SolveChoice(options: [
            .init(label: "A", reason: "A reason"), .init(label: "B", reason: "B reason"),
            .init(label: "C", reason: "C reason")
        ], correct: ["A", "C"], multiple: true, noneReason: "Some are correct.", shuffle: true)
        var field = SolveField(prompt: "Choose", choice: choice)
        let partial = check(field, answer: .choice(["A", "B"], none: false))
        #expect(partial.status == .incorrect)
        #expect(partial.options.first { $0.label == "B" } == .init(label: "B", selected: true, correct: false, reason: "B reason"))
        #expect(partial.options.first { $0.label == "C" } == .init(label: "C", selected: false, correct: true, reason: "C reason"))
        #expect(check(field, answer: .choice(["A", "C"], none: false)).status == .correct)
        #expect(check(field, answer: .choice(["A"], none: true)).status == .invalid)
        #expect(check(field, answer: .choice([], none: false)).status == .invalid)

        choice.correct = []
        choice.noneReason = "All options are false."
        field.choice = choice
        #expect(check(field, answer: .choice([], none: true)).status == .correct)
        #expect(check(field, answer: .choice(["B"], none: false)).status == .incorrect)
    }

    @Test func orderingAcceptsAlternateSequencesAndRequiresAllItems() {
        let field = SolveField(prompt: "Arrange", order: .init(items: ["B", "C", "A"], sequences: [["A", "B", "C"], ["C", "A", "B"]]))
        let alternate = check(field, answer: .order(["C", "A", "B"]))
        #expect(alternate.status == .correct)
        #expect(alternate.expectedOrder == ["C", "A", "B"])
        let wrong = check(field, answer: .order(["B", "C", "A"]))
        #expect(wrong.status == .incorrect)
        #expect(wrong.expectedOrder == ["A", "B", "C"])
        #expect(check(field, answer: .order(["A", "A", "B"])).status == .invalid)
    }

    @Test func unorderedGridAssignsFullRowsAndCountsDuplicatesOnceEach() {
        func row(_ labels: [String], _ amount: String) -> [SolveInput] {
            [.init(kind: .option, answers: labels), .init(kind: .number, answers: [amount])]
        }
        var grid = SolveGrid(columns: ["Account", "Amount"], rows: [row(["A", "B"], "2"), row(["B"], "2")],
                             options: ["A", "B"], rowOrderMatters: false, shuffle: true)
        var field = SolveField(prompt: "Bookings", grid: grid)
        #expect(check(field, answer: .grid([["B", "2"], ["A", "2"]])).status == .correct)

        grid.rows = [row(["A"], "1"), row(["B"], "2"), row(["B"], "2")]
        field.grid = grid
        #expect(check(field, answer: .grid([["B", "2"], ["B", "2"], ["A", "1"]])).status == .correct)
        let repeated = check(field, answer: .grid([["B", "2"], ["B", "2"], ["B", "2"]]))
        #expect(repeated.status == .incorrect)
        #expect(repeated.cells.count(where: { $0.allSatisfy { $0.status == .correct } }) == 2)
        let missing = check(field, answer: .grid([["B", "2"], ["B", "2"]]))
        #expect(missing.message == "One row is missing.")
        #expect(missing.cells.last?.compactMap(\.expected) == ["A", "1"])
        #expect(check(field, answer: .grid([["A", "1oops"], ["B", "2"], ["B", "2"]])).status == .invalid)
    }

    @Test func matchingGridChecksTitlesAgainstValuesAndAllowsReuse() {
        let grid = SolveGrid(columns: ["Match"], rows: [
            [.init(kind: .option, answers: ["B"])], [.init(kind: .option, answers: ["B"])],
            [.init(kind: .option, answers: ["A"])]
        ], rowLabels: ["One", "Two", "Three"], options: ["A", "B", "Distractor"], rowOrderMatters: true, shuffle: true)
        let field = SolveField(prompt: "Match", grid: grid)
        #expect(check(field, answer: .grid([["B"], ["B"], ["A"]])).status == .correct)
        let mismatch = check(field, answer: .grid([["A"], ["B"], ["B"]]))
        #expect(mismatch.cells.map { $0[0].status } == [.incorrect, .correct, .incorrect])
        #expect(check(field, answer: .grid([["X"], ["B"], ["A"]])).status == .invalid)
    }

    @Test func locallyComputedVarianceExplainsRecognizableMistakes() {
        let content = SolveVariance(outcomes: [0, 2], weights: [1, 3]).exercise
        let moment = SolveChecker.check(content, answers: [.text("1.5"), .text("2.25"), .text("0.75")])
        #expect(moment.fields[1].message?.contains("square of your E(X)") == true)
        let variance = SolveChecker.check(content, answers: [.text("1.5"), .text("3"), .text("1.5")])
        #expect(variance.fields[2].message?.contains("E(X²) minus E(X)") == true)
        let malformed = SolveChecker.check(content, answers: [.text("1.5"), .text("three"), .text("0.75")])
        #expect(malformed.hasInvalidInput)
        #expect(!malformed.isCorrect)
    }

    @Test func fullRangeUniformVarianceStillYieldsFreshComparableCases() {
        let sample = SolveVariance(outcomes: [-100, 100], weights: [1, 1]).exercise
        var card = SolveCard(draft: SolveDraft(skill: "Variance", reason: "Apply the formula", variation: "Different tables", sample: sample))
        let variants = card.varianceVariants(count: 20)
        #expect(variants.count == 20)
        #expect(variants.allSatisfy { $0.variance?.isValid == true && $0.variance?.weights != [1, 1] })
        #expect(card.append(variants) == variants.count)
        #expect(card.append(variants) == 0)
        let more = card.varianceVariants(count: 20)
        #expect(more.count == 20)
        #expect(card.append(more) == more.count)
    }

    @Test func persistedAnswersRoundTripAllFieldKinds() throws {
        let answers: [SolveAnswer] = [.text("1.23"), .choice(["A", "B"], none: false), .order(["C", "A"]), .grid([["B"], ["A"]])]
        let restored = try JSONDecoder().decode([SolveAnswer].self, from: JSONEncoder().encode(answers))
        #expect(restored == answers)
    }
}
