// BlueXTests/Views/AuthorsFormattingTests.swift
import XCTest
@testable import BlueX

final class AuthorsFormattingTests: XCTestCase {
    func testMatchingSummaryStatesCapCoverage() {
        XCTAssertEqual(
            AuthorsFormatting.matchingSummary(shown: 500, total: 207_000),
            "Showing 500 of 207000 matching authors"
        )
    }

    func testMatchingSummaryWhenNotCapped() {
        XCTAssertEqual(
            AuthorsFormatting.matchingSummary(shown: 7, total: 7),
            "Showing 7 of 7 matching authors"
        )
    }

    func testStatusIsCollectedFalseWhenEmpty() {
        XCTAssertFalse(AuthorsFormatting.statusIsCollected([:]))
    }

    func testStatusIsCollectedTrueWhenPopulated() {
        XCTAssertTrue(AuthorsFormatting.statusIsCollected(["active": 10]))
    }

    func testOutletOverlapNoteMentionsTotal() {
        let note = AuthorsFormatting.outletOverlapNote(totalAuthors: 207_000)
        XCTAssertTrue(note.contains("207000"))
        XCTAssertTrue(note.localizedCaseInsensitiveContains("counted once per outlet"))
    }

    func testConfoundedOutletNoteDoesNotClaimAFinding() {
        // Must warn against treating outlet differences as findings, not just describe
        // the dominance in neutral terms.
        XCTAssertTrue(AuthorsFormatting.confoundedOutletNote.localizedCaseInsensitiveContains("confounded"))
    }

    func testSortedStatusRowsAreDeterministic() {
        let rows = AuthorsFormatting.sortedStatusRows(["b": 2, "a": 1, "c": 3])
        XCTAssertEqual(rows.map(\.status), ["a", "b", "c"])
        XCTAssertEqual(rows.map(\.count), [1, 2, 3])
    }

    func testSortedStatusRowsEmpty() {
        XCTAssertTrue(AuthorsFormatting.sortedStatusRows([:]).isEmpty)
    }

    func testStatusNotCollectedMessageIsHonestNotAZeroedClaim() {
        // Must describe absence of measurement, not absence of moderation activity.
        XCTAssertFalse(AuthorsFormatting.statusNotCollectedMessage.localizedCaseInsensitiveContains("no "))
        XCTAssertTrue(AuthorsFormatting.statusNotCollectedMessage.localizedCaseInsensitiveContains("has not run"))
    }

    func testHandleNotCollectedMessageMentionsProbe() {
        XCTAssertTrue(AuthorsFormatting.handleNotCollectedMessage.localizedCaseInsensitiveContains("probe"))
    }
}
