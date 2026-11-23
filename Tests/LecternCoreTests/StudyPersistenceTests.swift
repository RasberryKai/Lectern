import Foundation
import Testing
@testable import LecternCore

struct StudyPersistenceTests {
    private let start = Date(timeIntervalSince1970: 1_767_312_000.125)
    private let utc = TimeZone(secondsFromGMT: 0)!

    @Test func interruptedSnapshotAndPartialJournalTailRecoverWithExactTimestamps() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(rootURL: root)
        let module = try await addDeck("Statistics", to: store)
        let entry = try await firstCard(in: module.id, store: store)
        let directory = store.moduleDirectory(module.id)
        let journalURL = directory.appendingPathComponent("reviews.jsonl")
        let snapshotURL = directory.appendingPathComponent("study.json")
        #expect(!FileManager.default.fileExists(atPath: journalURL.path))
        #expect(!FileManager.default.fileExists(atPath: snapshotURL.path))

        let goodID = UUID()
        let firstGood = try await grade(.good, entry, in: store, id: goodID)
        #expect(firstGood.due == start.addingTimeInterval(600))
        #expect(firstGood.lastReview == start)
        let olderSnapshot = try Data(contentsOf: snapshotURL)

        var current = try await firstCard(in: module.id, store: store)
        let missID = UUID()
        let missTime = firstGood.due.addingTimeInterval(0.25)
        let miss = try await grade(.again, current, in: store, id: missID, at: missTime)
        let complete = try Data(contentsOf: journalURL)
        try olderSnapshot.write(to: snapshotURL, options: .atomic)
        try (complete + Data("{\"schemaVe".utf8)).write(to: journalURL, options: .atomic)

        let reopened = LibraryStore(rootURL: root)
        current = try await firstCard(in: module.id, store: reopened)
        #expect(current.memory == miss)
        #expect(miss.lastReview == missTime)
        let duplicate = try await grade(.again, current, in: reopened, id: missID, at: missTime)
        #expect(duplicate == miss)
        #expect(try await reopened.studyCatalog(now: start, timeZone: utc).introducedToday == 1)

        try await reopened.undoStudyGrade(moduleID: module.id, eventID: missID)
        #expect(try await firstCard(in: module.id, store: reopened).memory == firstGood)
        try await reopened.undoStudyGrade(moduleID: module.id, eventID: goodID)
        try await reopened.undoStudyGrade(moduleID: module.id, eventID: goodID)
        let final = try await reopened.studyCatalog(now: start, timeZone: utc)
        #expect(final.introducedToday == 0)
        #expect(final.decks.first?.memory.isEmpty == true)
        #expect(try Data(contentsOf: journalURL).split(separator: 0x0a).count == 4)
        try FileManager.default.removeItem(at: snapshotURL)
        #expect(try await reopened.studyCatalog(now: start, timeZone: utc) == final)
    }

    @Test func twoActorsShareDailyCapsAndArchivingKeepsOriginalUsage() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = LibraryStore(rootURL: root)
        let second = LibraryStore(rootURL: root)
        var preferences = StudyPreferences()
        preferences.overallNewLimit = 1
        try await first.saveStudyPreferences(preferences)
        let left = try await addDeck("Accounting", to: first)
        let right = try await addDeck("Economics", to: first)
        let a = try await firstCard(in: left.id, store: first)
        let b = try await firstCard(in: right.id, store: second)
        async let firstGrade = try? grade(.good, a, in: first)
        async let secondGrade = try? grade(.good, b, in: second)
        let attempts = await [firstGrade, secondGrade]
        #expect(attempts.compactMap { $0 }.count == 1)
        let winner = attempts[0] != nil ? left.id : right.id
        _ = try await first.setModuleArchived(moduleID: winner, archived: true)
        let remaining = attempts[0] != nil ? b : a
        await #expect(throws: LibraryError.self) {
            try await grade(.good, remaining, in: second)
        }
        #expect(try await first.studyCatalog(now: start, timeZone: utc).introducedToday == 1)

        try await first.setStudyNewCardLimit(moduleID: remaining.moduleID, limit: 0)
        let tomorrow = start.addingTimeInterval(86_400)
        await #expect(throws: LibraryError.self) {
            try await grade(.good, remaining, in: second, at: tomorrow)
        }
        let cram = try await grade(.good, remaining, in: second, at: tomorrow, extra: 20)
        #expect(cram.reps == 1)
        #expect(try await first.studyCatalog(now: tomorrow, timeZone: utc).introducedToday == 1)
    }

    @Test func undoRejectsStaleGradesAndExplicitRescheduleReplaysFromJournal() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(rootURL: root)
        let module = try await addDeck("Economics", to: store)
        let entry = try await firstCard(in: module.id, store: store)
        let id = UUID()
        let first = try await grade(.good, entry, in: store, id: id)
        await #expect(throws: LibraryError.self) { try await grade(.again, entry, in: store) }
        let updated = try await firstCard(in: module.id, store: store)
        await #expect(throws: LibraryError.self) { try await grade(.again, updated, in: store) }

        var overrides = StudyOverrides()
        overrides.flipFirstCorrect = .repeatAfter(20)
        try await store.saveStudyOverrides(moduleID: module.id, overrides)
        let stalePreview = try await store.previewStudyReschedule()
        #expect(stalePreview.count == 1)
        #expect(try await firstCard(in: module.id, store: store).memory == first)

        overrides.flipFirstCorrect = .repeatAfter(30)
        try await store.saveStudyOverrides(moduleID: module.id, overrides)
        await #expect(throws: LibraryError.self) { try await store.applyStudyReschedule(stalePreview) }
        let preview = try await store.previewStudyReschedule(moduleID: module.id)
        try await store.applyStudyReschedule(preview)
        await #expect(throws: LibraryError.self) { try await store.undoStudyGrade(moduleID: module.id, eventID: id) }
        try FileManager.default.removeItem(at: store.moduleDirectory(module.id).appendingPathComponent("study.json"))
        let rebuilt = try await firstCard(in: module.id, store: store)
        #expect(rebuilt.memory?.due == start.addingTimeInterval(30 * 60))
        #expect(rebuilt.memory?.reps == first.reps)
        #expect(rebuilt.memory?.stability == first.stability)
        #expect(try await store.previewStudyReschedule(moduleID: module.id).count == 0)
    }

    @Test func editsDisablesAndModuleBackupKeepSchedules() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(rootURL: root.appendingPathComponent("live"))
        let module = try await addDeck("Accounting", to: store)
        let entry = try await firstCard(in: module.id, store: store)
        let first = try await grade(.good, entry, in: store)
        var current = try await firstCard(in: module.id, store: store)
        current.card = try await store.editStudyCardFront(current, front: "Reworded question")
        #expect(current.card.verdict == .good)
        #expect(current.card.currentRevisionID != entry.card.currentRevisionID)
        #expect(current.card.history.count == 2)
        #expect(try await store.setStudyCardDisabled(current, disabled: true).verdict == .unreviewed)
        let disabled = try await store.studyCatalog(now: start, timeZone: utc)
        #expect(disabled.decks.first?.approvedCards.isEmpty == true)
        #expect(disabled.decks.first?.memory[entry.id] == first)
        #expect(try await store.setStudyCardDisabled(current, disabled: false).verdict == .good)

        let backup = root.appendingPathComponent("module.json")
        try await store.setStudyNewCardLimit(moduleID: module.id, limit: 7)
        _ = try await store.moveLecture(moduleID: module.id, lectureID: entry.lectureID, toSlot: 2)
        try await store.exportModuleBackup(moduleID: module.id, to: backup)
        let restored = LibraryStore(rootURL: root.appendingPathComponent("restored"))
        _ = try await restored.restoreModuleBackup(from: backup)
        let deck = try #require(try await restored.studyCatalog(now: start, timeZone: utc).decks.first)
        #expect(deck.module.lectureSlots[entry.lectureID] == 2)
        #expect(deck.overrides.newCardLimit == 7)
        #expect(deck.introducedToday == 1)
        #expect(deck.approvedCards.first?.card.front == "Reworded question")
        #expect(deck.approvedCards.first?.memory == first)
    }

    private func addDeck(_ name: String, to store: LibraryStore) async throws -> Module {
        let module = try await store.createModule(name: name)
        let card = Card(front: "A question", back: "An answer", verdict: .good)
        _ = try await store.createLecture(Lecture(moduleID: module.id, name: "First lecture", cards: [card]))
        return module
    }

    private func firstCard(in moduleID: UUID, store: LibraryStore) async throws -> StudyCard {
        let catalog = try await store.studyCatalog(now: start, timeZone: utc)
        return try #require(catalog.decks.first(where: { $0.id == moduleID })?.approvedCards.first)
    }

    private func grade(
        _ rating: StudyRating, _ entry: StudyCard, in store: LibraryStore,
        id: UUID = UUID(), at date: Date? = nil, extra: Int = 0
    ) async throws -> StudyMemoryState {
        try await store.gradeStudyCard(entry, rating: rating, eventID: id, now: date ?? start,
                                       answeringTime: 2.5, permitEarly: false, extraNewPerModule: extra, timeZone: utc)
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("lectern-study-persistence-\(UUID())")
    }
}
