import Foundation
import CoreGraphics
import LecternCore

@main struct LecternTool {
    static func main() async {
        do { try await run() }
        catch {
            FileHandle.standardError.write(Data("Lectern: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
    static func run() async throws {
        var arguments = Array(CommandLine.arguments.dropFirst())
        var root: URL?
        if let i = arguments.firstIndex(of: "--root") {
            guard arguments.indices.contains(i + 1) else { throw LibraryError.invalid("--root requires a directory.") }
            root = URL(fileURLWithPath: arguments[i + 1], isDirectory: true); arguments.removeSubrange(i...i + 1)
        }
        let command = arguments.first ?? "help"
        let api = arguments.contains("--api"); arguments.removeAll { $0 == "--api" }
        let codex = arguments.contains("--codex"); arguments.removeAll { $0 == "--codex" }
        guard !(api && codex) else { throw LibraryError.invalid("Choose only one AI backend flag: --api or --codex.") }
        let savedSettings = await AISettingsStore().load()
        let backend: AIBackend = api ? .messagesAPI : codex ? .codexCLI : savedSettings.backend
        var model = switch backend {
        case .claudeCLI: savedSettings.cliModel
        case .messagesAPI: savedSettings.messagesAPIModel
        case .codexCLI: savedSettings.codexModel
        }
        if let i = arguments.firstIndex(of: "--model"), arguments.indices.contains(i + 1) {
            model = arguments[i + 1]; arguments.removeSubrange(i...i + 1)
        }
        if command == "help" || command == "--help" { print(help); return }
        if command == "anki-setup" { print(AnkiExporter.setupInstructions); return }
        if command == "demo" && root == nil { root = FileManager.default.temporaryDirectory.appendingPathComponent("Lectern-demo-\(UUID())") }
        let store = root.map { LibraryStore(rootURL: $0) } ?? LibraryStore()
        // Commands that recover or execute jobs must not interrupt a live app's runner.
        let sessionCommands: Set<String> = ["migrate-default", "generate", "revise", "ask", "retry", "demo"]
        let sessionLock = try sessionCommands.contains(command) ? LibrarySessionLock(rootURL: store.rootURL) : nil
        defer { withExtendedLifetime(sessionLock) {} }
        let runner = JobRunner(store: store, providers: [ClaudeCLIProvider(settings: savedSettings), MessagesAPIProvider(settings: savedSettings), CodexCLIProvider(settings: savedSettings)])
        let service = LibraryService(store: store, runner: runner)
        func arg(_ index: Int) throws -> String {
            guard arguments.indices.contains(index) else { throw LibraryError.invalid("Missing argument. Run lectern help.") }; return arguments[index]
        }
        func id(_ index: Int) throws -> UUID {
            guard let result = UUID(uuidString: try arg(index)) else { throw LibraryError.invalid("Invalid UUID argument \(index).") }; return result
        }
        func report(_ report: MigrationReport) {
            if let source = report.source { print("Source: \(source.path)") }
            print("Imported \(report.imported.count), already imported \(report.skipped.count), failures \(report.failures.count).")
            for failure in report.failures { print("  \(failure.source): \(failure.message)") }
        }
        switch command {
        case "overview":
            let snapshot = try await store.dashboard()
            let totals = snapshot.totals
            print("\(snapshot.modules.count) active modules, \(snapshot.archivedModuleCount) archived")
            print("\(totals.doneLectureCount)/\(totals.plannedLectureCount) lectures done; \(totals.reviewCardCount) cards to review; \(totals.readyExportCount) ready to export; \(totals.notImportedCount) not imported")
            for progress in snapshot.modules {
                print("\(progress.module.id)  \(progress.module.name): \(progress.totals.doneLectureCount)/\(progress.totals.plannedLectureCount) done; pace \(progress.pace)")
            }
        case "module-settings":
            guard let planned = Int(try arg(3)) else { throw LibraryError.invalid("Planned lectures must be a whole number.") }
            let dateText = try arg(4)
            let examDate: ExamDate?
            if dateText == "none" { examDate = nil }
            else {
                let parts = dateText.split(separator: "-", omittingEmptySubsequences: false)
                guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
                      let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else { throw LibraryError.invalid("Exam date must be YYYY-MM-DD or none.") }
                examDate = try ExamDate(year: year, month: month, day: day)
            }
            let module = try await store.updateModuleSettings(moduleID: id(1), name: arg(2), plannedLectureCount: planned, examDate: examDate)
            print("Saved \(module.name): \(module.plannedLectureCount) lectures planned.")
        case "archive", "unarchive":
            let module = try await store.setModuleArchived(moduleID: id(1), archived: command == "archive")
            print("\(module.name): \(module.isArchived ? "archived, read-only" : "active")")
        case "list":
            for module in try await store.modules() {
                print("\(module.id)  \(module.name)\(module.isArchived ? " [Archived]" : "")")
                for lecture in try await store.lectures(in: module.id) {
                    print("  \(lecture.id)  \(lecture.name) — \(lecture.pageCount) slides, \(lecture.cards.count) cards")
                }
            }
        case "create-module": print(try await store.createModule(name: arg(1)).id)
        case "import-pdf": print(try await store.importPDF(from: URL(fileURLWithPath: arg(2)), moduleID: id(1)).id)
        case "migrate-slides": report(await LegacyImporter(store: store).importProjects(from: URL(fileURLWithPath: try arg(1))))
        case "migrate-reviewer": report(await LegacyImporter(store: store).importReviewer(from: URL(fileURLWithPath: try arg(1))))
        case "migrate-default":
            let result = try await service.bootstrap()
            result.migrations.forEach(report)
            result.warnings.forEach { print("Warning: \($0)") }
            print("Library: \(store.rootURL.path)")
        case "generate":
            _ = try await runner.recoverInterruptedJobs()
            let job = try await runner.generate(moduleID: id(1), lectureID: id(2), backend: backend, model: model,
                                                regenerateAll: arguments.contains("--all"))
            await runner.waitUntilIdle(); try await printJob(store: store, moduleID: id(1), lectureID: id(2), jobID: job)
        case "revise":
            _ = try await runner.recoverInterruptedJobs()
            let job = try await runner.revise(moduleID: id(1), lectureID: id(2), cardID: id(3), feedback: arg(4), backend: backend, model: model)
            await runner.waitUntilIdle(); try await printJob(store: store, moduleID: id(1), lectureID: id(2), jobID: job)
        case "ask":
            _ = try await runner.recoverInterruptedJobs()
            guard let page = Int(try arg(3)) else { throw LibraryError.invalid("Source slide must be a number.") }
            let job = try await runner.ask(moduleID: id(1), lectureID: id(2), anchorPage: page, question: arg(4), backend: backend, model: model)
            await runner.waitUntilIdle(); try await printJob(store: store, moduleID: id(1), lectureID: id(2), jobID: job)
            let lecture = try await store.loadLecture(moduleID: id(1), lectureID: id(2))
            if let answer = lecture.threads.first(where: { $0.anchorPage == page })?.messages.last { print(answer.text) }
        case "approve":
            let cardID = try id(3)
            _ = try await store.updateLecture(moduleID: id(1), lectureID: id(2)) { try LectureReducer.reduce(&$0, action: .setVerdict(cardID: cardID, .good)) }
        case "accept":
            let cardID = try id(3); let approve = arguments.contains("--approve")
            _ = try await store.updateLecture(moduleID: id(1), lectureID: id(2)) { try LectureReducer.reduce(&$0, action: .acceptProposal(cardID: cardID, approve: approve)) }
        case "export":
            let moduleID = try id(1), url = URL(fileURLWithPath: try arg(2))
            let result = try await service.exportAnki(moduleID: moduleID, to: url, changedOnly: !arguments.contains("--all"))
            print("Wrote \(result.entries.count) cards to \(url.path). Run lectern anki-setup before your first import.")
        case "backup": try await store.exportBackup(moduleID: id(1), lectureID: id(2), to: URL(fileURLWithPath: arg(3)))
        case "restore": print(try await store.restoreBackup(from: URL(fileURLWithPath: arg(1))).id)
        case "backup-module": try await store.exportModuleBackup(moduleID: id(1), to: URL(fileURLWithPath: arg(2)))
        case "restore-module": print(try await store.restoreModuleBackup(from: URL(fileURLWithPath: arg(1))).id)
        case "retry":
            _ = try await runner.recoverInterruptedJobs()
            try await runner.retry(moduleID: id(1), lectureID: id(2), jobID: id(3)); await runner.waitUntilIdle()
            try await printJob(store: store, moduleID: id(1), lectureID: id(2), jobID: id(3))
        case "job-logs":
            let directory = store.jobDirectory(moduleID: try id(1), lectureID: try id(2), jobID: try id(3)).appendingPathComponent("ai-logs")
            try printLogs(in: directory)
        case "show":
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
            print(String(decoding: try encoder.encode(await store.loadLecture(moduleID: id(1), lectureID: id(2))), as: UTF8.self))
        case "doctor":
            print("Library: \(store.rootURL.path)")
            print("AI traces: <library>/Modules/<module>/Lectures/<lecture>/jobs/<job>/ai-logs/<attempt>/summary.json")
            print("Find a job's traces: lectern job-logs MODULE_ID LECTURE_ID JOB_ID")
            let executable = ClaudeCLIProvider.resolveExecutable(configuredPath: savedSettings.claudeCLIPath)
            print("CLI executable: \(executable.path) (\(FileManager.default.isExecutableFile(atPath: executable.path) ? "installed" : "configure path"))")
            print("Log in using: claude auth login. Lectern never reads subscription tokens.")
            print("API key: \((try? KeychainStore().loadAPIKey()) == nil ? "not set" : "present in Keychain")")
        case "demo": try await demo(store: store)
        default: throw LibraryError.invalid("Unknown command '\(command)'. Run lectern help.")
        }
    }
    static func printJob(store: LibraryStore, moduleID: UUID, lectureID: UUID, jobID: UUID) async throws {
        let lecture = try await store.loadLecture(moduleID: moduleID, lectureID: lectureID)
        guard let job = lecture.jobs.first(where: { $0.id == jobID }) else { throw LectureError.missingJob(jobID) }
        print("\(job.id): \(job.state.rawValue)")
        let logs = store.jobDirectory(moduleID: moduleID, lectureID: lectureID, jobID: jobID).appendingPathComponent("ai-logs")
        if FileManager.default.fileExists(atPath: logs.path) { print("AI logs: \(logs.path)") }
        if let error = job.error { throw AIError.transport(error) }
    }
    static func printLogs(in directory: URL) throws {
        guard FileManager.default.fileExists(atPath: directory.path) else {
            print("No AI traces for this job. Traces are recorded for new executions; ordinary job snapshots expire after 7 days (saved chat snapshots are retained).")
            return
        }
        for attempt in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let summary = attempt.appendingPathComponent("summary.json")
            guard FileManager.default.fileExists(atPath: summary.path) else { continue }
            print(summary.path)
            print(try String(contentsOf: summary, encoding: .utf8))
        }
    }
    static func demo(store: LibraryStore) async throws {
        try FileManager.default.createDirectory(at: store.rootURL, withIntermediateDirectories: true)
        let input = store.rootURL.appendingPathComponent("demo-input.pdf")
        var bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        guard let context = CGContext(input as CFURL, mediaBox: &bounds, nil) else { throw LibraryError.invalid("Cannot make demo PDF.") }
        for _ in 0..<2 { context.beginPDFPage(nil); context.setFillColor(CGColor(gray: 0.5, alpha: 1)); context.fill(CGRect(x: 20, y: 20, width: 100, height: 100)); context.endPDFPage() }; context.closePDF()
        let module = try await store.createModule(name: "Lectern demo")
        let lecture = try await store.importPDF(from: input, moduleID: module.id)
        let fake = FakeAIProvider(responses: [
            AIResponse(content: #"{"cards":[{"front":"Why heavier tails?","back":"Estimating variance adds uncertainty.","sourceSlides":[1],"flag":null}],"skipped":[{"slide":2,"reason":"Title slide"}]}"#),
            AIResponse(content: #"{"cards":[{"front":"Why does estimating variance produce heavier tails?","back":"It adds uncertainty to the standardized estimate.","sourceSlides":[1],"flag":null}],"rationale":"Clarifies the mechanism."}"#),
            AIResponse(content: "The variance is estimated, adding uncertainty [slide 1]."),
            AIResponse(content: #"{"learningPoints":[{"text":"Estimated variance adds uncertainty.","pages":[1]}]}"#)
        ])
        let runner = JobRunner(store: store, providers: [fake])
        _ = try await runner.generate(moduleID: module.id, lectureID: lecture.id); await runner.waitUntilIdle()
        let generated = try await store.loadLecture(moduleID: module.id, lectureID: lecture.id)
        guard let card = generated.cards.first else { throw LibraryError.invalid("Demo generation failed.") }
        _ = try await runner.revise(moduleID: module.id, lectureID: lecture.id, cardID: card.id, feedback: "Make the question specific."); await runner.waitUntilIdle()
        _ = try await store.updateLecture(moduleID: module.id, lectureID: lecture.id) { try LectureReducer.reduce(&$0, action: .acceptProposal(cardID: card.id, approve: true)) }
        _ = try await runner.ask(moduleID: module.id, lectureID: lecture.id, anchorPage: 1, question: "Why?"); await runner.waitUntilIdle()
        let service = LibraryService(store: store, runner: runner)
        let output = store.rootURL.deletingLastPathComponent().appendingPathComponent("\(store.rootURL.lastPathComponent)-anki.txt")
        let exported = try await service.exportAnki(moduleID: module.id, to: output)
        let backup = output.deletingPathExtension().appendingPathExtension("backup.json")
        try await store.exportBackup(moduleID: module.id, lectureID: lecture.id, to: backup)
        let restored = LibraryStore(rootURL: store.rootURL.deletingLastPathComponent().appendingPathComponent("\(store.rootURL.lastPathComponent)-restored"))
        _ = try await restored.restoreBackup(from: backup)
        let saved = try await store.loadLecture(moduleID: module.id, lectureID: lecture.id)
        guard exported.entries.count == 1, saved.jobs.count == 4, saved.jobs.allSatisfy({ $0.state == .succeeded }), saved.threads.first?.learningPoints.count == 1 else { throw LibraryError.invalid("Demo invariants failed.") }
        print("PASS: PDF → Generate → Revise → Accept & approve → Ask → Distil → Anki text → portable backup/restore.")
        print("Offline fixtures only. Library: \(store.rootURL.path)\nAnki text: \(output.path)")
    }
    static let help = """
    Lectern — local Swift backend, macOS 26+
    Optional: --root PATH (default ~/Library/Application Support/Lectern/Library)
    AI commands use your saved backend; --api selects the paid API and --codex selects Codex CLI.
    --model MODEL overrides the backend's model.

    demo                                     Offline end-to-end run in a new temporary library
    job-logs MODULE_ID LECTURE_ID JOB_ID       Trace paths and summaries for every execution attempt
    list                                     Modules and lectures
    overview                                 Active module progress and totals
    create-module NAME
    module-settings MODULE_ID NAME PLANNED YYYY-MM-DD|none
    archive MODULE_ID                        Read-only; wait/cancel jobs first
    unarchive MODULE_ID
    import-pdf MODULE_ID FILE.pdf
    migrate-default                          Read-only import of your installed legacy apps
    migrate-slides LEGACY_FOLDER             Also supports a friend's copied Projects folder
    migrate-reviewer SESSIONS_OR_BACKUP.json
    generate MODULE_ID LECTURE_ID [--all]     Default: selected slides without cards
    revise MODULE_ID LECTURE_ID CARD_ID FEEDBACK
    ask MODULE_ID LECTURE_ID SOURCE_SLIDE QUESTION
    approve MODULE_ID LECTURE_ID CARD_ID
    accept MODULE_ID LECTURE_ID CARD_ID [--approve]
    export MODULE_ID OUTPUT.txt [--all]       Default: approved new/changed cards
    anki-setup                               Required one-time Anki note-type setup
    backup MODULE_ID LECTURE_ID OUTPUT.json
    restore BACKUP.json
    backup-module MODULE_ID OUTPUT.json
    restore-module BACKUP.json
    retry MODULE_ID LECTURE_ID JOB_ID
    show MODULE_ID LECTURE_ID                 Full lecture JSON
    doctor
    """
}
