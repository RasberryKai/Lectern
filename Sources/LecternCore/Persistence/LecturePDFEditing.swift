import Darwin
import Foundation

/// A contiguous run of pages in the lecture's managed PDF.
public struct LecturePDFPart: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let filename: String
    public let pageCount: Int
    public let canSplit: Bool

    public init(id: UUID = UUID(), filename: String, pageCount: Int, canSplit: Bool = false) {
        self.id = id
        self.filename = filename
        self.pageCount = pageCount
        self.canSplit = canSplit
    }
}

public enum LecturePDFEdit: Equatable, Sendable {
    /// The range refers to zero-based pages in the current managed PDF.
    case existing(LecturePDFPart, pages: Range<Int>)
    case add(URL)
}

public struct LecturePDFRemovalImpact: LocalizedError, Equatable, Sendable {
    fileprivate let pages: Set<Int>
    fileprivate let notes: [Int: String]
    fileprivate let deletedCards: [Card]
    fileprivate let sharedCards: [Card]
    fileprivate let slideThreads: [SlideThread]

    public var noteCount: Int { notes.count }
    public var deletedCardCount: Int { deletedCards.count }
    public var sharedCardCount: Int { sharedCards.count }
    public var slideThreadCount: Int { slideThreads.count }
    public var errorDescription: String? { "Confirm removal of the selected PDFs and their attached content." }

    fileprivate var needsConfirmation: Bool {
        !notes.isEmpty || !deletedCards.isEmpty || !sharedCards.isEmpty || !slideThreads.isEmpty
    }

    fileprivate init(lecture: Lecture, pages: Set<Int>) {
        self.pages = pages
        notes = Dictionary(uniqueKeysWithValues: pages.compactMap { page in
            let note = lecture.slides[page - 1].note
            return note.isEmpty ? nil : (page, note)
        })
        var deleted: [Card] = []
        var shared: [Card] = []
        for card in lecture.cards where card.sourcePages.contains(where: pages.contains) {
            if card.sourcePages.contains(where: { $0 > 0 && $0 <= lecture.pageCount && !pages.contains($0) }) {
                shared.append(card)
            } else {
                deleted.append(card)
            }
        }
        deletedCards = deleted
        sharedCards = shared
        slideThreads = lecture.threads.filter { pages.contains($0.anchorPage) && (!$0.messages.isEmpty || !$0.learningPoints.isEmpty) }
    }
}

public extension Lecture {
    var editablePDFParts: [LecturePDFPart] {
        if let pdfParts { return pdfParts }
        guard pageCount > 0 else { return [] }
        return [LecturePDFPart(id: id, filename: sourceFilename.isEmpty ? name : sourceFilename,
                               pageCount: pageCount, canSplit: true)]
    }
}

extension LibraryStore {
    public func editPDFs(_ edits: [LecturePDFEdit], removing removedRanges: [Range<Int>] = [],
                         confirming confirmation: LecturePDFRemovalImpact? = nil,
                         basedOn expectedParts: [LecturePDFPart], moduleID: UUID, lectureID: UUID) throws -> Lecture { try locked {
        try requireEditable(moduleUnlocked(moduleID))
        let lecture = try readLecture(moduleID, lectureID)
        guard lecture.editablePDFParts == expectedParts else {
            throw LibraryError.invalid("The lecture's PDFs changed. Reopen Edit PDFs to get the latest order.")
        }
        return try editPDFsUnlocked(lecture, edits: edits, removing: removedRanges, confirming: confirmation)
    } }

    func editPDFsUnlocked(_ previous: Lecture, edits: [LecturePDFEdit], removing removedRanges: [Range<Int>] = [],
                          confirming confirmation: LecturePDFRemovalImpact? = nil) throws -> Lecture {
        guard !previous.isArchived else { throw LibraryError.invalid("Restore this lecture before editing its PDFs.") }
        if previous.pageCount == 0 && edits.isEmpty && removedRanges.isEmpty { return previous }
        let existingRanges = edits.compactMap { edit -> Range<Int>? in
            if case .existing(_, let pages) = edit { return pages }
            return nil
        }
        let originalOrder = existingRanges.sorted { $0.lowerBound < $1.lowerBound }
        let allRanges = (existingRanges + removedRanges).sorted { $0.lowerBound < $1.lowerBound }
        var nextPage = 0
        for range in allRanges {
            guard !range.isEmpty, range.lowerBound == nextPage, range.upperBound <= previous.pageCount else {
                throw LibraryError.invalid("Every existing slide must be kept or removed exactly once.")
            }
            nextPage = range.upperBound
        }
        guard nextPage == previous.pageCount else {
            throw LibraryError.invalid("Every existing slide must be kept or removed exactly once.")
        }

        let source = sourceURL(moduleID: previous.moduleID, lectureID: previous.id)
        let changesSlideLayout = !removedRanges.isEmpty || existingRanges != originalOrder
            || edits.prefix(existingRanges.count).contains { if case .add = $0 { return true }; return false }
        if changesSlideLayout, previous.jobs.contains(where: { $0.state == .running }) {
            throw LibraryError.invalid("Wait for this lecture's AI jobs to finish, or stop them before moving or removing slides.")
        }
        if previous.pageCount > 0, try PDFMerge.pageCount(of: source) != previous.pageCount {
            throw LibraryError.invalid("The lecture's PDF doesn't match its slide count.")
        }
        let removedPages = Set(removedRanges.flatMap { $0.map { $0 + 1 } })
        let impact = removedPages.isEmpty ? nil : LecturePDFRemovalImpact(lecture: previous, pages: removedPages)
        if let impact, impact.needsConfirmation, impact != confirmation {
            throw impact
        }

        let directory = source.deletingLastPathComponent()
        let staging = directory.appendingPathComponent(".stage-pdf-edit-\(UUID())")
        defer { try? FileManager.default.removeItem(at: staging) }
        let hasNewFiles = edits.count != existingRanges.count
        let rewritesSource = changesSlideLayout || hasNewFiles
        let counts: [Int]
        if rewritesSource {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
            let pieces: [(URL, Range<Int>?)] = edits.map { edit in
                switch edit {
                case .existing(_, let pages): (source, pages)
                case .add(let url): (url, nil)
                }
            }
            if pieces.isEmpty {
                try Data().write(to: staging.appendingPathComponent("remove-source"))
                counts = []
            } else {
                let merged = staging.appendingPathComponent("source.pdf")
                counts = try PDFMerge.assemble(pieces, to: merged)
                guard try PDFMerge.pageCount(of: merged) == counts.reduce(0, +) else {
                    throw LibraryError.invalid("The updated PDF has the wrong slide count.")
                }
            }
        } else {
            counts = existingRanges.map(\.count)
        }

        var lecture = previous
        var slides: [SlideState] = []
        var oldToNew: [Int: Int] = [:]
        var firstNewPage: Int?
        lecture.pdfParts = try zip(edits, counts).map { edit, count in
            switch edit {
            case .existing(let part, let pages):
                guard part.pageCount == count else { throw LibraryError.invalid("A PDF has the wrong slide count.") }
                for old in pages {
                    var slide = previous.slides[old]
                    slide.pageIndex = slides.count
                    oldToNew[old + 1] = slide.pageIndex + 1
                    slides.append(slide)
                }
                return part
            case .add(let url):
                let start = slides.count
                firstNewPage = firstNewPage ?? start
                slides += (start..<(start + count)).map { SlideState(pageIndex: $0) }
                return LecturePDFPart(filename: url.lastPathComponent, pageCount: count)
            }
        }
        lecture.slides = slides
        lecture.pageCount = slides.count
        if changesSlideLayout {
            lecture.remapPDFReferences(oldToNew, removing: removedPages, deletingCards: Set(impact?.deletedCards.map(\.id) ?? []))
            lecture.pdfLayoutRevision = UUID()
        } else if let firstNewPage {
            lecture.viewPreferences.focusedPageIndex = firstNewPage
        }
        if !removedPages.isEmpty || previous.pageCount == 0 {
            lecture.sourceFilename = lecture.pdfParts?.first?.filename ?? ""
        }
        if lecture.pageCount == 0 { lecture.viewPreferences.mode = .review }
        if !rewritesSource && lecture.pdfParts == previous.pdfParts { return previous }

        let now = Date()
        lecture.updatedAt = now
        reconcileCardMakingCompletion(from: previous, to: &lecture, at: now)
        try validate(lecture)
        if rewritesSource {
            let metadata = try Self.encoder().encode(lecture)
            try metadata.write(to: staging.appendingPathComponent("lecture.json"))
            try metadata.write(to: staging.appendingPathComponent("lecture.json.bak"))
            try FileManager.default.moveItem(at: staging, to: directory.appendingPathComponent(".pending-pdf-edit"))
            try finishPDFEdit(in: directory)
        } else {
            try write(lecture, to: directory.appendingPathComponent("lecture.json"))
        }
        return lecture
    }

    /// Replay an interrupted publication under the same lock used by lecture readers.
    /// The backup must describe the new PDF too, since the old layout can no longer be read.
    func finishPDFEdit(in directory: URL) throws {
        let pending = directory.appendingPathComponent(".pending-pdf-edit")
        guard FileManager.default.fileExists(atPath: pending.path) else { return }
        if FileManager.default.fileExists(atPath: pending.appendingPathComponent("remove-source").path) {
            let source = directory.appendingPathComponent("source.pdf")
            if unlink(source.path) != 0, errno != ENOENT {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        for filename in ["source.pdf", "lecture.json.bak", "lecture.json"] {
            let staged = pending.appendingPathComponent(filename)
            guard FileManager.default.fileExists(atPath: staged.path) else { continue }
            let target = directory.appendingPathComponent(filename)
            guard rename(staged.path, target.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        try? FileManager.default.removeItem(at: pending)
    }
}
