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

    @Test func importRestoresAnExportAndResumesAfterTheLibrarySwap() async throws {
        let files = FileManager.default
        let folder = files.temporaryDirectory.appendingPathComponent("Lectern restore \(UUID())", isDirectory: true)
        defer { try? files.removeItem(at: folder) }
        let source = LibraryStore(rootURL: folder.appendingPathComponent("Source"))
        let module = try await source.createModule(name: "Statistics")
        let input = folder.appendingPathComponent("Slides.pdf")
        let pdf = PDFDocument()
        pdf.insert(PDFPage(), at: 0)
        try #require(pdf.write(to: input))
        let lecture = try await source.importPDF(from: input, moduleID: module.id)
        let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j2ioAAAAASUVORK5CYII="))
        let image = try await source.importChatAttachment(moduleID: module.id, lectureID: lecture.id, data: png,
                                                         filename: "example.png", mediaType: "image/png")
        let sample = SolveVariance(outcomes: [0, 4], weights: [1, 1]).exercise
        let draft = SolveDraft(skill: "Calculate variance", reason: "Apply the formula", variation: "Change the outcomes", sample: sample)
        _ = try await source.updateLecture(moduleID: module.id, lectureID: lecture.id) {
            var card = Card(sourcePages: [1], front: sample.prompt, back: sample.explanation, verdict: .good)
            card.solve = SolveCard(draft: draft)
            $0.cards = [card]
            $0.currentChat.draftAttachments = [image]
        }
        let at = Date(timeIntervalSince1970: 1_767_312_000)
        let entry = try #require(try await source.studyCatalog(now: at).decks.first?.approvedCards.first)
        let exercise = try #require(try await source.presentSolveCase(entry, presentationID: UUID(), now: at))
        let savedLecture = try await source.loadLecture(moduleID: module.id, lectureID: lecture.id)
        _ = try await source.saveRules("Restored rules")
        let archive = folder.appendingPathComponent("Lectern Backup.zip")
        let importedPreferences = try preferences("Dark")
        try await source.exportLibraryBackup(to: archive, preferences: importedPreferences)

        let root = folder.appendingPathComponent("Current Library")
        let store = LibraryStore(rootURL: root)
        let existing = try await store.createModule(name: "Keep me")
        let oldPreferences = try preferences("Light")
        let sessionLock = try LibrarySessionLock(rootURL: root)
        defer { withExtendedLifetime(sessionLock) {} }
        let lockNames = [".session.lock", ".library.lock"]
        let oldLocks = try lockNames.map {
            try files.attributesOfItem(atPath: root.appendingPathComponent($0).path)[.systemFileNumber] as? NSNumber
        }

        try await store.stageLibraryBackupImport(from: archive)
        #expect(try await store.modules().map(\.id) == [existing.id])
        let restore = try #require(try await store.restorePendingLibraryBackup(previousPreferences: oldPreferences))
        #expect(restore.preferences == importedPreferences)
        #expect(try await store.modules().map(\.id) == [module.id])
        #expect(try await store.loadLecture(moduleID: module.id, lectureID: lecture.id) == savedLecture)
        #expect(try await store.loadRules() == "Restored rules")
        #expect(try Data(contentsOf: store.sourceURL(moduleID: module.id, lectureID: lecture.id)) == Data(contentsOf: input))
        #expect(try await store.loadChatAttachment(moduleID: module.id, lectureID: lecture.id, attachment: image) == png)
        #expect(try await store.studyCatalog(now: at).decks.first?.approvedCards.first?.seenSolveCaseIDs == [exercise.id])
        #expect(throws: LibraryError.self) { _ = try LibrarySessionLock(rootURL: root) }
        let restoredLocks = try lockNames.map {
            try files.attributesOfItem(atPath: root.appendingPathComponent($0).path)[.systemFileNumber] as? NSNumber
        }
        #expect(restoredLocks == oldLocks)

        // Simulate another startup after publishing the library and before finishing preference import.
        let reopened = LibraryStore(rootURL: root)
        let retry = try #require(try await reopened.restorePendingLibraryBackup(previousPreferences: importedPreferences))
        #expect(retry.preferences == restore.preferences)
        #expect(retry.previousLibrary == restore.previousLibrary)
        try await reopened.finishPendingLibraryBackupImport()
        #expect(try await reopened.restorePendingLibraryBackup(previousPreferences: importedPreferences) == nil)
        #expect(try Data(contentsOf: restore.previousLibrary.deletingLastPathComponent().appendingPathComponent("Preferences.plist")) == oldPreferences)
        for name in lockNames { #expect(!files.fileExists(atPath: restore.previousLibrary.appendingPathComponent(name).path)) }
        let prior = LibraryStore(rootURL: restore.previousLibrary)
        #expect(try await prior.modules().map(\.id) == [existing.id])
    }

    @Test func importsAValidEmptyBackup() async throws {
        let files = FileManager.default
        let folder = files.temporaryDirectory.appendingPathComponent("Lectern restore \(UUID())", isDirectory: true)
        defer { try? files.removeItem(at: folder) }
        try files.createDirectory(at: folder, withIntermediateDirectories: false)
        let archive = folder.appendingPathComponent("Empty.zip")
        let source = LibraryStore(rootURL: folder.appendingPathComponent("Empty"))
        let imported = try preferences("Dark")
        try await source.exportLibraryBackup(to: archive, preferences: imported)

        let store = LibraryStore(rootURL: folder.appendingPathComponent("Current"))
        let sessionLock = try LibrarySessionLock(rootURL: store.rootURL)
        defer { withExtendedLifetime(sessionLock) {} }
        _ = try await store.createModule(name: "Only in the current library")
        try await store.stageLibraryBackupImport(from: archive)
        let restore = try await store.restorePendingLibraryBackup(previousPreferences: preferences("Light"))
        #expect(restore?.preferences == imported)
        try await store.finishPendingLibraryBackupImport()
        #expect(try await store.modules().isEmpty)
    }

    enum InvalidArchive: CaseIterable {
        case tar, corruptZIPEntry, malformedPreferences, symlink, missingPDF, corruptStudyJournal, corruptExportJournal
    }

    @Test(arguments: InvalidArchive.allCases)
    func rejectsInvalidArchiveWithoutChangingTheLiveLibrary(problem: InvalidArchive) async throws {
        let files = FileManager.default
        let folder = files.temporaryDirectory.appendingPathComponent("Lectern invalid restore \(UUID())", isDirectory: true)
        defer { try? files.removeItem(at: folder) }
        let store = LibraryStore(rootURL: folder.appendingPathComponent("Live"))
        let existing = try await store.createModule(name: "Keep me")
        let original = try preferences("Light")
        let archive = folder.appendingPathComponent("Invalid.zip")
        let payload = folder.appendingPathComponent("Lectern")
        let source = LibraryStore(rootURL: payload.appendingPathComponent("Library"))
        let module = try await source.createModule(name: "Imported")
        let imported = try preferences("Dark")
        switch problem {
        case .tar:
            try imported.write(to: payload.appendingPathComponent("Preferences.plist"))
            try files.removeItem(at: source.rootURL.appendingPathComponent(".library.lock"))
            try runArchiveCommand("/usr/bin/tar", ["-cf", archive.path, "Lectern"], in: folder)
        case .corruptZIPEntry:
            let rules = "Unique content in the stored ZIP entry."
            _ = try await source.saveRules(rules)
            try imported.write(to: payload.appendingPathComponent("Preferences.plist"))
            try files.removeItem(at: source.rootURL.appendingPathComponent(".library.lock"))
            try runArchiveCommand("/usr/bin/zip", ["-q", "-0", "-r", archive.path, "Lectern"], in: folder)
            var bytes = try Data(contentsOf: archive)
            let entry = try #require(bytes.range(of: Data(rules.utf8)))
            bytes[entry.lowerBound] ^= 1
            try bytes.write(to: archive)
        case .malformedPreferences:
            try await source.exportLibraryBackup(to: archive, preferences: Data("wrong data".utf8))
        case .symlink:
            let link = source.rootURL.appendingPathComponent("Link")
            try files.createSymbolicLink(at: link, withDestinationURL: store.rootURL)
            try imported.write(to: payload.appendingPathComponent("Preferences.plist"))
            try files.removeItem(at: source.rootURL.appendingPathComponent(".library.lock"))
            try runArchiveCommand("/usr/bin/zip", ["-qr", "-y", archive.path, "Lectern"], in: folder)
        case .missingPDF:
            let input = folder.appendingPathComponent("Slides.pdf")
            let pdf = PDFDocument()
            pdf.insert(PDFPage(), at: 0)
            try #require(pdf.write(to: input))
            let lecture = try await source.importPDF(from: input, moduleID: module.id)
            try files.removeItem(at: source.sourceURL(moduleID: module.id, lectureID: lecture.id))
            try await source.exportLibraryBackup(to: archive, preferences: imported)
        case .corruptStudyJournal:
            let journal = source.moduleDirectory(module.id).appendingPathComponent("reviews.jsonl")
            try Data("invalid event\n".utf8).write(to: journal)
            try await source.exportLibraryBackup(to: archive, preferences: imported)
        case .corruptExportJournal:
            let directory = source.rootURL.appendingPathComponent("Exports")
            try files.createDirectory(at: directory, withIntermediateDirectories: false)
            try Data("invalid event\n".utf8).write(to: directory.appendingPathComponent("pending.json"))
            try await source.exportLibraryBackup(to: archive, preferences: imported)
        }

        await #expect(throws: (any Error).self) { try await store.stageLibraryBackupImport(from: archive) }
        #expect(try await store.restorePendingLibraryBackup(previousPreferences: original) == nil)
        #expect(try await store.modules().map(\.id) == [existing.id])
    }

    private func preferences(_ appearance: String) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: ["lectern.appearance": appearance], format: .xml, options: 0)
    }

    private func runArchiveCommand(_ command: String, _ arguments: [String], in folder: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments
        process.currentDirectoryURL = folder
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
    }
}
