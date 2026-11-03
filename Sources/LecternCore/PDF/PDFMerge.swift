import Foundation
import PDFKit

/// Helpers for importing several PDFs as one lecture. The files are merged into one
/// `source.pdf` at import; afterwards the lecture is indistinguishable from a single-file one.
public enum PDFMerge {
    /// Validates one file and returns its page count. The error names the file.
    public static func pageCount(of url: URL) throws -> Int {
        let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try open(url).pageCount
    }

    /// Natural file-name order: `Part 2` before `Part 10`.
    public static func naturalOrder(_ urls: [URL]) -> [URL] {
        urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Lecture name from the shared start of the file names, e.g. `05_Hypothesis_Tests_Part1.pdf` and
    /// `05_Hypothesis_Tests_Part2.pdf` give `05 Hypothesis Tests`. When not all files share a start
    /// (an extra exercise sheet), the files that share the first file's first word decide.
    public static func suggestedName(for filenames: [String]) -> String {
        let tokenized = filenames.map(tokens)
        guard let first = tokenized.first, !first.isEmpty else { return "" }
        var shared = commonPrefix(tokenized)
        if shared.isEmpty {
            let group = tokenized.filter { $0.first?.lowercased() == first[0].lowercased() }
            if group.count >= 2 { shared = commonPrefix(group) }
        }
        let connectors: Set<String> = ["part", "teil", "pt", "and", "und", "&", "+"]
        while let last = shared.last, connectors.contains(last.lowercased()) { shared.removeLast() }
        return (shared.isEmpty ? first : shared).joined(separator: " ")
    }

    /// Merges `urls` in the given order into one PDF at `destination` and returns its page count.
    /// Fails without writing anything if any file is locked, empty or unreadable.
    @discardableResult
    public static func merge(_ urls: [URL], to destination: URL) throws -> Int {
        guard !urls.isEmpty else { throw LibraryError.invalid("Choose at least one PDF.") }
        let scoped = urls.map { $0.startAccessingSecurityScopedResource() }
        defer { for (url, didStart) in zip(urls, scoped) where didStart { url.stopAccessingSecurityScopedResource() } }
        let sources = try urls.map(open)
        let merged = PDFDocument()
        for source in sources {
            for index in 0..<source.pageCount {
                guard let page = source.page(at: index)?.copy() as? PDFPage else {
                    throw LibraryError.invalid("Page \(index + 1) of \(source.documentURL?.lastPathComponent ?? "a PDF") can't be read.")
                }
                merged.insert(page, at: merged.pageCount)
            }
        }
        guard merged.write(to: destination) else { throw LibraryError.invalid("Couldn't write the merged PDF.") }
        return merged.pageCount
    }

    private static func open(_ url: URL) throws -> PDFDocument {
        let name = url.lastPathComponent
        guard let pdf = PDFDocument(url: url) else { throw LibraryError.invalid("\(name) can't be read as a PDF.") }
        guard !pdf.isLocked else { throw LibraryError.invalid("\(name) is password-protected. Unlock it first.") }
        guard pdf.pageCount > 0 else { throw LibraryError.invalid("\(name) has no pages.") }
        return pdf
    }

    private static func tokens(_ filename: String) -> [String] {
        let stem = (filename as NSString).deletingPathExtension
        return stem.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
            .split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private static func commonPrefix(_ lists: [[String]]) -> [String] {
        guard var prefix = lists.first else { return [] }
        for list in lists.dropFirst() {
            var count = 0
            while count < min(prefix.count, list.count), prefix[count].lowercased() == list[count].lowercased() { count += 1 }
            prefix = Array(prefix.prefix(count))
        }
        return prefix
    }
}
