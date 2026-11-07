import Foundation
import CoreGraphics
import ImageIO
import Testing
@testable import LecternCore

@Suite struct ChatAttachmentStorageTests {
    private func image(_ type: String = "public.png") throws -> Data {
        let bitmap = try #require(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        bitmap.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)); bitmap.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let bytes = NSMutableData(); let destination = try #require(CGImageDestinationCreateWithData(bytes, type as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(bitmap.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination)); return bytes as Data
    }
    private func fixture() async throws -> (LibraryStore, Module, Lecture, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lectern-attachment-test-\(UUID())")
        let store = LibraryStore(rootURL: root.appendingPathComponent("library")); let module = try await store.createModule(name: "Images")
        let lecture = try await store.createLecture(Lecture(moduleID: module.id, name: "Lecture"))
        return (store, module, lecture, root)
    }
    private func attach(_ store: LibraryStore, _ lecture: Lecture, data: Data, name: String = "diagram.png", mediaType: String = "image/png") async throws -> ChatAttachment {
        try await store.importChatAttachment(moduleID: lecture.moduleID, lectureID: lecture.id, data: data, filename: name, mediaType: mediaType)
    }
    @Test func importValidatesTypeAndPersistsPrivateVerifiedBytes() async throws {
        let (store, _, lecture, root) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let png = try image(); let attachment = try await attach(store, lecture, data: png, name: "../../diagram.png")
        #expect(attachment.filename == "diagram.png"); #expect(attachment.byteCount == png.count); #expect(attachment.sha256 == PromptBuilder.hash(png))
        #expect(try await store.loadChatAttachment(moduleID: lecture.moduleID, lectureID: lecture.id, attachment: attachment) == png)
        let url = store.chatAttachmentURL(moduleID: lecture.moduleID, lectureID: lecture.id, attachment: attachment)
        #expect((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let jpeg = try image("public.jpeg"); let jpg = try await attach(store, lecture, data: jpeg, name: "image.jpg", mediaType: "image/jpeg")
        #expect(jpg.relativePath.hasSuffix(".jpg")); #expect(try await store.loadChatAttachment(moduleID: lecture.moduleID, lectureID: lecture.id, attachment: jpg) == jpeg)
        await #expect(throws: LibraryError.self) { try await attach(store, lecture, data: png, mediaType: "image/jpeg") }
        await #expect(throws: LibraryError.self) { try await attach(store, lecture, data: Data("not an image".utf8)) }
        await #expect(throws: LibraryError.self) { try await attach(store, lecture, data: Data(repeating: 1, count: ChatAttachment.maximumImageBytes + 1)) }
    }
    @Test func selectionAllowsManyImagesWhileEnforcingIndividualAndCombinedLimits() throws {
        func metadata(_ size: Int) -> ChatAttachment { ChatAttachment(filename: "image.png", mediaType: "image/png", byteCount: size, sha256: String(repeating: "a", count: 64)) }
        try ChatAttachment.validateSelection([metadata(5 * 1_024 * 1_024), metadata(5 * 1_024 * 1_024)])
        try ChatAttachment.validateSelection((0..<100).map { _ in metadata(1) })
        #expect(throws: LibraryError.self) { try ChatAttachment.validateSelection([metadata(5 * 1_024 * 1_024 + 1)]) }
        #expect(throws: LibraryError.self) { try ChatAttachment.validateSelection([metadata(5 * 1_024 * 1_024), metadata(5 * 1_024 * 1_024), metadata(1)]) }
        let duplicate = metadata(1)
        #expect(throws: LibraryError.self) { try ChatAttachment.validateSelection([duplicate, duplicate]) }
    }
    @Test func loadRejectsTamperingAndSymlinks() async throws {
        let (store, _, lecture, root) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let bytes = try image(); let attachment = try await attach(store, lecture, data: bytes)
        let url = store.chatAttachmentURL(moduleID: lecture.moduleID, lectureID: lecture.id, attachment: attachment)
        try Data(repeating: 0, count: bytes.count).write(to: url)
        await #expect(throws: LibraryError.self) { try await store.loadChatAttachment(moduleID: lecture.moduleID, lectureID: lecture.id, attachment: attachment) }
        try FileManager.default.removeItem(at: url); let external = root.appendingPathComponent("external.png"); try bytes.write(to: external)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: external)
        await #expect(throws: LibraryError.self) { try await store.loadChatAttachment(moduleID: lecture.moduleID, lectureID: lecture.id, attachment: attachment) }
    }
    @Test @MainActor func imageOnlyDraftSurvivesNewChatResumeAndNilPreservesSelection() async throws {
        let (store, _, lecture, root) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let attachment = try await attach(store, lecture, data: image())
        let session = LectureSession(lecture: lecture, store: store, runner: JobRunner(store: store, providers: []))
        try await session.setChatDraft("", attachments: [attachment]); let firstID = session.lecture.currentChat.id
        try await session.setChatDraft("Unsent"); #expect(session.lecture.currentChat.draftAttachments == [attachment])
        try await session.setChatDraft(""); try await session.newChat()
        #expect(session.lecture.archivedChats.first?.draftAttachments == [attachment])
        try await session.setChatDraft("", attachments: [attachment]); let secondID = session.lecture.currentChat.id
        try await session.openChat(id: firstID)
        #expect(session.lecture.currentChat.draftAttachments == [attachment]); #expect(session.lecture.archivedChats.contains(where: { $0.id == secondID }))
        try await session.setChatDraft("", attachments: []); #expect(session.lecture.currentChat.draftAttachments.isEmpty)
    }
    @Test func oldChatAndMessageJSONDecodeWithoutAttachments() throws {
        let message = ChatMessage(role: .user, text: "Old message"); let chat = LectureChat(messages: [message])
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(chat)) as! [String: Any]
        object.removeValue(forKey: "draftAttachments"); var messages = object["messages"] as! [[String: Any]]; messages[0].removeValue(forKey: "attachments"); object["messages"] = messages
        let decoded = try JSONDecoder().decode(LectureChat.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.draftAttachments.isEmpty); #expect(decoded.messages[0].attachments.isEmpty)
    }
    @Test func lectureAndModuleBackupsRestoreAllReferencedImages() async throws {
        let (store, module, lecture, root) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let bytes = try image(); let attachments = try await [attach(store, lecture, data: bytes), attach(store, lecture, data: bytes), attach(store, lecture, data: bytes), attach(store, lecture, data: bytes)]
        _ = try await store.updateLecture(moduleID: module.id, lectureID: lecture.id) { value in
            value.currentChat.draftAttachments = [attachments[0]]
            var currentMessage = ChatMessage(role: .user, text: "Current"); currentMessage.attachments = [attachments[1]]; value.currentChat.messages = [currentMessage]
            var earlierMessage = ChatMessage(role: .user, text: "Earlier"); earlierMessage.attachments = [attachments[2]]
            value.archivedChats = [LectureChat(messages: [earlierMessage], draftAttachments: [attachments[3]])]
        }
        let backup = root.appendingPathComponent("lecture.json"); let moduleBackup = root.appendingPathComponent("module.json")
        try await store.exportBackup(moduleID: module.id, lectureID: lecture.id, to: backup); try await store.exportModuleBackup(moduleID: module.id, to: moduleBackup)
        try FileManager.default.removeItem(at: store.rootURL)
        let restored = LibraryStore(rootURL: root.appendingPathComponent("restored")); let restoredLecture = try await restored.restoreBackup(from: backup)
        #expect(restoredLecture.currentChat.draftAttachments == [attachments[0]]); #expect(restoredLecture.archivedChats[0].draftAttachments == [attachments[3]])
        let restoredModule = LibraryStore(rootURL: root.appendingPathComponent("restored-module")); _ = try await restoredModule.restoreModuleBackup(from: moduleBackup)
        let existingModule = LibraryStore(rootURL: root.appendingPathComponent("existing-module")); _ = try await existingModule.createModule(module)
        _ = try await existingModule.restoreBackup(from: backup)
        for attachment in attachments {
            #expect(try await restored.loadChatAttachment(moduleID: module.id, lectureID: lecture.id, attachment: attachment) == bytes)
            #expect(try await restoredModule.loadChatAttachment(moduleID: module.id, lectureID: lecture.id, attachment: attachment) == bytes)
            #expect(try await existingModule.loadChatAttachment(moduleID: module.id, lectureID: lecture.id, attachment: attachment) == bytes)
        }
        var object = try JSONSerialization.jsonObject(with: Data(contentsOf: backup)) as! [String: Any]
        var blobs = object["chatAttachments"] as! [String: String]; blobs[attachments[0].relativePath] = Data("corrupt".utf8).base64EncodedString(); object["chatAttachments"] = blobs
        let corrupt = root.appendingPathComponent("corrupt.json"); try JSONSerialization.data(withJSONObject: object).write(to: corrupt)
        let rejected = LibraryStore(rootURL: root.appendingPathComponent("rejected"))
        await #expect(throws: LibraryError.self) { try await rejected.restoreBackup(from: corrupt) }; #expect(try await rejected.modules().isEmpty)
        var moduleObject = try JSONSerialization.jsonObject(with: Data(contentsOf: moduleBackup)) as! [String: Any]
        var entries = moduleObject["lectures"] as! [[String: Any]]; entries[0].removeValue(forKey: "chatAttachments"); moduleObject["lectures"] = entries
        let missingModuleImages = root.appendingPathComponent("missing-module-images.json"); try JSONSerialization.data(withJSONObject: moduleObject).write(to: missingModuleImages)
        let rejectedModule = LibraryStore(rootURL: root.appendingPathComponent("rejected-module"))
        await #expect(throws: LibraryError.self) { try await rejectedModule.restoreModuleBackup(from: missingModuleImages) }; #expect(try await rejectedModule.modules().isEmpty)
    }
    @Test func archivedLectureRejectsImportsAndOldBackupsStillRestore() async throws {
        let (store, module, lecture, root) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let backup = root.appendingPathComponent("old.json"); try await store.exportBackup(moduleID: module.id, lectureID: lecture.id, to: backup)
        var object = try JSONSerialization.jsonObject(with: Data(contentsOf: backup)) as! [String: Any]; object.removeValue(forKey: "chatAttachments")
        try JSONSerialization.data(withJSONObject: object).write(to: backup)
        let restored = LibraryStore(rootURL: root.appendingPathComponent("old-restored")); _ = try await restored.restoreBackup(from: backup)
        try await store.setLectureArchived(moduleID: module.id, lectureID: lecture.id, archived: true)
        let data = try image(); await #expect(throws: LibraryError.self) { try await attach(store, lecture, data: data) }
        try await store.setLectureArchived(moduleID: module.id, lectureID: lecture.id, archived: false)
        _ = try await store.setModuleArchived(moduleID: module.id, archived: true)
        await #expect(throws: LibraryError.self) { try await attach(store, lecture, data: data) }
    }
}
