import Foundation

public struct BootstrapReport: Sendable {
    public var interruptedJobs: Int
    public var migrations: [MigrationReport]
    public var warnings: [String]
}

public struct LibraryService: Sendable {
    public let store: LibraryStore
    public let runner: JobRunner
    public init(store: LibraryStore, runner: JobRunner) { self.store = store; self.runner = runner }

    /// Safe to repeat: imports skip existing provenance identities; missing legacy apps are normal.
    public func bootstrap(importLegacy: Bool = true) async throws -> BootstrapReport {
        try await store.recoverPendingExports()
        let interrupted = try await runner.recoverInterruptedJobs()
        _ = try await store.loadRules()
        var reports: [MigrationReport] = [], warnings: [String] = []
        if importLegacy {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            var slides = support.appendingPathComponent("Slide Learning")
            let bookmark = slides.appendingPathComponent(".shared-library.bookmark")
            var scoped: URL?
            if FileManager.default.fileExists(atPath: bookmark.path) {
                do {
                    var stale = false
                    let bookmarkData = try Data(contentsOf: bookmark)
                    let shared: URL
                    do { shared = try URL(resolvingBookmarkData: bookmarkData, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale) }
                    catch { shared = try URL(resolvingBookmarkData: bookmarkData, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale) }
                    if shared.startAccessingSecurityScopedResource() { scoped = shared }
                    guard FileManager.default.fileExists(atPath: shared.appendingPathComponent("Projects").path) else { throw LibraryError.unavailable("Saved shared library is unavailable.") }
                    slides = shared
                    if stale { warnings.append("The legacy shared-folder bookmark is stale. It was read without changing the old app's settings.") }
                } catch { warnings.append("Could not access the legacy shared folder; importing retained local projects. Choose the shared folder explicitly to import its latest notes: \(error.localizedDescription)") }
            }
            defer { scoped?.stopAccessingSecurityScopedResource() }
            let importer = LegacyImporter(store: store)
            if FileManager.default.fileExists(atPath: slides.appendingPathComponent("Projects").path) { reports.append(await importer.importProjects(from: slides)) }
            let reviewer = support.appendingPathComponent("FlashcardReviewer/sessions.json")
            if FileManager.default.fileExists(atPath: reviewer.path) { reports.append(await importer.importReviewer(from: reviewer)) }
        }
        try await runner.cleanSnapshots()
        return BootstrapReport(interruptedJobs: interrupted, migrations: reports, warnings: warnings)
    }
    public func makeModuleRule(moduleID: UUID, feedback: String) async throws {
        let text = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // A transactional module operation avoids overwriting instructions from another window.
        try await store.appendModuleInstruction(moduleID: moduleID, text: text)
    }
    public func exportAnki(moduleID: UUID, lectureID: UUID? = nil, to url: URL, changedOnly: Bool = true) async throws -> AnkiExportResult {
        try store.assertExternalDestination(url)
        try await store.recoverPendingExports()
        let modules = try await store.modules()
        guard let module = modules.first(where: { $0.id == moduleID }) else { throw LibraryError.invalid("Module does not exist.") }
        let lectures: [Lecture]
        if let lectureID { lectures = [try await store.loadLecture(moduleID: moduleID, lectureID: lectureID)] }
        else { lectures = try await store.lectures(in: moduleID) }
        let export = try AnkiExporter.export(lectures: lectures, moduleName: module.name, changedOnly: changedOnly)
        guard !export.entries.isEmpty else { throw LibraryError.invalid("No eligible approved cards to export.") }
        // Write first. Failed file placement never marks cards as exported.
        try Data(export.text.utf8).write(to: url, options: .atomic)
        try await store.commitExport(moduleID: moduleID, entries: export.entries)
        return export
    }
}
