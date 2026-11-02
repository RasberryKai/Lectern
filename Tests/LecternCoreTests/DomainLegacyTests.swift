import Foundation
import XCTest
@testable import LecternCore

final class FlashcardDomainTests: XCTestCase {
    func testDollarMathWrappersConvertOnlyInAnkiExportAndPreserveSource() throws {
        let source = #"inline $x + 1$; display $$y^2$$; \(z\); \[w\]; \neq"#
        let card = Flashcard(front: source, back: "Answer", verdict: .good)
        let session = FlashcardSession(title: "Math", cards: [card])

        let formatted = try FlashcardMathFormatter.formatForAnki(source)
        XCTAssertEqual(formatted, #"inline \(x + 1\); display \[y^2\]; \(z\); \[w\]; \neq"#)

        let anki = try CardExport.ankiText(session: session)
        XCTAssertTrue(anki.contains(#"inline \(x + 1\); display \[y^2\]"#))
        XCTAssertEqual(session.cards[0].front, source)
    }

    func testCurrencyAndLoneDollarSignsRemainLiteralText() throws {
        let source = #"Price $5; range $5 and $10; a lone $ sign."#
        let spans = FlashcardMathAnalyzer.analyze(source)

        XCTAssertTrue(spans.contains { $0.kind == .currencyOrProse })
        XCTAssertFalse(spans.contains(where: \.requiresChoice))
        XCTAssertEqual(try FlashcardMathFormatter.formatForAnki(source), source)

        let card = Flashcard(front: source, back: "Cost", verdict: .good)
        let anki = try CardExport.ankiText(session: FlashcardSession(title: "Prices", cards: [card]))
        XCTAssertTrue(anki.contains(source))
    }

    func testAmbiguousAndUnmatchedDollarMathRequireAndUseExplicitChoices() throws {
        let ambiguous = #"$hello world$"#
        let card = Flashcard(front: "Define \(ambiguous)", back: "Meaning", verdict: .good)
        let session = FlashcardSession(title: "Ambiguous", cards: [card])
        let analyzed = FlashcardMathAnalyzer.analyze(card.front)
        XCTAssertTrue(analyzed.contains { $0.source == ambiguous && $0.requiresChoice })

        XCTAssertThrowsError(try CardExport.ankiText(session: session)) { error in
            guard case CardExportError.unresolvedMathChoice(let cardID, let side, let span) = error else {
                return XCTFail("Expected an actionable unresolved math choice error.")
            }
            XCTAssertEqual(cardID, card.id)
            XCTAssertEqual(side, .front)
            XCTAssertEqual(span, ambiguous)
            XCTAssertTrue((error as? LocalizedError)?.errorDescription?.contains("Keep as text") == true)
        }

        var keepAsText = session
        keepAsText.cards[0].mathInterpretations[ambiguous] = .keepAsText
        XCTAssertTrue(try CardExport.ankiText(session: keepAsText).contains(ambiguous))

        var treatAsMath = session
        treatAsMath.cards[0].mathInterpretations[ambiguous] = .treatAsMath
        XCTAssertTrue(try CardExport.ankiText(session: treatAsMath).contains(#"\(hello world\)"#))

        let unmatched = #"$x + 1"#
        XCTAssertTrue(FlashcardMathAnalyzer.analyze(unmatched).contains {
            $0.kind == .unmatchedDollar && $0.requiresChoice
        })
        XCTAssertThrowsError(try FlashcardMathFormatter.formatForAnki(unmatched))
        XCTAssertEqual(
            try FlashcardMathFormatter.formatForAnki(unmatched, interpretations: [unmatched: .treatAsMath]),
            #"\(x + 1\)"#
        )

        let unmatchedCard = Flashcard(front: unmatched, back: "Answer", verdict: .good)
        XCTAssertThrowsError(try CardExport.ankiText(session: FlashcardSession(title: "Unmatched", cards: [unmatchedCard])))
        var resolvedUnmatched = FlashcardSession(title: "Unmatched", cards: [unmatchedCard])
        resolvedUnmatched.cards[0].mathInterpretations[unmatched] = .treatAsMath
        XCTAssertTrue(try CardExport.ankiText(session: resolvedUnmatched).contains(#"\(x + 1\)"#))
    }

    func testAnkiFieldsEscapeTabsNewlinesQuotesHTMLAndUnicode() throws {
        let front = "Q\t\"é\" <tag> &"
        let back = "line 1\nline \"2\" <β> &"
        let card = Flashcard(front: front, back: back, verdict: .good)
        let anki = try CardExport.ankiText(session: FlashcardSession(title: "Fields", cards: [card]))

        XCTAssertTrue(anki.contains("#columns:Front\tBack"))
        XCTAssertTrue(anki.contains("\"Q\t\"\"é\"\" &lt;tag&gt; &amp;\""))
        XCTAssertTrue(anki.contains("\"line 1<br>line \"\"2\"\" &lt;β&gt; &amp;\""))
    }

    func testApprovedInterchangePreservesSeparatorBoundaryWhitespace() throws {
        let card = Flashcard(front: " front ", back: "\tanswer\t", verdict: .good)
        let session = FlashcardSession(title: "Padding", cards: [card])

        let interchange = try CardExport.approvedText(session: session)
        let report = DeckParser.parse(interchange)
        XCTAssertEqual(report.cards.count, 1)
        XCTAssertEqual(report.cards[0].front, card.front)
        XCTAssertEqual(report.cards[0].back, card.back)
    }

    func testPastedExampleKeepsNumberedAnswerContinuationsOnTheirCards() {
        let source = """
        Which direction is 'upstream' in a value chain? == Toward the raw material producers; downstream points toward the consumer
        What is an OEM in a supply chain? == The manufacturer that assembles suppliers' parts into the final product and sells it under its own brand, e.g. the carmaker (original equipment manufacturer)
        Backward integration == A downstream player takes over activities of its upstream suppliers
        Forward integration == An upstream player takes over activities of its downstream buyers
        Supply side vs. demand side of a firm's primary functions? == The supply side produces the offering (sourcing, manufacturing, logistics); the demand side sells it (marketing, sales, service)
        What are a firm's secondary (support) functions? == Functions that enable the operating value chain without being part of it, e.g. HR, finance, IT, R&D (Porter's value chain)
        Only valid purpose of a business, according to Peter Drucker? == To create a customer (Drucker)
        What role does profit play in Drucker's definition of business? == It is not the purpose of business but a limiting factor on it (Drucker)
        Per Drucker, what decides what a business is and whether it prospers? == What the customer thinks he is buying and considers valuable, not what the firm thinks it produces (Drucker)
        Two basic (entrepreneurial) functions of every business, per Drucker? == 1. Marketing
        2. Innovation
        Why does Drucker say a business has only two basic functions? == Its purpose is to create a customer, and only marketing and innovation do that
        Which function does Drucker call the unique, central function of a business? == Marketing, because it distinguishes a business from all other organizations
        Why should a firm ask 'What business are you REALLY in?' == Defining the business by customer benefit, not product, reveals disruptive technologies early (avoids marketing myopia, Levitt)
        Two markets a company competes in, per the strategic triangles (3C) model? == 1. Sales market: against competing suppliers for customers (customer value)
        2. Capital market: against competing investment alternatives for investors (ROI)
        Three types of attributes in Kano's customer satisfaction model? == 1. Hygiene (basic): missing them causes dissatisfaction, having them doesn't delight (points-of-parity)
        2. Excitement: delight when present, no dissatisfaction when missing (points-of-difference)
        3. Performance: satisfaction rises and falls with how well they are fulfilled
        Points-of-difference (POD) == Characteristics that differentiate a product or service from the competition
        Four elements of a positioning statement? == 1. Target group: who are we aiming at?
        2. Reference point: who are our competitors?
        3. Point-of-difference: what makes us better (primary benefit, USP)?
        4. Reason-to-believe: why should people trust us?
        Three basic motives that drive customers? == 1. Security (safety, belonging, nurture)
        2. Arousal (novelty, variety, play)
        3. Autonomy (power, performance, prestige)
        Brand network == A pattern in customers' brains linking a brand's codes to motives
        Three types of scarcity that give a supplier monopoly power, and how each is built? == 1. Unique value ('best', quality monopoly): innovation, brand and service management
        2. Unique volume ('last', quantity monopoly): capacity management
        3. Unique vendor ('first', question monopoly): sales channel and relationship management
        Where does profit come from in the scarcity view of competition? == From creating legal monopolies, i.e. offers customers can't get elsewhere (unique selling propositions, USP)
        Tit for tat in a repeated pricing game? == Cooperate until the rival defects, then retaliate for one round
        Grim trigger in a repeated pricing game? == Cooperate until the rival defects, then retaliate until the end of the game
        Price leadership / signaling? == One firm sets the market price or announces price increases in advance so rivals can follow
        Puppy dog ploy? == A small entrant isn't attacked because a price war would hurt the market leader's profit more than the newcomer's
        Three questions for selecting a target segment (a cluster of consumers with similar preferences)? == 1. Is it large enough?
        2. How strong is the competition there?
        3. Do we have the capability to serve it?
        Core idea of Blue Ocean Strategy (Kim and Mauborgne)? == Invent new value dimensions to create uncontested markets, making competition irrelevant instead of fighting rivals in existing ones
        How did Michael Porter change the perspective of industrial economics? == From a regulation lens (pushing 'excess' profits down) to a profit lens (how firms can push profits up) (Porter)
        Two main deviations from perfect competition that let firms earn profits, per Porter? == 1. Differentiated value: higher value at the same costs (differentiation)
        2. Cost differences: lower costs at the same value (cost leadership)
        How does the popular matrix of Porter's generic strategies arrange them? == 1. x-axis: how to compete, from cost leadership to differentiation
        2. y-axis: where to compete, from niche to general mass market
        Are cost leadership and differentiation an either-or choice? == No, they are points on a continuum: what counts is your cost-to-value gap versus competitors'
        Necessary criterion for profit in the cost-price-value framework? == Creating value for money: customers' willingness to pay clearly exceeds your costs
        Sufficient criterion for profit in the cost-price-value framework? == Capturing money for value: being able to enforce a price close to the customer's WTP (price advantage)
        Why does a uniform price leave money on the table? == Some customers would pay more than the price, while others would buy at a lower price that still covers costs
        What is price differentiation? == Charging different customers different prices according to their willingness to pay (economists: price discrimination)
        Why is price differentiation the key to profit? == It captures the profit potential a uniform price leaves unused by skimming each customer's WTP more closely
        Essence of a business model? == A concept of how the company makes money, i.e. how revenues end up exceeding costs
        """

        let report = DeckParser.parse(source)
        XCTAssertEqual(report.cards.count, 37)
        XCTAssertEqual(report.validEntryCount, 37)
        XCTAssertEqual(report.needsFixingCount, 0)
        XCTAssertTrue(report.warnings.isEmpty)
        XCTAssertEqual(report.blankLineCount, 0)

        XCTAssertEqual(
            report.cards.first { $0.front.hasPrefix("Two basic (entrepreneurial)") }?.back,
            "1. Marketing\n2. Innovation"
        )
        XCTAssertEqual(
            report.cards.first { $0.front.hasPrefix("Three types of attributes") }?.back,
            "1. Hygiene (basic): missing them causes dissatisfaction, having them doesn't delight (points-of-parity)\n"
                + "2. Excitement: delight when present, no dissatisfaction when missing (points-of-difference)\n"
                + "3. Performance: satisfaction rises and falls with how well they are fulfilled"
        )
        XCTAssertEqual(
            report.cards.first { $0.front.hasPrefix("Four elements of a positioning") }?.back.components(separatedBy: "\n").count,
            4
        )
        XCTAssertEqual(report.cards.first { $0.front.hasPrefix("Four elements of a positioning") }?.sourceLineNumber, 21)
    }

    func testUnnumberedMalformedLineAfterNumberedAnswerStillNeedsFixing() {
        let report = DeckParser.parse("List == 1. First item\nmalformed entry")

        XCTAssertEqual(report.cards.count, 2)
        XCTAssertEqual(report.cards[0].back, "1. First item")
        XCTAssertEqual(report.cards[0].sourceLineNumber, 1)
        XCTAssertEqual(report.cards[1].issue?.kind, .missingSeparator)
        XCTAssertEqual(report.cards[1].sourceLineNumber, 2)
        XCTAssertEqual(report.needsFixingCount, 1)
    }

    func testParserBackupRoundTripPersistsChoicesWarningsAndSelection() throws {
        let report = DeckParser.parse("Q == A\nQ == A\nOther == B")
        XCTAssertEqual(report.cards.count, 3)
        XCTAssertTrue(report.warnings.contains { $0.kind == .exactDuplicate })
        let parsedCardIDs = Set(report.cards.map(\.id))
        XCTAssertTrue(report.warnings.allSatisfy { Set($0.cardIDs).isSubset(of: parsedCardIDs) })
        let selectedID = report.cards[0].id
        var selectedCard = report.cards[0]
        selectedCard.mathInterpretations = [
            #"$hello world$"#: .keepAsText,
            #"$x + 1$"#: .treatAsMath
        ]
        var cards = report.cards
        cards[0] = selectedCard
        let session = FlashcardSession(
            title: "Backed up",
            cards: cards,
            importWarnings: report.warnings,
            selectedCardID: selectedID,
            reviewFilter: "needsAdjustment"
        )

        let restored = try SessionBackup.decode(SessionBackup.encode(session))
        XCTAssertEqual(restored.cards[0].mathInterpretations, selectedCard.mathInterpretations)
        XCTAssertEqual(restored.title, session.title)
        XCTAssertEqual(restored.importWarnings, report.warnings)
        XCTAssertEqual(restored.selectedCardID, selectedID)
        XCTAssertEqual(restored.reviewFilter, "needsAdjustment")
    }

    func testOlderBackupsDefaultNewMathAndImportMetadataFields() throws {
        let card = Flashcard(front: "Q", back: "A")
        let session = FlashcardSession(title: "Older", cards: [card])
        let data = try SessionBackup.encode(session)
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var sessionObject = try XCTUnwrap(root["session"] as? [String: Any])
        sessionObject.removeValue(forKey: "importWarnings")
        var cards = try XCTUnwrap(sessionObject["cards"] as? [[String: Any]])
        cards[0].removeValue(forKey: "mathInterpretations")
        sessionObject["cards"] = cards
        root["session"] = sessionObject

        let legacyData = try JSONSerialization.data(withJSONObject: root)
        let restored = try SessionBackup.decode(legacyData)
        XCTAssertEqual(restored.cards[0].mathInterpretations, [:])
        XCTAssertEqual(restored.importWarnings, [])
    }

    func testBackupsIgnoreRemovedBatchLabelAndOmitItOnExport() throws {
        let session = FlashcardSession(
            title: "Existing session",
            cards: [Flashcard(front: "Q", back: "A")],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: SessionBackup.encode(session)) as? [String: Any])
        var sessionObject = try XCTUnwrap(root["session"] as? [String: Any])
        sessionObject["batchLabel"] = "Legacy source"
        root["session"] = sessionObject

        let restored = try SessionBackup.decode(JSONSerialization.data(withJSONObject: root))
        XCTAssertEqual(restored, session)
        let exported = try XCTUnwrap(JSONSerialization.jsonObject(with: SessionBackup.encode(restored)) as? [String: Any])
        let exportedSession = try XCTUnwrap(exported["session"] as? [String: Any])
        XCTAssertNil(exportedSession["batchLabel"])
    }

    func testDedicatedAnkiFixtureCoversEscapingAndMathExport() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/AnkiImportFixture.txt")
        let source = try String(contentsOf: fixtureURL, encoding: .utf8)
        var report = DeckParser.parse(source)
        XCTAssertEqual(report.cards.count, 8)
        XCTAssertEqual(report.needsFixingCount, 0)
        XCTAssertTrue(report.warnings.isEmpty)

        for index in report.cards.indices { report.cards[index].verdict = .good }
        let session = FlashcardSession(title: "Anki fixture", cards: report.cards)
        let anki = try CardExport.ankiText(session: session)
        XCTAssertTrue(anki.contains("Café 漢字"))
        XCTAssertTrue(anki.contains("&lt;tag&gt; &amp; attr"))
        XCTAssertTrue(anki.contains(#"\(x^2 + y^2\)"#))
        XCTAssertTrue(anki.contains(#"\[\frac{a}{b}\]"#))
        XCTAssertTrue(anki.contains("<br>"))
        XCTAssertTrue(anki.contains("$5 and $10"))
    }

    func testFortyEntriesRetainOrderAndAccountForBlanksDuplicatesAndIssues() throws {
        let ordinary = (1...40).map { "Question \($0) == Answer \($0)" }.joined(separator: "\n")
        let source = ordinary + "\n\nQuestion 1 == Answer 1\nmalformed entry\nEmpty front == \n"
        let report = DeckParser.parse(source)

        XCTAssertEqual(report.cards.count, 43)
        XCTAssertEqual(report.cards.prefix(40).map(\.front), (1...40).map { "Question \($0)" })
        XCTAssertTrue(report.cards.allSatisfy { $0.verdict == .unreviewed })
        XCTAssertEqual(report.validEntryCount, 41)
        XCTAssertEqual(report.needsFixingCount, 2)
        XCTAssertEqual(report.blankLineCount, 1)
        XCTAssertTrue(report.warnings.contains { $0.kind == .exactDuplicate })
        XCTAssertEqual(report.cards[41].issue?.kind, .missingSeparator)
        XCTAssertEqual(report.cards[42].issue?.kind, .emptySide)
    }

    func testAIRevisionBriefIncludesOnlyAdjustmentCardsWithFeedbackInOrder() throws {
        let good = Flashcard(front: "Good front", back: "Good back", verdict: .good)
        let unreviewed = Flashcard(front: "Unreviewed front", back: "Unreviewed back")
        let adjustment = Flashcard(front: "Revised front", back: "Revised back", originalFront: "Old front", verdict: .needsAdjustment, notes: "Keep the definition concise")
        let rejected = Flashcard(front: "Reject without replacement", back: "Rejected answer", verdict: .bad)
        let replacement = Flashcard(front: "Replacement topic", back: "Old answer", verdict: .bad, notes: "Use a better example", replacementRequested: true)
        let secondAdjustment = Flashcard(front: "Second adjustment", back: "Second answer", verdict: .needsAdjustment)
        let session = FlashcardSession(
            title: "Complete deck",
            cards: [good, unreviewed, adjustment, rejected, replacement, secondAdjustment]
        )

        let brief = try CardExport.aiRevisionBrief(session: session)
        for required in [
            "Old front", "Revised front", "Keep the definition concise",
            "Second adjustment", "Second answer",
            "Complete deck", "Return only the revised cards", "separate session"
        ] {
            XCTAssertTrue(brief.localizedCaseInsensitiveContains(required), "Missing AI context: \(required)")
        }
        for excluded in [
            "Good front", "Good back", "Unreviewed front", "Unreviewed back",
            "Reject without replacement", "Rejected answer", "Replacement topic", "Old answer",
            "Use a better example", "replacementRequested"
        ] {
            XCTAssertFalse(brief.contains(excluded), "Unexpected AI context: \(excluded)")
        }
        let json = try XCTUnwrap(brief.components(separatedBy: "Card data:\n").last)
        let context = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(context["sessionTitle"] as? String, session.title)
        XCTAssertNil(context["batchLabel"])
        let cards = try XCTUnwrap(context["cards"] as? [[String: Any]])
        XCTAssertEqual(cards.compactMap { $0["id"] as? String }, [adjustment.id.uuidString, secondAdjustment.id.uuidString])
        let manualChange = try XCTUnwrap(cards.first?["manualFrontChange"] as? [String: String])
        XCTAssertEqual(manualChange, ["before": "Old front", "after": "Revised front"])
    }

    func testAIRevisionBriefHasNoCardsWhenNoneNeedAdjustment() throws {
        let session = FlashcardSession(title: "No revision needed", cards: [
            Flashcard(front: "Good", back: "Answer", verdict: .good),
            Flashcard(front: "Unreviewed", back: "Answer"),
            Flashcard(front: "Rejected", back: "Answer", verdict: .bad),
            Flashcard(front: "Replacement", back: "Answer", verdict: .bad, replacementRequested: true)
        ])
        let brief = try CardExport.aiRevisionBrief(session: session)
        let json = try XCTUnwrap(brief.components(separatedBy: "Card data:\n").last)
        let context = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let cards = try XCTUnwrap(context["cards"] as? [[String: Any]])
        XCTAssertTrue(cards.isEmpty)
    }
}
