import Foundation
import Testing
@testable import LecternCore

struct LibrarySessionLockTests {
    @Test func duplicateSessionIsBlockedUntilOwnerExits() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lectern-session-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        var owner: LibrarySessionLock? = try LibrarySessionLock(rootURL: root)
        _ = withExtendedLifetime(owner) {
            #expect(throws: LibraryError.self) { try LibrarySessionLock(rootURL: root) }
        }
        owner = nil
        let reopened = try LibrarySessionLock(rootURL: root)
        _ = withExtendedLifetime(reopened) {
            #expect(throws: LibraryError.self) { try LibrarySessionLock(rootURL: root) }
        }
    }

    @Test func separateLibrariesCanRunTogether() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lectern-sessions-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try LibrarySessionLock(rootURL: root.appendingPathComponent("first"))
        let second = try LibrarySessionLock(rootURL: root.appendingPathComponent("second"))
        withExtendedLifetime((first, second)) {}
    }
}
