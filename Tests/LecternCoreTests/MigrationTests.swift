import Foundation
import PDFKit
import Testing
@testable import LecternCore

struct MigrationTests {
    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lectern-migration-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
    }
    @Test func reviewerPreservesHistoryMathAndRawProvenanceAndIsIdempotent() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("sessions.json")
        let card = Flashcard(front: "new", back: "$5", originalFront: "old", verdict: .needsAdjustment, notes: "Fix this", rawImportLine: "raw==line", replacementRequested: true, mathInterpretations: ["$5": .keepAsText])
        let deleted = FlashcardSession(title: "Deleted", cards: [])
        let session = FlashcardSession(title: "Review", cards: [card], importWarnings: [FlashcardImportWarning(kind: .sameFront, cardIDs: [card.id], sourceLineNumbers: [2], message: "Retain me")], createdAt: Date(timeIntervalSince1970: 1000), selectedCardID: card.id)
        struct Archive: Encodable { var schemaVersion = 1; var sessions: [FlashcardSession]; var deletedSessionIDs: [UUID: Date] }
        let data = try LibraryStore.encoder().encode(Archive(sessions: [session, deleted], deletedSessionIDs: [deleted.id: Date()]))
        try data.write(to: source)
        let store = LibraryStore(rootURL: root.appendingPathComponent("Library")); let importer = LegacyImporter(store: store)
        let first = await importer.importReviewer(from: source)
        #expect(first.failures.isEmpty); #expect(first.imported.count == 1)
        #expect(first.skipped == [deleted.id])
        let module = try #require(try await store.modules().first)
        let lecture = try #require(try await store.lectures(in: module.id).first)
        #expect(lecture.cards.first?.id == card.id)
        #expect(lecture.cards.first?.history.map(\.front) == ["old", "new"])
        #expect(lecture.cards.first?.feedback == "Fix this")
        #expect(lecture.cards.first?.mathInterpretations == ["$5": .keepAsText])
        #expect(lecture.createdAt == session.createdAt)
        let provenance = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: store.rootURL.appendingPathComponent("Modules/\(module.id)/Lectures/\(lecture.id)/legacy-provenance.json"))) as? [String: Any])
        #expect(provenance["sessions"] == nil)
        let rawSession = try #require(provenance["session"] as? [String: Any])
        #expect(rawSession["id"] as? String == session.id.uuidString)
        #expect(rawSession["importWarnings"] != nil)
        let second = await importer.importReviewer(from: source)
        #expect(second.imported.isEmpty); #expect(second.failures.isEmpty)
        #expect(try Data(contentsOf: source) == data)
    }
    @Test func corruptArchiveUsesBackupButUnknownVersionDoesNot() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("sessions.json")
        let session = FlashcardSession(title: "Backup", cards: [Flashcard(front: "Q", back: "A")])
        try SessionBackup.encode(session).write(to: source.appendingPathExtension("bak"))
        try Data("broken".utf8).write(to: source)
        let importer = LegacyImporter(store: LibraryStore(rootURL: root.appendingPathComponent("Library")))
        let report = await importer.importReviewer(from: source)
        #expect(report.imported.count == 1); #expect(report.failures.isEmpty)
        #expect(try String(contentsOf: source, encoding: .utf8) == "broken")
        try Data("{\"schemaVersion\":99,\"sessions\":[]}".utf8).write(to: source)
        let rejected = await importer.importReviewer(from: source)
        #expect(rejected.failures.count == 1); #expect(rejected.imported.isEmpty)
    }
    @Test func malformedSessionIsIsolatedAndDistinctLibrariesDoNotCollide() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let session = FlashcardSession(title: "Good", cards: [Flashcard(front: "Q", back: "A")])
        let raw = try JSONSerialization.jsonObject(with: LibraryStore.encoder().encode(session))
        let data = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "sessions": [["broken": true], raw]])
        let a = root.appendingPathComponent("a.json"); let b = root.appendingPathComponent("b.json")
        try data.write(to: a); try data.write(to: b)
        let importer = LegacyImporter(store: LibraryStore(rootURL: root.appendingPathComponent("Library")))
        let first = await importer.importReviewer(from: a); let second = await importer.importReviewer(from: b)
        #expect(first.imported.count == 1); #expect(first.failures.count == 1)
        #expect(second.imported.count == 1); #expect(first.imported != second.imported)
    }
    @Test func legacyProjectDefaultsMissingPreferencesAndPreservesSource() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID(); let project = root.appendingPathComponent("Projects/\(id)")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let pdf = PDFDocument(); pdf.insert(PDFPage(), at: 0); #expect(pdf.write(to: project.appendingPathComponent("source.pdf")))
        let object: [String: Any] = ["schemaVersion": 1, "id": id.uuidString, "name": "Notes", "sourceFilename": "lecture.pdf", "pageCount": 1, "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-01-01T00:00:00Z", "slides": [["pageIndex": 0, "isSelected": false, "note": "Keep me"]], "viewPreferences": ["thumbnailSize": "compact", "filter": "all"]]
        let data = try JSONSerialization.data(withJSONObject: object); try data.write(to: project.appendingPathComponent("project.json"))
        let store = LibraryStore(rootURL: root.appendingPathComponent("Library")); let importer = LegacyImporter(store: store)
        let report = await importer.importProjects(from: root)
        #expect(report.failures.isEmpty); #expect(report.imported.count == 1)
        let module = try #require(try await store.modules().first)
        let lecture = try #require(try await store.lectures(in: module.id).first)
        #expect(lecture.slides.first?.note == "Keep me"); #expect(lecture.slides.first?.isSelected == false)
        #expect(lecture.viewPreferences.sidebarVisible)
        #expect(lecture.viewPreferences.thumbnailSize == .compact)
        #expect(try Data(contentsOf: project.appendingPathComponent("project.json")) == data)
        let repeatReport = await importer.importProjects(from: root)
        #expect(repeatReport.imported.isEmpty)
    }
}
