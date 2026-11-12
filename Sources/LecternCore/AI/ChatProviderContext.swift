import Foundation

/// Provider access is limited to the immutable snapshot, never the live library.
struct ChatProviderContext {
    let request: AIRequest
    let snapshot: ChatSnapshot

    private func assetURL(_ relative: String) throws -> URL {
        let root = request.workingDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let url = root.appendingPathComponent(relative).standardizedFileURL
        guard (snapshot.images ?? []).contains(where: { $0.relativePath == relative }) || relative == "cards.json" || snapshot.cards.indices.contains(where: { relative == snapshot.cardPath(at: $0) }) || snapshot.slides.contains(where: {
            relative == String(format: "slides/%03d.png", $0.page) || relative == String(format: "slides/%03d.txt", $0.page)
        }), url.resolvingSymlinksInPath() == url,
              url.path.hasPrefix(root.path + "/"), FileManager.default.fileExists(atPath: url.path) else {
            throw AIError.configuration("The frozen chat context file is unavailable or outside its job folder: \(relative)")
        }
        return url
    }
    /// Validate exactly the bytes returned to an API attachment, avoiding a second read after verification.
    func data(_ relative: String) throws -> Data {
        let bytes: Data
        do { bytes = try Data(contentsOf: assetURL(relative)) }
        catch let error as AIError { throw error }
        catch { throw AIError.configuration("The frozen chat asset could not be read: \(relative). Send a new message or retry.") }
        if let image = snapshot.images?.first(where: { $0.relativePath == relative }) {
            guard let hashes = snapshot.assetHashes, hashes[relative] == image.attachment.sha256,
                  bytes.count == image.attachment.byteCount, PromptBuilder.hash(bytes) == image.attachment.sha256 else {
                throw AIError.configuration("The frozen uploaded image changed or its manifest is invalid. Send a new message.")
            }
        }
        if let hashes = snapshot.assetHashes {
            guard let expected = hashes[relative], PromptBuilder.hash(bytes) == expected else {
                throw AIError.configuration("The frozen chat context changed: \(relative). Send a new message using the current lecture context.")
            }
        }
        return bytes
    }
    func file(_ relative: String) throws -> URL {
        _ = try data(relative)
        return try assetURL(relative)
    }
    func verifyAssets() throws {
        guard let hashes = snapshot.assetHashes, Set(hashes.keys) == Set(allowedFiles) else {
            throw AIError.configuration("The frozen chat context has an incomplete asset manifest. Send a new message using the current lecture context.")
        }
        for relative in allowedFiles { _ = try data(relative) }
    }
    func image(page: Int) throws -> [String: Any] {
        guard snapshot.slides.contains(where: { $0.page == page }) else { throw AIError.invalidResponse("Unknown slide \(page).") }
        let data = try data(String(format: "slides/%03d.png", page))
        return ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": data.base64EncodedString()]]
    }
    func slides(_ pages: [Int]) throws -> [[String: Any]] {
        try pages.flatMap { page -> [[String: Any]] in
            guard let slide = snapshot.slides.first(where: { $0.page == page }) else { throw AIError.invalidResponse("Unknown slide \(page).") }
            return [["type": "text", "text": "[S\(page)]\n\(slide.text)\nNote: \(slide.note)"], try image(page: page)]
        }
    }
    func cards(_ ids: [UUID]) throws -> String {
        let payload = try ids.map { id -> ChatCardContent in
            guard let index = snapshot.cards.firstIndex(where: { $0.id == id }) else { throw AIError.invalidResponse("Unknown card \(id).") }
            return ChatCardContent(snapshot.cards[index], number: index + 1, includeEditIDs: true)
        }
        return try ChatContextJSON.encode(payload)
    }
    func cardIDs(_ references: [String]) throws -> [UUID] {
        guard !references.isEmpty else { throw AIError.invalidResponse("get_cards requires at least one card reference, such as C12.") }
        return try references.map { reference in
            if let id = UUID(uuidString: reference), snapshot.cards.contains(where: { $0.id == id }) { return id }
            if reference.hasPrefix("C"), let number = Int(reference.dropFirst()),
               number > 0, number <= snapshot.cards.count, reference == "C\(number)" {
                return snapshot.cards[number - 1].id
            }
            throw AIError.invalidResponse("Unknown card \(reference). Use a displayed reference such as C12 or a frozen card UUID.")
        }
    }
    var allowedFiles: [String] {
        (snapshot.images ?? []).map(\.relativePath) + ["cards.json"] + snapshot.cards.indices.map { snapshot.cardPath(at: $0) } + snapshot.slides.flatMap { [String(format: "slides/%03d.png", $0.page), String(format: "slides/%03d.txt", $0.page)] }
    }
    func uploadedImages(_ ids: [UUID]) throws -> [[String: Any]] {
        try ids.flatMap { id -> [[String: Any]] in
            guard let image = snapshot.images?.first(where: { $0.attachment.id == id }),
                  ["image/png", "image/jpeg"].contains(image.attachment.mediaType) else { throw AIError.invalidResponse("Unknown uploaded image ID or unsupported image format.") }
            let bytes = try data(image.relativePath)
            return [["type": "text", "text": "Uploaded image \(id.uuidString): \(image.attachment.filename) (message \(image.messageID.uuidString))"],
                    ["type": "image", "source": ["type": "base64", "media_type": image.attachment.mediaType, "data": bytes.base64EncodedString()]]]
        }
    }
    /// Existing job prompts already carry All cards inline. Verify the actual payload,
    /// rather than assuming an attachment chip proves that its contents were supplied.
    var hasVerifiedInlineDeck: Bool {
        inlineContextLines.contains { line in
            if snapshot.cardContextVersion == 1 {
                guard let cards = try? JSONDecoder().decode([ChatCardContent].self, from: Data(line.utf8)) else { return false }
                return cards == ChatCardContent.deck(snapshot.cards)
            }
            guard let cards = try? JSONDecoder().decode([Card].self, from: Data(line.utf8)) else { return false }
            return cards == snapshot.cards
        }
    }
    var hasVerifiedInlineSlides: Bool {
        let expected = snapshot.slides.map { ChatSlide(page: $0.page, text: $0.text, note: $0.note, imagePath: nil) }
        return inlineContextLines.contains { line in
            guard let slides = try? JSONDecoder().decode([ChatSlide].self, from: Data(line.utf8)) else { return false }
            return slides == expected
        }
    }
    private var inlineContextLines: [Substring] {
        guard let start = request.prompt.range(of: "\nFROZEN ATTACHED CONTEXT:\n"),
              let end = request.prompt.range(of: "\nLOOKUP: ", options: .backwards), start.upperBound <= end.lowerBound else { return [] }
        return request.prompt[start.upperBound..<end.lowerBound].split(separator: "\n")
    }
    func reference(for relative: String) -> ContextRef? {
        if relative == "cards.json" { return .allCards }
        if let index = snapshot.cards.indices.first(where: { snapshot.cardPath(at: $0) == relative }) { return .card(snapshot.cards[index].id) }
        if relative.hasPrefix("slides/"), let page = Int(URL(fileURLWithPath: relative).deletingPathExtension().lastPathComponent), snapshot.slides.contains(where: { $0.page == page }) { return .slide(page) }
        return nil
    }
    func initialContent() throws -> (blocks: [[String: Any]], refs: [ContextRef]) {
        var blocks: [[String: Any]] = [["type": "text", "text": request.prompt]]
        var refs: [ContextRef] = []
        func record(_ ref: ContextRef) { if !refs.contains(ref) { refs.append(ref) } }
        func attachSlide(_ page: Int) throws {
            guard !refs.contains(.slide(page)) else { return }
            blocks += try slides([page]); record(.slide(page))
        }
        for ref in snapshot.initialRefs {
            switch ref {
            case .slide(let page): try attachSlide(page)
            case .card(let id):
                blocks.append(["type": "text", "text": try cards([id])]); record(ref)
                if let card = snapshot.cards.first(where: { $0.id == id }) { for page in card.sourcePages { try attachSlide(page) } }
            case .allSlides:
                blocks.append(["type": "text", "text": snapshot.slides.map { "[S\($0.page)] \($0.text)\nNote: \($0.note)" }.joined(separator: "\n\n")]); record(ref)
            case .allCards:
                if !hasVerifiedInlineDeck {
                    blocks.append(["type": "text", "text": try ChatContextJSON.encode(ChatCardContent.deck(snapshot.cards))])
                }
                record(ref)
            }
        }
        blocks += try uploadedImages((snapshot.images ?? []).filter(\.isCurrent).map { $0.attachment.id })
        return (blocks, refs)
    }
}

/// Decode only the message value while structured JSON is arriving; never expose JSON syntax in chat.
struct ChatMessageStream {
    private var raw = ""
    private var emitted = ""
    mutating func append(_ text: String) -> String {
        raw += text
        guard let key = raw.range(of: #""message"\s*:\s*""#, options: .regularExpression) else { return "" }
        var literal = "\""
        var escaped = false
        for character in raw[key.upperBound...] {
            if character == "\"" && !escaped { break }
            literal.append(character)
            if character == "\\" { escaped.toggle() } else { escaped = false }
        }
        // Incomplete escapes and unicode sequences are withheld until the next delta.
        if escaped { literal.removeLast() }
        literal += "\""
        guard let value = try? JSONDecoder().decode(String.self, from: Data(literal.utf8)), value.hasPrefix(emitted) else { return "" }
        let delta = String(value.dropFirst(emitted.count)); emitted = value; return delta
    }
}

final class ChatPreviewEmitter: @unchecked Sendable {
    private let lock = NSLock()
    private var stream = ChatMessageStream()
    private var hasText = false
    private let onEvent: @Sendable (AIEvent) -> Void
    init(onEvent: @escaping @Sendable (AIEvent) -> Void) { self.onEvent = onEvent }
    func append(_ text: String) {
        let delta = lock.withLock { () -> String in
            let delta = stream.append(text); hasText = hasText || !delta.isEmpty; return delta
        }
        if !delta.isEmpty { onEvent(.text(delta)) }
    }
    var emitted: Bool { lock.withLock { hasText } }
}

/// Records successful CLI Read results as they arrive, so Stop preserves an honest trace.
final class ChatCLIReadTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [String: ContextRef] = [:]
    private var seen = Set<ContextRef>()
    private let context: ChatProviderContext
    private let onEvent: @Sendable (AIEvent) -> Void
    init(context: ChatProviderContext, onEvent: @escaping @Sendable (AIEvent) -> Void) { self.context = context; self.onEvent = onEvent }
    func receive(_ data: Data) {
        guard let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = event["message"] as? [String: Any], let blocks = message["content"] as? [[String: Any]] else { return }
        var completed: [ContextRef] = []
        lock.withLock {
            for block in blocks {
                if block["type"] as? String == "tool_use", block["name"] as? String == "Read", let id = block["id"] as? String,
                   let input = block["input"] as? [String: Any], let path = input["file_path"] as? String {
                    let url = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : context.request.workingDirectory.appendingPathComponent(path)).standardizedFileURL.resolvingSymlinksInPath()
                    if let file = context.allowedFiles.first(where: { context.request.workingDirectory.appendingPathComponent($0).standardizedFileURL.resolvingSymlinksInPath() == url }),
                       (try? context.file(file)) == url {
                        pending[id] = context.reference(for: file)
                    }
                }
                if block["type"] as? String == "tool_result", let id = block["tool_use_id"] as? String,
                   let ref = pending.removeValue(forKey: id), block["is_error"] as? Bool != true, seen.insert(ref).inserted { completed.append(ref) }
            }
        }
        for ref in completed { onEvent(.read(ref)) }
    }
}
