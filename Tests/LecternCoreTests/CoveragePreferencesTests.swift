import Foundation
import XCTest
@testable import LecternCore

final class CoveragePreferencesTests: XCTestCase {
    private let oldPreferences = #"{"inspectorVisible":true,"sidebarVisible":false,"thumbnailSize":"large","filter":"selected","reviewFilter":"good","mode":"review"}"#

    func testPreferencesSavedBeforeCoverageStillDecode() throws {
        let prefs = try JSONDecoder().decode(ViewPreferences.self, from: Data(oldPreferences.utf8))
        XCTAssertEqual(prefs.mode, .review)
        XCTAssertEqual(prefs.thumbnailSize, .large)
        XCTAssertEqual(prefs.filter, .selected)
        XCTAssertEqual(prefs.reviewFilter, .good)
        XCTAssertFalse(prefs.sidebarVisible)
        XCTAssertFalse(prefs.coverageShowsBacks)
    }

    func testCoverageModeAndBacksRoundTrip() throws {
        let prefs = ViewPreferences(mode: .coverage, coverageShowsBacks: true)
        let decoded = try JSONDecoder().decode(ViewPreferences.self, from: JSONEncoder().encode(prefs))
        XCTAssertEqual(decoded, prefs)
    }

    func testUnknownModeFallsBackToPrepare() throws {
        let json = oldPreferences.replacingOccurrences(of: #""mode":"review""#, with: #""mode":"someFutureMode""#)
        let prefs = try JSONDecoder().decode(ViewPreferences.self, from: Data(json.utf8))
        XCTAssertEqual(prefs.mode, .prepare)
        XCTAssertEqual(prefs.reviewFilter, .good)
    }

    func testLectureWithCoveragePreferencesSurvivesStoreRoundTrip() throws {
        var lecture = Lecture(moduleID: UUID(), name: "L", pageCount: 2)
        lecture.viewPreferences.mode = .coverage
        lecture.viewPreferences.coverageShowsBacks = true
        let decoded = try LibraryStore.decoder().decode(Lecture.self, from: LibraryStore.encoder().encode(lecture))
        XCTAssertEqual(decoded.viewPreferences.mode, .coverage)
        XCTAssertTrue(decoded.viewPreferences.coverageShowsBacks)
    }
}
