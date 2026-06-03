import XCTest
@testable import BlueX

final class StratifiedSamplerTests: XCTestCase {

    // Helper: integer week keys stand in for week-start Dates (Sampler is generic over Hashable keys).
    func testEvenSplitAcrossTwoWeeks() {
        let counts = [1: 100, 2: 100]
        let alloc = StratifiedSampler.allocate(counts: counts, total: 50)
        XCTAssertEqual(alloc[1], 25)
        XCTAssertEqual(alloc[2], 25)
        XCTAssertEqual(alloc.values.reduce(0, +), 50)
    }

    func testProportionalAllocation() {
        let counts = [1: 300, 2: 100]   // 3:1 ratio
        let alloc = StratifiedSampler.allocate(counts: counts, total: 40)
        XCTAssertEqual(alloc[1], 30)
        XCTAssertEqual(alloc[2], 10)
        XCTAssertEqual(alloc.values.reduce(0, +), 40)
    }

    func testFloorOfOneForSparseWeek() {
        // Week 2 is tiny; pure proportional would round it to 0, but it must get ≥1.
        let counts = [1: 1000, 2: 1]
        let alloc = StratifiedSampler.allocate(counts: counts, total: 100)
        XCTAssertEqual(alloc[2], 1, "sparse non-empty week must get at least 1")
        XCTAssertEqual(alloc[1], 99)
        XCTAssertEqual(alloc.values.reduce(0, +), 100)
    }

    func testCapAtWeekAvailableCount() {
        // Week 1 only has 2 posts; cannot allocate more than 2 to it.
        let counts = [1: 2, 2: 1000]
        let alloc = StratifiedSampler.allocate(counts: counts, total: 500)
        XCTAssertEqual(alloc[1], 2, "cannot exceed available count")
        XCTAssertEqual(alloc[2], 498)
        XCTAssertEqual(alloc.values.reduce(0, +), 500)
    }

    func testTakeAllWhenTotalExceedsAvailable() {
        let counts = [1: 10, 2: 5]
        let alloc = StratifiedSampler.allocate(counts: counts, total: 100)
        XCTAssertEqual(alloc[1], 10)
        XCTAssertEqual(alloc[2], 5)
        XCTAssertEqual(alloc.values.reduce(0, +), 15)
    }

    func testEmptyInput() {
        let alloc = StratifiedSampler.allocate(counts: [Int: Int](), total: 100)
        XCTAssertTrue(alloc.isEmpty)
    }

    func testNeverAllocatesToEmptyWeek() {
        let counts = [1: 50, 2: 0]
        let alloc = StratifiedSampler.allocate(counts: counts, total: 30)
        XCTAssertEqual(alloc[2] ?? 0, 0, "empty week gets nothing")
        XCTAssertEqual(alloc[1], 30)
    }

    func testSeededRNGIsDeterministic() {
        var a = SeededRNG(seed: 42)
        var b = SeededRNG(seed: 42)
        let xs = (0..<5).map { _ in a.next() }
        let ys = (0..<5).map { _ in b.next() }
        XCTAssertEqual(xs, ys)
    }

    func testSeededShuffleSelectsDistinctSubset() {
        var rng = SeededRNG(seed: 7)
        let pool = Array(0..<100)
        let picked = Array(pool.shuffled(using: &rng).prefix(10))
        XCTAssertEqual(picked.count, 10)
        XCTAssertEqual(Set(picked).count, 10, "no duplicates")
        XCTAssertTrue(picked.allSatisfy { pool.contains($0) })
    }
}
