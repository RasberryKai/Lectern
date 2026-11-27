import AppKit
import LecternCore
import SwiftUI

struct ChatMessageView: View {
    let model: LectureWindowModel
    let message: ChatMessage
    @State private var hovering = false
    var body: some View {
        Group {
            if message.role == .user {
                HStack {
                    Spacer(minLength: 28)
                    VStack(alignment: .trailing, spacing: 5) {
                        if !message.context.isEmpty { Text("on " + model.chatContextLabel(message.context)).font(.system(size: 10.5)).foregroundStyle(Theme.faint) }
                        if !message.attachments.isEmpty { ChatAttachmentStrip(model: model, attachments: message.attachments) }
                        if !message.text.isEmpty { Text(message.text).font(.system(size: 13.5)).lineSpacing(4).textSelection(.enabled)
                            .padding(.horizontal, 12).padding(.vertical, 9).background(Theme.inset, in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    if !message.read.isEmpty { Label("Read " + model.chatContextLabel(message.read), systemImage: "sparkle").font(.system(size: 10.5)).foregroundStyle(Theme.faint) }
                    ChatCitedMarkdownView(model: model, text: message.text, jobID: message.editJobID)
                    if message.stopped { Text("Stopped").font(Theme.caption).foregroundStyle(Theme.faint) }
                    if message.searchedLecture { Text("Searched the lecture").font(Theme.caption).foregroundStyle(Theme.faint) }
                    if !message.quiz.isEmpty { quiz }
                    if let ids = message.createdCardIDs, !ids.isEmpty { createdCards(ids) }
                    if let requests = message.deletionRequests, !requests.isEmpty {
                        ChatDeletionBlock(model: model, chatID: model.displayedChat.id, messageID: message.id, requests: requests)
                    }
                    if let id = message.editJobID, let job = model.lecture.jobs.first(where: { $0.id == id }), job.chatEdits?.isEmpty == false || job.chatEditUndo?.isEmpty == false { ChatEditBlock(model: model, job: job) }
                    if let suggestion = message.suggestion { CardSuggestionBlock(model: model, message: message, suggestion: suggestion) }
                    HStack(spacing: 14) {
                        action("Copy", "doc.on.doc") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(message.text, forType: .string) }
                            .opacity(hovering ? 1 : 0).accessibilityHidden(!hovering)
                        if lectureChatJob != nil {
                            Button { Task { await model.toggleClicked(message) } } label: {
                                Label("Clicked", systemImage: message.clicked ? "checkmark.circle.fill" : "checkmark.circle").font(.system(size: 10.5, weight: message.clicked ? .semibold : .regular))
                            }
                            .buttonStyle(.plain).foregroundStyle(message.clicked ? Theme.good : Theme.faint)
                            .help(message.clicked ? "Unmark this explanation" : "This explanation worked: use it for your cards")
                            .opacity(hovering || message.clicked ? 1 : 0).accessibilityHidden(!hovering && !message.clicked)
                            .disabled(model.readOnly)
                        }
                        if message.createdCardIDs?.isEmpty != false,
                           message.deletionRequests?.contains(where: { $0.state == .deleted }) != true,
                           canRetryAnswer {
                            action("Retry", "arrow.clockwise") { Task { await model.retryChatAnswer(message) } }
                                .opacity(hovering ? 1 : 0).accessibilityHidden(!hovering)
                                .disabled(model.readOnly || model.runningChat != nil || model.isShowingAskActivity)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).onHover { hovering = $0 }
            }
        }
    }
    private var lectureChatJob: Job? {
        guard let id = message.editJobID else { return nil }
        return model.lecture.jobs.first { $0.id == id && $0.kind == .chat && $0.isLectureChat == true }
    }
    private var canRetryAnswer: Bool {
        guard let job = lectureChatJob else { return false }
        guard model.chatEditHasFlipReplacement(job) else { return true }
        return (job.chatEditDisposition != .applied || job.chatEditsUndoneAt != nil) && !model.chatEditConflicted(job)
    }
    private func action(_ title: String, _ symbol: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) { Label(title, systemImage: symbol).font(.system(size: 10.5)) }.buttonStyle(.plain).foregroundStyle(Theme.faint)
    }
    private func createdCards(_ ids: [UUID]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("Added \(Format.count(ids.count, "flashcard"))", systemImage: "rectangle.badge.plus")
                .font(.system(size: 12, weight: .semibold))
            ForEach(ids, id: \.self) { id in
                if let number = model.cardNumbers[id] {
                    Button("Open Card \(number)") { model.openChatCard(id) }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.ai)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(Theme.aiWash.opacity(0.6), in: RoundedRectangle(cornerRadius: 9))
    }
    private var quiz: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(message.quiz.enumerated()), id: \.offset) { index, item in
                DisclosureGroup {
                    ChatCitedMarkdownView(model: model, text: item.answer, jobID: message.editJobID).padding(.top, 6)
                } label: { Text("\(index + 1). \(item.question)").font(.system(size: 13, weight: .medium)) }
                    .padding(10).background(Theme.inset, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

/// Shared by saved answers, quizzes and streaming answers so citations behave alike.
struct ChatCitedMarkdownView: View {
    let model: LectureWindowModel
    let text: String
    let jobID: UUID?
    var streaming = false

    var body: some View {
        ChatMarkdownView(text: text, streaming: streaming) { citation in
            model.openChatCitation(citation, jobID: jobID)
        }
    }
}

struct ChatEditBlock: View {
    let model: LectureWindowModel
    let job: Job
    @State private var expanded = false
    var body: some View {
        let diffs = model.chatEditDiffs(job)
        let hasReplacement = model.chatEditHasFlipReplacement(job)
        let showsDiffs = diffs.count <= 3 || (hasReplacement ? !expanded : expanded)
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Image(systemName: "rectangle.and.pencil.and.ellipsis").foregroundStyle(Theme.ai)
                Text(model.chatEditTitle(job)).font(.system(size: 12, weight: .semibold))
                Spacer()
                if diffs.count > 3 {
                    Button { expanded.toggle() } label: { Image(systemName: showsDiffs ? "chevron.up" : "chevron.down") }
                        .buttonStyle(.plain)
                        .accessibilityLabel(showsDiffs ? "Hide changes" : "Show changes")
                }
            }
            if showsDiffs {
                ForEach(diffs) { diff in
                    VStack(alignment: .leading, spacing: 5) {
                        Button("Card \(diff.number)") { model.openChatCard(diff.cardID) }.buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.ai)
                        if let edit = job.chatEdits?.first(where: { $0.cardID == diff.cardID && $0.replacesFlipCard }),
                           let solve = edit.solve {
                            replacementPreview(solve, diff: diff)
                        } else if diff.caseEdits.isEmpty {
                            if diff.oldFront != diff.newFront { ChatWordDiff(before: diff.oldFront, after: diff.newFront) }
                            if diff.oldBack != diff.newBack { ChatWordDiff(before: diff.oldBack, after: diff.newBack) }
                            if diff.solveChanged && diff.oldFront == diff.newFront && diff.oldBack == diff.newBack {
                                Text("Exercise settings changed").font(Theme.caption).foregroundStyle(Theme.quiet)
                            }
                        } else {
                            ForEach(diff.caseEdits) { change in
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(change.ordinal.map { "Case \($0)" } ?? "Case variation")
                                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.quiet)
                                    if let oldQuestion = change.oldQuestion, oldQuestion != change.newQuestion {
                                        Text("Question").font(Theme.caption).foregroundStyle(Theme.faint)
                                        ChatWordDiff(before: oldQuestion, after: change.newQuestion)
                                    } else if change.oldQuestion == nil {
                                        Text("Original case unavailable. Proposed question:").font(Theme.caption).foregroundStyle(Theme.bad)
                                        Text(change.newQuestion).font(Theme.caption).textSelection(.enabled)
                                    }
                                    if let oldAnswer = change.oldAnswer, oldAnswer != change.newAnswer {
                                        Text("Answer").font(Theme.caption).foregroundStyle(Theme.faint)
                                        ChatWordDiff(before: oldAnswer, after: change.newAnswer)
                                    } else if change.oldAnswer == nil {
                                        Text("Proposed answer:").font(Theme.caption).foregroundStyle(Theme.faint)
                                        Text(change.newAnswer).font(Theme.caption).textSelection(.enabled)
                                    }
                                    ForEach(change.controlChanges, id: \.self) { setting in
                                        Text(setting).font(Theme.caption).foregroundStyle(Theme.quiet)
                                    }
                                    if change.controlChanges.isEmpty && change.controlsChanged,
                                       change.oldQuestion == change.newQuestion, change.oldAnswer == change.newAnswer {
                                        Text("Answer checking or exercise settings changed.")
                                            .font(Theme.caption).foregroundStyle(Theme.quiet)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 5)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if hasReplacement && model.chatEditPending(job) {
                Label("Study starts fresh, with previous reviews kept in history.", systemImage: "clock.arrow.circlepath")
                    .font(Theme.caption).foregroundStyle(Theme.quiet)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.chatEditPending(job) {
                ViewThatFits(in: .horizontal) {
                    HStack {
                        pendingActions
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        pendingActions
                    }
                }
                .disabled(model.readOnly)
            } else if job.chatEditsUndoneAt == nil, job.chatEditUndo?.isEmpty == false {
                Button("Undo") { Task { await model.undoChatEdits(jobID: job.id) } }
                    .buttonStyle(.plain).font(Theme.caption).foregroundStyle(Theme.ai)
                    .disabled(model.readOnly || !model.lecture.canUndoChatEdits(jobID: job.id))
            }
        }.padding(11).background(Theme.aiWash.opacity(0.6), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.ai.opacity(0.2)))
    }

    @ViewBuilder private var pendingActions: some View {
        if model.chatEditHasCaseConflict(job) {
            Text("A targeted case changed. Dismiss this proposal and ask again.")
                .font(Theme.caption).foregroundStyle(Theme.bad)
        } else if model.chatEditHasFlipReplacement(job) {
            if model.chatEditConflicted(job) {
                Text(job.pdfLayoutRevision != model.lecture.pdfLayoutRevision
                    ? "The slide order changed. Dismiss this proposal and ask again."
                    : "A card changed. Dismiss this proposal and ask again.")
                    .font(Theme.caption).foregroundStyle(Theme.bad)
            } else {
                let edits = job.chatEdits ?? []
                let replacementCount = edits.filter(\.replacesFlipCard).count
                let hasOtherEdits = edits.contains { !$0.replacesFlipCard }
                let title = hasOtherEdits ? "Replace and apply edits" : replacementCount == 1 ? "Replace card" : "Replace cards"
                Button(title) {
                    Task { await model.resolveChatEdits(job, apply: true) }
                }
                .buttonStyle(SecondaryButtonStyle())
                .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Button(model.chatEditConflicted(job) ? "Apply anyway" : "Apply all") {
                Task { await model.resolveChatEdits(job, apply: true) }
            }
            .buttonStyle(SecondaryButtonStyle())
        }
        Button("Dismiss") { Task { await model.resolveChatEdits(job, apply: false) } }
            .buttonStyle(.plain)
    }

    private func replacementPreview(_ solve: SolveDraft, diff: ChatEditDiff) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Proposed solve exercise").eyebrow()
            SolveExerciseView(content: solve.sample, mode: .browse, showsMistakeMessages: true)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
                .id("\(job.id)-\(diff.cardID)")
        }
        .padding(10)
        .background(Theme.inset, in: RoundedRectangle(cornerRadius: 10))
    }
}

struct ChatDeletionBlock: View {
    let model: LectureWindowModel
    let chatID: UUID
    let messageID: UUID
    let requests: [ChatDeletionRequest]
    @State private var resolving = false

    var body: some View {
        let pending = requests.filter { $0.state == .pending }
        let cards = Dictionary(uniqueKeysWithValues: model.activeCards.map { ($0.id, $0) })
        let stale = Set(pending.filter { request in cards[request.id].map(request.version.matches) != true }.map(\.id))
        VStack(alignment: .leading, spacing: 10) {
            Label(pending.isEmpty ? "Flashcard deletion reviewed" : "Delete \(Format.count(pending.count, "flashcard"))?",
                  systemImage: "trash")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.bad)
            ForEach(requests) { request in
                Divider()
                VStack(alignment: .leading, spacing: 5) {
                    Text(request.front)
                        .font(.system(size: 12, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                    if request.state == .pending {
                        DisclosureGroup("Show answer") {
                            Text(request.back).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                        .font(Theme.caption)
                        .foregroundStyle(Theme.quiet)
                        if stale.contains(request.id) {
                            Text("Card changed or is gone").font(Theme.caption).foregroundStyle(Theme.amber)
                        }
                        HStack(spacing: 10) {
                            Button("Delete", role: .destructive) { resolve([request.id], delete: true) }
                                .buttonStyle(SecondaryButtonStyle(foreground: Theme.bad))
                                .accessibilityLabel("Delete \(request.front)")
                                .disabled(stale.contains(request.id))
                            Button("Keep") { resolve([request.id], delete: false) }
                                .buttonStyle(SecondaryButtonStyle())
                                .accessibilityLabel("Keep \(request.front)")
                        }
                        .disabled(resolving || model.readOnly)
                    } else {
                        Text(request.state == .deleted ? "Deleted" : "Kept")
                            .font(Theme.caption).foregroundStyle(Theme.quiet)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if pending.count > 1 {
                HStack(spacing: 10) {
                    Button("Delete all", role: .destructive) { resolve(Set(pending.map(\.id)), delete: true) }
                        .buttonStyle(SecondaryButtonStyle(foreground: Theme.bad))
                        .disabled(!stale.isEmpty)
                    Button("Keep all") { resolve(Set(pending.map(\.id)), delete: false) }
                        .buttonStyle(SecondaryButtonStyle())
                }
                .disabled(resolving || model.readOnly)
            }
        }
        .padding(11)
        .background(Theme.aiWash.opacity(0.6), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.ai.opacity(0.2)))
    }

    private func resolve(_ ids: Set<UUID>, delete: Bool) {
        guard !resolving else { return }
        resolving = true
        Task {
            defer { resolving = false }
            await model.resolveChatDeletions(chatID: chatID, messageID: messageID, cardIDs: ids, delete: delete)
        }
    }
}

/// A Review-chat recommendation, made after the student reacted to an explanation. Nothing changes until Apply.
struct CardSuggestionBlock: View {
    let model: LectureWindowModel
    let message: ChatMessage
    let suggestion: CardSuggestion
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: suggestion.isEdit ? "rectangle.and.pencil.and.ellipsis" : "rectangle.badge.plus").foregroundStyle(Theme.ai)
                Text(title).font(.system(size: 12, weight: .semibold))
                Spacer()
            }
            if suggestion.state == .pending {
                Text(suggestion.reason).font(Theme.small).foregroundStyle(Theme.quiet).fixedSize(horizontal: false, vertical: true)
                if isEditOutOfDate {
                    Label(obsoleteMessage, systemImage: "clock.arrow.circlepath")
                        .font(Theme.small).foregroundStyle(Theme.amber).fixedSize(horizontal: false, vertical: true)
                }
                if suggestion.isEdit, let card = target {
                    if card.front != suggestion.front { ChatWordDiff(before: card.front, after: suggestion.front) }
                    if card.back != suggestion.back { ChatWordDiff(before: card.back, after: suggestion.back) }
                } else if !suggestion.isEdit {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(suggestion.front).font(.system(size: 12, weight: .medium))
                        Divider()
                        Text(suggestion.back).font(.system(size: 12)).foregroundStyle(Theme.quiet)
                    }.textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .padding(9).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 7))
                }
                HStack {
                    Button(suggestion.isEdit ? "Apply" : "Add card") { Task { await model.resolveSuggestion(message, apply: true) } }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(model.readOnly || isEditOutOfDate)
                        .help(isEditOutOfDate ? obsoleteMessage : (suggestion.isEdit ? "Apply this card change" : "Add this card"))
                    Button("Dismiss") { Task { await model.resolveSuggestion(message, apply: false) } }
                        .buttonStyle(.plain).disabled(model.readOnly)
                }
            } else if suggestion.state == .applied {
                if let id = suggestion.cardID ?? suggestion.createdCardID, let number = model.cardNumbers[id] {
                    Button("Open Card \(number)") { model.openChatCard(id) }.buttonStyle(.plain).font(Theme.caption).foregroundStyle(Theme.ai)
                } else {
                    Text(suggestion.isEdit ? "The edited card is no longer available." : "The added card is no longer available.")
                        .font(Theme.caption).foregroundStyle(Theme.quiet)
                }
            }
        }
        .padding(11).background(Theme.aiWash.opacity(0.6), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.ai.opacity(0.2)))
        .opacity(suggestion.state == .dismissed ? 0.6 : 1)
    }
    private var target: Card? { suggestion.cardID.flatMap { id in model.activeCards.first { $0.id == id } } }
    private var isEditOutOfDate: Bool {
        guard suggestion.state == .pending, suggestion.isEdit else { return false }
        guard let target else { return true }
        return target.currentRevisionID != suggestion.baseRevisionID
    }
    private var obsoleteMessage: String {
        target == nil ? "The card this suggestion targets was removed or replaced. Dismiss this obsolete suggestion." :
            "This card changed after the suggestion was made. Dismiss it or ask again."
    }
    private var title: String {
        let number = suggestion.cardID.flatMap { model.cardNumbers[$0] }
        switch suggestion.state {
        case .pending:
            if suggestion.isEdit {
                if isEditOutOfDate { return number.map { "Out of date · Card \($0)" } ?? "Suggestion is out of date" }
                return number.map { "Suggested change to Card \($0)" } ?? "Suggestion is out of date"
            }
            return "Suggested new card"
        case .applied:
            if suggestion.isEdit { return number.map { "Card \($0) updated · To review" } ?? "Card edit applied · Target removed" }
            if let id = suggestion.createdCardID, model.cardNumbers[id] == nil { return "Card added · No longer available" }
            return "Card added · To review"
        case .dismissed:
            return suggestion.isEdit && target == nil ? "Target card no longer available" : "Suggestion dismissed"
        }
    }
}

struct ChatWordDiff: View {
    let before: String
    let after: String
    var body: some View { Text(attributed).font(.system(size: 12)).lineSpacing(3).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
    private var attributed: AttributedString {
        let old = before.split(whereSeparator: \.isWhitespace).map(String.init)
        let new = after.split(whereSeparator: \.isWhitespace).map(String.init)
        // Bounded LCS: long rewrites are clearer as old/new paragraphs and avoid quadratic work.
        guard old.count * new.count <= 40000 else { return rewrite }
        var dp = Array(repeating: Array(repeating: 0, count: new.count + 1), count: old.count + 1)
        if !old.isEmpty && !new.isEmpty {
            for i in stride(from: old.count - 1, through: 0, by: -1) {
                for j in stride(from: new.count - 1, through: 0, by: -1) { dp[i][j] = old[i] == new[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1]) }
            }
        }
        guard Double(dp[0][0]) / Double(max(1, max(old.count, new.count))) >= 0.45 else { return rewrite }
        var result = AttributedString(), i = 0, j = 0
        while i < old.count || j < new.count {
            if i < old.count, j < new.count, old[i] == new[j] { result += AttributedString(old[i] + " "); i += 1; j += 1 }
            else if j < new.count && (i == old.count || dp[i][j + 1] >= dp[i + 1][j]) { result += styled(new[j] + " ", removed: false); j += 1 }
            else { result += styled(old[i] + " ", removed: true); i += 1 }
        }
        return result
    }
    private var rewrite: AttributedString { styled(before + "\n", removed: true) + styled(after, removed: false) }
    private func styled(_ source: String, removed: Bool) -> AttributedString {
        var text = AttributedString(source)
        text.foregroundColor = removed ? Theme.diffRemovedText : Theme.diffAddedText
        text.backgroundColor = removed ? Theme.diffRemovedWash : Theme.diffAddedWash
        if removed { text.strikethroughStyle = .single }
        return text
    }
}

struct ChatEditDiff: Identifiable {
    let cardID: UUID
    let number: Int
    let oldFront: String
    let oldBack: String
    let newFront: String
    let newBack: String
    let solveChanged: Bool
    let caseEdits: [ChatSolveCaseChangeDiff]
    var id: UUID { cardID }
}

struct ChatSolveCaseChangeDiff: Identifiable {
    let caseID: UUID
    let ordinal: Int?
    let oldQuestion: String?
    let oldAnswer: String?
    let newQuestion: String
    let newAnswer: String
    let controlsChanged: Bool
    let controlChanges: [String]
    var id: UUID { caseID }
}
