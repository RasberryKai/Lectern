import Foundation

extension LibraryStore {
    public func studyPreferences() throws -> StudyPreferences {
        try locked { try studyPreferencesUnlocked() }
    }

    public func studyOverrides(moduleID: UUID) throws -> StudyOverrides {
        try locked { try studyOverridesUnlocked(in: moduleID) }
    }

    public func studyCatalog(now: Date = Date(), timeZone: TimeZone = .current) throws -> StudyCatalog {
        try locked {
            let preferences = try studyPreferencesUnlocked()
            let today = StudyCatalog.studyDay(at: now, timeZone: timeZone)
            var decks: [StudyDeck] = []
            var introducedToday = 0
            for module in try modulesUnlocked() {
                let journal = try StudyJournal(directory: moduleDirectory(module.id))
                let count = journal.state.introductions[today, default: 0]
                introducedToday += count
                guard !module.isArchived else { continue }
                let overrides = try studyOverridesUnlocked(in: module.id)
                try overrides.applying(to: preferences.defaults).validated()
                let allLectures = try lectureListUnlocked(in: module)
                let lectures = allLectures.filter { !$0.isArchived }
                decks.append(StudyDeck(
                    module: module, lectures: lectures,
                    memory: Self.studyMemory(in: allLectures, journal: journal.state), overrides: overrides, introducedToday: count,
                    seenSolveCases: journal.state.seenSolveCases ?? [:]
                ))
            }
            return StudyCatalog(decks: decks, preferences: preferences, introducedToday: introducedToday)
        }
    }

    public func askFlashcard(moduleID: UUID, lectureID: UUID, sourcePage: Int?,
                             now: Date = Date(), timeZone: TimeZone = .current) throws -> StudyCard? {
        try locked {
            let module = try moduleUnlocked(moduleID)
            guard !module.isArchived else { return nil }
            let journal = try StudyJournal(directory: moduleDirectory(moduleID))
            let preferences = try studyPreferencesUnlocked()
            let overrides = try studyOverridesUnlocked(in: moduleID)
            let configuration = overrides.applying(to: preferences.defaults)
            try configuration.validated()
            let today = StudyCatalog.studyDay(at: now, timeZone: timeZone)
            let lectures = try lectureListUnlocked(in: module)
            let deck = StudyDeck(module: module, lectures: lectures,
                                 memory: Self.studyMemory(in: lectures, journal: journal.state), overrides: overrides,
                                 introducedToday: journal.state.introductions[today, default: 0])
            return try deck.askFlashcard(lectureID: lectureID, sourcePage: sourcePage, now: now, timeZone: timeZone) {
                try studyIntroductionBlockedReason(moduleID: moduleID, today: today, introducedHere: deck.introducedToday,
                                                   moduleLimit: configuration.newCardLimit,
                                                   overallLimit: preferences.overallNewLimit, extra: 0) == nil
            }
        }
    }

    public func saveStudyPreferences(_ preferences: StudyPreferences) throws {
        try locked {
            try preferences.validated()
            try write(preferences, to: rootURL.appendingPathComponent("study-preferences.json"))
        }
    }

    public func saveStudyOverrides(moduleID: UUID, _ overrides: StudyOverrides) throws {
        try locked {
            try requireEditable(moduleUnlocked(moduleID))
            try saveStudyOverridesUnlocked(moduleID: moduleID, overrides)
        }
    }

    public func setStudyNewCardLimit(moduleID: UUID, limit: Int) throws {
        try locked {
            try requireEditable(moduleUnlocked(moduleID))
            var overrides = try studyOverridesUnlocked(in: moduleID)
            overrides.newCardLimit = limit
            try saveStudyOverridesUnlocked(moduleID: moduleID, overrides)
        }
    }

    public func gradeStudyCard(
        _ entry: StudyCard, rating: StudyRating, eventID: UUID, now: Date,
        answeringTime: TimeInterval, permitEarly: Bool, extraNewPerModule: Int, timeZone: TimeZone = .current,
        solveResponse: StudySolveResponse? = nil
    ) throws -> StudyMemoryState {
        try locked {
            var journal = try StudyJournal(directory: moduleDirectory(entry.moduleID))
            if let saved = journal.state.grades[eventID] {
                guard saved.cardID == entry.id, saved.studyScheduleID == entry.card.studyScheduleID,
                      saved.rating == rating, saved.solveResponse == solveResponse,
                      !journal.state.undoneGrades.contains(eventID) else {
                    throw LibraryError.invalid("This study grade conflicts with a recorded event.")
                }
                try journal.synchronize()
                return saved.after
            }
            try requireEditable(moduleUnlocked(entry.moduleID))
            let lecture = try readLecture(entry.moduleID, entry.lectureID)
            let card = lecture.cards[try Self.studyCardIndex(entry, in: lecture, verdict: .good)]
            if let solve = card.solve {
                guard let solveResponse, let exercise = solve.activeCases.first(where: { $0.id == solveResponse.caseID })?.content.checkedContent,
                      !SolveChecker.check(exercise, answers: solveResponse.answers).hasInvalidInput else {
                    throw LibraryError.invalid("Check a valid solve response before rating this card.")
                }
            } else if solveResponse != nil {
                throw LibraryError.invalid("This card no longer contains the solve exercise.")
            }
            let previous = journal.state.memory(for: entry.id, studyScheduleID: entry.card.studyScheduleID)
            guard previous == entry.memory else {
                throw LibraryError.invalid("This card's schedule changed. Restart the session to use its latest schedule.")
            }
            guard permitEarly || previous.map({ $0.due <= now }) != false else {
                throw LibraryError.invalid("This card is not yet due.")
            }
            guard now.timeIntervalSinceReferenceDate.isFinite, answeringTime.isFinite, answeringTime >= 0,
                  extraNewPerModule >= 0 else { throw LibraryError.invalid("Invalid study timing or workload.") }
            let preferences = try studyPreferencesUnlocked()
            let configuration = try studyOverridesUnlocked(in: entry.moduleID).applying(to: preferences.defaults)
            let today = StudyCatalog.studyDay(at: now, timeZone: timeZone)
            if previous == nil, let reason = try studyIntroductionBlockedReason(
                moduleID: entry.moduleID, today: today, introducedHere: journal.state.introductions[today, default: 0],
                moduleLimit: configuration.newCardLimit, overallLimit: preferences.overallNewLimit, extra: extraNewPerModule
            ) {
                throw LibraryError.invalid(reason)
            }
            try journal.append(StudyJournalEvent(
                id: eventID, cardID: entry.id, studyScheduleID: entry.card.studyScheduleID,
                at: now, studyDay: today, source: .study,
                payload: .grade(rating: rating, answeringTime: answeringTime, configuration: configuration),
                solveResponse: solveResponse
            ))
            // Applying a valid grade always stores the resulting state.
            return journal.state.grades[eventID]!.after
        }
    }

    /// Presentation spends a generated case even when the learner leaves without a grade.
    public func presentSolveCase(_ entry: StudyCard, presentationID: UUID, now: Date = Date(),
                                 timeZone: TimeZone = .current) throws -> SolveCase? {
        try locked {
            try requireEditable(moduleUnlocked(entry.moduleID))
            let lecture = try readLecture(entry.moduleID, entry.lectureID)
            let card = lecture.cards[try Self.studyCardIndex(entry, in: lecture, verdict: .good)]
            guard let solve = card.solve else { return nil }
            var journal = try StudyJournal(directory: moduleDirectory(entry.moduleID))
            if let saved = journal.state.presentations?[presentationID] {
                guard saved.cardID == entry.id, saved.studyScheduleID == entry.card.studyScheduleID else {
                    throw LibraryError.invalid("This presentation ID belongs to another card or Study schedule.")
                }
                try journal.synchronize()
                return solve.activeCases.first { $0.id == saved.caseID && $0.content.checkedContent != nil }
            }
            guard journal.state.memory(for: entry.id, studyScheduleID: entry.card.studyScheduleID) == entry.memory else {
                throw LibraryError.invalid("This card's schedule changed. Refresh the session before studying it.")
            }
            let seen = journal.state.seenSolveCases?[entry.id] ?? []
            guard let exercise = solve.availableCases(excluding: seen).first else { return nil }
            try journal.append(StudyJournalEvent(
                id: presentationID, cardID: entry.id, studyScheduleID: entry.card.studyScheduleID,
                at: now, studyDay: StudyCatalog.studyDay(at: now, timeZone: timeZone),
                source: .presentation, payload: .present(caseID: exercise.id, reusable: solve.draft.reusesSample ? true : nil)
            ))
            return exercise
        }
    }

    public func retireSolveCase(_ entry: StudyCard, caseID: UUID) throws -> Card {
        try transaction(moduleID: entry.moduleID, lectureID: entry.lectureID) { lecture in
            let index = try Self.studyCardIndex(entry, in: lecture, verdict: .good)
            guard let caseIndex = lecture.cards[index].solve?.cases.firstIndex(where: { $0.id == caseID }) else {
                throw LibraryError.invalid("This solve case is no longer available.")
            }
            if lecture.cards[index].verifiedSolveExample?.id == caseID { lecture.cards[index].exported = nil }
            lecture.cards[index].solve?.cases[caseIndex].retired = true
            return lecture.cards[index]
        }.result
    }

    /// Recheck the stored revision, approval, and unseen count before spending on variants.
    public func solveRefillCandidate(_ entry: StudyCard) throws -> StudyCard? {
        try locked {
            let module = try moduleUnlocked(entry.moduleID)
            guard !module.isArchived else { return nil }
            let lecture = try readLecture(entry.moduleID, entry.lectureID)
            guard let index = try? Self.studyCardIndex(entry, in: lecture, verdict: .good) else { return nil }
            let card = lecture.cards[index]
            guard let draft = card.solve?.draft, !draft.reusesSample, draft.validated != nil else { return nil }
            let journal = try StudyJournal(directory: moduleDirectory(entry.moduleID))
            return StudyCard(moduleID: entry.moduleID, lectureID: entry.lectureID, lectureName: lecture.name,
                             moduleName: module.name, card: card,
                             memory: journal.state.memory(for: entry.id, studyScheduleID: card.studyScheduleID),
                             seenSolveCaseIDs: journal.state.seenSolveCases?[entry.id] ?? [])
        }
    }

    @discardableResult
    public func appendSolveCases(_ contents: [SolveCaseContent], to entry: StudyCard) throws -> Int {
        try transaction(moduleID: entry.moduleID, lectureID: entry.lectureID) { lecture in
            guard let index = try? Self.studyCardIndex(entry, in: lecture, verdict: .good),
                  var solve = lecture.cards[index].solve, !solve.draft.reusesSample else { return 0 }
            let added = solve.append(contents)
            lecture.cards[index].solve = solve
            return added
        }.result
    }

    public func undoStudyGrade(moduleID: UUID, eventID: UUID) throws {
        try locked {
            try requireEditable(moduleUnlocked(moduleID))
            var journal = try StudyJournal(directory: moduleDirectory(moduleID))
            if journal.state.undoneGrades.contains(eventID) {
                try journal.synchronize()
                return
            }
            guard let grade = journal.state.grades[eventID] else {
                throw LibraryError.invalid("This study grade is missing.")
            }
            let module = try moduleUnlocked(moduleID)
            var currentCard: Card?
            for lectureID in module.lectureIDs {
                if let card = try readLecture(moduleID, lectureID).cards.first(where: { $0.id == grade.cardID }) {
                    currentCard = card
                    break
                }
            }
            if let currentCard, currentCard.studyScheduleID != grade.studyScheduleID {
                throw LibraryError.invalid("This grade belongs to an older Study schedule and can no longer be undone.")
            }
            let now = Date()
            try journal.append(StudyJournalEvent(
                id: UUID(), cardID: grade.cardID, studyScheduleID: grade.studyScheduleID,
                at: now, studyDay: StudyCatalog.studyDay(at: now, timeZone: .current),
                source: .undo, payload: .undo(gradeID: eventID)
            ))
        }
    }

    public func setStudyCardDisabled(_ entry: StudyCard, disabled: Bool) throws -> Card {
        try transaction(moduleID: entry.moduleID, lectureID: entry.lectureID) { lecture in
            let index = try Self.studyCardIndex(entry, in: lecture, verdict: disabled ? .good : .unreviewed)
            var expected = entry.card
            expected.verdict = lecture.cards[index].verdict
            // Background refill and approval history do not edit the exercise.
            expected.solve = lecture.cards[index].solve
            expected.hasApprovedSolve = lecture.cards[index].hasApprovedSolve
            guard lecture.cards[index] == expected else {
                throw LibraryError.invalid("This card was edited. Study cannot change its review status.")
            }
            try LectureReducer.reduce(&lecture, action: .setVerdict(cardID: entry.id, disabled ? .unreviewed : .good))
            return lecture.cards[index]
        }.result
    }

    public func editStudyCardFront(_ entry: StudyCard, front: String) throws -> Card {
        try editStudyCard(entry, front: front, back: entry.card.back)
    }

    public func editStudyCard(_ entry: StudyCard, front: String, back: String) throws -> Card {
        try transaction(moduleID: entry.moduleID, lectureID: entry.lectureID) { lecture in
            let index = try Self.studyCardIndex(entry, in: lecture, verdict: .good)
            let old = lecture.cards[index]
            guard old.solve == nil else { throw LibraryError.invalid("Revise the solve exercise in Review.") }
            guard front != old.front || back != old.back else { return old }
            let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
            try LectureReducer.reduce(&lecture, action: .commitEdit(
                cardID: old.id, front: front, back: back, sourcePages: old.sourcePages
            ), now: now)
            // Keep math choices for spans that still occur on either side.
            let spans = Set([front, back].flatMap(FlashcardMathAnalyzer.analyze).map(\.source))
            lecture.cards[index].mathInterpretations = old.mathInterpretations.filter { spans.contains($0.key) }
            if let issue = lecture.issues(for: lecture.cards[index]).first {
                throw LibraryError.invalid(issue.message)
            }
            try LectureReducer.reduce(&lecture, action: .setVerdict(cardID: old.id, .good), now: now)
            return lecture.cards[index]
        }.result
    }

    public func previewStudyReschedule(moduleID: UUID? = nil) throws -> StudyReschedulePreview {
        try locked { try previewStudyRescheduleUnlocked(moduleID: moduleID) }
    }

    public func applyStudyReschedule(_ preview: StudyReschedulePreview) throws {
        try locked {
            guard preview == (try previewStudyRescheduleUnlocked(moduleID: preview.moduleID)) else {
                throw LibraryError.invalid("The schedule changed. Preview the new due dates again.")
            }
            let now = Date()
            let today = StudyCatalog.studyDay(at: now, timeZone: .current)
            for (moduleID, batch) in preview.batches.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
                var journal = try StudyJournal(directory: moduleDirectory(moduleID))
                // All due date changes for a module share one durable record.
                try journal.append(StudyJournalEvent(
                    id: UUID(), cardID: nil, at: now, studyDay: today, source: .reschedule,
                    payload: .reschedule(configuration: batch.configuration,
                                         cardIDs: batch.changes.keys.sorted { $0.uuidString < $1.uuidString },
                                         solveIDs: batch.solveIDs.isEmpty ? nil : batch.solveIDs,
                                         scheduleIDs: batch.scheduleIDs.isEmpty ? nil : batch.scheduleIDs)
                ))
            }
        }
    }

    private static func studyCardIndex(_ entry: StudyCard, in lecture: Lecture, verdict: CardVerdict) throws -> Int {
        guard !lecture.isArchived, let index = lecture.cards.firstIndex(where: { $0.id == entry.id }),
              !lecture.cards[index].isSuperseded, lecture.cards[index].verdict == verdict,
              lecture.cards[index].currentRevisionID == entry.card.currentRevisionID,
              lecture.cards[index].studyScheduleID == entry.card.studyScheduleID,
              lecture.cards[index].sourcePages == entry.card.sourcePages else {
            throw LibraryError.invalid("This card changed or is no longer eligible for study. Refresh the session.")
        }
        return index
    }

    private static func studyMemory(in lectures: [Lecture], journal: StudyJournalState) -> [UUID: StudyMemoryState] {
        var memory: [UUID: StudyMemoryState] = [:]
        for card in lectures.flatMap(\.cards) {
            if let state = journal.memory(for: card.id, studyScheduleID: card.studyScheduleID) {
                memory[card.id] = state
            }
        }
        return memory
    }

    private func studyIntroductionBlockedReason(
        moduleID: UUID, today: String, introducedHere: Int, moduleLimit: Int, overallLimit: Int?, extra: Int
    ) throws -> String? {
        guard StudyCatalog.remainingNewCards(limit: moduleLimit, introduced: introducedHere, extra: extra) > 0 else {
            return "This module has reached today's new card limit."
        }
        guard let overallLimit else { return nil }

        let overallLimitMessage = "You have reached today's overall new card limit."
        var remaining = StudyCatalog.remainingNewCards(limit: overallLimit, introduced: introducedHere, extra: extra)
        guard remaining > 0 else { return overallLimitMessage }
        for id in try moduleIDsUnlocked() where id != moduleID {
            // Overall usage includes archived modules and only needs their study journals.
            let journal = try StudyJournal(directory: moduleDirectory(id))
            remaining = StudyCatalog.remainingNewCards(limit: remaining, introduced: journal.state.introductions[today, default: 0], extra: 0)
            if remaining == 0 { return overallLimitMessage }
        }
        return nil
    }

    private func previewStudyRescheduleUnlocked(moduleID: UUID?) throws -> StudyReschedulePreview {
        let preferences = try studyPreferencesUnlocked()
        let modules: [Module]
        if let moduleID {
            let module = try moduleUnlocked(moduleID)
            try requireEditable(module)
            modules = [module]
        } else {
            modules = try modulesUnlocked().filter { !$0.isArchived }
        }
        var batches: [UUID: StudyRescheduleBatch] = [:]
        for module in modules {
            let journal = try StudyJournal(directory: moduleDirectory(module.id))
            let configuration = try studyOverridesUnlocked(in: module.id).applying(to: preferences.defaults)
            try configuration.validated()
            var changes: [UUID: StudyRescheduleChange] = [:]
            var solveIDs: Set<UUID> = []
            var scheduleIDs: [UUID: UUID] = [:]
            for lecture in try lectureListUnlocked(in: module) where !lecture.isArchived {
                for card in lecture.cards where card.verdict == .good && !card.isSuperseded {
                    guard let previous = journal.state.memory(for: card.id, studyScheduleID: card.studyScheduleID) else { continue }
                    let next = StudyScheduler.reschedule(previous, configuration: configuration, cardID: card.id,
                                                         isSolve: card.solve != nil)
                    if previous.due != next.due {
                        changes[card.id] = StudyRescheduleChange(before: previous, after: next)
                        if let id = card.studyScheduleID { scheduleIDs[card.id] = id }
                        if card.solve != nil { solveIDs.insert(card.id) }
                    }
                }
            }
            if !changes.isEmpty {
                batches[module.id] = StudyRescheduleBatch(configuration: configuration, changes: changes,
                                                          solveIDs: solveIDs, scheduleIDs: scheduleIDs)
            }
        }
        return StudyReschedulePreview(moduleID: moduleID, batches: batches)
    }

    private func studyPreferencesUnlocked() throws -> StudyPreferences {
        let preferences: StudyPreferences = try readStudyPreferences(rootURL.appendingPathComponent("study-preferences.json")) ?? StudyPreferences()
        try preferences.validated()
        return preferences
    }

    private func studyOverridesUnlocked(in moduleID: UUID) throws -> StudyOverrides {
        try readStudyPreferences(studyOverridesURL(in: moduleDirectory(moduleID))) ?? StudyOverrides()
    }

    private func saveStudyOverridesUnlocked(moduleID: UUID, _ overrides: StudyOverrides) throws {
        try overrides.applying(to: studyPreferencesUnlocked().defaults).validated()
        try write(overrides, to: studyOverridesURL(in: moduleDirectory(moduleID)))
    }

    func studyOverridesURL(in directory: URL) -> URL {
        directory.appendingPathComponent("study-overrides.json")
    }

    func readStudyPreferences<T: Decodable>(_ url: URL) throws -> T? {
        guard FileManager.default.fileExists(atPath: url.path) ||
                FileManager.default.fileExists(atPath: url.appendingPathExtension("bak").path) else { return nil }
        return try read(url)
    }
}
