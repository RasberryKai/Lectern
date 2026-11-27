import Foundation
import Testing
@testable import LecternCore

@Suite struct ChatSolveCaseLookupTests {
    private func cardFixture() throws -> Card {
        let sample = SolveCaseContent(prompt: "A sample question", fields: [
            SolveField(prompt: "Value", input: SolveInput(kind: .number, answers: ["42"]))
        ], explanation: "Calculate the value.")
        var card = Card(front: sample.prompt, back: sample.explanation)
        try card.setSolveDraft(SolveDraft(skill: "Calculate", reason: "Use the rule", variation: "Change the inputs", sample: sample))
        var second = sample
        second.prompt = "A second question"
        var retired = SolveCase(content: second)
        retired.retired = true
        card.solve?.cases.append(SolveCase(content: second))
        card.solve?.cases.append(retired)
        return card
    }

    @Test func solveCaseLookupReturnsFrozenHashesAndEditability() throws {
        let card = try cardFixture()
        let context = ChatProviderContext(
            request: AIRequest(jobID: UUID(), kind: .chat, model: "fixture", prompt: "Question", pdf: nil,
                               workingDirectory: FileManager.default.temporaryDirectory),
            snapshot: ChatSnapshot(slides: [], cards: [card], initialRefs: [])
        )
        let json = try context.solveCases(["C1"])
        let lookup = try #require(JSONDecoder().decode([ChatSolveCaseLookup].self, from: Data(json.utf8)).first)
        #expect(lookup.number == 1)
        #expect(lookup.cardID == card.id)
        #expect(lookup.baseRevisionID == card.currentRevisionID)
        #expect(lookup.cases.count == 3)
        #expect(lookup.cases[0].isSample)
        #expect(lookup.cases[0].editable)
        #expect(!lookup.cases[1].isSample && lookup.cases[1].editable)
        #expect(lookup.cases[2].retired && !lookup.cases[2].editable)
        #expect(lookup.cases.map(\.baseContentHash) == card.solve!.cases.map { ChatSolveCaseEdit.contentHash($0.content) })
    }

    @Test func solveCaseLookupRejectsFlipAndUnknownReferencesClearly() throws {
        let flip = Card(front: "Term", back: "Definition")
        let context = ChatProviderContext(
            request: AIRequest(jobID: UUID(), kind: .chat, model: "fixture", prompt: "Question", pdf: nil,
                               workingDirectory: FileManager.default.temporaryDirectory),
            snapshot: ChatSnapshot(slides: [], cards: [flip], initialRefs: [])
        )
        #expect(throws: AIError.invalidResponse("Card C1 is a flip card. get_solve_cases only accepts solve cards.")) {
            try context.solveCases(["C1"])
        }
        #expect(throws: AIError.invalidResponse("Unknown card C9. Use a displayed reference such as C12 or a frozen card UUID.")) {
            try context.solveCases(["C9"])
        }
    }

    @Test func caseFilesAreIncludedOnlyInVersionedSolveSnapshots() throws {
        var card = try cardFixture()
        var legacy = ChatSnapshot(slides: [], cards: [card], initialRefs: [])
        let request = AIRequest(jobID: UUID(), kind: .chat, model: "fixture", prompt: "Question", pdf: nil,
                                workingDirectory: FileManager.default.temporaryDirectory)
        #expect(!ChatProviderContext(request: request, snapshot: legacy).allowedFiles.contains("cases/C1.json"))
        legacy.solveCaseContextVersion = 1
        #expect(ChatProviderContext(request: request, snapshot: legacy).allowedFiles.contains("cases/C1.json"))
        card.solve = nil
        legacy.cards = [card]
        #expect(!ChatProviderContext(request: request, snapshot: legacy).allowedFiles.contains("cases/C1.json"))
        var oldPayload = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(ChatCardContent(card, number: 1))) as? [String: Any])
        oldPayload.removeValue(forKey: "caseCount")
        let decoded = try JSONDecoder().decode(ChatCardContent.self, from: JSONSerialization.data(withJSONObject: oldPayload))
        #expect(decoded.caseCount == nil)
    }

    @Test func claudeScopedCaseReadMapsToItsParentCard() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lectern-case-read-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("cards"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("cases"), withIntermediateDirectories: true)
        let card = try cardFixture()
        var snapshot = ChatSnapshot(slides: [], cards: [card], initialRefs: [])
        snapshot.cardContextVersion = 1
        snapshot.solveCaseContextVersion = 1
        var hashes: [String: String] = [:]
        func write<T: Encodable>(_ value: T, at path: String) throws {
            let bytes = try ChatContextJSON.encode(value).data(using: .utf8)!
            try bytes.write(to: root.appendingPathComponent(path))
            hashes[path] = PromptBuilder.hash(bytes)
        }
        try write(ChatCardContent.deck([card]), at: "cards.json")
        try write(ChatCardContent(card, number: 1, includeEditIDs: true), at: snapshot.cardPath(at: 0))
        try write(ChatSolveCaseLookup(card: card, number: 1), at: snapshot.solveCasePath(at: 0))
        snapshot.assetHashes = hashes
        var request = AIRequest(jobID: UUID(), kind: .chat, model: "fixture", prompt: "Question", pdf: nil, workingDirectory: root)
        request.chatSnapshot = snapshot
        let prompt = try ClaudeCLIProvider.inputPrompt(for: request, pdfURL: nil)
        #expect(prompt.contains("cases/C12.json"))
        let path = root.appendingPathComponent("cases/C1.json").path
        let events: [[String: Any]] = [
            ["type": "assistant", "message": ["content": [["type": "tool_use", "id": "case-read", "name": "Read", "input": ["file_path": path]]]]],
            ["type": "user", "message": ["content": [["type": "tool_result", "tool_use_id": "case-read", "content": "case contents"]]]],
            ["type": "result", "subtype": "success", "stop_reason": "end_turn", "structured_output": ["message": "Reviewed", "edits": [], "quiz": []]]
        ]
        let data = try events.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n")
        let response = try ClaudeCLIProvider.parseChatStream(Data(data.utf8), request: request, snapshot: snapshot, onEvent: { _ in })
        #expect(response.read == [.card(card.id)])
    }
}
