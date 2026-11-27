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
        if let pdfParts {
            var remaining = pageCount
            for part in pdfParts {
                guard part.pageCount > 0, part.pageCount <= remaining else { throw LectureError.invalidMetadata("PDF parts do not match the slide count") }
                remaining -= part.pageCount
            }
            guard remaining == 0, Set(pdfParts.map(\.id)).count == pdfParts.count else {
                throw LectureError.invalidMetadata("PDF parts do not match the slide count")
            }
        }
        for ids in [cards.map(\.id), jobs.map(\.id), threads.map(\.id)] {
            var seen = Set<UUID>()
            for id in ids where !seen.insert(id).inserted { throw LectureError.duplicateID(id) }
        }
        guard Set(threads.map(\.anchorPage)).count == threads.count, threads.allSatisfy({
            $0.anchorPage == 0 || ((1...max(1, pageCount)).contains($0.anchorPage) && pageCount > 0)
        }) else { throw LectureError.invalidMetadata("Threads must have unique valid anchor pages") }
        if let focused = viewPreferences.focusedPageIndex, !(0..<pageCount).contains(focused) { throw LectureError.invalidMetadata("Invalid focused page") }
        if let selected = viewPreferences.selectedCardID, !cards.contains(where: { $0.id == selected }) { throw LectureError.missingCard(selected) }
        guard jobs.allSatisfy({ job in
            // Finished jobs can outlive every slide in their original generation scope.
            let historical = job.state != .running && pdfLayoutRevision != nil && job.pdfLayoutRevision != pdfLayoutRevision
            return (job.kind != .generate || !job.pages.isEmpty || historical)
                && job.pages.allSatisfy { $0 > 0 && $0 <= pageCount }
        }) else { throw LectureError.invalidMetadata("Job pages must belong to the document") }
        guard cards.allSatisfy({ !$0.history.isEmpty }) else { throw LectureError.invalidMetadata("Card history cannot be empty") }
        for card in cards where card.verdict == .good {
            guard issues(for: card).isEmpty else { throw LectureError.invalidApproval(card.id) }
        }
        return self
    }
    func issues(for card: Card) -> [CardIssue] {
        var result = card.issue.map { [$0] } ?? []
        if (card.solve != nil || card.requiresSourcePages || card.origin != .manual && pageCount > 0) && card.sourcePages.isEmpty { result.append(CardIssue(kind: .invalidSource, message: "This card needs a source page.")) }
        if card.front.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || card.back.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result.append(CardIssue(kind: .emptySide, message: "Both sides need text.")) }
        if card.sourcePages.contains(where: { $0 < 1 || $0 > pageCount }) { result.append(CardIssue(kind: .invalidSource, message: "Source pages must belong to the document and job scope.")) }
        if let allowed = card.allowedSourcePages, card.sourcePages.contains(where: { !allowed.contains($0) }), !result.contains(where: { $0.kind == .invalidSource }) { result.append(CardIssue(kind: .invalidSource, message: "Source pages are outside the job scope.")) }
        if let solve = card.solve {
            if solve.draft.validated == nil || Set(solve.cases.map(\.id)).count != solve.cases.count {
                result.append(CardIssue(kind: .invalidSolve, message: "Ask the AI sidebar to revise the exercise with a complete answer key."))
            }
        } else if ![card.front, card.back].allSatisfy({ (try? FlashcardMathFormatter.formatForAnki($0, interpretations: card.mathInterpretations)) != nil }) { result.append(CardIssue(kind: .unresolvedMath, message: "Choose how to interpret ambiguous or unbalanced math.")) }
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
            case .unreviewed: return card.verdict.isAwaitingReview
            case .good: return card.verdict == .good
            case .bad: return card.verdict == .bad
            case .needsAdjustment: return card.verdict.isAwaitingReview
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
    case applyChatEdits(jobID: UUID, edits: [ChatCardEdit], confirmsFlipReplacement: Bool = false)
    case undoChatEdits(jobID: UUID)
    case upsertThread(SlideThread)
    case setSlideSelection(pageIndex: Int, Bool)
    case updateNote(pageIndex: Int, String)
    case setViewPreferences(ViewPreferences)
    case markExported(cardIDs: [UUID])
    case markExportEntries([ExportEntry])
    /// Turns a chat learning point's draft into a card, or applies it to the card it improves.
    case acceptLearningPointDraft(pointID: UUID, front: String, back: String)
    /// The student doesn't want a card for this point; it no longer feeds Generate either.
    case skipLearningPoint(pointID: UUID)
    case resolveCardSuggestion(chatID: UUID, messageID: UUID, apply: Bool)
    case resolveChatDeletions(chatID: UUID, messageID: UUID, cardIDs: Set<UUID>, delete: Bool)
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
    @discardableResult
    private static func appendRevision(_ card: inout Card, author: RevisionAuthor, reason: String?, now: Date) -> UUID {
        var revision = CardRevision(front: card.front, back: card.back, author: author, reason: reason, at: now)
        revision.solve = card.solve?.draft
        card.history.append(revision)
        return revision.id
    }
    private static func setVerdict(_ verdict: CardVerdict, at index: Int, in lecture: inout Lecture) throws {
        if verdict == .good {
            guard lecture.issues(for: lecture.cards[index]).isEmpty else { throw LectureError.invalidApproval(lecture.cards[index].id) }
            if lecture.cards[index].solve != nil { lecture.cards[index].hasApprovedSolve = true }
        }
        lecture.cards[index].verdict = verdict
    }
    private static func apply(_ lecture: inout Lecture, action: LectureAction, now: Date) throws {
        switch action {
        case .setVerdict(let id, let verdict):
            let i = try index(id, in: lecture)
            try setVerdict(verdict, at: i, in: &lecture)
        case .commitEdit(let id, let front, let back, let pages):
            let i = try index(id, in: lecture)
            if lecture.cards[i].solve != nil, front != lecture.cards[i].front || back != lecture.cards[i].back {
                throw LectureError.invalidMetadata("Use the AI sidebar to revise the exercise and its answer key together.")
            }
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
            guard (lecture.cards[i].solve == nil) == (original.solve == nil) else {
                throw LectureError.invalidMetadata("Request a new proposal to change the card type.")
            }
            if lecture.cards[i].front != original.front || lecture.cards[i].back != original.back { lecture.cards[i].mathInterpretations = [:] }
            lecture.cards[i].front = original.front; lecture.cards[i].back = original.back; lecture.cards[i].verdict = .unreviewed
            try lecture.cards[i].setSolveDraft(original.solve)
            appendRevision(&lecture.cards[i], author: .user, reason: "Restore original", now: now)
        case .discardProposal(let id): lecture.cards[try index(id, in: lecture)].proposal = nil
        case .acceptProposal(let id, let approve):
            let i = try index(id, in: lecture)
            guard let proposal = lecture.cards[i].proposal, proposal.state == .ready, (1...3).contains(proposal.cards.count) else { throw LectureError.invalidProposal(id) }
            if lecture.cards[i].solve != nil || proposal.cards.contains(where: { $0.solve != nil }) {
                guard proposal.baseRevisionID == lecture.cards[i].currentRevisionID else { throw LectureError.invalidProposal(id) }
            }
            if proposal.cards.count > 1 {
                guard lecture.cards[i].solve == nil else { throw LectureError.invalidProposal(id) }
                let rootPointID = lecture.cards[i].learningPointID ?? lecture.learningPoints.first(where: { ($0.cardIDs ?? []).contains(id) })?.id
                let children = try proposal.cards.map { draft -> Card in
                    var child = Card(sourcePages: draft.sourcePages, front: draft.front, back: draft.back, flag: draft.flag,
                                     history: [CardRevision(front: draft.front, back: draft.back, author: .ai, reason: proposal.rationale, at: now)],
                                     origin: .splitFrom(cardID: id), allowedSourcePages: proposal.allowedSourcePages ?? lecture.cards[i].allowedSourcePages)
                    child.learningPointID = rootPointID
                    try child.setSolveDraft(draft.solve)
                    child.history = []
                    appendRevision(&child, author: .ai, reason: proposal.rationale, now: now)
                    return child
                }
                let keepsOriginal = proposal.cards.contains { $0.solve != nil }
                if !keepsOriginal { lecture.cards[i].supersededBy = children.map(\.id) }
                lecture.cards[i].proposal = nil
                lecture.cards.append(contentsOf: children)
                if let rootPointID, let p = lecture.learningPoints.firstIndex(where: { $0.id == rootPointID }) {
                    var seen = Set<UUID>()
                    let activeLinks = (lecture.learningPoints[p].cardIDs ?? []).filter { linkedID in
                        (keepsOriginal || linkedID != id) && lecture.cards.contains { $0.id == linkedID && !$0.isSuperseded }
                    }
                    lecture.learningPoints[p].cardIDs = (activeLinks + children.map(\.id)).filter { seen.insert($0).inserted }
                }
            } else {
                let draft = proposal.cards[0]
                let originalIsSolve = lecture.cards[i].solve != nil
                if originalIsSolve != (draft.solve != nil),
                   !originalIsSolve || lecture.cards[i].hasApprovedSolve == true || lecture.cards[i].verdict == .good {
                    var sibling = Card(sourcePages: draft.sourcePages, front: draft.front, back: draft.back, flag: draft.flag,
                                       history: [], origin: .splitFrom(cardID: id),
                                       allowedSourcePages: proposal.allowedSourcePages ?? lecture.cards[i].allowedSourcePages)
                    try sibling.setSolveDraft(draft.solve)
                    appendRevision(&sibling, author: .ai, reason: proposal.rationale, now: now)
                    lecture.cards[i].proposal = nil
                    lecture.cards.append(sibling)
                    let siblingIndex = lecture.cards.count - 1
                    if approve { try setVerdict(.good, at: siblingIndex, in: &lecture) }
                    return
                }
                if lecture.cards[i].front != draft.front || lecture.cards[i].back != draft.back { lecture.cards[i].mathInterpretations = [:] }
                lecture.cards[i].front = draft.front; lecture.cards[i].back = draft.back; lecture.cards[i].sourcePages = draft.sourcePages; lecture.cards[i].flag = draft.flag; lecture.cards[i].allowedSourcePages = proposal.allowedSourcePages ?? lecture.cards[i].allowedSourcePages; lecture.cards[i].proposal = nil; lecture.cards[i].verdict = .unreviewed
                if let issue = lecture.cards[i].issue, issue.kind == .importSyntax || issue.kind == .emptySide { lecture.cards[i].issue = nil }
                try lecture.cards[i].setSolveDraft(draft.solve)
                appendRevision(&lecture.cards[i], author: .ai, reason: proposal.rationale, now: now)
                if approve { try setVerdict(.good, at: i, in: &lecture) }
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
                let removedCardIDs = Set(lecture.cards.map(\.id))
                invalidateSuggestions(targeting: removedCardIDs, in: &lecture)
                lecture.cards.removeAll()
                lecture.skippedSlides.removeAll()
                lecture.viewPreferences.selectedCardID = nil
                // Chat points whose cards are gone wait in the drawer again unless this generation re-creates them.
                for p in lecture.learningPoints.indices where !(lecture.learningPoints[p].cardIDs ?? []).isEmpty {
                    lecture.learningPoints[p].cardIDs = nil
                    if lecture.learningPoints[p].draft != nil && lecture.learningPoints[p].included { lecture.learningPoints[p].reviewed = false }
                }
            }
            let generated = try drafts.map { draft in
                var card = Card(sourcePages: draft.sourcePages, front: draft.front, back: draft.back, flag: draft.flag, history: [CardRevision(front: draft.front, back: draft.back, author: .ai, reason: draft.learningPointID == nil ? nil : "From your chat", at: now)], origin: .generated(jobID: id), allowedSourcePages: pages)
                card.learningPointID = draft.learningPointID
                try card.setSolveDraft(draft.solve)
                if draft.solve != nil {
                    card.history = []
                    appendRevision(&card, author: .ai, reason: draft.learningPointID == nil ? nil : "From your chat", now: now)
                }
                return card
            }
            lecture.cards.append(contentsOf: generated)
            var generatedByPoint: [UUID: [UUID]] = [:]
            for card in generated {
                if let pointID = card.learningPointID { generatedByPoint[pointID, default: []].append(card.id) }
            }
            let activeCardIDs = Set(lecture.cards.filter { !$0.isSuperseded }.map(\.id))
            for (pointID, cardIDs) in generatedByPoint {
                guard let p = lecture.learningPoints.firstIndex(where: { $0.id == pointID }) else { continue }
                var seen = Set<UUID>()
                lecture.learningPoints[p].cardIDs = ((lecture.learningPoints[p].cardIDs ?? []).filter(activeCardIDs.contains) + cardIDs)
                    .filter { seen.insert($0).inserted }
                lecture.learningPoints[p].reviewed = true
            }
            lecture.skippedSlides.append(contentsOf: skipped); lecture.jobs[j].state = .succeeded; lecture.jobs[j].finishedAt = now; lecture.jobs[j].usage = usage
        case .landProposal(let id, let cards, let rationale, let usage):
            let j = try jobIndex(id, in: lecture)
            guard lecture.jobs[j].state == .running else { throw LectureError.jobNotRunning(id) }
            guard lecture.jobs[j].kind == .revise, (1...3).contains(cards.count) else { throw LectureError.invalidProposal(id) }
            guard let target = lecture.jobs[j].targetCardID, let base = lecture.jobs[j].baseRevisionID else { throw LectureError.invalidProposal(id) }
            let i = try index(target, in: lecture)
            lecture.cards[i].proposal = Proposal(jobID: id, baseRevisionID: base, cards: cards, rationale: rationale, allowedSourcePages: lecture.jobs[j].pages)
            lecture.jobs[j].state = .succeeded; lecture.jobs[j].finishedAt = now; lecture.jobs[j].usage = usage
        case .applyChatEdits(let id, let edits, let confirmsFlipReplacement):
            let j = try jobIndex(id, in: lecture)
            guard lecture.jobs[j].kind == .chat, lecture.jobs[j].state == .running else { throw LectureError.jobNotRunning(id) }
            guard Set(edits.map(\.cardID)).count == edits.count else { throw LectureError.invalidMetadata("Chat returned duplicate card edits.") }
            let hasReplacements = edits.contains(where: \.replacesFlipCard)
            if hasReplacements {
                guard confirmsFlipReplacement, lecture.jobs[j].chatEditDisposition == .proposed else {
                    throw LectureError.invalidMetadata("Confirm the solve-card replacement in chat first.")
                }
                guard lecture.jobs[j].pdfLayoutRevision == lecture.pdfLayoutRevision else { throw LectureError.staleSnapshot }
            }
            let allowed = lecture.jobs[j].chatCardVersions ?? []
            // Validate every edit against the same pre-edit lecture before mutating any card.
            var validatedEdits: [ChatCardEdit] = []
            for edit in edits {
                guard let version = allowed.first(where: { $0.cardID == edit.cardID && $0.revisionID == edit.baseRevisionID }) else {
                    throw LectureError.invalidMetadata("Chat tried to edit a card outside its selected context.")
                }
                let before = lecture.cards[try index(edit.cardID, in: lecture)]
                guard version.matches(before) else {
                    throw LectureError.invalidMetadata("A flashcard changed while chat was working. Your changes were kept; send the request again.")
                }
                if let caseEdits = edit.caseEdits {
                    guard let solve = before.solve, !caseEdits.isEmpty,
                          edit.baseRevisionID == before.currentRevisionID else {
                        throw LectureError.invalidMetadata("This solve card changed. Look up its current cases and ask the AI sidebar again.")
                    }
                    for caseEdit in caseEdits {
                        guard let current = solve.cases.first(where: { $0.id == caseEdit.caseID }) else {
                            throw LectureError.invalidMetadata("A solve case was removed after this proposal. Look up the current cases and ask the AI sidebar again.")
                        }
                        guard !current.retired else {
                            throw LectureError.invalidMetadata("A solve case was retired after this proposal. Look up an active case and ask the AI sidebar again.")
                        }
                        guard ChatSolveCaseEdit.contentHash(current.content) == caseEdit.baseContentHash else {
                            throw LectureError.invalidMetadata("A solve case changed after this proposal. Look up its current content and ask the AI sidebar again.")
                        }
                    }
                }
                guard let validated = edit.validated(for: before, allowsFlipReplacement: edit.replacesFlipCard) else {
                    throw LectureError.invalidMetadata("Chat returned an invalid card edit or solve-case answer key.")
                }
                validatedEdits.append(validated)
            }

            var candidate = lecture
            var undo: [ChatEditUndo] = []
            for edit in validatedEdits {
                let i = try index(edit.cardID, in: candidate)
                let before = candidate.cards[i]
                if let caseEdits = edit.caseEdits, var solve = before.solve {
                    var draft = solve.draft
                    var changed = false
                    for caseEdit in caseEdits {
                        guard let caseIndex = solve.cases.firstIndex(where: { $0.id == caseEdit.caseID }),
                              let content = caseEdit.content.checkedContent else { continue }
                        let original = solve.cases[caseIndex]
                        guard original.content != content else { continue }
                        let replacement = SolveCase(content: content)
                        solve.cases[caseIndex] = replacement
                        var retiredOriginal = original
                        retiredOriginal.retired = true
                        solve.cases.append(retiredOriginal)
                        if caseIndex == 0 {
                            draft.sample = content
                            candidate.cards[i].front = content.prompt
                            candidate.cards[i].back = content.explanation
                        }
                        changed = true
                    }
                    guard changed else { continue }
                    guard let checkedDraft = (draft.validated) else {
                        throw LectureError.invalidMetadata("The revised sample no longer forms a valid solve exercise.")
                    }
                    solve.draft = checkedDraft
                    candidate.cards[i].solve = solve
                } else {
                    guard before.front != edit.front || before.back != edit.back || before.solve?.draft != edit.solve else { continue }
                    candidate.cards[i].front = edit.front; candidate.cards[i].back = edit.back
                    try candidate.cards[i].setSolveDraft(edit.solve)
                    candidate.cards[i].mathInterpretations = [:]
                    if candidate.cards[i].verdict == .good || candidate.jobs[j].chatEdits != nil { candidate.cards[i].verdict = .unreviewed }
                }
                let reason = edit.replacesFlipCard ? "Replaced with a solve card in chat" : "Chat edit"
                let revisionID = appendRevision(&candidate.cards[i], author: .ai, reason: reason, now: now)
                if edit.replacesFlipCard {
                    candidate.cards[i].solveStudyScheduleID = revisionID
                    try setVerdict(.good, at: i, in: &candidate)
                }
                undo.append(ChatEditUndo(cardID: edit.cardID, appliedRevisionID: revisionID,
                    front: before.front, back: before.back, verdict: before.verdict, mathInterpretations: before.mathInterpretations,
                    appliedVerdict: candidate.cards[i].verdict, appliedMathInterpretations: candidate.cards[i].mathInterpretations,
                    solve: before.solve, appliedSolve: candidate.cards[i].solve,
                    priorSolveStudyScheduleID: before.solveStudyScheduleID, priorSolveApproval: before.hasApprovedSolve))
            }
            candidate.jobs[j].chatEditUndo = undo.isEmpty ? nil : undo
            lecture = candidate
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
            }
            var candidate = lecture
            let caseEditedCardIDs = Set(candidate.jobs[j].chatEdits?.filter { $0.caseEdits != nil && $0.solve == nil }.map(\.cardID) ?? [])
            for edit in edits {
                let i = try index(edit.cardID, in: candidate)
                if candidate.cards[i].studyScheduleID == edit.appliedRevisionID {
                    candidate.cards[i].solveStudyScheduleID = edit.priorSolveStudyScheduleID
                    candidate.cards[i].hasApprovedSolve = edit.priorSolveApproval
                }
                candidate.cards[i].front = edit.front; candidate.cards[i].back = edit.back
                candidate.cards[i].mathInterpretations = edit.mathInterpretations
                candidate.cards[i].solve = edit.solve
                if caseEditedCardIDs.contains(edit.cardID), var restored = candidate.cards[i].solve,
                   let applied = edit.appliedSolve {
                    let originalIDs = Set(restored.cases.map(\.id))
                    let retainedHistory = applied.cases.filter { !originalIDs.contains($0.id) }.map { changed -> SolveCase in
                        var historical = changed
                        historical.retired = true
                        return historical
                    }
                    restored.cases.append(contentsOf: retainedHistory)
                    candidate.cards[i].solve = restored
                }
                candidate.cards[i].verdict = edit.verdict
                if edit.verdict == .good && !candidate.issues(for: candidate.cards[i]).isEmpty { candidate.cards[i].verdict = .unreviewed }
                appendRevision(&candidate.cards[i], author: .user, reason: "Undo chat edit", now: now)
            }
            candidate.jobs[j].chatEditsUndoneAt = now
            lecture = candidate
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
                if let solveCaseID = entry.solveCaseID, lecture.cards[i].verifiedSolveExample?.id != solveCaseID { continue }
                lecture.cards[i].exported = ExportMark(revisionID: entry.revisionID, date: now)
            }
        case .acceptLearningPointDraft(let id, let front, let back):
            guard let p = lecture.learningPoints.firstIndex(where: { $0.id == id }), let draft = lecture.learningPoints[p].draft,
                  (lecture.learningPoints[p].cardIDs ?? []).isEmpty else { throw LectureError.invalidMetadata("This card draft is no longer available.") }
            let front = front.trimmingCharacters(in: .whitespacesAndNewlines), back = back.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !front.isEmpty, !back.isEmpty else { throw LectureError.invalidMetadata("Both sides need text.") }
            let point = lecture.learningPoints[p]
            let cardID: UUID
            if let target = draft.replacesCardID, let i = lecture.cards.firstIndex(where: { $0.id == target && !$0.isSuperseded && $0.solve == nil }) {
                if lecture.cards[i].front != front || lecture.cards[i].back != back { lecture.cards[i].mathInterpretations = [:] }
                lecture.cards[i].front = front; lecture.cards[i].back = back
                lecture.cards[i].sourcePages = Array(Set(lecture.cards[i].sourcePages + point.pages)).sorted()
                if let allowed = lecture.cards[i].allowedSourcePages { lecture.cards[i].allowedSourcePages = Array(Set(allowed + point.pages)).sorted() }
                lecture.cards[i].verdict = .unreviewed; lecture.cards[i].learningPointID = id
                appendRevision(&lecture.cards[i], author: .ai, reason: "From your chat", now: now)
                cardID = target
            } else {
                var card = Card(sourcePages: point.pages, front: front, back: back,
                                history: [CardRevision(front: front, back: back, author: .ai, reason: "From your chat", at: now)])
                card.learningPointID = id
                lecture.cards.append(card); cardID = card.id
            }
            lecture.learningPoints[p].cardIDs = [cardID]; lecture.learningPoints[p].reviewed = true
        case .skipLearningPoint(let id):
            guard let p = lecture.learningPoints.firstIndex(where: { $0.id == id }) else { return }
            lecture.learningPoints[p].included = false; lecture.learningPoints[p].reviewed = true
        case .resolveCardSuggestion(let chatID, let messageID, let apply):
            func resolve(_ chat: inout LectureChat) throws {
                guard let m = chat.messages.firstIndex(where: { $0.id == messageID }), var suggestion = chat.messages[m].suggestion, suggestion.state == .pending else {
                    throw LectureError.invalidMetadata("This suggestion is no longer available.")
                }
                defer { chat.messages[m].suggestion = suggestion }
                guard apply else { suggestion.state = .dismissed; return }
                if let target = suggestion.cardID {
                    let i = try index(target, in: lecture)
                    guard lecture.cards[i].solve == nil else {
                        throw LectureError.invalidMetadata("Use the AI sidebar to revise a solve exercise.")
                    }
                    guard !lecture.cards[i].isSuperseded, lecture.cards[i].currentRevisionID == suggestion.baseRevisionID else {
                        throw LectureError.invalidMetadata("This card changed after the suggestion was made. Dismiss it, or ask again.")
                    }
                    if lecture.cards[i].front != suggestion.front || lecture.cards[i].back != suggestion.back { lecture.cards[i].mathInterpretations = [:] }
                    lecture.cards[i].front = suggestion.front; lecture.cards[i].back = suggestion.back
                    lecture.cards[i].sourcePages = suggestion.sourcePages.isEmpty ? lecture.cards[i].sourcePages : suggestion.sourcePages
                    if let allowed = lecture.cards[i].allowedSourcePages { lecture.cards[i].allowedSourcePages = Array(Set(allowed + lecture.cards[i].sourcePages)).sorted() }
                    lecture.cards[i].verdict = .unreviewed
                    appendRevision(&lecture.cards[i], author: .ai, reason: "Suggested in Review chat", now: now)
                } else {
                    let card = Card(sourcePages: suggestion.sourcePages, front: suggestion.front, back: suggestion.back,
                                    history: [CardRevision(front: suggestion.front, back: suggestion.back, author: .ai, reason: "Suggested in Review chat", at: now)])
                    lecture.cards.append(card); suggestion.createdCardID = card.id
                }
                suggestion.state = .applied
            }
            if lecture.currentChat.id == chatID { var chat = lecture.currentChat; try resolve(&chat); lecture.currentChat = chat }
            else if let c = lecture.archivedChats.firstIndex(where: { $0.id == chatID }) { var chat = lecture.archivedChats[c]; try resolve(&chat); lecture.archivedChats[c] = chat }
            else { throw LectureError.invalidMetadata("This chat no longer exists.") }
        case .resolveChatDeletions(let chatID, let messageID, let cardIDs, let delete):
            guard lecture.currentChat.id == chatID,
                  let m = lecture.currentChat.messages.firstIndex(where: { $0.id == messageID && $0.role == .assistant }),
                  var requests = lecture.currentChat.messages[m].deletionRequests else {
                throw LectureError.invalidMetadata("This deletion request is no longer available.")
            }
            let selected = requests.indices.filter { cardIDs.contains(requests[$0].id) }
            guard !cardIDs.isEmpty, selected.count == cardIDs.count,
                  selected.allSatisfy({ requests[$0].state == .pending }) else {
                throw LectureError.invalidMetadata("The deletion request has changed. Review the remaining cards.")
            }
            if delete {
                let cardIndices = try selected.map { requestIndex in
                    let request = requests[requestIndex]
                    guard let i = lecture.cards.firstIndex(where: { $0.id == request.id }),
                          request.version.matches(lecture.cards[i]) else {
                        throw LectureError.invalidMetadata("A requested flashcard has changed or is gone. Keep it or ask again.")
                    }
                    return i
                }
                deleteCards(at: cardIndices, ids: cardIDs, in: &lecture)
            }
            for i in selected { requests[i].state = delete ? .deleted : .kept }
            lecture.currentChat.messages[m].deletionRequests = requests
            lecture.currentChat.updatedAt = now
        case .markExported(let ids):
            for id in ids {
                let i = try index(id, in: lecture)
                guard lecture.cards[i].verdict == .good, !lecture.cards[i].isSuperseded, lecture.issues(for: lecture.cards[i]).isEmpty, let revision = lecture.cards[i].currentRevisionID else { throw LectureError.invalidApproval(id) }
                lecture.cards[i].exported = ExportMark(revisionID: revision, date: now)
            }
        }
    }

    private static func deleteCards(at indices: [Int], ids: Set<UUID>, in lecture: inout Lecture) {
        for i in indices {
            // Keep the existing card history while removing it from the active deck.
            lecture.cards[i].supersededBy = []
            lecture.cards[i].proposal = nil
        }
        if let selected = lecture.viewPreferences.selectedCardID, ids.contains(selected) {
            lecture.viewPreferences.selectedCardID = nil
        }
        for i in lecture.learningPoints.indices {
            lecture.learningPoints[i].cardIDs?.removeAll(where: ids.contains)
        }
        invalidateSuggestions(targeting: ids, in: &lecture)
    }

    private static func invalidateSuggestions(targeting ids: Set<UUID>, in lecture: inout Lecture) {
        func invalidate(in chat: inout LectureChat) {
            for i in chat.messages.indices {
                guard var suggestion = chat.messages[i].suggestion, suggestion.state == .pending,
                      let target = suggestion.cardID, ids.contains(target) else { continue }
                suggestion.state = .dismissed
                chat.messages[i].suggestion = suggestion
            }
        }
        invalidate(in: &lecture.currentChat)
        for i in lecture.archivedChats.indices { invalidate(in: &lecture.archivedChats[i]) }
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
        if latest.pdfLayoutRevision != lecture.pdfLayoutRevision { undoStack.removeAll() }
        lecture = latest
    }
    public mutating func dispatch(_ action: LectureAction, now: Date = Date()) throws {
        let before = lecture
        try LectureReducer.reduce(&lecture, action: action, now: now)
        switch action {
        case .startJob, .updateJob, .landGeneration, .landProposal, .applyChatEdits, .undoChatEdits, .upsertThread, .markExported, .markExportEntries,
             .acceptLearningPointDraft, .skipLearningPoint, .resolveCardSuggestion, .resolveChatDeletions: return
        default: break
        }
        if before != lecture { undoStack.append(UndoEntry(before: before, after: lecture)); if undoStack.count > 50 { undoStack.removeFirst() } }
    }
    public mutating func undo(now: Date = Date()) {
        guard let entry = undoStack.popLast() else { return }
        for old in entry.before.cards {
            guard let changed = entry.after.cards.first(where: { $0.id == old.id }), old != changed, let i = lecture.cards.firstIndex(where: { $0.id == old.id }) else { continue }
            var current = lecture.cards[i]
            if (old.front != changed.front || old.back != changed.back || old.sourcePages != changed.sourcePages || old.solve?.draft != changed.solve?.draft)
                && current.front == changed.front && current.back == changed.back && current.sourcePages == changed.sourcePages
                && current.solve?.draft == changed.solve?.draft {
                if old.solve?.draft != changed.solve?.draft {
                    var previous = old.solve
                    let known = Set(previous?.cases.map(\.id) ?? [])
                    for var former in current.solve?.cases ?? [] where !known.contains(former.id) {
                        former.retired = true
                        previous?.cases.append(former)
                    }
                    current.solve = previous
                }
                current.front = old.front; current.back = old.back; current.sourcePages = old.sourcePages
                var revision = CardRevision(front: old.front, back: old.back, reason: "Undo", at: now)
                revision.solve = current.solve?.draft
                current.history.append(revision)
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
