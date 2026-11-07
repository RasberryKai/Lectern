import Foundation
import CoreGraphics
import Testing
@testable import LecternCore

@Suite struct ModuleSettingsTests {
    private func fixture() async throws -> (LibraryStore, Module, Lecture, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lectern-settings-\(UUID())")
        let store = LibraryStore(rootURL: root.appendingPathComponent("Library"))
        let module = try await store.createModule(name: "Statistics")
        let card = Card(front: "Why?", back: "Because.", verdict: .good)
        let lecture = try await store.createLecture(Lecture(moduleID: module.id, name: "Lecture", cards: [card]))
        return (store, module, try await store.loadLecture(moduleID: module.id, lectureID: lecture.id), root)
    }

    @Test func oldModuleJSONDefaultsToImportedCountAndActive() throws {
        let ids = [UUID(), UUID()]
        let data = try JSONSerialization.data(withJSONObject: ["id": UUID().uuidString, "name": "Legacy", "instructions": "Keep", "lectureIDs": ids.map(\.uuidString)])
        let module = try LibraryStore.decoder().decode(Module.self, from: data)
        #expect(module.plannedLectureCount == 2)
        #expect(module.slotStatusOverrides.isEmpty)
        #expect(module.examDate == nil); #expect(!module.isArchived)
        #expect(module.lectureIDs == ids)
        let roundTrip = try LibraryStore.decoder().decode(Module.self, from: LibraryStore.encoder().encode(module))
        #expect(roundTrip == module)
    }

    @Test func examDateRejectsNormalizedInvalidDatesAndRoundTripsAsComponents() throws {
        #expect(throws: (any Error).self) { try ExamDate(year: 2026, month: 2, day: 29) }
        #expect(throws: (any Error).self) { try ExamDate(year: 2026, month: 4, day: 31) }
        #expect(throws: (any Error).self) { try ExamDate(year: 0, month: 12, day: 1) }
        let exam = try ExamDate(year: 2028, month: 2, day: 29)
        let data = try JSONEncoder().encode(exam)
        #expect(try JSONDecoder().decode(ExamDate.self, from: data) == exam)
        for zone in ["Europe/Berlin", "America/Los_Angeles", "Pacific/Auckland"] {
            let timeZone = try #require(TimeZone(identifier: zone))
            #expect(try ExamDate(date: exam.date(in: timeZone), timeZone: timeZone) == exam)
        }
        #expect(throws: (any Error).self) { try JSONDecoder().decode(ExamDate.self, from: Data(#"{"year":2026,"month":2,"day":30}"#.utf8)) }
    }

    @Test func settingsPreserveLatestInstructionsOrderAndPlanningGrowsOnImport() async throws {
        let (store, module, first, root) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let exam = try ExamDate(year: 2026, month: 12, day: 14)
        try await store.appendModuleInstruction(moduleID: module.id, text: "Interpretation first.")
        let updated = try await store.updateModuleSettings(moduleID: module.id, name: " Statistics II ", plannedLectureCount: 2, examDate: exam)
        #expect(updated.name == "Statistics II"); #expect(updated.instructions == "Interpretation first.")
        #expect(updated.lectureIDs == [first.id]); #expect(updated.examDate == exam)
        let second = try await store.createLecture(Lecture(moduleID: module.id, name: "Second"))
        #expect(try await store.loadModule(moduleID: module.id).plannedLectureCount == 2)
        await #expect(throws: LibraryError.self) {
            try await store.updateModuleSettings(moduleID: module.id, name: "Old settings", plannedLectureCount: 1, examDate: nil)
        }
        let third = try await store.createLecture(Lecture(moduleID: module.id, name: "Third"))
        let loaded = try await store.loadModule(moduleID: module.id)
        #expect(loaded.lectureIDs == [first.id, second.id, third.id]); #expect(loaded.plannedLectureCount == 3)
        #expect(loaded.examDate == exam)
        var staleOrder = module; staleOrder.lectureIDs = [third.id, second.id, first.id]
        try await store.updateModule(staleOrder)
        let reordered = try await store.loadModule(moduleID: module.id)
        #expect(reordered.plannedLectureCount == 3); #expect(reordered.examDate == exam)
        #expect(reordered.lectureIDs == staleOrder.lectureIDs)
        let cleared = try await store.updateModuleSettings(moduleID: module.id, name: loaded.name, plannedLectureCount: 3, examDate: nil)
        #expect(cleared.examDate == nil)
        await #expect(throws: LibraryError.self) { try await store.updateModuleSettings(moduleID: module.id, name: "  ", plannedLectureCount: 3, examDate: nil) }
        await #expect(throws: LibraryError.self) { try await store.updateModuleSettings(moduleID: module.id, name: "M", plannedLectureCount: -1, examDate: nil) }
        await #expect(throws: LibraryError.self) { try await store.updateModuleSettings(moduleID: module.id, name: "M", plannedLectureCount: Int.max, examDate: nil) }
    }

    @Test func archiveBlocksAllContentMutationsAndAIAndCanBeReversed() async throws {
        let (store, module, lecture, root) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try await store.setModuleArchived(moduleID: module.id, archived: true)
        let archived = try await store.loadModule(moduleID: module.id)
        #expect(archived.isArchived)
        #expect(try await store.dashboard().modules.isEmpty)
        #expect(try await store.dashboard().archivedModuleCount == 1)
        #expect(try await store.loadLecture(moduleID: module.id, lectureID: lecture.id) == lecture)
        await #expect(throws: LibraryError.self) { try await store.updateLecture(moduleID: module.id, lectureID: lecture.id) { $0.name = "Lost" } }
        await #expect(throws: LibraryError.self) { try await store.createLecture(Lecture(moduleID: module.id, name: "New")) }
        await #expect(throws: LibraryError.self) { try await store.updateModule(module) }
        await #expect(throws: LibraryError.self) { try await store.updateModuleSettings(moduleID: module.id, name: "Lost", plannedLectureCount: 2, examDate: nil) }
        await #expect(throws: LibraryError.self) { try await store.appendModuleInstruction(moduleID: module.id, text: "Lost") }
        await #expect(throws: LibraryError.self) { try await store.saveLegacyProvenance(Data(), moduleID: module.id, lectureID: lecture.id) }
        let provider = FakeAIProvider(responses: [])
        let runner = JobRunner(store: store, providers: [provider])
        await #expect(throws: LibraryError.self) { try await runner.generate(moduleID: module.id, lectureID: lecture.id) }
        await #expect(throws: LibraryError.self) { try await runner.revise(moduleID: module.id, lectureID: lecture.id, cardID: lecture.cards[0].id, feedback: "Edit") }
        await #expect(throws: LibraryError.self) { try await runner.ask(moduleID: module.id, lectureID: lecture.id, anchorPage: 1, question: "Why?") }
        await #expect(throws: LibraryError.self) { try await runner.distil(moduleID: module.id, lectureID: lecture.id, anchorPage: 1) }
        await #expect(throws: LibraryError.self) { try await runner.retry(moduleID: module.id, lectureID: lecture.id, jobID: UUID()) }
        #expect(await provider.requests.isEmpty)
        let again = try await store.setModuleArchived(moduleID: module.id, archived: true)
        #expect(again.archivedAt == archived.archivedAt)
        let active = try await store.setModuleArchived(moduleID: module.id, archived: false)
        #expect(!active.isArchived)
        _ = try await store.updateLecture(moduleID: module.id, lectureID: lecture.id) { $0.name = "Editable again" }
        #expect(try await store.dashboard().modules.count == 1)
    }

    @Test func runningJobsPreventArchiveWithoutCancellingOrDroppingWork() async throws {
        let (store, module, lecture, root) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let job = Job(kind: .revise, pages: [], targetCardID: lecture.cards[0].id)
        _ = try await store.updateLecture(moduleID: module.id, lectureID: lecture.id) { $0.jobs.append(job) }
        await #expect(throws: LibraryError.self) { try await store.setModuleArchived(moduleID: module.id, archived: true) }
        let jobs = try await store.loadLecture(moduleID: module.id, lectureID: lecture.id).jobs
        #expect(jobs.count == 1); #expect(jobs[0].id == job.id); #expect(jobs[0].state == .running)
        #expect(try await !store.loadModule(moduleID: module.id).isArchived)
        _ = try await store.updateLecture(moduleID: module.id, lectureID: lecture.id) { $0.jobs[0].state = .cancelled }
        #expect(try await store.setModuleArchived(moduleID: module.id, archived: true).isArchived)
    }

    @Test func archivedExportAndBackupsPreserveMetadataAndReadOnlyState() async throws {
        let (store, module, lecture, root) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let exam = try ExamDate(year: 2026, month: 12, day: 14)
        _ = try await store.updateModuleSettings(moduleID: module.id, name: "Planned", plannedLectureCount: 12, examDate: exam)
        _ = try await store.setModuleArchived(moduleID: module.id, archived: true)
        let service = LibraryService(store: store, runner: JobRunner(store: store, providers: []))
        let exported = try await service.exportAnki(moduleID: module.id, to: root.appendingPathComponent("anki.txt"))
        #expect(exported.entries.count == 1)
        let saved = try await store.loadLecture(moduleID: module.id, lectureID: lecture.id)
        #expect(saved.cards[0].exported?.revisionID == saved.cards[0].currentRevisionID)
        #expect(saved.cards[0].history == lecture.cards[0].history)
        let moduleBackup = root.appendingPathComponent("module.json")
        try await store.exportModuleBackup(moduleID: module.id, to: moduleBackup)
        let restored = LibraryStore(rootURL: root.appendingPathComponent("Restored"))
        let result = try await restored.restoreModuleBackup(from: moduleBackup)
        #expect(result.isArchived); #expect(result.examDate == exam); #expect(result.plannedLectureCount == 12)
        #expect(try await restored.dashboard().modules.isEmpty)
        #expect(try await restored.loadLecture(moduleID: module.id, lectureID: lecture.id).cards == saved.cards)
        await #expect(throws: LibraryError.self) { try await restored.appendModuleInstruction(moduleID: module.id, text: "No") }
        let singleBackup = root.appendingPathComponent("lecture.json")
        try await store.exportBackup(moduleID: module.id, lectureID: lecture.id, to: singleBackup)
        let singleRestored = LibraryStore(rootURL: root.appendingPathComponent("SingleRestored"))
        _ = try await singleRestored.restoreBackup(from: singleBackup)
        #expect(try await singleRestored.loadModule(moduleID: module.id).isArchived)
        await #expect(throws: LibraryError.self) { try await store.restoreBackup(from: singleBackup) }
        let existingArchived = LibraryStore(rootURL: root.appendingPathComponent("ExistingArchived"))
        _ = try await existingArchived.createModule(Module(id: module.id, name: "Archived destination", archivedAt: Date()))
        await #expect(throws: LibraryError.self) { try await existingArchived.restoreBackup(from: singleBackup) }
        #expect(try await existingArchived.lectures(in: module.id).isEmpty)
    }

    @Test func damagedArchivedBackupPublishesNothingAndIntactRetrySucceeds() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lectern-archived-restore-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let pdfURL = root.appendingPathComponent("input.pdf")
        var box = CGRect(x: 0, y: 0, width: 400, height: 300)
        let context = try #require(CGContext(pdfURL as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil); context.endPDFPage(); context.closePDF()
        let source = LibraryStore(rootURL: root.appendingPathComponent("Source"))
        let module = try await source.createModule(name: "Archived")
        let lecture = try await source.importPDF(from: pdfURL, moduleID: module.id)
        _ = try await source.setModuleArchived(moduleID: module.id, archived: true)
        let intact = root.appendingPathComponent("intact.json")
        try await source.exportBackup(moduleID: module.id, lectureID: lecture.id, to: intact)
        let target = LibraryStore(rootURL: root.appendingPathComponent("Target"))
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: intact)) as? [String: Any])
        object.removeValue(forKey: "sourcePDF")
        let damaged = root.appendingPathComponent("damaged.json")
        try JSONSerialization.data(withJSONObject: object).write(to: damaged)
        await #expect(throws: LibraryError.self) { try await target.restoreBackup(from: damaged) }
        #expect(try await target.modules().isEmpty)
        object["sourcePDF"] = Data("invalid PDF".utf8).base64EncodedString()
        try JSONSerialization.data(withJSONObject: object).write(to: damaged)
        await #expect(throws: LibraryError.self) { try await target.restoreBackup(from: damaged) }
        #expect(try await target.modules().isEmpty)
        let restored = try await target.restoreBackup(from: intact)
        #expect(restored.id == lecture.id)
        #expect(try await target.loadModule(moduleID: module.id).isArchived)
        #expect(FileManager.default.fileExists(atPath: target.sourceURL(moduleID: module.id, lectureID: lecture.id).path))
    }
}
