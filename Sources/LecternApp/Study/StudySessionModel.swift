import Foundation
import LecternCore
import Observation

@Observable
final class StudySessionModel {
    enum Status { case studying, empty, done, limited, ended }
    enum Pane { case slide, ask }

    struct EditDraft {
        var front: String
        var back: String

        var canSave: Bool {
            !front.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                !back.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private struct Attempt {
        var entry: StudyCard
        var isRetry = false
    }

    private nonisolated struct CardKey: Hashable {
        let moduleID: UUID
        let lectureID: UUID
        let cardID: UUID

        init(_ entry: StudyCard) {
            moduleID = entry.moduleID
            lectureID = entry.lectureID
            cardID = entry.id
        }
    }

    private struct PendingGrade {
        let rating: StudyRating
        let answeredAt: Date
        let answeringTime: TimeInterval
        let retryAfterMiss: Bool
    }

    private struct Undo {
        enum Action {
            case grade(id: UUID, rating: StudyRating, appendedRetry: Bool)
            case disable(updated: StudyCard)
        }
        let position: Int
        let action: Action
        var solveCase: SolveCase? = nil
        var solveResponse: StudySolveResponse? = nil
    }

    let app: AppModel
    let scope: StudyScope
    let options: StudySessionOptions
    let includeFuture: Bool
    let extraNewPerModule: Int
    private let plan: StudyPlan
    private let clock = ContinuousClock()
    private let startedAt: ContinuousClock.Instant
    private var cardStartedAt: ContinuousClock.Instant
    private var finishedAt: ContinuousClock.Instant?
    private var pausedSeconds = 0.0
    private var queue: [Attempt]
    private var position = 0
    private var undo: Undo?
    private var limitLifted = false
    private var gradedIDs: [CardKey: Int] = [:]
    private var attemptID = UUID()
    private var solvePresentationID = UUID()
    private var pendingGrade: PendingGrade?

    private(set) var gradeCount = 0
    private(set) var missCount = 0
    private(set) var status: Status
    private(set) var isBusy = false
    private(set) var revealed = false
    private(set) var currentSolveCase: SolveCase?
    private(set) var currentSolveAnswers: [SolveAnswer]?
    private(set) var sourceIndex = 0
    private(set) var pane: Pane?
    private(set) var chatModel: LectureWindowModel?
    private(set) var chatError: String?
    private(set) var toast: String?
    private(set) var canSkipCurrent = false
    var error: String?
    var editDraft: EditDraft?

    init(app: AppModel, scope: StudyScope, options: StudySessionOptions, includeFuture: Bool,
         extraNewPerModule: Int, plan: StudyPlan) {
        self.app = app
        self.scope = scope
        self.options = options
        self.includeFuture = includeFuture
        self.extraNewPerModule = extraNewPerModule
        self.plan = plan
        let now = ContinuousClock().now
        startedAt = now
        cardStartedAt = now
        queue = plan.cards.map { Attempt(entry: $0) }
        status = plan.cards.isEmpty ? .empty : .studying
        if status == .empty { finishedAt = now }
    }

    var current: StudyCard? { status == .studying && queue.indices.contains(position) ? queue[position].entry : nil }
    var turnID: UUID { attemptID }
    var isRetry: Bool { current != nil && queue[position].isRetry }
    var sourcePage: Int? {
        guard let pages = current?.card.sourcePages, pages.indices.contains(sourceIndex) else { return nil }
        return pages[sourceIndex]
    }
    var hasPendingGrade: Bool { pendingGrade != nil }
    var canUndo: Bool { undo != nil && !isBusy && editDraft == nil && !hasPendingGrade }
    var canUndoDisable: Bool {
        if case .disable? = undo?.action { return canUndo }
        return false
    }
    var againCount: Int { queue.dropFirst(position).count(where: \.isRetry) }
    var distinctGradeCount: Int { gradedIDs.count }
    var totalCount: Int {
        if !limitLifted, case .cards = options.stop { return plan.startingCount }
        return plan.cards.count
    }
    var cardNumber: Int { min(totalCount, position + (status == .studying ? 1 : 0)) }
    var progress: Double { totalCount == 0 ? 0 : min(1, Double(position) / Double(totalCount)) }

    var scopeLabel: String {
        switch scope {
        case .all: "All modules"
        case .module(let id): app.module(id)?.name ?? "Module"
        case .lectures(_, let ids): Format.count(ids.count, "lecture")
        }
    }

    var backLabel: String { app.selection == .overview ? "Overview" : "Flashcards" }
    var elapsedSeconds: Int { Int(activeSeconds.rounded()) }
    var unseenCount: Int { refreshedPlan.totalUnseen }
    var dueRemaining: Int { refreshedPlan.dueCount }
    var deferredSolveCount: Int { refreshedPlan.deferredSolveCount }
    var readySolveCount: Int { refreshedPlan.cards.count { $0.card.solve != nil } }
    var approvedCount: Int { status == .empty ? plan.approvedCount : refreshedPlan.approvedCount }
    var nextDue: Date? { refreshedPlan.nextDue ?? (status == .empty ? plan.nextDue : nil) }
    var canKeepGoing: Bool { position < queue.count }
    var continuationDueCount: Int {
        app.studyCatalog.plan(scope: scope, options: options, limitNewInSession: 0, now: app.studyNow).cards.count
    }

    var cramCount: Int {
        guard unseenCount > 0 else { return 0 }
        let extended = app.studyCatalog.plan(scope: scope, options: options, includeFuture: false,
                                             extraNewPerModule: nextCramAllowance, limitNewInSession: 20, now: Date())
        return extended.cards.count(where: { $0.memory == nil })
    }

    var nextCramAllowance: Int {
        let catalog = app.studyCatalog
        let overallExcess = catalog.preferences.overallNewLimit.map { max(0, catalog.introducedToday - $0) } ?? 0
        let moduleID = scope.moduleID
        let moduleExcess = catalog.decks.lazy.filter { moduleID == nil || $0.id == moduleID }
            .map { max(0, $0.introducedToday - catalog.configuration(moduleID: $0.id).newCardLimit) }.max() ?? 0
        return min(Int.max - 20, max(extraNewPerModule, overallExcess, moduleExcess)) + 20
    }

    var nextModule: (module: Module, count: Int)? {
        guard case .module(let currentID) = scope else { return nil }
        let others = app.studyCatalog.decks.map(\.module).filter { $0.id != currentID }
        for module in others {
            let options = app.studyCatalog.configuration(moduleID: module.id).session
            let plan = app.studyCatalog.plan(scope: .module(module.id), options: options, now: Date())
            if plan.startingCount > 0 { return (module, plan.startingCount) }
        }
        return nil
    }

    private var refreshedPlan: StudyPlan {
        app.studyCatalog.plan(scope: scope, options: options, includeFuture: includeFuture,
                              extraNewPerModule: extraNewPerModule, now: Date())
    }

    func reveal() {
        guard let current, current.card.solve == nil, !isBusy, editDraft == nil, !revealed else { return }
        revealed = true
        toast = nil
    }

    func prepareCurrentSolveCase() async {
        guard let entry = current, entry.card.solve != nil, currentSolveCase == nil, !isBusy else { return }
        let turn = turnID
        var deferred = false
        await perform {
            do {
                let exercise = try await app.store.presentSolveCase(entry, presentationID: solvePresentationID)
                guard turnID == turn else { return }
                if let exercise {
                    currentSolveCase = exercise
                    cardStartedAt = clock.now
                } else {
                    deferred = true
                    toast = "No unseen cases are ready. This card keeps its schedule."
                    advance()
                }
                var refill = entry
                if let exercise { refill.seenSolveCaseIDs.insert(exercise.id) }
                app.prepareSolveCases(for: refill, checkLatest: exercise == nil)
            } catch {
                canSkipCurrent = true
                throw error
            }
        }
        if deferred { await app.refreshStudy() }
    }

    func checkSolve(answers: [SolveAnswer]) {
        guard !isBusy, !revealed, let content = currentSolveCase?.content,
              !SolveChecker.check(content, answers: answers).hasInvalidInput else { return }
        currentSolveAnswers = answers
        revealed = true
        toast = nil
    }

    func retireSolveCase() async {
        guard let entry = current, let exercise = currentSolveCase, revealed, !hasPendingGrade else { return }
        await perform {
            try await flushChatDraft()
            let updated = try await app.store.retireSolveCase(entry, caseID: exercise.id)
            var refill = entry
            refill.card = updated
            app.prepareSolveCases(for: refill, checkLatest: true)
            advance()
            toast = "Case removed. This card keeps its schedule."
            app.scheduleReload()
        }
    }

    func showSlide(cycle: Bool = false) {
        guard current != nil, editDraft == nil else { return }
        if cycle, pane == .slide, revealed, let count = current?.card.sourcePages.count, count > 0 {
            sourceIndex = (sourceIndex + 1) % count
        }
        pane = .slide
    }

    func previousSource() {
        guard revealed, let count = current?.card.sourcePages.count, count > 0 else { return }
        sourceIndex = (sourceIndex + count - 1) % count
    }

    func showAsk() {
        guard let current, (current.card.solve == nil || revealed),
              editDraft == nil, !isBusy, !hasPendingGrade else { return }
        pane = .ask
    }

    func closePane() { pane = nil }

    func loadAsk(for entry: StudyCard) async {
        guard pane == .ask, current.map(CardKey.init) == CardKey(entry) else { return }
        chatError = nil
        let ref = LectureRef(moduleID: entry.moduleID, lectureID: entry.lectureID)
        if let chatModel, chatModel.ref == ref {
            chatModel.selectCard(entry.id)
            chatModel.sourceIndex = sourceIndex
            chatModel.chatContext = ChatContext(followsScreen: false, pins: [.card(entry.id)])
            chatModel.studySolveContext = solveAskContext
            return
        }
        do {
            let lecture = try await app.store.loadLecture(moduleID: ref.moduleID, lectureID: ref.lectureID)
            guard !Task.isCancelled, pane == .ask, current.map(CardKey.init) == CardKey(entry) else { return }
            let session = LectureSession(lecture: lecture, store: app.store, runner: app.runner)
            session.startObserving()
            let model = LectureWindowModel(ref: ref, session: session, app: app)
            model.mode = .review
            model.reviewFilter = .all
            model.selectCard(entry.id)
            model.sourceIndex = sourceIndex
            model.chatContext = ChatContext(followsScreen: false, pins: [.card(entry.id)])
            model.studySolveContext = solveAskContext
            chatModel = model
        } catch {
            guard !Task.isCancelled, current.map(CardKey.init) == CardKey(entry) else { return }
            chatError = error.localizedDescription
        }
    }

    func refreshCardAfterNavigation() async {
        guard let entry = current, !isBusy else { return }
        do {
            let lecture = try await app.store.loadLecture(moduleID: entry.moduleID, lectureID: entry.lectureID)
            guard !Task.isCancelled, current.map(CardKey.init) == CardKey(entry) else { return }
            updateChatCard(lecture)
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
            canSkipCurrent = !hasPendingGrade
        }
    }

    func updateChatCard(_ lecture: Lecture) {
        guard !isBusy, !hasPendingGrade, editDraft == nil, let entry = current,
              lecture.moduleID == entry.moduleID, lecture.id == entry.lectureID else { return }
        guard let updated = lecture.cards.first(where: { $0.id == entry.id }),
              updated.verdict == .good, !updated.isSuperseded, !lecture.isArchived else {
            undo = nil
            toast = "This card has changed in Review. Its study schedule is saved."
            advance()
            Task { await app.refreshStudy() }
            return
        }
        guard updated != entry.card else { return }
        if updated.studyScheduleID != entry.card.studyScheduleID {
            let key = CardKey(entry)
            let remaining = queue.dropFirst(position + 1).filter { CardKey($0.entry) != key }
            queue.replaceSubrange((position + 1)..<queue.endIndex, with: remaining)
            undo = nil
            toast = "This card’s study schedule changed. It will be queued in a future session."
            advance()
            Task { await app.refreshStudy() }
            return
        }
        queue[position].entry.card = updated
        if updated.currentRevisionID != entry.card.currentRevisionID,
           updated.solve != nil || entry.card.solve != nil {
            resetCard()
        }
        if !updated.sourcePages.indices.contains(sourceIndex) { sourceIndex = 0 }
    }

    func intervalLabel(_ rating: StudyRating) -> String {
        guard let entry = current else { return "" }
        let configuration = app.studyCatalog.configuration(moduleID: entry.moduleID)
        if rating == .again, configuration.retryAfterMiss { return "end of session" }
        let now = max(Date(), entry.memory?.lastReview ?? .distantPast)
        guard let state = try? StudyScheduler.review(entry.memory, rating: rating, at: now,
                                                      configuration: configuration, cardID: entry.id,
                                                      isSolve: entry.card.solve != nil) else { return "" }
        let delay = max(60, Int(state.due.timeIntervalSince(now).rounded()))
        if delay < 86_400 { return "in \(Format.count(delay / 60, "min", "min"))" }
        return "in \(Format.count(delay / 86_400, "day"))"
    }

    func grade(_ rating: StudyRating) async {
        guard let entry = current, revealed, editDraft == nil, !isBusy,
              pendingGrade == nil || pendingGrade?.rating == rating else { return }
        let solveCase = currentSolveCase
        let response = solveCase.flatMap { exercise in
            currentSolveAnswers.map { StudySolveResponse(presentationID: solvePresentationID, caseID: exercise.id, answers: $0) }
        }
        guard entry.card.solve == nil || response != nil else { return }
        let eventID = attemptID
        let configuration = app.studyCatalog.configuration(moduleID: entry.moduleID)
        let request = pendingGrade ?? PendingGrade(rating: rating, answeredAt: Date(),
                                                  answeringTime: seconds(from: cardStartedAt, to: clock.now),
                                                  retryAfterMiss: configuration.retryAfterMiss)
        await perform {
            try await flushChatDraft()
            pendingGrade = request
            let state: StudyMemoryState
            do {
                state = try await app.store.gradeStudyCard(entry, rating: rating, eventID: eventID, now: request.answeredAt,
                                                           answeringTime: request.answeringTime, permitEarly: isRetry || includeFuture,
                                                           extraNewPerModule: extraNewPerModule, solveResponse: response)
            } catch {
                // A complete event can reach the journal before a sync error. Retry that event ID
                // with the same rating and time instead of turning it into a second grade.
                if error is LibraryError || error is StudyScheduleError {
                    pendingGrade = nil
                    canSkipCurrent = true
                }
                throw error
            }
            pendingGrade = nil
            let retry = rating == .again && request.retryAfterMiss
            undo = Undo(position: position, action: .grade(id: eventID, rating: rating, appendedRetry: retry),
                        solveCase: solveCase, solveResponse: response)
            gradeCount += 1
            gradedIDs[CardKey(entry), default: 0] += 1
            if rating == .again {
                missCount += 1
                toast = retry ? "Missed. It comes back at the end of this session." : "Missed. It comes back when it’s due."
            } else {
                toast = nil
            }
            if retry {
                var next = entry
                next.memory = state
                queue.append(Attempt(entry: next, isRetry: true))
            }
            advance()
            if status != .studying { await app.refreshStudy() }
        }
    }

    func retrySavingGrade() async {
        guard let pendingGrade else { return }
        await grade(pendingGrade.rating)
    }

    func disable() async {
        guard let entry = current, editDraft == nil, !hasPendingGrade else { return }
        await perform {
            try await flushChatDraft()
            let updated = try await app.store.setStudyCardDisabled(entry, disabled: true)
            var disabledEntry = entry
            disabledEntry.card = updated
            undo = Undo(position: position, action: .disable(updated: disabledEntry))
            toast = "Disabled. It’s back in \(entry.lectureName) as unreviewed."
            advance()
            app.scheduleReload()
        }
        await app.refreshStudy()
    }

    func undoLast() async {
        guard canUndo, let undo else { return }
        await perform {
            try await flushChatDraft()
            let original = queue[undo.position].entry
            switch undo.action {
            case .grade(let eventID, let rating, let appendedRetry):
                try await app.store.undoStudyGrade(moduleID: original.moduleID, eventID: eventID)
                if appendedRetry { queue.removeLast() }
                gradeCount -= 1
                if rating == .again { missCount -= 1 }
                let key = CardKey(original)
                if let count = gradedIDs[key], count > 1 { gradedIDs[key] = count - 1 }
                else { gradedIDs.removeValue(forKey: key) }
            case .disable(let updated):
                queue[undo.position].entry.card = try await app.store.setStudyCardDisabled(updated, disabled: false)
                app.scheduleReload()
            }
            position = undo.position
            self.undo = nil
            resetCard()
            if let previousCase = undo.solveCase, let response = undo.solveResponse {
                currentSolveCase = previousCase
                currentSolveAnswers = response.answers
                solvePresentationID = response.presentationID
                revealed = true
            } else {
                revealed = queue[position].entry.card.solve == nil
            }
            toast = nil
            status = .studying
            resumeClock()
        }
        await app.refreshStudy()
    }

    func beginEdit() {
        guard !isBusy, editDraft == nil, !hasPendingGrade, let entry = current, entry.card.solve == nil else { return }
        editDraft = EditDraft(front: entry.card.front, back: entry.card.back)
    }

    func saveEdit() async {
        guard let entry = current, let editDraft, editDraft.canSave else { return }
        await perform {
            let updated = try await app.store.editStudyCard(entry, front: editDraft.front, back: editDraft.back)
            let key = CardKey(entry)
            for index in queue.indices where CardKey(queue[index].entry) == key {
                queue[index].entry.card = updated
            }
            self.editDraft = nil
            if let chatModel { await chatModel.reloadAfterExternalChange() }
            app.scheduleReload()
        }
    }

    func openPrepare(page: Int) async {
        guard let entry = current, revealed, editDraft == nil, !hasPendingGrade else { return }
        await perform {
            try await flushChatDraft()
            chatModel = nil
            if pane == .ask { pane = .slide }
            app.openStudySource(entry, page: page)
        }
    }

    func stop() async {
        guard status == .studying, editDraft == nil, !hasPendingGrade else { return }
        await perform {
            try await flushChatDraft()
            finish(.ended)
            await app.refreshStudy()
        }
    }

    func keepGoing() {
        guard !isBusy, canKeepGoing else { return }
        limitLifted = true
        toast = nil
        status = .studying
        resumeClock()
        resetCard()
    }

    func back() async {
        await perform {
            try await flushChatDraft()
            app.endStudy()
        }
    }

    func prepareForWindowClose() async -> Bool {
        guard !isBusy else { return false }
        guard editDraft == nil else {
            error = "Save or cancel your edit before closing Study."
            return false
        }
        do {
            try await flushChatDraft()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func skipUnavailableCard() async {
        guard canSkipCurrent, current != nil, editDraft == nil, !hasPendingGrade else { return }
        await perform {
            try await flushChatDraft()
            // No grade was applied. Keep the durable due date and back out only of this attempt.
            undo = nil
            toast = nil
            advance()
        }
        await app.refreshStudy()
    }

    private func advance() {
        let previous = queue[position].entry
        position += 1
        resetCard()
        if !queue.indices.contains(position) {
            finish(.done)
        } else {
            let next = queue[position].entry
            if next.lectureID != previous.lectureID || next.moduleID != previous.moduleID { chatModel = nil }
            if !limitLifted, reachedLimit { finish(.limited) }
        }
    }

    private var reachedLimit: Bool {
        switch options.stop {
        case .complete: false
        case .cards(let count): distinctGradeCount >= count
        case .minutes(let minutes): activeSeconds >= Double(minutes) * 60
        }
    }

    private var activeSeconds: Double {
        max(0, seconds(from: startedAt, to: finishedAt ?? clock.now) - pausedSeconds)
    }

    private func resumeClock() {
        if let finishedAt { pausedSeconds += seconds(from: finishedAt, to: clock.now) }
        finishedAt = nil
    }

    private func resetCard() {
        cardStartedAt = clock.now
        attemptID = UUID()
        solvePresentationID = UUID()
        currentSolveCase = nil
        currentSolveAnswers = nil
        revealed = false
        sourceIndex = 0
        editDraft = nil
        if pane == .ask { pane = .slide }
    }

    private func finish(_ status: Status) {
        self.status = status
        finishedAt = clock.now
        pane = nil
        chatModel = nil
    }

    private var solveAskContext: String? {
        guard let exercise = currentSolveCase, let answers = currentSolveAnswers else { return nil }
        let answerData = try? JSONEncoder().encode(answers)
        let submission = answerData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return """
        The learner is asking about this specific checked solve-card case.
        Case ID: \(exercise.id.uuidString)
        Exercise:
        \(exercise.content.staticQuestion)
        Answer key and explanation:
        \(exercise.content.staticAnswer)
        Submitted answers in field order: \(submission)
        """
    }

    private func perform(_ body: () async throws -> Void) async {
        guard !isBusy else { return }
        isBusy = true
        error = nil
        canSkipCurrent = false
        defer { isBusy = false }
        do { try await body() }
        catch { self.error = error.localizedDescription }
    }

    private func flushChatDraft() async throws {
        guard let model = chatModel, !model.readOnly else { return }
        let persisted = model.lecture.currentChat
        let draft = model.chatDraft
        let attachments = model.chatDraftAttachments
        guard draft != persisted.draft || attachments != persisted.draftAttachments else { return }
        model.chatDraftSaveTask?.cancel()
        try await model.session.setChatDraft(draft, attachments: attachments, chatID: persisted.id)
    }

    private func seconds(from start: ContinuousClock.Instant, to end: ContinuousClock.Instant) -> Double {
        let value = start.duration(to: end).components
        return Double(value.seconds) + Double(value.attoseconds) / 1e18
    }
}
