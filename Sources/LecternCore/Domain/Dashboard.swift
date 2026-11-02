import Foundation

public enum LectureProgressStatus: String, CaseIterable, Equatable, Sendable {
    case notImported, preparing, toReview, toExport, done
}

public enum PreparationReason: Equatable, Sendable {
    case selectSlides
    /// Source pages are one based, matching Lecture.coverage(page:).
    case generateMissingCoverage(pages: [Int])
    case waitingForJobs(jobIDs: [UUID])
    case addCards
}

public struct LectureProgress: Equatable, Identifiable, Sendable {
    public let lectureID: UUID
    public let name: String
    public let status: LectureProgressStatus
    public let reviewCardCount: Int
    public let proposalCount: Int
    public let readyExportCount: Int
    public let changedExportCount: Int
    public let selectedPageCount: Int
    public let coveredSelectedPageCount: Int
    public let preparationReasons: [PreparationReason]
    public var id: UUID { lectureID }
}

public struct LectureSlot: Equatable, Identifiable, Sendable {
    public struct ID: Equatable, Hashable, Sendable {
        public let moduleID: UUID
        /// One based; importing a lecture fills a slot without changing its identity.
        public let index: Int
        public init(moduleID: UUID, index: Int) { self.moduleID = moduleID; self.index = index }
    }
    public let id: ID
    public let lectureID: UUID?
    public let status: LectureProgressStatus
}

public enum NextUpAction: Equatable, Sendable {
    case review(lectureID: UUID, cardCount: Int)
    case export(moduleID: UUID, lectureIDs: [UUID], cardCount: Int, changedCardCount: Int)
    case prepare(lectureID: UUID, reasons: [PreparationReason])
    case importLecture(moduleID: UUID, slotID: LectureSlot.ID)
}

/// Calendar states deliberately carry no formatted date, rounded week, or navigation text.
public enum ModulePace: Equatable, Sendable {
    case noExam
    case future(daysRemaining: Int, lecturesPerWeek: Double)
    case dueToday
    case overdue(daysOverdue: Int)
    case complete
}

public struct ProgressTotals: Equatable, Sendable {
    public var doneLectureCount = 0
    public var plannedLectureCount = 0
    public var reviewCardCount = 0
    public var reviewLectureCount = 0
    public var proposalCount = 0
    public var readyExportCount = 0
    public var changedExportCount = 0
    public var notImportedCount = 0
    public var remainingLectureCount: Int { plannedLectureCount - doneLectureCount }
}

public struct ModuleProgress: Equatable, Identifiable, Sendable {
    public let module: Module
    public let lectures: [LectureProgress]
    public let slots: [LectureSlot]
    public let statusCounts: [LectureProgressStatus: Int]
    public let totals: ProgressTotals
    public let nextUp: [NextUpAction]
    public let pace: ModulePace
    public var id: UUID { module.id }
}

public struct DashboardSnapshot: Equatable, Sendable {
    public let modules: [ModuleProgress]
    public let archivedModules: [Module]
    public let totals: ProgressTotals
    public var archivedModuleCount: Int { archivedModules.count }
}

public enum DashboardBuilder {
    /// The store validates identities before taking the atomic snapshot supplied here.
    /// No files, wall clock, mutable global state, or AI calls are consulted.
    public static func build(modules: [Module], lectures: [Lecture], now: Date, timeZone: TimeZone) -> DashboardSnapshot {
        let byModule = lectures.reduce(into: [UUID: [UUID: Lecture]]()) { result, lecture in
            result[lecture.moduleID, default: [:]][lecture.id] = lecture
        }
        let active = modules.filter { !$0.isArchived }.map { module in
            moduleProgress(module, lectures: module.lectureIDs.compactMap { byModule[module.id]?[$0] }, now: now, timeZone: timeZone)
        }
        let totals = active.reduce(into: ProgressTotals()) { sum, module in
            sum.doneLectureCount += module.totals.doneLectureCount
            sum.plannedLectureCount += module.totals.plannedLectureCount
            sum.reviewCardCount += module.totals.reviewCardCount
            sum.reviewLectureCount += module.totals.reviewLectureCount
            sum.proposalCount += module.totals.proposalCount
            sum.readyExportCount += module.totals.readyExportCount
            sum.changedExportCount += module.totals.changedExportCount
            sum.notImportedCount += module.totals.notImportedCount
        }
        return DashboardSnapshot(modules: active, archivedModules: modules.filter(\.isArchived), totals: totals)
    }

    private static func lectureProgress(_ lecture: Lecture) -> LectureProgress {
        let cards = lecture.cards.filter { !$0.isSuperseded }
        var review = 0, proposals = 0, ready = 0, changed = 0
        for card in cards {
            let valid = lecture.issues(for: card).isEmpty
            if card.verdict == .unreviewed || card.verdict == .needsAdjustment || card.proposal != nil || (card.verdict == .good && !valid) {
                review += 1
            }
            if card.proposal != nil { proposals += 1 }
            if card.verdict == .good && valid && card.currentRevisionID != nil && (card.exported == nil || card.changedSinceExport) {
                ready += 1
                if card.exported != nil { changed += 1 }
            }
        }
        let selected = lecture.slides.filter(\.isSelected)
        let missing = selected.filter { lecture.coverage(page: $0.pageIndex + 1) == 0 }.map { $0.pageIndex + 1 }
        let running = lecture.jobs.filter { $0.state == .running }.map(\.id)
        var reasons: [PreparationReason] = []
        if lecture.pageCount > 0 {
            if selected.isEmpty { reasons.append(.selectSlides) }
            if !missing.isEmpty { reasons.append(.generateMissingCoverage(pages: missing)) }
        } else if cards.isEmpty {
            reasons.append(.addCards)
        }
        if !running.isEmpty { reasons.append(.waitingForJobs(jobIDs: running)) }
        let status: LectureProgressStatus = review > 0 ? .toReview : !reasons.isEmpty ? .preparing : ready > 0 ? .toExport : .done
        return LectureProgress(lectureID: lecture.id, name: lecture.name, status: status, reviewCardCount: review,
                               proposalCount: proposals, readyExportCount: ready, changedExportCount: changed,
                               selectedPageCount: selected.count, coveredSelectedPageCount: selected.count - missing.count,
                               preparationReasons: reasons)
    }

    private static func moduleProgress(_ module: Module, lectures: [Lecture], now: Date, timeZone: TimeZone) -> ModuleProgress {
        let progress = lectures.map(lectureProgress)
        // Persisted plans are validated by the store. Keep standalone invalid inputs from
        // allocating unbounded empty slots, while never dropping an imported lecture.
        let planned = max(min(module.plannedLectureCount, Module.maximumPlannedLectureCount), progress.count)
        let slots = (0..<planned).map { index in
            LectureSlot(id: .init(moduleID: module.id, index: index + 1),
                        lectureID: index < progress.count ? progress[index].lectureID : nil,
                        status: index < progress.count ? progress[index].status : .notImported)
        }
        var counts = Dictionary(uniqueKeysWithValues: LectureProgressStatus.allCases.map { ($0, 0) })
        for slot in slots { counts[slot.status, default: 0] += 1 }
        var totals = ProgressTotals()
        totals.plannedLectureCount = planned
        totals.doneLectureCount = counts[.done, default: 0]
        totals.notImportedCount = counts[.notImported, default: 0]
        for lecture in progress {
            totals.reviewCardCount += lecture.reviewCardCount
            if lecture.reviewCardCount > 0 { totals.reviewLectureCount += 1 }
            totals.proposalCount += lecture.proposalCount
            totals.readyExportCount += lecture.readyExportCount
            totals.changedExportCount += lecture.changedExportCount
        }
        var actions: [NextUpAction] = []
        if let first = progress.first(where: { $0.status == .toReview }) {
            actions.append(.review(lectureID: first.lectureID, cardCount: first.reviewCardCount))
        }
        let exportable = progress.filter { $0.readyExportCount > 0 }
        if !exportable.isEmpty {
            actions.append(.export(moduleID: module.id, lectureIDs: exportable.map(\.lectureID),
                                   cardCount: totals.readyExportCount, changedCardCount: totals.changedExportCount))
        }
        if let first = progress.first(where: { $0.status == .preparing }) {
            actions.append(.prepare(lectureID: first.lectureID, reasons: first.preparationReasons))
        }
        if let first = slots.first(where: { $0.lectureID == nil }) {
            actions.append(.importLecture(moduleID: module.id, slotID: first.id))
        }
        return ModuleProgress(module: module, lectures: progress, slots: slots, statusCounts: counts, totals: totals,
                              nextUp: Array(actions.prefix(3)), pace: pace(module, remaining: totals.remainingLectureCount, now: now, timeZone: timeZone))
    }

    private static func pace(_ module: Module, remaining: Int, now: Date, timeZone: TimeZone) -> ModulePace {
        guard remaining > 0 else { return .complete }
        guard let exam = module.examDate else { return .noExam }
        let days = exam.daysRemaining(from: now, timeZone: timeZone)
        if days > 0 { return .future(daysRemaining: days, lecturesPerWeek: Double(remaining) * 7 / Double(days)) }
        return days == 0 ? .dueToday : .overdue(daysOverdue: -days)
    }
}
