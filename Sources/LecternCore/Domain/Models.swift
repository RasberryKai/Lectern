import Foundation

public struct Module: Codable, Equatable, Identifiable, Sendable {
    public static let maximumPlannedLectureCount = 10_000
    public var id: UUID
    public var name: String
    public var instructions: String
    public var lectureIDs: [UUID]
    public var plannedLectureCount: Int
    /// Manual statuses for empty, one-based planned slots. Imported lectures own their override.
    public var slotStatusOverrides: [Int: LectureProgressStatus] = [:]
    public var examDate: ExamDate?
    public var archivedAt: Date?
    public var isArchived: Bool { archivedAt != nil }
    public init(id: UUID = UUID(), name: String, instructions: String = "", lectureIDs: [UUID] = [], plannedLectureCount: Int? = nil, examDate: ExamDate? = nil, archivedAt: Date? = nil) {
        self.id = id; self.name = name; self.instructions = instructions; self.lectureIDs = lectureIDs
        self.plannedLectureCount = plannedLectureCount ?? lectureIDs.count; self.examDate = examDate; self.archivedAt = archivedAt
    }
    private enum CodingKeys: String, CodingKey { case id, name, instructions, lectureIDs, plannedLectureCount, slotStatusOverrides, examDate, archivedAt }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        instructions = try values.decode(String.self, forKey: .instructions)
        lectureIDs = try values.decode([UUID].self, forKey: .lectureIDs)
        plannedLectureCount = try values.decodeIfPresent(Int.self, forKey: .plannedLectureCount) ?? lectureIDs.count
        slotStatusOverrides = try values.decodeIfPresent([Int: LectureProgressStatus].self, forKey: .slotStatusOverrides) ?? [:]
        examDate = try values.decodeIfPresent(ExamDate.self, forKey: .examDate)
        archivedAt = try values.decodeIfPresent(Date.self, forKey: .archivedAt)
        guard (0...Self.maximumPlannedLectureCount).contains(plannedLectureCount) else { throw DecodingError.dataCorruptedError(forKey: .plannedLectureCount, in: values, debugDescription: "Planned lecture count must be between 0 and \(Self.maximumPlannedLectureCount).") }
        guard slotStatusOverrides.allSatisfy({ $0.key > 0 && $0.key <= plannedLectureCount && $0.value != .notImported }) else {
            throw DecodingError.dataCorruptedError(forKey: .slotStatusOverrides, in: values, debugDescription: "Manual statuses must refer to planned slots. Use Automatic for Not imported.")
        }
    }
}
public struct SlideState: Codable, Equatable, Identifiable, Sendable {
    public var pageIndex: Int
    public var isSelected: Bool
    public var note: String
    public var id: Int { pageIndex }
    public init(pageIndex: Int, isSelected: Bool = true, note: String = "") { self.pageIndex = pageIndex; self.isSelected = isSelected; self.note = note }
}
public enum SlideFilter: String, Codable, CaseIterable, Sendable { case all, selected }
public enum ThumbnailSize: String, Codable, CaseIterable, Sendable { case compact, regular, large }
public enum ReviewFilter: String, Codable, CaseIterable, Sendable { case all, unreviewed, good, bad, needsAdjustment, aiFlagged, proposals }
public enum LectureMode: String, Codable, Sendable { case prepare, review }
public struct ViewPreferences: Codable, Equatable, Sendable {
    public var focusedPageIndex: Int?
    public var inspectorVisible: Bool
    public var sidebarVisible: Bool
    public var thumbnailSize: ThumbnailSize
    public var filter: SlideFilter
    public var selectedCardID: UUID?
    public var reviewFilter: ReviewFilter
    public var mode: LectureMode
    public init(focusedPageIndex: Int? = nil, inspectorVisible: Bool = true, sidebarVisible: Bool = true, thumbnailSize: ThumbnailSize = .regular, filter: SlideFilter = .all, selectedCardID: UUID? = nil, reviewFilter: ReviewFilter = .all, mode: LectureMode = .prepare) {
        self.focusedPageIndex = focusedPageIndex; self.inspectorVisible = inspectorVisible; self.sidebarVisible = sidebarVisible; self.thumbnailSize = thumbnailSize; self.filter = filter; self.selectedCardID = selectedCardID; self.reviewFilter = reviewFilter; self.mode = mode
    }
    public static let `default` = ViewPreferences()
}
public enum RevisionAuthor: String, Codable, Sendable { case ai, user }
public struct CardRevision: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var front: String
    public var back: String
    public var author: RevisionAuthor
    public var reason: String?
    public var at: Date
    public init(id: UUID = UUID(), front: String, back: String, author: RevisionAuthor = .user, reason: String? = nil, at: Date = Date()) { self.id = id; self.front = front; self.back = back; self.author = author; self.reason = reason; self.at = at }
}
public enum CardOrigin: Codable, Equatable, Sendable { case generated(jobID: UUID), manual, splitFrom(cardID: UUID) }
public struct ExportMark: Codable, Equatable, Sendable {
    public var revisionID: UUID
    public var date: Date
    public init(revisionID: UUID, date: Date = Date()) { self.revisionID = revisionID; self.date = date }
}
public enum CardIssueKind: String, Codable, Sendable { case importSyntax, emptySide, invalidSource, unresolvedMath }
public struct CardIssue: Codable, Equatable, Sendable {
    public var kind: CardIssueKind
    public var message: String
    public init(kind: CardIssueKind, message: String) { self.kind = kind; self.message = message }
}
public struct CardDraft: Codable, Equatable, Sendable {
    public var front: String
    public var back: String
    public var sourcePages: [Int]
    public var flag: String?
    public init(front: String, back: String, sourcePages: [Int] = [], flag: String? = nil) { self.front = front; self.back = back; self.sourcePages = sourcePages; self.flag = flag }
}
public enum ProposalState: String, Codable, Sendable { case pending, ready, failed }
public struct Proposal: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var jobID: UUID
    public var baseRevisionID: UUID
    public var cards: [CardDraft]
    public var rationale: String
    public var state: ProposalState
    public var allowedSourcePages: [Int]?
    public init(id: UUID = UUID(), jobID: UUID, baseRevisionID: UUID, cards: [CardDraft] = [], rationale: String = "", state: ProposalState = .ready, allowedSourcePages: [Int]? = nil) { self.allowedSourcePages = allowedSourcePages; self.id = id; self.jobID = jobID; self.baseRevisionID = baseRevisionID; self.cards = cards; self.rationale = rationale; self.state = state }
}
public struct Card: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var sourcePages: [Int]
    public var front: String
    public var back: String
    public var verdict: CardVerdict
    public var feedback: String
    public var flag: String?
    public var issue: CardIssue?
    public var mathInterpretations: [String: MathInterpretation]
    public var history: [CardRevision]
    public var proposal: Proposal?
    public var origin: CardOrigin
    public var supersededBy: [UUID]?
    public var exported: ExportMark?
    /// Explicit job scope is retained so invalid model citations are never silently discarded.
    public var allowedSourcePages: [Int]?
    public init(id: UUID = UUID(), sourcePages: [Int] = [], front: String, back: String, verdict: CardVerdict = .unreviewed, feedback: String = "", flag: String? = nil, issue: CardIssue? = nil, mathInterpretations: [String: MathInterpretation] = [:], history: [CardRevision]? = nil, proposal: Proposal? = nil, origin: CardOrigin = .manual, supersededBy: [UUID]? = nil, exported: ExportMark? = nil, allowedSourcePages: [Int]? = nil) {
        self.id = id; self.sourcePages = sourcePages; self.front = front; self.back = back; self.verdict = verdict; self.feedback = feedback; self.flag = flag; self.issue = issue; self.mathInterpretations = mathInterpretations; self.history = history ?? [CardRevision(front: front, back: back, author: origin == .manual ? .user : .ai)]; self.proposal = proposal; self.origin = origin; self.supersededBy = supersededBy; self.exported = exported; self.allowedSourcePages = allowedSourcePages
    }
    public var currentRevisionID: UUID? { history.last?.id }
    public var isSuperseded: Bool { supersededBy != nil }
    public var changedSinceExport: Bool { exported.map { $0.revisionID != currentRevisionID } ?? false }
    public var proposalIsStale: Bool { proposal.map { $0.baseRevisionID != currentRevisionID } ?? false }
    public var requiresSourcePages: Bool {
        switch origin {
        case .manual: false
        case .generated: true
        case .splitFrom: allowedSourcePages?.isEmpty != true
        }
    }
    public var canBeApproved: Bool { (!requiresSourcePages || !sourcePages.isEmpty) && sourcePages.allSatisfy { $0 > 0 && (allowedSourcePages?.contains($0) ?? true) } && issue == nil && !front.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !back.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && [front, back].allSatisfy { (try? FlashcardMathFormatter.formatForAnki($0, interpretations: mathInterpretations)) != nil } }
}
public enum ThreadContext: Codable, Equatable, Hashable, Sendable { case none, slide, neighbours(Int), lecture }
public enum FlashcardContext: String, Codable, CaseIterable, Sendable { case none, all, current }
public enum MessageRole: String, Codable, Sendable { case user, assistant }
public struct ChatMessage: Codable, Equatable, Identifiable, Sendable {
    private enum CodingKeys: String, CodingKey { case id, role, text, citedPages, at, editJobID, attachments, context, read, quiz, stopped, searchedLecture, pendingEdits, conflictingCardIDs }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); role = try c.decode(MessageRole.self, forKey: .role); text = try c.decode(String.self, forKey: .text)
        citedPages = try c.decodeIfPresent([Int].self, forKey: .citedPages) ?? []; at = try c.decode(Date.self, forKey: .at); editJobID = try c.decodeIfPresent(UUID.self, forKey: .editJobID)
        attachments = try c.decodeIfPresent([ChatAttachment].self, forKey: .attachments) ?? []
        context = try c.decodeIfPresent([ContextRef].self, forKey: .context) ?? []; read = try c.decodeIfPresent([ContextRef].self, forKey: .read) ?? []; quiz = try c.decodeIfPresent([QuizItem].self, forKey: .quiz) ?? []; stopped = try c.decodeIfPresent(Bool.self, forKey: .stopped) ?? false
        searchedLecture = try c.decodeIfPresent(Bool.self, forKey: .searchedLecture) ?? false
        pendingEdits = try c.decodeIfPresent([ChatCardEdit].self, forKey: .pendingEdits) ?? []; conflictingCardIDs = try c.decodeIfPresent([UUID].self, forKey: .conflictingCardIDs) ?? []
    }

    public var id: UUID
    public var role: MessageRole
    public var text: String
    public var citedPages: [Int]
    public var at: Date
    public var attachments: [ChatAttachment] = []
    public var context: [ContextRef] = []
    public var read: [ContextRef] = []
    public var quiz: [QuizItem] = []
    public var stopped: Bool = false
    public var searchedLecture: Bool = false
    public var pendingEdits: [ChatCardEdit] = []
    public var conflictingCardIDs: [UUID] = []
    public var editJobID: UUID? = nil
    public init(id: UUID = UUID(), role: MessageRole, text: String, citedPages: [Int] = [], at: Date = Date()) { self.id = id; self.role = role; self.text = text; self.citedPages = citedPages; self.at = at }
}
public struct LearningPoint: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var text: String
    public var pages: [Int]
    public var included: Bool
    public var usedBy: [UUID]
    public init(id: UUID = UUID(), text: String, pages: [Int] = [], included: Bool = true, usedBy: [UUID] = []) { self.id = id; self.text = text; self.pages = pages; self.included = included; self.usedBy = usedBy }
}
public struct SlideThread: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var anchorPage: Int
    public var context: ThreadContext
    public var flashcardContext: FlashcardContext? = nil
    public var messages: [ChatMessage]
    public var learningPoints: [LearningPoint]
    public init(id: UUID = UUID(), anchorPage: Int, context: ThreadContext = .neighbours(1), messages: [ChatMessage] = [], learningPoints: [LearningPoint] = []) { self.id = id; self.anchorPage = anchorPage; self.context = context; self.messages = messages; self.learningPoints = learningPoints }
}
public enum JobKind: String, Codable, CaseIterable, Sendable { case generate, revise, ask, chat, distil }
public enum JobState: String, Codable, Sendable { case running, succeeded, failed, cancelled, interrupted }
public enum AIBackend: String, Codable, CaseIterable, Sendable { case claudeCLI, messagesAPI }
public struct AIUsage: Codable, Equatable, Sendable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var costUSD: Double?
    public var cacheCreationInputTokens: Int?
    public var cacheReadInputTokens: Int?
    public init(inputTokens: Int = 0, outputTokens: Int = 0, costUSD: Double? = nil, cacheCreationInputTokens: Int? = nil, cacheReadInputTokens: Int? = nil) { self.inputTokens = inputTokens; self.outputTokens = outputTokens; self.costUSD = costUSD; self.cacheCreationInputTokens = cacheCreationInputTokens; self.cacheReadInputTokens = cacheReadInputTokens }
}
public struct ChatCardVersion: Codable, Equatable, Sendable {
    public var cardID: UUID
    public var revisionID: UUID
    public var verdict: CardVerdict? = nil
    public var mathInterpretations: [String: MathInterpretation]? = nil
    public init(cardID: UUID, revisionID: UUID, verdict: CardVerdict? = nil,
                mathInterpretations: [String: MathInterpretation]? = nil) {
        self.cardID = cardID; self.revisionID = revisionID
        self.verdict = verdict; self.mathInterpretations = mathInterpretations
    }
    public func matches(_ card: Card) -> Bool {
        card.id == cardID && !card.isSuperseded && card.currentRevisionID == revisionID &&
            (verdict == nil || verdict == card.verdict) &&
            (mathInterpretations == nil || mathInterpretations == card.mathInterpretations)
    }
}
public struct ChatEditUndo: Codable, Equatable, Sendable {
    public var cardID: UUID
    public var appliedRevisionID: UUID
    public var front: String
    public var back: String
    public var verdict: CardVerdict
    public var mathInterpretations: [String: MathInterpretation]
    public var appliedVerdict: CardVerdict? = nil
    public var appliedMathInterpretations: [String: MathInterpretation]? = nil
    public func matches(_ card: Card) -> Bool {
        card.id == cardID && !card.isSuperseded && card.currentRevisionID == appliedRevisionID &&
            card.verdict == (appliedVerdict ?? (verdict == .good ? .unreviewed : verdict)) &&
            card.mathInterpretations == (appliedMathInterpretations ?? [:])
    }
}
public struct Job: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var kind: JobKind
    public var pages: [Int]
    public var inputHash: String
    public var rulesVersion: String
    public var backend: AIBackend
    public var state: JobState
    public var error: String?
    public var usage: AIUsage?
    public var startedAt: Date
    public var finishedAt: Date?
    public var targetCardID: UUID?
    public var threadID: UUID?
    public var baseRevisionID: UUID?
    public var prompt: String
    public var model: String
    /// Absent on older jobs, which keep their original additive behavior.
    public var replacesExistingCards: Bool? = nil
    public var isLectureChat: Bool? = nil
    public var chatEdits: [ChatCardEdit]? = nil
    public var chatEditDisposition: ChatEditDisposition? = nil
    public var chatCardVersions: [ChatCardVersion]? = nil
    public var chatEditUndo: [ChatEditUndo]? = nil
    public var chatEditsUndoneAt: Date? = nil
    public init(id: UUID = UUID(), kind: JobKind, pages: [Int], inputHash: String = "", rulesVersion: String = "1", backend: AIBackend = .claudeCLI, state: JobState = .running, error: String? = nil, usage: AIUsage? = nil, startedAt: Date = Date(), finishedAt: Date? = nil, targetCardID: UUID? = nil, threadID: UUID? = nil, baseRevisionID: UUID? = nil, prompt: String = "", model: String = "opus") {
        self.id = id; self.kind = kind; self.pages = pages; self.inputHash = inputHash; self.rulesVersion = rulesVersion; self.backend = backend; self.state = state; self.error = error; self.usage = usage; self.startedAt = startedAt; self.finishedAt = finishedAt; self.targetCardID = targetCardID; self.threadID = threadID; self.baseRevisionID = baseRevisionID; self.prompt = prompt; self.model = model
    }
}
public struct SkippedSlide: Codable, Equatable, Sendable {
    public var slide: Int
    public var reason: String
    public init(slide: Int, reason: String) { self.slide = slide; self.reason = reason }
}
public struct Lecture: Codable, Equatable, Identifiable, Sendable {
    private enum CodingKeys: String, CodingKey { case schemaVersion,id,moduleID,name,sourceFilename,pageCount,createdAt,updatedAt,slides,cards,threads,currentChat,archivedChats,learningPoints,jobs,skippedSlides,archivedAt,progressOverride,viewPreferences }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion); id = try c.decode(UUID.self, forKey: .id); moduleID = try c.decode(UUID.self, forKey: .moduleID); name = try c.decode(String.self, forKey: .name)
        sourceFilename = try c.decode(String.self, forKey: .sourceFilename); pageCount = try c.decode(Int.self, forKey: .pageCount); createdAt = try c.decode(Date.self, forKey: .createdAt); updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        slides = try c.decode([SlideState].self, forKey: .slides); cards = try c.decode([Card].self, forKey: .cards); threads = try c.decodeIfPresent([SlideThread].self, forKey: .threads) ?? []
        currentChat = try c.decodeIfPresent(LectureChat.self, forKey: .currentChat) ?? LectureChat.migrating(threads)
        if !c.contains(.currentChat) { currentChat.id = threads.first?.id ?? id }
        archivedChats = try c.decodeIfPresent([LectureChat].self, forKey: .archivedChats) ?? []
        learningPoints = try c.decodeIfPresent([LearningPoint].self, forKey: .learningPoints) ?? threads.flatMap(\.learningPoints)
        jobs = try c.decode([Job].self, forKey: .jobs); skippedSlides = try c.decode([SkippedSlide].self, forKey: .skippedSlides); archivedAt = try c.decodeIfPresent(Date.self, forKey: .archivedAt); progressOverride = try c.decodeIfPresent(LectureProgressStatus.self, forKey: .progressOverride)
        viewPreferences = try c.decode(ViewPreferences.self, forKey: .viewPreferences)
    }

    public static let currentSchemaVersion = 1
    public var schemaVersion: Int
    public var id: UUID
    public var moduleID: UUID
    public var name: String
    public var sourceFilename: String
    public var pageCount: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var slides: [SlideState]
    public var cards: [Card]
    public var threads: [SlideThread]
    public var currentChat: LectureChat
    public var archivedChats: [LectureChat]
    public var learningPoints: [LearningPoint]
    public var jobs: [Job]
    public var skippedSlides: [SkippedSlide]
    public var archivedAt: Date?
    public var isArchived: Bool { archivedAt != nil }
    public var progressOverride: LectureProgressStatus?
    public var viewPreferences: ViewPreferences
    public init(id: UUID = UUID(), moduleID: UUID, name: String, sourceFilename: String = "", pageCount: Int = 0, createdAt: Date = Date(), updatedAt: Date? = nil, slides: [SlideState]? = nil, cards: [Card] = [], threads: [SlideThread] = [], jobs: [Job] = [], skippedSlides: [SkippedSlide] = [], viewPreferences: ViewPreferences = .default, schemaVersion: Int = 1) {
        self.schemaVersion = schemaVersion; self.id = id; self.moduleID = moduleID; self.name = name; self.sourceFilename = sourceFilename; self.pageCount = pageCount; self.createdAt = createdAt; self.updatedAt = updatedAt ?? createdAt; self.slides = slides ?? (0..<max(0, pageCount)).map { SlideState(pageIndex: $0) }; self.cards = cards; self.threads = threads; self.currentChat = LectureChat.migrating(threads); self.archivedChats = []; self.learningPoints = threads.flatMap(\.learningPoints); self.jobs = jobs; self.skippedSlides = skippedSlides; self.viewPreferences = viewPreferences
    }
}
