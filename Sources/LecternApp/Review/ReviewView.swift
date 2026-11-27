import AppKit
import LecternCore
import SwiftUI

struct ReviewView: View {
    @Bindable var model: LectureWindowModel
    var focus: FocusState<EditorField?>.Binding

    var body: some View {
        VStack(spacing: 0) {
            header
            LecturePanes(model: model) {
                CardList(model: model)
            } stage: {
                GeometryReader { geometry in
                    ScrollView {
                        reviewStage
                            .frame(maxWidth: 640)
                            .padding(.horizontal, min(40, max(12, geometry.size.width * 0.04)))
                            .padding(.vertical, 24)
                            .frame(maxWidth: .infinity)
                    }
                }
                .background(Theme.canvas)
            } right: {
                LectureSidebar(model: model, focus: focus)
            }
        }
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                reviewTitle.fixedSize()
                Spacer(minLength: 0)
                modeDescription.fixedSize()
            }
            VStack(alignment: .leading, spacing: 4) { reviewTitle; modeDescription }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .background(Theme.inset)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private var reviewTitle: some View {
        Text("Review · \(model.moduleName) · \(model.lecture.name)")
            .font(Theme.heading(16))
            .tracking(-0.3)
            .lineLimit(1)
            .accessibilityAddTraits(.isHeader)
    }

    private var modeDescription: some View {
        Text(model.selectedCard?.solve == nil
             ? (model.testMode ? "Test hides the answer until you reveal it" : "Browse shows both sides of the card")
             : (model.testMode ? "Test hides the answer key until you check" : "Browse shows the generated example solved"))
            .font(.system(size: 13))
            .foregroundStyle(Theme.quiet)
    }

    private var reviewStage: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                if model.selectedCard != nil { CardPager(model: model) }
                Spacer()
                modePicker
            }
            if let card = model.selectedCard {
                if let solve = card.solve {
                    SolveCardDetail(model: model, card: card, solve: solve)
                        .id(card.id)
                } else {
                    CardDetail(model: model, card: card, focus: focus)
                }
            } else { emptyState }
        }
    }

    private var modePicker: some View {
        HStack(spacing: 0) {
            reviewModeButton("Browse", test: false)
            reviewModeButton("Test", test: true)
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.borderStrong))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Review mode")
        .help("T switches Browse / Test")
    }

    private func reviewModeButton(_ title: String, test: Bool) -> some View {
        let selected = model.testMode == test
        return Button { model.setTestMode(test) } label: {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(selected ? Theme.canvas : Theme.quiet)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(selected ? Theme.ink : .clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.activeCards.isEmpty {
                Text("No cards yet").font(Theme.heading(22))
                Text(model.lecture.pageCount > 0
                     ? "Select slides and note what matters in Prepare, then Generate. New cards land here as Unreviewed."
                     : "This lecture has no cards.")
                    .font(Theme.body).foregroundStyle(Theme.quiet)
                if model.lecture.pageCount > 0 {
                    Button("Go to Prepare") { model.setMode(.prepare) }.buttonStyle(PrimaryButtonStyle())
                }
            } else if model.testMode && model.reviewFilter == .unreviewed && model.count(for: .unreviewed) == 0 {
                Text("Every card is tested").font(Theme.heading(22))
                Text("\(Format.count(model.count(for: .good), "Good card")) ready for Anki. Bad cards stay here.")
                    .font(Theme.body).foregroundStyle(Theme.quiet)
                HStack(spacing: 10) {
                    Button("Export to Anki") {
                        Task { await model.app.returnToLibrary(destination: .export(model.ref.moduleID, lectureID: model.ref.lectureID)) }
                    }.buttonStyle(PrimaryButtonStyle())
                    Button("Show all cards") { model.setReviewFilter(.all) }.buttonStyle(SecondaryButtonStyle())
                }
            } else {
                Text("Nothing in this filter").font(Theme.heading(22))
                if model.reviewSearch.isEmpty {
                    Button("Show all cards") { model.setReviewFilter(.all) }.buttonStyle(SecondaryButtonStyle())
                } else {
                    Button("Clear search") { model.reviewSearch = ""; model.setReviewFilter(model.reviewFilter) }
                        .buttonStyle(SecondaryButtonStyle())
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Card list

private struct CardList: View {
    @Bindable var model: LectureWindowModel

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.faint)
                    TextField("Search cards", text: $model.reviewSearch).textFieldStyle(.plain).font(.system(size: 13))
                        .accessibilityLabel("Search cards")
                        .onChange(of: model.reviewSearch) { _, _ in model.setReviewFilter(model.reviewFilter) }
                }
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.border))
                SegmentedControl(options: [(ReviewFilter.all, "All"), (ReviewFilter.unreviewed, "To Review")],
                                 selection: Binding(get: { model.reviewFilter }, set: { model.setReviewFilter($0) }),
                                 activeFill: Theme.inset, activeText: Theme.ink)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 12)
            Rectangle().fill(Theme.border).frame(height: 1)
            let numbers = model.cardNumbers
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(model.visibleCards) { card in
                            Button { model.selectCard(card.id) } label: {
                                CardRow(card: card, number: numbers[card.id] ?? 0, issues: !model.lecture.issues(for: card).isEmpty,
                                        revising: model.runningJobs.contains { $0.kind == .revise && $0.targetCardID == card.id },
                                        selected: card.id == model.selectedCardID)
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(card.id == model.selectedCardID ? .isSelected : [])
                            .accessibilityLabel("Card \(numbers[card.id] ?? 0), \(card.front), \(card.verdict.v2Title)")
                            .accessibilityHint(card.solve == nil ? "" : "Solve card")
                            .id(card.id)
                        }
                    }
                    .padding(6)
                }
                .onChange(of: model.selectedCardID) { _, id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id) }
                }
            }
        }
        .background(Theme.inset)
    }
}

private struct CardRow: View {
    let card: Card
    let number: Int
    let issues: Bool
    let revising: Bool
    let selected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text("\(number)").font(Theme.caption).monospacedDigit().foregroundStyle(Theme.quiet).frame(width: 20, alignment: .leading)
            HStack(spacing: 5) {
                if card.solve != nil {
                    Text("solve")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.ai)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Theme.aiWash, in: RoundedRectangle(cornerRadius: 4))
                }
                Text(card.front.isEmpty ? "Empty front" : card.front)
                    .font(.system(size: 12.5))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            tag
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .background(selected ? Theme.surface : .clear, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(selected ? Theme.ai : .clear, lineWidth: 1.5))
        .contentShape(Rectangle())
    }

    private var tag: some View {
        HStack(spacing: 5) {
            if card.proposal != nil || card.flag != nil { Image(systemName: "sparkles").font(.system(size: 11)).foregroundStyle(Theme.ai) }
            if revising { ProgressView().controlSize(.mini) }
            else { Circle().fill(issues ? Theme.bad : verdictColor).frame(width: 7, height: 7) }
        }
        .accessibilityLabel(card.verdict.v2Title)
    }

    private var verdictColor: Color {
        switch card.verdict {
        case .good: Theme.solveGreen
        case .bad: Theme.bad
        default: Theme.borderStrong
        }
    }
}

private struct SolveCardDetail: View {
    @Bindable var model: LectureWindowModel
    let card: Card
    let solve: SolveCard

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 0) {
                if let sample = solve.draft.sample.checkedContent {
                    SolveExerciseView(
                        content: sample, mode: model.testMode ? .attempt : .browse, canReveal: model.testMode,
                        showAnswerKey: model.testMode && !model.answerHidden, showsMistakeMessages: true,
                        onReveal: model.revealAnswer, onCheck: { _ in model.revealAnswer() }
                    )
                    .id(model.testMode)
                    .id(card.currentRevisionID)
                } else {
                    Text("This exercise needs a valid answer key.")
                        .foregroundStyle(Theme.bad)
                        .padding(.horizontal, 26).padding(.vertical, 20)
                    if model.answerHidden { VerdictBar(model: model) }
                }
                if !model.answerHidden {
                    if let flag = card.flag {
                        Label(flag, systemImage: "sparkles").font(Theme.small).foregroundStyle(Theme.ai)
                            .padding(.horizontal, 26).padding(.bottom, 14)
                    }
                    let issues = model.lecture.issues(for: card)
                    if !issues.isEmpty {
                        ReviewIssues(model: model, card: card, issues: issues)
                            .padding(.horizontal, 26).padding(.bottom, 14)
                    }
                    Rectangle().fill(Theme.border).frame(height: 1)
                    variation.padding(.horizontal, 26).padding(.vertical, 20)
                    VerdictBar(model: model, wholeCard: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border).allowsHitTesting(false))
            hints
            if !model.answerHidden, let proposal = card.proposal {
                ProposalCard(model: model, card: card, proposal: proposal)
            }
        }
    }

    private var variation: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What changes between versions")
                .font(.system(size: 11.5, weight: .semibold))
                .tracking(0.2)
                .foregroundStyle(Theme.quiet)
            Text(answerFormat).foregroundStyle(Theme.quiet)
            if solve.draft.reusesSample {
                Text("The starting order is shuffled each time.")
                stableVariation("The items and their accepted order.")
            } else {
                Text(solve.draft.variation)
                stableVariation(solve.draft.skill)
            }
        }
        .font(.system(size: 14))
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Theme.inset, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
    }

    private var answerFormat: String {
        let descriptions = solve.draft.sample.fields.compactMap { field -> String? in
            if let input = field.input {
                let name = input.kind.rawValue.capitalized
                let details = input.acceptedFormats.map(\.label).joined(separator: " / ")
                return details.isEmpty ? name : "\(name): \(details)"
            }
            if let choice = field.choice { return choice.multiple ? "Choice: select all that apply" : "Choice: select one" }
            if field.order != nil { return "Order: put the items in sequence" }
            if let grid = field.grid { return "Grid: \(grid.columns.joined(separator: " · "))" }
            return nil
        }
        var seen = Set<String>()
        return descriptions.filter { seen.insert($0).inserted }.joined(separator: " · ")
    }

    private func stableVariation(_ description: String) -> some View {
        Text("\(Text("Stays the same:").fontWeight(.semibold).foregroundStyle(Theme.ink)) \(description)")
            .foregroundStyle(Theme.quiet)
    }

    private var hints: some View {
        let left = model.answerHidden ? ["Answer it like in Study", "↩ check"] : ["← → move", "T Browse / Test"]
        let right = model.answerHidden ? ["Space show answer", "← → skip"] : ["Source slides and Ask AI live in the sidebar"]
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) { hintLabels(left + right) }.fixedSize()
            VStack(spacing: 6) {
                HStack(spacing: 14) { hintLabels(left) }
                HStack(spacing: 14) { hintLabels(right) }
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.faint)
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }

    private func hintLabels(_ labels: [String]) -> some View {
        ForEach(labels, id: \.self) { Text($0) }
    }
}

private struct SolveReviewTools: View {
    let model: LectureWindowModel
    let card: Card
    let solve: SolveCard
    @State private var showRequest = false
    @State private var caseToRemove: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button("Request solve card change…") { showRequest = true }
                .buttonStyle(LinkButtonStyle(color: Theme.ai))
                .disabled(model.readOnly || card.proposal?.state == .pending)
            if card.verdict == .good && !solve.draft.reusesSample { casePool }
        }
        .sheet(isPresented: $showRequest) {
            SolveRevisionRequest(addsCard: false) { feedback in
                Task { await model.requestSolveRevision(feedback) }
            }
        }
        .alert("Remove this case?", isPresented: Binding(
            get: { caseToRemove != nil }, set: { if !$0 { caseToRemove = nil } }
        ), presenting: caseToRemove) { id in
            Button("Remove case", role: .destructive) { Task { await model.retireSolveCase(id) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The card and its review history stay in Study.")
        }
    }

    private var casePool: some View {
        let activeCases = solve.activeCases
        let seen = model.app.studyCatalog.decks.first { $0.id == model.ref.moduleID }?.seenSolveCases[card.id] ?? []
        let readyCount = activeCases.count { !seen.contains($0.id) && $0.content.checkedContent != nil }
        return DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                if readyCount == 0 {
                    Text("No verified cases are ready.").font(Theme.body).foregroundStyle(Theme.quiet)
                }
                ForEach(Array(solve.cases.enumerated()), id: \.element.id) { index, exercise in
                    if !exercise.retired {
                        SolvePoolCase(exercise: exercise, number: index + 1, seen: seen.contains(exercise.id),
                                      readOnly: model.readOnly) {
                            caseToRemove = exercise.id
                        }
                    }
                }
                if let error = model.solveRefillError {
                    Text(error).font(Theme.small).foregroundStyle(Theme.bad)
                }
                if model.isRefillingSolveCases {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Preparing more cases…").font(Theme.small).foregroundStyle(Theme.quiet)
                    }
                } else if readyCount < SolveCard.poolTarget && !model.readOnly {
                    Button(model.solveRefillError == nil ? "Prepare more cases" : "Retry preparing cases") {
                        model.refillSolveCases()
                    }
                        .buttonStyle(LinkButtonStyle())
                }
            }
            .padding(.top, 10)
        } label: {
            HStack(spacing: 8) {
                Text("Verified cases").font(Theme.body.weight(.semibold))
                Text("\(readyCount) ready").font(Theme.small).foregroundStyle(Theme.quiet)
                if model.isRefillingSolveCases { ProgressView().controlSize(.mini) }
            }
        }
        .panel(padding: 12)
    }
}

private struct SolveRevisionRequest: View {
    let addsCard: Bool
    let submit: (String) -> Void
    @State private var request = ""
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let feedback = request.trimmingCharacters(in: .whitespacesAndNewlines)
        VStack(alignment: .leading, spacing: 12) {
            Text(addsCard ? "Add a solve card" : "Request a change").font(Theme.heading(20))
            Text(addsCard ? "Lectern will draft a practice case based on this flip card."
                 : "What should change about this exercise?").font(Theme.body).foregroundStyle(Theme.quiet)
            TextField(addsCard ? "What should it practice? (optional)" : "Describe the change",
                      text: $request, axis: .vertical)
                .focused($focused)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...6)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(addsCard ? "Request solve card" : "Request change") {
                    dismiss()
                    submit(addsCard ? "Add a separate solve card that applies this rule. \(feedback)" : feedback)
                }
                .buttonStyle(PrimaryButtonStyle(tint: Theme.ai))
                .disabled(!addsCard && feedback.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 420)
        .onAppear { focused = true }
    }
}

private struct SolvePoolCase: View {
    let exercise: SolveCase
    let number: Int
    let seen: Bool
    let readOnly: Bool
    let remove: () -> Void
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            if expanded {
                VStack(alignment: .leading, spacing: 12) {
                    SolveExerciseView(content: exercise.content, canReveal: true, canRetry: true, usesKeyboardShortcuts: false)
                    Button("Remove case", action: remove).buttonStyle(LinkButtonStyle(color: Theme.bad))
                        .disabled(readOnly)
                }
                .padding(.top, 8)
            }
        } label: {
            HStack(spacing: 6) {
                Text("Case \(number)").font(Theme.body)
                if seen { Text("Seen").font(Theme.caption).foregroundStyle(Theme.quiet) }
            }
        }
    }
}

// MARK: - Card detail

private struct CardDetail: View {
    @Bindable var model: LectureWindowModel
    let card: Card
    var focus: FocusState<EditorField?>.Binding
    @State private var editingSide: EditorField?
    @State private var showSolveRequest = false

    var body: some View {
        let issues = model.lecture.issues(for: card)
        // Test mode: everything that gives the answer away waits for Space.
        let hidden = model.answerHidden
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                if !hidden, let flag = card.flag {
                    VStack(alignment: .leading, spacing: 10) {
                        Label { Text("**AI flagged this card.** \(flag)") } icon: { Image(systemName: "sparkles") }
                            .font(Theme.body).foregroundStyle(Theme.ai)
                        HStack(spacing: 20) {
                            Button("Fix it with AI") { model.fixFlagWithClaude(cardID: card.id); focus.wrappedValue = .ask }
                                .buttonStyle(LinkButtonStyle(color: Theme.ai))
                                .disabled(model.isShowingAskActivity)
                            Button("Dismiss") { model.dismissFlag(cardID: card.id) }
                                .buttonStyle(LinkButtonStyle(color: Theme.quiet))
                        }.disabled(model.readOnly)
                    }
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.aiWash, in: RoundedRectangle(cornerRadius: 10)).padding(16)
                }
                if !hidden, !issues.isEmpty { ReviewIssues(model: model, card: card, issues: issues).padding(12) }
                side("Front", text: $model.editorFront, field: .front, size: 24)
                Rectangle().fill(Theme.border).frame(height: 1)
                if hidden { answerPrompt } else { answer }
                VerdictBar(model: model)
            }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            if !model.testMode, card.proposal == nil, !model.readOnly {
                Button("Add solve card…") { showSolveRequest = true }
                    .buttonStyle(LinkButtonStyle(color: Theme.ai))
            }
            if !hidden { MathChoices(model: model, card: card) }
            hints(hidden: hidden)
            if !hidden { history }
        }
        .onChange(of: card.id) { _, _ in editingSide = nil }
        .onChange(of: hidden) { _, hidden in
            if hidden && editingSide == .back { editingSide = nil }
        }
        .onChange(of: editingSide) { old, _ in
            if old != nil { Task { await model.run { try await model.session.flushEdits() } } }
        }
        .sheet(isPresented: $showSolveRequest) {
            SolveRevisionRequest(addsCard: true) { feedback in
                Task { await model.requestSolveRevision(feedback) }
            }
        }
    }

    /// Stands in for the back until Space. Clicking it reveals too; the button sits in the verdict bar.
    private var answerPrompt: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Back").eyebrow()
            Text("Answer it in your head first.")
                .font(.system(size: 19)).foregroundStyle(Theme.faint)
                .padding(.vertical, 4)
        }
        .padding(.horizontal, 26).padding(.vertical, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { model.revealAnswer() }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Show answer")
        .accessibilityAction { model.revealAnswer() }
    }

    @ViewBuilder private var answer: some View {
        side("Back", text: $model.editorBack, field: .back, size: 19)
            .transition(.opacity)
        if model.runningJobs.contains(where: { $0.kind == .revise && $0.targetCardID == card.id }) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Revising in the background…").font(Theme.small).foregroundStyle(Theme.ai)
            }.padding(16)
        }
        if let proposal = card.proposal { ProposalCard(model: model, card: card, proposal: proposal).padding(16) }
    }

    private func hints(hidden: Bool) -> some View {
        HStack(spacing: 12) {
            if hidden {
                Text("Space show answer").font(Theme.caption)
                Text("← → skip").font(Theme.caption)
            } else {
                Text("← → move").font(Theme.caption)
                Button("U undo") { Task { await model.undo() } }.buttonStyle(.plain).disabled(!model.session.canUndo || model.readOnly)
                Text(model.testMode ? "Rate the card, not your memory" : "Click text to edit").font(Theme.caption)
            }
        }.font(Theme.small).foregroundStyle(Theme.faint).frame(maxWidth: .infinity)
    }

    private func side(_ title: String, text: Binding<String>, field: EditorField, size: CGFloat) -> some View {
        let editing = editingSide == field && !model.readOnly
        let emphasized = field == .front
        let content = RenderedCardText(text: text.wrappedValue, size: size, emphasized: emphasized)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).eyebrow()
                if editing {
                    Spacer()
                    Button("Done") { editingSide = nil }
                        .buttonStyle(LinkButtonStyle())
                }
            }
            if editing {
                CardSourceEditor(
                    text: Binding(get: { text.wrappedValue }, set: {
                        text.wrappedValue = $0
                        model.editorChanged()
                    }),
                    label: title, size: size, emphasized: emphasized
                ) {
                    if editingSide == field { editingSide = nil }
                }
                .id(card.id)
            } else if model.readOnly {
                content
            } else {
                Button { editingSide = field } label: {
                    content
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Edit \(title.lowercased())"))
                .accessibilityValue(Text(verbatim: text.wrappedValue))
            }
        }
        .padding(.horizontal, 26).padding(.vertical, 20)
    }

    @ViewBuilder private var history: some View {
        if card.history.count > 1 {
            HStack(spacing: 10) {
                Text("\(Format.count(card.history.count - 1, "revision")) since the original").font(Theme.caption).foregroundStyle(Theme.quiet)
                Button("Restore original") { Task { await model.restoreOriginal() } }
                    .buttonStyle(LinkButtonStyle(color: Theme.quiet)).disabled(model.readOnly)
                if model.session.canUndo {
                    Button("Undo  U") { Task { await model.undo() } }.buttonStyle(LinkButtonStyle(color: Theme.quiet)).disabled(model.readOnly)
                }
            }
        }
    }
}

private struct ReviewIssues: View {
    let model: LectureWindowModel
    let card: Card
    let issues: [CardIssue]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(Theme.bad)
                    Text(issue.message).font(Theme.small)
                    Spacer()
                    if issue.kind == .importSyntax {
                        Button("Mark as fixed") { Task { await model.dispatch(.resolveIssue(cardID: card.id)) } }
                            .buttonStyle(LinkButtonStyle()).disabled(model.readOnly)
                    }
                }
            }
            Text("Approval is blocked until these are fixed.").font(Theme.caption).foregroundStyle(Theme.quiet)
        }
        .padding(10)
        .background(Theme.badWash, in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Ambiguous math

private struct MathChoices: View {
    let model: LectureWindowModel
    let card: Card

    var body: some View {
        let spans = (FlashcardMathAnalyzer.analyze(card.front) + FlashcardMathAnalyzer.analyze(card.back)).filter(\.requiresChoice)
        let unique = spans.reduce(into: [MathSourceSpan]()) { result, span in
            if !result.contains(where: { $0.source == span.source }) { result.append(span) }
        }
        if !unique.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Ambiguous math").font(.system(size: 13, weight: .semibold))
                Text("Anki needs to know whether these dollar signs are math or plain text.").font(Theme.small).foregroundStyle(Theme.quiet)
                ForEach(unique, id: \.source) { span in
                    HStack {
                        Text(span.source).font(.system(size: 12, design: .monospaced)).lineLimit(1)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Theme.inset, in: RoundedRectangle(cornerRadius: 4))
                        Spacer()
                        SegmentedControl(options: [(MathInterpretation?.some(.treatAsMath), "Math"), (MathInterpretation?.some(.keepAsText), "Text")],
                                         selection: Binding(get: { card.mathInterpretations[span.source] },
                                                            set: { value in
                                                                guard let value else { return }
                                                                Task { await model.dispatch(.setMathInterpretation(cardID: card.id, span: span.source, value)) }
                                                            }),
                                         activeFill: Theme.ai)
                            .disabled(model.readOnly)
                    }
                }
            }
            .padding(14)
            .background(Theme.amberWash, in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

// MARK: - Proposal

private struct ProposalCard: View {
    let model: LectureWindowModel
    let card: Card
    let proposal: Proposal

    private var addsSolveCard: Bool {
        card.solve == nil && proposal.cards.count == 1 && proposal.cards[0].solve != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(proposal.cards.count > 1 ? "Proposed change · split into \(proposal.cards.count) cards" : "Proposed change")
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.aiStrong)
                Spacer()

            }
            if card.proposalIsStale {
                Label("You edited this card after asking. The diff compares with your current text.", systemImage: "clock.arrow.circlepath")
                    .font(Theme.small).foregroundStyle(Theme.amber)
            }
            switch proposal.state {
            case .pending:
                HStack { ProgressView().controlSize(.small); Text("Waiting for AI…").font(Theme.small) }
            case .failed:
                Text("This proposal failed. Discard it to request the change again.").font(Theme.small).foregroundStyle(Theme.bad)
            case .ready:
                if proposal.cards.count == 1, let draft = proposal.cards.first {
                    if let solve = draft.solve {
                        SolveExerciseView(content: solve.sample, mode: .browse, showsMistakeMessages: true)
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
                            .id(proposal.id)
                        Text(solve.skill).font(Theme.heading(16, weight: .semibold))
                        Text(solve.reason).font(Theme.body)
                        if !solve.reusesSample {
                            Text(solve.variation).font(Theme.small).foregroundStyle(Theme.quiet)
                        }
                    } else {
                        if draft.front != card.front { DiffText(label: "Front", before: card.front, after: draft.front) }
                        if draft.back != card.back { DiffText(label: "Back", before: card.back, after: draft.back) }
                        if draft.front == card.front && draft.back == card.back {
                            Text("Text unchanged\(draft.sourcePages != card.sourcePages ? "; sources become \(Format.slides(draft.sourcePages))" : "").")
                                .font(Theme.small).foregroundStyle(Theme.quiet)
                        }
                    }
                } else {
                    ForEach(Array(proposal.cards.enumerated()), id: \.offset) { index, draft in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("New card \(index + 1) · \(Format.slides(draft.sourcePages))").eyebrow()
                            Text(draft.front).font(.system(size: 14, weight: .medium))
                            Text(draft.back).font(Theme.body).foregroundStyle(Theme.quiet)
                        }
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                    }
                    Text("Accepting replaces this card with the new ones, each Unreviewed.").font(Theme.caption).foregroundStyle(Theme.quiet)
                }
            }
            if !proposal.rationale.isEmpty {
                Text(proposal.rationale).font(Theme.small).foregroundStyle(Theme.quiet)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { proposalActions }
                VStack(alignment: .leading, spacing: 8) { proposalActions }
            }
            .disabled(model.readOnly || proposal.state == .pending)
        }
        .padding(18)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.ai, lineWidth: 1))
    }

    @ViewBuilder private var proposalActions: some View {
        if proposal.state == .ready {
            Button(addsSolveCard ? "Add solve card" : "Accept ↩") { Task { await model.acceptProposal(approve: false) } }
                .buttonStyle(PrimaryButtonStyle())
        }
        if proposal.state == .ready, proposal.cards.count == 1, proposal.cards.first?.solve == nil, card.solve == nil {
            Button("Accept and mark Good") { Task { await model.acceptProposal(approve: true) } }
                .buttonStyle(SecondaryButtonStyle())
        }
        Button("Discard") { Task { await model.discardProposal() } }
            .buttonStyle(.plain).font(Theme.body).foregroundStyle(Theme.quiet)
    }

    private var subtitle: String {
        guard let draft = proposal.cards.first, proposal.cards.count == 1 else { return "Compared with your current text" }
        if draft.front == card.front { return "Compared with your current text · front unchanged" }
        if draft.back == card.back { return "Compared with your current text · back unchanged" }
        return "Compared with your current text"
    }
}

/// Word diff against the current text: removed struck through in orange, added underlined in blue.
struct DiffText: View {
    let label: String
    let before: String
    let after: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).eyebrow()
            if survivingFraction < 0.45 {
                Text(before).strikethrough().foregroundStyle(Theme.diffRemovedText).textSelection(.enabled)
                Text(after).foregroundStyle(Theme.diffAddedText).textSelection(.enabled)
            } else { Text(attributed).textSelection(.enabled) }
        }.font(.system(size: 14)).lineSpacing(4)
    }

    private var survivingFraction: Double {
        let tokens = WordDiff.compare(before, after)
        let total = tokens.filter { $0.kind != .inserted }.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
        let surviving = tokens.filter { $0.kind == .unchanged }.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
        return total == 0 ? 0 : Double(surviving) / Double(total)
    }

    private var attributed: AttributedString {
        var result = AttributedString()
        var previousCharacter: Character?
        for token in WordDiff.compare(before, after) {
            // LCS shares whitespace between replacements; separate adjacent old/new words visually.
            if previousCharacter?.isWhitespace == false, token.text.first?.isWhitespace == false {
                result.append(AttributedString(" "))
            }
            var piece = AttributedString(token.text)
            switch token.kind {
            case .unchanged: break
            case .removed:
                piece.foregroundColor = Theme.diffRemovedText
                piece.backgroundColor = Theme.diffRemovedWash
                piece.strikethroughStyle = Text.LineStyle.single
            case .inserted:
                piece.foregroundColor = Theme.diffAddedText
                piece.backgroundColor = Theme.diffAddedWash
                piece.underlineStyle = Text.LineStyle.single
            }
            result.append(piece)
            previousCharacter = token.text.last
        }
        return result
    }
}

// MARK: - Source slides

struct ReviewSourcePane: View {
    let model: LectureWindowModel
    @State private var scrollerStyle = NSScroller.preferredScrollerStyle

    var body: some View {
        GeometryReader { viewport in
            // A legacy scroller takes up width only on overflow. Reserve that width
            // so resizing a tall slide cannot make the scroller toggle repeatedly.
            let gutter = scrollerStyle == .legacy
                ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: scrollerStyle)
                : 0

            ScrollView {
                Group {
                    if let card = model.selectedCard {
                        if model.answerHidden {
                            Text("Show the answer to see its source slides.").foregroundStyle(Theme.quiet)
                        } else {
                            ReviewSourceSection(model: model, card: card)
                        }
                    } else {
                        Text("Select a card to see its source slides.").foregroundStyle(Theme.quiet)
                    }
                }
                .font(Theme.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .frame(width: max(0, viewport.size.width - gutter), alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSScroller.preferredScrollerStyleDidChangeNotification)) { _ in
            scrollerStyle = NSScroller.preferredScrollerStyle
        }
    }
}

private struct ReviewSourceSection: View {
    @Bindable var model: LectureWindowModel
    let card: Card
    @State private var showSourcePicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            sourceActions
            if card.sourcePages.isEmpty {
                Text("No source slides linked to this card.").foregroundStyle(Theme.quiet)
            } else {
                let index = min(model.sourceIndex, card.sourcePages.count - 1)
                let page = card.sourcePages[index]
                if page > 0, page <= model.lecture.pageCount {
                    let url = model.app.store.sourceURL(moduleID: model.ref.moduleID, lectureID: model.ref.lectureID)
                    SlideImage(sourceURL: url, pageIndex: page - 1, width: 900)
                        .onTapGesture { model.enlargedPage = page }
                    HStack {
                        Text("Slide \(page)")
                        Spacer()
                        Button("Enlarge") { model.enlargedPage = page }.buttonStyle(LinkButtonStyle(color: Theme.quiet))
                        Button("Prepare") { model.jumpToPrepare(page: page) }.buttonStyle(LinkButtonStyle(color: Theme.quiet))
                    }
                    let note = model.noteText(for: page - 1)
                    if !note.isEmpty { Text(note).foregroundStyle(Theme.quiet) }
                } else {
                    Text("This source slide is unavailable. Choose Edit source slides to update its number.").foregroundStyle(Theme.bad)
                }
                if card.sourcePages.count > 1 {
                    HStack {
                        Button { model.sourceIndex = (index - 1 + card.sourcePages.count) % card.sourcePages.count } label: { Image(systemName: "chevron.left") }
                            .accessibilityLabel("Previous source slide")
                        Text("\(index + 1) of \(card.sourcePages.count) sources · S cycles").font(Theme.caption).foregroundStyle(Theme.faint)
                        Button { model.sourceIndex = (index + 1) % card.sourcePages.count } label: { Image(systemName: "chevron.right") }
                            .accessibilityLabel("Next source slide")
                    }.buttonStyle(.plain)
                }
            }
            if let solve = card.solve {
                Rectangle().fill(Theme.border).frame(height: 1)
                SolveReviewTools(model: model, card: card, solve: solve)
                    .id(card.id)
            }
        }
    }

    private var sourceActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button("Edit source slides") { showSourcePicker = true }
                .buttonStyle(LinkButtonStyle(color: Theme.quiet))
                .disabled(model.readOnly)
                .popover(isPresented: $showSourcePicker) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Source slides").fontWeight(.semibold)
                        TextField("e.g. 1, 2", text: $model.editorSources)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Source slide numbers")
                            .onChange(of: model.editorSources) { _, _ in model.editorChanged() }
                        Button("Done") { showSourcePicker = false }
                            .buttonStyle(PrimaryButtonStyle())
                    }
                    .padding(16).frame(width: 220)
                    .onDisappear { Task { await model.run { try await model.session.flushEdits() } } }
                }
            if let point = card.learningPointID.flatMap({ id in model.lecture.learningPoints.first { $0.id == id } }) {
                if model.canShowChat(for: point) {
                    Button { model.showChat(for: point) } label: {
                        Label("From your chat", systemImage: "bubble.left.and.text.bubble.right")
                    }
                    .buttonStyle(LinkButtonStyle(color: Theme.ai))
                    .help("Show where this explanation clicked")
                } else {
                    Text("From deleted chat").font(Theme.small).foregroundStyle(Theme.quiet)
                }
            }
        }
    }

}

private struct VerdictBar: View {
    let model: LectureWindowModel
    var wholeCard = false

    var body: some View {
        HStack(spacing: 10) {
            if wholeCard {
                Text("The verdict is for the whole card.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.quiet)
            }
            Spacer(minLength: 0)
            trailing
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    @ViewBuilder private var trailing: some View {
        if model.answerHidden {
            Button { model.revealAnswer() } label: {
                HStack(spacing: 6) {
                    Text("Show answer").font(.system(size: 12.5, weight: .semibold))
                    ShortcutKey(text: "Space")
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.borderStrong))
            }.fixedSize()
        } else { verdicts }
    }

    private var verdicts: some View {
        HStack(spacing: 6) {
            verdictButton("Good", key: "1", value: .good)
            verdictButton("Bad", key: "2", value: .bad)
        }.fixedSize()
    }

    private func verdictButton(_ title: String, key: String, value: CardVerdict) -> some View {
        let active = model.selectedCard?.verdict == value
        let color = wholeCard && value == .good ? Theme.solveGreen : value.v2Color
        let wash = wholeCard ? (value == .good ? Theme.goodWash : Theme.badWash) : color.opacity(0.08)
        return Button {
            Task { await model.setVerdict(value) }
        } label: {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 7, height: 7).accessibilityHidden(true)
                Text(title).font(.system(size: 12.5, weight: active ? .semibold : .medium))
                ShortcutKey(text: key).accessibilityHidden(true)
            }
            .foregroundStyle(active ? color : Theme.quiet)
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(active ? wash : .clear, in: RoundedRectangle(cornerRadius: 7))
        }
        .accessibilityAddTraits(active ? .isSelected : [])
        .disabled(model.readOnly)
    }
}

private struct CardPager: View {
    let model: LectureWindowModel

    var body: some View {
        HStack(spacing: 10) {
            step("chevron.left", label: "Previous card", delta: -1)
            Text("\(model.selectedCard.flatMap { model.cardNumbers[$0.id] } ?? 0) / \(model.activeCards.count)")
                .font(.system(size: 12.5)).monospacedDigit().foregroundStyle(Theme.quiet)
            step("chevron.right", label: "Next card", delta: 1)
        }.buttonStyle(.plain).fixedSize()
    }

    private func step(_ icon: String, label: String, delta: Int) -> some View {
        Button { model.stepCard(delta) } label: {
            Image(systemName: icon).font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.ink)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(label)
    }
}
