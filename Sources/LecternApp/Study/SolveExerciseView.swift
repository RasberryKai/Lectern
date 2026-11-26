import LecternCore
import SwiftUI

/// The same exercise and local feedback appear in the Review sample and in Study.
struct SolveExerciseView: View {
    let content: SolveCaseContent
    var canReveal = false
    var canRetry = false
    var onCheck: ([SolveAnswer]) -> Void = { _ in }

    @State private var attempt: Attempt
    @FocusState private var focusedInput: InputLocation?

    init(content: SolveCaseContent, answers: [SolveAnswer]? = nil, canReveal: Bool = false,
         canRetry: Bool = false, onCheck: @escaping ([SolveAnswer]) -> Void = { _ in }) {
        self.content = content
        self.canReveal = canReveal
        self.canRetry = canRetry
        self.onCheck = onCheck
        _attempt = State(initialValue: Attempt(content: content, answers: answers))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ChatMarkdownView(text: content.prompt) { _ in }
            ForEach(content.fields.indices, id: \.self) { index in
                field(content.fields[index], at: index)
            }
            if attempt.isShowingSolution { solution }
            else { actions }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func field(_ field: SolveField, at index: Int) -> some View {
        let feedback = attempt.result?.fields[safe: index]
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(field.prompt).font(Theme.body.weight(.semibold))
                if let feedback, attempt.isShowingSolution || feedback.status == .invalid {
                    statusIcon(feedback.status)
                }
            }
            if let input = field.input {
                let value = binding(index, fallback: "") { answer in
                    if case .text(let text) = answer { return text }
                    return ""
                } write: { .text($0) }
                textInput(value, input: input, label: field.prompt, location: .field(index))
                if attempt.isShowingSolution, let expected = feedback?.expected ?? input.answers.first {
                    expectedValue(expected)
                }
            } else if let choice = field.choice {
                choiceInput(choice, at: index, feedback: feedback)
            } else if let order = field.order {
                orderInput(order, at: index, feedback: feedback)
            } else if let grid = field.grid {
                gridInput(grid, at: index, feedback: feedback)
            }
            if let feedback, let message = feedback.message, attempt.isShowingSolution || feedback.status == .invalid {
                Text(message).font(Theme.small)
                    .foregroundStyle(feedback.status == .invalid ? Theme.bad : Theme.quiet)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func textInput(_ value: Binding<String>, input: SolveInput, label: String, location: InputLocation) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Your answer", text: value)
                .textFieldStyle(.roundedBorder)
                .font(Theme.body)
                .focused($focusedInput, equals: location)
                .onSubmit { check() }
                .accessibilityLabel(label)
                .accessibilityHint(input.instructions)
                .disabled(attempt.isShowingSolution)
            if !input.instructions.isEmpty {
                Text(input.instructions).font(Theme.caption).foregroundStyle(Theme.quiet)
                    .accessibilityHidden(true)
            }
        }
    }

    private func choiceInput(_ choice: SolveChoice, at index: Int, feedback: SolveFieldFeedback?) -> some View {
        let selection = choiceSelection(at: index)
        let options = attempt.options[index]
        return VStack(alignment: .leading, spacing: 4) {
            Text(choice.multiple ? "Select all that apply." : "Select one answer.")
                .font(Theme.caption).foregroundStyle(Theme.quiet)
            ForEach(options, id: \.self) { label in
                choiceRow(label, selected: selection.labels.contains(label), multiple: choice.multiple,
                          feedback: attempt.isShowingSolution ? feedback?.options.first { $0.label == label } : nil,
                          revealedKey: attempt.revealedKey ? choice.correct.contains(label) : nil,
                          reason: choice.options.first { $0.label == label }?.reason) {
                    var labels = selection.labels
                    if !choice.multiple { labels = [label] }
                    else if labels.remove(label) == nil { labels.insert(label) }
                    update(.choice(labels, none: false), at: index)
                }
            }
            if let noneReason = choice.noneReason {
                choiceRow("None of these", selected: selection.none, multiple: choice.multiple,
                          feedback: attempt.isShowingSolution ? feedback?.options.first { $0.label == "None of these" } : nil,
                          revealedKey: attempt.revealedKey ? choice.correct.isEmpty : nil,
                          reason: noneReason) {
                    update(.choice([], none: choice.multiple ? !selection.none : true), at: index)
                }
            }
        }
    }

    private func choiceRow(_ label: String, selected: Bool, multiple: Bool, feedback: SolveOptionFeedback?,
                           revealedKey: Bool?, reason: String?, select: @escaping () -> Void) -> some View {
        let correct = feedback?.correct ?? revealedKey
        return VStack(alignment: .leading, spacing: 5) {
            Button(action: select) {
                HStack(spacing: 8) {
                    Image(systemName: choiceIndicator(multiple: multiple, selected: selected))
                        .foregroundStyle(selected ? Theme.accentText : Theme.quiet)
                        .accessibilityHidden(true)
                    Text(label).font(Theme.body)
                    Spacer(minLength: 4)
                    if let correct {
                        if correct && (selected || revealedKey != nil) { statusIcon(.correct) }
                        else if correct { Label("Missed", systemImage: "exclamationmark.circle").foregroundStyle(Theme.amber) }
                        else if selected { statusIcon(.incorrect) }
                    }
                }
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .disabled(attempt.isShowingSolution)
            if correct != nil, let reason = feedback?.reason ?? reason {
                Text(reason).font(Theme.small).foregroundStyle(Theme.quiet)
                    .padding(.leading, 22)
            }
        }
    }

    private func choiceIndicator(multiple: Bool, selected: Bool) -> String {
        if multiple { return selected ? "checkmark.square.fill" : "square" }
        return selected ? "largecircle.fill.circle" : "circle"
    }

    private func orderInput(_ order: SolveOrder, at field: Int, feedback: SolveFieldFeedback?) -> some View {
        let items = orderItems(at: field)
        return VStack(alignment: .leading, spacing: 5) {
            if !attempt.isShowingSolution {
                Text("Use the arrows to arrange the items.").font(Theme.caption).foregroundStyle(Theme.quiet)
            }
            ForEach(Array(items.enumerated()), id: \.element) { index, item in
                HStack(spacing: 8) {
                    Text("\(index + 1)").font(Theme.caption.monospacedDigit()).foregroundStyle(Theme.quiet)
                        .frame(minWidth: 18)
                    Text(item).font(Theme.body)
                    Spacer(minLength: 4)
                    if !attempt.isShowingSolution {
                        orderButton("up", item: item, disabled: index == items.startIndex) {
                            moveOrder(in: field, items: items, from: index, to: index - 1)
                        }
                        orderButton("down", item: item, disabled: index == items.count - 1) {
                            moveOrder(in: field, items: items, from: index, to: index + 1)
                        }
                    }
                }
                .padding(7)
                .background(Theme.inset, in: RoundedRectangle(cornerRadius: 6))
            }
            if attempt.isShowingSolution, let expected = feedback?.expectedOrder.nonEmpty ?? order.sequences.first {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Correct order").eyebrow()
                    ForEach(Array(expected.enumerated()), id: \.offset) { index, item in
                        Text("\(index + 1). \(item)").font(Theme.body)
                    }
                }
                .padding(.top, 5)
            }
        }
    }

    private func orderButton(_ direction: String, item: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "arrow.\(direction)").frame(width: 15, height: 14)
        }
        .buttonStyle(SecondaryButtonStyle())
        .accessibilityLabel("Move \(item) \(direction)")
        .disabled(disabled)
    }

    private func gridInput(_ grid: SolveGrid, at field: Int, feedback: SolveFieldFeedback?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !attempt.isShowingSolution {
                Text(grid.rowOrderMatters ? "Use the order shown." : "You can enter the rows in any order.")
                    .font(Theme.caption).foregroundStyle(Theme.quiet)
            }
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                    GridRow {
                        if grid.rowLabels != nil { Color.clear.frame(width: 1, height: 1).accessibilityHidden(true) }
                        ForEach(grid.columns, id: \.self) { heading in
                            Text(heading).font(Theme.small.weight(.semibold))
                        }
                    }
                    ForEach(grid.rows.indices, id: \.self) { row in
                        GridRow(alignment: .top) {
                            if let rowLabel = grid.rowLabels?[safe: row] {
                                Text(rowLabel).font(Theme.body).padding(.top, 4).frame(maxWidth: 170, alignment: .leading)
                            }
                            ForEach(grid.columns.indices, id: \.self) { column in
                                gridCell(grid, at: field, row: row, column: column,
                                         feedback: feedback?.cells[safe: row]?[safe: column])
                            }
                        }
                    }
                }
                .padding(3)
            }
            .defaultScrollAnchor(.leading)
        }
    }

    private func gridCell(_ grid: SolveGrid, at field: Int, row: Int, column: Int, feedback: SolveCellFeedback?) -> some View {
        let input = grid.rows[row][column]
        let rowLabel = grid.rowLabels?[safe: row] ?? "Row \(row + 1)"
        let label = "\(rowLabel), \(grid.columns[column])"
        let value = Binding(
            get: { gridValues(at: field)[row][column] },
            set: { text in
                var rows = gridValues(at: field)
                rows[row][column] = text
                update(.grid(rows), at: field)
            }
        )
        return VStack(alignment: .leading, spacing: 4) {
            if input.kind == .option {
                Picker(label, selection: value) {
                    Text("Choose…").tag("")
                    ForEach(attempt.options[field], id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .accessibilityLabel(label)
                .disabled(attempt.isShowingSolution)
            } else {
                textInput(value, input: input, label: label, location: .cell(field, row, column))
            }

            if let feedback, attempt.isShowingSolution || feedback.status == .invalid {
                HStack(spacing: 4) {
                    statusIcon(feedback.status)
                    if let message = feedback.message {
                        Text(message).font(Theme.caption).foregroundStyle(Theme.bad)
                    }
                }
            }
            if attempt.isShowingSolution, let expected = feedback?.expected ?? input.answers.first {
                expectedValue(expected)
            }
        }
        .frame(minWidth: 112, idealWidth: 152, maxWidth: 200, alignment: .leading)
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            if attempt.result?.hasInvalidInput == true {
                Label("Fix the marked fields, then check again.", systemImage: "exclamationmark.circle")
                    .font(Theme.small).foregroundStyle(Theme.bad)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            HStack(spacing: 10) {
                Button("Check", action: check).buttonStyle(PrimaryButtonStyle())
                if canReveal {
                    Button("Show solution") {
                        focusedInput = nil
                        attempt.result = nil
                        attempt.revealedKey = true
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }
        }
    }

    private var solution: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let result = attempt.result {
                Label(result.isCorrect ? "All answers match" : "Review the marked answers",
                      systemImage: result.isCorrect ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .font(Theme.body.weight(.semibold))
                    .foregroundStyle(result.isCorrect ? Theme.accentText : Theme.amber)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            Text("Worked solution").eyebrow()
            ChatMarkdownView(text: content.explanation) { _ in }
            if canRetry {
                Button("Try again") { attempt = Attempt(content: content) }
                    .buttonStyle(LinkButtonStyle())
            }
        }
        .panel(padding: 12, fill: Theme.inset)
    }

    private func expectedValue(_ expected: String) -> some View {
        Text("Expected · \(expected)").font(Theme.small)
            .foregroundStyle(Theme.quiet)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    private func statusIcon(_ status: SolveFeedbackStatus) -> some View {
        let (label, symbol, color) = switch status {
        case .correct: ("Correct", "checkmark.circle.fill", Theme.accentText)
        case .incorrect: ("Incorrect", "xmark.circle", Theme.bad)
        case .invalid: ("Invalid", "exclamationmark.circle", Theme.bad)
        }
        return Image(systemName: symbol).font(Theme.small).foregroundStyle(color)
            .accessibilityLabel(label)
    }

    private func check() {
        guard !attempt.isShowingSolution else { return }
        let result = SolveChecker.check(content, answers: attempt.answers)
        attempt.result = result
        guard !result.hasInvalidInput else { return }
        focusedInput = nil
        onCheck(attempt.answers)
    }

    private func update(_ answer: SolveAnswer, at index: Int) {
        guard !attempt.isShowingSolution else { return }
        if attempt.answers[index] != answer {
            attempt.answers[index] = answer
            attempt.result = nil
        }
    }

    private func binding<Value>(_ index: Int, fallback: Value, read: @escaping (SolveAnswer) -> Value,
                                write: @escaping (Value) -> SolveAnswer) -> Binding<Value> {
        Binding(get: { attempt.answers[safe: index].map(read) ?? fallback },
                set: { update(write($0), at: index) })
    }

    private func choiceSelection(at index: Int) -> (labels: Set<String>, none: Bool) {
        guard case .choice(let labels, let none) = attempt.answers[index] else { return ([], false) }
        return (labels, none)
    }

    private func orderItems(at index: Int) -> [String] {
        guard case .order(let items) = attempt.answers[index] else { return [] }
        return items
    }

    private func moveOrder(in field: Int, items: [String], from: Int, to: Int) {
        guard items.indices.contains(to) else { return }
        var updated = items
        updated.swapAt(from, to)
        update(.order(updated), at: field)
    }

    private func gridValues(at index: Int) -> [[String]] {
        guard case .grid(let rows) = attempt.answers[index] else { return [] }
        return rows
    }

    private enum InputLocation: Hashable {
        case field(Int)
        case cell(Int, Int, Int)
    }

    private struct Attempt {
        var answers: [SolveAnswer]
        let options: [[String]]
        var result: SolveCheckResult?
        var revealedKey = false

        var isShowingSolution: Bool { revealedKey || result?.hasInvalidInput == false }

        init(content: SolveCaseContent, answers: [SolveAnswer]? = nil) {
            options = content.fields.map { field in
                if let choice = field.choice {
                    let labels = choice.options.map(\.label)
                    return choice.shuffle ? labels.shuffled() : labels
                }
                if let grid = field.grid { return grid.shuffle ? grid.options.shuffled() : grid.options }
                return []
            }
            self.answers = answers ?? content.fields.map { field in
                if field.choice != nil { return .choice([], none: false) }
                if let order = field.order { return .order(order.items.shuffled()) }
                if let grid = field.grid {
                    return .grid(grid.rows.map { $0.map { _ in "" } })
                }
                return .text("")
            }
            result = answers.map { SolveChecker.check(content, answers: $0) }
        }
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }

    var nonEmpty: Self? { isEmpty ? nil : self }
}
