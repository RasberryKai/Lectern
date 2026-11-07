import Foundation
import Testing
@testable import LecternCore

@Suite struct ChatPromptOptimizationTests {
    private func fixture(refs: [ContextRef] = [.allCards]) throws -> (Lecture, ChatSnapshot, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lectern-compact-chat-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var card = Card(sourcePages: [], front: "Current unique question", back: "Current unique answer", feedback: "PRIVATE FEEDBACK")
        card.history.insert(CardRevision(front: "OBSOLETE QUESTION", back: "OBSOLETE ANSWER"), at: 0)
        card.exported = ExportMark(revisionID: UUID())
        var hidden = Card(front: "SUPERSEDED QUESTION", back: "SUPERSEDED ANSWER")
        hidden.supersededBy = [card.id]
        let lecture = Lecture(moduleID: UUID(), name: "Compact", cards: [hidden, card, Card(front: "Second question", back: "Second answer")])
        let snapshot = try JobRunner.chatSnapshot(lecture: lecture, refs: refs, source: root.appendingPathComponent("unused.pdf"), directory: root)
        return (lecture, snapshot, root)
    }

    @Test func bulkContentContainsOnlyCurrentStudyContentAndNoDuplicateIndex() throws {
        let (lecture, snapshot, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let prompt = try JobRunner.chatPrompt(lecture: lecture, question: "Check coverage", snapshot: snapshot)
        for text in ["OBSOLETE QUESTION", "OBSOLETE ANSWER", "PRIVATE FEEDBACK", "SUPERSEDED QUESTION", "\"history\":", "\"exported\":", "\"verdict\":"] {
            #expect(!prompt.contains(text))
            #expect(!String(decoding: try Data(contentsOf: root.appendingPathComponent("cards.json")), as: UTF8.self).contains(text))
        }
        #expect(prompt.components(separatedBy: "Current unique question").count == 2)
        #expect(prompt.components(separatedBy: "Current unique answer").count == 2)
        #expect(!prompt.contains(snapshot.cards[0].id.uuidString))
        #expect(!prompt.contains(snapshot.cards[0].currentRevisionID!.uuidString))
        #expect(snapshot.cards.count == 2)
        #expect(snapshot.cards[0].history.count == 2)
        let deck = try JSONDecoder().decode([ChatCardContent].self, from: Data(contentsOf: root.appendingPathComponent("cards.json")))
        #expect(deck.map(\.number) == [1, 2])
        #expect(deck.map(\.back) == snapshot.cards.map(\.back))
    }

    @Test func individualLookupResolvesDisplayedNumbersAndKeepsFrozenEditIDs() throws {
        let (lecture, snapshot, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let prompt = try JobRunner.chatPrompt(lecture: lecture, question: "Edit C1", snapshot: snapshot)
        let request = AIRequest(jobID: UUID(), kind: .chat, model: "opus", prompt: prompt, pdf: nil, workingDirectory: root)
        let context = ChatProviderContext(request: request, snapshot: snapshot)
        try context.verifyAssets()
        #expect(try context.cardIDs(["C1", "C2", snapshot.cards[0].id.uuidString]) == [snapshot.cards[0].id, snapshot.cards[1].id, snapshot.cards[0].id])
        for invalid in ["C0", "C3", "C-1", "C01", UUID().uuidString] {
            #expect(throws: AIError.self) { try context.cardIDs([invalid]) }
        }
        let detail = try JSONDecoder().decode(ChatCardContent.self, from: context.data("cards/C1.json"))
        #expect(detail.cardID == snapshot.cards[0].id)
        #expect(detail.baseRevisionID == snapshot.cards[0].currentRevisionID)
        #expect(context.reference(for: "cards/C1.json") == .card(snapshot.cards[0].id))
        #expect(context.reference(for: "cards/C2.json") == .card(snapshot.cards[1].id))
        let apiCards = try JSONDecoder().decode([ChatCardContent].self, from: Data(context.cards([snapshot.cards[0].id]).utf8))
        #expect(apiCards == [detail])
    }

    @Test func stableDeckPrefixSurvivesNewQuestionHistoryAndAppMetadata() throws {
        var (lecture, snapshot, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let before = try JobRunner.chatPrompt(lecture: lecture, question: "First question", snapshot: snapshot)
        lecture.currentChat.messages.append(ChatMessage(role: .user, text: "Changing conversation"))
        lecture.currentChat.summary = "Changing summary"
        snapshot.cards[0].feedback = "Different feedback"
        snapshot.cards[0].exported = nil
        snapshot.cards[0].history.insert(CardRevision(front: "Another old question", back: "Another old answer"), at: 0)
        let after = try JobRunner.chatPrompt(lecture: lecture, question: "Different question", snapshot: snapshot)
        let marker = "SUMMARY OF OLDER TURNS:"
        #expect(before.components(separatedBy: marker).first == after.components(separatedBy: marker).first)
        #expect(before != after)
        #expect(try JobRunner.chatPrompt(lecture: lecture, question: "Different question", snapshot: snapshot) == after)
        let frozen = try #require(after.range(of: "FROZEN ATTACHED CONTEXT:"))
        let history = try #require(after.range(of: "LAST TEN TURNS"))
        #expect(frozen.lowerBound < history.lowerBound)
    }

    @Test func apiDoesNotAttachTheInlineDeckTwice() throws {
        let (lecture, snapshot, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let prompt = try JobRunner.chatPrompt(lecture: lecture, question: "Coverage", snapshot: snapshot)
        let request = AIRequest(jobID: UUID(), kind: .chat, model: "opus", prompt: prompt, pdf: nil, workingDirectory: root)
        let initial = try ChatProviderContext(request: request, snapshot: snapshot).initialContent()
        #expect(initial.blocks.count == 1)
        #expect(initial.refs == [.allCards])
    }

    @Test func compactCardsPreserveSourcePagesAndMathDecisions() throws {
        let card = Card(sourcePages: [2, 7], front: "Interpret $5", back: "The original answer", mathInterpretations: ["$5": .keepAsText])
        let content = ChatCardContent(card, number: 12)
        let decoded = try JSONDecoder().decode(ChatCardContent.self, from: Data(ChatContextJSON.encode(content).utf8))
        #expect(decoded.number == 12)
        #expect(decoded.sourcePages == [2, 7])
        #expect(decoded.mathInterpretations == card.mathInterpretations)
        #expect(decoded.front == card.front)
        #expect(decoded.back == card.back)
        #expect(decoded.cardID == nil && decoded.baseRevisionID == nil)
    }

    @Test func unfocusedQuestionsRetainCardDiscoveryAndFocusedCardsStayCompact() throws {
        let (lecture, snapshot, root) = try fixture(refs: []); defer { try? FileManager.default.removeItem(at: root) }
        let index = try JobRunner.chatPrompt(lecture: lecture, question: "Find the current question", snapshot: snapshot)
        #expect(index.contains("C1: Current unique question"))
        var focused = snapshot; focused.initialRefs = [.card(snapshot.cards[0].id)]
        let prompt = try JobRunner.chatPrompt(lecture: lecture, question: "Edit this", snapshot: focused)
        #expect(prompt.contains(snapshot.cards[0].currentRevisionID!.uuidString))
        #expect(!prompt.contains("OBSOLETE ANSWER"))
        var request = AIRequest(jobID: UUID(), kind: .chat, model: "opus", prompt: prompt, pdf: nil, workingDirectory: root)
        request.chatSnapshot = focused
        let cli = try ClaudeCLIProvider.inputPrompt(for: request, pdfURL: nil)
        let required = try #require(cli.components(separatedBy: "Before answering, Read these attached context files: ").last)
        #expect(required.replacingOccurrences(of: "\\/", with: "/").contains("cards/C1.json"))
    }
}
