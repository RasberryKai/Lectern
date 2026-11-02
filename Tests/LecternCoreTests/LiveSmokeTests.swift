import Foundation
import Testing
@testable import LecternCore

/// Explicit opt-in only: these use a real subscription quota or incur API charges.
@Suite struct LiveSmokeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LECTERN_LIVE_CLI"] == "1"))
    func subscriptionConnection() async throws { try await smoke(ClaudeCLIProvider(), model: AISettings.defaultCLIModel) }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LECTERN_LIVE_API"] == "1"))
    func paidAPIConnection() async throws { try await smoke(MessagesAPIProvider(), model: AISettings.defaultMessagesAPIModel) }

    private func smoke(_ provider: any AIProvider, model: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lectern-live-smoke-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let request = AIRequest(jobID: UUID(), kind: .ask, model: model, prompt: "Reply with exactly Lectern connected.", pdf: nil, workingDirectory: directory)
        let response = try await provider.execute(request, onEvent: { _ in })
        #expect(response.content.contains("Lectern connected"))
    }
}
