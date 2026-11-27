import Foundation

extension Lecture {
    /// Remap references after the slides themselves have been moved or removed.
    mutating func remapPDFReferences(_ oldToNew: [Int: Int], removing removed: Set<Int>, deletingCards deletedCards: Set<UUID>) {
        func page(_ value: Int) -> Int? {
            removed.contains(value) ? nil : oldToNew[value] ?? value
        }
        func pages(_ values: [Int]) -> [Int] { values.compactMap(page).sorted() }
        func citation(_ text: String) -> String { ChatCitationMarkup.remapSlides(in: text, using: oldToNew, removing: removed) }
        func context(_ ref: ContextRef) -> ContextRef? {
            switch ref {
            case .slide(let number): page(number).map(ContextRef.slide)
            case .card(let id) where deletedCards.contains(id): nil
            default: ref
            }
        }
        func point(_ value: LearningPoint) -> LearningPoint {
            var value = value
            value.pages = pages(value.pages)
            value.cardIDs?.removeAll(where: deletedCards.contains)
            if let target = value.draft?.replacesCardID, deletedCards.contains(target) { value.draft?.replacesCardID = nil }
            value.evidence = value.evidence?.map { item in
                LearningPointEvidence(messageID: item.messageID, quote: citation(item.quote))
            }
            return value
        }
        func message(_ value: ChatMessage) -> ChatMessage {
            var value = value
            value.text = citation(value.text)
            value.citedPages = pages(value.citedPages)
            value.context = value.context.compactMap(context)
            value.read = value.read.compactMap(context)
            value.quiz = value.quiz.map {
                QuizItem(question: $0.question, answer: citation($0.answer))
            }
            if let sources = value.suggestion?.sourcePages { value.suggestion?.sourcePages = pages(sources) }
            if let target = value.suggestion?.cardID, deletedCards.contains(target), value.suggestion?.state == .pending {
                value.suggestion?.state = .dismissed
            }
            return value
        }
        func chat(_ value: LectureChat) -> LectureChat {
            var value = value
            value.messages = value.messages.map(message)
            value.summary = citation(value.summary)
            return value
        }
        let generationIDs = deletedCards.isEmpty ? [:] : cardGenerationIDs
        cards.removeAll { deletedCards.contains($0.id) }
        for index in cards.indices {
            var card = cards[index]
            if case .splitFrom = card.origin, let jobID = generationIDs[card.id] {
                card.inheritedGenerationJobID = jobID
            }
            card.sourcePages = pages(card.sourcePages)
            card.allowedSourcePages = card.allowedSourcePages.map(pages)
            card.supersededBy?.removeAll(where: deletedCards.contains)
            if var proposal = card.proposal {
                proposal.allowedSourcePages = proposal.allowedSourcePages.map(pages)
                if proposal.cards.contains(where: { !$0.sourcePages.isEmpty && $0.sourcePages.allSatisfy(removed.contains) }) {
                    card.proposal = nil
                } else {
                    for draft in proposal.cards.indices {
                        proposal.cards[draft].sourcePages = pages(proposal.cards[draft].sourcePages)
                    }
                    card.proposal = proposal
                }
            }
            cards[index] = card
        }
        threads = threads.compactMap { thread in
            guard let anchor = page(thread.anchorPage) else { return nil }
            var thread = thread
            thread.anchorPage = anchor
            thread.messages = thread.messages.map(message)
            thread.learningPoints = thread.learningPoints.map(point)
            return thread
        }
        currentChat = chat(currentChat)
        archivedChats = archivedChats.map(chat)
        learningPoints = learningPoints.map(point)
        for index in jobs.indices { jobs[index].pages = pages(jobs[index].pages) }
        skippedSlides = skippedSlides.compactMap { skipped in
            page(skipped.slide).map { SkippedSlide(slide: $0, reason: skipped.reason) }
        }
        viewPreferences.focusedPageIndex = viewPreferences.focusedPageIndex.flatMap { index in page(index + 1).map { $0 - 1 } }
        if let selected = viewPreferences.selectedCardID, deletedCards.contains(selected) { viewPreferences.selectedCardID = nil }
    }
}

extension ChatCitationMarkup {
    private static let markdownCitations = try! NSRegularExpression(
        pattern: #"```[\s\S]*?```|"# + literalPattern + #"|\[[^\]]+\]\((?:https?://|mailto:)[^)]*\)|"# + citationPattern
    )

    static func remapSlides(in text: String, using oldToNew: [Int: Int], removing removed: Set<Int>) -> String {
        let original = text as NSString
        var result = text
        for match in markdownCitations.matches(in: text, range: NSRange(location: 0, length: original.length)).reversed() {
            // The final capture group belongs to the citation alternative.
            let citation = match.range(at: match.numberOfRanges - 1)
            guard citation.location != NSNotFound, let targets = targets(in: original.substring(with: citation)),
                  targets.contains(where: { kind, number in
                      kind == "S" && (removed.contains(number) || oldToNew[number].map { $0 != number } == true)
                  }),
                  let range = Range(match.range, in: result) else { continue }
            let mapped = targets.filter { kind, number in kind != "S" || !removed.contains(number) }
                .map { kind, number in "\(kind)\(kind == "S" ? oldToNew[number] ?? number : number)" }
            result.replaceSubrange(range, with: mapped.isEmpty ? "(slide removed)" : "[" + mapped.joined(separator: ", ") + "]")
        }
        return result
    }
}
