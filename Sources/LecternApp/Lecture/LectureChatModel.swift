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
    func sendChat(retrying failure: ChatPreparationFailure? = nil) async {
        guard !readOnly, runningChat == nil, !isStartingChat, !isImportingChatImages else { return }
        let question = failure?.question ?? chatDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let refs = failure?.refs ?? resolvedChatContext
        let attachments = failure?.attachments ?? chatDraftAttachments
        let chatID = lecture.currentChat.id
        guard failure == nil || failure?.chatID == chatID else { return }
        guard !question.isEmpty || !attachments.isEmpty else { return }
        let messageID = failure?.messageID ?? UUID()
        var message = ChatMessage(id: messageID, role: .user, text: question)
        message.context = refs
        message.attachments = attachments
        pendingChatMessage = PendingChatMessage(chatID: chatID, message: message)
        chatPreparationFailure = nil
        isStartingChat = true
        defer { isStartingChat = false; pendingChatMessage = nil }
        chatDraftSaveTask?.cancel()
        let submittedDraft = chatDraft
        // Clear the submitted content before any saving or context preparation can suspend.
        if failure == nil || chatDraft.trimmingCharacters(in: .whitespacesAndNewlines) == question { chatDraft = "" }
        let sentIDs = Set(attachments.map(\.id))
        chatDraftAttachments.removeAll { sentIDs.contains($0.id) }
        do {
            try await flushAllThrowing()
            _ = try await session.chat(question: question, contextRefs: refs, attachments: attachments, messageID: messageID, backend: settings.backend, model: settings.selectedModel)
        } catch {
            // A refresh can fail after the job was committed; first check for the saved message.
            try? await session.refresh()
            if lecture.currentChat.messages.contains(where: { $0.id == messageID }) {
                errorMessage = Self.describe(error)
            } else {
                chatPreparationFailure = ChatPreparationFailure(chatID: chatID, messageID: messageID, question: question, refs: refs, attachments: attachments, message: Self.describe(error))
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
        guard !readOnly, runningChat == nil, !isStartingChat, !isImportingChatImages else { return }
        chatDraftSaveTask?.cancel()
        await run { try await session.setChatDraft(chatDraft, attachments: chatDraftAttachments); try await session.newChat() }
        chatDraft = lecture.currentChat.draft
        chatDraftAttachments = lecture.currentChat.draftAttachments
        chatAttachmentError = nil
        chatPreparationFailure = nil
        chatContext = ChatContext()
        panes.openChat(mode)
    }
    func resumeChat(_ id: UUID) async {
        guard runningChat == nil, !isStartingChat, !isImportingChatImages else { return }
        if readOnly {
            readOnlyChatID = id == lecture.currentChat.id ? nil : id
            panes.openChat(mode)
            return
        }
        chatDraftSaveTask?.cancel()
        await run { try await session.setChatDraft(chatDraft, attachments: chatDraftAttachments); try await session.openChat(id: id) }
        chatDraft = lecture.currentChat.draft
        chatDraftAttachments = lecture.currentChat.draftAttachments
        chatAttachmentError = nil
        chatPreparationFailure = nil
        chatContext = ChatContext()
        panes.openChat(mode)
    }
    func deleteChat(_ id: UUID) async { guard !readOnly else { return }; await run { try await session.deleteArchivedChat(id: id) } }
    func removeChatLearningPoint(_ id: UUID) async {
        guard !readOnly else { return }
        await run {
            _ = try await app.store.updateLecture(moduleID: ref.moduleID, lectureID: ref.lectureID) { lecture in
                guard let index = lecture.learningPoints.firstIndex(where: { $0.id == id }) else { return }
                lecture.learningPoints[index].included = false
            }
            try await session.refresh()
        }
    }
    func hasChat(forPage page: Int) -> Bool { firstChatMessage(forPage: page) != nil }
    func firstChatMessage(forPage page: Int) -> (chatID: UUID, messageID: UUID)? {
        for chat in [lecture.currentChat] + lecture.archivedChats.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            if let message = chat.messages.first(where: { $0.context.contains(.slide(page)) || $0.read.contains(.slide(page)) || $0.citedPages.contains(page) }) { return (chat.id, message.id) }
        }
        return nil
    }
    func showChat(forPage page: Int) {
        askVisible = true; panes.openChat(mode)
        guard let target = firstChatMessage(forPage: page) else { return }
        Task {
            if target.chatID != displayedChat.id { await resumeChat(target.chatID) }
            chatScrollTarget = nil
            chatScrollTarget = target.messageID
        }
    }
    func fixFlagWithClaude(cardID: UUID) {
        guard !readOnly, runningChat == nil, !isStartingChat, let card = activeCards.first(where: { $0.id == cardID }) else { return }
        askVisible = true; panes.openChat(mode)
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
    func openChatCitation(_ kind: String, _ number: Int) {
        if kind == "C" { if let card = activeCards.first(where: { cardNumbers[$0.id] == number }) { openChatCard(card.id) }; return }
        guard number > 0, number <= lecture.pageCount else { return }
        if mode == .prepare { focus(number - 1) } else { enlargedPage = number }
    }
    func openChatCard(_ id: UUID) {
        reviewSearch = ""; reviewFilter = .all; setMode(.review); selectCard(id)
        panes.openChat(.review); askVisible = true
    }
    func makeCard(from message: ChatMessage) async {
        guard !readOnly else { return }
        let question = chatMessages.prefix(while: { $0.id != message.id }).last(where: { $0.role == .user })?.text ?? "Question"
        let pages = Array(Set(message.citedPages + message.read.compactMap { if case .slide(let p) = $0 { p } else { nil } })).sorted()
        let card = Card(sourcePages: pages, front: question, back: message.text)
        await dispatch(.addCards([card]))
        if activeCards.contains(where: { $0.id == card.id }) { openChatCard(card.id) }
    }
    func retryChatAnswer(_ message: ChatMessage) async {
        guard !readOnly, runningChat == nil else { return }
        await run { _ = try await session.retryChat(messageID: message.id, backend: settings.backend, model: settings.selectedModel); try await session.refresh() }
    }
    func chatEditPending(_ job: Job) -> Bool { job.chatEditDisposition == .proposed }
    func chatEditConflicted(_ job: Job) -> Bool {
        if (job.chatEdits ?? []).contains(where: { edit in !activeCards.contains(where: { $0.id == edit.cardID && $0.currentRevisionID == edit.baseRevisionID }) }) { return true }
        return (job.chatCardVersions ?? []).contains { version in
            guard (job.chatEdits ?? []).contains(where: { $0.cardID == version.cardID }) else { return false }
            return !activeCards.contains(where: { version.matches($0) })
        }
    }
    func chatEditTitle(_ job: Job) -> String {
        if job.chatEditsUndoneAt != nil { return "Changes undone" }
        if job.chatEditDisposition == .dismissed { return "Suggestions dismissed" }
        let count = job.chatEdits?.count ?? job.chatEditUndo?.count ?? 0
        if chatEditPending(job) { return chatEditConflicted(job) ? "Cards changed meanwhile · not applied" : "Suggested changes to \(count) cards" }
        return "Updated \(Format.count(count, "card")) · To review"
    }
    func chatEditDiffs(_ job: Job) -> [ChatEditDiff] {
        (job.chatEdits ?? []).compactMap { edit in
            guard let card = lecture.cards.first(where: { $0.id == edit.cardID }) else { return nil }
            let undo = job.chatEditUndo?.first(where: { $0.cardID == edit.cardID })
            let base = card.history.first(where: { $0.id == edit.baseRevisionID })
            return ChatEditDiff(cardID: card.id, number: cardNumbers[card.id] ?? 0, oldFront: undo?.front ?? base?.front ?? card.front, oldBack: undo?.back ?? base?.back ?? card.back, newFront: edit.front, newBack: edit.back)
        }
    }
    func resolveChatEdits(_ job: Job, apply: Bool) async {
        guard !readOnly, let message = chatMessages.first(where: { $0.editJobID == job.id }) else { return }
        let force = chatEditConflicted(job)
        await run {
            try await session.flushEdits()
            try await session.resolveChatEdits(messageID: message.id, apply: apply, force: force)
            try await session.refresh()
        }
        syncEditor(); app.scheduleReload()
    }
}
