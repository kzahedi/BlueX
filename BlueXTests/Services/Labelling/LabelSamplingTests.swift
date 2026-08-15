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

    func testFullPoolDrawIsShuffledNotSorted() {
        // When count >= pool.count, all remaining items are returned, but they must be
        // shuffled deterministically, not sorted. A sorted return in the smallest batches
        // (last batch of a stage, or filtered pool) is systematic bias exactly where
        // sampling matters most.
        let pool = (0..<50).map { "at://p/\(String(format: "%02d", $0))" }
        let result = LabelSampling.draw(from: pool, excluding: [], count: 100, seed: 42)

        // Verify result contains all pool items (set equality).
        XCTAssertEqual(Set(result), Set(pool))
        XCTAssertEqual(result.count, pool.count)

        // Verify reproducibility: same seed must give same order.
        let result2 = LabelSampling.draw(from: pool, excluding: [], count: 100, seed: 42)
        XCTAssertEqual(result, result2)

        // Verify it is NOT in sorted order. Probability of a shuffled sequence landing
        // in sorted order by chance is 1/50! ≈ 3e-65, effectively impossible.
        let sorted = pool.sorted()
        XCTAssertNotEqual(result, sorted, "result must be shuffled, not sorted")
    }
}
