import Foundation
import Testing
@testable import LecternCore

@Suite struct PromptTests {
    @Test func generateGoldenAndPrecedence() throws {
        let module = Module(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "Statistics", instructions: "Interpretation over formulas.")
        var lecture = Lecture(moduleID: module.id, name: "Inference", pageCount: 2)
        lecture.slides[0].note = "Test confidence, not arithmetic."
        lecture.threads = [SlideThread(anchorPage: 1, learningPoints: [
            LearningPoint(text: "Parameter vs statistic.", pages: [1]),
            LearningPoint(text: "Excluded misconception", pages: [1], included: false),
            LearningPoint(text: "Other slide only", pages: [2])
        ])]
        let prompt = try PromptBuilder.build(kind: .generate, rules: "One idea per card.", module: module, lecture: lecture,
                                             pages: [1], existingFronts: ["Z question", "A question"])
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/prompt-generate.txt")
        if ProcessInfo.processInfo.environment["LECTERN_UPDATE_GOLDENS"] == "1" { try Data(prompt.utf8).write(to: fixture) }
        #expect(prompt == (try String(contentsOf: fixture, encoding: .utf8)))
        #expect(!prompt.contains("Excluded misconception")); #expect(!prompt.contains("Other slide only"))
        #expect(PromptBuilder.systemPrompt.contains("global rules < module instructions < included learning points < explicit slide notes"))
    }
    @Test func reviseDoesNotTellModelToAvoidItsOwnTargetAndIncludesOriginal() throws {
        let module = Module(name: "M")
        let card = Card(sourcePages: [1], front: "Current?", back: "Answer.", history: [CardRevision(front: "Original?", back: "Old.")])
        let lecture = Lecture(moduleID: module.id, name: "Lecture", pageCount: 1, cards: [card])
        let prompt = try PromptBuilder.build(kind: .revise, rules: "Short.", module: module, lecture: lecture,
                                             pages: [1], existingFronts: [card.front], card: card, feedback: "Explain why.")
        #expect(!prompt.contains("ALREADY COVERED")); #expect(prompt.contains("Original?")); #expect(prompt.contains("Explain why."))
    }
    @Test func allStructuredSchemasAreValidJSONAndHashChangesWithInput() throws {
        for kind in [JobKind.generate, .revise, .distil] {
            let object = try #require(JSONSerialization.jsonObject(with: Data(AIOutputSchema.json(for: kind)!.utf8)) as? [String: Any])
            #expect(object["additionalProperties"] as? Bool == false)
        }
        #expect(AIOutputSchema.json(for: .ask) == nil)
        #expect(PromptBuilder.hash("a") != PromptBuilder.hash("b"))
    }
}
