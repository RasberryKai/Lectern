import Foundation
import PDFKit
import Testing
@testable import LecternCore

struct StorageTests {
    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lectern-storage-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    @Test func corruptPrimaryRecoversWithoutDestroyingBackup() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(rootURL: root)
        let module = try await store.createModule(name: "Economics")
        let lecture = try await store.createLecture(Lecture(moduleID: module.id, name: "Before", cards: [Card(front: "Q", back: "A")]))
        _ = try await store.updateLecture(moduleID: module.id, lectureID: lecture.id) { $0.name = "After" }
        let json = root.appendingPathComponent("Modules/\(module.id)/Lectures/\(lecture.id)/lecture.json")
        let backup = try Data(contentsOf: json.appendingPathExtension("bak"))
        try Data("broken".utf8).write(to: json)
        let recovered = try await store.loadLecture(moduleID: module.id, lectureID: lecture.id)
        #expect(recovered.name == "Before")
        #expect(try Data(contentsOf: json.appendingPathExtension("bak")) == backup)
        #expect(try Data(contentsOf: json) == backup)
    }
    @Test func unknownSchemaNeverRollsBackToOlderBackup() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(rootURL: root)
        let module = try await store.createModule(name: "Test")
        let lecture = try await store.createLecture(Lecture(moduleID: module.id, name: "Lecture"))
        _ = try await store.updateLecture(moduleID: module.id, lectureID: lecture.id) { $0.name = "Updated" }
        let json = root.appendingPathComponent("Modules/\(module.id)/Lectures/\(lecture.id)/lecture.json")
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: json)) as? [String: Any])
        object["schemaVersion"] = 99
        try JSONSerialization.data(withJSONObject: object).write(to: json)
        await #expect(throws: LibraryError.self) { try await store.loadLecture(moduleID: module.id, lectureID: lecture.id) }
        #expect((try JSONSerialization.jsonObject(with: Data(contentsOf: json)) as? [String: Any])?["schemaVersion"] as? Int == 99)
    }
    @Test func independentActorsCannotLoseConcurrentEdits() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let first = LibraryStore(rootURL: root); let second = LibraryStore(rootURL: root)
        let module = try await first.createModule(name: "Test")
        let lecture = try await first.createLecture(Lecture(moduleID: module.id, name: "Lecture"))
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<30 {
                group.addTask {
                    let store = index.isMultiple(of: 2) ? first : second
                    _ = try await store.updateLecture(moduleID: module.id, lectureID: lecture.id) { $0.cards.append(Card(front: "Q\(index)", back: "A")) }
                }
            }
            try await group.waitForAll()
        }
        #expect(try await first.loadLecture(moduleID: module.id, lectureID: lecture.id).cards.count == 30)
    }
    @Test func portableBackupRestoresPDFAndProvenance() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let pdf = PDFDocument(); pdf.insert(PDFPage(), at: 0)
        let source = root.appendingPathComponent("input.pdf"); #expect(pdf.write(to: source))
        let store = LibraryStore(rootURL: root.appendingPathComponent("original"))
        let module = try await store.createModule(name: "Module")
        let lecture = try await store.importPDF(from: source, moduleID: module.id)
        try await store.saveLegacyProvenance(Data("{\"raw\":true}".utf8), moduleID: module.id, lectureID: lecture.id)
        let persisted = try await store.loadLecture(moduleID: module.id, lectureID: lecture.id)
        let backup = root.appendingPathComponent("backup.json")
        try await store.exportBackup(moduleID: module.id, lectureID: lecture.id, to: backup)
        try FileManager.default.removeItem(at: store.rootURL)
        let restoredStore = LibraryStore(rootURL: root.appendingPathComponent("restored"))
        let restored = try await restoredStore.restoreBackup(from: backup)
        #expect(restored == persisted)
        #expect(PDFDocument(url: restoredStore.sourceURL(moduleID: module.id, lectureID: lecture.id))?.pageCount == 1)
        #expect(try String(contentsOf: restoredStore.rootURL.appendingPathComponent("Modules/\(module.id)/Lectures/\(lecture.id)/legacy-provenance.json"), encoding: .utf8) == "{\"raw\":true}")
    }
    @Test func missingIndexedLectureIsReported() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(rootURL: root)
        let module = try await store.createModule(name: "Test")
        let lecture = try await store.createLecture(Lecture(moduleID: module.id, name: "Lecture"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("Modules/\(module.id)/Lectures/\(lecture.id)"))
        await #expect(throws: LibraryError.self) { try await store.lectures(in: module.id) }
        await #expect(throws: LibraryError.self) { try await store.modules() }
    }
    @Test func repairsInterruptedLectureIndexAndReportsBadLecture() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(rootURL: root)
        let module = try await store.createModule(name: "Test")
        let lecture = try await store.createLecture(Lecture(moduleID: module.id, name: "Lecture"))
        let moduleURL = root.appendingPathComponent("Modules/\(module.id)/module.json")
        try LibraryStore.encoder().encode(module).write(to: moduleURL)
        #expect(try await store.modules().first?.lectureIDs == [lecture.id])
        let json = root.appendingPathComponent("Modules/\(module.id)/Lectures/\(lecture.id)/lecture.json")
        try Data("bad".utf8).write(to: json)
        await #expect(throws: (any Error).self) { try await store.lectures(in: module.id) }
    }
}
