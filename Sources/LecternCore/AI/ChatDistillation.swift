import Foundation
import PDFKit

/// What started a background pass over a lecture chat.
public enum ChatDistillationTrigger: Equatable, Sendable {
    /// An answer landed: update the summary, judge the student's latest reaction.
    case answer(jobID: UUID)
    /// The student marked an answer as the explanation that worked.
    case clicked(messageID: UUID)
    /// The chat was left (New chat, another chat opened, or idle): every open discussion ends.
    case chatEnded
}

struct ChatDistillationRequest: Sendable {
    var moduleID: UUID
    var lectureID: UUID
    var chatID: UUID
    var backend: AIBackend
    var model: String
    var trigger: ChatDistillationTrigger
}

/// Learning points (Prepare) and card suggestions (Review) are judged by what the student does next,
/// never at the moment an answer lands. Both run here, after the fact, on Sonnet.
enum ChatDistillationRules {
    static let window = 30
    static let maximumPoints = 4

    static func isCardContext(_ refs: [ContextRef]) -> Bool {
        refs.contains { if case .card = $0 { true } else if case .allCards = $0 { true } else { false } }
    }

    /// Prepare messages are slide conversations. Review chat and card-context chat never make learning points.
    static func isPrepare(_ message: ChatMessage, in lecture: Lecture) -> Bool {
        guard let id = message.editJobID, let job = lecture.jobs.first(where: { $0.id == id }) else { return false }
        return job.kind == .chat && job.allowsCardCreation != true && !isCardContext(message.context)
    }
    static func isReview(_ message: ChatMessage, in lecture: Lecture) -> Bool {
        guard let id = message.editJobID, let job = lecture.jobs.first(where: { $0.id == id }) else { return false }
        return job.kind == .chat && job.allowsCardCreation == true
    }

    static func normalized(_ text: String) -> String {
        let stripped = text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "“", with: "\"").replacingOccurrences(of: "”", with: "\"")
            .replacingOccurrences(of: "‘", with: "'").replacingOccurrences(of: "’", with: "'")
        return stripped.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
    /// A quote must appear word for word in the message. "…" may skip text between parts.
    static func quote(_ quote: String, appearsIn text: String) -> Bool {
        let haystack = normalized(text)
        let parts = quote.replacingOccurrences(of: "...", with: "…").split(separator: "…")
            .map { normalized(String($0)).trimmingCharacters(in: CharacterSet(charactersIn: " \"'.,;:!?")) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty, parts.joined(separator: " ").count >= 4 else { return false }
        var searchStart = haystack.startIndex
        for part in parts {
            guard let range = haystack.range(of: part, range: searchStart..<haystack.endIndex) else { return false }
            searchStart = range.upperBound
        }
        return true
    }

    static func readPages(of messages: [ChatMessage], pageCount: Int) -> Set<Int> {
        var pages = Set<Int>()
        for ref in messages.flatMap({ $0.context + $0.read }) {
            switch ref {
            case .slide(let page) where page > 0 && page <= pageCount: pages.insert(page)
            case .allSlides where pageCount > 0: pages.formUnion(1...pageCount)
            default: break
            }
        }
        return pages
    }

    static let pointInstructions = """
    You judge which explanations in this study chat the student actually understood, and turn only those into learning points with a flashcard draft. The flashcards are generated from these points, so a wrong point teaches the wrong thing: when in doubt, return nothing.

    Split CHAT into discussions: consecutive turns about one concept. A discussion has ENDED when a later student message moves to a different concept, when an assistant answer in it is marked clicked, or when DISCUSSION STATE says the chat is over. Otherwise the last discussion is still open: return nothing for it.

    Read every student message after an answer as a reaction to that answer:
    - Lost: "don't get", "still", "??", "simpler", "again", "like what is", "what do you mean", "that doesn't make sense", an example of the same thing, or the answer's main claim asked again in other words. That answer failed: no point from it. Count it in difficulty.
    - Check ("so X?", "meaning X", "X, right?"): if the AI agreed, the student understood it in their own words (ownWords). If the AI said "not quite" or corrected part of it, it is a misconception (misconception): the point states the wrong belief and the right one, "Not X: Y".
    - The student corrects the AI and the AI agrees: ownWords.
    - New target: a term the answer introduced, an application, an edge case, a why or what-if. The previous answer landed (understood).
    - Already knew ("I got that part, the only thing..."): no point from that answer; the gap they name is the target.
    - Formatting, card or study-method talk: no signal, never a point.
    - Clicked answer: it landed, whatever followed.
    - A discussion that ends without a reaction: understood only if the student asked a specific question. Broad requests ("explain this slide", "give me the gist", "summarize", "simplify each one", "explain these three") with no specific follow-up give no point.

    Rules:
    - Zero points is the default. At most one point per ended discussion; two only when it holds a corrected misconception and a separate insight. At most 4 in total.
    - Write the point from the chat, never from slide text: the insight that resolved the student's gap, at most 30 words, the transferable principle only, no worked examples or example numbers. Prefer the student's own words when they restated it correctly.
    - evidence: copy verbatim, at most 20 words, the student message that proves your verdict (a clicked answer may stand in when the student said nothing more). messageID must be a CHAT id. Optionally add the answer that worked.
    - difficulty: lost follow-ups before it landed, 0 to 3. endMessageID: the last message of that discussion.
    - front/back: one short atomic flashcard that tests the point: a short question, a short answer. A misconception card contrasts the trap with the truth.
    - replacesCardID: when an EXISTING CARD already tests this concept but misses what the student needed, give its id and write the improved card. When an existing card already covers it fully, return no point.
    - mergesPointID: when an EXISTING POINT covers the same idea, give its id and a sharper version instead of a new point. Never repeat or reintroduce an excluded point.
    - pages: the slides the discussion is about, only from READ SLIDES. Check facts against READ SLIDES and omit anything they don't support. Never turn a false student guess into a fact.
    - closedThroughMessageID: the last message of the last ended discussion, or null when none has ended.
    """

    static let suggestionInstructions = """
    You decide whether this Review conversation should change a flashcard. The student studies their cards here and asks about them.

    Recommend at most one change, and only when this conversation shows a card failed the student and an explanation then worked:
    - the student marked an answer clicked (that answer is TARGET), or
    - the student's latest message shows the previous explanation landed: they restated it and the AI agreed, said it makes sense, or moved on to something else, or
    - the student corrected a card's content and the AI agreed.
    Never while the student is still confused. Never for formatting, length or style requests: those are handled directly. Never when LATEST EXCHANGE CHANGED CARDS is true, unless TARGET is clicked.

    Prefer editing the discussed card: give its cardID and baseRevisionID from DISCUSSED CARDS and the complete new front and back. Suggest a new card (cardID and baseRevisionID null) only for a separate concept that no card in ALL CARD FRONTS tests. Write from the explanation that worked, in the student's words where possible. Keep the card short and atomic, in the style of the existing cards. reason: one short sentence the student will read, such as "The due/default difference is what made this card click."
    sourceSlides: only from READ SLIDES; for an edit keep the card's sources unless the explanation relied on others.
    Return suggestion null when none of this applies. Null is the usual answer.
    """
}

extension JobRunner {
    /// Marks or unmarks an answer as the explanation that worked. Marking it starts a background pass:
    /// learning points in Prepare, a card suggestion in Review.
    public func setChatAnswerClicked(moduleID: UUID, lectureID: UUID, messageID: UUID, clicked: Bool,
                                     backend: AIBackend = .claudeCLI, model: String = "opus") async throws {
        try await store.assertModuleEditable(moduleID: moduleID)
        let updated = try await store.updateLecture(moduleID: moduleID, lectureID: lectureID) { lecture in
            if let m = lecture.currentChat.messages.firstIndex(where: { $0.id == messageID && $0.role == .assistant }) {
                lecture.currentChat.messages[m].clicked = clicked
            } else if let c = lecture.archivedChats.firstIndex(where: { $0.messages.contains { $0.id == messageID && $0.role == .assistant } }),
                      let m = lecture.archivedChats[c].messages.firstIndex(where: { $0.id == messageID }) {
                lecture.archivedChats[c].messages[m].clicked = clicked
            } else { throw AIError.configuration("That answer is no longer in this lecture.") }
        }
        let chatID = ([updated.currentChat] + updated.archivedChats).first { $0.messages.contains { $0.id == messageID } }?.id
        guard clicked, let chatID, providers[backend] != nil else { return }
        enqueueChatDistillation(ChatDistillationRequest(moduleID: moduleID, lectureID: lectureID, chatID: chatID,
                                                        backend: backend, model: model, trigger: .clicked(messageID: messageID)))
    }

    /// Ends every open discussion in a chat the student left, so its last concept can still become a point.
    /// With `idleFor`, only does so when the chat's last message is at least that old.
    public func endChatDiscussions(moduleID: UUID, lectureID: UUID, chatID: UUID, idleFor: TimeInterval? = nil,
                                   backend: AIBackend = .claudeCLI, model: String = "opus") async throws {
        guard providers[backend] != nil else { return }
        let lecture = try await store.loadLecture(moduleID: moduleID, lectureID: lectureID)
        guard let chat = ([lecture.currentChat] + lecture.archivedChats).first(where: { $0.id == chatID }),
              let cursor = chat.pointCursor, cursor < chat.messages.count else { return }
        if let idleFor, let last = chat.messages.last, Date().timeIntervalSince(last.at) < idleFor { return }
        guard chat.messages[cursor...].contains(where: { $0.role == .user && ChatDistillationRules.isPrepare($0, in: lecture) }) else { return }
        enqueueChatDistillation(ChatDistillationRequest(moduleID: moduleID, lectureID: lectureID, chatID: chatID,
                                                        backend: backend, model: model, trigger: .chatEnded))
    }

    func enqueueChatDistillation(_ request: ChatDistillationRequest) {
        let id = UUID()
        let previous = distilChains[request.chatID]?.task
        let task = Task {
            await previous?.value
            await self.runChatDistillation(request, distilID: id)
            self.finishChatDistillation(id, chatID: request.chatID)
        }
        active[id] = task
        distilChains[request.chatID] = (id, task)
    }
    private func finishChatDistillation(_ id: UUID, chatID: UUID) {
        if distilChains[chatID]?.id == id { distilChains.removeValue(forKey: chatID) }
        finishDistil(id)
    }

    private enum DistilPlan {
        case points(window: [ChatMessage], readPages: Set<Int>, cursorStart: Int, cursorEnd: Int, closeAll: Bool, clicked: UUID?)
        case suggestion(window: [ChatMessage], target: ChatMessage, discussed: [Card], readPages: Set<Int>, exchangeChangedCards: Bool)
    }

    func runChatDistillation(_ input: ChatDistillationRequest, distilID: UUID) async {
        var failureHandled = false
        let parentJobID: UUID? = if case .answer(let id) = input.trigger { id } else { nil }
        let warningJobID = parentJobID ?? distilID
        do {
            let lecture = try await store.loadLecture(moduleID: input.moduleID, lectureID: input.lectureID)
            guard let chat = ([lecture.currentChat] + lecture.archivedChats).first(where: { $0.id == input.chatID }) else { return }
            let messages = chat.messages

            // Summary maintenance only follows a new answer, exactly as before.
            let olderCount = max(0, messages.count - 20)
            let summarizedCount = min(olderCount, chat.summarizedMessageCount ?? 0)
            let newlyOlderMessages: [ChatMessage] = parentJobID == nil ? [] : Array(messages.dropFirst(summarizedCount).prefix(olderCount - summarizedCount))

            let exchange = parentJobID.map { id in messages.filter { $0.editJobID == id } } ?? []
            let clickedID: UUID? = if case .clicked(let id) = input.trigger { id } else { nil }
            let anchor = clickedID.flatMap { id in messages.first { $0.id == id } } ?? exchange.last(where: { $0.role == .assistant })

            var plan: DistilPlan?
            if let anchor, ChatDistillationRules.isReview(anchor, in: lecture) {
                plan = suggestionPlan(lecture: lecture, messages: messages, target: anchor, clicked: clickedID != nil)
            } else if anchor.map({ ChatDistillationRules.isPrepare($0, in: lecture) }) ?? (input.trigger == .chatEnded) {
                let firstExchangeIndex = exchange.first.flatMap { m in messages.firstIndex { $0.id == m.id } }
                let clickedIndex = clickedID.flatMap { id in messages.firstIndex { $0.id == id } }
                let startForClick = clickedIndex.flatMap { i in messages[..<i].lastIndex { $0.role == .user } }
                let cursor = min(chat.pointCursor ?? firstExchangeIndex ?? startForClick ?? messages.count, messages.count)
                let start = max(cursor, messages.count - ChatDistillationRules.window)
                let window = messages[start...].filter { ChatDistillationRules.isPrepare($0, in: lecture) }
                let readPages = ChatDistillationRules.readPages(of: window, pageCount: lecture.pageCount)
                if window.contains(where: { $0.role == .user }), !readPages.isEmpty {
                    plan = .points(window: Array(window), readPages: readPages, cursorStart: cursor, cursorEnd: messages.count,
                                   closeAll: input.trigger == .chatEnded, clicked: clickedID)
                } else if chat.pointCursor == nil, input.trigger != .chatEnded {
                    // Start tracking from here so later discussions are judged.
                    let cursorValue = firstExchangeIndex ?? messages.count
                    _ = try await store.updateLecture(moduleID: input.moduleID, lectureID: input.lectureID) { latest in
                        Self.updateChat(&latest, id: chat.id) { if $0.pointCursor == nil { $0.pointCursor = cursorValue } }
                    }
                }
            }
            guard plan != nil || !newlyOlderMessages.isEmpty else { return }

            let directory = store.jobDirectory(moduleID: input.moduleID, lectureID: input.lectureID, jobID: distilID)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            func json<T: Encodable>(_ value: T) throws -> String { String(decoding: try encoder.encode(value), as: UTF8.self) }
            struct Line: Encodable { var id: UUID; var role: String; var text: String; var clicked: Bool? }
            func lines(_ list: [ChatMessage]) -> [Line] {
                list.map { Line(id: $0.id, role: $0.role.rawValue, text: $0.role == .assistant && $0.text.count > 2400 ? String($0.text.prefix(2400)) + "…" : $0.text, clicked: $0.clicked ? true : nil) }
            }
            let sourceText: (Set<Int>) -> String = { pages in
                let document = PDFDocument(url: self.store.sourceURL(moduleID: input.moduleID, lectureID: input.lectureID))
                return pages.sorted().map { page in
                    let text = document?.page(at: page - 1)?.string ?? ""
                    let note = lecture.slides.indices.contains(page - 1) ? lecture.slides[page - 1].note : ""
                    return "S\(page): \(text)\nNote: \(note)"
                }.joined(separator: "\n")
            }
            var prompt = "Also return summary: at most THREE LINES, update PREVIOUS SUMMARY only with NEWLY OLDER MESSAGES. If NEWLY OLDER MESSAGES is empty retain previous summary exactly. Never summarize the latest exchange into the older summary.\nPREVIOUS SUMMARY:\n\(chat.summary)\nNEWLY OLDER MESSAGES:\n\(try json(lines(newlyOlderMessages)))\n\n"
            let schema: String
            switch plan {
            case .points(let window, let readPages, _, _, let closeAll, let clicked):
                struct ExistingPoint: Encodable { var id: UUID; var text: String; var pages: [Int]; var excluded: Bool }
                struct ExistingCard: Encodable { var id: UUID; var front: String; var back: String; var sourceSlides: [Int] }
                let points = lecture.learningPoints.filter { !$0.pages.allSatisfy { !readPages.contains($0) } }
                    .map { ExistingPoint(id: $0.id, text: $0.text, pages: $0.pages, excluded: !$0.included) }
                let cards = lecture.cards.filter { !$0.isSuperseded && $0.verdict != .bad && $0.sourcePages.contains(where: readPages.contains) }
                    .map { ExistingCard(id: $0.id, front: $0.front, back: $0.back, sourceSlides: $0.sourcePages) }
                let state = closeAll ? "The chat is over: every discussion has ended." : clicked.map { "The student just marked answer \($0.uuidString) as clicked: its discussion has ended." } ?? "The chat continues: the last discussion is open unless a later student message moved on."
                prompt = ChatDistillationRules.pointInstructions + "\n\n" + prompt + "DISCUSSION STATE: \(state)\nCHAT (oldest first):\n\(try json(lines(window)))\nEXISTING POINTS:\n\(try json(points))\nEXISTING CARDS on these slides:\n\(try json(cards))\nREAD SLIDES:\n\(sourceText(readPages))"
                schema = AIOutputSchema.chatDistillation
            case .suggestion(let window, let target, let discussed, let readPages, let changed):
                struct DiscussedCard: Encodable { var cardID: UUID; var baseRevisionID: UUID?; var number: Int; var front: String; var back: String; var sourceSlides: [Int] }
                let active = lecture.cards.filter { !$0.isSuperseded }
                let numbers = Dictionary(uniqueKeysWithValues: active.enumerated().map { ($0.element.id, $0.offset + 1) })
                prompt = ChatDistillationRules.suggestionInstructions + "\n\n" + prompt
                    + "TARGET: \(target.id.uuidString)\(target.clicked ? " (clicked)" : "")\nLATEST EXCHANGE CHANGED CARDS: \(changed)\nCHAT (oldest first):\n\(try json(lines(window)))\n"
                    + "DISCUSSED CARDS:\n\(try json(discussed.map { DiscussedCard(cardID: $0.id, baseRevisionID: $0.currentRevisionID, number: numbers[$0.id] ?? 0, front: $0.front, back: $0.back, sourceSlides: $0.sourcePages) }))\n"
                    + "ALL CARD FRONTS:\n\(try json(active.map(\.front)))\nREAD SLIDES:\n\(sourceText(readPages))"
                schema = AIOutputSchema.reviewDistillation
            case nil:
                prompt = "Summarize older messages only. Learning-point extraction is disabled for this exchange. Return learningPoints empty and closedThroughMessageID null.\n\n" + prompt
                schema = AIOutputSchema.chatDistillation
            }

            let distilModel: String
            switch input.backend {
            case .claudeCLI: distilModel = AISettings.learningPointCLIModel
            case .messagesAPI: distilModel = AISettings.learningPointAPIModel
            case .codexCLI: distilModel = input.model.isEmpty || input.model == "opus" ? AISettings.defaultCodexModel : input.model
            }
            var request = AIRequest(jobID: distilID, kind: .distil, model: distilModel, prompt: prompt, pdf: nil, workingDirectory: directory)
            request.systemPrompt = PromptBuilder.systemPrompt(for: .distil)
            request.outputSchemaOverride = schema
            let jobPages: [Int] = switch plan {
            case .points(_, let pages, _, _, _, _): pages.sorted()
            case .suggestion(_, _, _, let pages, _): pages.sorted()
            case nil: []
            }
            var distilJob = Job(id: distilID, kind: .distil, pages: jobPages, backend: input.backend, threadID: input.chatID, prompt: request.prompt, model: request.model)
            distilJob.inputHash = try Self.inputHash(request)
            let frozenDistilJob = distilJob
            let frozenPlan = plan

            try await AIDiagnostics.withTrace(request: request, backend: input.backend) { trace in
                trace.record("background_distillation_started", ["parentJobID": parentJobID?.uuidString ?? "", "trigger": String(describing: input.trigger)])
                do {
                    trace.phase("snapshot_persistence")
                    try JSONEncoder().encode(Snapshot(request: request, learningPointIDs: [])).write(to: directory.appendingPathComponent("snapshot.json"), options: .atomic)
                    _ = try await store.updateLecture(moduleID: input.moduleID, lectureID: input.lectureID) { $0.jobs.append(frozenDistilJob) }

                    trace.phase("provider_execution")
                    guard let provider = providers[input.backend] else { throw AIError.configuration("Provider unavailable.") }
                    let response = try await provider.execute(request) { event in trace.event(event) }
                    recordRunnerResponse(response, trace: trace)

                    trace.phase("response_validation")
                    let data = Data(response.content.utf8)
                    var summary: String?
                    var landing: Landing?
                    switch frozenPlan {
                    case .suggestion(_, let target, let discussed, let readPages, _):
                        let output = try JSONDecoder().decode(ReviewDistillation.self, from: data)
                        summary = output.summary
                        let suggestion = output.suggestion.flatMap { Self.validatedSuggestion($0, lecture: lecture, discussed: discussed, readPages: readPages) }
                        if output.suggestion != nil && suggestion == nil { trace.record("card_suggestion_rejected", [:]) }
                        if let suggestion { landing = .suggestion(suggestion, messageID: target.id) }
                    case .points(let window, let readPages, let cursorStart, let cursorEnd, let closeAll, _):
                        let output = try JSONDecoder().decode(ChatDistillation.self, from: data)
                        summary = output.summary
                        var decision = Self.validatedPoints(output, lecture: lecture, window: window, readPages: readPages, closeAll: closeAll, cursorEnd: cursorEnd, messages: messages)
                        decision.startCursor = cursorStart
                        if decision.rejected > 0 { trace.record("learning_points_rejected", ["count": decision.rejected]) }
                        landing = .points(decision)
                    case nil:
                        struct SummaryOnly: Decodable { var summary: String? }
                        summary = try JSONDecoder().decode(SummaryOnly.self, from: data).summary
                    }

                    trace.phase("lecture_persistence")
                    let frozenSummary = summary, frozenLanding = landing
                    _ = try await store.updateLecture(moduleID: input.moduleID, lectureID: input.lectureID) { latest in
                        if let j = latest.jobs.firstIndex(where: { $0.id == distilID }) { latest.jobs[j].state = .succeeded; latest.jobs[j].usage = response.usage; latest.jobs[j].finishedAt = Date() }
                        switch frozenLanding {
                        case .points(let decision): Self.apply(decision, to: &latest, chatID: input.chatID)
                        case .suggestion(let suggestion, let messageID):
                            Self.updateChat(&latest, id: input.chatID) { chat in
                                guard let m = chat.messages.firstIndex(where: { $0.id == messageID }), chat.messages[m].suggestion?.state != .applied else { return }
                                chat.messages[m].suggestion = suggestion
                            }
                        case nil: break
                        }
                        guard parentJobID != nil else { return }
                        let summary = (frozenSummary ?? chat.summary).split(separator: "\n").prefix(3).joined(separator: "\n")
                        if latest.currentChat.id == chat.id, latest.currentChat.messages.count == chat.messages.count { latest.currentChat.summary = summary; latest.currentChat.summarizedMessageCount = olderCount }
                        else if let c = latest.archivedChats.firstIndex(where: { $0.id == chat.id && $0.messages.count == chat.messages.count }) { latest.archivedChats[c].summary = summary; latest.archivedChats[c].summarizedMessageCount = olderCount }
                    }
                    trace.record("background_distillation_landed", ["parentJobID": parentJobID?.uuidString ?? "", "jobID": distilID.uuidString])
                    emit(moduleID: input.moduleID, lectureID: input.lectureID, jobID: warningJobID, event: .stage("Succeeded"))
                } catch let operationError {
                    failureHandled = true
                    var message = operationError.localizedDescription
                    if let logPath = diagnosticLogPath(trace) { message += "\nAI diagnostics: \(logPath)" }
                    trace.failure(operationError, event: "background_distillation_failed", fields: ["parentJobID": parentJobID?.uuidString ?? ""])
                    let persistedMessage = message
                    _ = try? await store.updateLecture(moduleID: input.moduleID, lectureID: input.lectureID) { latest in
                        if let j = latest.jobs.firstIndex(where: { $0.id == distilID }) { latest.jobs[j].state = .failed; latest.jobs[j].error = persistedMessage; latest.jobs[j].finishedAt = Date() }
                    }
                    emit(moduleID: input.moduleID, lectureID: input.lectureID, jobID: warningJobID, event: .stage("Succeeded"),
                         warning: "Answer saved; learning points could not be extracted: \(message)")
                    throw operationError
                }
            }
        } catch {
            guard !failureHandled else { return }
            let message = error.localizedDescription
            _ = try? await store.updateLecture(moduleID: input.moduleID, lectureID: input.lectureID) { latest in
                if let j = latest.jobs.firstIndex(where: { $0.id == distilID }) { latest.jobs[j].state = .failed; latest.jobs[j].error = message; latest.jobs[j].finishedAt = Date() }
            }
            emit(moduleID: input.moduleID, lectureID: input.lectureID, jobID: warningJobID, event: .stage("Succeeded"), warning: "Answer saved; learning points could not be extracted: \(message)")
        }
    }

    private func suggestionPlan(lecture: Lecture, messages: [ChatMessage], target: ChatMessage, clicked: Bool) -> DistilPlan? {
        guard let targetIndex = messages.firstIndex(where: { $0.id == target.id }) else { return nil }
        let job = target.editJobID.flatMap { id in lecture.jobs.first { $0.id == id } }
        let changed = target.createdCardIDs?.isEmpty == false || job?.chatEdits?.isEmpty == false
        if changed && !clicked { return nil }
        guard target.suggestion?.state != .applied else { return nil }
        // A first question can't show a reaction to anything; only a click can stand in for one.
        let window = Array(messages[max(0, targetIndex - 7)...targetIndex]).filter { ChatDistillationRules.isReview($0, in: lecture) }
        guard clicked || window.filter({ $0.role == .user }).count >= 2 else { return nil }
        let ids = Set(window.flatMap(\.context).compactMap { if case .card(let id) = $0 { id } else { nil } })
        let discussed = lecture.cards.filter { ids.contains($0.id) && !$0.isSuperseded }
        var pages = ChatDistillationRules.readPages(of: window, pageCount: lecture.pageCount)
        pages.formUnion(discussed.flatMap(\.sourcePages).filter { $0 > 0 && $0 <= lecture.pageCount })
        return .suggestion(window: window, target: target, discussed: discussed, readPages: pages, exchangeChangedCards: changed)
    }

    static func validatedSuggestion(_ wire: ReviewDistillation.Suggestion, lecture: Lecture, discussed: [Card], readPages: Set<Int>) -> CardSuggestion? {
        let front = wire.front.trimmingCharacters(in: .whitespacesAndNewlines), back = wire.back.trimmingCharacters(in: .whitespacesAndNewlines)
        let reason = wire.reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !front.isEmpty, !back.isEmpty, !reason.isEmpty else { return nil }
        if let raw = wire.cardID {
            guard let id = UUID(uuidString: raw), let card = discussed.first(where: { $0.id == id }),
                  wire.baseRevisionID.flatMap(UUID.init(uuidString:)) == card.currentRevisionID,
                  card.front != front || card.back != back else { return nil }
            let pages = wire.sourceSlides.isEmpty ? card.sourcePages : wire.sourceSlides
            guard Set(pages).isSubset(of: readPages.union(card.sourcePages)) else { return nil }
            return CardSuggestion(reason: reason, cardID: id, baseRevisionID: card.currentRevisionID, front: front, back: back, sourcePages: Array(Set(pages)).sorted())
        }
        guard Set(wire.sourceSlides).isSubset(of: readPages),
              !lecture.cards.contains(where: { !$0.isSuperseded && ChatDistillationRules.normalized($0.front) == ChatDistillationRules.normalized(front) }) else { return nil }
        return CardSuggestion(reason: reason, front: front, back: back, sourcePages: Array(Set(wire.sourceSlides)).sorted())
    }

    enum Landing: Sendable { case points(PointDecision), suggestion(CardSuggestion, messageID: UUID) }

    struct PointDecision: Sendable {
        var added: [LearningPoint] = []
        var merged: [LearningPoint] = []
        var cursor: Int?
        /// Where judging started; saved on chats that weren't tracked yet so the open discussion stays in view.
        var startCursor: Int?
        var rejected = 0
    }

    static func validatedPoints(_ output: ChatDistillation, lecture: Lecture, window: [ChatMessage], readPages: Set<Int>,
                                closeAll: Bool, cursorEnd: Int, messages: [ChatMessage]) -> PointDecision {
        var decision = PointDecision()
        let windowIndex = Dictionary(uniqueKeysWithValues: window.enumerated().map { ($0.element.id, $0.offset) })
        let closedThrough: Int? = closeAll ? window.count - 1 : output.closedThroughMessageID.flatMap(UUID.init(uuidString:)).flatMap { windowIndex[$0] }
        if closeAll { decision.cursor = cursorEnd }
        else if let closedThrough, let index = messages.firstIndex(where: { $0.id == window[closedThrough].id }) { decision.cursor = index + 1 }
        guard let closedThrough else { decision.rejected = output.learningPoints.count; return decision }
        var activeCount: [Int: Int] = [:]
        for point in lecture.learningPoints where point.included { for page in point.pages { activeCount[page, default: 0] += 1 } }
        let mergeable = Dictionary(uniqueKeysWithValues: lecture.learningPoints.filter { $0.included && ($0.cardIDs ?? []).isEmpty }.map { ($0.id, $0) })
        let activeCards = lecture.cards.filter { !$0.isSuperseded }
        for wire in output.learningPoints.prefix(ChatDistillationRules.maximumPoints) {
            let text = wire.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let front = wire.front.trimmingCharacters(in: .whitespacesAndNewlines), back = wire.back.trimmingCharacters(in: .whitespacesAndNewlines)
            let pages = Array(Set(wire.pages)).sorted()
            guard let kind = LearningPointKind(rawValue: wire.kind), !text.isEmpty, LearningPoint.wordCount(text) <= LearningPoint.maximumWords,
                  !front.isEmpty, !back.isEmpty, !pages.isEmpty, pages.allSatisfy(readPages.contains),
                  let endID = UUID(uuidString: wire.endMessageID), let end = windowIndex[endID], end <= closedThrough else { decision.rejected += 1; continue }
            var evidence: [LearningPointEvidence] = []
            var fromStudentOrClick = false
            var evidenceValid = !wire.evidence.isEmpty
            for item in wire.evidence {
                guard let id = UUID(uuidString: item.messageID), let i = windowIndex[id], i <= closedThrough,
                      ChatDistillationRules.quote(item.quote, appearsIn: window[i].text) else { evidenceValid = false; break }
                if window[i].role == .user || window[i].clicked { fromStudentOrClick = true }
                evidence.append(LearningPointEvidence(messageID: id, quote: item.quote))
            }
            guard evidenceValid, fromStudentOrClick else { decision.rejected += 1; continue }
            let replaces = wire.replacesCardID.flatMap(UUID.init(uuidString:)).flatMap { id in activeCards.first { $0.id == id }?.id }
            let draft = LearningPointDraft(front: front, back: back, replacesCardID: replaces)
            if let mergeID = wire.mergesPointID.flatMap(UUID.init(uuidString:)), var target = mergeable[mergeID] ?? decision.added.first(where: { $0.id == mergeID }) {
                target.text = text; target.pages = Array(Set(target.pages + pages)).sorted(); target.kind = kind
                target.difficulty = max(target.difficulty ?? 0, min(3, max(0, wire.difficulty)))
                target.evidence = (target.evidence ?? []) + evidence; target.draft = draft; target.reviewed = false
                target.episodeEndMessageID = endID
                if let i = decision.added.firstIndex(where: { $0.id == mergeID }) { decision.added[i] = target } else { decision.merged.append(target) }
                continue
            }
            guard !lecture.learningPoints.contains(where: { ChatDistillationRules.normalized($0.text) == ChatDistillationRules.normalized(text) }),
                  pages.allSatisfy({ activeCount[$0, default: 0] < LearningPoint.maximumActivePerSlide }) else { decision.rejected += 1; continue }
            for page in pages { activeCount[page, default: 0] += 1 }
            var point = LearningPoint(text: text, pages: pages)
            point.kind = kind; point.difficulty = min(3, max(0, wire.difficulty)); point.evidence = evidence; point.draft = draft
            point.episodeEndMessageID = endID
            decision.added.append(point)
        }
        return decision
    }

    static func apply(_ decision: PointDecision, to lecture: inout Lecture, chatID: UUID) {
        for point in decision.merged {
            if let i = lecture.learningPoints.firstIndex(where: { $0.id == point.id && $0.included && ($0.cardIDs ?? []).isEmpty }) { lecture.learningPoints[i] = point }
        }
        for point in decision.added where !lecture.learningPoints.contains(where: { $0.id == point.id || $0.text == point.text }) {
            lecture.learningPoints.append(point)
        }
        updateChat(&lecture, id: chatID) { chat in
            if let cursor = decision.cursor { chat.pointCursor = max(chat.pointCursor ?? 0, min(cursor, chat.messages.count)) }
            else if chat.pointCursor == nil, let start = decision.startCursor { chat.pointCursor = min(start, chat.messages.count) }
        }
    }

    static func updateChat(_ lecture: inout Lecture, id: UUID, _ change: (inout LectureChat) -> Void) {
        if lecture.currentChat.id == id { change(&lecture.currentChat) }
        else if let c = lecture.archivedChats.firstIndex(where: { $0.id == id }) { change(&lecture.archivedChats[c]) }
    }
}
