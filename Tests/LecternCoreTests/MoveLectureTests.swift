import Foundation
import PDFKit
import Testing
@testable import LecternCore

struct MoveLectureTests {
    private func fixture() async throws -> (LibraryStore, Module, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lectern-move-\(UUID())")
        let store = LibraryStore(rootURL: root.appendingPathComponent("Library"))
        let module = try await store.createModule(Module(name: "Statistics", plannedLectureCount: 3))
        return (store, module, root)
    }

    private func files(in directory: URL) throws -> [String: Data] {
        let enumerator = try #require(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]))
        var result: [String: Data] = [:]
        for case let url as URL in enumerator where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            result[String(url.path.dropFirst(directory.path.count))] = try Data(contentsOf: url)
        }
        return result
    }

    @Test func movingPreservesAllContentAndFilesAcrossReloadAndBackup() async throws {
        let (store, module, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Lecture Five.pdf")
        let pdf = PDFDocument(); pdf.insert(PDFPage(), at: 0)
        #expect(pdf.write(to: source))
        let imported = try await store.importPDF(from: source, moduleID: module.id, slot: 1)
        let job = Job(kind: .ask, pages: [1])
        _ = try await store.updateLecture(moduleID: module.id, lectureID: imported.id) {
            $0.slides[0].note = "Keep this note"
            var card = Card(sourcePages: [1], front: "Question", back: "Answer", verdict: .good)
            card.exported = ExportMark(revisionID: card.currentRevisionID!)
            $0.cards = [card]
            $0.currentChat = LectureChat(messages: [ChatMessage(role: .user, text: "Keep this chat")], draft: "Unsent")
            $0.archivedChats = [LectureChat(title: "Earlier chat")]
            $0.learningPoints = [LearningPoint(text: "Keep this point", pages: [1])]
            $0.jobs = [job]
            $0.progressOverride = .toReview
            $0.viewPreferences = ViewPreferences(focusedPageIndex: 0, selectedCardID: card.id, mode: .review)
        }
        let lecture = try await store.loadLecture(moduleID: module.id, lectureID: imported.id)
        let second = try await store.createLecture(Lecture(moduleID: module.id, name: "Second"), slot: 2)
        let sixth = try await store.createLecture(Lecture(moduleID: module.id, name: "Sixth"), slot: 6)
        try await store.saveLegacyProvenance(Data("{\"original\":true}".utf8), moduleID: module.id, lectureID: lecture.id)
        let logs = store.jobDirectory(moduleID: module.id, lectureID: lecture.id, jobID: job.id)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try Data("Immutable job snapshot".utf8).write(to: logs.appendingPathComponent("snapshot.txt"))
        let directory = store.sourceURL(moduleID: module.id, lectureID: lecture.id).deletingLastPathComponent()
        let before = try files(in: directory)
        let ankiBefore = try AnkiExporter.export(lecture: lecture, moduleName: module.name, changedOnly: false)
        #expect(ankiBefore.entries.count == 1)

        _ = try await store.moveLecture(moduleID: module.id, lectureID: lecture.id, toSlot: 5)

        let reopened = LibraryStore(rootURL: store.rootURL)
        let moved = try await reopened.loadLecture(moduleID: module.id, lectureID: lecture.id)
        #expect(moved == lecture)
        #expect(try files(in: directory) == before)
        #expect(try AnkiExporter.export(lecture: moved, moduleName: module.name, changedOnly: false).entries == ankiBefore.entries)
        let progress = try #require(await reopened.dashboard().modules.first)
        #expect(progress.slots[0].lectureID == nil)
        #expect(progress.slots[0].status == .notImported)
        #expect(progress.slots[4].lectureID == lecture.id)
        #expect(progress.slots[4].statusOverride == .toReview)
        #expect(progress.module.lectureIDs == [second.id, lecture.id, sixth.id])
        #expect(try await reopened.loadModule(moduleID: module.id).nextImportSlot == 1)
        let backup = root.appendingPathComponent("backup.json")
        try await reopened.exportModuleBackup(moduleID: module.id, to: backup)
        let restored = LibraryStore(rootURL: root.appendingPathComponent("Restored"))
        _ = try await restored.restoreModuleBackup(from: backup)
        #expect(try await restored.dashboard().modules[0].slots == progress.slots)
        #expect(try await restored.loadLecture(moduleID: module.id, lectureID: lecture.id) == lecture)
    }

    @Test func movesBackwardExpandsPlanAndKeepsLectureStatus() async throws {
        let (store, module, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let lecture = try await store.createLecture(Lecture(moduleID: module.id, name: "Fifth"), slot: 1)
        let persisted = try await store.loadLecture(moduleID: module.id, lectureID: lecture.id)
        try await store.setEmptySlotStatus(.done, slotID: .init(moduleID: module.id, index: 3))
        _ = try await store.moveLecture(moduleID: module.id, lectureID: lecture.id, toSlot: 5)
        #expect(try await store.loadModule(moduleID: module.id).plannedLectureCount == 5)
        _ = try await store.moveLecture(moduleID: module.id, lectureID: lecture.id, toSlot: 3)
        let progress = try #require(await store.dashboard().modules.first)
        #expect(progress.module.plannedLectureCount == 5)
        #expect(progress.slots[2].lectureID == lecture.id)
        #expect(progress.slots[2].statusOverride == nil)
        #expect(progress.module.slotStatusOverrides.isEmpty)
        #expect(progress.slots[4].lectureID == nil)
        #expect(try await store.loadLecture(moduleID: module.id, lectureID: lecture.id) == persisted)
        let before = try await store.loadModule(moduleID: module.id)
        #expect(try await store.moveLecture(moduleID: module.id, lectureID: lecture.id, toSlot: 3) == before)
    }

    @Test func invalidOccupiedAndArchivedMovesLeaveModuleUnchanged() async throws {
        let (store, module, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let lecture = try await store.createLecture(Lecture(moduleID: module.id, name: "First"), slot: 1)
        _ = try await store.createLecture(Lecture(moduleID: module.id, name: "Second"), slot: 2)
        let before = try await store.loadModule(moduleID: module.id)
        for slot in [0, -1, 2, Module.maximumPlannedLectureCount + 1] {
            await #expect(throws: LibraryError.self) { try await store.moveLecture(moduleID: module.id, lectureID: lecture.id, toSlot: slot) }
            #expect(try await store.loadModule(moduleID: module.id) == before)
        }
        await #expect(throws: LibraryError.self) { try await store.moveLecture(moduleID: module.id, lectureID: UUID(), toSlot: 3) }
        _ = try await store.setModuleArchived(moduleID: module.id, archived: true)
        let archived = try await store.loadModule(moduleID: module.id)
        await #expect(throws: LibraryError.self) { try await store.moveLecture(moduleID: module.id, lectureID: lecture.id, toSlot: 3) }
        #expect(try await store.loadModule(moduleID: module.id) == archived)
        _ = try await store.setModuleArchived(moduleID: module.id, archived: false)
        try await store.setLectureArchived(moduleID: module.id, lectureID: lecture.id, archived: true)
        let archivedLecture = try await store.loadModule(moduleID: module.id)
        await #expect(throws: LibraryError.self) { try await store.moveLecture(moduleID: module.id, lectureID: lecture.id, toSlot: 3) }
        #expect(try await store.loadModule(moduleID: module.id) == archivedLecture)
    }

    @Test func competingMovesCannotOverwriteAnotherLecture() async throws {
        let (first, module, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let second = LibraryStore(rootURL: first.rootURL)
        let a = try await first.createLecture(Lecture(moduleID: module.id, name: "A"), slot: 1)
        let b = try await first.createLecture(Lecture(moduleID: module.id, name: "B"), slot: 2)
        let savedA = try await first.loadLecture(moduleID: module.id, lectureID: a.id)
        let savedB = try await first.loadLecture(moduleID: module.id, lectureID: b.id)
        let successes = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for (store, lecture) in [(first, a), (second, b)] {
                group.addTask { (try? await store.moveLecture(moduleID: module.id, lectureID: lecture.id, toSlot: 5)) != nil }
            }
            var count = 0
            for await success in group { if success { count += 1 } }
            return count
        }
        #expect(successes == 1)
        let saved = try await first.loadModule(moduleID: module.id)
        #expect(saved.lectureSlots.values.filter { $0 == 5 }.count == 1)
        #expect(Set(saved.lectureIDs) == [a.id, b.id])
        #expect(try await first.loadLecture(moduleID: module.id, lectureID: a.id) == savedA)
        #expect(try await first.loadLecture(moduleID: module.id, lectureID: b.id) == savedB)
    }
}
