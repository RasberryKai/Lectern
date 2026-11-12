import LecternCore
import SwiftUI

struct ReviewView: View {
    @Bindable var model: LectureWindowModel
    var focus: FocusState<EditorField?>.Binding

    var body: some View {
        LecturePanes(model: model) {
            CardList(model: model)
        } stage: {
            ScrollView {
                if let card = model.selectedCard {
                    CardDetail(model: model, card: card, focus: focus)
                        .frame(maxWidth: 760)
                        .padding(.horizontal, 28).padding(.vertical, 24)
                        .frame(maxWidth: .infinity)
                } else { emptyState.padding(40) }
            }
        } right: {
            LectureSidePanel(model: model, focus: focus)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.activeCards.isEmpty {
                Text("No cards yet").font(Theme.serif(22))
                Text(model.lecture.pageCount > 0
                     ? "Select slides and note what matters in Prepare, then Generate. New cards land here as Unreviewed."
                     : "This lecture has no cards.")
                    .font(Theme.body).foregroundStyle(Theme.quiet)
                if model.lecture.pageCount > 0 {
                    Button("Go to Prepare") { model.setMode(.prepare) }.buttonStyle(PrimaryButtonStyle())
                }
            } else if model.testMode && model.reviewFilter == .unreviewed {
                Text("Every card is tested").font(Theme.serif(22))
                Text("\(model.count(for: .good)) Good cards go to Anki. Needs work and Bad cards stay here.")
                    .font(Theme.body).foregroundStyle(Theme.quiet)
                HStack(spacing: 10) {
                    Button("Export to Anki") {
                        Task { await model.app.returnToLibrary(destination: .export(model.ref.moduleID)) }
                    }.buttonStyle(PrimaryButtonStyle())
                    Button("Show all cards") { model.setReviewFilter(.all) }.buttonStyle(SecondaryButtonStyle())
                }
            } else {
                Text("Nothing in this filter").font(Theme.serif(22))
                Button("Show all cards") { model.setReviewFilter(.all) }.buttonStyle(SecondaryButtonStyle())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Card list

private struct CardList: View {
    @Bindable var model: LectureWindowModel

    private let filters: [(ReviewFilter, String)] = [
        (.all, "All"), (.unreviewed, "To review"), (.aiFlagged, "AI flagged"),
        (.needsAdjustment, "Needs work"), (.bad, "Bad"), (.good, "Good"), (.proposals, "Proposals")
    ]

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.faint)
                    TextField("Search cards", text: $model.reviewSearch).textFieldStyle(.plain).font(Theme.body)
                        .accessibilityLabel("Search cards")
                }
                .padding(8).background(Theme.surface, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.border))
                ViewThatFits(in: .horizontal) {
                    filterRows(columns: 3)
                    filterRows(columns: 2)
                    filterRows(columns: 1)
                }
            }.padding(10)
            Divider().overlay(Theme.border)
            let numbers = model.cardNumbers
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(model.visibleCards) { card in
                            CardRow(card: card, number: numbers[card.id] ?? 0, issues: !model.lecture.issues(for: card).isEmpty,
                                    revising: model.runningJobs.contains { $0.kind == .revise && $0.targetCardID == card.id },
                                    selected: card.id == model.selectedCardID)
                                .id(card.id)
                                .onTapGesture { model.selectCard(card.id) }
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
    }
    private func filterRows(columns: Int) -> some View {
        let shown = filters.filter { $0.0 != .proposals || model.count(for: .proposals) > 0 }
        return VStack(alignment: .leading, spacing: 5) {
            ForEach(0..<((shown.count + columns - 1) / columns), id: \.self) { row in
                HStack(spacing: 5) {
                    ForEach(Array(shown.dropFirst(row * columns).prefix(columns)), id: \.0) { filter, title in
                        let active = model.reviewFilter == filter
                        Button { model.setReviewFilter(filter) } label: {
                            HStack(spacing: 5) {
                                if filter == .aiFlagged { Image(systemName: "sparkles").foregroundStyle(active ? Theme.canvas : Theme.ai) }
                                Text(title)
                                Text("\(model.count(for: filter))").fontWeight(.semibold)
                            }
                            .font(Theme.small).foregroundStyle(active ? Theme.canvas : Theme.quiet)
                            .padding(.horizontal, 9).padding(.vertical, 3)
                            .background(active ? Theme.ink : Theme.surface, in: Capsule())
                            .overlay(Capsule().strokeBorder(active ? Theme.ink : Theme.border))
                            .fixedSize()
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
    }

}

private struct CardRow: View {
    let card: Card
    let number: Int
    let issues: Bool
    let revising: Bool
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text("\(number)").font(Theme.caption).monospacedDigit().foregroundStyle(Theme.quiet).frame(width: 22, alignment: .leading)
            Text(card.front.isEmpty ? "Empty front" : card.front).font(Theme.small).lineLimit(1)
            Spacer(minLength: 4)
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
            else { Circle().fill(issues ? Theme.bad : card.verdict.v2Color).frame(width: 7, height: 7) }
        }
        .accessibilityLabel(card.verdict.v2Title)
    }
}

// MARK: - Card detail

private struct CardDetail: View {
    @Bindable var model: LectureWindowModel
    let card: Card
    var focus: FocusState<EditorField?>.Binding
    @State private var showSourcePicker = false

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
                            Button("Dismiss") { model.dismissFlag(cardID: card.id) }
                                .buttonStyle(LinkButtonStyle(color: Theme.quiet))
                        }.disabled(model.readOnly)
                    }
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.aiWash, in: RoundedRectangle(cornerRadius: 10)).padding(16)
                }
                if !hidden, !issues.isEmpty { issueList(issues).padding(12) }
                side("Front", text: $model.editorFront, field: .front, size: 24)
                Rectangle().fill(Theme.border).frame(height: 1)
                if hidden { answerPrompt } else { answer }
                VerdictBar(model: model, focus: focus)
            }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.border))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            if !hidden { MathChoices(model: model, card: card) }
            hints(hidden: hidden)
            if !hidden { history }
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
        if (card.verdict == .needsAdjustment && card.proposal == nil) || focus.wrappedValue == .feedback { feedback }
        if model.lecture.pageCount > 0 { sources }
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

    private func issueList(_ issues: [CardIssue]) -> some View {
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

    private func side(_ title: String, text: Binding<String>, field: EditorField, size: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).eyebrow()
            TextField(title, text: text, axis: .vertical)
                .font(field == .front ? Theme.serif(size, weight: .medium) : .system(size: size))
                .lineSpacing(5)
                .textFieldStyle(.plain)
                .lineLimit(1...20)
                .padding(.vertical, 4)
                .focused(focus, equals: field)
                .disabled(model.readOnly)
                .onChange(of: text.wrappedValue) { _, _ in
                    if focus.wrappedValue == field { model.editorChanged() }
                }
            MathPreviewView(text: text.wrappedValue)
        }
        .padding(.horizontal, 26).padding(.vertical, 20)
    }

    private var sources: some View {
        HStack(spacing: 8) {
            Text("From").foregroundStyle(Theme.quiet)
            ForEach(card.sourcePages, id: \.self) { page in
                HStack(spacing: 5) {
                    Button("Slide \(page)") { model.enlargedPage = page }.buttonStyle(.plain)
                    Button {
                        model.editorSources = card.sourcePages.filter { $0 != page }.map(String.init).joined(separator: ", ")
                        model.editorChanged()
                    } label: { Image(systemName: "xmark").font(.system(size: 9)).foregroundStyle(Theme.faint) }
                    .buttonStyle(.plain).disabled(model.readOnly).accessibilityLabel("Remove slide \(page) source")
                }
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Theme.inset, in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.border))
            }
            Button("add") { showSourcePicker = true }.buttonStyle(LinkButtonStyle(color: Theme.quiet)).disabled(model.readOnly)
                .popover(isPresented: $showSourcePicker) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Source slides").fontWeight(.semibold)
                        TextField("e.g. 1, 2", text: $model.editorSources).textFieldStyle(.roundedBorder)
                            .onChange(of: model.editorSources) { _, _ in model.editorChanged() }
                        Button("Done") { showSourcePicker = false }.buttonStyle(PrimaryButtonStyle())
                    }.padding(16).frame(width: 220)
                }
            Spacer()
            Text(card.history.count > 1 ? "Edited" : "As generated").foregroundStyle(Theme.quiet)
        }
        .font(Theme.small).padding(.horizontal, 26).padding(.vertical, 10)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private var feedback: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Your feedback:").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.amber)
                TextField("What should change? Enter sends · Shift+Enter for a new line.", text: $model.feedbackDraft, axis: .vertical)
                    .textFieldStyle(.plain).font(Theme.small).lineLimit(1...6)
                    .focused(focus, equals: .feedback)
                    .disabled(model.readOnly)
            }
            if !model.feedbackDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                HStack(spacing: 10) {
                    Button("Send to AI ↩") { Task { await model.sendFeedback() } }
                        .buttonStyle(SecondaryButtonStyle(foreground: Theme.aiStrong, stroke: Theme.ai))
                        .disabled(model.readOnly || card.proposal != nil)
                        .help(card.proposal != nil ? "Resolve the current proposal first." : "AI rewrites the card; you keep reviewing.")
                    Button("Make module rule") { Task { await model.makeModuleRule() } }
                        .buttonStyle(LinkButtonStyle())
                        .disabled(model.readOnly)
                        .help("Appends this feedback to the module instructions for future generations.")
                    if let result = model.proposeResult { Text(result).font(Theme.caption).foregroundStyle(Theme.quiet).lineLimit(2) }
                }
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.amberWash.opacity(0.55))
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
                Text("This proposal failed. Discard it and send the feedback again.").font(Theme.small).foregroundStyle(Theme.bad)
            case .ready:
                if proposal.cards.count == 1, let draft = proposal.cards.first {
                    if draft.front != card.front { DiffText(label: "Front", before: card.front, after: draft.front) }
                    if draft.back != card.back { DiffText(label: "Back", before: card.back, after: draft.back) }
                    if draft.front == card.front && draft.back == card.back {
                        Text("Text unchanged\(draft.sourcePages != card.sourcePages ? "; sources become \(Format.slides(draft.sourcePages))" : "").")
                            .font(Theme.small).foregroundStyle(Theme.quiet)
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
            .disabled(model.readOnly || proposal.state != .ready)
        }
        .padding(18)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.ai, lineWidth: 1))
    }

    @ViewBuilder private var proposalActions: some View {
        Button("Accept ↩") { Task { await model.acceptProposal(approve: false) } }
            .buttonStyle(PrimaryButtonStyle())
        if proposal.cards.count == 1 {
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

// MARK: - Source pane

struct ReviewSourcePane: View {
    @Bindable var model: LectureWindowModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let card = model.selectedCard, !card.sourcePages.isEmpty {
                    let index = min(model.sourceIndex, card.sourcePages.count - 1)
                    let page = card.sourcePages[index]
                    let url = model.app.store.sourceURL(moduleID: model.ref.moduleID, lectureID: model.ref.lectureID)
                    if model.answerHidden {
                        // The slide is the answer; blur it until Space.
                        SlideImage(sourceURL: url, pageIndex: page - 1, width: 900)
                            .blur(radius: 22).opacity(0.5)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay { Text("Hidden until you show the answer").font(Theme.small).foregroundStyle(Theme.quiet) }
                            .accessibilityLabel("Source slide hidden until you show the answer")
                    } else if page > 0 && page <= model.lecture.pageCount {
                        SlideImage(sourceURL: url, pageIndex: page - 1, width: 900)
                            .onTapGesture { model.enlargedPage = page }
                        HStack {
                            Text("Slide \(page)").font(Theme.body)
                            Spacer()
                            Button("Enlarge") { model.enlargedPage = page }.buttonStyle(LinkButtonStyle(color: Theme.quiet))
                            Button("Prepare") { model.jumpToPrepare(page: page) }.buttonStyle(LinkButtonStyle(color: Theme.quiet))
                        }
                        if card.sourcePages.count > 1 {
                            HStack {
                                Button { model.sourceIndex = (index - 1 + card.sourcePages.count) % card.sourcePages.count } label: { Image(systemName: "chevron.left") }
                                Text("\(index + 1) of \(card.sourcePages.count) sources · S cycles").font(Theme.caption).foregroundStyle(Theme.faint)
                                Button { model.sourceIndex = (index + 1) % card.sourcePages.count } label: { Image(systemName: "chevron.right") }
                            }.buttonStyle(.plain)
                        }
                        let note = model.noteText(for: page - 1)
                        if !note.isEmpty { Text(note).font(Theme.body).foregroundStyle(Theme.quiet) }
                    } else { Text("This source slide is unavailable. Update its number on the card.").font(Theme.body).foregroundStyle(Theme.bad) }
                } else { Text("No source slides linked to this card.").font(Theme.body).foregroundStyle(Theme.quiet) }
            }.padding(16)
        }
    }
}

private struct VerdictBar: View {
    let model: LectureWindowModel
    var focus: FocusState<EditorField?>.Binding

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 7) { pager; Spacer(minLength: 8); trailing }
            VStack(alignment: .leading, spacing: 10) { pager; trailing }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Theme.inset.opacity(0.5))
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private var pager: some View {
        HStack(spacing: 10) {
            Button { model.stepCard(-1) } label: { Image(systemName: "chevron.left") }.accessibilityLabel("Previous card")
            Text("\(model.selectedCard.flatMap { model.cardNumbers[$0.id] } ?? 0) / \(model.activeCards.count)")
                .font(Theme.small).monospacedDigit().foregroundStyle(Theme.quiet)
            Button { model.stepCard(1) } label: { Image(systemName: "chevron.right") }.accessibilityLabel("Next card")
        }.fixedSize()
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
            verdictButton("Bad", key: "2", value: .bad)
            verdictButton("Needs work", key: "3", value: .needsAdjustment)
            verdictButton("Good", key: "1", value: .good)
        }.fixedSize()
    }

    private func verdictButton(_ title: String, key: String, value: CardVerdict) -> some View {
        let active = model.selectedCard?.verdict == value
        return Button {
            Task { await model.setVerdict(value) }
            if value == .needsAdjustment { focus.wrappedValue = .feedback }
        } label: {
            HStack(spacing: 6) {
                Circle().fill(value.v2Color).frame(width: 7, height: 7)
                Text(title).font(.system(size: 12.5, weight: active ? .semibold : .medium))
                ShortcutKey(text: key)
            }
            .foregroundStyle(active ? value.v2Color : Theme.ink)
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(active ? value.v2Color.opacity(0.1) : Theme.surface, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(active ? value.v2Color : Theme.borderStrong))
        }.disabled(model.readOnly)
    }
}
