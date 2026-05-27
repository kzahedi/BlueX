import XCTest
@testable import BlueX

final class ATProtoDateTests: XCTestCase {

    func testParsesFractionalSeconds() {
        let date = ATProtoDate.parse("2024-06-01T10:00:00.000Z")
        XCTAssertNotNil(date)
        let components = Calendar(identifier: .iso8601).dateComponents(
            in: TimeZone(identifier: "UTC")!, from: date!
        )
        XCTAssertEqual(components.year, 2024)
        XCTAssertEqual(components.month, 6)
        XCTAssertEqual(components.day, 1)
        XCTAssertEqual(components.hour, 10)
    }

    func testParsesWholeSecondsWithoutFraction() {
        // Some AT Protocol records omit fractional seconds — the old single-format
        // parser would return nil here and silently drop the post.
        let date = ATProtoDate.parse("2024-01-01T00:00:00Z")
        XCTAssertNotNil(date)
    }

    func testFractionalAndWholeSecondParseToSameInstant() {
        let withFraction = ATProtoDate.parse("2024-06-01T10:00:00.000Z")
        let withoutFraction = ATProtoDate.parse("2024-06-01T10:00:00Z")
        XCTAssertEqual(withFraction, withoutFraction)
    }

    func testReturnsNilForGarbage() {
        XCTAssertNil(ATProtoDate.parse("not a date"))
        XCTAssertNil(ATProtoDate.parse(""))
    }
}
