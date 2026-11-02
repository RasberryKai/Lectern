import Foundation

public struct ExportEntry: Codable, Equatable, Sendable {
    public var lectureID: UUID
    public var cardID: UUID
    public var revisionID: UUID
    public init(lectureID: UUID, cardID: UUID, revisionID: UUID) {
        self.lectureID = lectureID; self.cardID = cardID; self.revisionID = revisionID
    }
    public var lecternID: String { lectureID.uuidString + ":" + cardID.uuidString }
}
public struct AnkiExportResult: Equatable, Sendable {
    public var text: String
    public var cardIDs: [UUID]
    /// Entries are authoritative: card UUIDs alone may collide across migrated lectures.
    public var entries: [ExportEntry]
    public init(text: String, cardIDs: [UUID], entries: [ExportEntry] = []) {
        self.text = text; self.cardIDs = cardIDs; self.entries = entries
    }
}
public enum AnkiExporter {
    public static let noteTypeName = "Lectern"
    public static let noteTypeFields = ["LecternID", "Front", "Back"]
    public static let frontTemplate = "{{Front}}"
    public static let backTemplate = "{{FrontSide}}<hr id=answer>{{Back}}"
    public static let setupInstructions = """
    In Anki, create a note type named Lectern with fields LecternID, Front, Back in that order.
    Set its front template to {{Front}} and back template to {{FrontSide}}<hr id=answer>{{Back}}.
    Import the UTF-8 text file with existing notes set to Update and match scope set to note type.
    Map LecternID, Front, Back to the matching fields and Tags to tags; allow HTML in fields.
    Keep LecternID unchanged on later imports. The header selects an existing note type; it does not create one.
    """
    /// Only approved cards that are new or changed. LecternID is the first regular Anki field.
    public static func export(lectures: [Lecture], moduleName: String, changedOnly: Bool = true) throws -> AnkiExportResult {
        var rows: [String] = [], ids: [UUID] = []
        var entries: [ExportEntry] = []
        for lecture in lectures {
            _ = try lecture.validated()
            for card in lecture.cards where card.verdict == .good && !card.isSuperseded && (!changedOnly || card.exported == nil || card.changedSinceExport) {
                guard lecture.issues(for: card).isEmpty else { throw LectureError.invalidApproval(card.id) }
                let front = try FlashcardMathFormatter.formatForAnki(card.front, interpretations: card.mathInterpretations)
                let back = try FlashcardMathFormatter.formatForAnki(card.back, interpretations: card.mathInterpretations)
                guard let revisionID = card.currentRevisionID else { throw LectureError.invalidApproval(card.id) }
                let entry = ExportEntry(lectureID: lecture.id, cardID: card.id, revisionID: revisionID)
                rows.append([entry.lecternID, field(front), field(back), tag(moduleName) + "::" + tag(lecture.name)].joined(separator: "\t"))
                entries.append(entry)
                ids.append(card.id)
            }
        }
        let headers = ["#separator:Tab", "#html:true", "#notetype:Lectern", "#tags column:4", "#columns:LecternID\tFront\tBack\tTags"]
        return AnkiExportResult(text: (headers + rows).joined(separator: "\n"), cardIDs: ids, entries: entries)
    }
    public static func export(lecture: Lecture, moduleName: String, changedOnly: Bool = true) throws -> AnkiExportResult { try export(lectures: [lecture], moduleName: moduleName, changedOnly: changedOnly) }
    private static func tag(_ name: String) -> String {
        let clean = name.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: "_")
            .replacingOccurrences(of: "::", with: "_").replacingOccurrences(of: "\"", with: "_")
        return clean.isEmpty ? "Untitled" : clean
    }
    private static func field(_ text: String) -> String {
        let quote = text.contains("\t") || text.contains("\"")
        let escaped = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "'", with: "&#39;")
            .replacingOccurrences(of: "\n", with: "<br>")
        return quote ? "\"" + escaped.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : escaped
    }
}
public enum WordDiffKind: String, Codable, Sendable { case unchanged, inserted, removed }
public struct WordDiffToken: Codable, Equatable, Sendable {
    public var text: String
    public var kind: WordDiffKind
    public init(text: String, kind: WordDiffKind) { self.text = text; self.kind = kind }
}
public enum WordDiff {
    /// Whitespace is retained verbatim so joining current tokens reconstructs the edited text.
    public static func compare(_ before: String, _ after: String) -> [WordDiffToken] {
        func tokens(_ value: String) -> [String] {
            var result: [String] = []
            for character in value {
                if let last = result.last, last.last?.isWhitespace == character.isWhitespace { result[result.count - 1].append(character) }
                else { result.append(String(character)) }
            }
            return result
        }
        let old = tokens(before), new = tokens(after)
        // Cards are short; LCS produces stable readable word-level replacements.
        var lengths = Array(repeating: Array(repeating: 0, count: new.count + 1), count: old.count + 1)
        for i in old.indices.reversed() { for j in new.indices.reversed() { lengths[i][j] = old[i] == new[j] ? lengths[i + 1][j + 1] + 1 : max(lengths[i + 1][j], lengths[i][j + 1]) } }
        var result: [WordDiffToken] = [], i = 0, j = 0
        while i < old.count || j < new.count {
            if i < old.count && j < new.count && old[i] == new[j] { result.append(WordDiffToken(text: old[i], kind: .unchanged)); i += 1; j += 1 }
            else if i < old.count && (j == new.count || lengths[i + 1][j] >= lengths[i][j + 1]) { result.append(WordDiffToken(text: old[i], kind: .removed)); i += 1 }
            else { result.append(WordDiffToken(text: new[j], kind: .inserted)); j += 1 }
        }
        return result
    }
}
public extension Card {
    init(draft: CardDraft, origin: CardOrigin = .manual, allowedSourcePages: [Int]? = nil) {
        self.init(sourcePages: draft.sourcePages, front: draft.front, back: draft.back, flag: draft.flag, origin: origin, allowedSourcePages: allowedSourcePages)
    }
}
