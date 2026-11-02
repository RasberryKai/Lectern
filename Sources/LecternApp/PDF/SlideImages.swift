import AppKit
import CryptoKit
import Foundation
import PDFKit
import SwiftUI

nonisolated struct PDFThumbnail: @unchecked Sendable {
    let image: NSImage
    let pageIndex: Int
}

nonisolated enum PDFThumbnailError: LocalizedError, Equatable, Sendable {
    case invalidRequest, unreadableSource, renderFailed
    var errorDescription: String? {
        switch self {
        case .invalidRequest: "The thumbnail request is invalid."
        case .unreadableSource: "The source PDF could not be opened."
        case .renderFailed: "The slide could not be rendered."
        }
    }
}

/// Ported from Slide Learning: lazy, cached slide rendering off the main actor.
/// Rendering only; AI input goes through LecternCore's PDFExporter.
actor PDFThumbnailProvider {
    static let shared = PDFThumbnailProvider()

    private let cacheDirectory: URL
    private var memoryCache: [String: PDFThumbnail] = [:]
    private var memoryOrder: [String] = []

    init(cacheDirectory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lectern/Thumbnails", isDirectory: true)) {
        self.cacheDirectory = cacheDirectory
    }

    /// `pageIndex` is zero based, matching PDFKit and `SlideState.pageIndex`.
    func thumbnail(sourceURL: URL, pageIndex: Int, width: CGFloat, scale: CGFloat = 2) async throws -> PDFThumbnail {
        try Task.checkCancellation()
        guard pageIndex >= 0, width > 0 else { throw PDFThumbnailError.invalidRequest }
        let bucket = (width / 80).rounded(.up) * 80   // a few sizes share one cache entry
        let cacheURL = cacheURL(sourceURL: sourceURL, pageIndex: pageIndex, width: bucket, scale: scale)
        let key = cacheURL.lastPathComponent
        if let hit = memoryCache[key] { return hit }
        if let image = NSImage(contentsOf: cacheURL) {
            let thumbnail = PDFThumbnail(image: image, pageIndex: pageIndex)
            remember(thumbnail, key: key)
            return thumbnail
        }
        let rendered: PDFThumbnail = try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            guard let document = PDFDocument(url: sourceURL), pageIndex < document.pageCount,
                  let page = document.page(at: pageIndex) else { throw PDFThumbnailError.unreadableSource }
            let bounds = page.bounds(for: .cropBox)
            let ratio = bounds.width > 0 ? bounds.height / bounds.width : 0.75
            let size = CGSize(width: bucket * scale, height: bucket * scale * ratio)
            return PDFThumbnail(image: page.thumbnail(of: size, for: .cropBox), pageIndex: pageIndex)
        }.value
        try Task.checkCancellation()
        try? store(rendered.image, at: cacheURL)
        remember(rendered, key: key)
        return rendered
    }

    private func remember(_ thumbnail: PDFThumbnail, key: String) {
        memoryCache[key] = thumbnail
        memoryOrder.append(key)
        if memoryOrder.count > 400 { memoryCache.removeValue(forKey: memoryOrder.removeFirst()) }
    }

    private func cacheURL(sourceURL: URL, pageIndex: Int, width: CGFloat, scale: CGFloat) -> URL {
        let values = try? sourceURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let fingerprint = "\(values?.fileSize ?? 0)-\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        let key = "\(sourceURL.path)|\(fingerprint)|\(pageIndex)|\(width)|\(scale)"
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return cacheDirectory.appendingPathComponent("\(digest).png")
    }

    private func store(_ image: NSImage, at url: URL) throws {
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .png, properties: [:]) else { throw PDFThumbnailError.renderFailed }
        try data.write(to: url, options: .atomic)
    }
}

/// A rendered slide that loads lazily and keeps its aspect ratio.
struct SlideImage: View {
    let sourceURL: URL
    /// Zero based.
    let pageIndex: Int
    var width: CGFloat
    var cornerRadius: CGFloat = 6
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            } else {
                Rectangle().fill(Theme.inset)
                    .aspectRatio(4 / 3, contentMode: .fit)
                    .overlay {
                        if failed {
                            Label("Slide \(pageIndex + 1) unavailable", systemImage: "exclamationmark.triangle")
                                .font(Theme.caption).foregroundStyle(Theme.quiet)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .task(id: "\(sourceURL.path)#\(pageIndex)#\(Int(width / 80))") {
            do {
                image = try await PDFThumbnailProvider.shared.thumbnail(sourceURL: sourceURL, pageIndex: pageIndex, width: width).image
                failed = false
            } catch is CancellationError {
            } catch { failed = true }
        }
        .accessibilityLabel("Slide \(pageIndex + 1)")
    }
}
