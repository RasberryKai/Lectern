import Foundation
import Testing
@testable import LecternCore

struct JobActivityTests {
    private func progress(_ events: [AIEvent]) -> JobProgress {
        var value = JobProgress(moduleID: UUID(), lectureID: UUID(), jobID: UUID(), stage: "Queued", streamedText: "")
        events.forEach { value.apply($0) }
        return value
    }

    @Test func recordsStepsInOrderWithoutBookkeepingStages() {
        let card = UUID()
        let value = progress([.stage("Reading lecture…"), .read(.slide(4)), .stage("Sending"), .stage("Writing"),
                              .stage("Reading slides…"), .read(.slide(12)), .read(.card(card)), .stage("Sending"),
                              .stage("Writing"), .text("Answer"), .stage("Succeeded")])
        #expect(value.activity == [.thinking, .reading(.slide(4)), .thinking, .reading(.slide(12)), .reading(.card(card)), .thinking])
        #expect(value.read == [.slide(4), .slide(12), .card(card)])
        #expect(value.stage == "Succeeded")
        #expect(value.streamedText == "Answer")
    }

    @Test func collapsesRepeatsAndIgnoresDuplicateReads() {
        let value = progress([.stage("Starting Claude"), .stage("Sending"), .read(.allCards), .read(.allCards),
                              .stage("Reading uploaded images…"), .stage("Reading uploaded images…")])
        #expect(value.activity == [.thinking, .reading(.allCards), .images])
        #expect(value.read == [.allCards])
    }
}
