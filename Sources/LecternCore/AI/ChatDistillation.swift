import Foundation
import PDFKit

/// What started a background pass over a lecture chat.
public enum ChatDistillationTrigger: Equatable, Sendable {
    /// An answer landed: update the summary, judge the student's latest reaction.
    case answer(jobID: UUID)
    /// The student marked an answer as the explanation that worked.
    case clicked(messageID: UUID)
    /// A stable chat boundary was captured when the student left or the chat became idle.
    case chatEnded(reason: ChatDistillationEndReason, throughMessageID: UUID)

    var name: String {
        switch self {
        case .answer: "answer"
        case .clicked: "clicked"
        case .chatEnded(let reason, _): reason.rawValue
        }
    }
    var identifier: String {
        switch self {
        case .answer(let jobID): jobID.uuidString
        case .clicked(let messageID): messageID.uuidString
        case .chatEnded(_, let messageID): messageID.uuidString
        }
    }
}

public enum ChatDistillationEndReason: String, Sendable {
    case newChat, switchChat, idle, chatEnded
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
    static let clickedWindow = 30
    static let maximumPoints = 4

    static func isCardContext(_ refs: [ContextRef]) -> Bool {
        refs.contains { if case .card = $0 { true } else if case .allCards = $0 { true } else { false } }
    }

    /// Prepare messages are slide conversations. Review chat and card-context chat never make learning points.
    static func isPrepare(_ message: ChatMessage, in lecture: Lecture) -> Bool {
        guard let id = message.editJobID, let job = lecture.jobs.first(where: { $0.id == id }) else { return false }
        return job.kind == .chat && job.isLectureChat == true && job.state == .succeeded &&
            job.allowsCardCreation != true && !message.stopped && !isCardContext(message.context)
    }
    static func isReview(_ message: ChatMessage, in lecture: Lecture) -> Bool {
        guard let id = message.editJobID, let job = lecture.jobs.first(where: { $0.id == id }) else { return false }
        return job.kind == .chat && job.isLectureChat == true && job.state == .succeeded &&
            job.allowsCardCreation == true && !message.stopped
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

    /// A question alone is not a reaction. A later student turn or an explicit click is.
    static func hasStudentReaction(in messages: [ChatMessage]) -> Bool {
        for (index, message) in messages.enumerated() {
            if message.clicked && message.role == .assistant { return true }
            if message.role == .user, messages[..<index].contains(where: { $0.role == .assistant }) { return true }
        }
        return false
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
    - An answer that the student abandons or never reacts to gives no point, even when the question was specific. Leaving, switching chats, an idle timeout, or a stopped answer is not evidence that the explanation worked. A click is an explicit positive reaction.

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
            func isClickable(_ message: ChatMessage) -> Bool {
                guard message.id == messageID, message.role == .assistant, !message.stopped,
                      let jobID = message.editJobID,
                      let job = lecture.jobs.first(where: { $0.id == jobID }) else { return false }
                return job.kind == .chat && job.isLectureChat == true && job.state == .succeeded
            }
            if let m = lecture.currentChat.messages.firstIndex(where: isClickable) {
                lecture.currentChat.messages[m].clicked = clicked
            } else if let c = lecture.archivedChats.firstIndex(where: { $0.messages.contains { $0.id == messageID && $0.role == .assistant } }),
                      let m = lecture.archivedChats[c].messages.firstIndex(where: isClickable) {
                lecture.archivedChats[c].messages[m].clicked = clicked
            } else { throw AIError.configuration("Only a completed lecture-chat answer can be marked Clicked.") }
        }
        let chat = ([updated.currentChat] + updated.archivedChats).first { $0.messages.contains { $0.id == messageID } }
        guard clicked, let chat else { return }
        let context = Self.diagnosticContext(moduleID: moduleID, lectureID: lectureID, chatID: chat.id,
                                            purpose: chat.messages.first(where: { $0.id == messageID }).map { ChatDistillationRules.isReview($0, in: updated) ? "reviewSuggestion" : "preparePoints" } ?? "preparePoints",
                                            trigger: "clicked", triggerID: messageID.uuidString, parentJobID: nil)
        guard !chat.processedClickedAnswerIDs.contains(messageID) else {
            recordDistillationSkip(moduleID: moduleID, lectureID: lectureID, chatID: chat.id, backend: backend, model: model,
                                   context: context, reason: "clickedAnswerAlreadyProcessed")
            return
        }
        guard providers[backend] != nil else {
            recordDistillationSkip(moduleID: moduleID, lectureID: lectureID, chatID: chat.id, backend: backend, model: model,
                                   context: context, reason: "providerUnavailable")
            return
        }
        enqueueChatDistillation(ChatDistillationRequest(moduleID: moduleID, lectureID: lectureID, chatID: chat.id,
                                                        backend: backend, model: model, trigger: .clicked(messageID: messageID)))
    }

    /// Ends every open discussion in a chat the student left, so its last concept can still become a point.
    /// With `idleFor`, only does so when the chat's last message is at least that old.
    public func endChatDiscussions(moduleID: UUID, lectureID: UUID, chatID: UUID, idleFor: TimeInterval? = nil,
                                   reason: ChatDistillationEndReason = .chatEnded,
                                   backend: AIBackend = .claudeCLI, model: String = "opus") async throws {
        let triggerID = chatID.uuidString
        let context = Self.diagnosticContext(moduleID: moduleID, lectureID: lectureID, chatID: chatID,
                                            purpose: "preparePoints", trigger: reason.rawValue,
                                            triggerID: triggerID, parentJobID: nil)
        guard providers[backend] != nil else {
            recordDistillationSkip(moduleID: moduleID, lectureID: lectureID, chatID: chatID, backend: backend, model: model,
                                   context: context, reason: "providerUnavailable")
            return
        }
        let lecture = try await store.loadLecture(moduleID: moduleID, lectureID: lectureID)
        guard let chat = ([lecture.currentChat] + lecture.archivedChats).first(where: { $0.id == chatID }) else {
            recordDistillationSkip(moduleID: moduleID, lectureID: lectureID, chatID: chatID, backend: backend, model: model,
                                   context: context, reason: "chatNotFound")
            return
        }
        guard let cursor = chat.pointCursor, cursor < chat.messages.count else {
            recordDistillationSkip(moduleID: moduleID, lectureID: lectureID, chatID: chatID, backend: backend, model: model,
                                   context: context, reason: chat.pointCursor == nil ? "legacyChatNotTracked" : "cursorAtEnd")
            return
        }
        if let idleFor, let last = chat.messages.last, Date().timeIntervalSince(last.at) < idleFor {
            recordDistillationSkip(moduleID: moduleID, lectureID: lectureID, chatID: chatID, backend: backend, model: model,
                                   context: context, reason: "idleThresholdNotReached")
            return
        }
        guard chat.messages[cursor...].contains(where: { $0.role == .user && ChatDistillationRules.isPrepare($0, in: lecture) }),
              let boundary = chat.messages.last?.id else {
            recordDistillationSkip(moduleID: moduleID, lectureID: lectureID, chatID: chatID, backend: backend, model: model,
                                   context: context, reason: "noUnjudgedPrepareMessages")
            return
        }
        enqueueChatDistillation(ChatDistillationRequest(moduleID: moduleID, lectureID: lectureID, chatID: chatID,
                                                        backend: backend, model: model,
                                                        trigger: .chatEnded(reason: reason, throughMessageID: boundary)))
    }

    private static func distillationModel(_ backend: AIBackend, requested: String) -> String {
        switch backend {
        case .claudeCLI: AISettings.learningPointCLIModel
        case .messagesAPI: AISettings.learningPointAPIModel
        case .codexCLI: requested.isEmpty || requested == "opus" ? AISettings.defaultCodexModel : requested
        }
    }

    private static func diagnosticContext(moduleID: UUID, lectureID: UUID, chatID: UUID,
                                          purpose: String, trigger: String, triggerID: String,
                                          parentJobID: UUID?) -> [String: String] {
        var context = ["feature": "learningPointsV2", "purpose": purpose, "trigger": trigger,
                       "triggerID": triggerID, "moduleID": moduleID.uuidString,
                       "lectureID": lectureID.uuidString, "chatID": chatID.uuidString]
        if let parentJobID { context["parentJobID"] = parentJobID.uuidString }
        return context
    }

    private func recordDistillationSkip(jobID: UUID = UUID(), moduleID: UUID, lectureID: UUID, chatID: UUID,
                                        backend: AIBackend, model: String, context: [String: String],
                                        reason: String) {
        AIDiagnostics.recordSkipped(jobID: jobID, backend: backend, kind: .distil,
                                    model: Self.distillationModel(backend, requested: model),
                                    workingDirectory: store.jobDirectory(moduleID: moduleID, lectureID: lectureID, jobID: jobID),
                                    context: context, reason: reason)
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
        case points(window: [ChatMessage], readPages: Set<Int>, cursorStart: Int, cursorEnd: Int,
                    closeAll: Bool, clicked: UUID?, advanceCursor: Bool)
        case suggestion(window: [ChatMessage], target: ChatMessage, discussed: [Card], readPages: Set<Int>, exchangeChangedCards: Bool)
    }

    func runChatDistillation(_ input: ChatDistillationRequest, distilID: UUID) async {
        var failureHandled = false
        let parentJobID: UUID? = if case .answer(let id) = input.trigger { id } else { nil }
        let warningJobID = parentJobID ?? distilID
        do {
            let lecture = try await store.loadLecture(moduleID: input.moduleID, lectureID: input.lectureID)
            guard let chat = ([lecture.currentChat] + lecture.archivedChats).first(where: { $0.id == input.chatID }) else {
                recordDistillationSkip(jobID: distilID, moduleID: input.moduleID, lectureID: input.lectureID, chatID: input.chatID,
                                       backend: input.backend, model: input.model,
                                       context: Self.diagnosticContext(moduleID: input.moduleID, lectureID: input.lectureID, chatID: input.chatID,
                                                                       purpose: "summary", trigger: input.trigger.name, triggerID: input.trigger.identifier, parentJobID: parentJobID),
                                       reason: "chatNotFound")
                return
            }
            let clickedID: UUID? = if case .clicked(let id) = input.trigger { id } else { nil }
            if let clickedID, !chat.messages.contains(where: { $0.id == clickedID && $0.clicked }) {
                recordDistillationSkip(jobID: distilID, moduleID: input.moduleID, lectureID: input.lectureID, chatID: input.chatID,
                                       backend: input.backend, model: input.model,
                                       context: Self.diagnosticContext(moduleID: input.moduleID, lectureID: input.lectureID, chatID: input.chatID,
                                                                       purpose: "preparePoints", trigger: input.trigger.name, triggerID: input.trigger.identifier, parentJobID: nil),
                                       reason: "clickRetracted")
                return
            }
            if let clickedID, chat.processedClickedAnswerIDs.contains(clickedID) {
                recordDistillationSkip(jobID: distilID, moduleID: input.moduleID, lectureID: input.lectureID, chatID: input.chatID,
                                       backend: input.backend, model: input.model,
                                       context: Self.diagnosticContext(moduleID: input.moduleID, lectureID: input.lectureID, chatID: input.chatID,
                                                                       purpose: "preparePoints", trigger: input.trigger.name, triggerID: input.trigger.identifier, parentJobID: nil),
                                       reason: "clickedAnswerAlreadyProcessed")
                return
            }

            let messages: [ChatMessage]
            let endBoundaryIndex: Int?
            if case .chatEnded(_, let boundaryID) = input.trigger {
                guard let boundary = chat.messages.firstIndex(where: { $0.id == boundaryID }) else {
                    recordDistillationSkip(jobID: distilID, moduleID: input.moduleID, lectureID: input.lectureID, chatID: input.chatID,
                                           backend: input.backend, model: input.model,
                                           context: Self.diagnosticContext(moduleID: input.moduleID, lectureID: input.lectureID, chatID: input.chatID,
                                                                           purpose: "preparePoints", trigger: input.trigger.name, triggerID: input.trigger.identifier, parentJobID: nil),
                                           reason: "endBoundaryMissing")
                    return
                }
                messages = Array(chat.messages.prefix(boundary + 1))
                endBoundaryIndex = boundary
            } else {
                messages = chat.messages
                endBoundaryIndex = nil
            }

            // Summary maintenance follows a new answer only.
            let olderCount = max(0, messages.count - 20)
            let summarizedCount = min(olderCount, chat.summarizedMessageCount ?? 0)
            let newlyOlderMessages: [ChatMessage] = parentJobID == nil ? [] : Array(messages.dropFirst(summarizedCount).prefix(olderCount - summarizedCount))

            let exchange = parentJobID.map { id in messages.filter { $0.editJobID == id } } ?? []
            let anchor = clickedID.flatMap { id in messages.first { $0.id == id } } ?? exchange.last(where: { $0.role == .assistant })
            let isChatEnded: Bool = { if case .chatEnded = input.trigger { true } else { false } }()

            var plan: DistilPlan?
            if let anchor, ChatDistillationRules.isReview(anchor, in: lecture) {
                plan = suggestionPlan(lecture: lecture, messages: messages, target: anchor, clicked: clickedID != nil)
            } else if let clickedID, let clickedIndex = messages.firstIndex(where: { $0.id == clickedID }),
                      ChatDistillationRules.isPrepare(messages[clickedIndex], in: lecture) {
                let start = max(0, clickedIndex - ChatDistillationRules.clickedWindow + 1)
                let window = messages[start...clickedIndex].filter { ChatDistillationRules.isPrepare($0, in: lecture) }
                let pages = ChatDistillationRules.readPages(of: window, pageCount: lecture.pageCount)
                if window.contains(where: { $0.role == .user }), !pages.isEmpty {
                    plan = .points(window: window, readPages: pages, cursorStart: chat.pointCursor ?? start,
                                   cursorEnd: clickedIndex + 1, closeAll: false, clicked: clickedID, advanceCursor: false)
                }
            } else if isChatEnded || anchor.map({ ChatDistillationRules.isPrepare($0, in: lecture) }) == true {
                let firstExchangeIndex = exchange.first.flatMap { message in messages.firstIndex { $0.id == message.id } }
                let start = min(chat.pointCursor ?? firstExchangeIndex ?? messages.count, messages.count)
                let window = messages[start...].filter { ChatDistillationRules.isPrepare($0, in: lecture) }
                let pages = ChatDistillationRules.readPages(of: window, pageCount: lecture.pageCount)
                if window.contains(where: { $0.role == .user }), !pages.isEmpty {
                    plan = .points(window: window, readPages: pages, cursorStart: start,
                                   cursorEnd: (endBoundaryIndex.map { $0 + 1 } ?? messages.count),
                                   closeAll: isChatEnded, clicked: nil, advanceCursor: true)
                }
            }

            // The first answer has no reaction yet. Tracking was persisted with the student message;
            // only summarize older history here if needed, and wait for a later reaction to judge it.
            if parentJobID != nil, clickedID == nil, let currentPlan = plan,
               case .points(let window, _, _, _, _, _, _) = currentPlan,
               !ChatDistillationRules.hasStudentReaction(in: window) {
                plan = nil
            }
            if plan == nil && newlyOlderMessages.isEmpty {
                if let clickedID {
                    _ = try await store.updateLecture(moduleID: input.moduleID, lectureID: input.lectureID) { latest in
                        Self.updateChat(&latest, id: chat.id) { chat in
                            if !chat.processedClickedAnswerIDs.contains(clickedID) { chat.processedClickedAnswerIDs.append(clickedID) }
                        }
                    }
                }
                let purpose = anchor.map { ChatDistillationRules.isReview($0, in: lecture) ? "reviewSuggestion" : "preparePoints" } ?? "preparePoints"
                recordDistillationSkip(jobID: distilID, moduleID: input.moduleID, lectureID: input.lectureID, chatID: input.chatID,
                                       backend: input.backend, model: input.model,
                                       context: Self.diagnosticContext(moduleID: input.moduleID, lectureID: input.lectureID, chatID: input.chatID,
                                                                       purpose: purpose, trigger: input.trigger.name, triggerID: input.trigger.identifier, parentJobID: parentJobID),
                                       reason: clickedID == nil ? "noEligibleEndedDiscussion" : "clickedAnswerHadNoEligibleContext")
                return
            }

            let purpose: String
            switch plan {
            case .points: purpose = "preparePoints"
            case .suggestion: purpose = "reviewSuggestion"
            case nil: purpose = "summary"
            }
            let diagnosticContext = Self.diagnosticContext(moduleID: input.moduleID, lectureID: input.lectureID, chatID: input.chatID,
                                                           purpose: purpose, trigger: input.trigger.name,
                                                           triggerID: input.trigger.identifier, parentJobID: parentJobID)
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
            case .points(let window, let readPages, _, _, let closeAll, let clicked, _):
                struct ExistingPoint: Encodable { var id: UUID; var text: String; var pages: [Int]; var excluded: Bool }
                struct ExistingCard: Encodable { var id: UUID; var front: String; var back: String; var sourceSlides: [Int] }
                let points = lecture.learningPoints.filter { !$0.pages.allSatisfy { !readPages.contains($0) } }
                    .map { ExistingPoint(id: $0.id, text: $0.text, pages: $0.pages, excluded: !$0.included) }
                let cards = lecture.cards.filter { !$0.isSuperseded && $0.verdict != .bad && $0.sourcePages.contains(where: readPages.contains) }
                    .map { ExistingCard(id: $0.id, front: $0.front, back: $0.back, sourceSlides: $0.sourcePages) }
                let state: String
                if closeAll, let endBoundaryIndex, let id = messages.indices.contains(endBoundaryIndex) ? messages[endBoundaryIndex].id : nil {
                    state = "The chat ended at message \(id.uuidString). Messages after that boundary do not belong to this pass. This does not imply understanding: abandoned or unreacted answers get no point."
                } else if let clicked { state = "The student marked answer \(clicked.uuidString) as clicked: that answer is explicit positive evidence." }
                else { state = "The chat continues: the last discussion is open unless a later student message moved to another concept." }
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

            let distilModel = Self.distillationModel(input.backend, requested: input.model)
            var request = AIRequest(jobID: distilID, kind: .distil, model: distilModel, prompt: prompt, pdf: nil, workingDirectory: directory)
            request.systemPrompt = PromptBuilder.systemPrompt(for: .distil)
            request.outputSchemaOverride = schema
            request.diagnosticContext = diagnosticContext
            let jobPages: [Int] = switch plan {
            case .points(_, let pages, _, _, _, _, _): pages.sorted()
            case .suggestion(_, _, _, let pages, _): pages.sorted()
            case nil: []
            }
            var distilJob = Job(id: distilID, kind: .distil, pages: jobPages, backend: input.backend, threadID: input.chatID, prompt: request.prompt, model: request.model)
            distilJob.inputHash = try Self.inputHash(request)
            distilJob.pdfLayoutRevision = lecture.pdfLayoutRevision
            let frozenDistilJob = distilJob
            let frozenPlan = plan
            let windowCount: Int = switch plan {
            case .points(let window, _, _, _, _, _, _): window.count
            case .suggestion(let window, _, _, _, _): window.count
            case nil: 0
            }

            try await AIDiagnostics.withTrace(request: request, backend: input.backend) { trace in
                trace.setMetadata(["trigger": input.trigger.name, "triggerID": input.trigger.identifier,
                                   "windowMessages": windowCount, "promptCharacters": prompt.count])
                trace.record("background_distillation_started", ["parentJobID": parentJobID?.uuidString ?? "",
                                                                  "trigger": input.trigger.name, "triggerID": input.trigger.identifier])
                do {
                    trace.phase("snapshot_persistence")
                    try JSONEncoder().encode(Snapshot(request: request, learningPointIDs: [])).write(to: directory.appendingPathComponent("snapshot.json"), options: .atomic)
                    _ = try await store.updateLecture(moduleID: input.moduleID, lectureID: input.lectureID) {
                        guard $0.pdfLayoutRevision == frozenDistilJob.pdfLayoutRevision else { throw LectureError.staleSnapshot }
                        $0.jobs.append(frozenDistilJob)
                    }

                    trace.phase("provider_execution")
                    guard let provider = providers[input.backend] else { throw AIError.configuration("Provider unavailable.") }
                    let response = try await provider.execute(request) { event in trace.event(event) }
                    let usageReported = response.usage.inputTokens > 0 || response.usage.outputTokens > 0 || response.usage.costUSD != nil ||
                        response.usage.cacheReadInputTokens != nil || response.usage.cacheCreationInputTokens != nil
                    trace.record("provider_returned", ["usageReported": usageReported])
                    recordRunnerResponse(response, trace: trace)

                    trace.phase("response_validation")
                    let data = Data(response.content.utf8)
                    var summary: String?
                    var landing: Landing?
                    var validatedRejected = 0
                    switch frozenPlan {
                    case .suggestion(_, let target, let discussed, let readPages, _):
                        let output = try JSONDecoder().decode(ReviewDistillation.self, from: data)
                        summary = output.summary
                        let suggestion = output.suggestion.flatMap { Self.validatedSuggestion($0, lecture: lecture, discussed: discussed, readPages: readPages) }
                        if output.suggestion != nil && suggestion == nil { trace.record("card_suggestion_rejected", [:]) }
                        if let suggestion { landing = .suggestion(suggestion, messageID: target.id) }
                    case .points(let window, let readPages, let cursorStart, let cursorEnd, let closeAll, let clicked, let advanceCursor):
                        let output = try JSONDecoder().decode(ChatDistillation.self, from: data)
                        summary = output.summary
                        var decision = Self.validatedPoints(output, lecture: lecture, window: window, readPages: readPages,
                                                             closeAll: closeAll, cursorEnd: cursorEnd, messages: messages)
                        if advanceCursor { decision.startCursor = cursorStart }
                        else { decision.cursor = nil; decision.startCursor = nil }
                        validatedRejected = decision.rejected
                        if clicked == nil && advanceCursor == false { decision.cursor = nil }
                        landing = .points(decision)
                    case nil:
                        struct SummaryOnly: Decodable { var summary: String? }
                        summary = try JSONDecoder().decode(SummaryOnly.self, from: data).summary
                    }

                    trace.phase("lecture_persistence")
                    let frozenSummary = summary, frozenLanding = landing
                    let transaction = try await store.transaction(moduleID: input.moduleID, lectureID: input.lectureID) { latest -> PointLandingOutcome in
                        if let j = latest.jobs.firstIndex(where: { $0.id == distilID }) { latest.jobs[j].state = .succeeded; latest.jobs[j].usage = response.usage; latest.jobs[j].finishedAt = Date() }
                        var outcome = PointLandingOutcome()
                        switch frozenLanding {
                        case .points(let decision): outcome = Self.apply(decision, to: &latest, chatID: input.chatID)
                        case .suggestion(let suggestion, let messageID):
                            Self.updateChat(&latest, id: input.chatID) { chat in
                                guard let m = chat.messages.firstIndex(where: { $0.id == messageID }), chat.messages[m].suggestion?.state != .applied else { return }
                                chat.messages[m].suggestion = suggestion
                            }
                        case nil: break
                        }
                        if let clickedID {
                            Self.updateChat(&latest, id: input.chatID) { chat in
                                if !chat.processedClickedAnswerIDs.contains(clickedID) { chat.processedClickedAnswerIDs.append(clickedID) }
                            }
                        }
                        guard parentJobID != nil else { return outcome }
                        let summary = (frozenSummary ?? chat.summary).split(separator: "\n").prefix(3).joined(separator: "\n")
                        if latest.currentChat.id == chat.id, latest.currentChat.messages.count == chat.messages.count { latest.currentChat.summary = summary; latest.currentChat.summarizedMessageCount = olderCount }
                        else if let c = latest.archivedChats.firstIndex(where: { $0.id == chat.id && $0.messages.count == chat.messages.count }) { latest.archivedChats[c].summary = summary; latest.archivedChats[c].summarizedMessageCount = olderCount }
                        return outcome
                    }
                    let finalRejected = transaction.result.rejected + validatedRejected
                    let outcomeFields: [String: Any] = ["pointsAdded": transaction.result.added,
                                                        "pointsMerged": transaction.result.merged,
                                                        "pointsRejected": finalRejected]
                    trace.record("distillation_outcome", outcomeFields)
                    trace.setMetadata(outcomeFields)
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
            guard let id = UUID(uuidString: raw), let card = discussed.first(where: { $0.id == id && $0.solve == nil }),
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
        /// Where judging started; used only if a migrated chat has not started tracking yet.
        var startCursor: Int?
        var rejected = 0
    }

    struct PointLandingOutcome: Sendable {
        var added = 0
        var merged = 0
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
        var mergeable = Dictionary(uniqueKeysWithValues: lecture.learningPoints.filter { $0.included && ($0.cardIDs ?? []).isEmpty }.map { ($0.id, $0) })
        let activeCards = lecture.cards.filter { !$0.isSuperseded }
        decision.rejected += max(0, output.learningPoints.count - ChatDistillationRules.maximumPoints)
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
                if window[i].role == .assistant && window[i].clicked { fromStudentOrClick = true }
                if window[i].role == .user && window[..<i].contains(where: { $0.role == .assistant }) { fromStudentOrClick = true }
                evidence.append(LearningPointEvidence(messageID: id, quote: item.quote))
            }
            guard evidenceValid, fromStudentOrClick else { decision.rejected += 1; continue }
            let replaces = wire.replacesCardID.flatMap(UUID.init(uuidString:)).flatMap { id in activeCards.first { $0.id == id && $0.solve == nil }?.id }
            let draft = LearningPointDraft(front: front, back: back, replacesCardID: replaces)
            if let mergeID = wire.mergesPointID.flatMap(UUID.init(uuidString:)),
               var target = decision.added.first(where: { $0.id == mergeID }) ?? decision.merged.first(where: { $0.id == mergeID }) ?? mergeable[mergeID] {
                let duplicate = lecture.learningPoints.contains { $0.id != mergeID && ChatDistillationRules.normalized($0.text) == ChatDistillationRules.normalized(text) } ||
                    decision.added.contains { $0.id != mergeID && ChatDistillationRules.normalized($0.text) == ChatDistillationRules.normalized(text) }
                let newPages = Set(pages).subtracting(target.pages)
                guard !duplicate, newPages.allSatisfy({ activeCount[$0, default: 0] < LearningPoint.maximumActivePerSlide }) else {
                    decision.rejected += 1; continue
                }
                target.text = text; target.pages = Array(Set(target.pages + pages)).sorted(); target.kind = kind
                target.difficulty = max(target.difficulty ?? 0, min(3, max(0, wire.difficulty)))
                var combinedEvidence = target.evidence ?? []
                for item in evidence where !combinedEvidence.contains(where: { $0.messageID == item.messageID && $0.quote == item.quote }) { combinedEvidence.append(item) }
                target.evidence = combinedEvidence; target.draft = draft; target.reviewed = false
                target.episodeEndMessageID = endID
                if let i = decision.added.firstIndex(where: { $0.id == mergeID }) { decision.added[i] = target }
                else if let i = decision.merged.firstIndex(where: { $0.id == mergeID }) { decision.merged[i] = target }
                else { decision.merged.append(target) }
                mergeable[mergeID] = target
                for page in newPages { activeCount[page, default: 0] += 1 }
                continue
            }
            guard !lecture.learningPoints.contains(where: { ChatDistillationRules.normalized($0.text) == ChatDistillationRules.normalized(text) }),
                  !decision.added.contains(where: { ChatDistillationRules.normalized($0.text) == ChatDistillationRules.normalized(text) }),
                  pages.allSatisfy({ activeCount[$0, default: 0] < LearningPoint.maximumActivePerSlide }) else { decision.rejected += 1; continue }
            for page in pages { activeCount[page, default: 0] += 1 }
            var point = LearningPoint(text: text, pages: pages)
            point.kind = kind; point.difficulty = min(3, max(0, wire.difficulty)); point.evidence = evidence; point.draft = draft
            point.episodeEndMessageID = endID
            decision.added.append(point)
        }
        return decision
    }

    @discardableResult
    static func apply(_ decision: PointDecision, to lecture: inout Lecture, chatID: UUID) -> PointLandingOutcome {
        var outcome = PointLandingOutcome()
        var activeCount: [Int: Int] = [:]
        for point in lecture.learningPoints where point.included { for page in point.pages { activeCount[page, default: 0] += 1 } }
        for point in decision.merged {
            guard let i = lecture.learningPoints.firstIndex(where: { $0.id == point.id && $0.included && ($0.cardIDs ?? []).isEmpty }) else {
                outcome.rejected += 1; continue
            }
            let current = lecture.learningPoints[i]
            guard !lecture.learningPoints.contains(where: { $0.id != point.id && ChatDistillationRules.normalized($0.text) == ChatDistillationRules.normalized(point.text) }) else {
                outcome.rejected += 1; continue
            }
            let newPages = Set(point.pages).subtracting(current.pages)
            guard newPages.allSatisfy({ activeCount[$0, default: 0] < LearningPoint.maximumActivePerSlide }) else {
                outcome.rejected += 1; continue
            }
            var merged = current
            merged.text = point.text; merged.pages = Array(Set(current.pages + point.pages)).sorted()
            merged.kind = point.kind; merged.difficulty = max(current.difficulty ?? 0, point.difficulty ?? 0)
            var combinedEvidence = current.evidence ?? []
            for item in point.evidence ?? [] where !combinedEvidence.contains(where: { $0.messageID == item.messageID && $0.quote == item.quote }) { combinedEvidence.append(item) }
            merged.evidence = combinedEvidence; merged.draft = point.draft; merged.reviewed = false
            merged.episodeEndMessageID = point.episodeEndMessageID
            lecture.learningPoints[i] = merged
            for page in newPages { activeCount[page, default: 0] += 1 }
            outcome.merged += 1
        }
        for point in decision.added {
            guard !lecture.learningPoints.contains(where: { $0.id == point.id || ChatDistillationRules.normalized($0.text) == ChatDistillationRules.normalized(point.text) }),
                  point.pages.allSatisfy({ activeCount[$0, default: 0] < LearningPoint.maximumActivePerSlide }) else {
                outcome.rejected += 1; continue
            }
            lecture.learningPoints.append(point)
            for page in point.pages { activeCount[page, default: 0] += 1 }
            outcome.added += 1
        }
        updateChat(&lecture, id: chatID) { chat in
            if let cursor = decision.cursor { chat.pointCursor = max(chat.pointCursor ?? 0, min(cursor, chat.messages.count)) }
            else if chat.pointCursor == nil, let start = decision.startCursor { chat.pointCursor = min(start, chat.messages.count) }
        }
        return outcome
    }

    static func updateChat(_ lecture: inout Lecture, id: UUID, _ change: (inout LectureChat) -> Void) {
        if lecture.currentChat.id == id { change(&lecture.currentChat) }
        else if let c = lecture.archivedChats.firstIndex(where: { $0.id == id }) { change(&lecture.archivedChats[c]) }
    }
}
