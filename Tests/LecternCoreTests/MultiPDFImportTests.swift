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
}
