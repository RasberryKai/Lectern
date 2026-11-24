import XCTest
@testable import LecternCore

final class ExamOverviewTests: XCTestCase {
    private let utc = TimeZone(secondsFromGMT: 0)!
    private var now: Date { ISO8601DateFormatter().date(from: "2026-11-23T12:00:00Z")! }

    func testCalmTableExampleUsesTheThreeDayFinishLine() throws {
        let law = try deck("Business & Trade Law", examDay: 7, planned: 6, done: 2, approved: 120, pending: 5)
        let english = try deck("English 1", examDay: 9, planned: 12, done: 3, approved: 169, limit: 52)
        let chinese = try deck("Chinese HSK 1", examDay: 11, planned: 12, done: 6)
        let psychology = try deck("Psychology", examDay: 14, planned: 12, done: 0, pending: 3)
        let accounting = try deck("Financial Accounting", examDay: 16, planned: 12, done: 2, approved: 3)
        let math = try deck("Math", examDay: 18, planned: 12, done: 0)

        let overview = overview([math, chinese, law, accounting, english, psychology])
        XCTAssertEqual(overview.rows.map(\.id), [law, english, chinese, psychology, accounting, math].map(\.id))
        XCTAssertEqual(overview.rows.map(\.daysUntilExam), [14, 16, 18, 21, 23, 25])
        XCTAssertEqual(overview.rows.map(\.metrics.cards?.total), [375, 676, nil, 3, 18, nil])
        XCTAssertEqual(overview.rows.map(\.metrics.cards?.isEstimate), [true, true, nil, false, true, nil])
        XCTAssertEqual(overview.rows.map(\.metrics.lecturesPerWeek?.needed), [3, 5, 3, 5, 4, 4])
        XCTAssertEqual(overview.rows.map(\.metrics.cardsPerDay?.needed), [35, 52, nil, nil, 1, nil])
        XCTAssertEqual(overview.rows.map(\.metrics.cardsPerDay?.isBehind), [true, false, nil, nil, false, nil])
        XCTAssertEqual(overview.totals.lectures, .init(completed: 13, total: 66, isEstimate: false))
        XCTAssertEqual(overview.totals.cards, .init(completed: 0, total: 1_072, isEstimate: true))
        XCTAssertEqual(overview.totals.lecturesPerWeek, .init(needed: 24, isBehind: false))
        XCTAssertEqual(overview.totals.cardsPerDay, .init(needed: 88, isBehind: false))
    }

    func testExamTodayPastFinishLineAndUndatedModules() throws {
        let today = try deck("Today", month: 11, examDay: 23, planned: 3, done: 1, approved: 3, seen: 1)
        let atFinishLine = try deck("Finish line", month: 11, examDay: 26, planned: 5, done: 1, approved: 3, seen: 1)
        let passed = try deck("Passed", month: 11, examDay: 22, planned: 5, done: 1, approved: 3)
        let undated = try deck("Undated", examDay: nil, planned: 2, done: 1, approved: 3, seen: 1)
        let allSeen = try deck("All seen", examDay: 5, planned: 1, done: 1, approved: 3, seen: 3)

        let overview = overview([undated, passed, today, atFinishLine, allSeen])
        XCTAssertEqual(overview.rows.map(\.id), [today, atFinishLine, allSeen, undated].map(\.id))
        XCTAssertEqual(overview.rows.map(\.metrics.lecturesPerWeek?.needed), [2, 4, nil, nil])
        XCTAssertEqual(overview.rows.map(\.metrics.cardsPerDay?.needed), [8, 14, nil, nil])
        XCTAssertEqual(overview.rows[2].metrics.cards, .init(completed: 3, total: 3, isEstimate: false))
        XCTAssertEqual(overview.rows[3].metrics.cards, .init(completed: 1, total: 6, isEstimate: true))
        XCTAssertEqual(overview.totals.lectures.total, 11)
    }

    func testLectureAmberCountsOnlyRecentCompletions() throws {
        let day: TimeInterval = 86_400
        let onPace = try deck("On pace", examDay: 7, planned: 5, done: 3, approved: 3,
                              completionDates: [now, now - 7 * day, now - 8 * day])
        let behind = try deck("Behind", examDay: 7, planned: 5, done: 3, approved: 3,
                              completionDates: [now, now - 7 * day - 1, now + day])
        XCTAssertEqual(overview([onPace, behind]).rows.map(\.metrics.lecturesPerWeek),
                       [.init(needed: 2, isBehind: false), .init(needed: 2, isBehind: true)])
    }

    private func overview(_ decks: [StudyDeck]) -> ExamOverview {
        let dashboard = DashboardBuilder.build(modules: decks.map(\.module), lectures: decks.flatMap(\.lectures), now: now, timeZone: utc)
        return ExamOverview(dashboard: dashboard, study: StudyCatalog(decks: decks), now: now, timeZone: utc)
    }

    private func deck(_ name: String, month: Int = 12, examDay: Int?, planned: Int, done: Int,
                      approved: Int = 0, pending: Int = 0, seen: Int = 0,
                      limit: Int? = nil, completionDates: [Date] = []) throws -> StudyDeck {
        let id = UUID()
        let approvedCards = (0..<approved).map { Card(front: "Question \($0)", back: "Answer", verdict: .good) }
        var lectures = (0..<done).map { index -> Lecture in
            var lecture = Lecture(moduleID: id, name: "Lecture \(index)", cards: index == 0 ? approvedCards : [])
            if lecture.cards.isEmpty { lecture.progressOverride = .done }
            if index < completionDates.count { lecture.cardMakingCompletedAt = completionDates[index] }
            return lecture
        }
        if pending > 0 {
            var cards = (0..<pending).map { Card(front: "Pending \($0)", back: "Answer") }
            cards.append(Card(front: "Rejected", back: "Answer", verdict: .bad))
            cards.append(Card(front: "Superseded", back: "Answer", supersededBy: []))
            lectures.append(Lecture(moduleID: id, name: "In Review", cards: cards))
        }
        let exam = try examDay.map { try ExamDate(year: 2026, month: month, day: $0) }
        let module = Module(id: id, name: name, lectureIDs: lectures.map(\.id), plannedLectureCount: planned, examDate: exam)
        let memory = try StudyScheduler.review(nil, rating: .again, at: now)
        var overrides = StudyOverrides()
        overrides.newCardLimit = limit
        return StudyDeck(module: module, lectures: lectures,
                         memory: Dictionary(uniqueKeysWithValues: approvedCards.prefix(seen).map { ($0.id, memory) }),
                         overrides: overrides, introducedToday: seen)
    }
}
