import Foundation
import Testing
@testable import LecternCore

@Suite struct ChatContextSelectionTests {
    @Test func allSlidesReplacesSlidesAndKeepsCardsAndScreenFollowing() {
        let card = UUID()
        var context = ChatContext(pins: [.slide(1), .card(card), .slide(2)])
        context.pin(.allSlides)
        #expect(context.pins == [.card(card), .allSlides])
        #expect(context.followsScreen)
        context.pin(.slide(3))
        #expect(context.pins == [.card(card), .slide(3)])
    }

    @Test func allCardsReplacesCardsAndKeepsSlidesAndScreenDisabled() {
        let first = UUID(), second = UUID()
        var context = ChatContext(followsScreen: false, pins: [.card(first), .slide(2), .card(second)])
        context.pin(.allCards)
        #expect(context.pins == [.slide(2), .allCards])
        #expect(!context.followsScreen)
        context.pin(.card(second))
        #expect(context.pins == [.slide(2), .card(second)])
    }

    @Test func repeatedPinsAreUniqueAndCategoriesCanBothBeSelected() {
        var context = ChatContext(pins: [.allSlides])
        context.pin(.allCards)
        context.pin(.allCards)
        #expect(context.pins == [.allSlides, .allCards])
        context.pin(.slide(1))
        context.pin(.slide(1))
        #expect(context.pins == [.allCards, .slide(1)])
    }
}
