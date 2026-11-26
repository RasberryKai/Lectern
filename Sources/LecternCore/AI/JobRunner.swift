import Foundation

public struct JobProgress: Equatable, Sendable {
    public var moduleID: UUID
    public var lectureID: UUID
    public var jobID: UUID
    public var stage: String
    public var streamedText: String
    public var warning: String?
    public var read: [ContextRef] = []
    /// What the AI did so far, in order, for the chat's "what is it doing" hints.
    public var activity: [JobActivity] = []

    public mutating func apply(_ event: AIEvent) {
        switch event {
        case .stage(let stage):
            self.stage = stage
            if let step = JobActivity(stage: stage) { note(step) }
        case .text(let text): streamedText += text
        case .read(let ref):
            guard !read.contains(ref) else { return }
            read.append(ref); note(.reading(ref))
        }
    }
    private mutating func note(_ step: JobActivity) { if activity.last != step { activity.append(step) } }
}

/// One step of a running AI job. Reads come from `.read` events; stages only add "thinking" or images.
public enum JobActivity: Equatable, Sendable {
    case thinking
    case reading(ContextRef)
    case images

    init?(stage: String) {
        switch stage {
        // Bookkeeping stages, and ones the matching `.read` events describe better.
        case "Queued", "Writing", "Reading slides…", "Succeeded", "Failed", "Cancelled", "Persistence failed": return nil
        case "Reading uploaded images…": self = .images
        default: self = .thinking
        }
    }
}

/// Every provider call passes through this actor. Durable state lives in LibraryStore;
/// only queue scheduling and transient stream text live here.
public actor JobRunner {
    struct Work: Sendable {
        var moduleID: UUID
        var lectureID: UUID
        var job: Job
        var request: AIRequest
        var learningPointIDs: [UUID]
        var generationDrafts: [GenerationDraftSnapshot] = []
        var generationDraftsFrozen = false
    }
    struct GenerationDraftSnapshot: Codable, Equatable, Sendable {
        var wirePointID: UUID
        var learningPointID: UUID
        var sourceCardID: UUID?
        var sourceCardPages: [Int]?
        var wasPendingDraft: Bool?
        var draftReplacesCardID: UUID?
        var front: String
        var back: String
        var pages: [Int]
        var kind: String?
        var solve: SolveDraft?

        init(wirePointID: UUID, learningPointID: UUID, sourceCardID: UUID?, sourceCardPages: [Int]?, wasPendingDraft: Bool?,
             draftReplacesCardID: UUID?, front: String, back: String, pages: [Int], kind: String?, solve: SolveDraft? = nil) {
            self.wirePointID = wirePointID; self.learningPointID = learningPointID; self.sourceCardID = sourceCardID
            self.sourceCardPages = sourceCardPages
            self.wasPendingDraft = wasPendingDraft; self.draftReplacesCardID = draftReplacesCardID
            self.front = front; self.back = back; self.pages = pages; self.kind = kind
            self.solve = solve
        }

        init(_ draft: PromptBuilder.ChatCardDraft) {
            self.init(wirePointID: draft.wirePointID, learningPointID: draft.originPointID,
                      sourceCardID: draft.sourceCardID, sourceCardPages: draft.sourceCardPages,
                      wasPendingDraft: draft.wasPendingDraft,
                      draftReplacesCardID: draft.draftReplacesCardID, front: draft.front,
                      back: draft.back, pages: draft.pages, kind: draft.kind, solve: draft.solve)
        }
    }
    struct Snapshot: Codable {
        var request: AIRequest
        var learningPointIDs: [UUID]
        /// Missing in older snapshots; retry reconstructs these from the original prompt.
        var generationDrafts: [GenerationDraftSnapshot]? = nil
    }
    private let pdfExporter: any PDFSnapshotExporting
    let store: LibraryStore
    let providers: [AIBackend: any AIProvider]
    var pending: [Work] = []
    var active: [UUID: Task<Void, Never>] = [:]
    var solveVariantSlotBusy = false
    var solveVariantWaiters: [(id: UUID, continuation: CheckedContinuation<Bool, Never>)] = []
    var reservations = Set<String>()
    var progress: [UUID: JobProgress] = [:]
    private var subscribers: [UUID: AsyncStream<JobProgress>.Continuation] = [:]
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    /// Background chat distillations run one at a time per chat, so two triggers never save the same point twice.
    var distilChains: [UUID: (id: UUID, task: Task<Void, Never>)] = [:]

    public init(store: LibraryStore, providers: [any AIProvider], pdfExporter: any PDFSnapshotExporting = PDFExporter()) {
        self.store = store; self.pdfExporter = pdfExporter
        self.providers = Dictionary(providers.map { ($0.backend, $0) }, uniquingKeysWith: { _, last in last })
    }

    public func events() -> AsyncStream<JobProgress> {
        let id = UUID()
        return AsyncStream { continuation in
            subscribers[id] = continuation
            for value in progress.values { continuation.yield(value) }
            continuation.onTermination = { @Sendable _ in Task { await self.removeSubscriber(id) } }
        }
    }
    private func removeSubscriber(_ id: UUID) { subscribers.removeValue(forKey: id) }
    public func currentProgress() -> [JobProgress] { Array(progress.values) }

    @discardableResult
    public func generate(moduleID: UUID, lectureID: UUID, backend: AIBackend = .claudeCLI,
                         model: String = "opus", regenerateAll: Bool = false,
                         additionalInstructions: String = "", replaceExistingCards: Bool = false) async throws -> UUID {
        try await enqueue(kind: .generate, moduleID: moduleID, lectureID: lectureID, backend: backend,
                          model: model, regenerateAll: regenerateAll,
                          additionalInstructions: additionalInstructions, replaceExistingCards: replaceExistingCards)
    }
    @discardableResult
    public func revise(moduleID: UUID, lectureID: UUID, cardID: UUID, feedback: String,
                       backend: AIBackend = .claudeCLI, model: String = "opus") async throws -> UUID {
        guard !feedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AIError.configuration("Revision feedback is empty.") }
        return try await enqueue(kind: .revise, moduleID: moduleID, lectureID: lectureID,
                                 backend: backend, model: model, cardID: cardID, feedback: feedback)
    }
    @discardableResult
    public func ask(moduleID: UUID, lectureID: UUID, anchorPage: Int, context: ThreadContext = .neighbours(1),
                    question: String, cardID: UUID? = nil, backend: AIBackend = .claudeCLI,
                    model: String = "opus", flashcardContext: FlashcardContext? = nil) async throws -> UUID {
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AIError.configuration("Ask a question first.") }
        return try await enqueue(kind: .ask, moduleID: moduleID, lectureID: lectureID, backend: backend,
                                 model: model, cardID: cardID, anchorPage: anchorPage, context: context, question: question,
                                 flashcardContext: flashcardContext)
    }
    @discardableResult
    public func distil(moduleID: UUID, lectureID: UUID, anchorPage: Int, backend: AIBackend = .claudeCLI,
                       model: String = "opus") async throws -> UUID {
        try await enqueue(kind: .distil, moduleID: moduleID, lectureID: lectureID, backend: backend, model: model, anchorPage: anchorPage)
    }

    @discardableResult
    public func chat(moduleID: UUID, lectureID: UUID, anchorPage: Int, context: ThreadContext,
                     question: String, cardID: UUID? = nil, backend: AIBackend = .claudeCLI,
                     model: String = "opus", flashcardContext: FlashcardContext = .none) async throws -> UUID {
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AIError.configuration("Ask a question first.") }
        return try await enqueue(kind: .chat, moduleID: moduleID, lectureID: lectureID, backend: backend,
            model: model, cardID: cardID, anchorPage: anchorPage, context: context, question: question,
            flashcardContext: flashcardContext)
    }

    /// Learning points update existing cards via proposals; they never silently create duplicates.
    public struct ProposeUpdatesResult: Sendable {
        public var jobIDs: [UUID] = []
        public var skippedCardIDs: [UUID] = []
        public var failures: [UUID: String] = [:]
    }
    public func proposeUpdates(moduleID: UUID, lectureID: UUID, page: Int,
                               backend: AIBackend = .claudeCLI, model: String = "opus") async throws -> ProposeUpdatesResult {
        try Task.checkCancellation()
        let lecture = try await store.loadLecture(moduleID: moduleID, lectureID: lectureID)
        let points = (lecture.learningPoints + lecture.threads.flatMap(\.learningPoints).filter { old in !lecture.learningPoints.contains(where: { $0.id == old.id }) }).filter { $0.included && $0.pages.contains(page) }
        guard !points.isEmpty else { throw AIError.configuration("No included learning points for this slide.") }
        let feedback = points.map(\.text).joined(separator: "\n")
        var result = ProposeUpdatesResult()
        for card in lecture.cards where !card.isSuperseded && card.verdict != .bad && card.sourcePages.contains(page) {
            if card.proposal != nil || lecture.jobs.contains(where: { $0.state == .running && $0.kind == .revise && $0.targetCardID == card.id }) {
                result.skippedCardIDs.append(card.id); continue
            }
            do {
                result.jobIDs.append(try await revise(moduleID: moduleID, lectureID: lectureID, cardID: card.id,
                    feedback: feedback, backend: backend, model: model))
            } catch {
                if Task.isCancelled || error is CancellationError {
                    for id in result.jobIDs { try await cancel(moduleID: moduleID, lectureID: lectureID, jobID: id) }
                    throw CancellationError()
                }
                result.failures[card.id] = error.localizedDescription
            }
        }
        return result
    }

    private func enqueue(kind: JobKind, moduleID: UUID, lectureID: UUID, backend: AIBackend, model: String,
                         regenerateAll: Bool = false, cardID: UUID? = nil, feedback: String = "",
                         anchorPage: Int? = nil, context: ThreadContext = .neighbours(1), question: String = "",
                         additionalInstructions: String = "", replaceExistingCards: Bool = false,
                         flashcardContext: FlashcardContext? = nil) async throws -> UUID {
        try Task.checkCancellation()
        try await store.assertModuleEditable(moduleID: moduleID)
        guard providers[backend] != nil else { throw AIError.configuration("No provider configured for \(backend.rawValue).") }
        let key = "\(lectureID):\(kind.rawValue):\(cardID?.uuidString ?? ""):\(anchorPage ?? 0)"
        guard reservations.insert(key).inserted else { throw AIError.configuration("This operation is already being prepared.") }
        defer { reservations.remove(key); schedule() }
        let resolvedModel: String
        if kind == .distil {
            switch backend {
            case .claudeCLI: resolvedModel = AISettings.learningPointCLIModel
            case .messagesAPI: resolvedModel = AISettings.learningPointAPIModel
            case .codexCLI: resolvedModel = Self.codexModel(model)
            }
        } else { resolvedModel = try Self.cardModel(model, backend: backend) }
        let modules = try await store.modules()
        guard let module = modules.first(where: { $0.id == moduleID }) else { throw AIError.configuration("Module no longer exists.") }
        let initial = try await store.loadLecture(moduleID: moduleID, lectureID: lectureID)
        let card: Card?
        if let cardID {
            guard let found = initial.cards.first(where: { $0.id == cardID && !$0.isSuperseded }) else { throw LectureError.missingCard(cardID) }
            card = found
        } else { card = nil }
        let anchor = anchorPage
        var thread: SlideThread?
        var pages: [Int]
        switch kind {
        case .generate:
            pages = regenerateAll || replaceExistingCards ? initial.slides.filter(\.isSelected).map { $0.pageIndex + 1 } : initial.uncoveredSelectedPages
            guard !pages.isEmpty else { throw AIError.configuration("No selected slides without cards. Choose Regenerate all explicitly to include covered slides.") }
        case .revise:
            guard let card, card.proposal == nil else { throw AIError.configuration("Resolve this card's existing proposal first.") }
            pages = card.sourcePages
        case .ask, .chat, .distil:
            guard let anchor, anchor == 0 || ((1...max(1, initial.pageCount)).contains(anchor) && initial.pageCount > 0) else { throw AIError.configuration("Choose a valid chat context.") }
            thread = initial.threads.first(where: { $0.anchorPage == anchor }) ?? SlideThread(anchorPage: anchor, context: context)
            if kind == .ask || kind == .chat {
                thread?.context = context
                thread?.flashcardContext = flashcardContext ?? (card == nil ? FlashcardContext.none : .current)
            }
            guard let currentThread = thread else { throw AIError.configuration("Thread could not be prepared.") }
            switch currentThread.context {
            case .none: pages = []
            case .slide:
                guard anchor > 0 else { throw AIError.configuration("No current slide is available. Choose No slide or Whole lecture.") }
                pages = [anchor]
            case .neighbours(let distance):
                guard distance >= 0 && distance <= 100 else { throw AIError.configuration("Neighbour range must be 0 to 100.") }
                guard anchor > 0 && initial.pageCount > 0 else { throw AIError.configuration("No current slide is available. Choose No slide.") }
                pages = Array(max(1, anchor - distance)...min(initial.pageCount, anchor + distance))
            case .lecture: pages = initial.pageCount > 0 ? Array(1...initial.pageCount) : []
            }
        }
        pages = Array(Set(pages)).sorted()
        guard pages.count <= 100 else { throw AIError.limit("v1 supports up to 100 slides per call. Reduce the selected context.") }
        guard pages.allSatisfy({ $0 > 0 && $0 <= initial.pageCount }) else { throw AIError.configuration("Repair invalid source slide links before sending this request.") }
        let allLectures = try await store.lectures(in: moduleID)
        let fronts = allLectures.filter { !replaceExistingCards || $0.id != lectureID }
            .flatMap(\.cards).filter { $0.verdict != .bad && !$0.isSuperseded }.map(\.front)
        let rules = kind == .generate || kind == .revise ? try await store.loadRules() : ""
        let contextCards: [Card]?
        if kind == .ask || kind == .chat {
            switch thread?.flashcardContext ?? .none {
            case .none: contextCards = []
            case .all: contextCards = initial.cards.filter { !$0.isSuperseded }
            case .current:
                guard card != nil else { throw AIError.configuration("Select a flashcard to use This flashcard.") }
                contextCards = nil // Sent once through CURRENT CARD below.
            }
        } else { contextCards = nil }
        let prompt = try PromptBuilder.build(kind: kind, rules: rules, module: module, lecture: initial,
                                             pages: pages, existingFronts: fronts,
                                             card: (kind == .ask || kind == .chat) && thread?.flashcardContext != .current ? nil : card, feedback: feedback,
                                             thread: thread, question: question, generationInstructions: additionalInstructions,
                                             contextCards: contextCards, replacesExistingCards: replaceExistingCards)
        let generationDrafts = kind == .generate
            ? PromptBuilder.chatCardDrafts(lecture: initial, pages: pages, replacesExistingCards: replaceExistingCards).map(GenerationDraftSnapshot.init)
            : []
        var job = Job(kind: kind, pages: pages, rulesVersion: PromptBuilder.hash(rules), backend: backend,
                      targetCardID: cardID, threadID: thread?.id, baseRevisionID: card?.currentRevisionID, prompt: prompt, model: resolvedModel)
        job.replacesExistingCards = replaceExistingCards ? true : nil
        if kind == .chat {
            let editableCards = thread?.flashcardContext == .current ? card.map { [$0] } ?? [] : contextCards ?? []
            job.chatCardVersions = editableCards.filter { $0.solve == nil }.compactMap { card in
                card.currentRevisionID.map { ChatCardVersion(cardID: card.id, revisionID: $0,
                    verdict: card.verdict, mathInterpretations: card.mathInterpretations) }
            }
        }
        let directory = store.jobDirectory(moduleID: moduleID, lectureID: lectureID, jobID: job.id)
        var committed = false
        defer { if !committed { try? FileManager.default.removeItem(at: directory) } }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var pdf: Data?
        if !pages.isEmpty {
            let destination = directory.appendingPathComponent("input.pdf")
            _ = try await pdfExporter.export(PDFExportPlan(sourceURL: store.sourceURL(moduleID: moduleID, lectureID: lectureID),
                selectedPageIndices: pages.map { $0 - 1 }, notesByPageIndex: Dictionary(uniqueKeysWithValues: initial.slides.map { ($0.pageIndex, $0.note) })), to: destination)
            try Task.checkCancellation()
            pdf = try Data(contentsOf: destination)
        }
        try Task.checkCancellation()
        let pointIDs = (initial.learningPoints + initial.threads.flatMap(\.learningPoints)).filter { $0.included && $0.pages.contains(where: pages.contains) }.map(\.id)
        var request = AIRequest(jobID: job.id, kind: kind, model: resolvedModel, prompt: prompt, pdf: pdf, workingDirectory: directory)
        request.diagnosticContext = [
            "moduleID": moduleID.uuidString,
            "lectureID": lectureID.uuidString,
            "purpose": kind.rawValue
        ]
        job.inputHash = try Self.inputHash(request)
        job.pdfLayoutRevision = initial.pdfLayoutRevision
        var persistedRequest = request; persistedRequest.pdf = nil
        try JSONEncoder().encode(Snapshot(request: persistedRequest, learningPointIDs: pointIDs, generationDrafts: generationDrafts)).write(to: directory.appendingPathComponent("snapshot.json"), options: .atomic)
        let frozenJob = job
        let frozenThread = thread
        try Task.checkCancellation()
        _ = try await store.updateLecture(moduleID: moduleID, lectureID: lectureID) { lecture in
            try Task.checkCancellation()
            guard lecture.pdfLayoutRevision == frozenJob.pdfLayoutRevision else { throw LectureError.staleSnapshot }
            if lecture.jobs.contains(where: { existing in
                existing.state == .running && (kind == .generate ? existing.kind == .generate :
                    (cardID != nil && kind == .revise ? existing.kind == .revise && existing.targetCardID == cardID :
                        existing.threadID != nil && existing.threadID == frozenThread?.id))
            }) { throw AIError.configuration("A job for this scope is already running.") }
            if let target = cardID, kind == .revise, lecture.cards.first(where: { $0.id == target })?.proposal != nil {
                throw AIError.configuration("A proposal arrived while this request was being prepared. Resolve it first.")
            }
            if var thread = frozenThread {
                if let current = lecture.threads.first(where: { $0.anchorPage == thread.anchorPage }) {
                    thread.id = current.id
                    guard thread.id == frozenJob.threadID else { throw AIError.configuration("Thread changed while preparing. Try again.") }
                    thread.messages = current.messages; thread.learningPoints = current.learningPoints
                }
                if kind == .ask || kind == .chat { thread.messages.append(ChatMessage(role: .user, text: question)) }
                try LectureReducer.reduce(&lecture, action: .upsertThread(thread))
            }
            if kind == .revise, let cardID {
                var message = ChatMessage(role: .user, text: feedback); message.context = [.card(cardID)]; message.editJobID = frozenJob.id
                if lecture.currentChat.messages.isEmpty { lecture.currentChat.title = LectureChat.title(for: feedback) }
                lecture.currentChat.messages.append(message)
            }
            try LectureReducer.reduce(&lecture, action: .startJob(frozenJob))
        }
        committed = true
        if Task.isCancelled {
            try await cancel(moduleID: moduleID, lectureID: lectureID, jobID: job.id)
            throw CancellationError()
        }
        pending.append(Work(moduleID: moduleID, lectureID: lectureID, job: job, request: request,
                            learningPointIDs: pointIDs, generationDrafts: generationDrafts, generationDraftsFrozen: true))
        emit(moduleID: moduleID, lectureID: lectureID, jobID: job.id, event: .stage("Queued"))
        schedule()
        return job.id
    }

    private static func codexModel(_ model: String) -> String {
        model.isEmpty || model == "opus" ? AISettings.defaultCodexModel : model
    }

    static func cardModel(_ model: String, backend: AIBackend) throws -> String {
        switch backend {
        case .claudeCLI: return model.isEmpty ? AISettings.defaultCLIModel : model
        case .codexCLI: return codexModel(model)
        case .messagesAPI:
            let resolved = model == "opus" || model.isEmpty ? AISettings.defaultMessagesAPIModel : model
            guard resolved.hasPrefix("claude-") else { throw AIError.configuration("Messages API needs a full model ID such as claude-opus-5-5.") }
            return resolved
        }
    }

    private struct PromptDraftSnapshot: Decodable {
        var point: UUID
        var front: String
        var back: String
        var pages: [Int]
        var kind: String?
        var solve: SolveDraft?
    }

    /// Older immutable job snapshots did not persist draft expectations separately. Their
    /// original prompt still contains the complete draft payload, keyed by the old root point ID.
    private static func generationDraftsFromOriginalPrompt(_ prompt: String) -> [GenerationDraftSnapshot] {
        guard let marker = prompt.range(of: "CHAT CARD DRAFTS"),
              let separator = prompt[marker.upperBound...].range(of: ":\n") else { return [] }
        let payload = prompt[separator.upperBound...]
        let end = payload.range(of: "\n\n")?.lowerBound ?? payload.endIndex
        guard let data = String(payload[..<end]).data(using: .utf8),
              let drafts = try? JSONDecoder().decode([PromptDraftSnapshot].self, from: data) else { return [] }
        return drafts.map { draft in
            GenerationDraftSnapshot(wirePointID: draft.point, learningPointID: draft.point, sourceCardID: nil,
                                    sourceCardPages: nil, wasPendingDraft: nil, draftReplacesCardID: nil,
                                    front: draft.front, back: draft.back, pages: draft.pages, kind: draft.kind, solve: draft.solve)
        }
    }

    private static func generationDraftIsCurrent(_ draft: GenerationDraftSnapshot, in lecture: Lecture) -> Bool {
        guard let point = lecture.learningPoints.first(where: { $0.id == draft.learningPointID }), point.included else { return false }
        if let sourceCardID = draft.sourceCardID {
            guard let card = lecture.cards.first(where: { $0.id == sourceCardID && !$0.isSuperseded }),
                  (point.cardIDs ?? []).contains(sourceCardID) || card.learningPointID == point.id,
                  card.front == draft.front, card.back == draft.back,
                  card.solve?.draft == draft.solve,
                  draft.sourceCardPages == nil || card.sourcePages == draft.sourceCardPages else { return false }
            return true
        }

        func matchesPendingDraft() -> Bool {
            guard point.isPendingDraft, let current = point.draft,
                  current.front == draft.front, current.back == draft.back else { return false }
            return draft.wasPendingDraft != true || current.replacesCardID == draft.draftReplacesCardID
        }
        func matchesLinkedCard() -> Bool {
            let linkedIDs = Set(point.cardIDs ?? [])
            return lecture.cards.contains { card in
                !card.isSuperseded && (linkedIDs.contains(card.id) || card.learningPointID == point.id) &&
                    card.front == draft.front && card.back == draft.back && card.solve?.draft == draft.solve
            }
        }

        switch draft.wasPendingDraft {
        case true: return matchesPendingDraft()
        case false: return matchesLinkedCard()
        case nil: return matchesPendingDraft() || matchesLinkedCard()
        }
    }

    private static func normalizedCardKey(front: String, back: String, solve: SolveDraft?) -> String {
        func normalize(_ text: String) -> String {
            text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        if let solve = solve?.validated { return "solve\u{0}" + normalize(solve.skill) + "\u{0}" + solve.sample.signature }
        return normalize(front) + "\u{0}" + normalize(back)
    }

    static func inputHash(_ request: AIRequest) throws -> String {
        struct Input: Encodable { var kind: JobKind; var model: String; var systemPrompt: String; var prompt: String; var pdf: Data?; var chatSnapshot: ChatSnapshot? }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return PromptBuilder.hash(try encoder.encode(Input(kind: request.kind, model: request.model,
            systemPrompt: request.systemPrompt, prompt: request.prompt, pdf: request.pdf, chatSnapshot: request.chatSnapshot)))
    }

    func schedule() {
        while active.count + (solveVariantSlotBusy ? 1 : 0) < 3 && !pending.isEmpty {
            let work = pending.removeFirst()
            active[work.job.id] = Task { await self.run(work) }
        }
        if active.count < 3 && !solveVariantSlotBusy && !solveVariantWaiters.isEmpty {
            solveVariantSlotBusy = true
            solveVariantWaiters.removeFirst().continuation.resume(returning: true)
        }
        if active.isEmpty && pending.isEmpty && reservations.isEmpty && !solveVariantSlotBusy && solveVariantWaiters.isEmpty {
            let waiters = idleWaiters; idleWaiters.removeAll(); waiters.forEach { $0.resume() }
        }
    }
    private func run(_ work: Work) async {
        var autoDistilAnchor: Int?
        var chatSucceeded = false
        var executionTrace: AIInteractionTrace?
        do {
            try await AIDiagnostics.withTrace(request: work.request, backend: work.job.backend) { trace in
                executionTrace = trace
                do {
                    trace.record("job_execution_started", ["jobKind": work.job.kind.rawValue])
                    trace.phase("provider_execution")
                    try Task.checkCancellation()
                    guard let provider = providers[work.job.backend] else { throw AIError.configuration("Provider unavailable.") }
                    emit(moduleID: work.moduleID, lectureID: work.lectureID, jobID: work.job.id, event: .stage("Sending"))
                    trace.record("provider_call_started", ["backend": work.job.backend.rawValue, "model": work.job.model])
                    // One ordered consumer per attempt: separate Tasks per event could deliver text and reads out of order.
                    let (events, sink) = AsyncStream<AIEvent>.makeStream()
                    let forwarding = Task { for await event in events { self.receive(work: work, event: event) } }
                    let response: AIResponse
                    do {
                        response = try await provider.execute(work.request) { event in
                            trace.event(event)
                            sink.yield(event)
                        }
                    } catch {
                        sink.finish(); await forwarding.value
                        throw error
                    }
                    sink.finish(); await forwarding.value
                    recordRunnerResponse(response, trace: trace)
                    try Task.checkCancellation()
                    if work.request.chatSnapshot != nil {
                        try await landLectureChat(work, response: response, trace: trace)
                        chatSucceeded = true
                    } else {
                        autoDistilAnchor = try await land(work, response: response, trace: trace)
                    }
                    trace.record("job_landed", ["state": JobState.succeeded.rawValue])
                    emit(moduleID: work.moduleID, lectureID: work.lectureID, jobID: work.job.id, event: .stage("Succeeded"))
                } catch {
                    let cancelled = error is CancellationError || Task.isCancelled
                    let errorText = error.localizedDescription
                    let logPath = diagnosticLogPath(trace)
                    let diagnosticError = errorText + (logPath.map { "\nAI diagnostics: \($0)" } ?? "")
                    trace.failure(error, event: cancelled ? "job_cancelled" : "job_execution_failed")
                    trace.phase("failure_state_persistence")
                    do {
                        let updated = try await store.updateLecture(moduleID: work.moduleID, lectureID: work.lectureID) { lecture in
                            guard let i = lecture.jobs.firstIndex(where: { $0.id == work.job.id }), lecture.jobs[i].state == .running else { return }
                            lecture.jobs[i].state = cancelled ? .cancelled : .failed
                            lecture.jobs[i].error = cancelled ? nil : diagnosticError
                            lecture.jobs[i].finishedAt = Date()
                        }
                        let state = updated.jobs.first(where: { $0.id == work.job.id })?.state.rawValue ?? "missing"
                        trace.record("job_failure_state_persisted", ["state": state, "intendedState": cancelled ? "cancelled" : "failed"])
                        emit(moduleID: work.moduleID, lectureID: work.lectureID, jobID: work.job.id,
                             event: .stage(cancelled ? "Cancelled" : "Failed"), warning: cancelled ? nil : diagnosticError)
                    } catch let persistenceError {
                        trace.failure(persistenceError, event: "job_failure_state_persistence_failed", fields: ["jobError": errorText])
                        var warning = "\(errorText)\nJob-state persistence failed: \(persistenceError.localizedDescription)"
                        if let logPath { warning += "\nAI diagnostics: \(logPath)" }
                        emit(moduleID: work.moduleID, lectureID: work.lectureID, jobID: work.job.id,
                             event: .stage("Persistence failed"), warning: warning)
                    }
                    throw error
                }
            }
        } catch {
            // The trace records this outcome; keep the runner alive for queued work.
        }
        active.removeValue(forKey: work.job.id)
        if chatSucceeded, !Task.isCancelled, let chatID = work.job.threadID {
            enqueueChatDistillation(ChatDistillationRequest(moduleID: work.moduleID, lectureID: work.lectureID, chatID: chatID,
                backend: work.job.backend, model: work.job.model, trigger: .answer(jobID: work.job.id)))
        }
        if let anchor = autoDistilAnchor {
            do { _ = try await distil(moduleID: work.moduleID, lectureID: work.lectureID, anchorPage: anchor, backend: work.job.backend, model: work.job.model) }
            catch {
                executionTrace?.record("automatic_distil_enqueue_failed", ["error": error.localizedDescription])
                let logPath = executionTrace.flatMap(diagnosticLogPath)
                let suffix = logPath.map { "\nAI diagnostics: \($0)" } ?? ""
                emit(moduleID: work.moduleID, lectureID: work.lectureID, jobID: work.job.id, event: .stage("Succeeded"), warning: "Answer saved; learning-point extraction could not start: \(error.localizedDescription)\(suffix)")
            }
        }
        schedule()
    }
    func finishDistil(_ id: UUID) { active.removeValue(forKey: id); schedule() }
    private func receive(work: Work, event: AIEvent) {
        guard active[work.job.id] != nil else { return }
        emit(moduleID: work.moduleID, lectureID: work.lectureID, jobID: work.job.id, event: event)
    }
    func recordRunnerResponse(_ response: AIResponse, trace: AIInteractionTrace) {
        trace.recordUsage(response.usage)
        if let data = try? JSONEncoder().encode(response), let object = try? JSONSerialization.jsonObject(with: data) {
            trace.writeJSON("runner-response.json", object)
        }
        trace.record("runner_response_captured", ["contentCharacters": response.content.count])
    }
    func diagnosticLogPath(_ trace: AIInteractionTrace) -> String? {
        let directory = trace.directory
        let files = ["summary.json", "events.jsonl", "request.json", "runner-response.json"]
        guard files.contains(where: { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }) else { return nil }
        return directory.path
    }
    func emit(moduleID: UUID, lectureID: UUID, jobID: UUID, event: AIEvent, warning: String? = nil) {
        var value = progress[jobID] ?? JobProgress(moduleID: moduleID, lectureID: lectureID, jobID: jobID, stage: "Queued", streamedText: "")
        value.apply(event)
        if let warning { value.warning = warning }
        progress[jobID] = value; subscribers.values.forEach { $0.yield(value) }
    }

    /// Landing reads the latest lecture, so edits made while the provider ran are preserved.
    /// Cards/proposal/thread and succeeded state commit in the same atomic lecture write.
    private func land(_ work: Work, response: AIResponse, trace: AIInteractionTrace) async throws -> Int? {
        trace.phase("response_validation")
        let data = Data(response.content.utf8)
        var generated: GeneratedCards?; var revised: RevisedCards?; var points: DistilledPoints?; var chat: ChatReply?
        switch work.job.kind {
        case .generate: generated = try JSONDecoder().decode(GeneratedCards.self, from: data)
        case .revise:
            revised = try JSONDecoder().decode(RevisedCards.self, from: data)
            guard let count = revised?.cards.count, (1...3).contains(count) else { throw AIError.invalidResponse("Revision must return 1 to 3 cards.") }
        case .distil:
            points = try JSONDecoder().decode(DistilledPoints.self, from: data)
            guard let points, points.learningPoints.count <= 3, points.learningPoints.allSatisfy({ !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.pages.isEmpty && $0.pages.allSatisfy(work.job.pages.contains) }) else { throw AIError.invalidResponse("Invalid learning points or source slide references.") }
        case .ask: guard !response.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AIError.invalidResponse("AI returned an empty answer.") }
        case .chat:
            chat = try JSONDecoder().decode(ChatReply.self, from: data)
            guard let chat, !chat.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AIError.invalidResponse("AI returned an empty chat message.")
            }
        }
        let frozenGenerated = generated, frozenRevised = revised, frozenPoints = points, frozenChat = chat
        trace.phase("lecture_persistence")
        let result = try await store.updateLecture(moduleID: work.moduleID, lectureID: work.lectureID) { lecture in
            guard let j = lecture.jobs.firstIndex(where: { $0.id == work.job.id }), lecture.jobs[j].state == .running else { throw LectureError.jobNotRunning(work.job.id) }
            switch work.job.kind {
            case .generate:
                guard let output = frozenGenerated else { throw AIError.invalidResponse("Missing generation payload.") }
                guard output.skipped.allSatisfy({ work.job.pages.contains($0.slide) && !$0.reason.isEmpty }) else { throw AIError.invalidResponse("Invalid skipped-slide entry.") }
                let snapshotDrafts = work.generationDraftsFrozen
                    ? work.generationDrafts
                    : Self.generationDraftsFromOriginalPrompt(work.request.prompt)
                let expected = snapshotDrafts.filter { work.learningPointIDs.contains($0.learningPointID) }
                let expectedByWireID = Dictionary(expected.map { ($0.wirePointID, $0) }, uniquingKeysWith: { first, _ in first })
                let liveExpected = expected.filter { Self.generationDraftIsCurrent($0, in: lecture) }
                let liveByWireID = Dictionary(liveExpected.map { ($0.wirePointID, $0) }, uniquingKeysWith: { first, _ in first })

                // A repeated explicit point key is a duplicate model result, not another ordinary card.
                var seenPointLabels = Set<String>()
                var linked = Set<UUID>()
                var linkedCards: [CardDraft] = []
                var unlinkedCards: [CardDraft] = []
                var invalidSolvePages = Set<Int>()
                for wire in output.cards {
                    if let solve = wire.solve, solve.validated == nil {
                        invalidSolvePages.formUnion(wire.sourceSlides)
                        continue
                    }
                    if let label = wire.point {
                        let identity = UUID(uuidString: label)?.uuidString.lowercased() ?? label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                        guard seenPointLabels.insert(identity).inserted else { continue }
                        if let pointID = UUID(uuidString: label) {
                            if let draft = expectedByWireID[pointID] {
                                // The request's draft changed while the provider was running. Drop this stale
                                // result instead of consuming the current point or restoring obsolete text.
                                guard let current = liveByWireID[pointID] else { continue }
                                guard (current.solve == nil) == (wire.solve == nil) else { continue }
                                var card = wire.draft
                                card.learningPointID = current.learningPointID
                                linkedCards.append(card)
                                linked.insert(draft.wirePointID)
                                continue
                            }
                        }
                    }
                    unlinkedCards.append(wire.draft)
                }

                // A current linked card may have been edited or split after the request snapshot.
                // Re-add those latest descendants after Replace so stale model output cannot erase them.
                var preservedCards: [CardDraft] = []
                var preservedCardIDs = Set<UUID>()
                if work.job.replacesExistingCards == true {
                    for pointID in Set(expected.map(\.learningPointID)) {
                        guard let point = lecture.learningPoints.first(where: { $0.id == pointID }), point.included else { continue }
                        let unchangedSourceIDs = Set(liveExpected.filter { $0.learningPointID == pointID }.compactMap(\.sourceCardID))
                        let linkedIDs = Set(point.cardIDs ?? [])
                        for card in lecture.cards where !card.isSuperseded &&
                            (linkedIDs.contains(card.id) || card.learningPointID == pointID) &&
                            !unchangedSourceIDs.contains(card.id) && preservedCardIDs.insert(card.id).inserted {
                            let currentPages = card.sourcePages.filter(work.job.pages.contains)
                            let sourcePages = currentPages.isEmpty ? point.pages.filter(work.job.pages.contains) : currentPages
                            guard !sourcePages.isEmpty else { continue }
                            var preserved = CardDraft(front: card.front, back: card.back, sourcePages: sourcePages, flag: card.flag, solve: card.solve?.draft)
                            preserved.learningPointID = pointID
                            preservedCards.append(preserved)
                        }
                    }
                }

                let expectedSignatures = Set(expected.map { Self.normalizedCardKey(front: $0.front, back: $0.back, solve: $0.solve) })
                let linkedSignatures = Set((linkedCards + preservedCards).map { Self.normalizedCardKey(front: $0.front, back: $0.back, solve: $0.solve) })
                var unlinkedSignatures = Set<String>()
                let uniqueUnlinked = unlinkedCards.filter { draft in
                    let key = Self.normalizedCardKey(front: draft.front, back: draft.back, solve: draft.solve)
                    guard !expectedSignatures.contains(key), !linkedSignatures.contains(key) else { return false }
                    return unlinkedSignatures.insert(key).inserted
                }

                var cards = linkedCards + preservedCards + uniqueUnlinked
                for draft in liveExpected where !linked.contains(draft.wirePointID) {
                    cards.append(CardDraft(front: draft.front, back: draft.back, sourcePages: draft.pages,
                                           learningPointID: draft.learningPointID, solve: draft.solve))
                }
                let covered = Set(cards.flatMap(\.sourcePages) + output.skipped.map(\.slide))
                let missing = work.job.pages.filter { !covered.contains($0) }.map { page in
                    let reason = invalidSolvePages.contains(page) ? "Model returned a solve exercise with an invalid answer key." : "Model returned no card or skip reason; review this slide."
                    return SkippedSlide(slide: page, reason: reason)
                }
                try LectureReducer.reduce(&lecture, action: .landGeneration(jobID: work.job.id, cards: cards, skipped: output.skipped + missing, usage: response.usage))
            case .revise:
                guard let output = frozenRevised else { throw AIError.invalidResponse("Missing revision payload.") }
                try LectureReducer.reduce(&lecture, action: .landProposal(jobID: work.job.id, cards: output.cards.map(\.draft), rationale: output.rationale, usage: response.usage))
                var message = ChatMessage(role: .assistant, text: output.rationale.isEmpty ? "Revision ready to review on the card." : output.rationale); message.editJobID = work.job.id
                if let id = work.job.targetCardID { message.context = [.card(id)] }
                if let current = lecture.currentChat.messages.first(where: { $0.editJobID == work.job.id && $0.role == .user }) { message.context = current.context; lecture.currentChat.messages.append(message) }
                else if let c = lecture.archivedChats.firstIndex(where: { $0.messages.contains(where: { $0.editJobID == work.job.id && $0.role == .user }) }) { lecture.archivedChats[c].messages.append(message) }
            case .ask, .chat, .distil:
                guard let t = lecture.threads.firstIndex(where: { $0.id == work.job.threadID }) else { throw AIError.invalidResponse("The slide thread no longer exists.") }
                if work.job.kind == .ask || work.job.kind == .chat {
                    if let chat = frozenChat {
                        let solveCardIDs = Set(lecture.cards.filter { $0.solve != nil }.map(\.id))
                        try LectureReducer.reduce(&lecture, action: .applyChatEdits(jobID: work.job.id, edits: chat.edits.filter { !solveCardIDs.contains($0.cardID) }))
                    }
                    let text = frozenChat?.message ?? response.content
                    let expression = try NSRegularExpression(pattern: #"\[slide (\d+)\]"#, options: .caseInsensitive)
                    let range = NSRange(text.startIndex..., in: text)
                    let citations = expression.matches(in: text, range: range).compactMap { match -> Int? in
                        guard let r = Range(match.range(at: 1), in: text), let p = Int(text[r]), work.job.pages.contains(p) else { return nil }; return p
                    }
                    var message = ChatMessage(role: .assistant, text: text, citedPages: Array(Set(citations)).sorted())
                    if lecture.jobs[j].chatEditUndo?.isEmpty == false { message.editJobID = work.job.id }
                    lecture.threads[t].messages.append(message)
                } else if let output = frozenPoints {
                    // Preserve user edits, exclusions and IDs across repeated distillation.
                    for point in output.learningPoints where !lecture.threads[t].learningPoints.contains(where: { $0.text == point.text && $0.pages == point.pages }) {
                        lecture.threads[t].learningPoints.append(LearningPoint(text: point.text, pages: point.pages))
                    }
                }
                lecture.jobs[j].state = .succeeded; lecture.jobs[j].usage = response.usage; lecture.jobs[j].finishedAt = Date()
            }
                for p in lecture.learningPoints.indices where work.learningPointIDs.contains(lecture.learningPoints[p].id) {
                    if !lecture.learningPoints[p].usedBy.contains(work.job.id) { lecture.learningPoints[p].usedBy.append(work.job.id) }
                }
                for t in lecture.threads.indices {
                    for p in lecture.threads[t].learningPoints.indices where work.learningPointIDs.contains(lecture.threads[t].learningPoints[p].id) {
                        if !lecture.threads[t].learningPoints[p].usedBy.contains(work.job.id) { lecture.threads[t].learningPoints[p].usedBy.append(work.job.id) }
                    }
                }
        }
        trace.record("lecture_persisted", ["jobID": work.job.id.uuidString])
        if let output = generated, output.cards.isEmpty || output.cards.count > work.job.pages.count * 3 {
            emit(moduleID: work.moduleID, lectureID: work.lectureID, jobID: work.job.id, event: .stage("Succeeded"), warning: output.cards.isEmpty ? "No cards returned. Inspect skipped-slide reasons." : "More than 3 cards per slide on average. Review the scope and card quality.")
        }
        return (work.job.kind == .ask || (work.job.kind == .chat && chat?.edits.isEmpty == true)) && !work.job.pages.isEmpty
            ? result.threads.first(where: { $0.id == work.job.threadID })?.anchorPage : nil
    }

    public func cancel(moduleID: UUID, lectureID: UUID, jobID: UUID) async throws {
        // Persist cancellation before signalling so a racing completion cannot land cards.
        let updated = try await store.updateLecture(moduleID: moduleID, lectureID: lectureID) { lecture in
            guard let i = lecture.jobs.firstIndex(where: { $0.id == jobID }) else { throw LectureError.missingJob(jobID) }
            guard lecture.jobs[i].state == .running else { return }
            lecture.jobs[i].state = .cancelled; lecture.jobs[i].finishedAt = Date()
        }
        guard updated.jobs.first(where: { $0.id == jobID })?.state == .cancelled else { return }
        pending.removeAll { $0.job.id == jobID }; active[jobID]?.cancel()
        emit(moduleID: moduleID, lectureID: lectureID, jobID: jobID, event: .stage("Cancelled"))
        schedule()
    }

    public func retry(moduleID: UUID, lectureID: UUID, jobID: UUID) async throws {
        let current = try await store.loadLecture(moduleID: moduleID, lectureID: lectureID)
        if let job = current.jobs.first(where: { $0.id == jobID }), job.kind == .chat, job.isLectureChat == true, job.threadID == current.currentChat.id {
            try await retryLectureChat(moduleID: moduleID, lectureID: lectureID, jobID: jobID); return
        }
        try await store.assertModuleEditable(moduleID: moduleID)
        try Task.checkCancellation()
        let reservation = "retry:\(jobID)"
        guard reservations.insert(reservation).inserted else { throw AIError.configuration("Retry is already preparing.") }
        defer { reservations.remove(reservation); schedule() }
        guard active[jobID] == nil, !pending.contains(where: { $0.job.id == jobID }) else { throw AIError.configuration("Job is still active.") }
        let lecture = try await store.loadLecture(moduleID: moduleID, lectureID: lectureID)
        guard var job = lecture.jobs.first(where: { $0.id == jobID }), [.failed, .cancelled, .interrupted].contains(job.state) else { throw AIError.configuration("Only failed, cancelled or interrupted jobs can be retried.") }
        guard job.pdfLayoutRevision == lecture.pdfLayoutRevision else {
            throw AIError.configuration("The slide order changed since this job. Start a new request.")
        }
        if job.kind == .chat, let versions = job.chatCardVersions,
           !versions.allSatisfy({ version in lecture.cards.contains { version.matches($0) } }) {
            throw AIError.configuration("These flashcards changed since this chat request. Send your message again to use the current cards.")
        }
        guard providers[job.backend] != nil else { throw AIError.configuration("Configure the original backend before retrying.") }
        let directory = store.jobDirectory(moduleID: moduleID, lectureID: lectureID, jobID: jobID)
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("snapshot.json").path) else { throw AIError.configuration("This job snapshot has expired or is missing. Start a new job instead.") }
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: directory.appendingPathComponent("snapshot.json")))
        var request = snapshot.request
        request.workingDirectory = directory
        let pdfURL = directory.appendingPathComponent("input.pdf")
        request.pdf = FileManager.default.fileExists(atPath: pdfURL.path) ? try Data(contentsOf: pdfURL) : nil
        guard request.jobID == jobID, request.kind == job.kind, try Self.inputHash(request) == job.inputHash else { throw AIError.invalidResponse("The immutable job snapshot is missing or changed. Start a new job instead.") }
        job.state = .running; job.error = nil; job.finishedAt = nil
        let frozen = job
        try Task.checkCancellation()
        _ = try await store.updateLecture(moduleID: moduleID, lectureID: lectureID) { lecture in
            try Task.checkCancellation()
            guard lecture.pdfLayoutRevision == frozen.pdfLayoutRevision else { throw LectureError.staleSnapshot }
            guard let i = lecture.jobs.firstIndex(where: { $0.id == jobID }), [.failed, .cancelled, .interrupted].contains(lecture.jobs[i].state) else { throw AIError.configuration("This job has already landed.") }
            if frozen.kind == .chat, let versions = frozen.chatCardVersions,
               !versions.allSatisfy({ version in lecture.cards.contains { version.matches($0) } }) {
                throw AIError.configuration("These flashcards changed since this chat request. Send your message again to use the current cards.")
            }
            guard !lecture.jobs.contains(where: { $0.state == .running && $0.id != jobID && ($0.kind == .generate && frozen.kind == .generate || $0.targetCardID != nil && $0.targetCardID == frozen.targetCardID || $0.threadID != nil && $0.threadID == frozen.threadID) }) else { throw AIError.configuration("Another job for this scope is running.") }
            lecture.jobs[i] = frozen
        }
        if Task.isCancelled {
            try await cancel(moduleID: moduleID, lectureID: lectureID, jobID: jobID)
            throw CancellationError()
        }
        progress.removeValue(forKey: jobID)
        emit(moduleID: moduleID, lectureID: lectureID, jobID: jobID, event: .stage("Queued"))
        let generationDrafts = snapshot.generationDrafts ?? Self.generationDraftsFromOriginalPrompt(request.prompt)
        pending.append(Work(moduleID: moduleID, lectureID: lectureID, job: job, request: request,
                            learningPointIDs: snapshot.learningPointIDs, generationDrafts: generationDrafts,
                            generationDraftsFrozen: true)); schedule()
    }

    /// Call once at app launch, before accepting commands. Never reruns an interrupted call automatically.
    public func recoverInterruptedJobs() async throws -> Int {
        guard active.isEmpty && pending.isEmpty && reservations.isEmpty else { throw AIError.configuration("Recovery must run before starting jobs.") }
        var count = 0
        for module in try await store.modules() {
            for lecture in try await store.lectures(in: module.id) where lecture.jobs.contains(where: { $0.state == .running }) {
                count += lecture.jobs.filter { $0.state == .running }.count
                _ = try await store.updateLecture(moduleID: module.id, lectureID: lecture.id) { latest in
                    for i in latest.jobs.indices where latest.jobs[i].state == .running {
                        latest.jobs[i].state = .interrupted; latest.jobs[i].error = "Lectern stopped before this job finished. Retry uses the original snapshot."
                    }
                }
            }
        }
        return count
    }
    public func waitUntilIdle() async {
        if active.isEmpty && pending.isEmpty && reservations.isEmpty && !solveVariantSlotBusy && solveVariantWaiters.isEmpty { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    public func cleanSnapshots(olderThan date: Date = Date().addingTimeInterval(-7 * 86400)) async throws {
        for module in try await store.modules() {
            for lecture in try await store.lectures(in: module.id) {
                let savedChatJobIDs = Set(([lecture.currentChat] + lecture.archivedChats).flatMap(\.messages).compactMap(\.editJobID))
                for job in lecture.jobs where job.state != .running && !savedChatJobIDs.contains(job.id) && (job.finishedAt ?? job.startedAt) < date {
                    let directory = store.jobDirectory(moduleID: module.id, lectureID: lecture.id, jobID: job.id)
                    if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
                }
                // Also retire snapshots left by a process crash before its job record committed.
                let jobsDirectory = store.sourceURL(moduleID: module.id, lectureID: lecture.id).deletingLastPathComponent().appendingPathComponent("jobs")
                if FileManager.default.fileExists(atPath: jobsDirectory.path) {
                    for directory in try FileManager.default.contentsOfDirectory(at: jobsDirectory, includingPropertiesForKeys: [.contentModificationDateKey]) {
                        guard let id = UUID(uuidString: directory.lastPathComponent), !lecture.jobs.contains(where: { $0.id == id }),
                              let modified = try directory.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, modified < date else { continue }
                        try FileManager.default.removeItem(at: directory)
                    }
                }
            }
        }
    }
}
