import Foundation
import Testing
import AppKit
@testable import LecternCore

@Suite(.serialized)
struct ChatImageProviderTests {
    private func fixture() throws -> (AIRequest, URL, ChatSnapshotImage, ChatSnapshotImage) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lectern-chat-image-\(UUID())")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("attachments"), withIntermediateDirectories: true)
        try Data("[]".utf8).write(to: root.appendingPathComponent("cards.json"))
        let currentBytes = Data("current-png-fixture".utf8), priorBytes = Data("prior-jpeg-fixture".utf8)
        let current = ChatSnapshotImage(attachment: ChatAttachment(filename: "current.png", mediaType: "image/png", byteCount: currentBytes.count, sha256: PromptBuilder.hash(currentBytes)), messageID: UUID(), isCurrent: true)
        let prior = ChatSnapshotImage(attachment: ChatAttachment(filename: "prior.jpg", mediaType: "image/jpeg", byteCount: priorBytes.count, sha256: PromptBuilder.hash(priorBytes)), messageID: UUID(), isCurrent: false)
        try currentBytes.write(to: root.appendingPathComponent(current.relativePath)); try priorBytes.write(to: root.appendingPathComponent(prior.relativePath))
        var snapshot = ChatSnapshot(slides: [], cards: [], initialRefs: [])
        snapshot.images = [prior, current]
        snapshot.assetHashes = ["cards.json": PromptBuilder.hash(Data("[]".utf8)), current.relativePath: current.attachment.sha256, prior.relativePath: prior.attachment.sha256]
        var request = AIRequest(jobID: UUID(), kind: .chat, model: "opus", prompt: "Image metadata only", pdf: nil, workingDirectory: root)
        request.chatSnapshot = snapshot
        return (request, root, current, prior)
    }

    @Test func currentImagesAreMultimodalWhilePriorImagesAreLookupOnly() throws {
        let (request, root, current, prior) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let context = ChatProviderContext(request: request, snapshot: request.chatSnapshot!)
        try context.verifyAssets()
        let initial = try context.initialContent()
        let images = initial.blocks.filter { $0["type"] as? String == "image" }
        #expect(images.count == 1); #expect(initial.refs.isEmpty)
        #expect((images[0]["source"] as? [String: Any])?["media_type"] as? String == "image/png")
        let currentData = try context.data(current.relativePath).base64EncodedString()
        #expect((images[0]["source"] as? [String: Any])?["data"] as? String == currentData)
        #expect(!request.prompt.contains(currentData))
        let lookup = try context.uploadedImages([prior.attachment.id])
        #expect((lookup.last?["source"] as? [String: Any])?["media_type"] as? String == "image/jpeg")
        #expect(context.reference(for: current.relativePath) == nil)
        #expect(throws: AIError.self) { try context.uploadedImages([UUID()]) }
    }

    @Test func cliRequiresActualCurrentImageReadWithoutInventingLectureTrace() throws {
        let (request, root, current, prior) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let args = try ClaudeCLIProvider.arguments(for: request, model: "opus", pdfURL: nil)
        #expect(args.contains { $0.contains(current.relativePath) }); #expect(args.contains { $0.contains(prior.relativePath) })
        let prompt = try ClaudeCLIProvider.inputPrompt(for: request, pdfURL: nil)
        #expect(prompt.replacingOccurrences(of: "\\/", with: "/").contains(current.relativePath)); #expect(!prompt.contains("current-png-fixture"))
        let final: [String: Any] = ["type": "result", "subtype": "success", "stop_reason": "tool_use", "structured_output": ["message": "Image explained.", "edits": [], "quiz": []]]
        let finalData = try JSONSerialization.data(withJSONObject: final)
        #expect(throws: AIError.self) { try ClaudeCLIProvider.parseChatStream(finalData, request: request, snapshot: request.chatSnapshot!, onEvent: { _ in }) }
        let path = root.appendingPathComponent(current.relativePath).path
        let events: [[String: Any]] = [
            ["type": "assistant", "message": ["content": [["type": "tool_use", "name": "Read", "id": "image1", "input": ["file_path": path]]]]],
            ["type": "user", "message": ["content": [["type": "tool_result", "tool_use_id": "image1", "content": "Image bytes"]]]], final
        ]
        let bytes = try events.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n")
        let response = try ClaudeCLIProvider.parseChatStream(Data(bytes.utf8), request: request, snapshot: request.chatSnapshot!, onEvent: { _ in })
        #expect(response.read.isEmpty); #expect(!response.searchedLecture)
    }

    @Test func frozenImageManifestRejectsTamperingAndSymlinks() throws {
        let (request, root, current, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let context = ChatProviderContext(request: request, snapshot: request.chatSnapshot!)
        let image = root.appendingPathComponent(current.relativePath)
        try Data("tampered".utf8).write(to: image)
        #expect(throws: AIError.self) { try context.verifyAssets() }
        #expect(throws: AIError.self) { try context.uploadedImages([current.attachment.id]) }
        try FileManager.default.removeItem(at: image)
        try FileManager.default.createSymbolicLink(at: image, withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        #expect(throws: AIError.self) { try context.data(current.relativePath) }
        var missing = request.chatSnapshot!; missing.assetHashes = nil
        #expect(throws: AIError.self) { try ChatProviderContext(request: request, snapshot: missing).uploadedImages([current.attachment.id]) }
    }

    @Test func oldSnapshotsDecodeWithoutImagesAndKeepTheirAssetAllowlist() throws {
        let snapshot = try JSONDecoder().decode(ChatSnapshot.self, from: Data(#"{"slides":[],"cards":[],"initialRefs":[]}"#.utf8))
        #expect(snapshot.images == nil)
        let request = AIRequest(jobID: UUID(), kind: .chat, model: "opus", prompt: "", pdf: nil, workingDirectory: URL(fileURLWithPath: "/private/tmp"))
        #expect(ChatProviderContext(request: request, snapshot: snapshot).allowedFiles == ["cards.json"])
    }

    @Test func apiLooksUpPriorUploadsAsImageToolResults() async throws {
        let (request, root, current, prior) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        ImageToolProtocol.state.configure([
            Self.events([["type": "tool_use", "id": "lookup1", "name": "read_images", "input": ["ids": [prior.attachment.id.uuidString]]]], stop: "tool_use"),
            Self.events([["type": "text", "text": #"{"message":"Compared the images.","edits":[],"quiz":[]}"#]], stop: "end_turn")
        ])
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ImageToolProtocol.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        let provider = MessagesAPIProvider(apiKey: { "offline-fixture" }, session: session, endpoint: URL(string: "https://image-provider.test/messages")!)
        let response = try await provider.execute(request, onEvent: { _ in })
        #expect(response.read.isEmpty); #expect(!response.searchedLecture)
        let bodies = ImageToolProtocol.state.bodies
        #expect(bodies.count == 2)
        let first = try JSONSerialization.jsonObject(with: bodies[0]) as! [String: Any]
        let second = try JSONSerialization.jsonObject(with: bodies[1]) as! [String: Any]
        let firstText = String(decoding: try JSONSerialization.data(withJSONObject: first, options: .withoutEscapingSlashes), as: UTF8.self)
        let secondText = String(decoding: try JSONSerialization.data(withJSONObject: second, options: .withoutEscapingSlashes), as: UTF8.self)
        #expect(firstText.contains("image/png")); #expect(!firstText.contains("image/jpeg"))
        #expect(firstText.contains(try Data(contentsOf: root.appendingPathComponent(current.relativePath)).base64EncodedString()))
        #expect(secondText.contains("image/jpeg")); #expect(secondText.contains("tool_result"))
    }

    @Test @MainActor func imageOnlyAndPriorUploadsFreezeForImmutableRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lectern-image-runner-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(rootURL: root)
        let module = try await store.createModule(name: "Images")
        let lecture = try await store.createLecture(Lecture(moduleID: module.id, name: "Image lecture"))
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.setColor(.red, atX: 0, y: 0)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        var uploads: [ChatAttachment] = []
        for index in 0..<6 {
            uploads.append(try await store.importChatAttachment(moduleID: module.id, lectureID: lecture.id, data: png, filename: "diagram-\(index).png", mediaType: "image/png"))
        }
        let upload = try #require(uploads.first)
        let provider = ImageCaptureProvider()
        let imageRunner = JobRunner(store: store, providers: [provider])
        let session = LectureSession(lecture: lecture, store: store, runner: imageRunner)
        try await session.setChatDraft("", attachments: uploads)
        #expect(try await store.loadLecture(moduleID: module.id, lectureID: lecture.id).currentChat.draftAttachments == uploads)
        let first = try await imageRunner.chat(moduleID: module.id, lectureID: lecture.id, question: "", contextRefs: [], attachments: uploads)
        await imageRunner.waitUntilIdle()
        let persisted = try await store.loadLecture(moduleID: module.id, lectureID: lecture.id)
        #expect(persisted.currentChat.title == "Image question")
        #expect(persisted.currentChat.messages.first?.text == "")
        #expect(persisted.currentChat.messages.first?.attachments == uploads)
        let requests = await provider.requests
        let original = try #require(requests.first)
        #expect(original.chatSnapshot?.images?.count == 6)
        #expect(try ChatProviderContext(request: original, snapshot: original.chatSnapshot!).initialContent().blocks.filter { $0["type"] as? String == "image" }.count == 6)
        let image = try #require(original.chatSnapshot?.images?.first)
        #expect(image.isCurrent); #expect(image.messageID == persisted.currentChat.messages.first?.id)
        #expect(original.prompt.contains("Describe and analyze")); #expect(!original.prompt.contains(png.base64EncodedString()))
        #expect(try Data(contentsOf: store.jobDirectory(moduleID: module.id, lectureID: lecture.id, jobID: first).appendingPathComponent(image.relativePath)) == png)
        // The upload remains available after its original message falls outside text history.
        _ = try await store.updateLecture(moduleID: module.id, lectureID: lecture.id) { latest in
            for index in 0..<24 { latest.currentChat.messages.append(ChatMessage(role: index.isMultiple(of: 2) ? .user : .assistant, text: "Later turn \(index)")) }
        }
        let followup = try await imageRunner.chat(moduleID: module.id, lectureID: lecture.id, question: "Explain the previous diagram", contextRefs: [])
        await imageRunner.waitUntilIdle()
        let afterFollowup = await provider.requests
        let frozen = try #require(afterFollowup.last)
        #expect(frozen.chatSnapshot?.images?.count == 6)
        #expect(frozen.chatSnapshot?.images?.first?.isCurrent == false)
        #expect(frozen.chatSnapshot?.images?.first?.attachment.id == upload.id)
        #expect(frozen.chatSnapshot?.images?.first?.messageID == persisted.currentChat.messages.first?.id)
        #expect(frozen.prompt.contains(upload.id.uuidString))
        #expect(frozen.prompt.contains("PRIOR UPLOAD"))
        let priorLookup = try ChatProviderContext(request: frozen, snapshot: frozen.chatSnapshot!).uploadedImages([upload.id])
        #expect((priorLookup.last?["source"] as? [String: Any])?["data"] as? String == png.base64EncodedString())
        #expect(try ChatProviderContext(request: frozen, snapshot: frozen.chatSnapshot!).initialContent().blocks.filter { $0["type"] as? String == "image" }.isEmpty)
        try FileManager.default.removeItem(at: store.chatAttachmentURL(moduleID: module.id, lectureID: lecture.id, attachment: upload))
        try await imageRunner.retryLectureChat(moduleID: module.id, lectureID: lecture.id, jobID: followup)
        await imageRunner.waitUntilIdle()
        let retried = await provider.requests
        #expect(retried.last == frozen)
        let count = retried.count
        try Data("tampered".utf8).write(to: frozen.workingDirectory.appendingPathComponent(image.relativePath))
        await #expect(throws: AIError.self) { try await imageRunner.retryLectureChat(moduleID: module.id, lectureID: lecture.id, jobID: followup) }
        #expect(await provider.requests.count == count)
    }

    private static func events(_ blocks: [[String: Any]], stop: String) -> Data {
        var events: [[String: Any]] = [["type": "message_start", "message": ["usage": ["input_tokens": 1]]]]
        for (index, block) in blocks.enumerated() { events += [["type": "content_block_start", "index": index, "content_block": block], ["type": "content_block_stop", "index": index]] }
        events += [["type": "message_delta", "delta": ["stop_reason": stop], "usage": ["output_tokens": 1]], ["type": "message_stop"]]
        return Data(events.map { "data: " + String(decoding: try! JSONSerialization.data(withJSONObject: $0), as: UTF8.self) + "\n\n" }.joined().utf8)
    }
}

private final class ImageToolState: @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [Data] = [], captured: [Data] = []
    var bodies: [Data] { lock.withLock { captured } }
    func configure(_ data: [Data]) { lock.withLock { responses = data; captured = [] } }
    func next(_ request: URLRequest) -> Data {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; body.append(contentsOf: buffer.prefix(count)) }
        }
        return lock.withLock { captured.append(body); return responses.isEmpty ? Data() : responses.removeFirst() }
    }
}
private final class ImageToolProtocol: URLProtocol {
    static let state = ImageToolState()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "image-provider.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let data = Self.state.next(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["content-type": "text/event-stream"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private actor ImageCaptureProvider: AIProvider {
    nonisolated let backend = AIBackend.claudeCLI
    var requests: [AIRequest] = []
    func execute(_ request: AIRequest, onEvent: @escaping @Sendable (AIEvent) -> Void) async throws -> AIResponse {
        if request.kind == .distil { return AIResponse(content: #"{"learningPoints":[],"summary":""}"#) }
        requests.append(request)
        return AIResponse(content: #"{"message":"Image explained.","edits":[],"quiz":[]}"#)
    }
}
