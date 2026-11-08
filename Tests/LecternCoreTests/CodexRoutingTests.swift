import Foundation
import CoreGraphics
import Testing
@testable import LecternCore

@Suite struct CodexRoutingTests {
    @Test func settingsRoundTripAndDecodeLegacySettings() async throws {
        let old = #"{"backend":"claudeCLI","cliModel":"opus","messagesAPIModel":"claude-opus-5-5","messagesAPIVersion":"2026-10-21","maxOutputTokens":32768}"#
        let legacy = try JSONDecoder().decode(AISettings.self, from: Data(old.utf8))
        #expect(legacy.codexCLIPath == nil)
        #expect(legacy.codexModel == AISettings.defaultCodexModel)

        let suite = "Lectern-CodexRoutingTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let store = AISettingsStore(defaults: defaults)
        let settings = AISettings(backend: .codexCLI, codexCLIPath: "/opt/homebrew/bin/codex", codexModel: "gpt-custom")
        try await store.save(settings)
        let loaded = await store.load()
        #expect(loaded == settings)
        #expect(loaded.selectedModel == "gpt-custom")
    }

    @Test func askAndAutomaticDistillationKeepConfiguredCodexModel() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lectern-codex-routing-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pdf = root.appendingPathComponent("lecture.pdf")
        var box = CGRect(x: 0, y: 0, width: 400, height: 300)
        let context = try #require(CGContext(pdf as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil); context.endPDFPage(); context.closePDF()
        let library = LibraryStore(rootURL: root.appendingPathComponent("library"))
        let module = try await library.createModule(name: "Codex routing")
        let lecture = try await library.importPDF(from: pdf, moduleID: module.id)
        let provider = FakeAIProvider(responses: [
            AIResponse(content: #"{"cards":[{"front":"Q","back":"A","sourceSlides":[1],"flag":null}],"skipped":[]}"#),
            AIResponse(content: #"{"cards":[{"front":"Q revised","back":"A revised","sourceSlides":[1],"flag":null}],"rationale":"Clarified."}"#),
            AIResponse(content: "The explanation."),
            AIResponse(content: #"{"learningPoints":[]}"#),
            AIResponse(content: #"{"message":"The chat answer.","edits":[],"quiz":[]}"#),
            AIResponse(content: #"{"learningPoints":[]}"#),
            AIResponse(content: #"{"message":"The lecture chat answer.","edits":[],"quiz":[]}"#),
            AIResponse(content: #"{"learningPoints":[]}"#)
        ], backend: .codexCLI)
        let runner = JobRunner(store: library, providers: [provider])

        _ = try await runner.generate(moduleID: module.id, lectureID: lecture.id,
            backend: .codexCLI, model: "gpt-custom")
        await runner.waitUntilIdle()
        let generated = try await library.loadLecture(moduleID: module.id, lectureID: lecture.id)
        let card = try #require(generated.cards.first)
        _ = try await runner.revise(moduleID: module.id, lectureID: lecture.id, cardID: card.id,
            feedback: "Clarify", backend: .codexCLI, model: "gpt-custom")
        await runner.waitUntilIdle()
        _ = try await runner.ask(moduleID: module.id, lectureID: lecture.id, anchorPage: 1,
            question: "Explain this", backend: .codexCLI, model: "gpt-custom")
        await runner.waitUntilIdle()
        _ = try await runner.chat(moduleID: module.id, lectureID: lecture.id, anchorPage: 1,
            context: .lecture, question: "Continue", backend: .codexCLI, model: "gpt-custom")
        await runner.waitUntilIdle()
        _ = try await runner.chat(moduleID: module.id, lectureID: lecture.id, question: "Continue in lecture chat",
            contextRefs: [.slide(1)], backend: .codexCLI, model: "gpt-custom")
        await runner.waitUntilIdle()

        let requests = await provider.requests
        #expect(requests.map(\.model) == Array(repeating: "gpt-custom", count: 8))
        #expect(requests.map(\.kind) == [.generate, .revise, .ask, .distil, .chat, .distil, .chat, .distil])
    }
}
