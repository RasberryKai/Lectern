import Foundation

public enum LectureError: Error, LocalizedError, Equatable, Sendable {
    case identityMismatch, staleSnapshot
    case unsupportedSchema(Int), invalidMetadata(String), missingCard(UUID), missingJob(UUID), missingThread(UUID)
    case invalidApproval(UUID), invalidProposal(UUID), duplicateID(UUID), jobNotRunning(UUID), jobAlreadyExists(UUID)
    public var errorDescription: String? {
        switch self {
        case .invalidMetadata(let message): return message
        case .missingCard: return "A flashcard no longer exists. Send a new request using the current cards."
        case .jobNotRunning: return "This request is no longer running."
        case .staleSnapshot: return "The lecture changed. Reload it and try again."
        default: return "The lecture could not be updated because its data changed or is invalid."
        }
    }
}
public extension Lecture {
    func canUndoChatEdits(jobID: UUID) -> Bool {
        guard let job = jobs.first(where: { $0.id == jobID }), job.state == .succeeded,
              job.chatEditsUndoneAt == nil, let edits = job.chatEditUndo, !edits.isEmpty else { return false }
        return edits.allSatisfy { edit in
            cards.contains { edit.matches($0) }
        }
    }
    func validated() throws -> Lecture {
        guard progressOverride != .notImported else {
            throw LectureError.invalidMetadata("Only empty slots can be marked Not imported.")
        }
        guard schemaVersion == Self.currentSchemaVersion else { throw LectureError.unsupportedSchema(schemaVersion) }
        guard pageCount >= 0, slides.count == pageCount, slides.enumerated().allSatisfy({ $0.offset == $0.element.pageIndex }) else { throw LectureError.invalidMetadata("Slide state does not match page count") }
        for ids in [cards.map(\.id), jobs.map(\.id), threads.map(\.id)] {
            var seen = Set<UUID>()
            for id in ids where !seen.insert(id).inserted { throw LectureError.duplicateID(id) }
        }
        guard Set(threads.map(\.anchorPage)).count == threads.count, threads.allSatisfy({
            $0.anchorPage == 0 || ((1...max(1, pageCount)).contains($0.anchorPage) && pageCount > 0)
        }) else { throw LectureError.invalidMetadata("Threads must have unique valid anchor pages") }
        if let focused = viewPreferences.focusedPageIndex, !(0..<pageCount).contains(focused) { throw LectureError.invalidMetadata("Invalid focused page") }
        if let selected = viewPreferences.selectedCardID, !cards.contains(where: { $0.id == selected }) { throw LectureError.missingCard(selected) }
        guard jobs.allSatisfy({ job in (job.kind != .generate || !job.pages.isEmpty) && job.pages.allSatisfy { $0 > 0 && $0 <= pageCount } }) else { throw LectureError.invalidMetadata("Job pages must belong to the document") }
        guard cards.allSatisfy({ !$0.history.isEmpty }) else { throw LectureError.invalidMetadata("Card history cannot be empty") }
        for card in cards where card.verdict == .good {
            guard issues(for: card).isEmpty else { throw LectureError.invalidApproval(card.id) }
        }
        return self
    }
    func issues(for card: Card) -> [CardIssue] {
        var result = card.issue.map { [$0] } ?? []
        if (card.requiresSourcePages || card.origin != .manual && pageCount > 0) && card.sourcePages.isEmpty { result.append(CardIssue(kind: .invalidSource, message: "AI cards need a source page.")) }
        if card.front.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || card.back.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result.append(CardIssue(kind: .emptySide, message: "Both sides need text.")) }
        if card.sourcePages.contains(where: { $0 < 1 || $0 > pageCount }) { result.append(CardIssue(kind: .invalidSource, message: "Source pages must belong to the document and job scope.")) }
        if let allowed = card.allowedSourcePages, card.sourcePages.contains(where: { !allowed.contains($0) }), !result.contains(where: { $0.kind == .invalidSource }) { result.append(CardIssue(kind: .invalidSource, message: "Source pages are outside the job scope.")) }
        if ![card.front, card.back].allSatisfy({ (try? FlashcardMathFormatter.formatForAnki($0, interpretations: card.mathInterpretations)) != nil }) { result.append(CardIssue(kind: .unresolvedMath, message: "Choose how to interpret ambiguous or unbalanced math.")) }
        return result
    }
    func coverage(page: Int) -> Int { cards.filter { !$0.isSuperseded && $0.verdict != .bad && $0.sourcePages.contains(page) }.count }
    var uncoveredSelectedPages: [Int] { slides.filter { $0.isSelected && coverage(page: $0.pageIndex + 1) == 0 }.map { $0.pageIndex + 1 } }
    var visibleCards: [Card] {
        cards.filter { card in
            guard !card.isSuperseded else { return false }
            switch viewPreferences.reviewFilter {
            case .all: return true
            case .aiFlagged: return card.flag != nil
            case .proposals: return card.proposal != nil
            case .unreviewed: return card.verdict == .unreviewed
            case .good: return card.verdict == .good
            case .bad: return card.verdict == .bad
            case .needsAdjustment: return card.verdict == .needsAdjustment
            }
        }.enumerated().sorted { lhs, rhs in
            let l = lhs.element.flag != nil, r = rhs.element.flag != nil
            return l == r ? lhs.offset < rhs.offset : l
        }.map(\.element)
    }
}
public enum LectureAction: Equatable, Sendable {
    case setVerdict(cardID: UUID, CardVerdict)
    case commitEdit(cardID: UUID, front: String, back: String, sourcePages: [Int])
    case setFeedback(cardID: UUID, String)
    case resolveIssue(cardID: UUID)
    case setMathInterpretation(cardID: UUID, span: String, MathInterpretation)
    case restoreOriginal(cardID: UUID)
    case acceptProposal(cardID: UUID, approve: Bool)
    case discardProposal(cardID: UUID)
    case addCards([Card])
    case startJob(Job)
    case updateJob(Job)
    case landGeneration(jobID: UUID, cards: [CardDraft], skipped: [SkippedSlide], usage: AIUsage?)
    case landProposal(jobID: UUID, cards: [CardDraft], rationale: String, usage: AIUsage?)
    case applyChatEdits(jobID: UUID, edits: [ChatCardEdit])
    case undoChatEdits(jobID: UUID)
    case upsertThread(SlideThread)
    case setSlideSelection(pageIndex: Int, Bool)
    case updateNote(pageIndex: Int, String)
    case setViewPreferences(ViewPreferences)
    case markExported(cardIDs: [UUID])
    case markExportEntries([ExportEntry])
}
public enum LectureReducer {
    /// Reduces a copy first: failed validation never leaves partial mutations behind.
    public static func reduce(_ lecture: inout Lecture, action: LectureAction, now: Date = Date()) throws {
        var next = lecture
        try apply(&next, action: action, now: now)
        next.updatedAt = now
        _ = try next.validated()
        lecture = next
    }
    private static func index(_ id: UUID, in lecture: Lecture) throws -> Int {
        guard let i = lecture.cards.firstIndex(where: { $0.id == id }) else { throw LectureError.missingCard(id) }; return i
    }
    private static func jobIndex(_ id: UUID, in lecture: Lecture) throws -> Int {
        guard let i = lecture.jobs.firstIndex(where: { $0.id == id }) else { throw LectureError.missingJob(id) }; return i
    }
    private static func appendRevision(_ card: inout Card, author: RevisionAuthor, reason: String?, now: Date) {
        card.history.append(CardRevision(front: card.front, back: card.back, author: author, reason: reason, at: now))
    }
    private static func apply(_ lecture: inout Lecture, action: LectureAction, now: Date) throws {
        switch action {
        case .setVerdict(let id, let verdict):
            let i = try index(id, in: lecture)
            if verdict == .good && !lecture.issues(for: lecture.cards[i]).isEmpty { throw LectureError.invalidApproval(id) }
            lecture.cards[i].verdict = verdict
        case .commitEdit(let id, let front, let back, let pages):
            let i = try index(id, in: lecture)
            guard lecture.cards[i].front != front || lecture.cards[i].back != back || lecture.cards[i].sourcePages != pages else { return }
            if lecture.cards[i].front != front || lecture.cards[i].back != back { lecture.cards[i].mathInterpretations = [:] }
            lecture.cards[i].front = front; lecture.cards[i].back = back; lecture.cards[i].sourcePages = pages
            if lecture.cards[i].verdict == .good { lecture.cards[i].verdict = .unreviewed }
            appendRevision(&lecture.cards[i], author: .user, reason: "Manual edit", now: now)
        case .setFeedback(let id, let feedback): lecture.cards[try index(id, in: lecture)].feedback = feedback
        case .resolveIssue(let id): lecture.cards[try index(id, in: lecture)].issue = nil
        case .setMathInterpretation(let id, let span, let choice): lecture.cards[try index(id, in: lecture)].mathInterpretations[span] = choice
        case .restoreOriginal(let id):
            let i = try index(id, in: lecture)
            guard let original = lecture.cards[i].history.first else { return }
            if lecture.cards[i].front != original.front || lecture.cards[i].back != original.back { lecture.cards[i].mathInterpretations = [:] }
            lecture.cards[i].front = original.front; lecture.cards[i].back = original.back; lecture.cards[i].verdict = .unreviewed
            appendRevision(&lecture.cards[i], author: .user, reason: "Restore original", now: now)
        case .discardProposal(let id): lecture.cards[try index(id, in: lecture)].proposal = nil
        case .acceptProposal(let id, let approve):
            let i = try index(id, in: lecture)
            guard let proposal = lecture.cards[i].proposal, proposal.state == .ready, (1...3).contains(proposal.cards.count) else { throw LectureError.invalidProposal(id) }
            if proposal.cards.count > 1 {
                let children = proposal.cards.map { draft in Card(sourcePages: draft.sourcePages, front: draft.front, back: draft.back, flag: draft.flag, history: [CardRevision(front: draft.front, back: draft.back, author: .ai, reason: proposal.rationale, at: now)], origin: .splitFrom(cardID: id), allowedSourcePages: proposal.allowedSourcePages ?? lecture.cards[i].allowedSourcePages) }
                lecture.cards[i].supersededBy = children.map(\.id); lecture.cards[i].proposal = nil; lecture.cards.append(contentsOf: children)
            } else {
                let draft = proposal.cards[0]
                if lecture.cards[i].front != draft.front || lecture.cards[i].back != draft.back { lecture.cards[i].mathInterpretations = [:] }
                lecture.cards[i].front = draft.front; lecture.cards[i].back = draft.back; lecture.cards[i].sourcePages = draft.sourcePages; lecture.cards[i].flag = draft.flag; lecture.cards[i].allowedSourcePages = proposal.allowedSourcePages ?? lecture.cards[i].allowedSourcePages; lecture.cards[i].proposal = nil; lecture.cards[i].verdict = .unreviewed
                if let issue = lecture.cards[i].issue, issue.kind == .importSyntax || issue.kind == .emptySide { lecture.cards[i].issue = nil }
                appendRevision(&lecture.cards[i], author: .ai, reason: proposal.rationale, now: now)
                if approve { guard lecture.issues(for: lecture.cards[i]).isEmpty else { throw LectureError.invalidApproval(id) }; lecture.cards[i].verdict = .good }
            }
        case .addCards(let cards): lecture.cards.append(contentsOf: cards)
        case .startJob(let job):
            guard !lecture.jobs.contains(where: { $0.id == job.id }) else { throw LectureError.jobAlreadyExists(job.id) }
            lecture.jobs.append(job)
        case .updateJob(let job): lecture.jobs[try jobIndex(job.id, in: lecture)] = job
        case .landGeneration(let id, let drafts, let skipped, let usage):
            let j = try jobIndex(id, in: lecture)
            guard lecture.jobs[j].state == .running else { throw LectureError.jobNotRunning(id) }
            guard lecture.jobs[j].kind == .generate else { throw LectureError.invalidMetadata("Wrong job kind") }
            let pages = lecture.jobs[j].pages
            if lecture.jobs[j].replacesExistingCards == true {
                lecture.cards.removeAll()
                lecture.skippedSlides.removeAll()
                lecture.viewPreferences.selectedCardID = nil
            }
            lecture.cards.append(contentsOf: drafts.map { Card(sourcePages: $0.sourcePages, front: $0.front, back: $0.back, flag: $0.flag, history: [CardRevision(front: $0.front, back: $0.back, author: .ai, at: now)], origin: .generated(jobID: id), allowedSourcePages: pages) })
            lecture.skippedSlides.append(contentsOf: skipped); lecture.jobs[j].state = .succeeded; lecture.jobs[j].finishedAt = now; lecture.jobs[j].usage = usage
        case .landProposal(let id, let cards, let rationale, let usage):
            let j = try jobIndex(id, in: lecture)
            guard lecture.jobs[j].state == .running else { throw LectureError.jobNotRunning(id) }
            guard lecture.jobs[j].kind == .revise, (1...3).contains(cards.count) else { throw LectureError.invalidProposal(id) }
            guard let target = lecture.jobs[j].targetCardID, let base = lecture.jobs[j].baseRevisionID else { throw LectureError.invalidProposal(id) }
            let i = try index(target, in: lecture)
            lecture.cards[i].proposal = Proposal(jobID: id, baseRevisionID: base, cards: cards, rationale: rationale, allowedSourcePages: lecture.jobs[j].pages)
            lecture.jobs[j].state = .succeeded; lecture.jobs[j].finishedAt = now; lecture.jobs[j].usage = usage
        case .applyChatEdits(let id, let edits):
            let j = try jobIndex(id, in: lecture)
            guard lecture.jobs[j].kind == .chat, lecture.jobs[j].state == .running else { throw LectureError.jobNotRunning(id) }
            guard Set(edits.map(\.cardID)).count == edits.count else { throw LectureError.invalidMetadata("Chat returned duplicate card edits.") }
            let allowed = lecture.jobs[j].chatCardVersions ?? []
            var undo: [ChatEditUndo] = []
            for edit in edits {
                guard let version = allowed.first(where: { $0.cardID == edit.cardID && $0.revisionID == edit.baseRevisionID }) else {
                    throw LectureError.invalidMetadata("Chat tried to edit a card outside its selected context.")
                }
                let i = try index(edit.cardID, in: lecture)
                guard version.matches(lecture.cards[i]) else {
                    throw LectureError.invalidMetadata("A flashcard changed while chat was working. Your changes were kept; send the request again.")
                }
                guard !edit.front.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !edit.back.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw LectureError.invalidMetadata("Chat returned a card with an empty front or back.")
                }
                guard lecture.cards[i].front != edit.front || lecture.cards[i].back != edit.back else { continue }
                let before = lecture.cards[i]
                lecture.cards[i].front = edit.front; lecture.cards[i].back = edit.back
                lecture.cards[i].mathInterpretations = [:]
                if lecture.cards[i].verdict == .good || lecture.jobs[j].chatEdits != nil { lecture.cards[i].verdict = .unreviewed }
                let revision = CardRevision(front: edit.front, back: edit.back, author: .ai, reason: "Chat edit", at: now)
                lecture.cards[i].history.append(revision)
                undo.append(ChatEditUndo(cardID: edit.cardID, appliedRevisionID: revision.id,
                    front: before.front, back: before.back, verdict: before.verdict, mathInterpretations: before.mathInterpretations,
                    appliedVerdict: lecture.cards[i].verdict, appliedMathInterpretations: lecture.cards[i].mathInterpretations))
            }
            lecture.jobs[j].chatEditUndo = undo.isEmpty ? nil : undo
        case .undoChatEdits(let id):
            let j = try jobIndex(id, in: lecture)
            guard lecture.jobs[j].state == .succeeded, lecture.jobs[j].chatEditsUndoneAt == nil,
                  let edits = lecture.jobs[j].chatEditUndo, !edits.isEmpty else {
                throw LectureError.invalidMetadata("There are no chat edits to undo.")
            }
            for edit in edits {
                let i = try index(edit.cardID, in: lecture)
                guard edit.matches(lecture.cards[i]) else {
                    throw LectureError.invalidMetadata("A card was changed after this chat edit. Undo would overwrite newer changes.")
                }
                lecture.cards[i].front = edit.front; lecture.cards[i].back = edit.back
                lecture.cards[i].mathInterpretations = edit.mathInterpretations
                lecture.cards[i].verdict = edit.verdict
                if edit.verdict == .good && !lecture.issues(for: lecture.cards[i]).isEmpty { lecture.cards[i].verdict = .unreviewed }
                appendRevision(&lecture.cards[i], author: .user, reason: "Undo chat edit", now: now)
            }
            lecture.jobs[j].chatEditsUndoneAt = now
        case .upsertThread(let thread):
            if let i = lecture.threads.firstIndex(where: { $0.id == thread.id }) { lecture.threads[i] = thread } else { lecture.threads.append(thread) }
        case .setSlideSelection(let page, let selected):
            guard lecture.slides.indices.contains(page) else { throw LectureError.invalidMetadata("Invalid slide") }
            lecture.slides[page].isSelected = selected
        case .updateNote(let page, let text):
            guard lecture.slides.indices.contains(page) else { throw LectureError.invalidMetadata("Invalid slide") }
            let wasEmpty = lecture.slides[page].note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            lecture.slides[page].note = text
            if wasEmpty && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { lecture.slides[page].isSelected = true }
        case .setViewPreferences(let preferences): lecture.viewPreferences = preferences
        case .markExportEntries(let entries):
            for entry in entries where entry.lectureID == lecture.id {
                let i = try index(entry.cardID, in: lecture)
                guard lecture.cards[i].history.contains(where: { $0.id == entry.revisionID }) else { throw LectureError.invalidMetadata("Export revision is missing") }
                lecture.cards[i].exported = ExportMark(revisionID: entry.revisionID, date: now)
            }
        case .markExported(let ids):
            for id in ids {
                let i = try index(id, in: lecture)
                guard lecture.cards[i].verdict == .good, !lecture.cards[i].isSuperseded, lecture.issues(for: lecture.cards[i]).isEmpty, let revision = lecture.cards[i].currentRevisionID else { throw LectureError.invalidApproval(id) }
                lecture.cards[i].exported = ExportMark(revisionID: revision, date: now)
            }
        }
    }
}

/// In-memory undo stores only touched user fields; asynchronous job state is never rolled back.
public struct LectureController: Sendable {
    public private(set) var lecture: Lecture
    private var undoStack: [UndoEntry] = []
    private struct UndoEntry: Sendable { var before: Lecture; var after: Lecture }
    public init(lecture: Lecture) { self.lecture = lecture }
    public var canUndo: Bool { !undoStack.isEmpty }
    /// Refresh from persistence without dropping user undo. Older snapshots are rejected atomically.
    public mutating func receive(_ latest: Lecture) throws {
        guard latest.id == lecture.id, latest.moduleID == lecture.moduleID else { throw LectureError.identityMismatch }
        guard latest.updatedAt.timeIntervalSince1970.rounded(.down) >= lecture.updatedAt.timeIntervalSince1970.rounded(.down) else { throw LectureError.staleSnapshot }
        let replacementLanded = latest.jobs.contains { job in
            job.kind == .generate && job.replacesExistingCards == true && job.state == .succeeded &&
                lecture.jobs.first(where: { $0.id == job.id })?.state != .succeeded
        }
        for current in lecture.cards {
            guard let incoming = latest.cards.first(where: { $0.id == current.id }) else {
                guard replacementLanded else { throw LectureError.staleSnapshot }
                continue
            }
            guard Set(current.history.map(\.id)).isSubset(of: Set(incoming.history.map(\.id))) else { throw LectureError.staleSnapshot }
        }
        _ = try latest.validated()
        lecture = latest
    }
    public mutating func dispatch(_ action: LectureAction, now: Date = Date()) throws {
        let before = lecture
        try LectureReducer.reduce(&lecture, action: action, now: now)
        switch action {
        case .startJob, .updateJob, .landGeneration, .landProposal, .applyChatEdits, .undoChatEdits, .upsertThread, .markExported, .markExportEntries: return
        default: break
        }
        if before != lecture { undoStack.append(UndoEntry(before: before, after: lecture)); if undoStack.count > 50 { undoStack.removeFirst() } }
    }
    public mutating func undo(now: Date = Date()) {
        guard let entry = undoStack.popLast() else { return }
        for old in entry.before.cards {
            guard let changed = entry.after.cards.first(where: { $0.id == old.id }), old != changed, let i = lecture.cards.firstIndex(where: { $0.id == old.id }) else { continue }
            var current = lecture.cards[i]
            if (old.front != changed.front || old.back != changed.back || old.sourcePages != changed.sourcePages)
                && current.front == changed.front && current.back == changed.back && current.sourcePages == changed.sourcePages {
                current.front = old.front; current.back = old.back; current.sourcePages = old.sourcePages
                current.history.append(CardRevision(front: old.front, back: old.back, reason: "Undo", at: now))
            }
            if old.allowedSourcePages != changed.allowedSourcePages && current.allowedSourcePages == changed.allowedSourcePages { current.allowedSourcePages = old.allowedSourcePages }
            if old.verdict != changed.verdict && current.verdict == changed.verdict {
                current.verdict = old.verdict == .good && (!lecture.issues(for: current).isEmpty || current.front != old.front || current.back != old.back) ? .unreviewed : old.verdict
            }
            if old.flag != changed.flag && current.flag == changed.flag { current.flag = old.flag }
            if old.feedback != changed.feedback && current.feedback == changed.feedback { current.feedback = old.feedback }
            if old.issue != changed.issue && current.issue == changed.issue { current.issue = old.issue }
            if old.mathInterpretations != changed.mathInterpretations && current.mathInterpretations == changed.mathInterpretations { current.mathInterpretations = old.mathInterpretations }
            if old.proposal != changed.proposal && current.proposal == changed.proposal { current.proposal = old.proposal }
            if old.supersededBy != changed.supersededBy { current.supersededBy = old.supersededBy }
            lecture.cards[i] = current
        }
        let addedIDs = Set(entry.after.cards.map(\.id)).subtracting(entry.before.cards.map(\.id))
        // Preserve every generated/created card and its history; undo hides additions as superseded.
        for i in lecture.cards.indices where addedIDs.contains(lecture.cards[i].id) { lecture.cards[i].supersededBy = [] }
        for i in lecture.slides.indices where entry.before.slides.indices.contains(i) && entry.after.slides.indices.contains(i) {
            let before = entry.before.slides[i], after = entry.after.slides[i]
            if before.note != after.note && lecture.slides[i].note == after.note { lecture.slides[i].note = before.note }
            if before.isSelected != after.isSelected && lecture.slides[i].isSelected == after.isSelected { lecture.slides[i].isSelected = before.isSelected }
        }
        if entry.before.viewPreferences != entry.after.viewPreferences { lecture.viewPreferences = entry.before.viewPreferences }
        if let selected = lecture.viewPreferences.selectedCardID, !lecture.cards.contains(where: { $0.id == selected }) {
            lecture.viewPreferences.selectedCardID = nil
        }
        lecture.viewPreferences.reviewFilter = .all
        lecture.updatedAt = now
    }
}
