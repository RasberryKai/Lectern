import Foundation
import Testing
@testable import LecternCore

struct HardeningTests {
    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lectern-hardening-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func explicitModuleOrderSurvivesListingAndReload() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(rootURL: root)
        var module = try await store.createModule(name: "Ordered")
        let first = try await store.createLecture(Lecture(moduleID: module.id, name: "Z", createdAt: Date(timeIntervalSince1970: 300)))
        let second = try await store.createLecture(Lecture(moduleID: module.id, name: "A", createdAt: Date(timeIntervalSince1970: 100)))
        let third = try await store.createLecture(Lecture(moduleID: module.id, name: "M", createdAt: Date(timeIntervalSince1970: 200)))
        let order = [third.id, first.id, second.id]
        module.lectureIDs = order
        try await store.updateModule(module)
        #expect(try await store.modules().first?.lectureIDs == order)
        #expect(try await store.lectures(in: module.id).map(\.id) == order)
        let reloaded = LibraryStore(rootURL: root)
        #expect(try await reloaded.modules().first?.lectureIDs == order)
        #expect(try await reloaded.lectures(in: module.id).map(\.id) == order)
        // Interrupted creation appends the orphan without sorting away the explicit prefix.
        module.lectureIDs = [third.id, first.id]
        try LibraryStore.encoder().encode(module).write(to: root.appendingPathComponent("Modules/\(module.id)/module.json"))
        #expect(try await reloaded.modules().first?.lectureIDs == order)
    }

    @Test(arguments: ["duplicateThreads", "duplicateJobs", "invalidFocus", "emptyHistory", "invalidApproval"])
    func invalidPrimaryMetadataRecoversValidBackup(kind: String) async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(rootURL: root)
        let module = try await store.createModule(name: "Validation")
        let lecture = try await store.createLecture(Lecture(moduleID: module.id, name: "Original", cards: [Card(front: "Q", back: "A")]))
        _ = try await store.updateLecture(moduleID: module.id, lectureID: lecture.id) { $0.name = "Newer" }
        let json = root.appendingPathComponent("Modules/\(module.id)/Lectures/\(lecture.id)/lecture.json")
        let backup = try Data(contentsOf: json.appendingPathExtension("bak"))
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: json)) as? [String: Any])
        switch kind {
        case "duplicateThreads":
            let thread = SlideThread(anchorPage: 1)
            let raw = try JSONSerialization.jsonObject(with: LibraryStore.encoder().encode(thread))
            object["threads"] = [raw, raw]
        case "duplicateJobs":
            let job = Job(kind: .revise, pages: [])
            let raw = try JSONSerialization.jsonObject(with: LibraryStore.encoder().encode(job))
            object["jobs"] = [raw, raw]
        case "invalidFocus":
            var preferences = try #require(object["viewPreferences"] as? [String: Any])
            preferences["focusedPageIndex"] = 99; object["viewPreferences"] = preferences
        case "emptyHistory":
            var cards = try #require(object["cards"] as? [[String: Any]])
            cards[0]["history"] = []; object["cards"] = cards
        case "invalidApproval":
            var cards = try #require(object["cards"] as? [[String: Any]])
            cards[0]["front"] = ""; cards[0]["verdict"] = "good"; object["cards"] = cards
        default: Issue.record("Unknown fixture")
        }
        try JSONSerialization.data(withJSONObject: object).write(to: json)
        let recovered = try await store.loadLecture(moduleID: module.id, lectureID: lecture.id)
        #expect(recovered.name == "Original")
        #expect(try recovered.validated() == recovered)
        #expect(try Data(contentsOf: json.appendingPathExtension("bak")) == backup)
        #expect(try Data(contentsOf: json) == backup)
        let siblings = try FileManager.default.contentsOfDirectory(atPath: json.deletingLastPathComponent().path)
        #expect(siblings.contains(where: { $0.hasPrefix("lecture.json.corrupt-") }))
    }

    @Test(arguments: ["duplicateThreads", "duplicateJobs"])
    func malformedPortableBackupIsRejectedBeforePublishing(kind: String) async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(rootURL: root.appendingPathComponent("original"))
        let module = try await store.createModule(name: "Backup validation")
        let lecture = try await store.createLecture(Lecture(moduleID: module.id, name: "Lecture"))
        let backup = root.appendingPathComponent("backup.json")
        try await store.exportBackup(moduleID: module.id, lectureID: lecture.id, to: backup)
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: backup)) as? [String: Any])
        var rawLecture = try #require(object["lecture"] as? [String: Any])
        if kind == "duplicateThreads" {
            let thread = try JSONSerialization.jsonObject(with: LibraryStore.encoder().encode(SlideThread(anchorPage: 1)))
            rawLecture["threads"] = [thread, thread]
        } else {
            let job = try JSONSerialization.jsonObject(with: LibraryStore.encoder().encode(Job(kind: .revise, pages: [])))
            rawLecture["jobs"] = [job, job]
        }
        object["lecture"] = rawLecture
        let damaged = try JSONSerialization.data(withJSONObject: object)
        try damaged.write(to: backup)
        let restored = LibraryStore(rootURL: root.appendingPathComponent("restored"))
        await #expect(throws: LectureError.self) { try await restored.restoreBackup(from: backup) }
        #expect(try await restored.modules().isEmpty)
        #expect(try Data(contentsOf: backup) == damaged)
    }

    @Test func exportJournalReplayCompletesPartialMarkingWithoutLosingLaterEdit() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(rootURL: root)
        let module = try await store.createModule(name: "Export")
        // A repeated card ID across lectures must still be scoped by lecture identity.
        let cardID = UUID()
        let first = try await store.createLecture(Lecture(moduleID: module.id, name: "First", cards: [Card(id: cardID, front: "Q1", back: "A1", verdict: .good)]))
        let second = try await store.createLecture(Lecture(moduleID: module.id, name: "Second", cards: [Card(id: cardID, front: "Q2", back: "A2", verdict: .good)]))
        let entries = try AnkiExporter.export(lectures: [first, second], moduleName: module.name).entries
        #expect(entries.count == 2)
        let at = Date(timeIntervalSince1970: 1000)
        _ = try await store.updateLecture(moduleID: module.id, lectureID: first.id) { lecture in
            try LectureReducer.reduce(&lecture, action: .markExportEntries([entries[0]]), now: at)
        }
        let edited = try await store.updateLecture(moduleID: module.id, lectureID: second.id) { lecture in
            try LectureReducer.reduce(&lecture, action: .commitEdit(cardID: cardID, front: "Edited after export snapshot", back: "A2", sourcePages: []))
        }
        let editedRevision = edited.cards[0].currentRevisionID
        let persistedEdit = try await store.loadLecture(moduleID: module.id, lectureID: second.id)
        struct Journal: Encodable { var schemaVersion = 1; var moduleID: UUID; var entries: [ExportEntry]; var at: Date }
        let journalURL = root.appendingPathComponent("Exports/pending.json")
        try FileManager.default.createDirectory(at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try LibraryStore.encoder().encode(Journal(moduleID: module.id, entries: entries, at: at)).write(to: journalURL)
        let restarted = LibraryStore(rootURL: root)
        try await restarted.recoverPendingExports()
        #expect(!FileManager.default.fileExists(atPath: journalURL.path))
        let markedFirst = try await restarted.loadLecture(moduleID: module.id, lectureID: first.id)
        let markedSecond = try await restarted.loadLecture(moduleID: module.id, lectureID: second.id)
        #expect(markedFirst.cards[0].exported == ExportMark(revisionID: entries[0].revisionID, date: at))
        #expect(!markedFirst.cards[0].changedSinceExport)
        #expect(markedSecond.cards[0].exported == ExportMark(revisionID: entries[1].revisionID, date: at))
        #expect(markedSecond.cards[0].front == "Edited after export snapshot")
        #expect(markedSecond.cards[0].currentRevisionID == editedRevision)
        #expect(markedSecond.cards[0].changedSinceExport)
        #expect(markedSecond.cards[0].verdict == .unreviewed)
        #expect(markedSecond.updatedAt >= persistedEdit.updatedAt)
        try await restarted.recoverPendingExports()
        #expect(try await restarted.loadLecture(moduleID: module.id, lectureID: first.id) == markedFirst)
        #expect(try await restarted.loadLecture(moduleID: module.id, lectureID: second.id) == markedSecond)
    }

    @Test func backupAndAnkiDestinationsCannotOverwriteManagedLibrary() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("Library")
        let store = LibraryStore(rootURL: library)
        let module = try await store.createModule(name: "Protected")
        let lecture = try await store.createLecture(Lecture(moduleID: module.id, name: "Lecture", cards: [Card(front: "Q", back: "A", verdict: .good)]))
        let metadata = library.appendingPathComponent("Modules/\(module.id)/Lectures/\(lecture.id)/lecture.json")
        let original = try Data(contentsOf: metadata)
        await #expect(throws: LibraryError.self) { try await store.exportBackup(moduleID: module.id, lectureID: lecture.id, to: metadata) }
        let service = LibraryService(store: store, runner: JobRunner(store: store, providers: []))
        await #expect(throws: LibraryError.self) { try await service.exportAnki(moduleID: module.id, to: metadata) }
        #expect(throws: LibraryError.self) { try store.assertExternalDestination(library) }
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: library)
        #expect(throws: LibraryError.self) { try store.assertExternalDestination(alias.appendingPathComponent("overwrite.txt")) }
        try store.assertExternalDestination(root.appendingPathComponent("Library-backup.json"))
        #expect(try Data(contentsOf: metadata) == original)
        #expect(try await store.loadLecture(moduleID: module.id, lectureID: lecture.id).cards[0].exported == nil)
    }

    @Test func legacyGoodAmbiguousMathIsRetainedForUsableReReview() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(rootURL: root.appendingPathComponent("Library"))
        let legacyCard = Flashcard(front: "Ambiguous $x", back: "Answer", verdict: .good, notes: "Old feedback", rawImportLine: "Ambiguous $x == Answer")
        let session = FlashcardSession(title: "Legacy", cards: [legacyCard], selectedCardID: legacyCard.id)
        let data = try SessionBackup.encode(session)
        let source = root.appendingPathComponent("reviewer-backup.json"); try data.write(to: source)
        let report = await LegacyImporter(store: store).importReviewer(from: source)
        #expect(report.failures.isEmpty); #expect(report.imported.count == 1)
        let module = try #require(try await store.modules().first)
        let lecture = try #require(try await store.lectures(in: module.id).first)
        let card = try #require(lecture.cards.first)
        #expect(card.id == legacyCard.id); #expect(card.front == legacyCard.front)
        #expect(card.verdict == .unreviewed); #expect(card.flag != nil)
        #expect(card.feedback == legacyCard.notes)
        #expect(lecture.viewPreferences.selectedCardID == card.id)
        #expect(try lecture.validated() == lecture)
        #expect(lecture.issues(for: card).contains(where: { $0.kind == .unresolvedMath }))
        let provenance = store.rootURL.appendingPathComponent("Modules/\(module.id)/Lectures/\(lecture.id)/legacy-provenance.json")
        #expect(try SessionBackup.decode(Data(contentsOf: provenance)).cards[0].verdict == .good)
        #expect(try Data(contentsOf: source) == data)
        let updated = try await store.updateLecture(moduleID: module.id, lectureID: lecture.id) { lecture in
            try LectureReducer.reduce(&lecture, action: .commitEdit(cardID: card.id, front: "Resolved question", back: "Answer", sourcePages: []))
            try LectureReducer.reduce(&lecture, action: .setVerdict(cardID: card.id, .good))
        }
        #expect(updated.cards[0].verdict == .good)
        #expect(try AnkiExporter.export(lecture: updated, moduleName: module.name).entries.count == 1)
    }
}
