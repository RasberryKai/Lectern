// Ported from Slide Learning; source page indices remain zero based.
import CoreGraphics
import CoreText
import Foundation
import PDFKit

public struct PDFExportPlan: Sendable, Equatable {
    public let sourceURL: URL
    public let managedProjectsRootURL: URL?
    public let selectedPageIndices: [Int]
    public let notesByPageIndex: [Int: String]

    public init(
        sourceURL: URL,
        managedProjectsRootURL: URL? = nil,
        selectedPageIndices: [Int],
        notesByPageIndex: [Int: String] = [:]
    ) {
        self.sourceURL = sourceURL
        self.managedProjectsRootURL = managedProjectsRootURL
        self.selectedPageIndices = selectedPageIndices
        self.notesByPageIndex = notesByPageIndex
    }
}

public struct PDFExportResult: Sendable, Equatable {
    public let destinationURL: URL
    public let outputPageCount: Int
    public init(destinationURL: URL, outputPageCount: Int) { self.destinationURL = destinationURL; self.outputPageCount = outputPageCount }
}

public protocol PDFSnapshotExporting: Sendable {
    func export(_ plan: PDFExportPlan, to destinationURL: URL) async throws -> PDFExportResult
}

public enum PDFExportError: LocalizedError, Equatable, Sendable {
    case noSelection
    case unreadableSource
    case encryptedSource
    case destinationInsideProject
    case invalidPage(Int)
    case cannotCreateContext
    case cannotCreateDestination(String)
    case invalidOutput
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .noSelection: "Select at least one slide before exporting."
        case .unreadableSource: "The copied source PDF could not be opened."
        case .encryptedSource: "Password-protected PDFs are not supported."
        case .destinationInsideProject: "Choose an export location outside the project folder."
        case .invalidPage(let page): "Source slide \(page + 1) could not be read."
        case .cannotCreateContext: "The export PDF could not be created."
        case .cannotCreateDestination(let message): message
        case .invalidOutput: "The export PDF did not pass validation."
        case .failed(let message): message
        }
    }
}

/// Composes exported pages directly from PDF page operators. It intentionally
/// has no concept of annotations or on-slide editing: the only additions are
/// the source-number footer and the separate plain-text notes region.
public struct PDFExporter: PDFSnapshotExporting, @unchecked Sendable {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func export(_ plan: PDFExportPlan, to destinationURL: URL) async throws -> PDFExportResult {
        let work = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try exportSynchronously(plan, to: destinationURL, fileManager: fileManager)
        }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: { work.cancel() }
    }

    private func exportSynchronously(
        _ plan: PDFExportPlan,
        to destinationURL: URL,
        fileManager: FileManager
    ) throws -> PDFExportResult {
        let selected = Array(Set(plan.selectedPageIndices)).sorted()
        guard !selected.isEmpty else { throw PDFExportError.noSelection }
        guard !isInsideManagedProjectsRoot(destinationURL, rootURL: plan.managedProjectsRootURL) else {
            throw PDFExportError.destinationInsideProject
        }
        guard let source = CGPDFDocument(plan.sourceURL as CFURL) else {
            throw PDFExportError.unreadableSource
        }
        guard !source.isEncrypted, source.isUnlocked else {
            throw PDFExportError.encryptedSource
        }

        let parent = destinationURL.deletingLastPathComponent()
        let temporaryURL = parent.appendingPathComponent(".slide-learning-export-\(UUID().uuidString).pdf")
        var completed = false
        defer {
            if !completed { try? fileManager.removeItem(at: temporaryURL) }
        }

        guard let context = CGContext(temporaryURL as CFURL, mediaBox: nil, nil) else {
            throw PDFExportError.cannotCreateContext
        }

        var outputPageCount = 0
        var contextClosed = false
        defer {
            if !contextClosed {
                context.closePDF()
            }
        }

        for index in selected {
            try Task.checkCancellation()
            guard index >= 0, index < source.numberOfPages,
                  let page = source.page(at: index + 1) else {
                throw PDFExportError.invalidPage(index)
            }
            let note = plan.notesByPageIndex[index] ?? ""
            let layout = try PageLayout(page: page, note: note)
            drawPage(layout, sourcePage: page, sourceNumber: index + 1, context: context)
            outputPageCount += 1

            var remaining = layout.remainingNote
            while !remaining.isEmpty {
                try Task.checkCancellation()
                let continuation = try PageLayout.continuation(width: layout.width, note: remaining)
                drawContinuation(continuation, sourceNumber: index + 1, context: context)
                outputPageCount += 1
                remaining = continuation.remainingNote
            }
        }

        context.closePDF()
        contextClosed = true

        guard let output = PDFDocument(url: temporaryURL), output.pageCount == outputPageCount,
              output.pageCount > 0,
              output.isLocked == false,
              outputContainsExpectedContent(output, selected: selected, notes: plan.notesByPageIndex) else {
            throw PDFExportError.invalidOutput
        }

        do {
            if fileManager.fileExists(atPath: destinationURL.path) {
                _ = try fileManager.replaceItemAt(destinationURL, withItemAt: temporaryURL)
            } else {
                try fileManager.moveItem(at: temporaryURL, to: destinationURL)
            }
        } catch {
            throw PDFExportError.cannotCreateDestination("Could not place the exported PDF: \(error.localizedDescription)")
        }
        completed = true
        return PDFExportResult(destinationURL: destinationURL, outputPageCount: outputPageCount)
    }
}

private func isInsideManagedProjectsRoot(_ destinationURL: URL, rootURL: URL?) -> Bool {
    guard let rootURL else { return false }
    let sourceDirectory = rootURL.standardizedFileURL.resolvingSymlinksInPath().path
    let destination = destinationURL.standardizedFileURL.resolvingSymlinksInPath().path
    return destination == sourceDirectory || destination.hasPrefix(sourceDirectory + "/")
}

private func outputContainsExpectedContent(
    _ output: PDFDocument,
    selected: [Int],
    notes: [Int: String]
) -> Bool {
    let strings = (0..<output.pageCount).compactMap { output.page(at: $0)?.string }
    let outputText = normalizeWhitespace(strings.joined(separator: " "))
    guard selected.allSatisfy({ sourceNumber in
        strings.contains { $0.contains("Source slide \(sourceNumber + 1)") }
    }) else { return false }
    return notes.filter { selected.contains($0.key) && !$0.value.isEmpty }.allSatisfy {
        let tokens = normalizeWhitespace($0.value).split(separator: " ")
        return tokens.allSatisfy { outputText.contains($0) }
    }
}

private func normalizeWhitespace(_ text: String) -> String {
    text.split { $0.isWhitespace }.joined(separator: " ")
}

typealias PDFExportService = PDFExporter

private struct PageLayout {
    static let footerHeight: CGFloat = 26
    static let maximumFirstNotesHeight: CGFloat = 260
    static let continuationHeight: CGFloat = 720
    static let margin: CGFloat = 18
    static let minimumPageWidth: CGFloat = 144

    let width: CGFloat
    let slideHeight: CGFloat
    let notesHeight: CGFloat
    let note: String
    let remainingNote: String

    init(page: CGPDFPage, note: String) throws {
        let crop = page.getBoxRect(.cropBox)
        guard crop.width.isFinite, crop.height.isFinite, crop.width > 0, crop.height > 0 else {
            throw PDFExportError.failed("The source page has invalid bounds.")
        }
        let rotation = ((page.rotationAngle % 360) + 360) % 360
        let rotated = rotation == 90 || rotation == 270
        let orientedWidth = rotated ? crop.height : crop.width
        let orientedHeight = rotated ? crop.width : crop.height
        let scale = max(1, Self.minimumPageWidth / orientedWidth)
        width = orientedWidth * scale
        slideHeight = orientedHeight * scale
        guard !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            self.note = ""
            notesHeight = 0
            remainingNote = ""
            return
        }

        let contentWidth = max(1, width - 2 * Self.margin)
        let measured = measure(note: note, width: contentWidth)
        notesHeight = min(Self.maximumFirstNotesHeight, max(72, measured + 48))
        let remainder = try visibleRemainder(note: note, width: contentWidth, height: max(1, notesHeight - 46))
        remainingNote = remainder
        self.note = prefix(note, excluding: remainder)
    }

    private init(width: CGFloat, note: String) throws {
        self.width = width
        slideHeight = 0
        notesHeight = Self.continuationHeight
        let remainder = try visibleRemainder(note: note, width: max(1, width - 2 * Self.margin),
                                              height: Self.continuationHeight - 62)
        self.note = prefix(note, excluding: remainder)
        remainingNote = remainder
    }

    static func continuation(width: CGFloat, note: String) throws -> PageLayout {
        guard !note.isEmpty else { throw PDFExportError.invalidOutput }
        return try PageLayout(width: width, note: note)
    }
}

private func drawPage(_ layout: PageLayout, sourcePage: CGPDFPage, sourceNumber: Int, context: CGContext) {
    let pageRect = CGRect(x: 0, y: 0, width: layout.width,
                          height: layout.slideHeight + PageLayout.footerHeight + layout.notesHeight)
    beginPage(context, rect: pageRect)

    let slideRect = CGRect(x: 0, y: PageLayout.footerHeight + layout.notesHeight,
                           width: layout.width, height: layout.slideHeight)
    context.saveGState()
    let transform = sourcePage.getDrawingTransform(.cropBox, rect: slideRect, rotate: 0, preserveAspectRatio: true)
    context.concatenate(transform)
    context.drawPDFPage(sourcePage)
    context.restoreGState()

    drawText("Source slide \(sourceNumber)", in: CGRect(x: PageLayout.margin, y: 6,
        width: max(1, layout.width - 2 * PageLayout.margin), height: 16), context: context, fontSize: 10)
    if layout.notesHeight > 0 {
        drawText("Notes", in: CGRect(x: PageLayout.margin,
            y: PageLayout.footerHeight + layout.notesHeight - 30,
            width: max(1, layout.width - 2 * PageLayout.margin), height: 16), context: context, fontSize: 12)
        drawText(layout.note, in: CGRect(x: PageLayout.margin, y: PageLayout.footerHeight + 10,
            width: max(1, layout.width - 2 * PageLayout.margin), height: max(1, layout.notesHeight - 46)),
            context: context, fontSize: 11)
    }
    context.endPDFPage()
}

private func drawContinuation(_ layout: PageLayout, sourceNumber: Int, context: CGContext) {
    let pageRect = CGRect(x: 0, y: 0, width: layout.width,
                          height: PageLayout.continuationHeight)
    beginPage(context, rect: pageRect)
    drawText("Notes for source slide \(sourceNumber)",
             in: CGRect(x: PageLayout.margin, y: pageRect.height - 32,
                        width: max(1, layout.width - 2 * PageLayout.margin), height: 18),
             context: context, fontSize: 12)
    drawText(layout.note, in: CGRect(x: PageLayout.margin, y: 18,
                                     width: max(1, layout.width - 2 * PageLayout.margin), height: pageRect.height - 62),
             context: context, fontSize: 11)
    context.endPDFPage()
}

private func beginPage(_ context: CGContext, rect: CGRect) {
    var value = rect
    let data = Data(bytes: &value, count: MemoryLayout<CGRect>.size)
    context.beginPDFPage([kCGPDFContextMediaBox as String: data] as CFDictionary)
}

private func drawText(_ string: String, in rect: CGRect, context: CGContext, fontSize: CGFloat) {
    guard !string.isEmpty, rect.width > 0, rect.height > 0 else { return }
    let attributes: [NSAttributedString.Key: Any] = [
        .font: CTFontCreateWithName("Helvetica" as CFString, fontSize, nil),
        .foregroundColor: CGColor(gray: 0, alpha: 1)
    ]
    let attributed = NSAttributedString(string: string, attributes: attributes)
    let framesetter = CTFramesetterCreateWithAttributedString(attributed)
    let path = CGPath(rect: rect, transform: nil)
    let frame = CTFramesetterCreateFrame(framesetter, CFRangeMake(0, attributed.length), path, nil)
    CTFrameDraw(frame, context)
}

private func measure(note: String, width: CGFloat) -> CGFloat {
    let attributed = NSAttributedString(string: note, attributes: [
        .font: CTFontCreateWithName("Helvetica" as CFString, 11, nil)
    ])
    let framesetter = CTFramesetterCreateWithAttributedString(attributed)
    var fitRange = CFRange()
    let size = CTFramesetterSuggestFrameSizeWithConstraints(
        framesetter, CFRangeMake(0, attributed.length), nil,
        CGSize(width: width, height: CGFloat.greatestFiniteMagnitude), &fitRange)
    return size.height
}

private func visibleRemainder(note: String, width: CGFloat, height: CGFloat) throws -> String {
    let attributed = NSAttributedString(string: note, attributes: [
        .font: CTFontCreateWithName("Helvetica" as CFString, 11, nil)
    ])
    let framesetter = CTFramesetterCreateWithAttributedString(attributed)
    let frame = CTFramesetterCreateFrame(framesetter, CFRangeMake(0, attributed.length),
        CGPath(rect: CGRect(x: 0, y: 0, width: width, height: height), transform: nil), nil)
    let visible = CTFrameGetVisibleStringRange(frame)
    guard visible.location >= 0,
          visible.length > 0,
          visible.location + visible.length <= attributed.length else {
        throw PDFExportError.invalidOutput
    }
    guard visible.location + visible.length < attributed.length else { return "" }
    return (note as NSString).substring(from: visible.location + visible.length)
}

private func prefix(_ full: String, excluding suffix: String) -> String {
    guard !suffix.isEmpty else { return full }
    let count = max(0, full.utf16.count - suffix.utf16.count)
    return (full as NSString).substring(to: count)
}
