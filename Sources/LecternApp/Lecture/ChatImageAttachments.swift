import AppKit
import ImageIO
import LecternCore
import SwiftUI
import UniformTypeIdentifiers

nonisolated enum ChatImageInput: Sendable {
    case file(URL)
    case data(Data, filename: String)

    static func images(on pasteboard: NSPasteboard) -> [ChatImageInput] {
        let files = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
            .filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }
        if !files.isEmpty { return files.map(Self.file) }
        if let data = pasteboard.data(forType: .png) { return [.data(data, filename: "Pasted image.png")] }
        if let data = pasteboard.data(forType: .tiff) { return [.data(data, filename: "Pasted image.tiff")] }
        for type in pasteboard.types ?? [] {
            guard let imageType = UTType(type.rawValue), imageType.conforms(to: .image),
                  let data = pasteboard.data(forType: type) else { continue }
            return [.data(data, filename: "Pasted image." + (imageType.preferredFilenameExtension ?? "png"))]
        }
        if let image = pasteboard.readObjects(forClasses: [NSImage.self])?.first as? NSImage,
           let data = image.tiffRepresentation { return [.data(data, filename: "Pasted image.tiff")] }
        return []
    }

    /// Decode one frame, apply orientation, and bound the upload independently of
    /// the source format. Claude accepts the resulting PNG/JPEG on both backends.
    func normalized() throws -> (data: Data, filename: String, mediaType: String) {
        let bytes: Data
        let filename: String
        switch self {
        case .file(let url):
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 25 * 1_024 * 1_024 else { throw LibraryError.invalid("Choose an image smaller than 25 MB.") }
            bytes = try Data(contentsOf: url, options: .mappedIfSafe)
            filename = url.lastPathComponent
        case .data(let data, let name): bytes = data; filename = name
        }
        guard bytes.count <= 25 * 1_024 * 1_024,
              let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              let sourceType = CGImageSourceGetType(source) as String?, UTType(sourceType)?.conforms(to: .image) == true,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2_048,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw LibraryError.invalid("This image couldn’t be opened. Choose a valid image file.") }
        func encode(_ type: UTType, quality: Double? = nil) -> Data? {
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else { return nil }
            let options = quality.map { [kCGImageDestinationLossyCompressionQuality: $0] as CFDictionary }
            CGImageDestinationAddImage(destination, image, options)
            return CGImageDestinationFinalize(destination) ? output as Data : nil
        }
        let base = (filename as NSString).deletingPathExtension
        if let png = encode(.png), png.count <= 5 * 1_024 * 1_024 {
            return (png, base + ".png", "image/png")
        }
        guard let jpeg = encode(.jpeg, quality: 0.85), jpeg.count <= 5 * 1_024 * 1_024 else {
            throw LibraryError.invalid("This image is too large to attach. Try a smaller image.")
        }
        return (jpeg, base + ".jpg", "image/jpeg")
    }
}

extension LectureWindowModel {
    var canAttachChatImages: Bool { !readOnly && !isImportingChatImages && !isStartingChat && !isClosing }
    func chooseChatImages() {
        guard !readOnly, !isImportingChatImages, !isStartingChat else { return }
        let panel = NSOpenPanel()
        panel.title = "Attach images"
        panel.message = "Up to 4 images per message, 10 MiB total."
        panel.prompt = "Attach"
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { Task { await importChatImages(panel.urls.map(ChatImageInput.file)) } }
    }

    func importChatImages(_ inputs: [ChatImageInput]) async {
        guard !inputs.isEmpty else { return }
        _ = await prepareChatImages(count: inputs.count) { inputs }
    }

    func importChatImageProviders(_ providers: [NSItemProvider]) async -> Bool {
        await prepareChatImages(count: providers.count) {
            var images: [ChatImageInput] = []
            for provider in providers {
                if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                    let data = try await Self.imageDropData(provider, type: UTType.fileURL.identifier)
                    guard let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL else {
                        throw LibraryError.invalid("This dropped image file couldn’t be opened.")
                    }
                    images.append(.file(url))
                } else if let type = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true }) {
                    let data = try await Self.imageDropFileData(provider, type: type)
                    let name = provider.suggestedName ?? "Dropped image.\(UTType(type)?.preferredFilenameExtension ?? "png")"
                    images.append(.data(data, filename: name))
                } else { throw LibraryError.invalid("Drop image files to attach them to chat.") }
            }
            return images
        }
    }

    private static func imageDropData(_ provider: NSItemProvider, type: String) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: type) { data, error in
                if let data, data.count <= 25 * 1_024 * 1_024 { continuation.resume(returning: data) }
                else if data != nil { continuation.resume(throwing: LibraryError.invalid("Choose an image smaller than 25 MB.")) }
                else { continuation.resume(throwing: error ?? LibraryError.invalid("This dropped image couldn’t be loaded.")) }
            }
        }
    }

    private static func imageDropFileData(_ provider: NSItemProvider, type: String) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                do {
                    guard let url else { throw error ?? LibraryError.invalid("This dropped image couldn’t be loaded.") }
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= 25 * 1_024 * 1_024 else { throw LibraryError.invalid("Choose an image smaller than 25 MB.") }
                    // Item-provider temporary files are valid only inside this callback.
                    let data = try Data(contentsOf: url, options: .mappedIfSafe)
                    guard data.count <= 25 * 1_024 * 1_024 else { throw LibraryError.invalid("Choose an image smaller than 25 MB.") }
                    continuation.resume(returning: data)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func prepareChatImages(count: Int, _ load: () async throws -> [ChatImageInput]) async -> Bool {
        guard canAttachChatImages else { return false }
        guard count > 0, chatDraftAttachments.count + count <= ChatAttachment.maximumImageCount else {
            chatAttachmentError = "Attach up to 4 images per message."
            return false
        }
        let chatID = lecture.currentChat.id
        isImportingChatImages = true
        chatAttachmentError = nil
        chatDraftSaveTask?.cancel()
        defer { isImportingChatImages = false }
        do {
            let inputs = try await load()
            guard lecture.currentChat.id == chatID, !isClosing else { return false }
            guard chatDraftAttachments.count + inputs.count <= ChatAttachment.maximumImageCount else {
                throw LibraryError.invalid("Attach up to 4 images per message.")
            }
            let normalized = try await Task.detached(priority: .userInitiated) { try inputs.map { try $0.normalized() } }.value
            guard lecture.currentChat.id == chatID, !isClosing else { return false }
            let totalBytes = chatDraftAttachments.reduce(0) { $0 + $1.byteCount } + normalized.reduce(0) { $0 + $1.data.count }
            guard totalBytes <= ChatAttachment.maximumSelectionBytes else { throw LibraryError.invalid("Attached images must total at most 10 MiB per message.") }
            var additions: [ChatAttachment] = []
            for image in normalized {
                let attachment = try await app.store.importChatAttachment(moduleID: ref.moduleID, lectureID: ref.lectureID, data: image.data, filename: image.filename, mediaType: image.mediaType)
                additions.append(attachment)
            }
            try ChatAttachment.validateSelection(chatDraftAttachments + additions)
            chatDraftAttachments += additions
            // Cancel any text save scheduled while decoding; persist the latest
            // text and images as one draft so an older task cannot erase images.
            chatDraftSaveTask?.cancel()
            try await session.setChatDraft(chatDraft, attachments: chatDraftAttachments, chatID: chatID)
            return true
        } catch { chatAttachmentError = Self.describe(error); return false }
    }

    func removeChatImage(_ id: UUID) {
        guard !readOnly, !isStartingChat else { return }
        chatDraftAttachments.removeAll { $0.id == id }
        chatAttachmentError = nil
        setChatDraft(chatDraft)
    }
}

struct ChatAttachmentStrip: View {
    let model: LectureWindowModel
    let attachments: [ChatAttachment]
    var remove: ((UUID) -> Void)?
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    ChatAttachmentThumbnail(model: model, attachment: attachment, remove: remove)
                }
            }.padding(3)
        }
    }
}

private struct ChatAttachmentThumbnail: View {
    let model: LectureWindowModel
    let attachment: ChatAttachment
    let remove: ((UUID) -> Void)?
    @State private var image: NSImage?
    @State private var failed = false
    @State private var preview = false
    var body: some View {
        Button { preview = true } label: {
            Group {
                if let image { Image(nsImage: image).resizable().scaledToFill() }
                else { Image(systemName: failed ? "exclamationmark.triangle" : "photo").foregroundStyle(Theme.quiet) }
            }.frame(width: 74, height: 64).background(Theme.inset).clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.border))
        }.buttonStyle(.plain).help(attachment.filename).accessibilityLabel("Preview \(attachment.filename)")
            .onDrag {
                guard image != nil else { return NSItemProvider() }
                return NSItemProvider(contentsOf: model.app.store.chatAttachmentURL(moduleID: model.ref.moduleID, lectureID: model.ref.lectureID, attachment: attachment)) ?? NSItemProvider()
            }
            .overlay(alignment: .topTrailing) {
                if let remove {
                    Button { remove(attachment.id) } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).frame(width: 24, height: 24)
                            .background(Theme.surface.opacity(0.95), in: Circle()).contentShape(Circle())
                    }.buttonStyle(.plain).help("Remove \(attachment.filename)")
                        .accessibilityLabel("Remove \(attachment.filename)").offset(x: 3, y: -3)
                }
            }
            .popover(isPresented: $preview) {
                VStack(alignment: .leading, spacing: 10) {
                    if let image { Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: 640, maxHeight: 480) }
                    else { Text("This image is unavailable.").font(Theme.body) }
                    Text(attachment.filename).font(Theme.caption).foregroundStyle(Theme.quiet)
                }.padding(14)
            }
            .task(id: attachment.id) {
                do {
                    let data = try await model.app.store.loadChatAttachment(moduleID: model.ref.moduleID, lectureID: model.ref.lectureID, attachment: attachment)
                    image = NSImage(data: data)
                    failed = image == nil
                } catch { failed = true }
            }
    }
}
