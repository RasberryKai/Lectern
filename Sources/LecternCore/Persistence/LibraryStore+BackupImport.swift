import Darwin
import Foundation
import PDFKit

public struct LibraryBackupRestore: Sendable {
    public let preferences: Data
    /// The previous library will be at this path once the restore finishes.
    public let previousLibrary: URL
}

extension LibraryStore {
    /// Validate the ZIP in a private sibling directory. Publication happens on the next app startup.
    @concurrent public nonisolated func stageLibraryBackupImport(from url: URL) async throws {
        let files = FileManager.default
        let parent = backupImportRoot.deletingLastPathComponent()
        let work = parent.appendingPathComponent(".lectern-backup-\(UUID())", isDirectory: true)
        try files.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: work) }

        let archive = work.appendingPathComponent("Backup.zip")
        let extracted = work.appendingPathComponent("Extracted", isDirectory: true)
        guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw LibraryError.invalid("Choose a ZIP from Lectern’s Download Backup.")
        }
        try files.copyItem(at: url, to: archive)
        try files.createDirectory(at: extracted, withIntermediateDirectories: false)

        // bsdtar accepts several formats. Check the ZIP directory separately before extracting.
        try Self.runBackupArchiveTool("/usr/bin/unzip", ["-Z", "-t", archive.path])
        // Keep bsdtar's default path and symlink protections. Ignore archived permissions and metadata.
        try Self.runBackupArchiveTool("/usr/bin/tar", [
            "-x", "-k", "-f", archive.path, "-C", extracted.path,
            "--no-same-owner", "--no-same-permissions", "--no-acls", "--no-fflags",
            "--no-mac-metadata", "--no-xattrs"
        ])

        try Self.secureBackupTree(at: extracted)
        try Self.requireBackupChildren(["Lectern"], in: extracted)
        let payload = extracted.appendingPathComponent("Lectern", isDirectory: true)
        try Self.requireBackupChildren(["Library", "Preferences.plist"], in: payload)
        let replacement = payload.appendingPathComponent("Library", isDirectory: true)
        let preferences = payload.appendingPathComponent("Preferences.plist")
        _ = try Self.readBackupPreferences(at: preferences)
        let replacementInfo = try Self.backupItemInfo(at: replacement)
        guard replacementInfo.st_mode & S_IFMT == S_IFDIR,
              try Self.backupLockNames.allSatisfy({ try !Self.backupItemExists(at: replacement.appendingPathComponent($0)) }) else {
            throw LibraryError.invalid("The ZIP does not contain a valid Lectern library.")
        }

        let candidate = LibraryStore(rootURL: replacement)
        try await candidate.recoverPendingExports()
        try await candidate.validateBackupLibrary()
        try files.removeItem(at: replacement.appendingPathComponent(".library.lock"))
        try files.moveItem(at: preferences, to: payload.appendingPathComponent(".imported-preferences.plist"))
        let receipt = LibraryBackupImportReceipt(id: UUID(), replacementInode: replacementInfo.st_ino)
        try JSONEncoder().encode(receipt).write(to: payload.appendingPathComponent(".receipt.json"), options: .atomic)
        try Task.checkCancellation()
        try Self.renameBackupItem(from: payload, to: pendingBackupImport, flags: UInt32(RENAME_EXCL))
    }

    /// Call with the library session lock held, before opening any live lecture or starting jobs.
    /// Until finish succeeds, subsequent launches receive the same preferences and retained library path.
    public func restorePendingLibraryBackup(previousPreferences: Data) throws -> LibraryBackupRestore? {
        let pending = pendingBackupImport
        guard try Self.backupItemExists(at: pending) else { return nil }
        return try locked {
            let receipt = try LibraryBackupImportReceipt.load(from: pending)
            let preferences = try Self.readBackupPreferences(at: pending.appendingPathComponent(".imported-preferences.plist"))
            let root = backupImportRoot
            if try Self.backupItemInfo(at: root).st_ino != receipt.replacementInode {
                let replacement = pending.appendingPathComponent("Library", isDirectory: true)
                guard try Self.backupItemInfo(at: replacement).st_ino == receipt.replacementInode else {
                    throw LibraryError.invalid("The staged Lectern library for this import is missing.")
                }
                // Write the rollback preferences before moving the current library out of place.
                try previousPreferences.write(to: pending.appendingPathComponent("Preferences.plist"), options: .atomic)
                for name in Self.backupLockNames {
                    try Self.linkBackupLock(from: root.appendingPathComponent(name), to: replacement.appendingPathComponent(name))
                }
                // Both library paths name the same lock inodes throughout the swap.
                try Self.renameBackupItem(from: root, to: replacement, flags: UInt32(RENAME_SWAP))
            }
            return LibraryBackupRestore(preferences: preferences,
                                        previousLibrary: retainedLibraryFolder(for: receipt).appendingPathComponent("Library", isDirectory: true))
        }
    }

    /// Call after saving the restored preferences, while still holding the library session lock.
    public func finishPendingLibraryBackupImport() throws {
        let pending = pendingBackupImport
        guard try Self.backupItemExists(at: pending) else { return }
        try locked {
            let receipt = try LibraryBackupImportReceipt.load(from: pending)
            guard try Self.backupItemInfo(at: backupImportRoot).st_ino == receipt.replacementInode else {
                throw LibraryError.invalid("The staged library must be restored before finishing the import.")
            }
            let retained = retainedLibraryFolder(for: receipt)
            try Self.renameBackupItem(from: pending, to: retained, flags: UInt32(RENAME_EXCL))
            for name in [".receipt.json", ".imported-preferences.plist", "Library/.library.lock", "Library/.session.lock"] {
                try? FileManager.default.removeItem(at: retained.appendingPathComponent(name))
            }
        }
    }

    private nonisolated var backupImportRoot: URL {
        rootURL.standardizedFileURL.resolvingSymlinksInPath()
    }

    private nonisolated var pendingBackupImport: URL {
        let root = backupImportRoot
        return root.deletingLastPathComponent().appendingPathComponent(".\(root.lastPathComponent)-backup-import", isDirectory: true)
    }

    private func retainedLibraryFolder(for receipt: LibraryBackupImportReceipt) -> URL {
        let root = backupImportRoot
        return root.deletingLastPathComponent()
            .appendingPathComponent("\(root.lastPathComponent) Before Import \(receipt.id)", isDirectory: true)
    }

    private static let backupLockNames = [".session.lock", ".library.lock"]

    // This store is rooted in the private extraction directory and cannot have other clients.
    private func validateBackupLibrary() throws {
        if FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("rules.md").path) {
            _ = try String(contentsOf: rootURL.appendingPathComponent("rules.md"), encoding: .utf8)
        }
        let preferences = try studyPreferences()
        for module in try modulesUnlocked() {
            let directory = moduleDirectory(module.id)
            let journalURL = directory.appendingPathComponent(StudyJournal.journalName)
            if FileManager.default.fileExists(atPath: journalURL.path) {
                let journal = try Data(contentsOf: journalURL)
                if let end = journal.lastIndex(of: 0x0a) {
                    _ = try StudyJournal.replay(journal.prefix(through: end))
                }
            }
            let overrides: StudyOverrides? = try readStudyPreferences(studyOverridesURL(in: directory))
            try overrides?.applying(to: preferences.defaults).validated()
            for lecture in try lectureListUnlocked(in: module) {
                let source = sourceURL(moduleID: module.id, lectureID: lecture.id)
                if lecture.pageCount > 0 || FileManager.default.fileExists(atPath: source.path) {
                    guard let pdf = PDFDocument(url: source), !pdf.isLocked, pdf.pageCount == lecture.pageCount else {
                        throw LibraryError.invalid("The backup PDF for “\(lecture.name)” is missing or invalid.")
                    }
                }
                try validateAttachmentFiles(for: lecture)
            }
        }
    }

    private static func runBackupArchiveTool(_ path: String, _ arguments: [String]) throws {
        let process = Process()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = [:]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        try process.run()
        let diagnostics = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, diagnostics.isEmpty else {
            throw LibraryError.invalid("The ZIP could not be read as a Lectern backup.")
        }
    }

    private static func secureBackupTree(at url: URL) throws {
        let info = try backupItemInfo(at: url)
        switch info.st_mode & S_IFMT {
        case S_IFDIR:
            guard chmod(url.path, 0o700) == 0 else { throw backupPOSIXError(at: url) }
            for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                try secureBackupTree(at: child)
            }
        case S_IFREG where info.st_nlink == 1:
            guard chmod(url.path, 0o600) == 0 else { throw backupPOSIXError(at: url) }
        default:
            throw LibraryError.invalid("A Lectern backup may contain only regular files and directories.")
        }
    }

    private static func requireBackupChildren(_ names: Set<String>, in directory: URL) throws {
        let children = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        guard Set(children.map(\.lastPathComponent)) == names else {
            throw LibraryError.invalid("Choose a ZIP from Lectern’s Download Backup.")
        }
    }

    private static func readBackupPreferences(at url: URL) throws -> Data {
        guard try backupItemInfo(at: url).st_mode & S_IFMT == S_IFREG else {
            throw LibraryError.invalid("The backup’s preferences file is invalid.")
        }
        let data = try Data(contentsOf: url)
        guard (try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]) != nil else {
            throw LibraryError.invalid("The backup’s preferences file is invalid.")
        }
        return data
    }

    private static func backupItemInfo(at url: URL) throws -> stat {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw backupPOSIXError(at: url) }
        return info
    }

    private static func backupItemExists(at url: URL) throws -> Bool {
        var info = stat()
        guard lstat(url.path, &info) != 0 else { return true }
        if errno == ENOENT { return false }
        throw backupPOSIXError(at: url)
    }

    private static func linkBackupLock(from src: URL, to dst: URL) throws {
        let source = try backupItemInfo(at: src)
        guard source.st_mode & S_IFMT == S_IFREG else {
            throw LibraryError.invalid("The current library lock is invalid.")
        }
        if link(src.path, dst.path) == 0 { return }
        guard errno == EEXIST else { throw backupPOSIXError(at: dst) }
        let previous = try backupItemInfo(at: dst)
        guard source.st_dev == previous.st_dev, source.st_ino == previous.st_ino else {
            throw LibraryError.invalid("The current library lock changed before the import could finish.")
        }
    }

    private static func renameBackupItem(from src: URL, to dst: URL, flags: UInt32) throws {
        guard renamex_np(src.path, dst.path, flags) == 0 else { throw backupPOSIXError(at: dst) }
    }

    private static func backupPOSIXError(at url: URL) -> NSError {
        let code = errno
        return NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: url.path])
    }
}

private struct LibraryBackupImportReceipt: Codable {
    let id: UUID
    let replacementInode: UInt64

    static func load(from folder: URL) throws -> Self {
        try JSONDecoder().decode(Self.self, from: Data(contentsOf: folder.appendingPathComponent(".receipt.json")))
    }
}
