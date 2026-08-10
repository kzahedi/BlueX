import XCTest
@testable import BlueX

final class DecimatorTests: XCTestCase {
    func testShortSeriesIsUntouched() {
        let xs = Array(0..<10)
        XCTAssertEqual(Decimator.downsample(xs, to: 100), xs)
    }

    func testLongSeriesIsCapped() {
        let xs = Array(0..<1000)
        XCTAssertLessThanOrEqual(Decimator.downsample(xs, to: 50).count, 50)
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
    }

    func testDegenerateInputs() {
        XCTAssertTrue(Decimator.downsample([Int](), to: 10).isEmpty)
        XCTAssertEqual(Decimator.downsample([5], to: 10), [5])
        XCTAssertEqual(Decimator.downsample([1, 2, 3], to: 1), [1, 2, 3],
                       "a cap below 2 cannot preserve both endpoints, so pass through")
    }
}
