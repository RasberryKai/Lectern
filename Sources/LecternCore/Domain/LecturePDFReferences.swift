import Foundation

extension Lecture {
    /// Remap references after the slides themselves have been moved.
    mutating func remapPDFReferences(_ oldToNew: [Int: Int]) {
        func page(_ value: Int) -> Int { oldToNew[value] ?? value }
        func pages(_ values: [Int]) -> [Int] { values.map(page).sorted() }
        func context(_ ref: ContextRef) -> ContextRef {
            if case .slide(let number) = ref { return .slide(page(number)) }
            return ref
        }
        func point(_ value: LearningPoint) -> LearningPoint {
            var value = value
            value.pages = pages(value.pages)
            value.evidence = value.evidence?.map { item in
                LearningPointEvidence(messageID: item.messageID, quote: ChatCitationMarkup.remapSlides(in: item.quote, using: oldToNew))
            }
            return value
        }
        func message(_ value: ChatMessage) -> ChatMessage {
            var value = value
            value.text = ChatCitationMarkup.remapSlides(in: value.text, using: oldToNew)
            value.citedPages = pages(value.citedPages)
            value.context = value.context.map(context)
            value.read = value.read.map(context)
            value.quiz = value.quiz.map {
                QuizItem(question: $0.question, answer: ChatCitationMarkup.remapSlides(in: $0.answer, using: oldToNew))
            }
            if let sources = value.suggestion?.sourcePages { value.suggestion?.sourcePages = pages(sources) }
            return value
        }
        func chat(_ value: LectureChat) -> LectureChat {
            var value = value
            value.messages = value.messages.map(message)
            value.summary = ChatCitationMarkup.remapSlides(in: value.summary, using: oldToNew)
            return value
        }
        for index in cards.indices {
            var card = cards[index]
            card.sourcePages = pages(card.sourcePages)
            card.allowedSourcePages = card.allowedSourcePages.map(pages)
            if var proposal = card.proposal {
                proposal.allowedSourcePages = proposal.allowedSourcePages.map(pages)
                for draft in proposal.cards.indices {
                    proposal.cards[draft].sourcePages = pages(proposal.cards[draft].sourcePages)
                }
                card.proposal = proposal
            }
            cards[index] = card
        }
        for index in threads.indices {
            threads[index].anchorPage = page(threads[index].anchorPage)
            threads[index].messages = threads[index].messages.map(message)
            threads[index].learningPoints = threads[index].learningPoints.map(point)
        }
        currentChat = chat(currentChat)
        archivedChats = archivedChats.map(chat)
        learningPoints = learningPoints.map(point)
        for index in jobs.indices { jobs[index].pages = pages(jobs[index].pages) }
        for index in skippedSlides.indices { skippedSlides[index].slide = page(skippedSlides[index].slide) }
        viewPreferences.focusedPageIndex = viewPreferences.focusedPageIndex.map { page($0 + 1) - 1 }
    }
}

extension ChatCitationMarkup {
    private static let markdownCitations = try! NSRegularExpression(
        pattern: #"```[\s\S]*?```|"# + literalPattern + #"|\[[^\]]+\]\((?:https?://|mailto:)[^)]*\)|"# + citationPattern
    )

    static func remapSlides(in text: String, using oldToNew: [Int: Int]) -> String {
        let original = text as NSString
        var result = text
        for match in markdownCitations.matches(in: text, range: NSRange(location: 0, length: original.length)).reversed() {
            // The final capture group belongs to the citation alternative.
            let citation = match.range(at: match.numberOfRanges - 1)
            guard citation.location != NSNotFound, let targets = targets(in: original.substring(with: citation)),
                  targets.contains(where: { kind, number in kind == "S" && oldToNew[number].map { $0 != number } == true }),
                  let range = Range(match.range, in: result) else { continue }
            let mapped = targets.map { kind, number in "\(kind)\(kind == "S" ? oldToNew[number] ?? number : number)" }
            result.replaceSubrange(range, with: "[" + mapped.joined(separator: ", ") + "]")
        }
        return result
    }
}
