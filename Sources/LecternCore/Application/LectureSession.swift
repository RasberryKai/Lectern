import Foundation
import Observation

/// Frontend adapter: views observe this object and dispatch actions, never save a whole stale lecture.
@MainActor @Observable
public final class LectureSession {
    public private(set) var lecture: Lecture
    public private(set) var canUndo = false
    public private(set) var jobs: [UUID: JobProgress] = [:]
    public private(set) var lastError: String?
    public private(set) var isClosed = false
    public let store: LibraryStore
    public let runner: JobRunner
    @ObservationIgnored private var controller: LectureController
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var editTask: Task<Void, Never>?
    @ObservationIgnored private var editingCards: [UUID: PendingEdit] = [:]
    @ObservationIgnored private var isMutating = false
    @ObservationIgnored private var mutationWaiters: [CheckedContinuation<Void, Never>] = []
    private struct PendingEdit: Sendable { var front: String; var back: String; var sourcePages: [Int] }

    public init(lecture: Lecture, store: LibraryStore, runner: JobRunner) {
        self.lecture = lecture; self.store = store; self.runner = runner; self.controller = LectureController(lecture: lecture)
    }
    deinit { eventTask?.cancel(); editTask?.cancel() }
    /// Call once per open window; release the session when the window closes.
    public func startObserving() {
        guard eventTask == nil else { return }
        eventTask = Task { [weak self, runner] in
            let events = await runner.events()
            for await value in events {
                guard let self, !Task.isCancelled else { break }
                guard value.lectureID == self.lecture.id && value.moduleID == self.lecture.moduleID else { continue }
                self.jobs[value.jobID] = value
                if ["Succeeded", "Failed", "Cancelled", "Persistence failed"].contains(value.stage) {
                    do { try await self.refresh() } catch { self.lastError = error.localizedDescription }
                }
            }
        }
    }
    private func acquire() async {
        if !isMutating { isMutating = true; return }
        await withCheckedContinuation { mutationWaiters.append($0) }
    }
    private func release() {
        if mutationWaiters.isEmpty { isMutating = false }
        else { mutationWaiters.removeFirst().resume() }
    }
    public func refresh() async throws {
        await acquire(); defer { release() }
        let latest = try await store.loadLecture(moduleID: lecture.moduleID, lectureID: lecture.id)
        try controller.receive(latest); lecture = latest; canUndo = controller.canUndo
        let cardIDs = Set(latest.cards.map(\.id))
        editingCards = editingCards.filter { cardIDs.contains($0.key) }
    }
    public func dispatch(_ action: LectureAction) async throws {
        // Serialized by the MainActor gate plus the store transaction, including async landings.
        await acquire(); defer { release() }
        let previous = controller
        let result = try await store.transaction(moduleID: lecture.moduleID, lectureID: lecture.id) { latest in
            var next = previous; try next.receive(latest); try next.dispatch(action)
            latest = next.lecture; return next
        }
        controller = result.result; try controller.receive(result.lecture)
        lecture = result.lecture; canUndo = controller.canUndo; lastError = nil
    }
    public func undo() async throws {
        try await flushEdits()
        await acquire(); defer { release() }
        let previous = controller
        let result = try await store.transaction(moduleID: lecture.moduleID, lectureID: lecture.id) { latest in
            var next = previous; try next.receive(latest); next.undo(); latest = next.lecture
            _ = try latest.validated(); return next
        }
        controller = result.result; try controller.receive(result.lecture)
        lecture = result.lecture; canUndo = controller.canUndo
    }
    /// Coalesce typing until a 500 ms pause. UI keeps its editor buffer and calls
    /// flushEdits on focus loss, window close and before starting any job.
    public func stageCardEdit(cardID: UUID, front: String, back: String, sourcePages: [Int]) {
        guard !isClosed else { lastError = "This lecture window is closed."; return }
        editingCards[cardID] = PendingEdit(front: front, back: back, sourcePages: sourcePages)
        editTask?.cancel()
        // Retain this session until the scheduled save finishes, even if a window drops its reference.
        editTask = Task { [self] in
            do { try await Task.sleep(for: .milliseconds(500)); try await flushEdits() }
            catch is CancellationError { }
            catch { lastError = error.localizedDescription }
        }
    }
    public func flushEdits() async throws {
        editTask?.cancel(); editTask = nil
        let edits = editingCards
        for (id, value) in edits {
            try await dispatch(.commitEdit(cardID: id, front: value.front, back: value.back, sourcePages: value.sourcePages))
            // Keep a newer editor buffer if it changed while the save awaited the store.
            if let current = editingCards[id], current.front == value.front && current.back == value.back && current.sourcePages == value.sourcePages { editingCards.removeValue(forKey: id) }
        }
    }
    /// Window/app close must await this method and keep the window open if saving fails.
    public func closeAndFlush() async throws {
        isClosed = true
        do { try await flushEdits() }
        catch { isClosed = false; throw error }
        eventTask?.cancel(); eventTask = nil
    }
    public func generate(backend: AIBackend = .claudeCLI, model: String = "opus", regenerateAll: Bool = false,
                         additionalInstructions: String = "", replaceExistingCards: Bool = false) async throws -> UUID {
        try await flushEdits()
        return try await runner.generate(moduleID: lecture.moduleID, lectureID: lecture.id, backend: backend, model: model,
                                         regenerateAll: regenerateAll, additionalInstructions: additionalInstructions,
                                         replaceExistingCards: replaceExistingCards)
    }
    public func revise(cardID: UUID, feedback: String, backend: AIBackend = .claudeCLI, model: String = "opus") async throws -> UUID {
        try await flushEdits()
        try await dispatch(.setFeedback(cardID: cardID, feedback))
        return try await runner.revise(moduleID: lecture.moduleID, lectureID: lecture.id, cardID: cardID, feedback: feedback, backend: backend, model: model)
    }
    public func ask(anchorPage: Int, context: ThreadContext = .neighbours(1), question: String, cardID: UUID? = nil,
                    backend: AIBackend = .claudeCLI, model: String = "opus",
                    flashcardContext: FlashcardContext? = nil) async throws -> UUID {
        try await flushEdits()
        return try await runner.ask(moduleID: lecture.moduleID, lectureID: lecture.id, anchorPage: anchorPage, context: context, question: question, cardID: cardID, backend: backend, model: model, flashcardContext: flashcardContext)
    }
    public func chat(anchorPage: Int, context: ThreadContext, question: String, cardID: UUID? = nil,
                     backend: AIBackend = .claudeCLI, model: String = "opus", flashcardContext: FlashcardContext = .none) async throws -> UUID {
        try await flushEdits()
        return try await runner.chat(moduleID: lecture.moduleID, lectureID: lecture.id, anchorPage: anchorPage,
            context: context, question: question, cardID: cardID, backend: backend, model: model, flashcardContext: flashcardContext)
    }
}
