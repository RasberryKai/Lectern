import Darwin
import Foundation

/// Held for the lifetime of an app or CLI job session. The short transaction lock
/// in LibraryStore cannot protect startup recovery from another live job runner.
public final class LibrarySessionLock: Sendable {
    private let descriptor: Int32

    public init(rootURL: URL) throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let descriptor = open(rootURL.appendingPathComponent(".session.lock").path,
                              O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw LibraryError.unavailable("Cannot open the library session lock.") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw LibraryError.unavailable("Another copy of Lectern is using this library. Quit the other copy, then reopen Lectern.")
        }
        self.descriptor = descriptor
    }

    deinit { close(descriptor) }
}
