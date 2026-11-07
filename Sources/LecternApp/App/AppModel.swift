import AppKit
import LecternCore
import Observation
import SwiftUI

nonisolated struct LectureRef: Codable, Hashable, Sendable, Identifiable {
    var id: UUID { lectureID }
    var moduleID: UUID
    var lectureID: UUID
}

nonisolated enum SidebarItem: Hashable {
    case overview
    case module(UUID)
    case export(UUID)
    case settings
}

/// Files picked or dropped together, shown in the import sheet before they are merged into one lecture.
nonisolated struct PendingPDFImport: Identifiable, Sendable {
    nonisolated struct File: Identifiable, Sendable {
        var id: URL { url }
        let url: URL
        let pageCount: Int
        /// Why the file can't be imported (locked, unreadable). It must be left out to continue.
        let problem: String?
    }
    enum Target: Sendable {
        /// A new lecture with this number.
        case newLecture(slot: Int)
        /// Appended after the last slide of an existing lecture.
        case append(lectureID: UUID, title: String, existingPages: Int)
    }
    let id = UUID()
    let moduleID: UUID
    let target: Target
    var files: [File]
    var name: String
}

/// One library per app: one store, one runner (global AI concurrency), one service.
@Observable
final class AppModel {
    static let shared = AppModel()

    enum Phase: Equatable { case loading, ready, failed(String) }

    let store: LibraryStore
    let runner: JobRunner
    let library: LibraryService
    let keychain: KeychainStore
    let settingsStore = AISettingsStore()
    private let providerConfiguration: ProviderConfiguration

    private(set) var phase: Phase = .loading
    private(set) var dashboard: DashboardSnapshot? = nil
    private(set) var modules: [Module] = []
    private(set) var settings: AISettings = .default
    private(set) var apiKeySaved = false
    private(set) var bootstrapReport: BootstrapReport? = nil
    var showBootstrapReport = false
    var renamingLecture: LectureRef?
    var activeLecture: LectureRef?
    private(set) var leavingLecture = false
    var selection: SidebarItem = .overview
    var errorMessage: String? = nil
    var showNewModule = false
    var settingsModuleID: UUID? = nil
    /// Two or more PDFs waiting in the import sheet.
    var pendingImport: PendingPDFImport? = nil
    /// Lecture windows read and clear this to switch mode when "Review"/"Open" targets an open window.
    var requestedModes: [UUID: LectureMode] = [:]

    @ObservationIgnored private var lectureWindows: [UUID: LectureWindowModel] = [:]
    @ObservationIgnored private var eventTask: Task<Void, Never>? = nil
    @ObservationIgnored private var reloadTask: Task<Void, Never>? = nil
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var started = false

    private init() {
        let environment = ProcessInfo.processInfo.environment
        if let root = environment["LECTERN_LIBRARY_ROOT"], !root.isEmpty {
            store = LibraryStore(rootURL: URL(fileURLWithPath: (root as NSString).expandingTildeInPath, isDirectory: true))
        } else {
            store = LibraryStore()
        }
        let configuration = ProviderConfiguration(.default)
        providerConfiguration = configuration
        let keychain = KeychainStore()
        self.keychain = keychain
        runner = JobRunner(store: store, providers: [
            ConfigurableProvider(backend: .claudeCLI, configuration: configuration, keychain: keychain),
            ConfigurableProvider(backend: .messagesAPI, configuration: configuration, keychain: keychain)
        ])
        library = LibraryService(store: store, runner: runner)
    }

    // MARK: Startup

    func start() async {
        guard !started else { return }
        started = true
        settings = await settingsStore.load()
        providerConfiguration.update(settings)
        refreshAPIKeyState()
        do {
            let skipLegacy = ProcessInfo.processInfo.environment["LECTERN_SKIP_LEGACY_IMPORT"] == "1"
            let report = try await library.bootstrap(importLegacy: !skipLegacy)
            bootstrapReport = report
            showBootstrapReport = report.interruptedJobs > 0 || !report.warnings.isEmpty
                || report.migrations.contains { !$0.failures.isEmpty || !$0.imported.isEmpty }
            try await reloadNow()
            phase = .ready
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }
        observeJobs()
        observeEnvironment()
    }

    private func observeJobs() {
        eventTask = Task { [weak self, runner] in
            let events = await runner.events()
            for await event in events {
                guard let self else { return }
                if ["Succeeded", "Failed", "Cancelled", "Persistence failed", "Queued"].contains(event.stage) {
                    self.scheduleReload()
                }
            }
        }
    }

    private func observeEnvironment() {
        let center = NotificationCenter.default
        let names: [Notification.Name] = [NSApplication.didBecomeActiveNotification, .NSCalendarDayChanged, .NSSystemTimeZoneDidChange]
        for name in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleReload() }
            })
        }
    }

    // MARK: Library state

    /// Coalesces bursts (job events, typing-driven saves) into one dashboard read.
    func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            do { try await self.reloadNow() } catch { self.errorMessage = error.localizedDescription }
        }
    }

    func reloadNow() async throws {
        let snapshot = try await store.dashboard(now: Date(), timeZone: .current)
        let list = try await store.modules()
        dashboard = snapshot
        modules = list
        if case .module(let id) = selection, !list.contains(where: { $0.id == id }) { selection = .overview }
        if case .export(let id) = selection, !list.contains(where: { $0.id == id }) { selection = .overview }
    }

    func module(_ id: UUID) -> Module? { modules.first { $0.id == id } }
    func progress(_ id: UUID) -> ModuleProgress? { dashboard?.modules.first { $0.module.id == id } }
    func isArchived(_ moduleID: UUID) -> Bool { module(moduleID)?.isArchived ?? false }
    var activeModules: [Module] { dashboard?.modules.map(\.module) ?? modules.filter { !$0.isArchived } }
    var archivedModules: [Module] { dashboard?.archivedModules ?? modules.filter(\.isArchived) }

    /// Runs a throwing operation and surfaces its message in the window instead of failing silently.
    func perform(_ operation: () async throws -> Void) async {
        do { try await operation() } catch { errorMessage = error.localizedDescription }
    }

    // MARK: Modules

    @discardableResult
    func createModule(name: String, instructions: String = "") async throws -> Module {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LibraryError.invalid("Give the module a name.") }
        let module = try await store.createModule(name: trimmed, instructions: instructions)
        try await reloadNow()
        selection = .module(module.id)
        return module
    }

    func setLectureStatus(_ status: LectureProgressStatus?, for ref: LectureRef) async {
        await perform {
            _ = try await store.updateLecture(moduleID: ref.moduleID, lectureID: ref.lectureID) {
                $0.progressOverride = status
            }
            try await reloadNow()
        }
    }

    func setEmptySlotStatus(_ status: LectureProgressStatus?, for slotID: LectureSlot.ID) async {
        await perform {
            try await store.setEmptySlotStatus(status, slotID: slotID)
            try await reloadNow()
        }
    }

    func renameLecture(_ ref: LectureRef, name: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LibraryError.invalid("Give the presentation a name.") }
        let workspace = lectureWindows[ref.lectureID]
        try await workspace?.flushAllThrowing()
        _ = try await store.updateLecture(moduleID: ref.moduleID, lectureID: ref.lectureID) { lecture in
            lecture.name = trimmed
        }
        try await workspace?.session.refresh()
        try await reloadNow()
    }

    func saveInstructions(moduleID: UUID, instructions: String) async throws {
        var module = try await store.loadModule(moduleID: moduleID)
        module.instructions = instructions
        try await store.updateModule(module)
        try await reloadNow()
    }

    /// One PDF imports straight away. Two or more open the import sheet, which merges them into one lecture.
    func importPDFs(_ urls: [URL], into moduleID: UUID) async {
        let pdfs = urls.filter { $0.pathExtension.lowercased() == "pdf" }
        let skipped = urls.count - pdfs.count
        let skippedNote = skipped > 0 ? "Only PDF files can be imported; \(Format.count(skipped, "other file")) left out." : nil
        if pdfs.count >= 2 {
            await openImportSheet(pdfs, into: moduleID)
            if let skippedNote { errorMessage = skippedNote }
            return
        }
        var failures: [String] = []
        if let url = pdfs.first {
            do { _ = try await store.importPDF(from: url, moduleID: moduleID) }
            catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
        }
        if let skippedNote { failures.append(skippedNote) }
        try? await reloadNow()
        if !failures.isEmpty { errorMessage = failures.joined(separator: "\n") }
    }

    func chooseAndImportPDFs(into moduleID: UUID) async {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose lecture slides. Several PDFs become one lecture; you set the order next."
        panel.prompt = "Import"
        guard panel.runModal() == .OK else { return }
        await importPDFs(panel.urls, into: moduleID)
    }

    private func openImportSheet(_ urls: [URL], into moduleID: UUID) async {
        let ordered = PDFMerge.naturalOrder(urls)
        let files = await inspect(ordered)
        let lectureCount = (try? await store.lectures(in: moduleID).count) ?? 0
        pendingImport = PendingPDFImport(moduleID: moduleID, target: .newLecture(slot: lectureCount + 1), files: files,
                                         name: PDFMerge.suggestedName(for: ordered.map(\.lastPathComponent)))
    }

    private func inspect(_ urls: [URL]) async -> [PendingPDFImport.File] {
        await Task.detached(priority: .userInitiated) {
            urls.map { url -> PendingPDFImport.File in
                do { return .init(url: url, pageCount: try PDFMerge.pageCount(of: url), problem: nil) }
                catch { return .init(url: url, pageCount: 0, problem: error.localizedDescription) }
            }
        }.value
    }

    /// Adding to an existing lecture always goes through the sheet, even for one PDF: pages can't be removed again.
    func appendPDFs(_ urls: [URL], to ref: LectureRef) async {
        let pdfs = urls.filter { $0.pathExtension.lowercased() == "pdf" }
        guard !pdfs.isEmpty else { errorMessage = "Only PDF files can be added."; return }
        do {
            let lecture = try await store.loadLecture(moduleID: ref.moduleID, lectureID: ref.lectureID)
            guard lecture.pageCount > 0 else {
                errorMessage = "\(lecture.name) has no slides to add to. Import the PDFs as a new lecture instead."
                return
            }
            let index = modules.first { $0.id == ref.moduleID }?.lectureIDs.firstIndex(of: ref.lectureID) ?? 0
            let ordered = PDFMerge.naturalOrder(pdfs)
            pendingImport = PendingPDFImport(moduleID: ref.moduleID,
                                             target: .append(lectureID: ref.lectureID, title: Format.lectureTitle(index: index, name: lecture.name), existingPages: lecture.pageCount),
                                             files: await inspect(ordered), name: lecture.name)
            if pdfs.count < urls.count { errorMessage = "Only PDF files can be added; \(Format.count(urls.count - pdfs.count, "other file")) left out." }
        } catch { errorMessage = error.localizedDescription }
    }

    func chooseAndAppendPDFs(to ref: LectureRef) async {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose PDFs to add after the lecture's last slide."
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        await appendPDFs(panel.urls, to: ref)
    }

    /// Appends the sheet's files and opens the lecture in Prepare on the first new slide.
    func appendConfirmed(_ urls: [URL], to ref: LectureRef) async throws {
        let workspace = lectureWindows[ref.lectureID]
        try await workspace?.flushAllThrowing()
        _ = try await store.appendPDFs(urls, moduleID: ref.moduleID, lectureID: ref.lectureID)
        if let workspace { await workspace.reloadAfterExternalChange() }
        try? await reloadNow()
        selection = .module(ref.moduleID)
        openLecture(ref, mode: .prepare)
    }

    /// Merges the sheet's files in order into one lecture and opens it in Prepare.
    func importMerged(_ urls: [URL], name: String, into moduleID: UUID) async throws {
        let lecture = try await store.importPDFs(urls, name: name, moduleID: moduleID)
        try? await reloadNow()
        selection = .module(moduleID)
        openLecture(LectureRef(moduleID: moduleID, lectureID: lecture.id), mode: .prepare)
    }

    /// Lectures with durable running or queued jobs. Archive refuses these.
    func runningJobs(in moduleID: UUID) async throws -> [(lectureID: UUID, jobID: UUID)] {
        try await store.lectures(in: moduleID).flatMap { lecture in
            lecture.jobs.filter { $0.state == .running }.map { (lectureID: lecture.id, jobID: $0.id) }
        }
    }

    /// Flush open editors for the module, optionally cancel its jobs, then archive.
    func archive(moduleID: UUID, cancellingJobs: Bool) async throws {
        for window in lectureWindows.values where window.ref.moduleID == moduleID {
            try await window.flushAllThrowing()
        }
        let running = try await runningJobs(in: moduleID)
        if !running.isEmpty {
            guard cancellingJobs else {
                throw LibraryError.invalid("Claude is still working on \(Format.count(running.count, "job")) in this module. Wait or cancel them first.")
            }
            for job in running { try await runner.cancel(moduleID: moduleID, lectureID: job.lectureID, jobID: job.jobID) }
        }
        try await store.setModuleArchived(moduleID: moduleID, archived: true)
        try await reloadNow()
        for window in lectureWindows.values where window.ref.moduleID == moduleID { await window.reloadAfterExternalChange() }
    }

    func unarchive(moduleID: UUID) async throws {
        try await store.setModuleArchived(moduleID: moduleID, archived: false)
        try await reloadNow()
        for window in lectureWindows.values where window.ref.moduleID == moduleID { await window.reloadAfterExternalChange() }
    }

    // MARK: Settings

    func updateSettings(_ new: AISettings) async throws {
        try await settingsStore.save(new)
        settings = new
        providerConfiguration.update(new)
    }

    func refreshAPIKeyState() {
        apiKeySaved = ((try? keychain.loadAPIKey()) ?? nil) != nil
    }

    var cliExecutable: URL { ClaudeCLIProvider.resolveExecutable(configuredPath: settings.claudeCLIPath) }
    var cliFound: Bool { FileManager.default.isExecutableFile(atPath: cliExecutable.path) }

    /// Short status for the sidebar footer. CLI login itself is checked by the provider at call time.
    var backendStatus: (text: String, ready: Bool) {
        switch settings.backend {
        case .claudeCLI: cliFound ? ("Claude CLI found", true) : ("Claude CLI not found", false)
        case .messagesAPI: apiKeySaved ? ("Anthropic API key saved", true) : ("API key missing", false)
        }
    }

    // MARK: Lecture windows

    func register(_ window: LectureWindowModel) { lectureWindows[window.ref.lectureID] = window }
    func unregister(_ window: LectureWindowModel) {
        if lectureWindows[window.ref.lectureID] === window { lectureWindows.removeValue(forKey: window.ref.lectureID) }
    }
    var hasOpenLectureWindows: Bool { !lectureWindows.isEmpty }

    /// Application termination: every window must save before the app may quit.
    func closeAllLectureWindows() async -> Bool {
        var failures: [String] = []
        for window in Array(lectureWindows.values) {
            do { try await window.closeAndFlush() }
            catch { failures.append("\(window.session.lecture.name): \(error.localizedDescription)") }
        }
        if !failures.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Some edits could not be saved"
            alert.informativeText = failures.joined(separator: "\n") + "\n\nLectern stays open so nothing is lost."
            alert.runModal()
            return false
        }
        return true
    }

    /// Keep the workspace visible if saving fails; navigation must never discard edits.
    func returnToLibrary(destination: SidebarItem? = nil) async {
        guard !leavingLecture else { return }
        leavingLecture = true
        defer { leavingLecture = false }
        do {
            if let ref = activeLecture, let workspace = lectureWindows[ref.lectureID] {
                try await workspace.closeAndFlush()
            }
            if let ref = activeLecture { requestedModes.removeValue(forKey: ref.lectureID) }
            activeLecture = nil
            if let destination { selection = destination }
            scheduleReload()
        } catch {
            errorMessage = "Your edits could not be saved. The lecture stays open. \(error.localizedDescription)"
        }
    }

    func openLecture(_ ref: LectureRef, mode: LectureMode?) {
        if let mode { requestedModes[ref.lectureID] = mode }
        activeLecture = ref
    }
}
