import Foundation
import Testing
@testable import LecternCore

struct StudyCatalogTests {
    private let now = Date(timeIntervalSince1970: 1_767_311_880)
    private let utc = TimeZone(secondsFromGMT: 0)!

    @Test func legacySessionOptionsPreserveExistingSettingsAndInheritNewCardOrder() throws {
        let legacy = Data("""
            {"cardTypes":"flip","queueOrder":"mixed","spaceRelatedCards":false,"stop":{"cards":{"_0":12}}}
            """.utf8)
        var options = try JSONDecoder().decode(StudySessionOptions.self, from: legacy)
        #expect(options.cardTypes == .flip)
        #expect(options.queueOrder == .mixed)
        #expect(options.newCardOrder == .sequential)
        #expect(!options.spaceRelatedCards)
        #expect(options.stop == .cards(12))

        options.newCardOrder = .shuffleAcrossSelection
        let saved = try JSONEncoder().encode(options)
        #expect(try JSONDecoder().decode(StudySessionOptions.self, from: saved) == options)

        var defaults = StudyConfiguration()
        defaults.session = options
        let legacyOverrides = Data(#"{"spaceRelatedCards":true}"#.utf8)
        var overrides = try JSONDecoder().decode(StudyOverrides.self, from: legacyOverrides)
        #expect(overrides.newCardOrder == nil)
        #expect(overrides.applying(to: defaults).session.newCardOrder == .shuffleAcrossSelection)
        overrides.newCardOrder = .sequential
        #expect(overrides.applying(to: defaults).session.newCardOrder == .sequential)
        #expect(overrides.applying(to: defaults).session.spaceRelatedCards)
    }

    @Test func shuffleUsesOnlySelectedEligibleCardsAndKeepsLectureOrderInWithinMode() {
        let module = Module(name: "Module")
        let firstCards = (1...3).map { card("First \($0)") }
        let secondCards = (1...3).map { card("Second \($0)") }
        let undecided = Card(front: "Undecided", back: "Answer")
        let replaced = Card(front: "Replaced", back: "Answer", verdict: .good, supersededBy: [firstCards[0].id])
        let first = Lecture(moduleID: module.id, name: "First", cards: firstCards + [undecided, replaced])
        let second = Lecture(moduleID: module.id, name: "Second", cards: secondCards)
        let unselected = Lecture(moduleID: module.id, name: "Unselected", cards: [card("Unselected")])
        let catalog = StudyCatalog(decks: [deck(module, lectures: [first, second, unselected])])
        let selected = StudyScope.lectures(moduleID: module.id, lectureIDs: [first.id, second.id])
        let standalone = StudyScope.lectures(moduleID: module.id, lectureIDs: [first.id])
        let allIDs = Set((firstCards + secondCards).map(\.id))

        var options = StudySessionOptions()
        options.newCardOrder = .shuffleWithinLecture
        let within = catalog.plan(scope: selected, options: options, shuffleSeed: 0, now: now).cards
        let withinStandalone = catalog.plan(scope: standalone, options: options, shuffleSeed: 0, now: now).cards
        #expect(Set(within.map(\.id)) == allIDs)
        #expect(within.map(\.lectureID) == Array(repeating: first.id, count: 3) + Array(repeating: second.id, count: 3))
        #expect((0..<32).contains { seed in
            catalog.plan(scope: standalone, options: options, shuffleSeed: UInt64(seed), now: now).cards.map(\.id) != firstCards.map(\.id)
        })

        options.newCardOrder = .shuffleAcrossSelection
        let across = catalog.plan(scope: selected, options: options, shuffleSeed: 0, now: now).cards
        let sameSeed = catalog.plan(scope: selected, options: options, shuffleSeed: 0, now: now).cards
        let acrossStandalone = catalog.plan(scope: standalone, options: options, shuffleSeed: 0, now: now).cards
        #expect(Set(across.map(\.id)) == allIDs)
        #expect(across == sameSeed)
        #expect(acrossStandalone == withinStandalone)
        let acrossOrders = (0..<32).map { seed in
            catalog.plan(scope: selected, options: options, shuffleSeed: UInt64(seed), now: now).cards
        }
        #expect(acrossOrders.contains { $0.first?.lectureID == second.id })
        #expect(acrossOrders.contains { $0 != across })
    }

    @Test func acrossSelectionShufflesAcrossModulesBeforeApplyingNewCardLimits() {
        let first = Module(name: "First")
        let second = Module(name: "Second")
        let capped = Module(name: "Capped")
        let firstCards = (1...3).map { card("First \($0)") }
        let secondCards = (1...3).map { card("Second \($0)") }
        var overrides = StudyOverrides()
        overrides.newCardLimit = 2
        let catalog = StudyCatalog(decks: [
            deck(first, lectures: [Lecture(moduleID: first.id, name: "First", cards: firstCards)],
                 overrides: overrides, introducedToday: 1),
            deck(second, lectures: [Lecture(moduleID: second.id, name: "Second", cards: secondCards)],
                 introducedToday: 1),
            deck(capped, lectures: [Lecture(moduleID: capped.id, name: "Capped", cards: [card("Capped")])],
                 introducedToday: 3)
        ], preferences: {
            var preferences = StudyPreferences()
            preferences.defaults.newCardLimit = 3
            preferences.overallNewLimit = 7
            return preferences
        }(), introducedToday: 5)

        var options = StudySessionOptions()
        options.newCardOrder = .shuffleAcrossSelection
        let plan = catalog.plan(options: options, shuffleSeed: 0, now: now)
        let cappedPlans = (0..<32).map { seed in
            catalog.plan(options: options, shuffleSeed: UInt64(seed), now: now).cards
        }
        #expect(cappedPlans.allSatisfy { cards in
            cards.count == 2 && !cards.contains { $0.moduleID == capped.id }
        })
        #expect(cappedPlans.contains { $0.allSatisfy { $0.moduleID == second.id } })
        #expect(plan.totalUnseen == 7)
        let one = catalog.plan(options: options, limitNewInSession: 1, shuffleSeed: 0, now: now)
        #expect(one.cards == Array(plan.cards.prefix(1)))
        let extra = catalog.plan(options: options, extraNewPerModule: 1, shuffleSeed: 0, now: now)
        #expect(extra.cards.count == 3)

        let withoutOverallCap = StudyCatalog(decks: catalog.decks, preferences: {
            var preferences = catalog.preferences
            preferences.overallNewLimit = nil
            return preferences
        }(), introducedToday: catalog.introducedToday)
        let uncapped = withoutOverallCap.plan(options: options, shuffleSeed: 0, now: now)
        #expect(uncapped.cards.count == 3)
        #expect(uncapped.cards.count { $0.moduleID == first.id } == 1)
        #expect(uncapped.cards.count { $0.moduleID == second.id } == 2)
    }

    @Test func withinLectureUsesLocalSpacerAndFallsBackBeforeMovingToAnotherLecture() throws {
        let module = Module(name: "Module")
        let splitID = UUID()
        let due = card("Due", pages: [1], origin: .splitFrom(cardID: splitID))
        let sharedPage = card("Shared page", pages: [1])
        let sharedParent = card("Shared parent", origin: .splitFrom(cardID: splitID))
        let unrelated = card("Unrelated", pages: [2])
        let other = card("Different lecture", pages: [1], origin: .splitFrom(cardID: splitID))
        let memory = try StudyScheduler.review(nil, rating: .good, at: now.addingTimeInterval(-300_000))
        let second = Lecture(moduleID: module.id, name: "Second", cards: [other])
        let relatedOnly = Lecture(moduleID: module.id, name: "First", cards: [due, sharedPage, sharedParent])
        var withSpacer = relatedOnly
        withSpacer.cards.append(unrelated)
        let catalog = StudyCatalog(decks: [deck(module, lectures: [withSpacer, second], memory: [due.id: memory])])
        let noLocalSpacer = StudyCatalog(decks: [deck(module, lectures: [relatedOnly, second], memory: [due.id: memory])])

        var options = StudySessionOptions()
        options.newCardOrder = .shuffleWithinLecture
        options.spaceRelatedCards = false
        let localSeed = try #require((0..<32).map(UInt64.init).first { seed in
            catalog.plan(options: options, shuffleSeed: seed, now: now).cards.dropFirst().first?.id != unrelated.id
        })
        let unspaced = noLocalSpacer.plan(options: options, shuffleSeed: localSeed, now: now)
        options.spaceRelatedCards = true
        let spaced = catalog.plan(options: options, shuffleSeed: localSeed, now: now)
        #expect(spaced.cards.prefix(2).map(\.id) == [due.id, unrelated.id])
        #expect(spaced.cards.last?.id == other.id)
        let fallback = noLocalSpacer.plan(options: options, shuffleSeed: localSeed, now: now)
        #expect(fallback.cards == unspaced.cards)
        #expect(fallback.cards.last?.id == other.id)

        options.newCardOrder = .shuffleAcrossSelection
        options.spaceRelatedCards = false
        let acrossSeed = try #require((0..<32).map(UInt64.init).first { seed in
            noLocalSpacer.plan(options: options, shuffleSeed: seed, now: now).cards.dropFirst().first?.lectureID == relatedOnly.id
        })
        options.spaceRelatedCards = true
        let across = noLocalSpacer.plan(options: options, shuffleSeed: acrossSeed, now: now)
        #expect(across.cards.prefix(2).map(\.id) == [due.id, other.id])

        options.newCardOrder = .sequential
        let sequential = noLocalSpacer.plan(options: options, now: now)
        #expect(sequential.cards.map(\.id) == [due.id, other.id, sharedPage.id, sharedParent.id])
    }

    @Test func mixedQueueAlternatesDueReviewsAndShuffledNewCards() throws {
        let module = Module(name: "Module")
        let firstDue = card("First due")
        let secondDue = card("Second due")
        let firstNew = card("First new")
        let secondNew = card("Second new")
        let first = Lecture(moduleID: module.id, name: "First", cards: [secondDue, firstNew])
        let second = Lecture(moduleID: module.id, name: "Second", cards: [firstDue, secondNew])
        let memory = try [
            firstDue.id: StudyScheduler.review(nil, rating: .good, at: now.addingTimeInterval(-400_000)),
            secondDue.id: StudyScheduler.review(nil, rating: .good, at: now.addingTimeInterval(-300_000))
        ]
        let catalog = StudyCatalog(decks: [deck(module, lectures: [first, second], memory: memory)])
        var options = StudySessionOptions()
        options.newCardOrder = .shuffleAcrossSelection
        let dueFirst = catalog.plan(options: options, shuffleSeed: 5, now: now).cards
        options.queueOrder = .mixed
        let mixed = catalog.plan(options: options, shuffleSeed: 5, now: now).cards

        #expect(dueFirst.prefix(2).map(\.id) == [firstDue.id, secondDue.id])
        #expect(mixed.map { $0.memory != nil } == [true, false, true, false])
        #expect(mixed.filter { $0.memory != nil }.map(\.id) == [firstDue.id, secondDue.id])
        #expect(mixed.filter { $0.memory == nil } == Array(dueFirst.suffix(2)))
    }

    @Test func askFlashcardPrefersLocalDueDayThenNearestSourceSlide() {
        let module = Module(name: "Probability")
        let near = card("Near", pages: [5, 18])
        let far = card("Far", pages: [10])
        let older = card("Older", pages: [20])
        let crossLecture = card("Another lecture", pages: [5])
        let local = Lecture(moduleID: module.id, name: "Local", cards: [near, far, older])
        let other = Lecture(moduleID: module.id, name: "Other", cards: [crossLecture])
        var memory = [near.id: schedule(dueIn: -120), far.id: schedule(dueIn: -3_600),
                      crossLecture.id: schedule(dueIn: -172_800)]

        let sameDay = deck(module, lectures: [other, local], memory: memory)
        #expect(sameDay.askFlashcard(lectureID: local.id, sourcePage: 5, now: now, timeZone: utc) { true }?.id == near.id)
        #expect(sameDay.askFlashcard(lectureID: local.id, sourcePage: nil, now: now, timeZone: utc) { true }?.id == far.id)

        memory[older.id] = schedule(dueIn: -86_400)
        let differentDays = deck(module, lectures: [other, local], memory: memory)
        #expect(differentDays.askFlashcard(lectureID: local.id, sourcePage: 5, now: now, timeZone: utc) { true }?.id == older.id)
    }

    @Test func askFlashcardIgnoresIneligibleCardsAndFallsBackToTheMostOverdueInTheModule() {
        let module = Module(name: "Probability")
        let overdue = card("Overdue")
        let due = card("Due")
        let disabled = Card(front: "Disabled", back: "Answer")
        let superseded = Card(front: "Superseded", back: "Answer", verdict: .good, supersededBy: [due.id])
        let unseen = card("Unseen")
        let archivedCard = card("Archived")
        let local = Lecture(moduleID: module.id, name: "Local", cards: [disabled, superseded, unseen])
        let other = Lecture(moduleID: module.id, name: "Other", cards: [due, overdue])
        var archived = Lecture(moduleID: module.id, name: "Archived", cards: [archivedCard])
        archived.archivedAt = now
        let memory = [disabled.id: schedule(dueIn: -86_400), superseded.id: schedule(dueIn: -86_400),
                      archivedCard.id: schedule(dueIn: -86_400), overdue.id: schedule(dueIn: -3_600),
                      due.id: schedule(dueIn: 0)]
        let catalog = deck(module, lectures: [archived, local, other], memory: memory)

        #expect(catalog.askFlashcard(lectureID: local.id, sourcePage: 1, now: now, timeZone: utc) { true }?.id == overdue.id)

        let empty = deck(module, lectures: [archived, local], memory: memory)
        #expect(empty.askFlashcard(lectureID: local.id, sourcePage: 1, now: now, timeZone: utc) { false } == nil)
    }

    @Test func askFlashcardPrefersLocalNewCardsThenFallsBackToTheLeastRecentlyReviewedCard() {
        let module = Module(name: "Probability")
        let near = card("Near", pages: [7])
        let far = card("Far", pages: [12])
        let otherUnseen = card("From another lecture", pages: [6])
        let recent = card("Reviewed recently", pages: [6])
        let leastRecent = card("Reviewed long ago")
        let local = Lecture(moduleID: module.id, name: "Local", cards: [far, near, recent])
        let other = Lecture(moduleID: module.id, name: "Other", cards: [otherUnseen, leastRecent])
        let memory = [recent.id: schedule(dueIn: 300, reviewedAgo: 600),
                      leastRecent.id: schedule(dueIn: 600, reviewedAgo: 86_400)]
        let catalog = deck(module, lectures: [other, local], memory: memory)

        #expect(catalog.askFlashcard(lectureID: local.id, sourcePage: 6, now: now, timeZone: utc) { true }?.id == near.id)
        #expect(catalog.askFlashcard(lectureID: local.id, sourcePage: 6, now: now, timeZone: utc) { false }?.id == leastRecent.id)
    }

    @Test func askFlashcardUsesFreshModuleAndOverallDailyIntroductionCounts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lectern-ask-study-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(rootURL: root)
        let module = try await store.createModule(name: "Probability")
        let other = try await store.createModule(name: "Regression")
        let localCard = card("Probability")
        let local = try await store.createLecture(Lecture(moduleID: module.id, name: "Local", cards: [localCard]))
        let remote = try await store.createLecture(Lecture(moduleID: other.id, name: "Remote", cards: [card("Remote")]))
        var preferences = StudyPreferences()
        preferences.overallNewLimit = 1
        try await store.saveStudyPreferences(preferences)
        let entry = try #require(try await store.askFlashcard(moduleID: other.id, lectureID: remote.id, sourcePage: nil,
                                                            now: now, timeZone: utc))

        #expect(try await store.askFlashcard(moduleID: module.id, lectureID: local.id, sourcePage: nil,
                                             now: now, timeZone: utc)?.id == localCard.id)
        _ = try await store.gradeStudyCard(entry, rating: .good, eventID: UUID(), now: now, answeringTime: 2,
                                           permitEarly: false, extraNewPerModule: 0, timeZone: utc)
        _ = try await store.setModuleArchived(moduleID: other.id, archived: true)
        #expect(try await store.askFlashcard(moduleID: module.id, lectureID: local.id, sourcePage: nil,
                                             now: now, timeZone: utc) == nil)

        try await store.setStudyNewCardLimit(moduleID: module.id, limit: 0)
        let tomorrow = now.addingTimeInterval(86_400)
        #expect(try await store.askFlashcard(moduleID: module.id, lectureID: local.id, sourcePage: nil,
                                             now: tomorrow, timeZone: utc) == nil)
        try await store.setStudyNewCardLimit(moduleID: module.id, limit: 1)
        #expect(try await store.askFlashcard(moduleID: module.id, lectureID: local.id, sourcePage: nil,
                                             now: tomorrow, timeZone: utc)?.id == localCard.id)
    }

    private func schedule(dueIn: TimeInterval, reviewedAgo: TimeInterval = 172_800) -> StudyMemoryState {
        StudyMemoryState(stability: 1, difficulty: 5, due: now.addingTimeInterval(dueIn),
                         lastReview: now.addingTimeInterval(-reviewedAgo), reps: 3, lapses: 0, phase: .review)
    }

    private func card(_ front: String, pages: [Int] = [], origin: CardOrigin = .manual) -> Card {
        Card(sourcePages: pages, front: front, back: "Answer", verdict: .good, origin: origin)
    }

    private func deck(_ module: Module, lectures: [Lecture], memory: [UUID: StudyMemoryState] = [:],
                      overrides: StudyOverrides = .init(), introducedToday: Int = 0) -> StudyDeck {
        StudyDeck(module: module, lectures: lectures, memory: memory, overrides: overrides, introducedToday: introducedToday)
    }
}
