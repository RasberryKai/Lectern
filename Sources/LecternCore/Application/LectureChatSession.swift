import Foundation

extension LectureSession {
    @discardableResult
    public func chat(question: String, contextRefs: [ContextRef], attachments: [ChatAttachment] = [], backend: AIBackend = .claudeCLI, model: String = "opus") async throws -> UUID {
        try await flushEdits()
        let id = try await runner.chat(moduleID: lecture.moduleID, lectureID: lecture.id, question: question, contextRefs: contextRefs, attachments: attachments, backend: backend, model: model)
        try await refresh(); return id
    }
    public func setChatDraft(_ text: String, attachments: [ChatAttachment]? = nil, chatID expectedChatID: UUID? = nil) async throws {
        if let attachments { try ChatAttachment.validateSelection(attachments) }
        let chatID = expectedChatID ?? lecture.currentChat.id
        _ = try await store.updateLecture(moduleID: lecture.moduleID, lectureID: lecture.id) { latest in
            guard latest.currentChat.id == chatID else { return }; latest.currentChat.draft = text
            if let attachments { latest.currentChat.draftAttachments = attachments }
        }; try await refresh()
    }
    public func newChat() async throws {
        _ = try await store.updateLecture(moduleID: lecture.moduleID, lectureID: lecture.id) { latest in
            guard !latest.jobs.contains(where: { ($0.kind == .chat || $0.kind == .ask) && $0.state == .running }) else { throw AIError.configuration("Stop the answer before starting another chat.") }
            if !latest.currentChat.messages.isEmpty || !latest.currentChat.draft.isEmpty || !latest.currentChat.draftAttachments.isEmpty { latest.archivedChats.insert(latest.currentChat, at: 0) }
            latest.currentChat = LectureChat()
        }; try await refresh()
    }
    public func openChat(id: UUID) async throws {
        _ = try await store.updateLecture(moduleID: lecture.moduleID, lectureID: lecture.id) { latest in
            guard !latest.jobs.contains(where: { ($0.kind == .chat || $0.kind == .ask) && $0.state == .running }) else { throw AIError.configuration("Stop the answer before switching chats.") }
            guard let index = latest.archivedChats.firstIndex(where: { $0.id == id }) else { return }
            let chat = latest.archivedChats.remove(at: index)
            if !latest.currentChat.messages.isEmpty || !latest.currentChat.draft.isEmpty || !latest.currentChat.draftAttachments.isEmpty { latest.archivedChats.insert(latest.currentChat, at: 0) }
            latest.currentChat = chat
        }; try await refresh()
    }
    public func deleteArchivedChat(id: UUID) async throws {
        _ = try await store.updateLecture(moduleID: lecture.moduleID, lectureID: lecture.id) { $0.archivedChats.removeAll { $0.id == id } }; try await refresh()
    }
    public func stopChat() async throws {
        for job in lecture.jobs where job.kind == .chat && job.state == .running {
            try await runner.stopLectureChat(moduleID: lecture.moduleID, lectureID: lecture.id, jobID: job.id)
        }; try await refresh()
    }
    public func retryChat(messageID: UUID, backend: AIBackend = .claudeCLI, model: String = "opus") async throws {
        guard let message = lecture.currentChat.messages.first(where: { $0.id == messageID }), let jobID = message.editJobID else { throw AIError.configuration("The original request is unavailable.") }
        try await runner.retryLectureChat(moduleID: lecture.moduleID, lectureID: lecture.id, jobID: jobID)
        try await refresh()
    }
    public func resolveChatEdits(messageID: UUID, apply: Bool, force: Bool = false) async throws {
        _ = try await store.updateLecture(moduleID: lecture.moduleID, lectureID: lecture.id) { latest in
            guard let m = latest.currentChat.messages.firstIndex(where: { $0.id == messageID }), let id = latest.currentChat.messages[m].editJobID, let j = latest.jobs.firstIndex(where: { $0.id == id }), latest.jobs[j].chatEditDisposition == .proposed else { return }
            if apply {
                var edits = latest.jobs[j].chatEdits ?? []
                if force {
                    for i in edits.indices { guard let card = latest.cards.first(where: { $0.id == edits[i].cardID && !$0.isSuperseded }), let revision = card.currentRevisionID else { throw LectureError.missingCard(edits[i].cardID) }; edits[i].baseRevisionID = revision }
                    latest.jobs[j].chatCardVersions = latest.cards.compactMap { c in c.currentRevisionID.map { ChatCardVersion(cardID: c.id, revisionID: $0, verdict: c.verdict, mathInterpretations: c.mathInterpretations) } }
                }
                latest.jobs[j].state = .running
                try LectureReducer.reduce(&latest, action: .applyChatEdits(jobID: id, edits: edits))
                latest.jobs[j].state = .succeeded; latest.jobs[j].chatEditDisposition = .applied
            } else { latest.jobs[j].chatEditDisposition = .dismissed }
            latest.currentChat.messages[m].pendingEdits = []; latest.currentChat.messages[m].conflictingCardIDs = []
        }; try await refresh()
    }
    public func sendFeedback(cardID: UUID, feedback: String, backend: AIBackend = .claudeCLI, model: String = "opus") async throws -> UUID {
        try await revise(cardID: cardID, feedback: feedback, backend: backend, model: model)
    }
}
