import XCTest
@testable import BlueX

final class LabelSamplingTests: XCTestCase {
    func testSameSeedSameDraw() {
        let pool = (0..<1000).map { "at://p/\($0)" }
        let a = LabelSampling.draw(from: pool, excluding: [], count: 100, seed: 42)
        let b = LabelSampling.draw(from: pool, excluding: [], count: 100, seed: 42)
        XCTAssertEqual(a, b, "identical seed must reproduce the identical draw, in order")
    }

    func testDifferentSeedDifferentDraw() {
        let pool = (0..<1000).map { "at://p/\($0)" }
        XCTAssertNotEqual(LabelSampling.draw(from: pool, excluding: [], count: 100, seed: 1),
                          LabelSampling.draw(from: pool, excluding: [], count: 100, seed: 2))
    }

    func testExcludedURIsNeverDrawn() {
        let pool = (0..<50).map { "at://p/\($0)" }
        let drawn = Set(pool.prefix(40))
        let result = LabelSampling.draw(from: pool, excluding: drawn, count: 100, seed: 7)
        XCTAssertEqual(Set(result).intersection(drawn), [])
        XCTAssertEqual(result.count, 10, "only the 10 undrawn remain")
    }

    func testNoDuplicatesInDraw() {
        let pool = (0..<500).map { "at://p/\($0)" }
        let result = LabelSampling.draw(from: pool, excluding: [], count: 200, seed: 9)
        XCTAssertEqual(Set(result).count, result.count)
    }

    func testDrawIsOrderInsensitiveToPoolOrder() {
        // The pool arrives from SQL; row order is not guaranteed. The draw must not
        // depend on it, or "same seed" silently stops meaning "same sample".
        let pool = (0..<300).map { "at://p/\($0)" }
        let a = LabelSampling.draw(from: pool, excluding: [], count: 50, seed: 3)
        let b = LabelSampling.draw(from: pool.shuffled(), excluding: [], count: 50, seed: 3)
        XCTAssertEqual(a, b)
    }

    func testEmptyPoolAndOversizedCount() {
        XCTAssertEqual(LabelSampling.draw(from: [], excluding: [], count: 10, seed: 1), [])
        let pool = ["at://p/1", "at://p/2"]
        XCTAssertEqual(Set(LabelSampling.draw(from: pool, excluding: [], count: 10, seed: 1)), Set(pool))
    }
}
