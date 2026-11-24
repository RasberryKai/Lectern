import Foundation
import PDFKit
import Testing
@testable import LecternCore

struct LectureCompletionTests {
    @Test func legacyCompletedLectureHasNoInventedCompletionDate() throws {
        let lecture = Lecture(
            moduleID: UUID(), name: "Legacy", updatedAt: Date(),
            cards: [Card(front: "Q", back: "A", verdict: .good)],
            cardMakingCompletedAt: Date()
        )
        let encoded = try JSONEncoder().encode(lecture)
        var json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        json.removeValue(forKey: "cardMakingCompletedAt")

        let decoded = try JSONDecoder().decode(Lecture.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.cardMakingCompletedAt == nil)

        let module = Module(id: decoded.moduleID, name: "Legacy", lectureIDs: [decoded.id])
        let snapshot = DashboardBuilder.build(modules: [module], lectures: [decoded], now: Date(), timeZone: .current)
        let progress = try #require(snapshot.modules.first?.lectures.first)
        #expect(progress.status == .toExport)
        #expect(progress.status.cardMakingStatus == .done)
        #expect(progress.cardMakingCompletedAt == nil)
    }

    @Test func completionTransitionSurvivesEditsAndExportThenClearsOnReopen() async throws {
        let (store, module, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let initial = try await store.createLecture(Lecture(
            moduleID: module.id, name: "Lecture", cards: [Card(front: "Q", back: "A")]
        ))
        #expect(try await store.dashboard().modules[0].lectures[0].automaticStatus == .toReview)

        let completed = try await store.updateLecture(moduleID: module.id, lectureID: initial.id) {
            $0.cards[0].verdict = .good
        }
        let completedAt = try #require(completed.cardMakingCompletedAt)
        #expect(completedAt.timeIntervalSince1970 == completed.updatedAt.timeIntervalSince1970.rounded(.down))
        #expect(try await store.dashboard().modules[0].lectures[0].status == .toExport)

        let renamed = try await store.updateLecture(moduleID: module.id, lectureID: initial.id) {
            $0.name = "Renamed"
        }
        #expect(renamed.cardMakingCompletedAt == completedAt)

        try await store.commitExport(moduleID: module.id, entries: [
            ExportEntry(lectureID: initial.id, cardID: renamed.cards[0].id, revisionID: renamed.cards[0].currentRevisionID!)
        ])
        let exported = try await store.loadLecture(moduleID: module.id, lectureID: initial.id)
        #expect(exported.cardMakingCompletedAt == completedAt)
        #expect(try await store.dashboard().modules[0].lectures[0].status == .done)

        let reopened = try await store.updateLecture(moduleID: module.id, lectureID: initial.id) {
            $0.cards[0].verdict = .unreviewed
        }
        #expect(reopened.cardMakingCompletedAt == nil)
        #expect(try await store.dashboard().modules[0].lectures[0].status == .toReview)

        let completedAgain = try await store.updateLecture(moduleID: module.id, lectureID: initial.id) {
            $0.cards[0].verdict = .good
        }
        #expect(completedAgain.cardMakingCompletedAt != nil)
    }

    @Test func runningAskAndItsFailureDoNotResetCompletionTime() async throws {
        let (store, module, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let initial = try await store.createLecture(Lecture(
            moduleID: module.id, name: "Lecture", cards: [Card(front: "Q", back: "A")]
        ))
        let lecture = try await store.updateLecture(moduleID: module.id, lectureID: initial.id) {
            $0.cards[0].verdict = .good
        }
        let completedAt = try #require(lecture.cardMakingCompletedAt)

        let running = try await store.updateLecture(moduleID: module.id, lectureID: lecture.id) {
            $0.jobs.append(Job(kind: .ask, pages: []))
        }
        #expect(running.cardMakingCompletedAt == completedAt)
        let waiting = try #require(try await store.dashboard().modules.first?.lectures.first)
        #expect(waiting.automaticStatus == .preparing)
        #expect(waiting.preparationReasons == [.waitingForJobs(jobIDs: [running.jobs[0].id])])
        #expect(waiting.cardMakingCompletedAt == completedAt)

        let failed = try await store.updateLecture(moduleID: module.id, lectureID: lecture.id) {
            $0.jobs[0].state = .failed
        }
        #expect(failed.cardMakingCompletedAt == completedAt)
        #expect(try await store.dashboard().modules[0].lectures[0].automaticStatus == .toExport)
    }

    @Test func noCardsStayAutomaticallyIncompleteAndManualOverridesCount() async throws {
        let (store, module, root) = try await fixture(planned: 2)
        defer { try? FileManager.default.removeItem(at: root) }
        try await store.setEmptySlotStatus(.done, slotID: .init(moduleID: module.id, index: 2))
        let lecture = try await store.createLecture(Lecture(moduleID: module.id, name: "Empty"), slot: 1)
        let initial = try #require(try await store.dashboard().modules.first)
        #expect(initial.lectures[0].automaticStatus == .preparing)
        #expect(initial.lectures[0].cardMakingCompletedAt == nil)
        #expect(initial.cardMakingDoneCount == 1)

        let manuallyDone = try await store.updateLecture(moduleID: module.id, lectureID: lecture.id) {
            $0.progressOverride = .toExport
        }
        #expect(manuallyDone.cardMakingCompletedAt != nil)
        #expect(try await store.dashboard().modules[0].cardMakingDoneCount == 2)

        let automaticAgain = try await store.updateLecture(moduleID: module.id, lectureID: lecture.id) {
            $0.progressOverride = nil
        }
        #expect(automaticAgain.cardMakingCompletedAt == nil)
        #expect(try await store.dashboard().modules[0].cardMakingDoneCount == 1)
    }

    @Test func appendingUncoveredSlidesReopensAndClearsCompletionDate() async throws {
        let (store, module, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("one-page.pdf")
        try makeOnePagePDF(at: source)
        let lecture = try await store.importPDF(from: source, moduleID: module.id)
        let completed = try await store.updateLecture(moduleID: module.id, lectureID: lecture.id) {
            $0.cards = [Card(sourcePages: [1], front: "Q", back: "A", verdict: .good)]
        }
        #expect(completed.cardMakingCompletedAt != nil)
        #expect(try await store.dashboard().modules[0].lectures[0].automaticStatus == .toExport)

        let reopened = try await store.appendPDFs([source], moduleID: module.id, lectureID: lecture.id)
        #expect(reopened.pageCount == 2)
        #expect(reopened.cardMakingCompletedAt == nil)
        #expect(try await store.dashboard().modules[0].lectures[0].automaticStatus == .preparing)
    }

    private func fixture(planned: Int = 1) async throws -> (LibraryStore, Module, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lectern-completion-\(UUID())")
        let store = LibraryStore(rootURL: root.appendingPathComponent("Library"))
        let module = try await store.createModule(Module(name: "Module", plannedLectureCount: planned))
        return (store, module, root)
    }

    private func makeOnePagePDF(at url: URL) throws {
        let pdf = PDFDocument()
        let page = PDFPage()
        page.setBounds(CGRect(x: 0, y: 0, width: 300, height: 400), for: .mediaBox)
        pdf.insert(page, at: 0)
        #expect(pdf.write(to: url))
    }
}
