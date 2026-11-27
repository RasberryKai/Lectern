import AppKit
import LecternCore
import SwiftUI

/// Review and Study share the inputs, local checker feedback, and worked solution.
struct SolveExerciseView: View {
    enum Mode { case attempt, browse }

    let content: SolveCaseContent
    var mode: Mode
    var canReveal: Bool
    var canRetry: Bool
    var showAnswerKey: Bool
    var showsMistakeMessages: Bool
    var showsWorkedSolutionWhenCorrect: Bool
    var usesKeyboardShortcuts: Bool
    var onReveal: () -> Void
    var onCheck: ([SolveAnswer]) -> Void

    @State private var attempt: Attempt
    @FocusState private var focusedInput: InputLocation?
    @Environment(\.isEnabled) private var isEnabled

    init(
        content: SolveCaseContent, answers: [SolveAnswer]? = nil, mode: Mode = .attempt,
        canReveal: Bool = false, canRetry: Bool = false, showAnswerKey: Bool = false,
        showsMistakeMessages: Bool = false, showsWorkedSolutionWhenCorrect: Bool = true, usesKeyboardShortcuts: Bool = true,
        onReveal: @escaping () -> Void = {}, onCheck: @escaping ([SolveAnswer]) -> Void = { _ in }
    ) {
        let content = content.checkedContent ?? content
        self.content = content
        self.mode = mode
        self.canReveal = canReveal
        self.canRetry = canRetry
        self.showAnswerKey = showAnswerKey
        self.showsMistakeMessages = showsMistakeMessages
        self.showsWorkedSolutionWhenCorrect = showsWorkedSolutionWhenCorrect
        self.usesKeyboardShortcuts = usesKeyboardShortcuts
        self.onReveal = onReveal
        self.onCheck = onCheck
        _attempt = State(initialValue: Attempt(content: content, answers: answers, shuffle: mode == .attempt))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                if !clozeInPrompt {
                    prompt(content.prompt, isStatement: content.fields.count == 1 && binaryChoice(0))
                }
                ForEach(content.fields.indices, id: \.self) { index in
                    field(content.fields[index], at: index)
                }
                if let result = activeFeedback {
                    resultBanner(result)
                }
                if isLocked {
                    if isShowingKey || checkedResult?.isCorrect == false || showsWorkedSolutionWhenCorrect {
                        solution
                    }
                    if showsMistakeMessages { mistakeMessages }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 26)
            .padding(.vertical, 20)

            if !isLocked || canRetry && mode == .attempt && !showAnswerKey { footer }
        }
        .background {
            if usesChoiceKeys {
                KeyMonitor(handler: handleChoiceKey)
            }
        }
        .onAppear(perform: focusFirstInput)
        .onChange(of: isLocked) { _, isLocked in
            if isLocked { focusedInput = nil }
        }
    }

    private var checkedResult: SolveCheckResult? {
        guard let result = attempt.result, !result.hasInvalidInput else { return nil }
        return result
    }

    private var isShowingKey: Bool {
        mode == .browse || checkedResult == nil && (showAnswerKey || attempt.revealedKey)
    }

    private var isLocked: Bool { isShowingKey || checkedResult != nil }

    private var activeFeedback: SolveCheckResult? { isShowingKey ? nil : attempt.result }

    private var usesChoiceKeys: Bool {
        usesKeyboardShortcuts && !isLocked && content.fields.count == 1 && content.fields.first?.choice != nil
    }

    private var clozeInPrompt: Bool {
        content.fields.count == 1 && content.fields.first?.input?.kind == .term && clozeParts(content.prompt) != nil
    }

    private func prompt(_ text: String, isStatement: Bool) -> some View {
        ChatMarkdownView(text: text, textSize: 19) { _ in }
            .padding(.leading, isStatement ? 14 : 0)
            .overlay(alignment: .leading) {
                if isStatement {
                    RoundedRectangle(cornerRadius: 1).fill(Theme.borderStrong).frame(width: 3)
                        .accessibilityHidden(true)
                }
            }
    }

    @ViewBuilder private func field(_ field: SolveField, at index: Int) -> some View {
        let feedback = activeFeedback?.fields[safe: index]
        let cloze = field.input?.kind == .term ? clozeParts(clozeInPrompt ? content.prompt : field.prompt) : nil
        VStack(alignment: .leading, spacing: 8) {
            if cloze == nil && showsFieldLabel(field.prompt) {
                Text(field.prompt)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let input = field.input {
                scalarField(input, label: field.prompt, index: index, cloze: cloze, feedback: feedback)
            } else if let choice = field.choice {
                choiceInput(choice, at: index, feedback: feedback)
            } else if let order = field.order {
                orderInput(order, at: index, feedback: feedback)
            } else if let grid = field.grid {
                gridInput(grid, at: index, feedback: feedback)
            }
            if let feedback, let message = feedback.message, isLocked || feedback.status == .invalid {
                feedbackNote(message, status: feedback.status)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func showsFieldLabel(_ label: String) -> Bool {
        let normalized = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard content.fields.count == 1 else { return true }
        return normalized != content.prompt.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            && !["answer", "your answer", "answer:", "your answer:"].contains(normalized)
    }

    private func scalarField(_ input: SolveInput, label: String, index: Int, cloze: [String]?,
                             feedback: SolveFieldFeedback?) -> some View {
        let value = Binding(
            get: {
                if case .text(let text) = attempt.answers[index] { return text }
                return ""
            },
            set: { update(.text($0), at: index) }
        )
        let appearance = fieldAppearance(feedback?.status)
        return VStack(alignment: .leading, spacing: 7) {
            if let cloze {
                let sentence = cloze.joined(separator: " blank ")
                SolveClozeLayout {
                    clozeWords(cloze[0])
                    inputBox(value, input: input, label: sentence, location: .field(index), appearance: appearance)
                        .frame(idealWidth: 190, maxWidth: 190)
                    clozeWords(cloze[1])
                }
                .font(.system(size: 19))
                .foregroundStyle(Theme.ink)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        inputBox(value, input: input, label: label, location: .field(index), appearance: appearance)
                            .frame(width: 190)
                        formatBadge(input)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        inputBox(value, input: input, label: label, location: .field(index), appearance: appearance)
                            .frame(maxWidth: 190)
                        formatBadge(input)
                    }
                }
            }
            if cloze != nil { formatBadge(input) }
            if feedback?.status == .incorrect, let expected = feedback?.expected {
                expectedValue(expected)
            } else if isLocked, input.kind == .term, input.answers.count > 1 {
                Text("Accepted: \(input.answers.joined(separator: ", "))")
                    .font(Theme.small)
                    .foregroundStyle(Theme.quiet)
                    .textSelection(.enabled)
            }
        }
    }

    private func clozeParts(_ text: String) -> [String]? {
        let parts = text.components(separatedBy: "____")
        guard parts.count == 2, !text.contains("\n"), !text.contains("$"),
              !parts.contains(where: { $0.hasPrefix("_") || $0.hasSuffix("_") }) else { return nil }
        return parts
    }

    private func clozeWords(_ text: String) -> some View {
        ForEach(Array(text.split(whereSeparator: \.isWhitespace).enumerated()), id: \.offset) { _, word in
            Text(verbatim: String(word)).accessibilityHidden(true)
        }
    }

    @ViewBuilder private func formatBadge(_ input: SolveInput) -> some View {
        if !input.instructions.isEmpty {
            Text(input.instructions)
                .font(Theme.small.weight(.semibold))
                .foregroundStyle(Theme.ai)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Theme.aiWash, in: RoundedRectangle(cornerRadius: 6))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private func inputBox(
        _ value: Binding<String>, input: SolveInput, label: String, location: InputLocation,
        appearance: FieldAppearance, compact: Bool = false, alignTrailing: Bool = false
    ) -> some View {
        let display = isShowingKey ? SolveChecker.displayedAnswers(for: input).first ?? "" : value.wrappedValue
        let hint = inputPlaceholder(input, compact: compact)
        let alignment: Alignment = alignTrailing ? .trailing : .leading
        let layout = RoundedRectangle(cornerRadius: 8)
        let focused = focusedInput == location && !isLocked
        Group {
            if isLocked {
                HStack(spacing: 6) {
                    Text(verbatim: display.isEmpty ? "—" : display)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: alignment)
                    if let symbol = appearance.symbol {
                        Image(systemName: symbol).font(Theme.caption).accessibilityHidden(true)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(label)
                .accessibilityValue([display, appearance.summary].filter { !$0.isEmpty }.joined(separator: ", "))
            } else {
                TextField(label, text: value, prompt: Text(hint).foregroundStyle(Theme.faint))
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(alignTrailing ? .trailing : .leading)
                    .focused($focusedInput, equals: location)
                    .onSubmit(check)
                    .accessibilityHint(input.instructions)
            }
        }
        .font(.system(size: compact ? 15 : 16, weight: .medium).monospacedDigit())
        .foregroundStyle(appearance.ink)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(minHeight: 42)
        .background(appearance.fill, in: layout)
        .overlay {
            layout.strokeBorder(focused ? Theme.ai : appearance.stroke, lineWidth: focused ? 2 : 1)
                .allowsHitTesting(false)
        }
    }

    private func inputPlaceholder(_ input: SolveInput, compact: Bool) -> String {
        if input.kind == .date { return input.acceptedFormats.first?.label ?? "" }
        guard !compact else { return "" }
        switch input.acceptedFormats.first {
        case .fraction: return "a/b"
        case .percent: return "0%"
        case .decimalPoint, .decimalComma:
            guard let places = input.decimalPlaces, places > 0 else { return "0" }
            let separator = input.acceptedFormats.first == .decimalComma ? "," : "."
            return "0" + separator + String(repeating: "0", count: places)
        default: return ""
        }
    }

    private func binaryChoice(_ index: Int) -> Bool {
        guard let choice = content.fields[index].choice, !choice.multiple, choice.noneReason == nil else { return false }
        let labels = Set(choice.options.map { $0.label.lowercased() })
        return labels == ["true", "false"] || labels == ["wahr", "falsch"]
    }

    private func choiceInput(_ choice: SolveChoice, at index: Int, feedback: SolveFieldFeedback?) -> some View {
        let binary = binaryChoice(index)
        let options = binary ? choice.options.map(\.label) : attempt.options[index]
        return VStack(alignment: .leading, spacing: 8) {
            if binary {
                HStack(spacing: 10) {
                    ForEach(options, id: \.self) { label in
                        choiceRow(label, choice: choice, field: index, position: nil, feedback: feedback, binary: true)
                    }
                }
                if isLocked, let correct = choice.correct.first,
                   let reason = choice.options.first(where: { $0.label == correct })?.reason {
                    Text(reason).font(.system(size: 14)).foregroundStyle(Theme.quiet)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                if !isLocked {
                    Text(choice.multiple ? "Select all that apply." : "Select one answer.")
                        .font(Theme.small).foregroundStyle(Theme.quiet)
                }
                ForEach(Array(options.enumerated()), id: \.element) { offset, label in
                    choiceRow(label, choice: choice, field: index, position: offset + 1, feedback: feedback)
                }
                if choice.noneReason != nil {
                    choiceRow("None of these", choice: choice, field: index, position: options.count + 1,
                              feedback: feedback, isNone: true)
                }
            }
        }
    }

    private func choiceRow(
        _ label: String, choice: SolveChoice, field: Int, position: Int?, feedback: SolveFieldFeedback?,
        binary: Bool = false, isNone: Bool = false
    ) -> some View {
        let selection = choiceSelection(at: field)
        let correct = isNone ? choice.correct.isEmpty : choice.correct.contains(label)
        let selected = isShowingKey ? correct : (isNone ? selection.none : selection.labels.contains(label))
        let appearance: FieldAppearance = if isShowingKey && correct { .key }
        else if isLocked && selected { correct ? .correct : .incorrect }
        else if checkedResult != nil && correct { .missed }
        else if isLocked { .quiet }
        else { selected ? .selected : .plain }
        let option = feedback?.options.first { $0.label == label }
        let reason = option?.reason ?? (isNone ? choice.noneReason : choice.options.first { $0.label == label }?.reason)
        let shape = RoundedRectangle(cornerRadius: 10)

        return Button {
            selectChoice(label, at: field, choice: choice, none: isNone)
        } label: {
            Group {
                if binary {
                    HStack(spacing: 8) {
                        Text(label).font(.system(size: 15, weight: .semibold))
                        if isLocked, let symbol = appearance.symbol {
                            Image(systemName: symbol).font(Theme.small).accessibilityHidden(true)
                        } else if usesChoiceKeys, let key = binaryShortcut(label), key != "t" || !canReveal {
                            ShortcutKey(text: key.uppercased()).accessibilityHidden(true)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .padding(.horizontal, 8)
                } else {
                    HStack(alignment: .top, spacing: 10) {
                        Text(position.map(String.init) ?? "")
                            .font(Theme.small.weight(.semibold).monospacedDigit())
                            .foregroundStyle(Theme.faint)
                            .frame(width: 18, alignment: .leading)
                            .accessibilityHidden(true)
                        choiceIndicator(multiple: choice.multiple, selected: selected, appearance: appearance)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(label).font(.system(size: 15))
                            if appearance == .incorrect || appearance == .missed {
                                Text(appearance == .missed ? "Missed" : "Wrongly selected")
                                    .font(Theme.caption.weight(.semibold))
                                    .foregroundStyle(Theme.bad)
                            }
                            if isLocked, let reason {
                                Text(reason).font(.system(size: 13.5)).foregroundStyle(Theme.quiet)
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
            }
            .foregroundStyle(appearance.ink)
            .background(appearance.fill, in: shape)
            .overlay {
                shape.strokeBorder(
                    appearance.stroke,
                    style: StrokeStyle(lineWidth: appearance == .selected ? 2 : 1,
                                       dash: appearance == .missed || isNone ? [4, 3] : [])
                )
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityValue(appearance.summary)
        .disabled(isLocked)
    }

    private func choiceIndicator(multiple: Bool, selected: Bool, appearance: FieldAppearance) -> some View {
        let shape = RoundedRectangle(cornerRadius: multiple ? 5 : 10)
        return ZStack {
            shape.fill(selected ? appearance.stroke : Theme.surface)
            shape.strokeBorder(selected ? appearance.stroke : Theme.borderStrong, lineWidth: 1.5)
            if selected {
                Image(systemName: appearance == .incorrect ? "xmark" : "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(appearance == .selected ? Theme.surface : Theme.onAccent)
            }
        }
        .frame(width: 20, height: 20)
        .accessibilityHidden(true)
    }

    private func choiceSelection(at index: Int) -> (labels: Set<String>, none: Bool) {
        guard case .choice(let labels, let none) = attempt.answers[index] else { return ([], false) }
        return (labels, none)
    }

    private func selectChoice(_ label: String, at index: Int, choice: SolveChoice, none: Bool = false) {
        let selection = choiceSelection(at: index)
        if none {
            update(.choice([], none: !choice.multiple || !selection.none), at: index)
        } else if !choice.multiple {
            update(.choice([label], none: false), at: index)
        } else {
            var labels = selection.labels
            if labels.remove(label) == nil { labels.insert(label) }
            update(.choice(labels, none: false), at: index)
        }
    }

    private func binaryShortcut(_ label: String) -> String? {
        switch label.lowercased() {
        case "true", "wahr": "t"
        case "false", "falsch": "f"
        default: nil
        }
    }

    private func handleChoiceKey(_ event: NSEvent, _ editingText: Bool) -> Bool {
        guard isEnabled, !isLocked, !editingText, !event.isARepeat, Key.modifiers(event).isEmpty,
              content.fields.count == 1, let choice = content.fields.first?.choice else { return false }
        let key = Key.letter(event)
        if binaryChoice(0) {
            guard key != "t" || !canReveal,
                  let label = choice.options.first(where: { binaryShortcut($0.label) == key })?.label else { return false }
            selectChoice(label, at: 0, choice: choice)
        } else {
            let options = attempt.options[0]
            guard let position = Int(key), position > 0 else { return false }
            if let label = options[safe: position - 1] {
                selectChoice(label, at: 0, choice: choice)
            } else if position == options.count + 1, choice.noneReason != nil {
                selectChoice("None of these", at: 0, choice: choice, none: true)
            } else {
                return false
            }
        }
        return true
    }

    private func orderInput(_ order: SolveOrder, at field: Int, feedback: SolveFieldFeedback?) -> some View {
        let items = isShowingKey ? order.sequences.first ?? [] : orderItems(at: field)
        let expected = feedback?.expectedOrder ?? []
        let firstWrong = items.indices.first { position in
            expected[safe: position].map { $0 != items[position] } == true
        }
        return VStack(alignment: .leading, spacing: 8) {
            if isLocked {
                ForEach(Array(items.enumerated()), id: \.element) { position, item in
                    let status = expected[safe: position].map { $0 == item ? SolveFeedbackStatus.correct : .incorrect }
                    orderRow(item, position: position, count: items.count, field: field,
                             appearance: fieldAppearance(status), dragging: false,
                             correction: firstWrong == position ? expected[safe: position] : nil)
                }
            } else {
                SolveOrderingView(items: items, onMove: { moveOrder(in: field, from: $0, to: $1) }) { item, position, dragging in
                    orderRow(item, position: position, count: items.count, field: field,
                             appearance: .plain, dragging: dragging)
                }
                Text("Drag to reorder or use ⌥↑ / ⌥↓ on a focused item.")
                    .font(Theme.small)
                    .foregroundStyle(Theme.quiet)
            }
            if let firstWrong, let correction = expected[safe: firstWrong] {
                Text("First wrong position: \(correction) belongs at position \(firstWrong + 1).")
                    .font(Theme.small)
                    .foregroundStyle(Theme.bad)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if firstWrong != nil {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Correct order").eyebrow()
                    ForEach(Array(expected.enumerated()), id: \.element) { index, item in
                        Text("\(index + 1). \(item)").font(Theme.body)
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    private func orderRow(
        _ item: String, position: Int, count: Int, field: Int, appearance: FieldAppearance,
        dragging: Bool, correction: String? = nil
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10)
        return HStack(spacing: 10) {
            Text("\(position + 1)")
                .font(Theme.body.weight(.semibold).monospacedDigit())
                .foregroundStyle(Theme.faint)
                .frame(minWidth: 18, alignment: .leading)
                .accessibilityHidden(true)
            Text(item)
                .font(.system(size: 15))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if isLocked {
                if let symbol = appearance.symbol {
                    Image(systemName: symbol)
                        .font(Theme.small)
                        .accessibilityLabel(appearance.summary)
                }
            } else {
                Image(systemName: "line.3.horizontal")
                    .font(Theme.small.weight(.medium))
                    .foregroundStyle(Theme.faint)
                    .accessibilityHidden(true)
                HStack(spacing: 4) {
                    orderButton("up", item: item, disabled: position == 0) {
                        moveOrder(in: field, from: position, to: position - 1)
                    }
                    orderButton("down", item: item, disabled: position == count - 1) {
                        moveOrder(in: field, from: position, to: position + 1)
                    }
                }
            }
        }
        .foregroundStyle(appearance.ink)
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .frame(minHeight: 48)
        .background(dragging ? Theme.inset : appearance.fill, in: shape)
        .overlay {
            shape.strokeBorder(dragging ? Theme.ai : appearance.stroke,
                               style: StrokeStyle(lineWidth: 1, dash: correction == nil ? [] : [4, 3]))
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(dragging ? 0.15 : 0), radius: 5, y: 3)
    }

    private func orderButton(_ direction: String, item: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "arrow.\(direction)")
                .font(Theme.body.weight(.medium))
                .foregroundStyle(Theme.quiet)
                .frame(width: 32, height: 32)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.border))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(disabled ? 0.35 : 1)
        .accessibilityLabel("Move \(item) \(direction)")
        .disabled(disabled)
    }

    private func gridInput(_ grid: SolveGrid, at field: Int, feedback: SolveFieldFeedback?) -> some View {
        let matching = grid.columns.count == 1 && grid.rowLabels != nil && grid.rows.allSatisfy { $0[0].kind == .option }
        return VStack(alignment: .leading, spacing: 8) {
            if matching, let labels = grid.rowLabels {
                matchingGrid(grid, labels: labels, at: field, feedback: feedback)
            } else {
                ViewThatFits(in: .horizontal) {
                    gridTable(grid, at: field, feedback: feedback)
                    ScrollView(.horizontal) {
                        gridTable(grid, at: field, feedback: feedback)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .defaultScrollAnchor(.leading)
                }
                if !isLocked, !grid.rowOrderMatters {
                    Text("Rows can be entered in any order.").font(Theme.small).foregroundStyle(Theme.quiet)
                }
                if isLocked, let feedback {
                    missingGridRows(grid, at: field, feedback: feedback)
                }
            }
        }
    }

    private func gridTable(_ grid: SolveGrid, at field: Int, feedback: SolveFieldFeedback?) -> some View {
        let wideFirstColumn = grid.columns.count > 1 && grid.rows.allSatisfy { $0[0].kind == .option }
        return Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                if grid.rowLabels != nil {
                    Color.clear.frame(width: 1, height: 1).accessibilityHidden(true)
                }
                ForEach(grid.columns.indices, id: \.self) { column in
                    let alignTrailing = grid.rows.allSatisfy { $0[column].kind == .number }
                    Text(grid.columns[column])
                        .font(Theme.small.weight(.semibold))
                        .foregroundStyle(Theme.quiet)
                        .frame(maxWidth: .infinity, alignment: alignTrailing ? .trailing : .leading)
                        .padding(.horizontal, alignTrailing ? 10 : 0)
                }
            }
            ForEach(grid.rows.indices, id: \.self) { row in
                GridRow(alignment: .top) {
                    if let label = grid.rowLabels?[safe: row] {
                        Text(label)
                            .font(.system(size: 14))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 150, alignment: .leading)
                            .padding(.top, 10)
                    }
                    ForEach(grid.columns.indices, id: \.self) { column in
                        let wide = wideFirstColumn && column == 0
                        gridCell(grid, at: field, row: row, column: column,
                                 feedback: feedback?.cells[safe: row]?[safe: column])
                            .frame(minWidth: wide ? 152 : 100, idealWidth: wide ? 210 : 132,
                                   maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private func matchingGrid(_ grid: SolveGrid, labels: [String], at field: Int,
                              feedback: SolveFieldFeedback?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(labels.indices, id: \.self) { row in
                if row > 0 { Divider().overlay(Theme.border) }
                let cell = feedback?.cells[safe: row]?[safe: 0]
                SolveMatchingRowLayout {
                    Text(labels[row])
                        .font(.system(size: 17))
                        .foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    gridCell(grid, at: field, row: row, column: 0, feedback: cell)
                }
                .padding(.vertical, 12)
            }
        }
    }

    private func gridCell(_ grid: SolveGrid, at field: Int, row: Int, column: Int,
                          feedback: SolveCellFeedback?) -> some View {
        let input = grid.rows[row][column]
        let rowLabel = grid.rowLabels?[safe: row] ?? "Row \(row + 1)"
        let label = "\(rowLabel), \(grid.columns[column])"
        let value = Binding(
            get: { gridValues(at: field)[safe: row]?[safe: column] ?? "" },
            set: { updateGrid($0, in: grid, field: field, row: row, column: column) }
        )
        let appearance = fieldAppearance(feedback?.status)
        let rowIsEmpty = gridValues(at: field)[safe: row]?.allSatisfy {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } == true
        return VStack(alignment: .leading, spacing: 4) {
            if input.kind == .option {
                gridPicker(value, options: attempt.options[field], input: input, label: label, appearance: appearance)
            } else {
                inputBox(value, input: input, label: label, location: .cell(field, row, column),
                         appearance: appearance, compact: true, alignTrailing: input.kind == .number)
                    .help(input.instructions)
                if !isLocked, let unit = input.unit, !grid.columns[column].contains(unit) {
                    Text(input.instructions).font(Theme.caption).foregroundStyle(Theme.quiet)
                }
            }
            if let feedback, let message = feedback.message,
               feedback.status == .invalid || isLocked && !rowIsEmpty {
                feedbackNote(message, status: feedback.status)
            }
            if isLocked, feedback?.status == .incorrect, let expected = feedback?.expected,
               !rowIsEmpty || grid.rowLabels != nil {
                expectedValue(expected)
            }
        }
    }

    private func updateGrid(_ text: String, in grid: SolveGrid, field: Int, row: Int, column: Int) {
        let current = gridValues(at: field)
        var rows = grid.rows.indices.map { row in
            grid.columns.indices.map { current[safe: row]?[safe: $0] ?? "" }
        }
        rows[row][column] = text
        update(.grid(rows), at: field)
    }

    @ViewBuilder private func gridPicker(
        _ value: Binding<String>, options: [String], input: SolveInput, label: String, appearance: FieldAppearance
    ) -> some View {
        let display = isShowingKey ? input.answers.first ?? "" : value.wrappedValue
        if isLocked {
            gridPickerLabel(display.isEmpty ? "—" : display, appearance: appearance)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(label)
                .accessibilityValue([display, appearance.summary].filter { !$0.isEmpty }.joined(separator: ", "))
        } else {
            SolveOptionPicker(selection: value, options: options, label: label) {
                gridPickerLabel(display.isEmpty ? "Choose…" : display, appearance: appearance)
            }
        }
    }

    private func gridPickerLabel(_ display: String, appearance: FieldAppearance) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8)
        return HStack(spacing: 6) {
            Text(display)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let symbol = isLocked ? appearance.symbol : "chevron.down" {
                Image(systemName: symbol).font(Theme.caption.weight(.semibold)).accessibilityHidden(true)
            }
        }
        .font(.system(size: 17, weight: .semibold))
        .foregroundStyle(appearance.ink)
        .padding(.horizontal, 15)
        .padding(.vertical, 10)
        .frame(minHeight: 46)
        .background(appearance.fill, in: shape)
        .overlay(shape.strokeBorder(appearance.stroke))
        .contentShape(shape)
    }

    private func missingGridRows(_ grid: SolveGrid, at field: Int, feedback: SolveFieldFeedback) -> some View {
        let missing = gridValues(at: field).indices.filter { row in
            gridValues(at: field)[row].allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
        return ForEach(missing, id: \.self) { row in
            let expected = feedback.cells[safe: row]?.enumerated().compactMap { column, cell in
                cell.expected.map { "\(grid.columns[column]) \($0)" }
            } ?? []
            if !expected.isEmpty {
                Text("Missing row: \(expected.joined(separator: " · "))")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.bad)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Theme.bad, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            }
        }
    }

    private func fieldAppearance(_ status: SolveFeedbackStatus?) -> FieldAppearance {
        if isShowingKey { return .key }
        if status == .invalid { return .invalid }
        if checkedResult == nil { return .plain }
        return status == .correct ? .correct : .incorrect
    }

    private func feedbackNote(_ message: String, status: SolveFeedbackStatus) -> some View {
        Text(message)
            .font(Theme.small)
            .foregroundStyle(status == .invalid ? Theme.amber : status == .incorrect ? Theme.bad : Theme.quiet)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.updatesFrequently)
    }

    private func expectedValue(_ expected: String) -> some View {
        Text("Expected: \(expected)")
            .font(Theme.small)
            .foregroundStyle(Theme.quiet)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    private func resultBanner(_ result: SolveCheckResult) -> some View {
        let invalid = result.hasInvalidInput
        let ink = invalid ? Theme.amber : result.isCorrect ? Theme.solveGreenInk : Theme.solveRedInk
        let fill = invalid ? Theme.amberWash : result.isCorrect ? Theme.goodWash : Theme.badWash
        let title = invalid ? "Fix the marked fields, then check again."
            : result.isCorrect ? "All answers match." : "Review the marked answers."
        return Text(title)
            .font(.system(size: 15.5, weight: .semibold))
            .foregroundStyle(ink)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(fill, in: RoundedRectangle(cornerRadius: 10))
            .accessibilityAddTraits(.updatesFrequently)
    }

    private var solution: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Worked solution").eyebrow()
            ChatMarkdownView(text: content.explanation, textSize: 14) { _ in }
        }
    }

    @ViewBuilder private var mistakeMessages: some View {
        let shown = Set(checkedResult?.fields.compactMap(\.message) ?? [])
        let messages = SolveChecker.varianceMistakeMessages(for: content).filter { !shown.contains($0) }
        if !messages.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Text("Mistake messages").eyebrow()
                ForEach(messages, id: \.self) { message in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").accessibilityHidden(true)
                        Text(message).fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.quiet)
                }
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Theme.border).frame(height: 1)
            HStack(spacing: 10) {
                if isLocked {
                    Spacer(minLength: 0)
                    Button("Try again", action: retry).buttonStyle(SecondaryButtonStyle())
                } else {
                    if canReveal {
                        Button(action: reveal) {
                            HStack(spacing: 6) {
                                Text("Show answer").font(Theme.body.weight(.semibold))
                                if usesKeyboardShortcuts {
                                    ShortcutKey(text: "Space").accessibilityHidden(true)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.quiet)
                    }
                    Spacer(minLength: 0)
                    Button(action: check) {
                        HStack(spacing: 7) {
                            Text("Check")
                            if usesKeyboardShortcuts {
                                Text("↩").font(Theme.caption.weight(.semibold))
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .overlay(RoundedRectangle(cornerRadius: 3)
                                        .strokeBorder(Theme.onSolveGreen.opacity(0.7)))
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                    .buttonStyle(SolveCheckButtonStyle())
                    .keyboardShortcut(usesKeyboardShortcuts ? KeyboardShortcut(.return, modifiers: []) : nil)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    private func focusFirstInput() {
        // Review Test starts with the card shortcuts available, including Space to reveal.
        guard usesKeyboardShortcuts, !canReveal, !isLocked, isEnabled else { return }
        for (index, field) in content.fields.enumerated() {
            if field.input != nil {
                focusedInput = .field(index)
                return
            }
            if let grid = field.grid {
                for (row, inputs) in grid.rows.enumerated() {
                    if let column = inputs.firstIndex(where: { $0.kind != .option }) {
                        focusedInput = .cell(index, row, column)
                        return
                    }
                }
            }
        }
    }

    private func check() {
        guard !isLocked, isEnabled else { return }
        let result = SolveChecker.check(content, answers: attempt.answers)
        attempt.result = result
        guard !result.hasInvalidInput else { return }
        focusedInput = nil
        onCheck(attempt.answers)
    }

    private func reveal() {
        guard !isLocked, isEnabled else { return }
        focusedInput = nil
        attempt.result = nil
        attempt.revealedKey = true
        onReveal()
    }

    private func retry() {
        attempt = Attempt(content: content)
        focusFirstInput()
    }

    private func update(_ answer: SolveAnswer, at index: Int) {
        guard !isLocked, isEnabled, attempt.answers[index] != answer else { return }
        attempt.answers[index] = answer
        attempt.result = nil
    }

    private func orderItems(at index: Int) -> [String] {
        guard case .order(let items) = attempt.answers[index] else { return [] }
        return items
    }

    private func moveOrder(in field: Int, from: Int, to: Int) {
        var items = orderItems(at: field)
        guard items.indices.contains(from), items.indices.contains(to), from != to else { return }
        items.insert(items.remove(at: from), at: to)
        update(.order(items), at: field)
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

        init(content: SolveCaseContent, answers: [SolveAnswer]? = nil, shuffle: Bool = true) {
            options = content.fields.map { field in
                if let choice = field.choice {
                    let labels = choice.options.map(\.label)
                    return shuffle && choice.shuffle ? labels.shuffled() : labels
                }
                if let grid = field.grid { return shuffle && grid.shuffle ? grid.options.shuffled() : grid.options }
                return []
            }
            self.answers = content.fields.enumerated().map { index, field in
                if let answer = answers?[safe: index] { return answer }
                if field.choice != nil { return .choice([], none: false) }
                if let order = field.order {
                    return .order(shuffle ? order.shuffledIncorrectly() ?? order.items : order.items)
                }
                if let grid = field.grid {
                    return .grid(grid.rows.map { $0.map { _ in "" } })
                }
                return .text("")
            }
            result = answers.map { SolveChecker.check(content, answers: $0) }
        }
    }
}

private struct SolveCheckButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13.5, weight: .semibold))
            .foregroundStyle(Theme.onSolveGreen)
            .padding(.horizontal, 14)
            .frame(height: 38)
            .background(Theme.solveGreen, in: RoundedRectangle(cornerRadius: 9))
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.4)
    }
}

private enum FieldAppearance {
    case plain, selected, key, correct, incorrect, invalid, missed, quiet

    var stroke: Color {
        switch self {
        case .plain: Theme.borderStrong
        case .selected: Theme.ink
        case .key, .correct: Theme.solveGreen
        case .incorrect, .missed: Theme.bad
        case .invalid: Theme.amber
        case .quiet: Theme.border
        }
    }

    var fill: Color {
        switch self {
        case .correct: Theme.goodWash
        case .incorrect: Theme.badWash
        case .invalid: Theme.amberWash
        default: Theme.surface
        }
    }

    var ink: Color {
        switch self {
        case .key, .correct: Theme.solveGreenInk
        case .incorrect, .missed: Theme.solveRedInk
        case .invalid: Theme.amber
        case .quiet: Theme.quiet
        default: Theme.ink
        }
    }

    var symbol: String? {
        switch self {
        case .key, .correct: "checkmark"
        case .incorrect: "xmark"
        case .invalid, .missed: "exclamationmark.circle"
        default: nil
        }
    }

    var summary: String {
        switch self {
        case .key: "Answer key"
        case .correct: "Correct"
        case .incorrect: "Incorrect"
        case .invalid: "Invalid"
        case .missed: "Missed"
        default: ""
        }
    }
}

private struct SolveClozeLayout: Layout {
    private let spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = layoutRows(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: rows.map(\.width).max() ?? 0,
                      height: rows.reduce(0) { $0 + $1.height } + CGFloat(max(0, rows.count - 1)) * spacing)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in layoutRows(subviews, width: bounds.width) {
            var x = bounds.minX
            for (index, size) in row.cells {
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                                      anchor: .topLeading, proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func layoutRows(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let ideal = subviews[index].sizeThatFits(.unspecified)
            let size = ideal.width <= width ? ideal
                : subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil))
            let gap = row.cells.isEmpty ? 0 : spacing
            if gap > 0 && row.width + gap + size.width > width {
                rows.append(row)
                row = Row()
            }
            row.width += (row.cells.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.cells.append((index, size))
        }
        if !row.cells.isEmpty { rows.append(row) }
        return rows
    }

    private struct Row {
        var cells: [(Int, CGSize)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
