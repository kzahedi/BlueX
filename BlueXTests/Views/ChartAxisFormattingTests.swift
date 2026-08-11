// BlueXTests/Views/ChartAxisFormattingTests.swift
import XCTest
@testable import BlueX

final class ChartAxisFormattingTests: XCTestCase {
    private let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    // MARK: - spanDays

    func testSpanDaysEmptyIsZero() {
        XCTAssertEqual(ChartAxisFormatting.spanDays([], calendar: calendar), 0)
    }

    func testSpanDaysSinglePointIsZero() {
        XCTAssertEqual(ChartAxisFormatting.spanDays([date(2026, 8, 5)], calendar: calendar), 0)
    }

    func testSpanDaysTwoWeeks() {
        let dates = [date(2026, 7, 22), date(2026, 8, 5)]
        XCTAssertEqual(ChartAxisFormatting.spanDays(dates, calendar: calendar), 14)
    }

    func testSpanDaysIgnoresOrdering() {
        // Latest date listed first — min/max must not depend on input order.
        let dates = [date(2026, 8, 5), date(2018, 1, 1)]
        XCTAssertEqual(ChartAxisFormatting.spanDays(dates, calendar: calendar), 3138)
    }

    func testSpanDaysEightYearCorpus() {
        let dates = [date(2018, 1, 1), date(2026, 8, 5)]
        XCTAssertTrue(ChartAxisFormatting.spanDays(dates, calendar: calendar) > 365 * 8)
    }

    // MARK: - dateFormat

    func testDateFormatShortSpanUsesDayMonth() {
        let anchor = date(2026, 8, 5)
        let format = ChartAxisFormatting.dateFormat(spanDays: 0)
        XCTAssertEqual(anchor.formatted(format), anchor.formatted(.dateTime.month(.abbreviated).day()))
    }

    func testDateFormatJustBelowThresholdUsesDayMonth() {
        let format = ChartAxisFormatting.dateFormat(spanDays: ChartAxisFormatting.shortSpanThresholdDays - 1)
        let anchor = date(2026, 8, 5)
        XCTAssertEqual(anchor.formatted(format), anchor.formatted(.dateTime.month(.abbreviated).day()))
    }

    func testDateFormatAtThresholdUsesMonthYear() {
        let format = ChartAxisFormatting.dateFormat(spanDays: ChartAxisFormatting.shortSpanThresholdDays)
        let anchor = date(2026, 8, 5)
        XCTAssertEqual(anchor.formatted(format), anchor.formatted(.dateTime.month(.abbreviated).year(.twoDigits)))
    }

    func testDateFormatLongSpanUsesMonthYear() {
        let format = ChartAxisFormatting.dateFormat(spanDays: 365 * 8)
        let anchor = date(2026, 8, 5)
        XCTAssertEqual(anchor.formatted(format), anchor.formatted(.dateTime.month(.abbreviated).year(.twoDigits)))
    }

    func testDesiredTickCountIsSmallAndPositive() {
        XCTAssertTrue(ChartAxisFormatting.desiredTickCount > 0)
        XCTAssertTrue(ChartAxisFormatting.desiredTickCount <= 10)
    }
}
