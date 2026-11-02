import Foundation
import PDFKit
import CryptoKit
import Darwin

public enum LibraryError: Error, LocalizedError, Sendable {
    case unsupportedSchema(Int), invalid(String), unavailable(String), alreadyExists(UUID), archivedModule(UUID)
    public var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version): "Unsupported library schema \(version)."
        case .invalid(let message), .unavailable(let message): message
        case .alreadyExists(let id): "Lecture \(id) already exists."
        case .archivedModule: "This module is archived and read-only. Unarchive it before making changes."
        }
    }
}

/// All read-modify-write operations hold a process-wide advisory lock in addition to actor isolation.
public actor LibraryStore {
    public nonisolated let rootURL: URL
    public init(rootURL: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Lectern/Library", isDirectory: true)) { self.rootURL = rootURL }
    public nonisolated func sourceURL(moduleID: UUID, lectureID: UUID) -> URL { lectureDirectory(moduleID, lectureID).appendingPathComponent("source.pdf") }
    public nonisolated func jobDirectory(moduleID: UUID, lectureID: UUID, jobID: UUID) -> URL { lectureDirectory(moduleID, lectureID).appendingPathComponent("jobs/\(jobID.uuidString)", isDirectory: true) }
    nonisolated func moduleDirectory(_ id: UUID) -> URL { rootURL.appendingPathComponent("Modules/\(id.uuidString)", isDirectory: true) }
    nonisolated func lectureDirectory(_ module: UUID, _ lecture: UUID) -> URL { moduleDirectory(module).appendingPathComponent("Lectures/\(lecture.uuidString)", isDirectory: true) }
    private func locked<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let fd = open(rootURL.appendingPathComponent(".library.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw LibraryError.unavailable("Cannot open library lock.") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw LibraryError.unavailable("Cannot lock library.") }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
    public func modules() throws -> [Module] { try locked { try modulesUnlocked() } }
    private func modulesUnlocked() throws -> [Module] {
        try directories(rootURL.appendingPathComponent("Modules")).map { directory in
            guard let id = UUID(uuidString: directory.lastPathComponent) else { throw LibraryError.invalid("Invalid module directory identity.") }
            return try moduleUnlocked(id)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    /// A single lock makes all Overview totals describe the same library snapshot.
    public func dashboard(now: Date = Date(), timeZone: TimeZone = .current) throws -> DashboardSnapshot { try locked {
        let modules = try modulesUnlocked()
        let lectures = try modules.flatMap { module in try module.lectureIDs.map { try readLecture(module.id, $0) } }
        return DashboardBuilder.build(modules: modules, lectures: lectures, now: now, timeZone: timeZone)
    } }
    public func loadModule(moduleID: UUID) throws -> Module { try locked { try moduleUnlocked(moduleID) } }
    private func moduleUnlocked(_ id: UUID) throws -> Module {
        let url = moduleDirectory(id).appendingPathComponent("module.json")
        var module: Module = try read(url)
        guard module.id == id else { throw LibraryError.invalid("Module identity does not match its directory.") }
        let ids = try lectureFiles(id).map { try readLecture(id, $0) }.map(\.id)
        guard Set(module.lectureIDs).count == module.lectureIDs.count,
              Set(module.lectureIDs).isSubset(of: Set(ids)) else { throw LibraryError.invalid("A module references duplicate or missing lecture metadata.") }
        let original = module
        module.lectureIDs += ids.filter { !module.lectureIDs.contains($0) }.sorted { $0.uuidString < $1.uuidString }
        module.plannedLectureCount = max(module.plannedLectureCount, module.lectureIDs.count)
        // Repair interrupted publication or pre-planning metadata without changing user order.
        if module != original { try write(module, to: url) }
        return module
    }
    private func requireEditable(_ module: Module) throws {
        guard !module.isArchived else { throw LibraryError.archivedModule(module.id) }
    }
    /// An early guard for expensive job preparation; every durable mutation checks again under its lock.
    public func assertModuleEditable(moduleID: UUID) throws { try locked { try requireEditable(moduleUnlocked(moduleID)) } }
    private func validateModule(_ module: Module) throws {
        guard (0...Module.maximumPlannedLectureCount).contains(module.plannedLectureCount), module.plannedLectureCount >= module.lectureIDs.count, Set(module.lectureIDs).count == module.lectureIDs.count else {
            throw LibraryError.invalid("Planned lectures cannot be fewer than imported lectures, and lecture order must contain unique identities.")
        }
    }
    public func createModule(name: String, instructions: String = "") throws -> Module { try createModule(Module(name: name, instructions: instructions)) }
    public func createModule(_ module: Module) throws -> Module { try locked {
        let url = moduleDirectory(module.id).appendingPathComponent("module.json")
        if FileManager.default.fileExists(atPath: url.path) { return try moduleUnlocked(module.id) }
        try validateModule(module)
        guard module.lectureIDs.isEmpty else { throw LibraryError.invalid("Create an empty module, then import its lectures.") }
        try write(module, to: url); return module
    } }
    public func updateModule(_ module: Module) throws { try locked {
        let url = moduleDirectory(module.id).appendingPathComponent("module.json")
        let current = try moduleUnlocked(module.id)
        try requireEditable(current)
        guard module.archivedAt == current.archivedAt else { throw LibraryError.invalid("Use setModuleArchived to archive or unarchive a module.") }
        var updated = module
        guard Set(module.lectureIDs).count == module.lectureIDs.count, Set(module.lectureIDs).isSubset(of: Set(current.lectureIDs)) else { throw LibraryError.invalid("Lecture order contains duplicate or unknown identities.") }
        updated.lectureIDs = module.lectureIDs + current.lectureIDs.filter { !module.lectureIDs.contains($0) }
        // This compatibility API edits metadata/order. Planning belongs to the narrow
        // settings operation, so a cached pre-import Module cannot erase a newer plan.
        updated.plannedLectureCount = current.plannedLectureCount
        updated.examDate = current.examDate
        try validateModule(updated)
        try write(updated, to: url)
    } }
    /// Narrow settings update preserves instruction/order/archive changes from other windows.
    @discardableResult public func updateModuleSettings(moduleID: UUID, name: String, plannedLectureCount: Int, examDate: ExamDate?) throws -> Module { try locked {
        var module = try moduleUnlocked(moduleID); try requireEditable(module)
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw LibraryError.invalid("Give the module a name.") }
        module.name = name; module.plannedLectureCount = plannedLectureCount; module.examDate = examDate
        try validateModule(module)
        try write(module, to: moduleDirectory(moduleID).appendingPathComponent("module.json")); return module
    } }
    /// Archiving does not cancel or discard paid work. Wait/cancel and retry when idle.
    @discardableResult public func setModuleArchived(moduleID: UUID, archived: Bool, at: Date = Date()) throws -> Module { try locked {
        var module = try moduleUnlocked(moduleID)
        if module.isArchived == archived { return module }
        if archived {
            let hasJobs = try module.lectureIDs.contains { id in try readLecture(moduleID, id).jobs.contains { $0.state == .running } }
            guard !hasJobs else { throw LibraryError.invalid("Wait for this module's running jobs, or cancel them before archiving.") }
        }
        module.archivedAt = archived ? at : nil
        try write(module, to: moduleDirectory(moduleID).appendingPathComponent("module.json")); return module
    } }
    public func appendModuleInstruction(moduleID: UUID, text: String) throws { try locked {
        let url = moduleDirectory(moduleID).appendingPathComponent("module.json")
        var module = try moduleUnlocked(moduleID); try requireEditable(module)
        module.instructions += (module.instructions.isEmpty ? "" : "\n") + text
        try write(module, to: url)
    } }
    public func lectures(in moduleID: UUID) throws -> [Lecture] { try locked {
        let module = try moduleUnlocked(moduleID)
        let ids = try lectureFiles(moduleID)
        guard Set(module.lectureIDs).isSubset(of: Set(ids)) else { throw LibraryError.invalid("A module references missing lecture metadata.") }
        let ordered = module.lectureIDs + ids.filter { !module.lectureIDs.contains($0) }.sorted { $0.uuidString < $1.uuidString }
        return try ordered.map { try readLecture(moduleID, $0) }
    } }
    public func loadLecture(moduleID: UUID, lectureID: UUID) throws -> Lecture { try locked { try readLecture(moduleID, lectureID) } }
    public func updateLecture(moduleID: UUID, lectureID: UUID, _ mutation: @Sendable (inout Lecture) throws -> Void) throws -> Lecture {
        try transaction(moduleID: moduleID, lectureID: lectureID, mutation).lecture
    }
    /// Returns caller-owned state alongside the durable lecture, under one read/modify/write lock.
    public func transaction<Result: Sendable>(moduleID: UUID, lectureID: UUID,
        _ mutation: @Sendable (inout Lecture) throws -> Result) throws -> (lecture: Lecture, result: Result) {
        try locked {
            try requireEditable(moduleUnlocked(moduleID))
            var lecture = try readLecture(moduleID, lectureID)
            let result = try mutation(&lecture)
            guard lecture.id == lectureID, lecture.moduleID == moduleID else { throw LibraryError.invalid("Lecture identity cannot change.") }
            lecture.updatedAt = Date(); try validate(lecture)
            try write(lecture, to: lectureDirectory(moduleID, lectureID).appendingPathComponent("lecture.json"))
            return (lecture, result)
        }
    }
    public nonisolated func assertExternalDestination(_ url: URL) throws {
        func canonical(_ value: URL) -> String {
            var ancestor = value.standardizedFileURL
            var missing: [String] = []
            while !FileManager.default.fileExists(atPath: ancestor.path) && ancestor.path != "/" {
                missing.append(ancestor.lastPathComponent); ancestor.deleteLastPathComponent()
            }
            var resolved = ancestor.resolvingSymlinksInPath()
            for component in missing.reversed() { resolved.appendPathComponent(component) }
            return resolved.standardizedFileURL.path
        }
        let root = canonical(rootURL)
        let destination = canonical(url)
        guard url.isFileURL, destination != root, !destination.hasPrefix(root + "/") else {
            throw LibraryError.invalid("Choose an export destination outside Lectern's managed library.")
        }
    }
    public func createLecture(_ lecture: Lecture, sourceURL: URL? = nil) throws -> Lecture { try locked { try createLectureUnlocked(lecture, sourceURL: sourceURL) } }
    private func createLectureUnlocked(_ lecture: Lecture, sourceURL: URL?) throws -> Lecture {
        try validate(lecture)
        let moduleURL = moduleDirectory(lecture.moduleID).appendingPathComponent("module.json")
        var module = try moduleUnlocked(lecture.moduleID)
        try requireEditable(module)
        let directory = lectureDirectory(lecture.moduleID, lecture.id)
        guard !FileManager.default.fileExists(atPath: directory.appendingPathComponent("lecture.json").path) else { throw LibraryError.alreadyExists(lecture.id) }
        guard module.lectureIDs.count < Module.maximumPlannedLectureCount else { throw LibraryError.invalid("This module has reached its lecture limit.") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let sourceURL {
            let data = try Data(contentsOf: sourceURL)
            guard let pdf = PDFDocument(data: data), !pdf.isLocked, pdf.pageCount == lecture.pageCount else { throw LibraryError.invalid("PDF is unreadable or its page count differs from lecture metadata.") }
            try data.write(to: self.sourceURL(moduleID: lecture.moduleID, lectureID: lecture.id), options: .atomic)
        } else if lecture.pageCount > 0 && !FileManager.default.fileExists(atPath: self.sourceURL(moduleID: lecture.moduleID, lectureID: lecture.id).path) {
            throw LibraryError.invalid("A lecture with slides requires a source PDF.")
        }
        try write(lecture, to: directory.appendingPathComponent("lecture.json"))
        if !module.lectureIDs.contains(lecture.id) { module.lectureIDs.append(lecture.id) }
        module.plannedLectureCount = max(module.plannedLectureCount, module.lectureIDs.count)
        try write(module, to: moduleURL); return lecture
    }
    public func importPDF(from url: URL, moduleID: UUID) throws -> Lecture {
        let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let pdf = PDFDocument(url: url), !pdf.isLocked, pdf.pageCount > 0 else { throw LibraryError.invalid("The selected PDF is empty, locked or unreadable.") }
        return try createLecture(Lecture(moduleID: moduleID, name: url.deletingPathExtension().lastPathComponent, sourceFilename: url.lastPathComponent, pageCount: pdf.pageCount), sourceURL: url)
    }
    public func loadRules() throws -> String { try locked {
        let url = rootURL.appendingPathComponent("rules.md")
        if FileManager.default.fileExists(atPath: url.path) { return try String(contentsOf: url, encoding: .utf8) }
        guard let bundled = Bundle.module.url(forResource: "rules", withExtension: "md") else { throw LibraryError.unavailable("Bundled rules are missing.") }
        let rules = try String(contentsOf: bundled, encoding: .utf8)
        try Data(rules.utf8).write(to: url, options: .atomic); return rules
    } }
    @discardableResult public func saveRules(_ rules: String) throws -> String { try locked {
        try Data(rules.utf8).write(to: rootURL.appendingPathComponent("rules.md"), options: .atomic)
        return SHA256.hash(data: Data(rules.utf8)).map { String(format: "%02x", $0) }.joined()
    } }
    /// Raw source metadata preserves every legacy field, including import warnings and raw malformed lines.
    public func saveLegacyProvenance(_ data: Data, moduleID: UUID, lectureID: UUID) throws { try locked {
        try requireEditable(moduleUnlocked(moduleID))
        let url = lectureDirectory(moduleID, lectureID).appendingPathComponent("legacy-provenance.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) { try data.write(to: url, options: .atomic) }
    } }
    private struct Backup: Codable { var schemaVersion = 1; var module: Module; var lecture: Lecture; var sourcePDF: Data?; var provenance: Data? }
    public func exportBackup(moduleID: UUID, lectureID: UUID, to url: URL) throws {
        try assertExternalDestination(url)
        try locked {
        let lecture = try readLecture(moduleID, lectureID)
        let source = sourceURL(moduleID: moduleID, lectureID: lectureID)
        let provenance = lectureDirectory(moduleID, lectureID).appendingPathComponent("legacy-provenance.json")
        let backup = Backup(module: try read(moduleDirectory(moduleID).appendingPathComponent("module.json")), lecture: lecture, sourcePDF: FileManager.default.fileExists(atPath: source.path) ? try Data(contentsOf: source) : nil, provenance: FileManager.default.fileExists(atPath: provenance.path) ? try Data(contentsOf: provenance) : nil)
        if lecture.pageCount > 0 && backup.sourcePDF == nil { throw LibraryError.invalid("Source PDF is missing; backup would be incomplete.") }
        try Self.encoder().encode(backup).write(to: url, options: .atomic)
        }
    }
    public func restoreBackup(from url: URL) throws -> Lecture { try locked {
        let backup: Backup = try Self.decoder().decode(Backup.self, from: Data(contentsOf: url))
        guard backup.schemaVersion == 1 else { throw LibraryError.unsupportedSchema(backup.schemaVersion) }
        try validate(backup.lecture)
        guard backup.lecture.moduleID == backup.module.id else { throw LibraryError.invalid("Backup module identity mismatch.") }
        guard !backup.module.isArchived || !backup.lecture.jobs.contains(where: { $0.state == .running }) else { throw LibraryError.invalid("An archived backup cannot contain running jobs.") }
        let existing = lectureDirectory(backup.module.id, backup.lecture.id).appendingPathComponent("lecture.json")
        guard !FileManager.default.fileExists(atPath: existing.path) else { throw LibraryError.alreadyExists(backup.lecture.id) }
        let moduleURL = moduleDirectory(backup.module.id).appendingPathComponent("module.json")
        let createsModule = !FileManager.default.fileExists(atPath: moduleURL.path)
        if !createsModule { try requireEditable(moduleUnlocked(backup.module.id)) }
        if let data = backup.sourcePDF {
            guard let pdf = PDFDocument(data: data), !pdf.isLocked, pdf.pageCount == backup.lecture.pageCount else { throw LibraryError.invalid("Backup source PDF is invalid or has the wrong page count.") }
        } else if backup.lecture.pageCount > 0 { throw LibraryError.invalid("Backup source PDF is missing.") }
        if createsModule {
            // Stage the complete new module. Publishing an archived shell first would
            // make a failed restore impossible to retry without unarchiving it.
            var module = backup.module; module.lectureIDs = [backup.lecture.id]; try validateModule(module)
            let target = moduleDirectory(module.id)
            guard !FileManager.default.fileExists(atPath: target.path) else { throw LibraryError.alreadyExists(module.id) }
            let staging = rootURL.appendingPathComponent(".restore-lecture-module-\(UUID())")
            defer { try? FileManager.default.removeItem(at: staging) }
            let directory = staging.appendingPathComponent("Lectures/\(backup.lecture.id)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let data = backup.sourcePDF { try data.write(to: directory.appendingPathComponent("source.pdf"), options: .atomic) }
            if let provenance = backup.provenance { try provenance.write(to: directory.appendingPathComponent("legacy-provenance.json"), options: .atomic) }
            try write(backup.lecture, to: directory.appendingPathComponent("lecture.json"))
            try write(module, to: staging.appendingPathComponent("module.json"))
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: staging, to: target)
            return backup.lecture
        }
        let temporary = rootURL.appendingPathComponent(".restore-\(UUID()).pdf")
        defer { try? FileManager.default.removeItem(at: temporary) }
        if let data = backup.sourcePDF { try data.write(to: temporary, options: .atomic) }
        let directory = lectureDirectory(backup.lecture.moduleID, backup.lecture.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Publish provenance before the lecture so a crash cannot produce an apparently complete restore without it.
        if let provenance = backup.provenance { try provenance.write(to: directory.appendingPathComponent("legacy-provenance.json"), options: .atomic) }
        return try createLectureUnlocked(backup.lecture, sourceURL: backup.sourcePDF == nil ? nil : temporary)
    } }
    private struct ModuleBackup: Codable {
        var schemaVersion = 1
        var module: Module
        var lectures: [Backup]
    }
    public func exportModuleBackup(moduleID: UUID, to url: URL) throws {
        try assertExternalDestination(url)
        try locked {
            var module = try moduleUnlocked(moduleID)
            let ids = try lectureFiles(moduleID)
            guard Set(module.lectureIDs).isSubset(of: Set(ids)) else { throw LibraryError.invalid("Module references missing lectures.") }
            module.lectureIDs += ids.filter { !module.lectureIDs.contains($0) }.sorted { $0.uuidString < $1.uuidString }
            let backups = try module.lectureIDs.map { id -> Backup in
                let lecture = try readLecture(moduleID, id)
                let pdf = sourceURL(moduleID: moduleID, lectureID: id)
                let provenance = lectureDirectory(moduleID, id).appendingPathComponent("legacy-provenance.json")
                let data = FileManager.default.fileExists(atPath: pdf.path) ? try Data(contentsOf: pdf) : nil
                guard lecture.pageCount == 0 || data != nil else { throw LibraryError.invalid("Source PDF is missing; module backup would be incomplete.") }
                return Backup(module: module, lecture: lecture, sourcePDF: data,
                    provenance: FileManager.default.fileExists(atPath: provenance.path) ? try Data(contentsOf: provenance) : nil)
            }
            try Self.encoder().encode(ModuleBackup(module: module, lectures: backups)).write(to: url, options: .atomic)
        }
    }
    /// Publish a whole restored module with one directory rename, after validating every lecture/PDF.
    /// Existing module identities are refused; no current user data is replaced.
    public func restoreModuleBackup(from url: URL) throws -> Module { try locked {
        let backup = try Self.decoder().decode(ModuleBackup.self, from: Data(contentsOf: url))
        guard backup.schemaVersion == 1 else { throw LibraryError.unsupportedSchema(backup.schemaVersion) }
        let module = backup.module
        try validateModule(module)
        guard Set(module.lectureIDs).count == module.lectureIDs.count,
              Set(backup.lectures.map { $0.lecture.id }) == Set(module.lectureIDs),
              backup.lectures.count == module.lectureIDs.count else { throw LibraryError.invalid("Module backup lecture identities do not match its order.") }
        let target = moduleDirectory(module.id)
        guard !FileManager.default.fileExists(atPath: target.path) else { throw LibraryError.alreadyExists(module.id) }
        let staging = rootURL.appendingPathComponent(".restore-module-\(UUID())")
        defer { try? FileManager.default.removeItem(at: staging) }
        for entry in backup.lectures {
            guard entry.schemaVersion == 1, entry.module.id == module.id, entry.lecture.moduleID == module.id else { throw LibraryError.invalid("Mismatched module backup entry.") }
            guard !module.isArchived || !entry.lecture.jobs.contains(where: { $0.state == .running }) else { throw LibraryError.invalid("An archived backup cannot contain running jobs.") }
            try validate(entry.lecture)
            if entry.lecture.pageCount > 0 {
                guard let data = entry.sourcePDF, let pdf = PDFDocument(data: data), !pdf.isLocked,
                      pdf.pageCount == entry.lecture.pageCount else { throw LibraryError.invalid("Module backup source PDF is missing or invalid.") }
            }
            let directory = staging.appendingPathComponent("Lectures/\(entry.lecture.id)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let pdf = entry.sourcePDF { try pdf.write(to: directory.appendingPathComponent("source.pdf"), options: .atomic) }
            if let provenance = entry.provenance { try provenance.write(to: directory.appendingPathComponent("legacy-provenance.json"), options: .atomic) }
            try write(entry.lecture, to: directory.appendingPathComponent("lecture.json"))
        }
        try write(module, to: staging.appendingPathComponent("module.json"))
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: staging, to: target)
        return module
    } }
    private struct ExportJournal: Codable {
        var schemaVersion = 1
        var moduleID: UUID
        var entries: [ExportEntry]
        var at: Date
    }
    /// A write-ahead record makes multi-lecture export marking replayable after a crash.
    public func commitExport(moduleID: UUID, entries: [ExportEntry]) throws { try locked {
        let journal = ExportJournal(moduleID: moduleID, entries: entries, at: Date())
        let url = rootURL.appendingPathComponent("Exports/\(UUID()).json")
        try write(journal, to: url)
        try applyExport(journal)
        try FileManager.default.removeItem(at: url)
    } }
    public func recoverPendingExports() throws { try locked {
        let directory = rootURL.appendingPathComponent("Exports")
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter({ $0.pathExtension == "json" }) {
            let journal: ExportJournal = try read(url)
            guard journal.schemaVersion == 1 else { throw LibraryError.unsupportedSchema(journal.schemaVersion) }
            try applyExport(journal)
            try FileManager.default.removeItem(at: url)
        }
    } }
    private func applyExport(_ journal: ExportJournal) throws {
        for id in Set(journal.entries.map(\.lectureID)) {
            var lecture = try readLecture(journal.moduleID, id)
            let previousUpdatedAt = lecture.updatedAt
            try LectureReducer.reduce(&lecture, action: .markExportEntries(journal.entries), now: journal.at)
            lecture.updatedAt = max(previousUpdatedAt, journal.at)
            try write(lecture, to: lectureDirectory(journal.moduleID, id).appendingPathComponent("lecture.json"))
        }
    }
    private func directories(_ url: URL) throws -> [URL] {
        if !FileManager.default.fileExists(atPath: url.path) { return [] }
        return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]).filter { try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true }
    }
    private func lectureFiles(_ moduleID: UUID) throws -> [UUID] {
        try directories(moduleDirectory(moduleID).appendingPathComponent("Lectures")).compactMap { directory in
            let url = directory.appendingPathComponent("lecture.json")
            guard FileManager.default.fileExists(atPath: url.path) || FileManager.default.fileExists(atPath: url.appendingPathExtension("bak").path) else { return nil } // unpublished partial copy
            guard let id = UUID(uuidString: directory.lastPathComponent) else { throw LibraryError.invalid("Invalid lecture directory: \(directory.lastPathComponent)") }
            return id
        }
    }
    private func readLecture(_ module: UUID, _ id: UUID) throws -> Lecture {
        let lecture: Lecture = try read(lectureDirectory(module, id).appendingPathComponent("lecture.json"))
        try validate(lecture)
        guard lecture.id == id, lecture.moduleID == module else { throw LibraryError.invalid("Lecture identity does not match its directory.") }
        return lecture
    }
    private func validate(_ lecture: Lecture) throws {
        guard lecture.schemaVersion == Lecture.currentSchemaVersion else { throw LibraryError.unsupportedSchema(lecture.schemaVersion) }
        _ = try lecture.validated()
    }
    private func read<T: Decodable>(_ url: URL) throws -> T {
        func decode(_ data: Data) throws -> T {
            if let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let version = object["schemaVersion"] as? Int, version != 1 { throw LibraryError.unsupportedSchema(version) }
            let result = try Self.decoder().decode(T.self, from: data)
            if let lecture = result as? Lecture {
                try validate(lecture)
                let directory = url.deletingLastPathComponent()
                guard directory.lastPathComponent == lecture.id.uuidString,
                      directory.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == lecture.moduleID.uuidString else { throw LibraryError.invalid("Lecture identity does not match its directory.") }
            }
            if let module = result as? Module, url.deletingLastPathComponent().lastPathComponent != module.id.uuidString { throw LibraryError.invalid("Module identity does not match its directory.") }
            return result
        }
        do { return try decode(Data(contentsOf: url)) }
        catch LibraryError.unsupportedSchema(let version) { throw LibraryError.unsupportedSchema(version) }
        catch {
            let primaryError = error
            let backupURL = url.appendingPathExtension("bak")
            guard FileManager.default.fileExists(atPath: backupURL.path) else { throw primaryError }
            let backup = try Data(contentsOf: backupURL); let result = try decode(backup)
            // Keep the damaged primary for diagnosis; never rotate it over the valid backup.
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.copyItem(at: url, to: url.appendingPathExtension("corrupt-\(UUID())")) }
            try backup.write(to: url, options: .atomic); return result
        }
    }
    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try Self.encoder().encode(value)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path) { try Data(contentsOf: url).write(to: url.appendingPathExtension("bak"), options: .atomic) }
        try data.write(to: url, options: .atomic)
    }
    static func encoder() -> JSONEncoder { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601; return encoder }
    static func decoder() -> JSONDecoder { let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder }
}
