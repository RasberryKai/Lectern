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
                decks.append(StudyDeck(
                    module: module, lectures: try lectureListUnlocked(in: module).filter { !$0.isArchived },
                    memory: journal.state.memory, overrides: overrides, introducedToday: count
                ))
            }
            return StudyCatalog(decks: decks, preferences: preferences, introducedToday: introducedToday)
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
        answeringTime: TimeInterval, permitEarly: Bool, extraNewPerModule: Int, timeZone: TimeZone = .current
    ) throws -> StudyMemoryState {
        try locked {
            var journal = try StudyJournal(directory: moduleDirectory(entry.moduleID))
            if let saved = journal.state.grades[eventID] {
                guard saved.cardID == entry.id, saved.rating == rating, !journal.state.undoneGrades.contains(eventID) else {
                    throw LibraryError.invalid("This study grade conflicts with a recorded event.")
                }
                try journal.synchronize()
                return saved.after
            }
            try requireEditable(moduleUnlocked(entry.moduleID))
            let lecture = try readLecture(entry.moduleID, entry.lectureID)
            _ = try Self.studyCardIndex(entry, in: lecture, verdict: .good)
            let previous = journal.state.memory[entry.id]
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
            if previous == nil {
                try checkStudyIntroduction(moduleID: entry.moduleID, today: today,
                                           introducedHere: journal.state.introductions[today, default: 0],
                                           moduleLimit: configuration.newCardLimit, overallLimit: preferences.overallNewLimit,
                                           extra: extraNewPerModule)
            }
            try journal.append(StudyJournalEvent(
                id: eventID, cardID: entry.id, at: now, studyDay: today, source: .study,
                payload: .grade(rating: rating, answeringTime: answeringTime, configuration: configuration)
            ))
            // Applying a valid grade always stores the resulting state.
            return journal.state.grades[eventID]!.after
        }
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
            let now = Date()
            try journal.append(StudyJournalEvent(
                id: UUID(), cardID: grade.cardID, at: now, studyDay: StudyCatalog.studyDay(at: now, timeZone: .current),
                source: .undo, payload: .undo(gradeID: eventID)
            ))
        }
    }

    public func setStudyCardDisabled(_ entry: StudyCard, disabled: Bool) throws -> Card {
        try transaction(moduleID: entry.moduleID, lectureID: entry.lectureID) { lecture in
            let index = try Self.studyCardIndex(entry, in: lecture, verdict: disabled ? .good : .unreviewed)
            var expected = entry.card
            expected.verdict = lecture.cards[index].verdict
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
                                         cardIDs: batch.changes.keys.sorted { $0.uuidString < $1.uuidString })
                ))
            }
        }
    }

    private static func studyCardIndex(_ entry: StudyCard, in lecture: Lecture, verdict: CardVerdict) throws -> Int {
        guard !lecture.isArchived, let index = lecture.cards.firstIndex(where: { $0.id == entry.id }),
              !lecture.cards[index].isSuperseded, lecture.cards[index].verdict == verdict,
              lecture.cards[index].currentRevisionID == entry.card.currentRevisionID,
              lecture.cards[index].sourcePages == entry.card.sourcePages else {
            throw LibraryError.invalid("This card changed or is no longer eligible for study. Refresh the session.")
        }
        return index
    }

    private func checkStudyIntroduction(
        moduleID: UUID, today: String, introducedHere: Int, moduleLimit: Int, overallLimit: Int?, extra: Int
    ) throws {
        guard StudyCatalog.remainingNewCards(limit: moduleLimit, introduced: introducedHere, extra: extra) > 0 else {
            throw LibraryError.invalid("This module has reached today's new card limit.")
        }
        if let overallLimit {
            var total = introducedHere
            for other in try modulesUnlocked() where other.id != moduleID {
                let journal = try StudyJournal(directory: moduleDirectory(other.id))
                total += journal.state.introductions[today, default: 0]
            }
            guard StudyCatalog.remainingNewCards(limit: overallLimit, introduced: total, extra: extra) > 0 else {
                throw LibraryError.invalid("You have reached today's overall new card limit.")
            }
        }
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
            for lecture in try lectureListUnlocked(in: module) where !lecture.isArchived {
                for card in lecture.cards where card.verdict == .good && !card.isSuperseded {
                    guard let previous = journal.state.memory[card.id] else { continue }
                    let next = StudyScheduler.reschedule(previous, configuration: configuration, cardID: card.id)
                    if previous.due != next.due {
                        changes[card.id] = StudyRescheduleChange(before: previous, after: next)
                    }
                }
            }
            if !changes.isEmpty {
                batches[module.id] = StudyRescheduleBatch(configuration: configuration, changes: changes)
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
