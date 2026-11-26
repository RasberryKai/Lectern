import Foundation
import Testing
@testable import LecternCore

@Suite struct SolveVariantRunnerTests {
    @Test func variantKeysNeedAgreementFromAnIndependentSolve() async throws {
        let sample = exercise("Bag A has two red balls and two blue balls. Find the probability of red.", key: "1/2")
        let repeated = exercise(sample.prompt, key: "9")
        let wrong = exercise("Bag B has one red ball and two blue balls. Find the probability of red.", key: "999951")
        let correct = exercise("Bag C has eight red balls and two blue balls. Find the probability of red.", key: "4/5")
        let draft = SolveDraft(skill: "Compute a discrete probability", reason: "Practice identifying a sample space.",
                               variation: "Change the colors and their quantities.", sample: sample)
        let generated = try JSONEncoder().encode(["cases": [repeated, wrong, correct]])
        let verified = """
        {"cases":[
          {"index":0,"explanation":"One of three balls is red.","fields":[{"answers":["1/3"],"rows":[],"optionReasons":[],"noneReason":""}]},
          {"index":1,"explanation":"Eight of ten balls are red, which simplifies to four fifths.","fields":[{"answers":["0.8"],"rows":[],"optionReasons":[],"noneReason":""}]}
        ]}
        """
        let provider = FakeAIProvider(responses: [
            AIResponse(content: String(decoding: generated, as: UTF8.self)), AIResponse(content: verified)
        ])
        let runner = JobRunner(store: LibraryStore(rootURL: FileManager.default.temporaryDirectory), providers: [provider])
        let cases = try await runner.prepareSolveVariants(draft: draft, existingCases: [], count: 3,
                                                          backend: .claudeCLI, model: "opus")
        #expect(cases.map(\.prompt) == [correct.prompt])
        #expect(cases.first?.explanation == "Eight of ten balls are red, which simplifies to four fifths.")
        let requests = await provider.requests
        #expect(requests.count == 2)
        #expect(requests[0].outputSchema == AIOutputSchema.solveVariants)
        #expect(requests[1].outputSchema == AIOutputSchema.verifiedSolveVariants)
        #expect(!requests[1].prompt.contains("999951"))
        #expect(!requests[1].prompt.contains("UNVERIFIED_EXPLANATION"))
        #expect(requests[1].prompt.contains(wrong.prompt))
        for request in requests {
            let schema = try #require(request.outputSchema)
            _ = try JSONSerialization.jsonObject(with: Data(schema.utf8))
        }
    }

    @Test func oldFrozenCardPromptsKeepTheirOutputContract() throws {
        let schema = #"{"type":"object","additionalProperties":false,"required":["cards","skipped"],"properties":{}}"#
        let request = AIRequest(jobID: UUID(), kind: .generate, model: "opus",
                                prompt: "Original request\n\nOUTPUT CONTRACT: return only JSON conforming to:\n" + schema,
                                pdf: nil, workingDirectory: FileManager.default.temporaryDirectory)
        #expect(request.outputSchema == schema)
    }

    @Test func withdrawingApprovalBeforeVerificationStopsTheSecondCall() async throws {
        let sample = exercise("Find the probability of red from two red and two blue balls.", key: "1/2")
        let draft = SolveDraft(skill: "Discrete probability", reason: "Practice finding favorable outcomes.",
                               variation: "Change the quantities.", sample: sample)
        let candidate = exercise("Find the probability of blue from five red and three blue balls.", key: "3/8")
        let generated = try JSONEncoder().encode(["cases": [candidate]])
        let provider = FakeAIProvider(responses: [AIResponse(content: String(decoding: generated, as: UTF8.self))])
        let runner = JobRunner(store: LibraryStore(rootURL: FileManager.default.temporaryDirectory), providers: [provider])
        let cases = try await runner.prepareSolveVariants(
            draft: draft, existingCases: [], count: 1, backend: .claudeCLI, model: "opus",
            isStillApproved: { await provider.requests.isEmpty }
        )
        #expect(cases.isEmpty)
        #expect(await provider.requests.count == 1)
    }

    private func exercise(_ prompt: String, key: String) -> SolveCaseContent {
        SolveCaseContent(prompt: prompt, fields: [
            SolveField(prompt: "Probability", input: SolveInput(kind: .number, answers: [key], formats: [.decimalPoint, .fraction]))
        ], explanation: "UNVERIFIED_EXPLANATION", variance: nil)
    }
}
