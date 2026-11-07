import Foundation
import PDFKit
import Testing
@testable import LecternCore

struct PlannedSlotStatusTests {
    private func fixture() async throws -> (LibraryStore, Module, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lectern-slot-status-\(UUID())")
        let store = LibraryStore(rootURL: root.appendingPathComponent("Library"))
        let module = try await store.createModule(Module(name: "Statistics", plannedLectureCount: 3))
        return (store, module, root)
    }

    @Test func manualStatusesWithoutPDFPersistAndUpdateProgressAndReset() async throws {
        let (store, module, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = LectureSlot.ID(moduleID: module.id, index: 1)
        let second = LectureSlot.ID(moduleID: module.id, index: 2)
        let third = LectureSlot.ID(moduleID: module.id, index: 3)
        try await store.setEmptySlotStatus(.done, slotID: third)
        try await store.setEmptySlotStatus(.toReview, slotID: second)

        let reopened = LibraryStore(rootURL: store.rootURL)
        let dashboard = try await reopened.dashboard()
        let progress = try #require(dashboard.modules.first)
        #expect(progress.slots.map(\.status) == [.notImported, .toReview, .done])
        #expect(progress.slots.map(\.statusOverride) == [nil, .toReview, .done])
        #expect(progress.slots.allSatisfy { $0.lectureID == nil })
        #expect(try await reopened.lectures(in: module.id).isEmpty)
        #expect(dashboard.totals.doneLectureCount == 1)
        #expect(dashboard.totals.notImportedCount == 1)
        #expect(dashboard.totals.reviewCardCount == 0)
        #expect(progress.nextUp == [.importLecture(moduleID: module.id, slotID: first)])

        try await reopened.setEmptySlotStatus(.done, slotID: first)
        try await reopened.setEmptySlotStatus(.done, slotID: second)
        let complete = try #require(await reopened.dashboard().modules.first)
        #expect(complete.pace == .complete)
        #expect(complete.nextUp.isEmpty)
        try await reopened.setEmptySlotStatus(nil, slotID: second)
        let reset = try #require(await reopened.dashboard().modules.first)
        #expect(reset.slots[1].status == .notImported)
        #expect(reset.slots[1].statusOverride == nil)
        #expect(reset.totals.doneLectureCount == 2)
        #expect(reset.nextUp == [.importLecture(moduleID: module.id, slotID: second)])
    }

    @Test func importingPDFKeepsItsSlotStatusAndDoesNotAffectOtherSlots() async throws {
        let (store, module, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = LectureSlot.ID(moduleID: module.id, index: 1)
        try await store.setEmptySlotStatus(.done, slotID: first)
        try await store.setEmptySlotStatus(.toReview, slotID: .init(moduleID: module.id, index: 3))
        let pdf = PDFDocument()
        let page = PDFPage()
        page.setBounds(CGRect(x: 0, y: 0, width: 300, height: 400), for: .mediaBox)
        pdf.insert(page, at: 0)
        let source = root.appendingPathComponent("Lecture.pdf")
        #expect(pdf.write(to: source))

        let lecture = try await store.importPDF(from: source, moduleID: module.id)
        #expect(lecture.progressOverride == .done)
        #expect(try await store.loadLecture(moduleID: module.id, lectureID: lecture.id).progressOverride == .done)
        let loaded = try await store.loadModule(moduleID: module.id)
        #expect(loaded.slotStatusOverrides == [3: .toReview])
        #expect(try await store.dashboard().modules[0].slots.map(\.status) == [.done, .notImported, .toReview])
        await #expect(throws: LibraryError.self) { try await store.setEmptySlotStatus(.preparing, slotID: first) }

        _ = try await store.updateLecture(moduleID: module.id, lectureID: lecture.id) { $0.progressOverride = nil }
        #expect(try await store.dashboard().modules[0].slots[0].status == .preparing)
        let second = try await store.importPDF(from: source, moduleID: module.id)
        let third = try await store.importPDF(from: source, moduleID: module.id)
        #expect(second.progressOverride == nil)
        #expect(third.progressOverride == .toReview)
        #expect(try await store.loadModule(moduleID: module.id).slotStatusOverrides.isEmpty)
    }

    @Test func metadataEditsBackupsAndArchivePreserveStatusesAndRemovedSlotsStayRemoved() async throws {
        let (store, module, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let third = LectureSlot.ID(moduleID: module.id, index: 3)
        try await store.setEmptySlotStatus(.toExport, slotID: third)
        var stale = module
        stale.instructions = "Use examples."
        try await store.updateModule(stale)
        #expect(try await store.loadModule(moduleID: module.id).slotStatusOverrides == [3: .toExport])

        let backup = root.appendingPathComponent("module.json")
        try await store.exportModuleBackup(moduleID: module.id, to: backup)
        let restoredStore = LibraryStore(rootURL: root.appendingPathComponent("Restored"))
        _ = try await restoredStore.restoreModuleBackup(from: backup)
        #expect(try await restoredStore.dashboard().modules[0].slots[2].status == .toExport)

        _ = try await store.setModuleArchived(moduleID: module.id, archived: true)
        await #expect(throws: LibraryError.self) { try await store.setEmptySlotStatus(.done, slotID: third) }
        _ = try await store.setModuleArchived(moduleID: module.id, archived: false)
        #expect(try await store.dashboard().modules[0].slots[2].status == .toExport)
        _ = try await store.updateModuleSettings(moduleID: module.id, name: module.name, plannedLectureCount: 2, examDate: nil)
        _ = try await store.updateModuleSettings(moduleID: module.id, name: module.name, plannedLectureCount: 3, examDate: nil)
        #expect(try await store.dashboard().modules[0].slots[2].status == .notImported)
        for index in [0, 4] {
            await #expect(throws: LibraryError.self) { try await store.setEmptySlotStatus(.done, slotID: .init(moduleID: module.id, index: index)) }
        }
    }

    @Test func lectureArchiveAndRestoreKeepEmptyStatusesSeparateFromImportedLectures() async throws {
        let (store, module, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let lecture = try await store.createLecture(Lecture(moduleID: module.id, name: "Imported"))
        try await store.setEmptySlotStatus(.done, slotID: .init(moduleID: module.id, index: 3))
        try await store.setLectureArchived(moduleID: module.id, lectureID: lecture.id, archived: true)
        #expect(try await store.dashboard().modules[0].slots.map(\.status) == [.notImported, .done, .notImported])
        try await store.setLectureArchived(moduleID: module.id, lectureID: lecture.id, archived: false)
        #expect(try await store.dashboard().modules[0].slots.map(\.status) == [.preparing, .notImported, .done])
        #expect(try await store.loadLecture(moduleID: module.id, lectureID: lecture.id).progressOverride == nil)
    }
}
