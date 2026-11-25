import Darwin
import Foundation

extension LibraryStore {
    /// Export the saved library tree and the app's preferences as a single ZIP.
    @concurrent public nonisolated func exportLibraryBackup(to destination: URL, preferences: Data) async throws {
        try assertExternalDestination(destination)
        let files = FileManager.default
        let staging = try files.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                    appropriateFor: destination, create: true)
        defer { try? files.removeItem(at: staging) }
        try assertExternalDestination(staging)
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: staging.path)

        let snapshot = staging.appendingPathComponent("Lectern", isDirectory: true)
        let library = snapshot.appendingPathComponent("Library", isDirectory: true)
        try files.createDirectory(at: library, withIntermediateDirectories: true)
        try await copyLibraryForBackup(to: library)
        try preferences.write(to: snapshot.appendingPathComponent("Preferences.plist"))

        let zip = staging.appendingPathComponent("Backup.zip")
        let archiver = Process()
        let errors = Pipe()
        archiver.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        archiver.arguments = ["-c", "-k", "--norsrc", "--keepParent", snapshot.path, zip.path]
        archiver.standardError = errors
        try archiver.run()
        let diagnostics = errors.fileHandleForReading.readDataToEndOfFile()
        archiver.waitUntilExit()
        guard archiver.terminationStatus == 0 else {
            let detail = String(decoding: diagnostics, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw LibraryError.unavailable(detail.isEmpty ? "Lectern couldn’t create the ZIP archive." : detail)
        }

        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: zip.path)
        try assertExternalDestination(destination)
        // The staging directory is on the destination volume, so publication is atomic.
        guard rename(zip.path, destination.path) == 0 else {
            let code = errno
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: destination.path])
        }
    }

    private func copyLibraryForBackup(to destination: URL) throws {
        try locked {
            let files = FileManager.default
            let entries = try files.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil)
            for entry in entries where entry.lastPathComponent != ".library.lock" && entry.lastPathComponent != ".session.lock" {
                try files.copyItem(at: entry, to: destination.appendingPathComponent(entry.lastPathComponent))
            }
        }
    }
}
