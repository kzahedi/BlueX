import XCTest
@testable import BlueX

final class DecimatorTests: XCTestCase {
    func testShortSeriesIsUntouched() {
        let xs = Array(0..<10)
        XCTAssertEqual(Decimator.downsample(xs, to: 100), xs)
    }

    func testLongSeriesIsCapped() {
        let xs = Array(0..<1000)
        // Exact count, not <=: a duplicate-emitting implementation would return fewer
        // than 50 distinct-looking points while still satisfying a `<=` bound.
        XCTAssertEqual(Decimator.downsample(xs, to: 50).count, 50)
    }

    /// Dropping either end would move the chart's date range, which is a lie about the
    /// data rather than a rendering shortcut.
    func testEndpointsArePreserved() {
        let xs = Array(0..<1000)
        let out = Decimator.downsample(xs, to: 50)
        XCTAssertEqual(out.first, 0)
        XCTAssertEqual(out.last, 999)
    }

    func testOrderIsPreserved() {
        let xs = Array(0..<1000)
        let out = Decimator.downsample(xs, to: 37)
        XCTAssertEqual(out, out.sorted())
        // Strict monotonicity: a monotonic sequence with repeats still equals its own
        // sorted form, so `== sorted()` alone can't catch a duplicate-index regression.
        for (a, b) in zip(out, out.dropFirst()) {
            XCTAssertLessThan(a, b, "adjacent samples must be strictly increasing, no duplicates")
        }
        XCTAssertEqual(Set(out).count, out.count, "no element should be sampled twice")
    }

    func testDegenerateInputs() {
        XCTAssertTrue(Decimator.downsample([Int](), to: 10).isEmpty)
        XCTAssertEqual(Decimator.downsample([5], to: 10), [5])
        XCTAssertEqual(Decimator.downsample([1, 2, 3], to: 1), [1, 2, 3],
                       "a cap below 2 cannot preserve both endpoints, so pass through")
    }

    /// The tightest cap that can still preserve both endpoints: no room for any interior
    /// samples at all.
    func testMaxPointsOfTwoKeepsOnlyEndpoints() {
        let xs = Array(0..<1000)
        XCTAssertEqual(Decimator.downsample(xs, to: 2), [0, 999])
    }

    /// The smallest possible reduction (drop exactly one point) — the case where an
    /// off-by-one in the interior-index math is most likely to surface.
    func testSmallestReductionDropsExactlyOnePoint() {
        let xs = Array(0..<1000)
        let out = Decimator.downsample(xs, to: 999)
        XCTAssertEqual(out.count, 999)
        XCTAssertEqual(out.first, 0)
        XCTAssertEqual(out.last, 999)
        XCTAssertEqual(Set(out).count, out.count, "no element should be sampled twice")
        for (a, b) in zip(out, out.dropFirst()) {
            XCTAssertLessThan(a, b)
        }
    }
}
