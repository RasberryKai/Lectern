import CryptoKit
import Darwin
import Foundation

public struct StudyReschedulePreview: Equatable, Sendable {
    public var count: Int { batches.values.reduce(0) { $0 + $1.changes.count } }

    let moduleID: UUID?
    let batches: [UUID: StudyRescheduleBatch]
}

struct StudyRescheduleBatch: Equatable, Sendable {
    let configuration: StudyConfiguration
    let changes: [UUID: StudyRescheduleChange]
    let solveIDs: Set<UUID>
    /// Non-nil schedule revisions for the changed cards. Missing IDs use the legacy schedule.
    let scheduleIDs: [UUID: UUID]
}

struct StudyRescheduleChange: Equatable, Sendable {
    let before: StudyMemoryState
    let after: StudyMemoryState
}

struct StudyJournalEvent: Codable {
    enum Source: String, Codable { case study, undo, reschedule, presentation }
    enum Payload: Codable {
        case grade(rating: StudyRating, answeringTime: TimeInterval, configuration: StudyConfiguration)
        case undo(gradeID: UUID)
        case reschedule(configuration: StudyConfiguration, cardIDs: [UUID], solveIDs: Set<UUID>? = nil,
                        scheduleIDs: [UUID: UUID]? = nil)
        case present(caseID: UUID, reusable: Bool? = nil)
    }

    static let modelVersion = "FSRS-6/Py-FSRS-6.3.2"

    var schemaVersion = 1
    var model = Self.modelVersion
    let id: UUID
    let cardID: UUID?
    /// The card's active Study schedule revision. Nil is the original, pre-conversion schedule.
    var studyScheduleID: UUID? = nil
    var epoch = 0
    let at: Date
    let studyDay: String
    let source: Source
    let payload: Payload
    var solveResponse: StudySolveResponse? = nil
}

struct StudyJournalState: Codable {
    struct Presentation: Codable {
        let cardID: UUID
        let caseID: UUID
        var studyScheduleID: UUID? = nil
    }

    struct Grade: Codable {
        let cardID: UUID
        var studyScheduleID: UUID? = nil
        let rating: StudyRating
        let studyDay: String
        let before: StudyMemoryState?
        let after: StudyMemoryState
        let previousChangeID: UUID?
        var solveResponse: StudySolveResponse? = nil
    }

    private struct ScheduleKey: Codable, Hashable {
        let cardID: UUID
        let studyScheduleID: UUID?
    }

    private var scheduleMemory: [ScheduleKey: StudyMemoryState] = [:]
    private(set) var introductions: [String: Int] = [:]
    private(set) var grades: [UUID: Grade] = [:]
    private(set) var undoneGrades: Set<UUID> = []
    private var latestChanges: [ScheduleKey: UUID] = [:]
    private var eventIDs: Set<UUID> = []
    private(set) var presentations: [UUID: Presentation]? = nil
    private(set) var seenSolveCases: [UUID: Set<UUID>]? = nil
    private var gradedPresentations: Set<UUID>? = nil

    func memory(for cardID: UUID, studyScheduleID: UUID?) -> StudyMemoryState? {
        scheduleMemory[ScheduleKey(cardID: cardID, studyScheduleID: studyScheduleID)]
    }

    private func scheduleKey(for event: StudyJournalEvent) -> ScheduleKey? {
        guard let cardID = event.cardID else { return nil }
        return ScheduleKey(cardID: cardID, studyScheduleID: event.studyScheduleID)
    }

    mutating func apply(_ event: StudyJournalEvent) throws {
        guard (1...2).contains(event.schemaVersion) else { throw LibraryError.unsupportedSchema(event.schemaVersion) }
        if event.schemaVersion == 1 {
            guard event.studyScheduleID == nil else { throw LibraryError.unsupportedSchema(event.schemaVersion) }
            if case .reschedule(_, _, _, let scheduleIDs) = event.payload, scheduleIDs != nil {
                throw LibraryError.unsupportedSchema(event.schemaVersion)
            }
        }
        guard event.model == StudyJournalEvent.modelVersion, event.epoch == 0 else {
            throw LibraryError.invalid("Unsupported study memory model or scheduling epoch.")
        }
        guard eventIDs.insert(event.id).inserted else {
            throw LibraryError.invalid("A study event ID was used more than once.")
        }
        switch (event.source, event.payload) {
        case (.presentation, .present(let caseID, let reusable)):
            guard let cardID = event.cardID, reusable == true || seenSolveCases?[cardID]?.contains(caseID) != true else {
                throw LibraryError.invalid("This solve case has already been presented.")
            }
            if presentations == nil { presentations = [:]; seenSolveCases = [:] }
            presentations?[event.id] = Presentation(cardID: cardID, caseID: caseID,
                                                     studyScheduleID: event.studyScheduleID)
            seenSolveCases?[cardID, default: []].insert(caseID)
        case (.study, .grade(let rating, let answeringTime, let configuration)):
            guard let cardID = event.cardID, answeringTime.isFinite, answeringTime >= 0 else {
                throw LibraryError.invalid("A study grade is missing a card or has an invalid answering time.")
            }
            if let response = event.solveResponse {
                guard let presentation = presentations?[response.presentationID],
                      presentation.cardID == cardID, presentation.caseID == response.caseID,
                      presentation.studyScheduleID == event.studyScheduleID,
                      gradedPresentations?.contains(response.presentationID) != true else {
                    throw LibraryError.invalid("The solve attempt was not presented or has already been rated.")
                }
                if gradedPresentations == nil { gradedPresentations = [] }
                gradedPresentations?.insert(response.presentationID)
            }
            try configuration.validated()
            let key = ScheduleKey(cardID: cardID, studyScheduleID: event.studyScheduleID)
            let previous = scheduleMemory[key]
            let next = try StudyScheduler.review(previous, rating: rating, at: event.at, configuration: configuration,
                                                 cardID: cardID, isSolve: event.solveResponse != nil)
            // A grade's undo chain is scoped to its schedule, so an old flip grade remains
            // independently undoable after the card has selected a solve schedule.
            grades[event.id] = Grade(cardID: cardID, studyScheduleID: event.studyScheduleID,
                                     rating: rating, studyDay: event.studyDay, before: previous,
                                     after: next, previousChangeID: latestChanges[key], solveResponse: event.solveResponse)
            if previous == nil { introductions[event.studyDay, default: 0] += 1 }
            scheduleMemory[key] = next
            latestChanges[key] = event.id
        case (.undo, .undo(let gradeID)):
            guard let grade = grades[gradeID], grade.cardID == event.cardID,
                  grade.studyScheduleID == event.studyScheduleID,
                  let key = scheduleKey(for: event), latestChanges[key] == gradeID,
                  undoneGrades.insert(gradeID).inserted else {
                throw LibraryError.invalid("This grade cannot be undone because the card's schedule changed.")
            }
            if let previous = grade.before { scheduleMemory[key] = previous }
            else { scheduleMemory.removeValue(forKey: key) }
            latestChanges[key] = grade.previousChangeID
            if let response = grade.solveResponse { gradedPresentations?.remove(response.presentationID) }
            if grade.before == nil {
                let count = introductions[grade.studyDay, default: 0]
                introductions[grade.studyDay] = count > 1 ? count - 1 : nil
            }
        case (.reschedule, .reschedule(let configuration, let cardIDs, let solveIDs, let scheduleIDs)):
            try configuration.validated()
            guard event.cardID == nil, !cardIDs.isEmpty, Set(cardIDs).count == cardIDs.count else {
                throw LibraryError.invalid("Invalid study reschedule event.")
            }
            for cardID in cardIDs {
                let key = ScheduleKey(cardID: cardID, studyScheduleID: scheduleIDs?[cardID])
                guard let previous = scheduleMemory[key] else {
                    throw LibraryError.invalid("A rescheduled card is missing prior study memory.")
                }
                scheduleMemory[key] = StudyScheduler.reschedule(previous, configuration: configuration, cardID: cardID,
                                                                isSolve: solveIDs?.contains(cardID) == true)
                latestChanges[key] = event.id
            }
        default:
            throw LibraryError.invalid("Invalid study event source.")
        }
    }
}

/// A newline commits each complete record. Readers recover only an interrupted final record.
struct StudyJournal {
    private struct Snapshot: Codable {
        var schemaVersion = 2
        let fingerprint: SHA256Digest
        let logPosition: Int
        let state: StudyJournalState
    }

    private struct SHA256Digest: Codable, Equatable {
        let bytes: Data
        init(_ data: Data) { bytes = Data(SHA256.hash(data: data)) }
    }

    static let journalName = "reviews.jsonl"
    static let snapshotName = "study.json"

    private let directory: URL
    private var physicalLength: Int
    private(set) var committed: Data
    private(set) var state: StudyJournalState

    private var journalURL: URL { directory.appendingPathComponent(Self.journalName) }
    private var snapshotURL: URL { directory.appendingPathComponent(Self.snapshotName) }

    init(directory: URL) throws {
        self.directory = directory
        let journal = directory.appendingPathComponent(Self.journalName)
        let data: Data
        do { data = try Data(contentsOf: journal) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { data = Data() }
        physicalLength = data.count
        committed = data.lastIndex(of: 0x0a).map { data.prefix(through: $0) } ?? Data()
        let fingerprint = SHA256Digest(committed)
        let cache = directory.appendingPathComponent(Self.snapshotName)
        if let data = try? Data(contentsOf: cache),
           let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
           snapshot.schemaVersion == 2, snapshot.logPosition == committed.count, snapshot.fingerprint == fingerprint {
            state = snapshot.state
        } else {
            state = try Self.replay(committed)
            if !committed.isEmpty { refreshSnapshot(fingerprint: fingerprint) }
        }
    }

    /// Validate backup data completely before staging its module.
    static func replay(_ data: Data) throws -> StudyJournalState {
        var state = StudyJournalState()
        guard !data.isEmpty else { return state }
        guard data.last == 0x0a else { throw LibraryError.invalid("The study journal ends with an incomplete event.") }
        let decoder = JSONDecoder()
        for line in data.dropLast().split(separator: 0x0a, omittingEmptySubsequences: false) {
            try state.apply(decoder.decode(StudyJournalEvent.self, from: Data(line)))
        }
        return state
    }

    mutating func append(_ event: StudyJournalEvent) throws {
        var event = event
        if event.studyScheduleID != nil { event.schemaVersion = max(event.schemaVersion, 2) }
        if case .reschedule(_, _, _, let scheduleIDs) = event.payload, scheduleIDs != nil {
            event.schemaVersion = max(event.schemaVersion, 2)
        }
        var next = state
        try next.apply(event)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(event)
        data.append(0x0a)
        let fd = open(journalURL.path, O_WRONLY | O_CREAT | O_APPEND, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        if physicalLength != committed.count {
            try handle.truncate(atOffset: UInt64(committed.count))
        }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        if committed.isEmpty { try synchronizeDirectory() }

        // The journal is authoritative. A process can be interrupted between these writes.
        committed.append(data)
        physicalLength = committed.count
        state = next
        refreshSnapshot(fingerprint: SHA256Digest(committed))
    }

    /// A retry can see a complete record after the previous writer reported a sync error.
    func synchronize() throws {
        let handle = try FileHandle(forWritingTo: journalURL)
        defer { try? handle.close() }
        try handle.synchronize()
        try synchronizeDirectory()
    }

    private func synchronizeDirectory() throws {
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private func refreshSnapshot(fingerprint: SHA256Digest) {
        let snapshot = Snapshot(fingerprint: fingerprint, logPosition: committed.count, state: state)
        if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: snapshotURL, options: .atomic) }
    }
}
