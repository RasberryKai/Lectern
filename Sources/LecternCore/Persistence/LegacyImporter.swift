import Foundation
import CryptoKit
import PDFKit

public struct MigrationFailure: Sendable, Equatable {
    public var source: String
    public var message: String
    public init(source: String, message: String) { self.source = source; self.message = message }
}
public struct MigrationReport: Sendable {
    public var source: URL?
    public var imported: [UUID] = []
    public var skipped: [UUID] = []
    public var failures: [MigrationFailure] = []
    public init() {}
}

/// Explicit, read-only migration. IDs include the source library path so unrelated libraries never collide.
public struct LegacyImporter: Sendable {
    public let store: LibraryStore
    public init(store: LibraryStore) { self.store = store }
    public func importProjects(from root: URL) async -> MigrationReport {
        var report = MigrationReport()
        let projects = root.lastPathComponent == "Projects" ? root : root.appendingPathComponent("Projects")
        report.source = projects
        do {
            let entries = try FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            let moduleID = Self.stableID("projects-module:" + projects.resolvingSymlinksInPath().path)
            _ = try await store.createModule(Module(id: moduleID, name: "Imported Slide Learning"))
            for directory in entries where UUID(uuidString: directory.lastPathComponent) != nil {
                do {
                    let id = Self.stableID("project:" + directory.resolvingSymlinksInPath().path)
                    if try await store.lectures(in: moduleID).contains(where: { $0.id == id }) { report.skipped.append(id); continue }
                    let source = directory.appendingPathComponent("source.pdf")
                    let metadata = directory.appendingPathComponent("project.json")
                    let lecture: Lecture
                    let provenance: Data
                    if FileManager.default.fileExists(atPath: metadata.path) || FileManager.default.fileExists(atPath: metadata.appendingPathExtension("bak").path) {
                        let decoded: (LegacyProject, Data) = try Self.readLegacy(metadata) { data in
                            let project = try LibraryStore.decoder().decode(LegacyProject.self, from: data)
                            guard project.schemaVersion == 1 else { throw LibraryError.unsupportedSchema(project.schemaVersion) }
                            guard project.id == UUID(uuidString: directory.lastPathComponent) else { throw LibraryError.invalid("Project ID does not match its folder.") }
                            return project
                        }
                        let project = decoded.0; provenance = decoded.1
                        lecture = Lecture(id: id, moduleID: moduleID, name: project.name, sourceFilename: project.sourceFilename, pageCount: project.pageCount, createdAt: project.createdAt, updatedAt: project.updatedAt, slides: project.slides, viewPreferences: project.viewPreferences.value)
                    } else {
                        guard let pdf = PDFDocument(url: source), !pdf.isLocked, pdf.pageCount > 0 else { throw LibraryError.invalid("Project has neither valid metadata nor a readable PDF.") }
                        lecture = Lecture(id: id, moduleID: moduleID, name: directory.lastPathComponent, sourceFilename: "source.pdf", pageCount: pdf.pageCount)
                        provenance = try JSONSerialization.data(withJSONObject: ["sourcePath": directory.path, "originalProjectID": directory.lastPathComponent, "metadataMissing": true], options: [.sortedKeys])
                    }
                    try await store.saveLegacyProvenance(provenance, moduleID: moduleID, lectureID: id)
                    _ = try await store.createLecture(lecture, sourceURL: source)
                    report.imported.append(id)
                } catch { report.failures.append(MigrationFailure(source: directory.path, message: error.localizedDescription)) }
            }
        } catch { report.failures.append(MigrationFailure(source: projects.path, message: error.localizedDescription)) }
        return report
    }
    /// Accepts a sessions.json archive, a directory containing it, or a single Reviewer backup.
    public func importReviewer(from input: URL) async -> MigrationReport {
        var report = MigrationReport()
        var isDirectory: ObjCBool = false
        _ = FileManager.default.fileExists(atPath: input.path, isDirectory: &isDirectory)
        let source = isDirectory.boolValue ? input.appendingPathComponent("sessions.json") : input
        report.source = source
        do {
            let parsed: ([String: Any], Data) = try Self.readLegacy(source) { data in
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw LibraryError.invalid("Reviewer backup must be a JSON object.") }
                guard let version = object["schemaVersion"] as? Int else { throw LibraryError.invalid("Reviewer backup lacks its schema version.") }
                guard version == 1 else { throw LibraryError.unsupportedSchema(version) }
                guard object["sessions"] is [Any] || object["session"] is [String: Any] else { throw LibraryError.invalid("Reviewer backup has no sessions.") }
                return object
            }
            let object = parsed.0
            // UUID-key dictionaries use the Codable alternating-key array representation.
            var tombstones: [UUID: Date] = [:]
            if let raw = object["deletedSessionIDs"] {
                let data = try JSONSerialization.data(withJSONObject: raw, options: [.fragmentsAllowed])
                tombstones = try LibraryStore.decoder().decode([UUID: Date].self, from: data)
            }
            let sessions = (object["sessions"] as? [Any]) ?? [object["session"]!]
            let moduleID = Self.stableID("reviewer-module:" + source.resolvingSymlinksInPath().path)
            _ = try await store.createModule(Module(id: moduleID, name: "Imported Flashcard Reviewer"))
            for (index, raw) in sessions.enumerated() {
                do {
                    let rawData = try JSONSerialization.data(withJSONObject: raw)
                    let session = try LibraryStore.decoder().decode(FlashcardSession.self, from: rawData)
                    if tombstones[session.id] != nil { report.skipped.append(session.id); continue }
                    try session.validate()
                    let id = Self.stableID("reviewer:" + source.resolvingSymlinksInPath().path + ":" + session.id.uuidString)
                    if try await store.lectures(in: moduleID).contains(where: { $0.id == id }) { report.skipped.append(id); continue }
                    var cards = session.cards.map { old in
                        var history = [CardRevision(id: Self.stableID(id.uuidString + old.id.uuidString + ":original"), front: old.originalFront, back: old.originalBack, author: .user, reason: "Legacy import", at: session.createdAt)]
                        if old.front != old.originalFront || old.back != old.originalBack { history.append(CardRevision(id: Self.stableID(id.uuidString + old.id.uuidString + ":current"), front: old.front, back: old.back, author: .user, reason: "Legacy edited version", at: session.updatedAt)) }
                        return Card(id: old.id, front: old.front, back: old.back, verdict: old.verdict, feedback: old.notes, issue: old.issue.map { CardIssue(kind: .importSyntax, message: $0.message) }, mathInterpretations: old.mathInterpretations, history: history)
                    }
                    // New validation is stricter than the legacy approval gate (notably math).
                    // Retain the original verdict in provenance, while keeping the imported lecture usable.
                    let validationContext = Lecture(moduleID: moduleID, name: session.title)
                    for c in cards.indices where cards[c].verdict == .good && !validationContext.issues(for: cards[c]).isEmpty {
                        cards[c].verdict = .unreviewed
                        cards[c].flag = "Imported approval needs re-review under Lectern validation."
                    }
                    let preferences = ViewPreferences(selectedCardID: session.selectedCardID, reviewFilter: ReviewFilter(rawValue: session.reviewFilter) ?? .all, mode: .review)
                    let lecture = Lecture(id: id, moduleID: moduleID, name: session.title, createdAt: session.createdAt, updatedAt: session.updatedAt, cards: cards, viewPreferences: preferences)
                    // Scope provenance to this session: sharing one lecture backup must not expose
                    // unrelated sessions from the source archive. Preserve all raw session fields.
                    let provenance = try JSONSerialization.data(withJSONObject: [
                        "schemaVersion": 1, "session": raw, "sourcePath": source.path
                    ], options: [.sortedKeys])
                    try await store.saveLegacyProvenance(provenance, moduleID: moduleID, lectureID: id)
                    _ = try await store.createLecture(lecture)
                    report.imported.append(id)
                } catch { report.failures.append(MigrationFailure(source: source.path + " session[\(index)]", message: error.localizedDescription)) }
            }
        } catch { report.failures.append(MigrationFailure(source: source.path, message: error.localizedDescription)) }
        return report
    }
    static func stableID(_ text: String) -> UUID {
        let bytes = Array(SHA256.hash(data: Data(text.utf8)).prefix(16))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], (bytes[6] & 0x0f) | 0x50, bytes[7], (bytes[8] & 0x3f) | 0x80, bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
    private static func readLegacy<T>(_ url: URL, decode: (Data) throws -> T) throws -> (T, Data) {
        do {
            let data = try Data(contentsOf: url)
            if let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let version = object["schemaVersion"] as? Int, version != 1 { throw LibraryError.unsupportedSchema(version) }
            return (try decode(data), data)
        }
        catch LibraryError.unsupportedSchema(let version) { throw LibraryError.unsupportedSchema(version) }
        catch {
            let backup = url.appendingPathExtension("bak")
            guard FileManager.default.fileExists(atPath: backup.path) else { throw error }
            let data = try Data(contentsOf: backup); return (try decode(data), data)
        }
    }
}

private struct LegacyProject: Decodable {
    var schemaVersion: Int
    var id: UUID
    var name: String
    var sourceFilename: String
    var pageCount: Int
    var createdAt: Date
    var updatedAt: Date
    var slides: [SlideState]
    var viewPreferences: LegacyPreferences
}
private struct LegacyPreferences: Decodable {
    var value: ViewPreferences
    enum CodingKeys: String, CodingKey { case focusedPageIndex, inspectorVisible, sidebarVisible, thumbnailSize, filter }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        value = ViewPreferences(focusedPageIndex: try values.decodeIfPresent(Int.self, forKey: .focusedPageIndex), inspectorVisible: try values.decodeIfPresent(Bool.self, forKey: .inspectorVisible) ?? true, sidebarVisible: try values.decodeIfPresent(Bool.self, forKey: .sidebarVisible) ?? true, thumbnailSize: try values.decodeIfPresent(ThumbnailSize.self, forKey: .thumbnailSize) ?? .regular, filter: try values.decodeIfPresent(SlideFilter.self, forKey: .filter) ?? .all)
    }
}
