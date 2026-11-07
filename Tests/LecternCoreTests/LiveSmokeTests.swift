import Foundation
import CoreGraphics
import Testing
@testable import LecternCore

/// Explicit opt-in only: these use a real subscription quota or incur API charges.
@Suite struct LiveSmokeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LECTERN_LIVE_CLI"] == "1"))
    func subscriptionConnection() async throws { try await smoke(ClaudeCLIProvider(), model: AISettings.defaultCLIModel) }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LECTERN_LIVE_API"] == "1"))
    func paidAPIConnection() async throws { try await smoke(MessagesAPIProvider(), model: AISettings.defaultMessagesAPIModel) }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LECTERN_LIVE_CLI"] == "1"))
    func subscriptionReadsRenderedPDF() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lectern-pdf-smoke-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // Shapes only: the answer requires viewing the PDF, not extracting text.
        let pdf = directory.appendingPathComponent("input.pdf")
        var bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        let context = try #require(CGContext(pdf as CFURL, mediaBox: &bounds, nil))
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fillEllipse(in: CGRect(x: 40, y: 100, width: 80, height: 80))
        context.fillEllipse(in: CGRect(x: 160, y: 100, width: 80, height: 80))
        context.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
        context.fill(CGRect(x: 280, y: 100, width: 80, height: 80))
        context.endPDFPage()
        context.closePDF()
        let request = AIRequest(jobID: UUID(), kind: .ask, model: "sonnet",
            prompt: "Use Read with pages set to \"1\" to render the supplied PDF. How many blue circles are visible? Reply with exactly BLUE_CIRCLES=<count>. If rendering fails, report the error instead of guessing.",
            pdf: nil, workingDirectory: directory)
        let response = try await ClaudeCLIProvider().execute(request, onEvent: { _ in })
        #expect(response.content.trimmingCharacters(in: .whitespacesAndNewlines) == "BLUE_CIRCLES=2")
    }

    private func smoke(_ provider: any AIProvider, model: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lectern-live-smoke-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let request = AIRequest(jobID: UUID(), kind: .ask, model: model, prompt: "Reply with exactly Lectern connected.", pdf: nil, workingDirectory: directory)
        let response = try await provider.execute(request, onEvent: { _ in })
        #expect(response.content.contains("Lectern connected"))
    }
}
