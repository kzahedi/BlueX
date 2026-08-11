// BlueXTests/Views/AuthorDetailLayoutTests.swift
import XCTest
@testable import BlueX

final class AuthorDetailLayoutTests: XCTestCase {
    func testShortTopContentFitsExactly() {
        // Plenty of room: the top section gets exactly its content height, no more.
        let height = AuthorDetailLayout.topSectionHeight(contentHeight: 200, availableHeight: 800)
        XCTAssertEqual(height, 200)
    }

    func testTallerTopContentStillFitsExactly() {
        // More outlets, taller content, still plenty of room: still exactly the content
        // height — no gap opens no matter how much bigger the content gets.
        let height = AuthorDetailLayout.topSectionHeight(contentHeight: 500, availableHeight: 800)
        XCTAssertEqual(height, 500)
    }

    func testShortWindowCapsTopSectionAboveRepliesFloor() {
        // Window too short for both at natural size: the top section yields down to
        // whatever is left once the replies floor, the spacing between them, and the
        // bottom padding are reserved.
        let available: CGFloat = 400
        let height = AuthorDetailLayout.topSectionHeight(contentHeight: 500, availableHeight: available)
        let expected = available - AuthorDetailLayout.repliesFloor - AuthorDetailLayout.sectionSpacing - AuthorDetailLayout.bottomPadding
        XCTAssertEqual(height, expected)
        // And that cap must be strictly less than the actual content height, i.e. the top
        // section becomes genuinely scrollable rather than magically fitting anyway.
        XCTAssertLessThan(height, 500)
    }

    func testExtremelyShortWindowNeverGoesNegative() {
        let height = AuthorDetailLayout.topSectionHeight(contentHeight: 500, availableHeight: 50)
        XCTAssertEqual(height, 0)
    }

    func testNonFiniteAvailableHeightFallsBackToContentHeight() {
        // Guards against a not-yet-laid-out GeometryReader reporting a non-finite size.
        let height = AuthorDetailLayout.topSectionHeight(contentHeight: 300, availableHeight: .infinity)
        XCTAssertEqual(height, 300)
    }
}
