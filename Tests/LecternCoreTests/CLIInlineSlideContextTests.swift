import Foundation
import Testing
@testable import LecternCore

struct CLIInlineSlideContextTests {
    private func fixture(scanned: Bool = false) throws -> AIRequest {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lectern-inline-slides-\(UUID())")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("slides"), withIntermediateDirectories: true)
        var snapshot = ChatSnapshot(slides: [
            ChatSlide(page: 1, text: "Motivation", note: "First note", imagePath: "slides/001.png"),
            ChatSlide(page: 2, text: scanned ? " \n" : "Performance", note: "", imagePath: "slides/002.png")
        ], cards: [], initialRefs: [.allSlides])
        snapshot.assetHashes = [:]
        for (path, bytes) in [("cards.json", Data("[]".utf8))] + snapshot.slides.flatMap({ slide in
            [(String(format: "slides/%03d.txt", slide.page), Data(slide.text.utf8)),
             (String(format: "slides/%03d.png", slide.page), Data("frozen image".utf8))]
        }) {
            try bytes.write(to: root.appendingPathComponent(path))
            snapshot.assetHashes?[path] = PromptBuilder.hash(bytes)
        }
        let lecture = Lecture(moduleID: UUID(), name: "Lecture")
        var request = AIRequest(jobID: UUID(), kind: .chat, model: "opus",
                                prompt: try JobRunner.chatPrompt(lecture: lecture, question: "Summarize everything", snapshot: snapshot),
                                pdf: nil, workingDirectory: root)
        request.chatSnapshot = snapshot
        return request
    }

    private func parse(_ request: AIRequest, paths: [String] = [], failed: Bool = false) throws -> AIResponse {
        var events: [[String: Any]] = []
        for (index, path) in paths.enumerated() {
            let id = "read\(index)"
            events.append(["type": "assistant", "message": ["content": [["type": "tool_use", "id": id, "name": "Read", "input": ["file_path": request.workingDirectory.appendingPathComponent(path).path]]]]])
            events.append(["type": "user", "message": ["content": [["type": "tool_result", "tool_use_id": id, "is_error": failed, "content": "Frozen content"]]]])
        }
        events.append(["type": "result", "subtype": "success", "stop_reason": "tool_use", "structured_output": ["message": "Summary", "edits": [], "quiz": []]])
        let data = Data(try events.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n").utf8)
        return try ClaudeCLIProvider.parseChatStream(data, request: request, snapshot: request.chatSnapshot!, onEvent: { _ in })
    }

    @Test func frozenInlineSlideTextDoesNotRequireRedundantReads() throws {
        let request = try fixture(); defer { try? FileManager.default.removeItem(at: request.workingDirectory) }
        let frozen = try JSONDecoder().decode(AIRequest.self, from: JSONEncoder().encode(request))
        #expect(ChatProviderContext(request: frozen, snapshot: frozen.chatSnapshot!).hasVerifiedInlineSlides)
        let response = try parse(frozen)
        #expect(response.read == [.slide(1), .slide(2)])
        #expect(!response.searchedLecture)
        let prompt = try ClaudeCLIProvider.inputPrompt(for: frozen, pdfURL: nil)
        #expect(prompt.contains("Before answering, Read these attached context files: []"))
    }

    @Test func scannedPagesRequireActualImageReads() throws {
        let request = try fixture(scanned: true); defer { try? FileManager.default.removeItem(at: request.workingDirectory) }
        #expect(throws: AIError.self) { try parse(request) }
        #expect(throws: AIError.self) { try parse(request, paths: ["slides/002.txt"]) }
        #expect(throws: AIError.self) { try parse(request, paths: ["slides/002.png"], failed: true) }
        let response = try parse(request, paths: ["slides/002.png"])
        #expect(Set(response.read) == [.slide(1), .slide(2)])
        #expect(!response.searchedLecture)
        let prompt = try ClaudeCLIProvider.inputPrompt(for: request, pdfURL: nil)
        let required = try #require(prompt.components(separatedBy: "Before answering, Read these attached context files: ").last)
        #expect(required.contains("002.png")); #expect(!required.contains("001.txt")); #expect(!required.contains("002.txt"))
    }

    @Test func incompleteTamperedOrHistoricalTextCannotSatisfyAllSlides() throws {
        var request = try fixture(); defer { try? FileManager.default.removeItem(at: request.workingDirectory) }
        let supplied = request.chatSnapshot!.slides.map { ChatSlide(page: $0.page, text: $0.text, note: $0.note, imagePath: nil) }
        let altered = [ChatSlide(page: 1, text: "Wrong", note: "First note", imagePath: nil), supplied[1]]
        for slides in [Array(supplied.prefix(1)), altered, Array(supplied.reversed())] {
            request.prompt = "\nFROZEN ATTACHED CONTEXT:\n\(try ChatContextJSON.encode(slides))\nLOOKUP: frozen files"
            #expect(!ChatProviderContext(request: request, snapshot: request.chatSnapshot!).hasVerifiedInlineSlides)
            #expect(throws: AIError.self) { try parse(request) }
        }
        request.prompt = "HISTORY:\n\(try ChatContextJSON.encode(supplied))\nFROZEN ATTACHED CONTEXT:\n\nLOOKUP: frozen files"
        #expect(throws: AIError.self) { try parse(request) }
        #expect(try parse(request, paths: ["slides/001.txt", "slides/002.txt"]).read == [.slide(1), .slide(2)])
    }

    @Test func providerFailureIsNotMaskedByMissingContextReads() throws {
        let request = try fixture(scanned: true); defer { try? FileManager.default.removeItem(at: request.workingDirectory) }
        let data = try JSONSerialization.data(withJSONObject: ["type": "result", "is_error": true, "result": "Usage limit reached"])
        do {
            _ = try ClaudeCLIProvider.parseChatStream(data, request: request, snapshot: request.chatSnapshot!, onEvent: { _ in })
            Issue.record("Expected the original provider failure")
        } catch AIError.limit(let message) {
            #expect(message == "Usage limit reached")
        }
    }
}
