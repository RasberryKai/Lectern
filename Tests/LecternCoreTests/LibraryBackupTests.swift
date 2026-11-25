import Foundation
import PDFKit
import Testing
@testable import LecternCore

struct LibraryBackupTests {
    @Test func fullBackupPreservesSavedFilesAndPreferences() async throws {
        let files = FileManager.default
        let folder = files.temporaryDirectory.appendingPathComponent("Lectern backup \(UUID())", isDirectory: true)
        defer { try? files.removeItem(at: folder) }
        let root = folder.appendingPathComponent("Custom Library", isDirectory: true)
        let store = LibraryStore(rootURL: root)
        let module = try await store.createModule(name: "Archived module")
        let pdf = PDFDocument()
        pdf.insert(PDFPage(), at: 0)
        let input = folder.appendingPathComponent("Slides.pdf")
        try #require(pdf.write(to: input))
        let lecture = try await store.importPDF(from: input, moduleID: module.id)
        _ = try await store.setModuleArchived(moduleID: module.id, archived: true)
        let sourcePDF = store.sourceURL(moduleID: module.id, lectureID: lecture.id)
        let lectureDirectory = sourcePDF.deletingLastPathComponent()
        let savedLecture = try await store.loadLecture(moduleID: module.id, lectureID: lecture.id)

        let extraFiles: [URL: Data] = [
            sourcePDF: try Data(contentsOf: sourcePDF),
            lectureDirectory.appendingPathComponent("chat-attachments/example.png"): Data([0, 1, 2]),
            lectureDirectory.appendingPathComponent("lecture.json.bak"): Data("recovery copy".utf8),
            lectureDirectory.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("reviews.jsonl"): Data("study history\n".utf8),
            root.appendingPathComponent("rules.md"): Data("user rules\n".utf8),
            root.appendingPathComponent("Exports/pending.json"): Data("export metadata".utf8),
            root.appendingPathComponent(".session.lock"): Data(),
            folder.appendingPathComponent("Codex/auth.json"): Data("outside the library".utf8)
        ]
        for (file, contents) in extraFiles {
            try files.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: file)
        }

        let destination = folder.appendingPathComponent("Lectern Backup.zip")
        try Data("previous backup".utf8).write(to: destination)
        let preferences = try PropertyListSerialization.data(fromPropertyList: ["lectern.appearance": "Dark"], format: .xml, options: 0)
        try await store.exportLibraryBackup(to: destination, preferences: preferences)

        let extracted = folder.appendingPathComponent("Extracted", isDirectory: true)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", destination.path, extracted.path]
        try unzip.run()
        unzip.waitUntilExit()
        try #require(unzip.terminationStatus == 0)

        let backup = extracted.appendingPathComponent("Lectern", isDirectory: true)
        let backedUpRoot = backup.appendingPathComponent("Library", isDirectory: true)
        #expect(try Data(contentsOf: backup.appendingPathComponent("Preferences.plist")) == preferences)
        for (file, contents) in extraFiles where file.path.hasPrefix(root.path + "/") && file.lastPathComponent != ".session.lock" {
            let relativePath = String(file.path.dropFirst(root.path.count + 1))
            #expect(try Data(contentsOf: backedUpRoot.appendingPathComponent(relativePath)) == contents)
        }
        #expect(!files.fileExists(atPath: backedUpRoot.appendingPathComponent(".library.lock").path))
        #expect(!files.fileExists(atPath: backedUpRoot.appendingPathComponent(".session.lock").path))
        #expect(!files.fileExists(atPath: backup.appendingPathComponent("Codex").path))

        let extractedStore = LibraryStore(rootURL: backedUpRoot)
        #expect(try await extractedStore.loadModule(moduleID: module.id).isArchived)
        #expect(try await extractedStore.loadLecture(moduleID: module.id, lectureID: lecture.id) == savedLecture)
    }

    @Test func backupRejectsDestinationsInsideTheLibrary() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Lectern backup \(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(rootURL: root)
        let destination = root.appendingPathComponent("nested/Backup.zip")

        await #expect(throws: LibraryError.self) {
            try await store.exportLibraryBackup(to: destination, preferences: Data())
        }
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
}
