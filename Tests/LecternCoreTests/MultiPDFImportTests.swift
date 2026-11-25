import Foundation
import PDFKit
import Testing
@testable import LecternCore

struct MultiPDFImportTests {
    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lectern-multipdf-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Writes a PDF whose pages have widths `width, width + 1, …` so merged order is checkable.
    private func writePDF(_ name: String, pages: Int, width: CGFloat, in folder: URL) throws -> URL {
        let pdf = PDFDocument()
        for index in 0..<pages {
            let page = PDFPage()
            page.setBounds(CGRect(x: 0, y: 0, width: width + CGFloat(index), height: 400), for: .mediaBox)
            pdf.insert(page, at: pdf.pageCount)
        }
        let url = folder.appendingPathComponent(name)
        #expect(pdf.write(to: url))
        return url
    }

    private func widths(_ url: URL) -> [CGFloat] {
        guard let pdf = PDFDocument(url: url) else { return [] }
        return (0..<pdf.pageCount).compactMap { pdf.page(at: $0)?.bounds(for: .mediaBox).width }
    }

    @Test func mergesFilesInGivenOrderIntoOneLecture() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let a = try writePDF("Part2.pdf", pages: 2, width: 200, in: root)
        let b = try writePDF("Part1.pdf", pages: 3, width: 300, in: root)
        let store = LibraryStore(rootURL: root.appendingPathComponent("library"))
        let module = try await store.createModule(name: "Statistics")

        let lecture = try await store.importPDFs([a, b], name: "  05 Tests  ", moduleID: module.id)

        #expect(lecture.name == "05 Tests")
        #expect(lecture.pageCount == 5)
        #expect(lecture.slides.count == 5 && lecture.slides.allSatisfy(\.isSelected))
        #expect(lecture.sourceFilename == "Part2.pdf")
        #expect(lecture.pdfParts?.map(\.filename) == ["Part2.pdf", "Part1.pdf"])
        #expect(lecture.pdfParts?.map(\.pageCount) == [2, 3])
        #expect(widths(store.sourceURL(moduleID: module.id, lectureID: lecture.id)) == [200, 201, 300, 301, 302])
        #expect(try await store.lectures(in: module.id).map(\.id) == [lecture.id])
    }

    @Test func emptyNameFallsBackToSharedStart() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let a = try writePDF("05_Hypothesis_Tests_Part1.pdf", pages: 1, width: 100, in: root)
        let b = try writePDF("05_Hypothesis_Tests_Part2.pdf", pages: 1, width: 100, in: root)
        let store = LibraryStore(rootURL: root.appendingPathComponent("library"))
        let module = try await store.createModule(name: "Statistics")
        let lecture = try await store.importPDFs([a, b], name: "", moduleID: module.id)
        #expect(lecture.name == "05 Hypothesis Tests")
    }

    @Test func unreadableFileIsNamedAndNothingIsImported() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let good = try writePDF("Good.pdf", pages: 2, width: 100, in: root)
        let bad = root.appendingPathComponent("Broken.pdf")
        try Data("not a pdf".utf8).write(to: bad)
        let store = LibraryStore(rootURL: root.appendingPathComponent("library"))
        let module = try await store.createModule(name: "Statistics")

        do {
            _ = try await store.importPDFs([good, bad], name: "X", moduleID: module.id)
            Issue.record("Import should fail")
        } catch {
            #expect(error.localizedDescription.contains("Broken.pdf"))
        }
        #expect(try await store.lectures(in: module.id).isEmpty)
        #expect(throws: LibraryError.self) { try PDFMerge.pageCount(of: bad) }
        #expect(try PDFMerge.pageCount(of: good) == 2)
    }

    @Test func archivedModuleRejectsMergedImport() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let a = try writePDF("A.pdf", pages: 1, width: 100, in: root)
        let b = try writePDF("B.pdf", pages: 1, width: 100, in: root)
        let store = LibraryStore(rootURL: root.appendingPathComponent("library"))
        let module = try await store.createModule(name: "Statistics")
        try await store.setModuleArchived(moduleID: module.id, archived: true)
        await #expect(throws: LibraryError.self) { try await store.importPDFs([a, b], name: "X", moduleID: module.id) }
    }

    @Test func archiveHidesLectureAndRestorePreservesItsPDFAndNotes() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let pdf = try writePDF("Lecture.pdf", pages: 1, width: 200, in: root)
        let store = LibraryStore(rootURL: root.appendingPathComponent("library"))
        let module = try await store.createModule(name: "Statistics")
        let imported = try await store.importPDF(from: pdf, moduleID: module.id)
        let lecture = try await store.updateLecture(moduleID: module.id, lectureID: imported.id) {
            $0.slides[0].note = "Keep this note"
        }
        let source = store.sourceURL(moduleID: module.id, lectureID: lecture.id)

        try await store.setLectureArchived(moduleID: module.id, lectureID: lecture.id, archived: true)
        #expect(try await store.lectures(in: module.id).isEmpty)
        #expect(try await store.lectures(in: module.id, includingArchived: true).first?.isArchived == true)
        #expect(try await store.dashboard().modules.first?.lectures.isEmpty == true)
        #expect(try Data(contentsOf: source) == Data(contentsOf: pdf))
        await #expect(throws: LibraryError.self) {
            try await store.updateLecture(moduleID: module.id, lectureID: lecture.id) { $0.name = "Stale edit" }
        }

        let replacement = try await store.importPDF(from: pdf, moduleID: module.id)
        #expect(try await store.loadModule(moduleID: module.id).plannedLectureCount == 1)
        try await store.setLectureArchived(moduleID: module.id, lectureID: lecture.id, archived: false)
        let restored = try await store.lectures(in: module.id)
        #expect(restored.map(\.id) == [lecture.id, replacement.id])
        #expect(restored.first?.slides == lecture.slides)
        #expect(try Data(contentsOf: source) == Data(contentsOf: pdf))
    }

    @Test func naturalOrderPutsPart2BeforePart10() {
        let urls = ["Part 10.pdf", "Part 2.pdf", "Part 1.pdf"].map { URL(fileURLWithPath: "/tmp/\($0)") }
        #expect(PDFMerge.naturalOrder(urls).map(\.lastPathComponent) == ["Part 1.pdf", "Part 2.pdf", "Part 10.pdf"])
    }

    @Test func suggestedNames() {
        #expect(PDFMerge.suggestedName(for: ["05_Hypothesis_Tests_Part1.pdf", "05_Hypothesis_Tests_Part2.pdf", "Exercise_Sheet_05.pdf"]) == "05 Hypothesis Tests")
        #expect(PDFMerge.suggestedName(for: ["Lecture 3 Part 1.pdf", "Lecture 3 Part 2.pdf"]) == "Lecture 3")
        #expect(PDFMerge.suggestedName(for: ["Intro.pdf", "Exercises.pdf"]) == "Intro")
        #expect(PDFMerge.suggestedName(for: []) == "")
    }

    // MARK: Append

    @Test func appendAddsPagesAfterExistingSlidesWithoutMovingThem() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let original = try writePDF("Lecture.pdf", pages: 3, width: 100, in: root)
        let sheet = try writePDF("Exercise.pdf", pages: 2, width: 500, in: root)
        let late = try writePDF("Errata.pdf", pages: 1, width: 700, in: root)
        let store = LibraryStore(rootURL: root.appendingPathComponent("library"))
        let module = try await store.createModule(name: "Statistics")
        let lecture = try await store.importPDF(from: original, moduleID: module.id)
        _ = try await store.updateLecture(moduleID: module.id, lectureID: lecture.id) { lecture in
            lecture.slides[1].isSelected = false
            lecture.slides[2].note = "keep me"
            lecture.cards.append(Card(sourcePages: [2], front: "Q", back: "A"))
        }

        let appended = try await store.appendPDFs([sheet, late], moduleID: module.id, lectureID: lecture.id)

        #expect(appended.pageCount == 6)
        #expect(appended.slides.map(\.isSelected) == [true, false, true, true, true, true])
        #expect(appended.slides[2].note == "keep me")
        #expect(appended.cards.first?.sourcePages == [2])
        #expect(appended.viewPreferences.focusedPageIndex == 3)
        #expect(appended.sourceFilename == "Lecture.pdf")
        #expect(widths(store.sourceURL(moduleID: module.id, lectureID: lecture.id)) == [100, 101, 102, 500, 501, 700])
        let reloaded = try await store.loadLecture(moduleID: module.id, lectureID: lecture.id)
        #expect(reloaded.pageCount == 6 && reloaded.slides == appended.slides && reloaded.cards == appended.cards)
    }

    @Test func appendWithBadFileChangesNothing() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let original = try writePDF("Lecture.pdf", pages: 2, width: 100, in: root)
        let bad = root.appendingPathComponent("Broken.pdf")
        try Data("not a pdf".utf8).write(to: bad)
        let store = LibraryStore(rootURL: root.appendingPathComponent("library"))
        let module = try await store.createModule(name: "Statistics")
        let lecture = try await store.importPDF(from: original, moduleID: module.id)

        do {
            _ = try await store.appendPDFs([bad], moduleID: module.id, lectureID: lecture.id)
            Issue.record("Append should fail")
        } catch {
            #expect(error.localizedDescription.contains("Broken.pdf"))
        }
        #expect(try await store.loadLecture(moduleID: module.id, lectureID: lecture.id).pageCount == 2)
        #expect(widths(store.sourceURL(moduleID: module.id, lectureID: lecture.id)) == [100, 101])
    }

    @Test func appendRefusesLecturesWithoutSlidesAndArchivedModules() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let extra = try writePDF("Extra.pdf", pages: 1, width: 100, in: root)
        let store = LibraryStore(rootURL: root.appendingPathComponent("library"))
        let module = try await store.createModule(name: "Statistics")
        let empty = try await store.createLecture(Lecture(moduleID: module.id, name: "From the reviewer"))
        await #expect(throws: LibraryError.self) { try await store.appendPDFs([extra], moduleID: module.id, lectureID: empty.id) }

        let withSlides = try await store.importPDF(from: extra, moduleID: module.id)
        try await store.setLectureArchived(moduleID: module.id, lectureID: withSlides.id, archived: true)
        await #expect(throws: LibraryError.self) { try await store.appendPDFs([extra], moduleID: module.id, lectureID: withSlides.id) }
        try await store.setLectureArchived(moduleID: module.id, lectureID: withSlides.id, archived: false)
        try await store.setModuleArchived(moduleID: module.id, archived: true)
        await #expect(throws: LibraryError.self) { try await store.appendPDFs([extra], moduleID: module.id, lectureID: withSlides.id) }
    }

    @Test func editReordersAndInsertsFilesWithoutDetachingSlideContent() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let first = try writePDF("First.pdf", pages: 2, width: 100, in: root)
        let second = try writePDF("Second.pdf", pages: 1, width: 200, in: root)
        let extra = try writePDF("Extra.pdf", pages: 1, width: 300, in: root)
        let store = LibraryStore(rootURL: root.appendingPathComponent("library"))
        let module = try await store.createModule(name: "Statistics")
        let lecture = try await store.importPDFs([first, second], name: "Lecture", moduleID: module.id)
        let parts = lecture.editablePDFParts
        try FileManager.default.removeItem(at: first)
        try FileManager.default.removeItem(at: second)
        _ = try await store.updateLecture(moduleID: module.id, lectureID: lecture.id) {
            $0.slides[1].note = "Keep this on the second page of First.pdf"
            $0.slides[1].isSelected = false
            $0.viewPreferences.focusedPageIndex = 1
            $0.cards = [Card(sourcePages: [1, 3], front: "Q", back: "A", allowedSourcePages: [1, 2, 3])]
            $0.learningPoints = [LearningPoint(text: "Point", pages: [3])]
            $0.threads = [SlideThread(anchorPage: 2)]
            $0.skippedSlides = [SkippedSlide(slide: 1, reason: "Title")]
            var message = ChatMessage(role: .assistant, text: "See [S1–3, C2] and `[S1]`.", citedPages: [1, 2, 3])
            message.context = [.slide(2), .allSlides]
            message.quiz = [QuizItem(question: "Where?", answer: "[S3]")]
            $0.currentChat.messages = [message]
        }

        let edits: [LecturePDFEdit] = [.existing(parts[1], pages: 2..<3), .add(extra), .existing(parts[0], pages: 0..<2)]
        let edited = try await store.editPDFs(edits, basedOn: parts, moduleID: module.id, lectureID: lecture.id)
        #expect(widths(store.sourceURL(moduleID: module.id, lectureID: lecture.id)) == [200, 300, 100, 101])
        #expect(edited.pdfParts?.map(\.filename) == ["Second.pdf", "Extra.pdf", "First.pdf"])
        #expect(edited.slides.map(\.pageIndex) == [0, 1, 2, 3])
        #expect(edited.slides.map(\.isSelected) == [true, true, true, false])
        #expect(edited.slides[3].note == "Keep this on the second page of First.pdf")
        #expect(edited.viewPreferences.focusedPageIndex == 3)
        #expect(edited.cards[0].sourcePages == [1, 3])
        #expect(edited.cards[0].allowedSourcePages == [1, 3, 4])
        #expect(edited.learningPoints[0].pages == [1])
        #expect(edited.threads[0].anchorPage == 4)
        #expect(edited.skippedSlides[0].slide == 3)
        #expect(edited.currentChat.messages[0].text == "See [S3, S4, S1, C2] and `[S1]`.")
        #expect(edited.currentChat.messages[0].context == [.slide(4), .allSlides])
        #expect(edited.currentChat.messages[0].quiz[0].answer == "[S1]")
        #expect(try await store.loadLecture(moduleID: module.id, lectureID: lecture.id).pdfParts == edited.pdfParts)
        await #expect(throws: LibraryError.self) {
            try await store.editPDFs(edits, basedOn: parts, moduleID: module.id, lectureID: lecture.id)
        }
    }

    @Test func legacyMergedPDFCanBeSplitAndReordered() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let merged = try writePDF("Merged.pdf", pages: 4, width: 100, in: root)
        let store = LibraryStore(rootURL: root.appendingPathComponent("library"))
        let module = try await store.createModule(name: "Statistics")
        let legacy = try await store.createLecture(
            Lecture(moduleID: module.id, name: "Legacy", sourceFilename: "Merged.pdf", pageCount: 4),
            sourceURL: merged
        )
        let parts = legacy.editablePDFParts
        #expect(parts.count == 1 && parts[0].canSplit)
        let first = LecturePDFPart(filename: "First part", pageCount: 2, canSplit: true)
        let second = LecturePDFPart(filename: "Second part", pageCount: 2, canSplit: true)
        let edits: [LecturePDFEdit] = [.existing(second, pages: 2..<4), .existing(first, pages: 0..<2)]
        let edited = try await store.editPDFs(edits, basedOn: parts, moduleID: module.id, lectureID: legacy.id)
        #expect(edited.pdfParts == [second, first])
        #expect(widths(store.sourceURL(moduleID: module.id, lectureID: legacy.id)) == [102, 103, 100, 101])

        let backup = root.appendingPathComponent("lecture.json")
        try await store.exportBackup(moduleID: module.id, lectureID: legacy.id, to: backup)
        let restoredStore = LibraryStore(rootURL: root.appendingPathComponent("restored"))
        let restored = try await restoredStore.restoreBackup(from: backup)
        #expect(restored.pdfParts == [second, first])
        #expect(widths(restoredStore.sourceURL(moduleID: module.id, lectureID: legacy.id)) == [102, 103, 100, 101])
    }
}
