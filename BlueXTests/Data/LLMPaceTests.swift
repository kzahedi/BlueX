import XCTest
import Foundation
@testable import BlueX

final class LLMPaceTests: XCTestCase {

    // MARK: - Raw value & cases

    func testRawValuesAreStableForCLIArgParsing() {
        // The CLI parses --pace burst|steady|gentle through LLMPace(rawValue:);
        // renaming a case is a CLI breaking change, so the strings are pinned here.
        XCTAssertEqual(LLMPace.burst.rawValue, "burst")
        XCTAssertEqual(LLMPace.steady.rawValue, "steady")
        XCTAssertEqual(LLMPace.gentle.rawValue, "gentle")
    }

    func testInitFromCLIString() {
        XCTAssertEqual(LLMPace(rawValue: "burst"), .burst)
        XCTAssertEqual(LLMPace(rawValue: "steady"), .steady)
        XCTAssertEqual(LLMPace(rawValue: "gentle"), .gentle)
        XCTAssertNil(LLMPace(rawValue: "fast"))
    }

    func testAllCasesEnumerated() {
        XCTAssertEqual(Set(LLMPace.allCases), [.burst, .steady, .gentle])
    }

    // MARK: - Delay ordering

    func testBaseDelayBurstIsZero() {
        XCTAssertEqual(LLMPace.burst.baseDelayNanoseconds, 0)
    }

    func testBaseDelayOrdering() {
        // burst < steady < gentle is the invariant — both UI labels and CLI flags
        // depend on gentle being the slowest.
        XCTAssertLessThan(LLMPace.burst.baseDelayNanoseconds,
                          LLMPace.steady.baseDelayNanoseconds)
        XCTAssertLessThan(LLMPace.steady.baseDelayNanoseconds,
                          LLMPace.gentle.baseDelayNanoseconds)
    }

    func testGentleIsAtLeastOneSecond() {
        // We pick gentle for unattended runs; <1s would defeat the purpose.
        XCTAssertGreaterThanOrEqual(LLMPace.gentle.baseDelayNanoseconds, 1_000_000_000)
    }

    // MARK: - Thermal back-off

    func testThermalBackoffZeroAtNominalAndFair() {
        XCTAssertEqual(ThermalBackoff.extraDelayNanoseconds(for: .nominal), 0)
        XCTAssertEqual(ThermalBackoff.extraDelayNanoseconds(for: .fair), 0)
    }

    func testThermalBackoffPositiveAtSerious() {
        XCTAssertGreaterThan(ThermalBackoff.extraDelayNanoseconds(for: .serious), 0)
    }

    func testThermalBackoffEscalatesFromSeriousToCritical() {
        XCTAssertLessThan(
            ThermalBackoff.extraDelayNanoseconds(for: .serious),
            ThermalBackoff.extraDelayNanoseconds(for: .critical)
        )
    }
}
