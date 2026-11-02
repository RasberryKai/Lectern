import LecternCore
import SwiftUI

struct ReviewView: View {
    @Bindable var model: LectureWindowModel
    var focus: FocusState<EditorField?>.Binding

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                CardList(model: model)
                    .frame(width: 280)
                    .background(Theme.sidebar)
                Rectangle().fill(Theme.border).frame(width: 1)
                ScrollView {
                    if let card = model.selectedCard {
                        CardDetail(model: model, card: card, focus: focus)
                            .padding(.horizontal, 28).padding(.vertical, 22)
                    } else {
                        emptyState.padding(40)
                    }
                }
                .frame(maxWidth: .infinity)
                if model.askVisible, let card = model.selectedCard {
                    Rectangle().fill(Theme.border).frame(width: 1)
                    SourcePane(model: model, card: card, focus: focus)
                        .frame(width: 340)
                        .background(Theme.surface)
                }
            }
            VerdictBar(model: model)
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
        (.all, "All"), (.aiFlagged, "AI flagged"), (.proposals, "Proposals ready"), (.unreviewed, "Unreviewed"),
        (.good, "Good"), (.needsAdjustment, "Needs adjustment"), (.bad, "Bad")
    ]

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 1) {
                ForEach(filters, id: \.0) { filter, title in
                    let active = model.reviewFilter == filter
                    Button { model.setReviewFilter(filter) } label: {
                        HStack {
                            Text(title).font(.system(size: 13, weight: active ? .semibold : .regular))
                            Spacer()
                            Text("\(model.count(for: filter))").font(Theme.small).monospacedDigit().foregroundStyle(Theme.quiet)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(active ? Theme.surface : .clear, in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
            Rectangle().fill(Theme.border).frame(height: 1).padding(.horizontal, 12)
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
                    .padding(12)
                }
                .onChange(of: model.selectedCardID) { _, id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id) }
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

    @ViewBuilder private var tag: some View {
        if card.proposal != nil { Pill(text: "Proposal", tone: .ai) }
        else if revising { Pill(text: "Revising", tone: .ai) }
        else if issues { Pill(text: "Fix", tone: .bad) }
        else if card.flag != nil && card.verdict == .unreviewed { Pill(text: "Flagged", tone: .amber) }
        else {
            switch card.verdict {
            case .good: Pill(text: "Good", tone: .good)
            case .needsAdjustment: Pill(text: "Adjust", tone: .amber)
            case .bad: Pill(text: "Bad", tone: .bad)
            case .unreviewed: Pill(text: "New", tone: .neutral)
            }
        }
    }
}

// MARK: - Card detail

private struct CardDetail: View {
    @Bindable var model: LectureWindowModel
    let card: Card
    var focus: FocusState<EditorField?>.Binding

    var body: some View {
        let issues = model.lecture.issues(for: card)
        VStack(alignment: .leading, spacing: 16) {
            header
            if let flag = card.flag {
                Label("Claude flagged: \(flag)", systemImage: "flag")
                    .font(Theme.small).foregroundStyle(Theme.amber)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.amberWash, in: RoundedRectangle(cornerRadius: 8))
            }
            if !issues.isEmpty { issueList(issues) }
            VStack(alignment: .leading, spacing: 0) {
                side("Front", text: $model.editorFront, field: .front, size: 18)
                Rectangle().fill(Theme.border).frame(height: 1)
                side("Back", text: $model.editorBack, field: .back, size: 16)
                if model.lecture.pageCount > 0 { sources }
                feedback
            }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            MathChoices(model: model, card: card)
            if model.runningJobs.contains(where: { $0.kind == .revise && $0.targetCardID == card.id }) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Claude is revising this card. Keep reviewing; the proposal appears here.").font(Theme.small).foregroundStyle(Theme.aiStrong)
                }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.aiWash, in: RoundedRectangle(cornerRadius: 10))
            }
            if let proposal = card.proposal { ProposalCard(model: model, card: card, proposal: proposal) }
            history
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("Card \(model.cardNumbers[card.id] ?? 0)").font(Theme.serif(22))
            Text(card.sourcePages.isEmpty ? "no source slide" : "from \(Format.slides(card.sourcePages))")
                .font(Theme.body).foregroundStyle(Theme.quiet)
            verdictPill
            if card.proposal != nil { Pill(text: card.proposalIsStale ? "Proposal on older text" : "Proposal ready", tone: .ai) }
            if case .splitFrom = card.origin { Pill(text: "Split", tone: .neutral) }
            Spacer()
        }
    }

    @ViewBuilder private var verdictPill: some View {
        switch card.verdict {
        case .good: Pill(text: "Good", tone: .good)
        case .bad: Pill(text: "Bad", tone: .bad)
        case .needsAdjustment: Pill(text: "Needs adjustment", tone: .amber)
        case .unreviewed: Pill(text: "Unreviewed", tone: .neutral)
        }
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
            TextEditor(text: text)
                .font(.system(size: size))
                .scrollContentBackground(.hidden)
                .frame(minHeight: size * 3.2, maxHeight: 260)
                .focused(focus, equals: field)
                .disabled(model.readOnly)
                .onChange(of: text.wrappedValue) { _, _ in
                    if focus.wrappedValue == field { model.editorChanged() }
                }
            MathPreviewView(text: text.wrappedValue)
        }
        .padding(.horizontal, 22).padding(.vertical, 16)
    }

    private var sources: some View {
        HStack(spacing: 8) {
            Text("Source slides").eyebrow()
            TextField("e.g. 8, 9", text: $model.editorSources)
                .textFieldStyle(.roundedBorder).frame(width: 140)
                .focused(focus, equals: .sources)
                .disabled(model.readOnly)
                .onChange(of: model.editorSources) { _, _ in
                    if focus.wrappedValue == .sources { model.editorChanged() }
                }
            Text("One-based slide numbers from the original PDF.").font(Theme.caption).foregroundStyle(Theme.faint)
            Spacer()
        }
        .padding(.horizontal, 22).padding(.bottom, 12)
    }

    private var feedback: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Your feedback:").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.amber)
                TextField("What should change? ⌘↩ sends it to Claude; Esc keeps it as a note.", text: $model.feedbackDraft, axis: .vertical)
                    .textFieldStyle(.plain).font(Theme.small).lineLimit(1...6)
                    .focused(focus, equals: .feedback)
                    .disabled(model.readOnly)
            }
            if !model.feedbackDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                HStack(spacing: 10) {
                    Button("Send to Claude ⌘↩") { Task { await model.sendFeedback() } }
                        .buttonStyle(SecondaryButtonStyle(foreground: Theme.aiStrong, stroke: Theme.ai))
                        .disabled(model.readOnly || card.proposal != nil)
                        .help(card.proposal != nil ? "Resolve the current proposal first." : "Claude rewrites the card; you keep reviewing.")
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
                Text(proposal.cards.count > 1 ? "Revision proposal · split into \(proposal.cards.count) cards" : "Revision proposal")
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.aiStrong)
                Spacer()
                Text(subtitle).font(Theme.small).foregroundStyle(Theme.quiet)
            }
            if card.proposalIsStale {
                Label("You edited this card after asking. The diff compares with your current text.", systemImage: "clock.arrow.circlepath")
                    .font(Theme.small).foregroundStyle(Theme.amber)
            }
            switch proposal.state {
            case .pending:
                HStack { ProgressView().controlSize(.small); Text("Waiting for Claude…").font(Theme.small) }
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
                Text("Why: \(proposal.rationale)").font(Theme.small).foregroundStyle(Theme.quiet)
            }
            HStack(spacing: 10) {
                if proposal.cards.count == 1 {
                    Button("Accept and approve ⇧↩") { Task { await model.acceptProposal(approve: true) } }
                        .buttonStyle(PrimaryButtonStyle(tint: Theme.aiStrong))
                }
                Button("Accept ↩") { Task { await model.acceptProposal(approve: false) } }
                    .buttonStyle(SecondaryButtonStyle(foreground: Theme.aiStrong, stroke: Theme.ai))
                if proposal.cards.count == 1 {
                    Button("Edit first") { Task { await model.editProposalFirst() } }.buttonStyle(SecondaryButtonStyle())
                }
                Button("Discard X") { Task { await model.discardProposal() } }.buttonStyle(SecondaryButtonStyle())
            }
            .disabled(model.readOnly || proposal.state != .ready)
        }
        .padding(18)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.aiStrong, lineWidth: 2))
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
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).eyebrow()
            Text(attributed).font(.system(size: 16)).lineSpacing(4).textSelection(.enabled)
        }
    }

    private var attributed: AttributedString {
        var result = AttributedString()
        for token in WordDiff.compare(before, after) {
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
        }
        return result
    }
}

// MARK: - Source pane

private struct SourcePane: View {
    @Bindable var model: LectureWindowModel
    let card: Card
    var focus: FocusState<EditorField?>.Binding

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Source").font(.system(size: 14, weight: .semibold))
                    Spacer()
                    if let page = currentPage {
                        Button("Open in Prepare  G") { model.jumpToPrepare(page: page) }.buttonStyle(LinkButtonStyle())
                    }
                }
                if card.sourcePages.isEmpty {
                    Text(model.lecture.pageCount == 0
                         ? "No source slides. This card came from the reviewer, so G, S and Ask are off."
                         : "This card has no source slide yet. Add one under the card text.")
                        .font(Theme.small).foregroundStyle(Theme.quiet)
                } else {
                    let url = model.app.store.sourceURL(moduleID: model.ref.moduleID, lectureID: model.ref.lectureID)
                    ForEach(Array(card.sourcePages.enumerated()), id: \.offset) { index, page in
                        if (1...max(1, model.lecture.pageCount)).contains(page) && model.lecture.pageCount > 0 {
                            VStack(alignment: .leading, spacing: 5) {
                                SlideImage(sourceURL: url, pageIndex: page - 1, width: 300)
                                    .overlay(RoundedRectangle(cornerRadius: 6)
                                        .strokeBorder(index == model.sourceIndex ? Theme.ai : Theme.border, lineWidth: index == model.sourceIndex ? 2 : 1))
                                    .onTapGesture { model.sourceIndex = index; model.enlargedPage = page }
                                let note = model.noteText(for: page - 1).trimmingCharacters(in: .whitespacesAndNewlines)
                                Text(note.isEmpty ? "Slide \(page)" : "Slide \(page) · note: “\(note)”")
                                    .font(Theme.caption).foregroundStyle(Theme.quiet).lineLimit(3)
                            }
                        } else {
                            Text("Slide \(page) isn't in this PDF. Fix the source number on the card.").font(Theme.small).foregroundStyle(Theme.bad)
                        }
                    }
                    if card.sourcePages.count > 1 {
                        Text("S cycles sources · Space enlarges").font(Theme.caption).foregroundStyle(Theme.faint)
                    }
                }
                if let page = card.sourcePages.first, model.lecture.pageCount > 0, (1...model.lecture.pageCount).contains(page) {
                    Rectangle().fill(Theme.border).frame(height: 1)
                    AskPanel(model: model, page: page, cardID: card.id, focus: focus)
                        .padding(-16)
                        .padding(.top, 8)
                }
            }
            .padding(18)
        }
    }

    private var currentPage: Int? {
        guard !card.sourcePages.isEmpty, model.lecture.pageCount > 0 else { return nil }
        return card.sourcePages[min(model.sourceIndex, card.sourcePages.count - 1)]
    }
}

// MARK: - Verdict bar

private struct VerdictBar: View {
    let model: LectureWindowModel

    var body: some View {
        let verdict = model.selectedCard?.verdict
        HStack(spacing: 10) {
            Button("← Previous") { model.stepCard(-1) }.buttonStyle(SecondaryButtonStyle())
            verdictButton("Good 1", .good, Theme.good, Theme.goodWash, active: verdict == .good)
            verdictButton("Bad 2", .bad, Theme.bad, Theme.badWash, active: verdict == .bad)
            verdictButton("Needs adjustment 3", .needsAdjustment, Theme.amber, Theme.amberWash, active: verdict == .needsAdjustment)
            Button("Next →") { model.stepCard(1) }.buttonStyle(SecondaryButtonStyle())
            Spacer()
            Text("S source · A ask · ⌘↩ send feedback to AI").font(Theme.small).foregroundStyle(Theme.quiet)
            Button("Undo U") { Task { await model.undo() } }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(!model.session.canUndo || model.readOnly)
        }
        .padding(.horizontal, 22).padding(.vertical, 12)
        .background(Theme.surface)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
        .disabled(model.selectedCard == nil)
    }

    private func verdictButton(_ title: String, _ value: CardVerdict, _ text: Color, _ wash: Color, active: Bool) -> some View {
        Button(title) { Task { await model.setVerdict(value) } }
            .buttonStyle(SecondaryButtonStyle(foreground: text, stroke: active ? text : text.opacity(0.45), fill: wash))
            .fontWeight(active ? .bold : .medium)
            .disabled(model.readOnly)
    }
}
