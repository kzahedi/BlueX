import XCTest
@testable import BlueX

final class LabellingFormattingTests: XCTestCase {

    // MARK: - Frame summary

    func testFrameSummaryStatesUniformRandomPlainly() {
        XCTAssertEqual(LabellingFormatting.frameSummary(.uniformRandom), "uniform random")
    }

    func testFrameSummaryNilFrameIsDistinctFromUniformRandom() {
        XCTAssertNotEqual(LabellingFormatting.frameSummary(nil), "uniform random")
        XCTAssertTrue(LabellingFormatting.frameSummary(nil).localizedCaseInsensitiveContains("unknown"))
    }

    func testFrameSummaryFilteredListsOutlet() {
        let frame = SamplingFrame(kind: .filtered, outletPK: 42, dateFrom: nil, dateTo: nil,
                                   minThreadReplies: nil, maxThreadReplies: nil)
        let summary = LabellingFormatting.frameSummary(frame)
        XCTAssertTrue(summary.contains("filtered"))
        XCTAssertTrue(summary.contains("42"))
    }

    func testFrameSummaryFilteredWithNoFiltersSetIsHonest() {
        let frame = SamplingFrame(kind: .filtered, outletPK: nil, dateFrom: nil, dateTo: nil,
                                   minThreadReplies: nil, maxThreadReplies: nil)
        XCTAssertEqual(LabellingFormatting.frameSummary(frame), "filtered (no filters set)")
    }

    func testFrameSummaryThreadSizeRange() {
        let frame = SamplingFrame(kind: .filtered, outletPK: nil, dateFrom: nil, dateTo: nil,
                                   minThreadReplies: 5, maxThreadReplies: 50)
        let summary = LabellingFormatting.frameSummary(frame)
        XCTAssertTrue(summary.contains("5"))
        XCTAssertTrue(summary.contains("50"))
    }

    func testFrameSummaryStratifiedShowsStratumIDAndDefinition() {
        let frame = SamplingFrame.stratified(
            stratumID: "tox_top_1", stratumDefinition: "tox_pct >= 99.0000",
            populationSize: 20844, frameFileSHA256: "abc123", drawSeed: 1)
        let summary = LabellingFormatting.frameSummary(frame)
        XCTAssertTrue(summary.contains("tox_top_1"))
        XCTAssertTrue(summary.contains("tox_pct >= 99.0000"))
    }

    // MARK: - buildFrame

    func testBuildFrameUniformRandomIgnoresOtherArguments() {
        let frame = LabellingFormatting.buildFrame(uniformRandom: true, outletPK: 7,
            dateFrom: Date(), dateTo: Date(), minThreadReplies: 1, maxThreadReplies: 2)
        XCTAssertEqual(frame, .uniformRandom)
    }

    func testBuildFrameFilteredCarriesOutletPK() {
        let frame = LabellingFormatting.buildFrame(uniformRandom: false, outletPK: 7,
            dateFrom: nil, dateTo: nil, minThreadReplies: nil, maxThreadReplies: nil)
        XCTAssertEqual(frame.kind, .filtered)
        XCTAssertEqual(frame.outletPK, 7)
    }

    // MARK: - parseOptionalInt

    func testParseOptionalIntBlankIsNil() {
        XCTAssertNil(LabellingFormatting.parseOptionalInt(""))
        XCTAssertNil(LabellingFormatting.parseOptionalInt("   "))
    }

    func testParseOptionalIntUnparseableIsNil() {
        XCTAssertNil(LabellingFormatting.parseOptionalInt("abc"))
    }

    func testParseOptionalIntNegativeIsNil() {
        XCTAssertNil(LabellingFormatting.parseOptionalInt("-1"))
    }

    func testParseOptionalIntValid() {
        XCTAssertEqual(LabellingFormatting.parseOptionalInt("42"), 42)
    }

    // MARK: - parseBatchSize

    func testParseBatchSizeDefaultsWhenBlank() {
        XCTAssertEqual(LabellingFormatting.parseBatchSize(""), 100)
    }

    func testParseBatchSizeDefaultsWhenZero() {
        XCTAssertEqual(LabellingFormatting.parseBatchSize("0"), 100)
    }

    func testParseBatchSizeDefaultsWhenNegative() {
        XCTAssertEqual(LabellingFormatting.parseBatchSize("-5"), 100)
    }

    func testParseBatchSizeValid() {
        XCTAssertEqual(LabellingFormatting.parseBatchSize("250"), 250)
    }

    // MARK: - batch list

    func testBatchProgressSummary() {
        XCTAssertEqual(LabellingFormatting.batchProgressSummary(labelled: 24, skipped: 2, drawn: 100),
                        "24 labelled · 2 skipped · 74 remaining")
    }

    /// Every batch-progress string must reconcile: labelled + skipped + remaining ==
    /// drawn, however the counts are split.
    func testBatchProgressSummaryCountsReconcile() {
        XCTAssertEqual(LabellingFormatting.batchProgressSummary(labelled: 0, skipped: 0, drawn: 5),
                        "0 labelled · 0 skipped · 5 remaining")
        XCTAssertEqual(LabellingFormatting.batchProgressSummary(labelled: 5, skipped: 0, drawn: 5),
                        "5 labelled · 0 skipped · 0 remaining")
    }

    func testPassLabel() {
        XCTAssertEqual(LabellingFormatting.passLabel(1), "Pass 1")
        XCTAssertEqual(LabellingFormatting.passLabel(2), "Pass 2")
    }

    // MARK: - Agreement — must never drop "intra-rater"

    func testAgreementSummaryContainsIntraRater() {
        let report = AgreementReport(n: 40, percentAgreement: 0.875, cohensKappa: 0.71)
        let summary = LabellingFormatting.agreementSummary(report)
        XCTAssertTrue(summary.contains("intra-rater"),
                       "Agreement string must say 'intra-rater' — a bare kappa overclaims.")
        XCTAssertTrue(summary.contains("40"))
        XCTAssertTrue(summary.contains("88") || summary.contains("87"))
        XCTAssertTrue(summary.contains("0.71"))
    }

    func testAgreementSummaryNeverSaysBareKappa() {
        let report = AgreementReport(n: 10, percentAgreement: 1.0, cohensKappa: 1.0)
        let summary = LabellingFormatting.agreementSummary(report)
        // "κ" must always be immediately preceded by "intra-rater" in this string.
        XCTAssertFalse(summary.contains("agreement κ") == true && !summary.contains("intra-rater κ"))
        XCTAssertTrue(summary.contains("intra-rater κ"))
    }

    // MARK: - Session

    func testSessionProgressSummaryIsOneIndexed() {
        XCTAssertEqual(LabellingFormatting.sessionProgressSummary(index: 0, total: 100), "Item 1 of 100")
        XCTAssertEqual(LabellingFormatting.sessionProgressSummary(index: 99, total: 100), "Item 100 of 100")
    }

    func testElapsedSummaryFormatsMinutesSeconds() {
        XCTAssertEqual(LabellingFormatting.elapsedSummary(0), "00:00")
        XCTAssertEqual(LabellingFormatting.elapsedSummary(65), "01:05")
        XCTAssertEqual(LabellingFormatting.elapsedSummary(3599), "59:59")
    }

    func testElapsedSummaryCapsAtNinetyNineMinutes() {
        // Minutes cap at 99; the seconds remainder keeps reflecting the real elapsed
        // time rather than being clamped to :59 as well.
        XCTAssertEqual(LabellingFormatting.elapsedSummary(999_999), "99:39")
    }

    // MARK: - keyIsPermitted — the advancement gate

    /// The one case this whole helper exists to prevent: a bare "0" (skip) keypress or
    /// its mouse-button equivalent silently abandoning a label that `.saveFailed` says
    /// was NOT persisted. Against the old, unconditional `case "0": viewModel.skip()`
    /// this would have failed (that code let "0" through unconditionally, in every
    /// state) — this is the "watch it fail" case for this fix.
    func testKeyZeroDeniedUnderSaveFailed() {
        XCTAssertFalse(LabellingFormatting.keyIsPermitted(
            "0", recordError: .saveFailed("disk full")))
    }

    func testKeyZeroDeniedUnderBatchNotFound() {
        XCTAssertFalse(LabellingFormatting.keyIsPermitted(
            "0", recordError: .batchNotFound))
    }

    func testClassKeysStayPermittedUnderSaveFailedForRetry() {
        for key in ["1", "2", "3"] {
            XCTAssertTrue(LabellingFormatting.keyIsPermitted(key, recordError: .saveFailed("x")),
                          "key \(key) must stay permitted so the annotator can retry")
        }
    }

    func testClassKeysStayPermittedUnderBatchNotFoundForRetry() {
        for key in ["1", "2", "3"] {
            XCTAssertTrue(LabellingFormatting.keyIsPermitted(key, recordError: .batchNotFound),
                          "key \(key) must stay permitted so the annotator can retry")
        }
    }

    func testAllKeysPermittedWhenNoRecordError() {
        for key in ["0", "1", "2", "3"] {
            XCTAssertTrue(LabellingFormatting.keyIsPermitted(key, recordError: nil))
        }
    }

    func testAllKeysPermittedUnderPostNotFoundBecauseItIsTransientNotBlocking() {
        for key in ["0", "1", "2", "3"] {
            XCTAssertTrue(LabellingFormatting.keyIsPermitted(
                key, recordError: .postNotFound("at://gone")))
        }
    }
}

// MARK: - Text scale

extension LabellingFormattingTests {

    func testTextScaleClampsIntoSupportedRange() {
        XCTAssertEqual(LabellingFormatting.clampedTextScale(1.3), 1.3, accuracy: 0.0001)
        XCTAssertEqual(LabellingFormatting.clampedTextScale(0.1),
                       LabellingFormatting.minTextScale, accuracy: 0.0001)
        XCTAssertEqual(LabellingFormatting.clampedTextScale(99),
                       LabellingFormatting.maxTextScale, accuracy: 0.0001)
    }

    /// A corrupted stored preference must not render invisible or absurd text.
    func testTextScaleFallsBackToOneOnNonsenseValues() {
        XCTAssertEqual(LabellingFormatting.clampedTextScale(0), 1.0, accuracy: 0.0001)
        XCTAssertEqual(LabellingFormatting.clampedTextScale(-5), 1.0, accuracy: 0.0001)
        XCTAssertEqual(LabellingFormatting.clampedTextScale(.nan), 1.0, accuracy: 0.0001)
        XCTAssertEqual(LabellingFormatting.clampedTextScale(.infinity), 1.0, accuracy: 0.0001)
    }
}

// MARK: - Definitions reference panel

extension LabellingFormattingTests {

    func testDefinitionPanelKeyLabelMatchesKeyBinding() {
        XCTAssertEqual(LabellingFormatting.definitionPanelKeyLabel(LabellingDefinitions.hate), "1 · hate")
        XCTAssertEqual(LabellingFormatting.definitionPanelKeyLabel(LabellingDefinitions.counter), "2 · counter")
        XCTAssertEqual(LabellingFormatting.definitionPanelKeyLabel(LabellingDefinitions.neutral), "3 · neutral")
        XCTAssertEqual(LabellingFormatting.definitionPanelKeyLabel(LabellingDefinitions.skip), "0 · skip")
    }
}
