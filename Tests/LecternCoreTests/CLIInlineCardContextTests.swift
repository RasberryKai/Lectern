import Foundation
import Testing
@testable import LecternCore

@Suite struct CLIInlineCardContextTests {
    private func fixture() throws -> (AIRequest, ChatSnapshotImage, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lectern-inline-cards-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let lecture = Lecture(moduleID: UUID(), name: "Fixture", cards: [Card(front: "First question", back: "First answer"), Card(front: "Second question", back: "Second answer")])
        var snapshot = try JobRunner.chatSnapshot(lecture: lecture, refs: [.allCards], source: root.appendingPathComponent("missing.pdf"), directory: root)
        let bytes = Data("frozen image".utf8)
        let image = ChatSnapshotImage(attachment: ChatAttachment(filename: "study.png", mediaType: "image/png", byteCount: bytes.count, sha256: PromptBuilder.hash(bytes)), messageID: UUID(), isCurrent: true)
        snapshot.images = [image]
        snapshot.assetHashes?[image.relativePath] = image.attachment.sha256
        try FileManager.default.createDirectory(at: root.appendingPathComponent("attachments"), withIntermediateDirectories: true)
        try bytes.write(to: root.appendingPathComponent(image.relativePath))
        let prompt = try JobRunner.chatPrompt(lecture: lecture, question: "Compare with these cards", snapshot: snapshot)
        var request = AIRequest(jobID: UUID(), kind: .chat, model: "opus", prompt: prompt, pdf: nil, workingDirectory: root)
        request.chatSnapshot = snapshot
        return (request, image, root)
    }

    private func stream(request: AIRequest, paths: [String], failed: Bool = false) throws -> Data {
        var events: [[String: Any]] = []
        for (index, path) in paths.enumerated() {
            let id = "read\(index)"
            events.append(["type": "assistant", "message": ["content": [["type": "tool_use", "id": id, "name": "Read", "input": ["file_path": request.workingDirectory.appendingPathComponent(path).path]]]]])
            events.append(["type": "user", "message": ["content": [["type": "tool_result", "tool_use_id": id, "is_error": failed && index == paths.count - 1, "content": failed ? "Read failed" : "Read content"]]]])
        }
        events.append(["type": "result", "subtype": "success", "stop_reason": "tool_use", "structured_output": ["message": "Compared.", "edits": [], "quiz": []]])
        return Data(try events.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n").utf8)
    }
    private func parse(_ data: Data, _ request: AIRequest) throws -> AIResponse {
        try ClaudeCLIProvider.parseChatStream(data, request: request, snapshot: request.chatSnapshot!, onEvent: { _ in })
    }

    @Test func inlineFullDeckPlusActualImageReadSucceedsForExistingSnapshotFormat() throws {
        let (request, image, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        // No new optional flag is needed: retry requests derive evidence from the frozen prompt.
        let frozen = try JSONDecoder().decode(AIRequest.self, from: JSONEncoder().encode(request))
        #expect(ChatProviderContext(request: frozen, snapshot: frozen.chatSnapshot!).hasVerifiedInlineDeck)
        let response = try parse(stream(request: frozen, paths: [image.relativePath]), frozen)
        #expect(response.read == [.allCards]); #expect(!response.searchedLecture)
        let cliPrompt = try ClaudeCLIProvider.inputPrompt(for: frozen, pdfURL: nil)
        let suffix = try #require(cliPrompt.range(of: "Before answering, Read these attached context files: "))
        #expect(!cliPrompt[suffix.upperBound...].contains("cards.json"))
    }
    @Test func attachmentChipOrHistoryAloneDoesNotProveDeckWasSupplied() throws {
        var (request, image, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let encoded = String(decoding: try JSONEncoder().encode(request.chatSnapshot!.cards), as: UTF8.self)
        request.prompt = "HISTORY:\n\(encoded)\nFROZEN ATTACHED CONTEXT:\n\nLOOKUP: frozen files"
        #expect(!ChatProviderContext(request: request, snapshot: request.chatSnapshot!).hasVerifiedInlineDeck)
        #expect(throws: AIError.self) { try parse(stream(request: request, paths: [image.relativePath]), request) }
    }
    @Test func tamperedOrPartialInlineDeckCannotSatisfyAllCards() throws {
        var (request, image, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var cards = request.chatSnapshot!.cards; cards[0].back = "Wrong content"
        for supplied in [cards, Array(request.chatSnapshot!.cards.prefix(1))] {
            let json = String(decoding: try JSONEncoder().encode(supplied), as: UTF8.self)
            request.prompt = "\nFROZEN ATTACHED CONTEXT:\n\(json)\nLOOKUP: frozen files"
            #expect(throws: AIError.self) { try parse(stream(request: request, paths: [image.relativePath]), request) }
        }
    }
    @Test func inlineDeckNeverExcusesUnreadImagesOrExplicitReadFailures() throws {
        let (request, image, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: AIError.self) { try parse(stream(request: request, paths: []), request) }
        #expect(throws: AIError.self) { try parse(stream(request: request, paths: [image.relativePath], failed: true), request) }
        #expect(throws: AIError.self) { try parse(stream(request: request, paths: [image.relativePath, "cards.json"], failed: true), request) }
    }
    @Test func successfulIndividualReadsOfEveryCardSatisfyAllCards() throws {
        var (request, image, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        request.prompt = "\nFROZEN ATTACHED CONTEXT:\n\nLOOKUP: frozen files"
        let cardFiles = request.chatSnapshot!.cards.map { "cards/\($0.id.uuidString).json" }
        let response = try parse(stream(request: request, paths: [image.relativePath] + cardFiles), request)
        #expect(response.read == request.chatSnapshot!.cards.map { .card($0.id) })
        #expect(!response.searchedLecture)
        #expect(throws: AIError.self) { try parse(stream(request: request, paths: [image.relativePath, cardFiles[0]]), request) }
    }
}
