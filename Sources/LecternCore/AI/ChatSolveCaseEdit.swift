import Foundation

/// A complete replacement for one existing solve case, tied to the frozen case content.
public struct ChatSolveCaseEdit: Codable, Equatable, Sendable {
    public var caseID: UUID
    public var baseContentHash: String
    public var content: SolveCaseContent

    public init(caseID: UUID, baseContentHash: String, content: SolveCaseContent) {
        self.caseID = caseID
        self.baseContentHash = baseContentHash
        self.content = content
    }

    /// Hashes the canonical sorted JSON representation shared by frozen lookup assets and edits.
    public static func contentHash(_ content: SolveCaseContent) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        let bytes = (try? encoder.encode(content)) ?? Data(String(reflecting: content).utf8)
        return PromptBuilder.hash(bytes)
    }
}
