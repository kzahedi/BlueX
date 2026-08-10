import XCTest
@testable import BlueX

final class ScrapeOrderTests: XCTestCase {

    func testRotatingByZeroReturnsOriginalOrder() {
        let items = [1, 2, 3, 4, 5]
        XCTAssertEqual(ScrapeOrder.rotated(items, startingAt: 0), items)
    }

    func testRotatingByTwoOfFivePutsElementTwoFirstAndWrapsTheRest() {
        let items = [0, 1, 2, 3, 4]
        XCTAssertEqual(ScrapeOrder.rotated(items, startingAt: 2), [2, 3, 4, 0, 1])
    }

    func testEveryElementAppearsExactlyOnceForEveryStartIndex() {
        let items = ["a", "b", "c", "d", "e", "f"]
        for start in 0..<items.count {
            let result = ScrapeOrder.rotated(items, startingAt: start)
            XCTAssertEqual(result.count, items.count, "count changed for start \(start)")
            XCTAssertEqual(Set(result), Set(items), "elements changed for start \(start)")
            for element in items {
                XCTAssertEqual(
                    result.filter { $0 == element }.count, 1,
                    "\(element) did not appear exactly once for start \(start)"
                )
            }
        }
    }

    func testEmptyArrayIsReturnedUnchanged() {
        let items: [Int] = []
        XCTAssertEqual(ScrapeOrder.rotated(items, startingAt: 0), items)
        XCTAssertEqual(ScrapeOrder.rotated(items, startingAt: 5), items)
        XCTAssertEqual(ScrapeOrder.rotated(items, startingAt: -3), items)
    }

    func testSingleElementArrayIsReturnedUnchanged() {
        let items = ["only"]
        XCTAssertEqual(ScrapeOrder.rotated(items, startingAt: 0), items)
        XCTAssertEqual(ScrapeOrder.rotated(items, startingAt: 7), items)
        XCTAssertEqual(ScrapeOrder.rotated(items, startingAt: -2), items)
    }

    func testOutOfRangeStartIndexNormalisesWithoutTrapping() {
        let items = [10, 20, 30, 40]

        XCTAssertEqual(ScrapeOrder.rotated(items, startingAt: -1), [40, 10, 20, 30])
        XCTAssertEqual(ScrapeOrder.rotated(items, startingAt: items.count), [10, 20, 30, 40])
        XCTAssertEqual(ScrapeOrder.rotated(items, startingAt: items.count + 3), [40, 10, 20, 30])
    }
}
