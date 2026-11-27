import Foundation
import LecternCore

struct ChatMention: Identifiable {
    let label: String
    let icon: String
    let ref: ContextRef?
    var id: String { ref.map(String.init(describing:)) ?? "screen" }
}

struct ChatPreparationFailure {
    let chatID: UUID
    let messageID: UUID
    let question: String
    let refs: [ContextRef]
    let attachments: [ChatAttachment]
    let allowsCardCreation: Bool
    let message: String
}

struct PendingChatMessage {
    let chatID: UUID
    let message: ChatMessage
}

extension LectureWindowModel {
    var displayedChat: LectureChat {
        if let id = readOnlyChatID, let chat = lecture.archivedChats.first(where: { $0.id == id }) { return chat }
        return lecture.currentChat
    }
    var earlierChats: [LectureChat] {
        ([lecture.currentChat] + lecture.archivedChats).filter { $0.id != displayedChat.id && (!$0.messages.isEmpty || !$0.draft.isEmpty || !$0.draftAttachments.isEmpty) }.sorted { $0.updatedAt > $1.updatedAt }
    }
    var chatMessages: [ChatMessage] {
        let messages = displayedChat.messages
        guard let pendingChatMessage, displayedChat.id == pendingChatMessage.chatID,
              !messages.contains(where: { $0.id == pendingChatMessage.message.id }) else { return messages }
        return messages + [pendingChatMessage.message]
    }
    var chatLearningPoints: [LearningPoint] { lecture.learningPoints }
    /// Card drafts from understood explanations the student hasn't added or skipped yet: what the drawer above the composer shows.
    /// Older points without a draft still wait here for Keep or Drop.
    var newChatLearningPoints: [LearningPoint] { lecture.learningPoints.filter { $0.included && !$0.reviewed && ($0.cardIDs ?? []).isEmpty } }
    /// Points whose discussion ended at this message: the chat marks the end of the concept there.
    func pointsEnding(at messageID: UUID) -> [LearningPoint] { lecture.learningPoints.filter { $0.episodeEndMessageID == messageID } }
    func cardNumber(replacedBy point: LearningPoint) -> Int? { point.draft?.replacesCardID.flatMap { cardNumbers[$0] } }
    var runningChat: Job? { runningJobs.first { $0.kind == .chat || $0.kind == .ask } }
    var chatFailures: [Job] {
        lecture.jobs.filter { ($0.kind == .chat || $0.kind == .ask) && $0.threadID == displayedChat.id && [.failed, .interrupted].contains($0.state) && !dismissedJobIDs.contains($0.id) }
    }
    var screenChatContext: [ContextRef] {
        if mode == .review, let card = selectedCard {
            let pages = card.sourcePages
            let page = pages.isEmpty ? nil : pages[min(max(0, sourceIndex), pages.count - 1)]
            return [.card(card.id)] + (page.map { [.slide($0)] } ?? [])
        }
        return focusedPage.map { [.slide($0)] } ?? []
    }
    var resolvedChatContext: [ContextRef] {
        var refs = chatContext.followsScreen ? visibleScreenChatContext : []
        for pin in chatContext.pins where !refs.contains(pin) { refs.append(pin) }
        return refs
    }
    var visibleScreenChatContext: [ContextRef] {
        screenChatContext.filter { ref in
            switch ref {
            case .slide: !chatContext.pins.contains(.allSlides)
            case .card: !chatContext.pins.contains(.allCards)
            default: true
            }
        }
    }
    func contextLabel(_ ref: ContextRef) -> String {
        switch ref {
        case .slide(let page): "Slide \(page)"
        case .card(let id): cardNumbers[id].map { "Card \($0)" } ?? "Deleted card"
        case .allSlides: "All slides"
        case .allCards: "All cards"
        }
    }
    func chatContextLabel(_ refs: [ContextRef]) -> String { refs.map(contextLabel).joined(separator: " · ") }
    var chatMentions: [ChatMention] {
        [ChatMention(label: "What I’m looking at", icon: "viewfinder", ref: nil),
         ChatMention(label: "All slides", icon: "rectangle.stack", ref: .allSlides),
         ChatMention(label: "All cards", icon: "rectangle.on.rectangle", ref: .allCards)]
        + lecture.slides.map { ChatMention(label: "Slide \($0.pageIndex + 1)", icon: "document", ref: .slide($0.pageIndex + 1)) }
        + activeCards.map { ChatMention(label: "Card \(cardNumbers[$0.id] ?? 0) · \($0.front)", icon: "rectangle", ref: .card($0.id)) }
    }
    func setChatDraft(_ text: String) {
        chatDraft = text
        chatDraftSaveTask?.cancel()
        guard !readOnly else { return }
        let chatID = lecture.currentChat.id
        let attachments = chatDraftAttachments
        chatDraftSaveTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(350))
                guard let self, self.lecture.currentChat.id == chatID else { return }
                try await self.session.setChatDraft(text, attachments: attachments, chatID: chatID)
            } catch is CancellationError {} catch { self?.errorMessage = Self.describe(error) }
        }
    }
    func sendChat(retrying failure: ChatPreparationFailure? = nil, offersAskActivity: Bool = false) async {
        guard !readOnly, runningChat == nil, !isStartingChat, !isImportingChatImages, !isShowingAskActivity else { return }
        let question = failure?.question ?? chatDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let refs = failure?.refs ?? resolvedChatContext
        let attachments = failure?.attachments ?? chatDraftAttachments
        let allowsCardCreation = failure?.allowsCardCreation ?? (mode == .review && studySolveContext == nil)
        let studyContext = studySolveContext
        let chatID = lecture.currentChat.id
        let sourcePage = screenChatContext.compactMap { ref -> Int? in
            if case .slide(let page) = ref { return page }
            return nil
        }.first
        guard failure == nil || failure?.chatID == chatID else { return }
        guard !question.isEmpty || !attachments.isEmpty else { return }
        let messageID = failure?.messageID ?? UUID()
        let turn = AskTurn(chatID: chatID, questionID: messageID)
        let activity = offersAskActivity && failure == nil && app.adhdModeEnabled ? app.adhdModeActivity.activity() : nil
        var message = ChatMessage(id: messageID, role: .user, text: question)
        message.context = refs
        message.attachments = attachments
        pendingChatMessage = PendingChatMessage(chatID: chatID, message: message)
        chatPreparationFailure = nil
        isStartingChat = true
        waitTowerTask?.cancel()
        if activity == .tower { scheduleWaitTower(for: turn) }
        defer { isStartingChat = false; pendingChatMessage = nil }
        chatDraftSaveTask?.cancel()
        let submittedDraft = chatDraft
        // Clear the submitted content before any saving or context preparation can suspend.
        if failure == nil || chatDraft.trimmingCharacters(in: .whitespacesAndNewlines) == question { chatDraft = "" }
        let sentIDs = Set(attachments.map(\.id))
        chatDraftAttachments.removeAll { sentIDs.contains($0.id) }
        do {
            try await flushAllThrowing()
            if activity == .flashcard, app.adhdModeEnabled {
                await beginAskFlashcard(turn: turn, sourcePage: sourcePage)
            }
            _ = try await session.chat(question: question, contextRefs: refs, attachments: attachments,
                                       messageID: messageID, backend: settings.backend, model: settings.selectedModel,
                                       allowsCardCreation: allowsCardCreation, studyExerciseContext: studyContext)
        } catch {
            // A refresh can fail after the job was committed; first check for the saved message.
            try? await session.refresh()
            if lecture.currentChat.messages.contains(where: { $0.id == messageID }) {
                errorMessage = Self.describe(error)
            } else {
                askFlashcard = nil
                waitTowerTask?.cancel()
                chatPreparationFailure = ChatPreparationFailure(chatID: chatID, messageID: messageID, question: question, refs: refs, attachments: attachments, allowsCardCreation: allowsCardCreation, message: Self.describe(error))
                // Keep a newer draft intact; the failure retains the original request for retry.
                if chatDraft.isEmpty && chatDraftAttachments.isEmpty {
                    chatDraft = failure == nil ? submittedDraft : question
                    chatDraftAttachments = attachments
                }
            }
        }
        chatDraftSaveTask?.cancel()
        do { try await session.setChatDraft(chatDraft, attachments: chatDraftAttachments, chatID: chatID) }
        catch { errorMessage = Self.describe(error) }
        app.scheduleReload()
    }
    func newChat() async {
        guard !readOnly, runningChat == nil, !isStartingChat, !isImportingChatImages, !isShowingAskActivity else { return }
        let leavingChatID = displayedChat.id
        chatDraftSaveTask?.cancel()
        await run { try await session.setChatDraft(chatDraft, attachments: chatDraftAttachments); try await session.newChat(backend: settings.backend, model: settings.selectedModel) }
        if displayedChat.id != leavingChatID { clearAskActivity() }
        chatDraft = lecture.currentChat.draft
        chatDraftAttachments = lecture.currentChat.draftAttachments
        chatAttachmentError = nil
        chatPreparationFailure = nil
        chatContext = ChatContext()
        showAsk()
    }
    func resumeChat(_ id: UUID) async {
        guard runningChat == nil, !isStartingChat, !isImportingChatImages, !isShowingAskActivity else { return }
        if readOnly {
            readOnlyChatID = id == lecture.currentChat.id ? nil : id
            return
        }
        let leavingChatID = displayedChat.id
        chatDraftSaveTask?.cancel()
        await run { try await session.setChatDraft(chatDraft, attachments: chatDraftAttachments); try await session.openChat(id: id, backend: settings.backend, model: settings.selectedModel) }
        if displayedChat.id != leavingChatID { clearAskActivity() }
        chatDraft = lecture.currentChat.draft
        chatDraftAttachments = lecture.currentChat.draftAttachments
        chatAttachmentError = nil
        chatPreparationFailure = nil
        chatContext = ChatContext()
    }
    func deleteChat(_ id: UUID) async { guard !readOnly else { return }; await run { try await session.deleteArchivedChat(id: id) } }
    func removeChatLearningPoint(_ id: UUID) async {
        guard !readOnly else { return }
        await run { try await session.dispatch(.skipLearningPoint(pointID: id)) }
    }
    func keepChatLearningPoints(_ ids: [UUID]) async {
        guard !readOnly, !ids.isEmpty else { return }
        await run {
            _ = try await app.store.updateLecture(moduleID: ref.moduleID, lectureID: ref.lectureID) { lecture in
                for index in lecture.learningPoints.indices where ids.contains(lecture.learningPoints[index].id) { lecture.learningPoints[index].reviewed = true }
            }
            try await session.refresh()
        }
    }
    /// Adds the card (or applies it to the card it improves). Edited text replaces the draft.
    func addChatCardDraft(_ point: LearningPoint, front: String? = nil, back: String? = nil) async {
        guard !readOnly, let draft = point.draft else { return }
        await run { try await session.dispatch(.acceptLearningPointDraft(pointID: point.id, front: front ?? draft.front, back: back ?? draft.back)) }
    }
    func addAllChatCardDrafts() async {
        guard !readOnly else { return }
        let drafts = newChatLearningPoints.filter { $0.draft != nil }
        let legacy = newChatLearningPoints.filter { $0.draft == nil }.map(\.id)
        await run {
            for point in drafts { try await session.dispatch(.acceptLearningPointDraft(pointID: point.id, front: point.draft!.front, back: point.draft!.back)) }
        }
        await keepChatLearningPoints(legacy)
    }
    func toggleClicked(_ message: ChatMessage) async {
        guard !readOnly else { return }
        await run { try await session.setAnswerClicked(messageID: message.id, clicked: !message.clicked, backend: settings.backend, model: settings.selectedModel) }
    }
    func resolveSuggestion(_ message: ChatMessage, apply: Bool) async {
        guard !readOnly else { return }
        await run {
            try await session.flushEdits()
            try await session.dispatch(.resolveCardSuggestion(chatID: displayedChat.id, messageID: message.id, apply: apply))
        }
        syncEditor(); app.scheduleReload()
    }
    func hasChat(forPage page: Int) -> Bool { firstChatMessage(forPage: page) != nil }
    func firstChatMessage(forPage page: Int) -> (chatID: UUID, messageID: UUID)? {
        for chat in [lecture.currentChat] + lecture.archivedChats.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            if let message = chat.messages.first(where: { $0.context.contains(.slide(page)) || $0.read.contains(.slide(page)) || $0.citedPages.contains(page) }) { return (chat.id, message.id) }
        }
        return nil
    }
    func showChat(forPage page: Int) {
        showAsk()
        guard let target = firstChatMessage(forPage: page) else { return }
        Task {
            if target.chatID != displayedChat.id { await resumeChat(target.chatID) }
            chatScrollTarget = nil
            chatScrollTarget = target.messageID
        }
    }
    /// Opens the chat at the discussion a learning point came from.
    func showChat(for point: LearningPoint) {
        showAsk()
        guard let target = chatLocation(for: point) else {
            errorMessage = "The source chat for this card is no longer available."
            return
        }
        Task {
            if target.chatID != displayedChat.id { await resumeChat(target.chatID) }
            guard displayedChat.id == target.chatID,
                  displayedChat.messages.contains(where: { $0.id == target.messageID }) else {
                errorMessage = "The source chat for this card is no longer available."
                return
            }
            chatScrollTarget = nil
            chatScrollTarget = target.messageID
        }
    }
    func canShowChat(for point: LearningPoint) -> Bool { chatLocation(for: point) != nil }
    private func chatLocation(for point: LearningPoint) -> (chatID: UUID, messageID: UUID)? {
        guard let messageID = point.episodeEndMessageID ?? point.evidence?.last?.messageID,
              let chat = ([lecture.currentChat] + lecture.archivedChats).first(where: { $0.messages.contains { $0.id == messageID } }) else { return nil }
        return (chat.id, messageID)
    }
    func fixFlagWithClaude(cardID: UUID) {
        guard !readOnly, runningChat == nil, !isStartingChat, !isShowingAskActivity,
              let card = activeCards.first(where: { $0.id == cardID }) else { return }
        showAsk()
        let question = "Fix this flag on Card \(cardNumbers[cardID] ?? 0): \(card.flag ?? card.issue?.message ?? "Check this card for accuracy and clarity.")"
        let refs: [ContextRef] = [.card(cardID)] + card.sourcePages.map(ContextRef.slide)
        isStartingChat = true
        Task {
            defer { isStartingChat = false }
            await run {
                try await flushAllThrowing()
                _ = try await session.chat(question: question, contextRefs: refs, backend: settings.backend, model: settings.selectedModel)
                try await session.setChatDraft(chatDraft, attachments: chatDraftAttachments)
                try await session.refresh()
            }
            app.scheduleReload()
        }
    }
    func dismissFlag(cardID: UUID) {
        guard !readOnly else { return }
        Task { await run {
            _ = try await app.store.updateLecture(moduleID: ref.moduleID, lectureID: ref.lectureID) { lecture in
                guard let index = lecture.cards.firstIndex(where: { $0.id == cardID }) else { return }; lecture.cards[index].flag = nil
            }
            try await session.refresh()
        } }
    }
    func openChatCitation(_ citation: ChatCitation, jobID: UUID?) {
        switch citation {
        case .slide(let page):
            guard page > 0, page <= lecture.pageCount else {
                errorMessage = "This cited slide is no longer available."
                return
            }
            jumpToPrepare(page: page)
            showAsk()
        case .card(let number):
            guard let id = lecture.chatCitationCardID(number: number, jobID: jobID) else {
                errorMessage = "This cited card is no longer available."
                return
            }
            openChatCard(id)
        }
    }
    func previewLearningPointSlide(_ page: Int) {
        guard page > 0, page <= lecture.pageCount else { return }
        if mode == .prepare { focus(page - 1) } else { enlargedPage = page }
    }
    func openChatCard(_ id: UUID) {
        showReviewCard(id)
        showAsk()
    }
    func resolveChatDeletions(chatID: UUID, messageID: UUID, cardIDs: Set<UUID>, delete: Bool) async {
        guard !readOnly else { return }
        await run {
            try await session.flushEdits()
            do {
                try await session.dispatch(.resolveChatDeletions(chatID: chatID, messageID: messageID, cardIDs: cardIDs, delete: delete))
            } catch {
                try? await session.refresh()
                throw error
            }
            if delete {
                chatContext.pins.removeAll { ref in
                    if case .card(let id) = ref { return cardIDs.contains(id) }
                    return false
                }
            }
        }
        syncEditor()
        app.scheduleReload()
    }
    func retryChatAnswer(_ message: ChatMessage) async {
        guard !readOnly, runningChat == nil, !isShowingAskActivity else { return }
        if askFlashcardJobID == message.editJobID { askFlashcard = nil }
        await run { _ = try await session.retryChat(messageID: message.id, backend: settings.backend, model: settings.selectedModel); try await session.refresh() }
    }
    func chatEditPending(_ job: Job) -> Bool { job.chatEditDisposition == .proposed }
    func chatEditHasFlipReplacement(_ job: Job) -> Bool {
        (job.chatEdits ?? []).contains(where: \.replacesFlipCard)
    }
    func chatEditHasCaseConflict(_ job: Job) -> Bool {
        (job.chatEdits ?? []).contains { edit in
            guard let caseEdits = edit.caseEdits, !caseEdits.isEmpty else { return false }
            guard let card = activeCards.first(where: { $0.id == edit.cardID }), let solve = card.solve else { return true }
            guard card.currentRevisionID == edit.baseRevisionID,
                  job.chatCardVersions?.first(where: { $0.cardID == card.id })?.matches(card) == true else { return true }
            return caseEdits.contains { change in
                guard let target = solve.cases.first(where: { $0.id == change.caseID }) else { return true }
                return target.retired || ChatSolveCaseEdit.contentHash(target.content) != change.baseContentHash
            }
        }
    }
    func chatEditConflicted(_ job: Job) -> Bool {
        if chatEditHasFlipReplacement(job) {
            if job.pdfLayoutRevision != lecture.pdfLayoutRevision { return true }
            let replacements = (job.chatEdits ?? []).filter(\.replacesFlipCard)
            if replacements.contains(where: { edit in
                !activeCards.contains(where: { $0.id == edit.cardID && $0.solve == nil })
            }) { return true }
        }
        if (job.chatEdits ?? []).contains(where: { edit in !activeCards.contains(where: { $0.id == edit.cardID && $0.currentRevisionID == edit.baseRevisionID }) }) { return true }
        if chatEditHasCaseConflict(job) { return true }
        return (job.chatCardVersions ?? []).contains { version in
            guard (job.chatEdits ?? []).contains(where: { $0.cardID == version.cardID }) else { return false }
            return !activeCards.contains(where: { version.matches($0) })
        }
    }
    func chatEditTitle(_ job: Job) -> String {
        if job.chatEditsUndoneAt != nil { return "Changes undone" }
        if job.chatEditDisposition == .dismissed { return "Suggestions dismissed" }
        let edits = job.chatEdits ?? []
        let replacementCount = edits.filter(\.replacesFlipCard).count
        let caseCount = edits.reduce(0) { $0 + ($1.caseEdits?.count ?? 0) }
        let cardCount = edits.filter { $0.caseEdits?.isEmpty != false }.count
        if chatEditPending(job) {
            if chatEditConflicted(job) {
                return chatEditHasFlipReplacement(job)
                    ? "Replacement needs a fresh proposal"
                    : "Cards or cases changed meanwhile · not applied"
            }
            if replacementCount > 0 {
                return "Approval needed to replace \(Format.count(replacementCount, "flip card"))"
            }
            if caseCount > 0 && cardCount > 0 { return "Suggested changes to \(Format.count(caseCount, "solve case")) and \(Format.count(cardCount, "card"))" }
            if caseCount > 0 { return "Suggested changes to \(Format.count(caseCount, "solve case"))" }
            return "Suggested changes to \(Format.count(cardCount, "card"))"
        }
        if replacementCount > 0, job.chatEditDisposition == .applied {
            let solveNoun = replacementCount == 1 ? "a solve card" : "solve cards"
            let status = "Replaced \(Format.count(replacementCount, "flip card")) with \(solveNoun) · Approved"
            let otherCardCount = cardCount - replacementCount
            return otherCardCount > 0 ? "\(status). Other card edits need review." : status
        }
        if caseCount > 0 && cardCount == 0 { return "Updated \(Format.count(caseCount, "solve case"))" }
        if caseCount > 0 { return "Updated \(Format.count(caseCount, "solve case")) and \(Format.count(cardCount, "card")) · To review" }
        return "Updated \(Format.count(cardCount, "card")) · To review"
    }
    func chatEditDiffs(_ job: Job) -> [ChatEditDiff] {
        (job.chatEdits ?? []).compactMap { edit -> ChatEditDiff? in
            guard let card = lecture.cards.first(where: { $0.id == edit.cardID }) else { return nil }
            let undo = job.chatEditUndo?.first(where: { $0.cardID == edit.cardID })
            let base = card.history.first(where: { $0.id == edit.baseRevisionID })
            let oldSolve = edit.solve == nil ? nil : undo?.solve?.draft ?? base?.solve ?? card.solve?.draft
            let caseSource = undo?.solve ?? card.solve
            let caseDiffs = (edit.caseEdits ?? []).map { change in
                let original = caseSource?.cases.first(where: { $0.id == change.caseID })
                let ordinal = caseSource?.cases.firstIndex(where: { $0.id == change.caseID }).map { $0 + 1 }
                let controlChanges = Self.solveCaseControlChanges(from: original?.content, to: change.content)
                return ChatSolveCaseChangeDiff(
                    caseID: change.caseID, ordinal: ordinal,
                    oldQuestion: original?.content.staticQuestion,
                    oldAnswer: original?.content.staticAnswer,
                    newQuestion: change.content.staticQuestion,
                    newAnswer: change.content.staticAnswer,
                    controlsChanged: original?.content != change.content,
                    controlChanges: controlChanges
                )
            }
            return ChatEditDiff(
                cardID: card.id, number: cardNumbers[card.id] ?? 0,
                oldFront: oldSolve?.sample.staticQuestion ?? undo?.front ?? base?.front ?? card.front,
                oldBack: oldSolve?.sample.staticAnswer ?? undo?.back ?? base?.back ?? card.back,
                newFront: edit.solve?.sample.staticQuestion ?? edit.front,
                newBack: edit.solve?.sample.staticAnswer ?? edit.back,
                solveChanged: oldSolve != edit.solve, caseEdits: caseDiffs
            )
        }
    }

    private static func solveCaseControlChanges(from old: SolveCaseContent?, to new: SolveCaseContent) -> [String] {
        guard let old else { return [] }
        var changes: [String] = []
        func change(_ label: String, _ before: String, _ after: String) {
            if before != after { changes.append("\(label): \(before) → \(after)") }
        }
        func yesNo(_ value: Bool) -> String { value ? "On" : "Off" }
        func inputChanges(_ oldInput: SolveInput, _ newInput: SolveInput, name: String) {
            change("\(name) answer type", oldInput.kind.rawValue, newInput.kind.rawValue)
            change("\(name) accepted formats", oldInput.acceptedFormats.map(\.label).joined(separator: ", "), newInput.acceptedFormats.map(\.label).joined(separator: ", "))
            change("\(name) tolerance", oldInput.tolerance.map { String(format: "%.4g", $0) } ?? "0", newInput.tolerance.map { String(format: "%.4g", $0) } ?? "0")
            change("\(name) unit", oldInput.unit ?? "none", newInput.unit ?? "none")
            change("\(name) decimal places", oldInput.decimalPlaces.map(String.init) ?? "none", newInput.decimalPlaces.map(String.init) ?? "none")
            change("\(name) language", oldInput.language ?? "en_US_POSIX (default)", newInput.language ?? "en_US_POSIX (default)")
            change("\(name) case sensitive", yesNo(oldInput.ignoreCase == false), yesNo(newInput.ignoreCase == false))
            change("\(name) ignored articles", oldInput.articles?.joined(separator: ", ") ?? "none", newInput.articles?.joined(separator: ", ") ?? "none")
            change("\(name) allow typos", yesNo(oldInput.allowTypo == true), yesNo(newInput.allowTypo == true))
            change("\(name) tone marks required", yesNo(oldInput.tonesMatter ?? true), yesNo(newInput.tonesMatter ?? true))
        }
        func inputSummary(_ input: SolveInput) -> String {
            [
                "type: \(input.kind.rawValue)",
                "formats: \(input.acceptedFormats.map(\.label).joined(separator: ", "))",
                "tolerance: \(input.tolerance.map(String.init(describing:)) ?? "0")",
                "unit: \(input.unit ?? "none")",
                "decimal places: \(input.decimalPlaces.map(String.init) ?? "none")",
                "language: \(input.language ?? "default")",
                "case sensitive: \(yesNo(input.ignoreCase == false))",
                "ignored articles: \(input.articles?.joined(separator: ", ") ?? "none")",
                "allow typos: \(yesNo(input.allowTypo == true))",
                "tone marks required: \(yesNo(input.tonesMatter ?? true))"
            ].joined(separator: " · ")
        }
        func fieldName(_ field: SolveField, _ index: Int) -> String {
            let prompt = field.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            return prompt.isEmpty ? "Part \(index + 1)" : prompt
        }
        func controlType(_ field: SolveField?) -> String {
            guard let field else { return "none" }
            if let input = field.input { return "\(input.kind.rawValue) input" }
            if field.choice != nil { return "choice" }
            if field.order != nil { return "order" }
            if field.grid != nil { return "grid" }
            return "none"
        }
        func controlSummary(_ field: SolveField) -> String {
            if let input = field.input { return inputSummary(input) }
            if let choice = field.choice {
                return "multiple answers: \(yesNo(choice.multiple)) · shuffle options: \(yesNo(choice.shuffle))"
            }
            if let grid = field.grid {
                var settings = ["shuffle options: \(yesNo(grid.shuffle))", "row order matters: \(yesNo(grid.rowOrderMatters))"]
                for (row, cells) in grid.rows.enumerated() {
                    for (column, input) in cells.enumerated() {
                        settings.append("row \(row + 1), column \(column + 1): \(inputSummary(input))")
                    }
                }
                return settings.joined(separator: " · ")
            }
            return "ordering"
        }
        for index in 0..<max(old.fields.count, new.fields.count) {
            let before = old.fields.indices.contains(index) ? old.fields[index] : nil
            let after = new.fields.indices.contains(index) ? new.fields[index] : nil
            let name = (after ?? before).map { fieldName($0, index) } ?? "Part \(index + 1)"
            change("\(name) control", controlType(before), controlType(after))
            if controlType(before) != controlType(after) {
                change("\(name) settings", before.map(controlSummary) ?? "none", after.map(controlSummary) ?? "none")
            }
            guard let before, let after else {
                continue
            }
            switch (before.input, after.input) {
            case (.some(let oldInput), .some(let newInput)):
                inputChanges(oldInput, newInput, name: name)
            case (.some(let input), nil): change("\(name) input settings", inputSummary(input), "none")
            case (nil, .some(let input)): change("\(name) input settings", "none", inputSummary(input))
            case (nil, nil): break
            }
            if let oldChoice = before.choice, let newChoice = after.choice {
                change("\(name) multiple answers", yesNo(oldChoice.multiple), yesNo(newChoice.multiple))
                change("\(name) shuffle options", yesNo(oldChoice.shuffle), yesNo(newChoice.shuffle))
            }
            if let oldGrid = before.grid, let newGrid = after.grid {
                change("\(name) shuffle options", yesNo(oldGrid.shuffle), yesNo(newGrid.shuffle))
                change("\(name) row order matters", yesNo(oldGrid.rowOrderMatters), yesNo(newGrid.rowOrderMatters))
                for rowIndex in 0..<max(oldGrid.rows.count, newGrid.rows.count) {
                    let oldRow = oldGrid.rows.indices.contains(rowIndex) ? oldGrid.rows[rowIndex] : []
                    let newRow = newGrid.rows.indices.contains(rowIndex) ? newGrid.rows[rowIndex] : []
                    let oldRowLabel = oldGrid.rowLabels.flatMap { $0.indices.contains(rowIndex) ? $0[rowIndex] : nil }
                    let newRowLabel = newGrid.rowLabels.flatMap { $0.indices.contains(rowIndex) ? $0[rowIndex] : nil }
                    let rowName = newRowLabel ?? oldRowLabel ?? "row \(rowIndex + 1)"
                    for columnIndex in 0..<max(oldRow.count, newRow.count) {
                        let oldInput = oldRow.indices.contains(columnIndex) ? oldRow[columnIndex] : nil
                        let newInput = newRow.indices.contains(columnIndex) ? newRow[columnIndex] : nil
                        let columnName = newGrid.columns.indices.contains(columnIndex) ? newGrid.columns[columnIndex]
                            : oldGrid.columns.indices.contains(columnIndex) ? oldGrid.columns[columnIndex]
                            : "column \(columnIndex + 1)"
                        let cellName = "\(name), \(rowName), \(columnName)"
                        switch (oldInput, newInput) {
                        case (.some(let oldInput), .some(let newInput)):
                            inputChanges(oldInput, newInput, name: cellName)
                        case (.some(let input), nil): change("\(cellName) input settings", inputSummary(input), "none")
                        case (nil, .some(let input)): change("\(cellName) input settings", "none", inputSummary(input))
                        case (nil, nil): break
                        }
                    }
                }
            }
        }
        return changes
    }

    func resolveChatEdits(_ job: Job, apply: Bool) async {
        guard !readOnly,
              let message = chatMessages.first(where: { $0.role == .assistant && $0.editJobID == job.id }) else { return }
        if apply, chatEditHasFlipReplacement(job), chatEditConflicted(job) {
            errorMessage = job.pdfLayoutRevision != lecture.pdfLayoutRevision
                ? "The slide order changed. Dismiss this proposal and ask again."
                : "A card changed. Dismiss this proposal and ask again."
            return
        }
        let force = !chatEditHasFlipReplacement(job) && chatEditConflicted(job)
        await run {
            try await session.flushEdits()
            try await session.resolveChatEdits(messageID: message.id, apply: apply, force: force)
            try await session.refresh()
        }
        syncEditor(); app.scheduleReload()
    }
}
