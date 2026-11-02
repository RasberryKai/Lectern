import Foundation

public struct JobProgress: Equatable, Sendable {
    public var moduleID: UUID
    public var lectureID: UUID
    public var jobID: UUID
    public var stage: String
    public var streamedText: String
    public var warning: String?
}

/// Every provider call passes through this actor. Durable state lives in LibraryStore;
/// only queue scheduling and transient stream text live here.
public actor JobRunner {
    private struct Work: Sendable {
        var moduleID: UUID
        var lectureID: UUID
        var job: Job
        var request: AIRequest
        var learningPointIDs: [UUID]
    }
    private struct Snapshot: Codable { var request: AIRequest; var learningPointIDs: [UUID] }
    private let pdfExporter: any PDFSnapshotExporting
    private let store: LibraryStore
    private let providers: [AIBackend: any AIProvider]
    private var pending: [Work] = []
    private var active: [UUID: Task<Void, Never>] = [:]
    private var reservations = Set<String>()
    private var progress: [UUID: JobProgress] = [:]
    private var subscribers: [UUID: AsyncStream<JobProgress>.Continuation] = [:]
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

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
                         model: String = "opus", regenerateAll: Bool = false) async throws -> UUID {
        try await enqueue(kind: .generate, moduleID: moduleID, lectureID: lectureID, backend: backend,
                          model: model, regenerateAll: regenerateAll)
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
                    model: String = "opus") async throws -> UUID {
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AIError.configuration("Ask a question first.") }
        return try await enqueue(kind: .ask, moduleID: moduleID, lectureID: lectureID, backend: backend,
                                 model: model, cardID: cardID, anchorPage: anchorPage, context: context, question: question)
    }
    @discardableResult
    public func distil(moduleID: UUID, lectureID: UUID, anchorPage: Int, backend: AIBackend = .claudeCLI,
                       model: String = "opus") async throws -> UUID {
        try await enqueue(kind: .distil, moduleID: moduleID, lectureID: lectureID, backend: backend, model: model, anchorPage: anchorPage)
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
        let points = lecture.threads.flatMap(\.learningPoints).filter { $0.included && $0.pages.contains(page) }
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
                         anchorPage: Int? = nil, context: ThreadContext = .neighbours(1), question: String = "") async throws -> UUID {
        try Task.checkCancellation()
        try await store.assertModuleEditable(moduleID: moduleID)
        guard providers[backend] != nil else { throw AIError.configuration("No provider configured for \(backend.rawValue).") }
        let key = "\(lectureID):\(kind.rawValue):\(cardID?.uuidString ?? ""):\(anchorPage ?? 0)"
        guard reservations.insert(key).inserted else { throw AIError.configuration("This operation is already being prepared.") }
        defer { reservations.remove(key); schedule() }
        let resolvedModel: String
        if kind == .distil {
            resolvedModel = backend == .claudeCLI ? AISettings.learningPointCLIModel : AISettings.learningPointAPIModel
        } else if backend == .messagesAPI {
            resolvedModel = model == "opus" || model.isEmpty ? AISettings.defaultMessagesAPIModel : model
            guard resolvedModel.hasPrefix("claude-") else { throw AIError.configuration("Messages API needs a full model ID such as claude-opus-5-5.") }
        } else { resolvedModel = model.isEmpty ? AISettings.defaultCLIModel : model }
        let modules = try await store.modules()
        guard let module = modules.first(where: { $0.id == moduleID }) else { throw AIError.configuration("Module no longer exists.") }
        let initial = try await store.loadLecture(moduleID: moduleID, lectureID: lectureID)
        let card: Card?
        if let cardID {
            guard let found = initial.cards.first(where: { $0.id == cardID && !$0.isSuperseded }) else { throw LectureError.missingCard(cardID) }
            card = found
        } else { card = nil }
        let anchor = kind == .ask ? (card?.sourcePages.first ?? anchorPage) : anchorPage
        var thread: SlideThread?
        var pages: [Int]
        switch kind {
        case .generate:
            pages = regenerateAll ? initial.slides.filter(\.isSelected).map { $0.pageIndex + 1 } : initial.uncoveredSelectedPages
            guard !pages.isEmpty else { throw AIError.configuration("No selected slides without cards. Choose Regenerate all explicitly to include covered slides.") }
        case .revise:
            guard let card, card.proposal == nil else { throw AIError.configuration("Resolve this card's existing proposal first.") }
            pages = card.sourcePages
        case .ask, .distil:
            guard let anchor, (1...max(1, initial.pageCount)).contains(anchor), initial.pageCount > 0 else { throw AIError.configuration("Ask needs a linked source slide.") }
            thread = initial.threads.first(where: { $0.anchorPage == anchor }) ?? SlideThread(anchorPage: anchor, context: context)
            if kind == .ask { thread?.context = context }
            guard let currentThread = thread else { throw AIError.configuration("Thread could not be prepared.") }
            switch currentThread.context {
            case .slide: pages = [anchor]
            case .neighbours(let distance):
                guard distance >= 0 && distance <= 100 else { throw AIError.configuration("Neighbour range must be 0 to 100.") }
                pages = Array(max(1, anchor - distance)...min(initial.pageCount, anchor + distance))
            case .lecture: pages = Array(1...initial.pageCount)
            }
        }
        pages = Array(Set(pages)).sorted()
        guard pages.count <= 100 else { throw AIError.limit("v1 supports up to 100 slides per call. Reduce the selected context.") }
        guard pages.allSatisfy({ $0 > 0 && $0 <= initial.pageCount }) else { throw AIError.configuration("Repair invalid source slide links before sending this request.") }
        let allLectures = try await store.lectures(in: moduleID)
        let fronts = allLectures.flatMap(\.cards).filter { $0.verdict != .bad && !$0.isSuperseded }.map(\.front)
        let rules = kind == .generate || kind == .revise ? try await store.loadRules() : ""
        let prompt = try PromptBuilder.build(kind: kind, rules: rules, module: module, lecture: initial,
                                             pages: pages, existingFronts: fronts, card: card, feedback: feedback,
                                             thread: thread, question: question)
        var job = Job(kind: kind, pages: pages, rulesVersion: PromptBuilder.hash(rules), backend: backend,
                      targetCardID: cardID, threadID: thread?.id, baseRevisionID: card?.currentRevisionID, prompt: prompt, model: resolvedModel)
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
        let pointIDs = initial.threads.flatMap(\.learningPoints).filter { $0.included && $0.pages.contains(where: pages.contains) }.map(\.id)
        let request = AIRequest(jobID: job.id, kind: kind, model: resolvedModel, prompt: prompt, pdf: pdf, workingDirectory: directory)
        job.inputHash = try Self.inputHash(request)
        var persistedRequest = request; persistedRequest.pdf = nil
        try JSONEncoder().encode(Snapshot(request: persistedRequest, learningPointIDs: pointIDs)).write(to: directory.appendingPathComponent("snapshot.json"), options: .atomic)
        let frozenJob = job
        let frozenThread = thread
        try Task.checkCancellation()
        _ = try await store.updateLecture(moduleID: moduleID, lectureID: lectureID) { lecture in
            try Task.checkCancellation()
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
                if kind == .ask { thread.messages.append(ChatMessage(role: .user, text: question)) }
                try LectureReducer.reduce(&lecture, action: .upsertThread(thread))
            }
            try LectureReducer.reduce(&lecture, action: .startJob(frozenJob))
        }
        committed = true
        if Task.isCancelled {
            try await cancel(moduleID: moduleID, lectureID: lectureID, jobID: job.id)
            throw CancellationError()
        }
        pending.append(Work(moduleID: moduleID, lectureID: lectureID, job: job, request: request, learningPointIDs: pointIDs))
        emit(moduleID: moduleID, lectureID: lectureID, jobID: job.id, event: .stage("Queued"))
        schedule()
        return job.id
    }

    private static func inputHash(_ request: AIRequest) throws -> String {
        struct Input: Encodable { var kind: JobKind; var model: String; var systemPrompt: String; var prompt: String; var pdf: Data? }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return PromptBuilder.hash(try encoder.encode(Input(kind: request.kind, model: request.model,
            systemPrompt: request.systemPrompt, prompt: request.prompt, pdf: request.pdf)))
    }

    private func schedule() {
        while active.count < 3 && !pending.isEmpty {
            let work = pending.removeFirst()
            active[work.job.id] = Task { await self.run(work) }
        }
        if active.isEmpty && pending.isEmpty && reservations.isEmpty {
            let waiters = idleWaiters; idleWaiters.removeAll(); waiters.forEach { $0.resume() }
        }
    }
    private func run(_ work: Work) async {
        var autoDistilAnchor: Int?
        do {
            try Task.checkCancellation()
            guard let provider = providers[work.job.backend] else { throw AIError.configuration("Provider unavailable.") }
            emit(moduleID: work.moduleID, lectureID: work.lectureID, jobID: work.job.id, event: .stage("Sending"))
            let response = try await provider.execute(work.request) { event in
                Task { await self.receive(work: work, event: event) }
            }
            try Task.checkCancellation()
            autoDistilAnchor = try await land(work, response: response)
            emit(moduleID: work.moduleID, lectureID: work.lectureID, jobID: work.job.id, event: .stage("Succeeded"))
        } catch {
            do {
                let cancelled = error is CancellationError || Task.isCancelled
                _ = try await store.updateLecture(moduleID: work.moduleID, lectureID: work.lectureID) { lecture in
                    guard let i = lecture.jobs.firstIndex(where: { $0.id == work.job.id }), lecture.jobs[i].state == .running else { return }
                    lecture.jobs[i].state = cancelled ? .cancelled : .failed
                    lecture.jobs[i].error = cancelled ? nil : error.localizedDescription
                    lecture.jobs[i].finishedAt = Date()
                }
                emit(moduleID: work.moduleID, lectureID: work.lectureID, jobID: work.job.id, event: .stage(cancelled ? "Cancelled" : "Failed"), warning: cancelled ? nil : error.localizedDescription)
            } catch {
                emit(moduleID: work.moduleID, lectureID: work.lectureID, jobID: work.job.id, event: .stage("Persistence failed"), warning: error.localizedDescription)
            }
        }
        active.removeValue(forKey: work.job.id)
        if let anchor = autoDistilAnchor {
            do { _ = try await distil(moduleID: work.moduleID, lectureID: work.lectureID, anchorPage: anchor, backend: work.job.backend, model: work.job.model) }
            catch { emit(moduleID: work.moduleID, lectureID: work.lectureID, jobID: work.job.id, event: .stage("Succeeded"), warning: "Answer saved; learning-point extraction could not start: \(error.localizedDescription)") }
        }
        schedule()
    }
    private func receive(work: Work, event: AIEvent) {
        guard active[work.job.id] != nil else { return }
        emit(moduleID: work.moduleID, lectureID: work.lectureID, jobID: work.job.id, event: event)
    }
    private func emit(moduleID: UUID, lectureID: UUID, jobID: UUID, event: AIEvent, warning: String? = nil) {
        var value = progress[jobID] ?? JobProgress(moduleID: moduleID, lectureID: lectureID, jobID: jobID, stage: "Queued", streamedText: "")
        switch event { case .stage(let stage): value.stage = stage; case .text(let text): value.streamedText += text }
        if let warning { value.warning = warning }
        progress[jobID] = value; subscribers.values.forEach { $0.yield(value) }
    }

    /// Landing reads the latest lecture, so edits made while the provider ran are preserved.
    /// Cards/proposal/thread and succeeded state commit in the same atomic lecture write.
    private func land(_ work: Work, response: AIResponse) async throws -> Int? {
        let data = Data(response.content.utf8)
        var generated: GeneratedCards?; var revised: RevisedCards?; var points: DistilledPoints?
        switch work.job.kind {
        case .generate: generated = try JSONDecoder().decode(GeneratedCards.self, from: data)
        case .revise:
            revised = try JSONDecoder().decode(RevisedCards.self, from: data)
            guard let count = revised?.cards.count, (1...3).contains(count) else { throw AIError.invalidResponse("Revision must return 1 to 3 cards.") }
        case .distil:
            points = try JSONDecoder().decode(DistilledPoints.self, from: data)
            guard let points, points.learningPoints.count <= 3, points.learningPoints.allSatisfy({ !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.pages.isEmpty && $0.pages.allSatisfy(work.job.pages.contains) }) else { throw AIError.invalidResponse("Invalid learning points or source slide references.") }
        case .ask: guard !response.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AIError.invalidResponse("Claude returned an empty answer.") }
        }
        let frozenGenerated = generated, frozenRevised = revised, frozenPoints = points
        let result = try await store.updateLecture(moduleID: work.moduleID, lectureID: work.lectureID) { lecture in
            guard let j = lecture.jobs.firstIndex(where: { $0.id == work.job.id }), lecture.jobs[j].state == .running else { throw LectureError.jobNotRunning(work.job.id) }
            switch work.job.kind {
            case .generate:
                guard let output = frozenGenerated else { throw AIError.invalidResponse("Missing generation payload.") }
                guard output.skipped.allSatisfy({ work.job.pages.contains($0.slide) && !$0.reason.isEmpty }) else { throw AIError.invalidResponse("Invalid skipped-slide entry.") }
                let covered = Set(output.cards.flatMap(\.sourceSlides) + output.skipped.map(\.slide))
                let missing = work.job.pages.filter { !covered.contains($0) }.map { SkippedSlide(slide: $0, reason: "Model returned no card or skip reason; review this slide.") }
                try LectureReducer.reduce(&lecture, action: .landGeneration(jobID: work.job.id, cards: output.cards.map(\.draft), skipped: output.skipped + missing, usage: response.usage))
            case .revise:
                guard let output = frozenRevised else { throw AIError.invalidResponse("Missing revision payload.") }
                try LectureReducer.reduce(&lecture, action: .landProposal(jobID: work.job.id, cards: output.cards.map(\.draft), rationale: output.rationale, usage: response.usage))
            case .ask, .distil:
                guard let t = lecture.threads.firstIndex(where: { $0.id == work.job.threadID }) else { throw AIError.invalidResponse("The slide thread no longer exists.") }
                if work.job.kind == .ask {
                    let expression = try NSRegularExpression(pattern: #"\[slide (\d+)\]"#, options: .caseInsensitive)
                    let range = NSRange(response.content.startIndex..., in: response.content)
                    let citations = expression.matches(in: response.content, range: range).compactMap { match -> Int? in
                        guard let r = Range(match.range(at: 1), in: response.content), let p = Int(response.content[r]), work.job.pages.contains(p) else { return nil }; return p
                    }
                    lecture.threads[t].messages.append(ChatMessage(role: .assistant, text: response.content, citedPages: Array(Set(citations)).sorted()))
                } else if let output = frozenPoints {
                    // Preserve user edits, exclusions and IDs across repeated distillation.
                    for point in output.learningPoints where !lecture.threads[t].learningPoints.contains(where: { $0.text == point.text && $0.pages == point.pages }) {
                        lecture.threads[t].learningPoints.append(LearningPoint(text: point.text, pages: point.pages))
                    }
                }
                lecture.jobs[j].state = .succeeded; lecture.jobs[j].usage = response.usage; lecture.jobs[j].finishedAt = Date()
            }
                for t in lecture.threads.indices {
                    for p in lecture.threads[t].learningPoints.indices where work.learningPointIDs.contains(lecture.threads[t].learningPoints[p].id) {
                        if !lecture.threads[t].learningPoints[p].usedBy.contains(work.job.id) { lecture.threads[t].learningPoints[p].usedBy.append(work.job.id) }
                    }
                }
        }
        if let output = generated, output.cards.isEmpty || output.cards.count > work.job.pages.count * 3 {
            emit(moduleID: work.moduleID, lectureID: work.lectureID, jobID: work.job.id, event: .stage("Succeeded"), warning: output.cards.isEmpty ? "No cards returned. Inspect skipped-slide reasons." : "More than 3 cards per slide on average. Review the scope and card quality.")
        }
        return work.job.kind == .ask ? result.threads.first(where: { $0.id == work.job.threadID })?.anchorPage : nil
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
        try await store.assertModuleEditable(moduleID: moduleID)
        try Task.checkCancellation()
        let reservation = "retry:\(jobID)"
        guard reservations.insert(reservation).inserted else { throw AIError.configuration("Retry is already preparing.") }
        defer { reservations.remove(reservation); schedule() }
        guard active[jobID] == nil, !pending.contains(where: { $0.job.id == jobID }) else { throw AIError.configuration("Job is still active.") }
        let lecture = try await store.loadLecture(moduleID: moduleID, lectureID: lectureID)
        guard var job = lecture.jobs.first(where: { $0.id == jobID }), [.failed, .cancelled, .interrupted].contains(job.state) else { throw AIError.configuration("Only failed, cancelled or interrupted jobs can be retried.") }
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
            guard let i = lecture.jobs.firstIndex(where: { $0.id == jobID }), [.failed, .cancelled, .interrupted].contains(lecture.jobs[i].state) else { throw AIError.configuration("This job has already landed.") }
            guard !lecture.jobs.contains(where: { $0.state == .running && $0.id != jobID && ($0.kind == .generate && frozen.kind == .generate || $0.targetCardID != nil && $0.targetCardID == frozen.targetCardID || $0.threadID != nil && $0.threadID == frozen.threadID) }) else { throw AIError.configuration("Another job for this scope is running.") }
            lecture.jobs[i] = frozen
        }
        if Task.isCancelled {
            try await cancel(moduleID: moduleID, lectureID: lectureID, jobID: jobID)
            throw CancellationError()
        }
        progress.removeValue(forKey: jobID)
        emit(moduleID: moduleID, lectureID: lectureID, jobID: jobID, event: .stage("Queued"))
        pending.append(Work(moduleID: moduleID, lectureID: lectureID, job: job, request: request, learningPointIDs: snapshot.learningPointIDs)); schedule()
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
        if active.isEmpty && pending.isEmpty && reservations.isEmpty { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    public func cleanSnapshots(olderThan date: Date = Date().addingTimeInterval(-7 * 86400)) async throws {
        for module in try await store.modules() {
            for lecture in try await store.lectures(in: module.id) {
                for job in lecture.jobs where job.state != .running && (job.finishedAt ?? job.startedAt) < date {
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
