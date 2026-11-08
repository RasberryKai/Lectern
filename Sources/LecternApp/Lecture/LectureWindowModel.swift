import AppKit
import LecternCore
import Observation
import SwiftUI

nonisolated enum PrepareFilter: Hashable { case all, selected, noCards }

/// Window-local state around one `LectureSession`.
///
/// Navigation (mode, focused slide, filters, selected card) lives here and is written back
/// as one `.setViewPreferences` when the window closes, so arrow-key browsing neither writes
/// to disk per keystroke nor fills the undo stack, and archived lectures stay readable
/// without any persisted change. Notes and card text use editor buffers that save per pause.
@Observable
final class LectureWindowModel {
    let ref: LectureRef
    let session: LectureSession
    let app: AppModel
    let openedAt = Date()

    var mode: LectureMode
    var focusedPageIndex: Int?
    var prepareFilter: PrepareFilter
    var reviewSearch = ""
    var reviewFilter: ReviewFilter
    var selectedCardID: UUID?
    var thumbnailSize: ThumbnailSize
    var notesVisible: Bool
    var thumbnailsVisible: Bool
    var askVisible = true
    var panes = LecturePaneState()
    var chatContext = ChatContext()
    var chatScrollTarget: UUID?
    var readOnlyChatID: UUID?
    var chatDraft = ""
    var chatDraftAttachments: [ChatAttachment] = []
    var chatAttachmentError: String?
    var isImportingChatImages = false
    var chatPreparationFailure: ChatPreparationFailure?
    var isStartingChat = false
    @ObservationIgnored var chatDraftSaveTask: Task<Void, Never>?
    var titleDraft: String?
    private(set) var isSavingTitle = false
    @ObservationIgnored private var titleSaveTask: Task<Void, Error>?

    func commitTitle() async throws {
        if let titleSaveTask { try await titleSaveTask.value; return }
        guard let draft = titleDraft else { return }
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != lecture.name else { titleDraft = nil; return }
        isSavingTitle = true
        let task = Task { try await app.renameLecture(ref, name: name) }
        titleSaveTask = task
        defer { titleSaveTask = nil; isSavingTitle = false }
        try await task.value
        titleDraft = nil
    }

    var errorMessage: String? = nil
    var dismissedSessionError: String? = nil
    var showGenerateSheet = false
    var enlargedPage: Int? = nil
    var sourceIndex = 0
    var dismissedJobIDs: Set<UUID> = []
    var proposeResult: String? = nil

    // Note buffer (zero-based page index).
    private(set) var noteDraftPage: Int? = nil
    private(set) var noteDraft = ""
    @ObservationIgnored private var noteTask: Task<Void, Never>? = nil

    // Card editor buffer.
    private(set) var editorCardID: UUID? = nil
    var editorFront = ""
    var editorBack = ""
    var editorSources = ""
    var feedbackDraft = ""
    @ObservationIgnored private var lastStaged: (front: String, back: String, sources: [Int])? = nil

    // Ask drafts per anchor page.
    var askDrafts: [Int: String] = [:]
    var askContexts: [Int: ThreadContext] = [:]
    var askFlashcardContexts: [Int: FlashcardContext] = [:]

    private(set) var isClosing = false

    init(ref: LectureRef, session: LectureSession, app: AppModel) {
        self.ref = ref
        self.session = session
        self.app = app
        let prefs = session.lecture.viewPreferences
        let lecture = session.lecture
        mode = lecture.pageCount == 0 ? .review : prefs.mode
        focusedPageIndex = lecture.pageCount > 0 ? (prefs.focusedPageIndex ?? 0) : nil
        prepareFilter = prefs.filter == .selected ? .selected : .all
        reviewFilter = prefs.reviewFilter
        selectedCardID = prefs.selectedCardID
        thumbnailSize = prefs.thumbnailSize
        notesVisible = prefs.inspectorVisible
        thumbnailsVisible = prefs.sidebarVisible
        if selectedCardID == nil { selectedCardID = visibleCards.first?.id }
        chatDraft = lecture.currentChat.draft
        chatDraftAttachments = lecture.currentChat.draftAttachments
        loadEditor()
    }

    var lecture: Lecture { session.lecture }
    var readOnly: Bool { app.isArchived(ref.moduleID) || isClosing }
    var moduleName: String { app.module(ref.moduleID)?.name ?? "" }
    var settings: AISettings { app.settings }

    // MARK: Errors

    func run(_ operation: () async throws -> Void) async {
        do { try await operation() } catch is CancellationError {
        } catch { errorMessage = Self.describe(error) }
    }

    static func describe(_ error: Error) -> String {
        if let error = error as? LectureError {
            switch error {
            case .invalidApproval: return "This card can't be approved yet. Fix the issues shown on it first."
            case .invalidProposal: return "This proposal can no longer be applied. Discard it and ask again."
            case .staleSnapshot: return "The lecture changed in another window. It has been reloaded; try again."
            case .missingCard: return "That card no longer exists."
            case .invalidMetadata(let message): return message
            default: return "The lecture could not be updated (\(error))."
            }
        }
        return error.localizedDescription
    }

    func dispatch(_ action: LectureAction) async {
        guard !readOnly else { errorMessage = "This module is archived and read-only."; return }
        await run { try await session.dispatch(action) }
        app.scheduleReload()
    }

    // MARK: Derived lecture values

    func slide(_ pageIndex: Int) -> SlideState? { lecture.slides.indices.contains(pageIndex) ? lecture.slides[pageIndex] : nil }
    func thread(page: Int) -> SlideThread? { lecture.threads.first { $0.anchorPage == page } }
    var focusedPage: Int? { focusedPageIndex.map { $0 + 1 } }

    var filteredSlides: [SlideState] {
        switch prepareFilter {
        case .all: lecture.slides
        case .selected: lecture.slides.filter(\.isSelected)
        case .noCards: lecture.slides.filter { lecture.coverage(page: $0.pageIndex + 1) == 0 }
        }
    }

    var visibleCards: [Card] {
        var copy = lecture
        copy.viewPreferences.reviewFilter = reviewFilter
        let cards = reviewFilter == .aiFlagged ? activeCards.filter { $0.flag != nil || $0.proposal != nil } : copy.visibleCards
        let order = Dictionary(uniqueKeysWithValues: activeCards.enumerated().map { ($0.element.id, $0.offset) })
        return cards.sorted { (order[$0.id] ?? 0) < (order[$1.id] ?? 0) }.filter { reviewSearch.isEmpty || $0.front.localizedCaseInsensitiveContains(reviewSearch) || $0.back.localizedCaseInsensitiveContains(reviewSearch) }
    }

    func count(for filter: ReviewFilter) -> Int {
        var copy = lecture
        copy.viewPreferences.reviewFilter = filter
        return filter == .aiFlagged ? activeCards.filter { $0.flag != nil || $0.proposal != nil }.count : copy.visibleCards.count
    }

    var activeCards: [Card] { lecture.cards.filter { !$0.isSuperseded } }
    var reviewedCount: Int { activeCards.filter { $0.verdict != .unreviewed }.count }

    /// Stable display numbers in lecture order ("Card 19").
    var cardNumbers: [UUID: Int] {
        Dictionary(uniqueKeysWithValues: activeCards.enumerated().map { ($0.element.id, $0.offset + 1) })
    }

    var selectedCard: Card? {
        guard let id = selectedCardID else { return nil }
        return lecture.cards.first { $0.id == id && !$0.isSuperseded }
    }

    func cards(from page: Int) -> [Card] { activeCards.filter { $0.sourcePages.contains(page) } }

    var runningJobs: [Job] { lecture.jobs.filter { $0.state == .running } }
    var runningGenerate: Job? { runningJobs.first { $0.kind == .generate } }

    func progress(_ jobID: UUID) -> JobProgress? { session.jobs[jobID] }

    /// Failed, cancelled and interrupted jobs from this lecture that the user has not dismissed.
    var attentionJobs: [Job] {
        lecture.jobs.filter { job in
            [.failed, .interrupted].contains(job.state) && !dismissedJobIDs.contains(job.id)
                && (job.state == .interrupted || (job.finishedAt ?? .distantPast) > openedAt.addingTimeInterval(-3600))
        }
    }

    /// The latest Generate that landed while this window was open, until dismissed.
    var landedGenerate: Job? {
        lecture.jobs.last { $0.kind == .generate && $0.state == .succeeded && ($0.finishedAt ?? .distantPast) > openedAt && !dismissedJobIDs.contains($0.id) }
    }

    // MARK: Navigation

    func setMode(_ new: LectureMode) {
        guard new != mode else { return }
        if new == .prepare && lecture.pageCount == 0 { errorMessage = "This lecture has no slides. It was imported from the reviewer."; return }
        Task { await flushAll() }
        mode = new
        if new == .review, selectedCardID == nil || selectedCard == nil { selectedCardID = visibleCards.first?.id; loadEditor() }
    }

    func moveFocus(_ delta: Int) {
        let slides = filteredSlides
        guard !slides.isEmpty else { return }
        let current = slides.firstIndex { $0.pageIndex == focusedPageIndex } ?? (delta > 0 ? -1 : slides.count)
        let next = min(max(current + delta, 0), slides.count - 1)
        focus(slides[next].pageIndex)
    }

    func focus(_ pageIndex: Int) {
        guard pageIndex != focusedPageIndex else { return }
        flushNote()
        focusedPageIndex = pageIndex
    }

    func toggleSelection(_ pageIndex: Int) async {
        guard let slide = slide(pageIndex) else { return }
        await dispatch(.setSlideSelection(pageIndex: pageIndex, !slide.isSelected))
    }

    func setAllSelected(_ selected: Bool) async {
        guard !readOnly else { return }
        await run {
            for slide in lecture.slides where slide.isSelected != selected {
                try await session.dispatch(.setSlideSelection(pageIndex: slide.pageIndex, selected))
            }
        }
        app.scheduleReload()
    }

    /// Review → Prepare at the card's linked slide (G).
    func jumpToPrepare(page: Int) {
        guard lecture.pageCount > 0, (1...lecture.pageCount).contains(page) else { return }
        flushAllInBackground()
        mode = .prepare
        if prepareFilter != .all && !filteredSlides.contains(where: { $0.pageIndex == page - 1 }) { prepareFilter = .all }
        focusedPageIndex = page - 1
    }

    /// Prepare → Review showing the cards from one slide.
    func showCards(fromPage page: Int) {
        flushNote()
        mode = .review
        reviewFilter = .all
        selectCard(cards(from: page).first?.id ?? visibleCards.first?.id)
    }

    func selectCard(_ id: UUID?) {
        guard id != selectedCardID else { return }
        flushCardInBackground()
        selectedCardID = id
        sourceIndex = 0
        loadEditor()
    }

    func stepCard(_ delta: Int) {
        let cards = visibleCards
        guard !cards.isEmpty else { return }
        let index = cards.firstIndex { $0.id == selectedCardID } ?? (delta > 0 ? -1 : cards.count)
        selectCard(cards[min(max(index + delta, 0), cards.count - 1)].id)
    }

    func setReviewFilter(_ filter: ReviewFilter) {
        reviewFilter = filter
        if let id = selectedCardID, visibleCards.contains(where: { $0.id == id }) { return }
        selectCard(visibleCards.first?.id)
    }

    // MARK: Notes

    func noteText(for pageIndex: Int) -> String {
        noteDraftPage == pageIndex ? noteDraft : (slide(pageIndex)?.note ?? "")
    }

    func editNote(_ text: String, pageIndex: Int) {
        guard !readOnly else { return }
        if noteDraftPage != pageIndex { flushNote() }
        noteDraftPage = pageIndex
        noteDraft = text
        noteTask?.cancel()
        noteTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.flushNote()
        }
    }

    /// Typing on a focused thumbnail opens the note and keeps the first character.
    func appendToNote(_ text: String) -> Bool {
        guard !readOnly, let page = focusedPageIndex else { return false }
        notesVisible = true
        editNote(noteText(for: page) + text, pageIndex: page)
        return true
    }

    func flushNote() {
        noteTask?.cancel(); noteTask = nil
        guard let page = noteDraftPage else { return }
        let text = noteDraft
        if slide(page)?.note == text { noteDraftPage = nil; return }
        Task { [weak self] in
            guard let self else { return }
            await self.dispatch(.updateNote(pageIndex: page, text))
            if self.noteDraftPage == page && self.noteDraft == text { self.noteDraftPage = nil }
        }
    }

    private func flushNoteNow() async throws {
        noteTask?.cancel(); noteTask = nil
        guard let page = noteDraftPage else { return }
        let text = noteDraft
        if slide(page)?.note != text, !app.isArchived(ref.moduleID) {
            try await session.dispatch(.updateNote(pageIndex: page, text))
        }
        if noteDraftPage == page && noteDraft == text { noteDraftPage = nil }
    }

    // MARK: Card editor

    func loadEditor() {
        let card = selectedCard
        editorCardID = card?.id
        editorFront = card?.front ?? ""
        editorBack = card?.back ?? ""
        editorSources = card?.sourcePages.map(String.init).joined(separator: ", ") ?? ""
        feedbackDraft = card?.feedback ?? ""
        lastStaged = card.map { (front: $0.front, back: $0.back, sources: $0.sourcePages) }
    }

    /// Called when the session's lecture changes. Keeps the user's in-flight typing, but picks
    /// up text that changed elsewhere (accepted proposal, restore, undo, another window).
    func syncEditor() {
        if selectedCardID != nil && selectedCard == nil {
            // Selected card was split, undone or removed: fall back to a visible card.
            selectedCardID = visibleCards.first?.id
            loadEditor()
            return
        }
        guard let card = selectedCard, card.id == editorCardID else { loadEditor(); return }
        let staged = lastStaged
        let matchesStaged = staged.map { $0.front == card.front && $0.back == card.back && $0.sources == card.sourcePages } ?? false
        let matchesBuffer = card.front == editorFront && card.back == editorBack && card.sourcePages == parsedSources
        if !matchesStaged && !matchesBuffer {
            let feedback = feedbackDraft   // keep feedback the user is still typing
            loadEditor()
            feedbackDraft = feedback
        }
    }

    var parsedSources: [Int] {
        editorSources.split(whereSeparator: { $0 == "," || $0 == " " || $0 == ";" }).compactMap { Int($0) }
    }

    func editorChanged() {
        guard !readOnly, let id = editorCardID else { return }
        let sources = parsedSources
        lastStaged = (front: editorFront, back: editorBack, sources: sources)
        session.stageCardEdit(cardID: id, front: editorFront, back: editorBack, sourcePages: sources)
    }

    func saveFeedback() async {
        guard let card = selectedCard, card.feedback != feedbackDraft else { return }
        await dispatch(.setFeedback(cardID: card.id, feedbackDraft))
    }

    private func flushCardInBackground() {
        Task { [weak self] in
            guard let self else { return }
            await self.run { try await self.session.flushEdits() }
            await self.saveFeedback()
        }
    }

    private func flushAllInBackground() { Task { await flushAll() } }

    func flushAll() async {
        await run {
            try await flushNoteNow()
            try await session.flushEdits()
        }
    }

    /// Throwing variant for archive and close paths, which must not proceed on failure.
    func flushAllThrowing() async throws {
        try await flushNoteNow()
        try await session.flushEdits()
    }

    // MARK: Review actions

    func setVerdict(_ verdict: CardVerdict) async {
        guard let card = selectedCard else { return }
        await run { try await session.flushEdits() }
        let before = visibleCards
        await dispatch(.setVerdict(cardID: card.id, verdict))
        guard errorMessage == nil, verdict != .needsAdjustment else { return }
        advance(from: card.id, previous: before)
    }

    /// After a verdict, move to the next card in the list as it was before the change.
    private func advance(from id: UUID, previous: [Card]) {
        guard let index = previous.firstIndex(where: { $0.id == id }) else { return }
        let remaining = visibleCards
        for candidate in previous[(index + 1)...] where remaining.contains(where: { $0.id == candidate.id }) {
            selectCard(candidate.id); return
        }
        if !remaining.contains(where: { $0.id == id }) { selectCard(remaining.first?.id) }
    }

    func acceptProposal(approve: Bool) async {
        guard let card = selectedCard, card.proposal?.state == .ready else { return }
        await run { try await session.flushEdits() }
        await dispatch(.acceptProposal(cardID: card.id, approve: approve))
        syncEditor()
    }

    func discardProposal() async {
        guard let card = selectedCard, card.proposal != nil else { return }
        await dispatch(.discardProposal(cardID: card.id))
    }

    /// "Edit first": take the proposal into the editors without accepting it.
    func editProposalFirst() async {
        guard let card = selectedCard, let draft = card.proposal?.cards.first, card.proposal?.cards.count == 1 else { return }
        editorFront = draft.front
        editorBack = draft.back
        editorSources = draft.sourcePages.map(String.init).joined(separator: ", ")
        editorChanged()
        await dispatch(.discardProposal(cardID: card.id))
    }

    func restoreOriginal() async {
        guard let card = selectedCard else { return }
        await run { try await session.flushEdits() }
        await dispatch(.restoreOriginal(cardID: card.id))
        loadEditor()
    }

    func undo() async {
        guard !readOnly, session.canUndo else { return }
        await run { try await session.undo() }
        reviewFilter = .all
        syncEditor()
        app.scheduleReload()
    }

    // MARK: AI

    private var backend: AIBackend { settings.backend }
    private var model: String { settings.selectedModel }

    func generate(additionalInstructions: String) async {
        guard !readOnly else { return }
        var started = false
        await run {
            try await flushNoteNow()
            _ = try await session.generate(backend: backend, model: model,
                                           additionalInstructions: additionalInstructions, replaceExistingCards: true)
            started = true
            try await session.refresh()
        }
        app.scheduleReload()
        // Review shows the generation overlay until the cards land, then reveals them.
        if started { setMode(.review) }
    }

    /// Called when a Generate stops running. In Review, show the new cards; with none,
    /// leave the job undismissed so Prepare's landing banner can explain the skipped slides.
    func revealGenerated(_ jobID: UUID) {
        guard mode == .review, let job = lecture.jobs.first(where: { $0.id == jobID }), job.state == .succeeded else { return }
        let fresh = activeCards.filter { if case .generated(let id) = $0.origin { return id == jobID }; return false }
        guard let first = fresh.first else { return }
        dismissedJobIDs.insert(jobID)
        setReviewFilter(fresh.allSatisfy { $0.verdict == .unreviewed } ? .unreviewed : .all)
        selectCard(first.id)
    }

    func sendFeedback() async {
        guard !readOnly, let card = selectedCard else { return }
        let feedback = feedbackDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !feedback.isEmpty else { errorMessage = "Write what should change first."; return }
        let previous = visibleCards
        var started = false
        await run {
            _ = try await session.revise(cardID: card.id, feedback: feedback, backend: backend, model: model)
            try await session.refresh()
            started = true
        }
        if started { advance(from: card.id, previous: previous) }
        app.scheduleReload()
    }

    func makeModuleRule() async {
        let feedback = feedbackDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !readOnly, !feedback.isEmpty else { return }
        await run { try await app.library.makeModuleRule(moduleID: ref.moduleID, feedback: feedback) }
        try? await app.reloadNow()
        if errorMessage == nil { proposeResult = "Added to \(moduleName)'s instructions. It applies to the next generation." }
    }

    func askContext(for page: Int) -> ThreadContext {
        let context = askContexts[page] ?? thread(page: page)?.context ?? .slide
        // Older chats may retain a neighbouring-slide scope; use the current slide instead.
        if context == .none || context == .lecture { return context }
        return page > 0 ? .slide : .none
    }

    func askFlashcardContext(for page: Int, cardID: UUID?) -> FlashcardContext {
        let context = askFlashcardContexts[page] ?? thread(page: page)?.flashcardContext
            ?? (cardID == nil ? FlashcardContext.none : .current)
        return context == .current && cardID == nil ? .none : context
    }

    func ask(page: Int, cardID: UUID? = nil) async {
        guard !readOnly else { return }
        let question = (askDrafts[page] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        let context = askContext(for: page)
        await run {
            _ = try await session.chat(anchorPage: page, context: context, question: question, cardID: cardID,
                                      backend: backend, model: model,
                                      flashcardContext: askFlashcardContext(for: page, cardID: cardID))
            askDrafts[page] = ""
            try await session.refresh()
        }
    }

    /// The running Ask/Distil job on a thread, if any, for streaming display.
    func runningConversationJob(page: Int) -> Job? {
        guard let thread = thread(page: page) else { return nil }
        return runningJobs.first { $0.threadID == thread.id && ($0.kind == .ask || $0.kind == .chat || $0.kind == .distil) }
    }

    func undoChatEdits(jobID: UUID) async {
        guard !readOnly else { return }
        await run {
            try await session.flushEdits()
            try await session.dispatch(.undoChatEdits(jobID: jobID))
        }
        syncEditor()
        app.scheduleReload()
    }

    func updateLearningPoint(page: Int, pointID: UUID, text: String? = nil, included: Bool? = nil) async {
        guard !readOnly, let threadID = thread(page: page)?.id else { return }
        // Change only this point inside a store mutation, so an answer landing meanwhile survives.
        await run {
            _ = try await app.store.updateLecture(moduleID: ref.moduleID, lectureID: ref.lectureID) { lecture in
                guard let t = lecture.threads.firstIndex(where: { $0.id == threadID }),
                      let p = lecture.threads[t].learningPoints.firstIndex(where: { $0.id == pointID }) else { return }
                if let text { lecture.threads[t].learningPoints[p].text = text }
                if let included { lecture.threads[t].learningPoints[p].included = included }
            }
            try await session.refresh()
        }
    }

    func proposeUpdates(page: Int) async {
        guard !readOnly else { return }
        await run {
            try await flushAllThrowing()
            let result = try await app.runner.proposeUpdates(moduleID: ref.moduleID, lectureID: ref.lectureID, page: page, backend: backend, model: model)
            try await session.refresh()
            var parts: [String] = []
            if !result.jobIDs.isEmpty { parts.append("Revising \(Format.count(result.jobIDs.count, "card")).") }
            if !result.skippedCardIDs.isEmpty { parts.append("\(Format.count(result.skippedCardIDs.count, "card")) skipped: a proposal or revision is already pending.") }
            if !result.failures.isEmpty { parts.append("\(result.failures.count) could not start: \(result.failures.values.first ?? "")") }
            proposeResult = parts.isEmpty ? "No cards on this slide to update." : parts.joined(separator: " ")
        }
        app.scheduleReload()
    }

    func cancel(_ jobID: UUID) async {
        await run {
            if runningChat?.id == jobID { try await session.stopChat() }
            else { try await app.runner.cancel(moduleID: ref.moduleID, lectureID: ref.lectureID, jobID: jobID) }
            try await session.refresh()
        }
        app.scheduleReload()
    }

    func retry(_ jobID: UUID) async {
        guard !readOnly else { return }
        await run {
            try await app.runner.retry(moduleID: ref.moduleID, lectureID: ref.lectureID, jobID: jobID)
            try await session.refresh()
        }
        app.scheduleReload()
    }

    // MARK: Lifecycle

    func reloadAfterExternalChange() async {
        await run { try await session.refresh() }
        syncEditor()
    }

    var currentPreferences: ViewPreferences {
        var prefs = lecture.viewPreferences
        prefs.mode = lecture.pageCount == 0 ? .review : mode
        prefs.focusedPageIndex = focusedPageIndex.flatMap { lecture.slides.indices.contains($0) ? $0 : nil }
        prefs.filter = prepareFilter == .selected ? .selected : .all
        prefs.reviewFilter = reviewFilter
        prefs.selectedCardID = selectedCardID.flatMap { id in lecture.cards.contains { $0.id == id } ? id : nil }
        prefs.thumbnailSize = thumbnailSize
        prefs.inspectorVisible = notesVisible
        prefs.sidebarVisible = thumbnailsVisible
        return prefs
    }

    /// Saves notes, card edits and view state. Throws so the window can stay open on failure.
    func closeAndFlush() async throws {
        chatDraftSaveTask?.cancel()
        if !readOnly { try await session.setChatDraft(chatDraft, attachments: chatDraftAttachments) }
        try await commitTitle()
        try await flushNoteNow()
        if !app.isArchived(ref.moduleID) && currentPreferences != lecture.viewPreferences {
            try await session.dispatch(.setViewPreferences(currentPreferences))
        }
        isClosing = true
        do { try await session.closeAndFlush() }
        catch { isClosing = false; throw error }
        app.unregister(self)
        app.scheduleReload()
    }
}
