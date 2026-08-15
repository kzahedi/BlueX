import XCTest
@testable import BlueX

/// Covers `AggregateReader`'s labelling-pool queries and `LabellingContext` fetch —
/// the SQL layer the labelling tab reads through. The load-bearing property here isn't
/// any one count: it's that `labellingPoolCount` and `labellingPoolURIs` can never
/// disagree (same shared predicate), and that `LabellingContext` structurally cannot
/// carry a model score, label, or class — see `testLabellingContextExposesNoModelFields`.
final class AggregateReaderLabellingTests: XCTestCase {
    private var reader: AggregateReader!

    override func setUpWithError() throws {
        reader = try AggregateReader(storeURL: try StoreFixture.make())
    }

    // MARK: - labellingPoolCount / labellingPoolURIs

    /// Uniform random draws from the whole reply population, no predicate at all.
    /// `AggregateReaderPopulationTests.testTotals` pins the fixture's total replies at
    /// 224 (1+2+3+9+10+99+100 across the 7 reply authors); the pool must agree exactly.
    func testUniformPoolCountIsTotalReplies() throws {
        XCTAssertEqual(try reader.labellingPoolCount(frame: .uniformRandom), 224)
    }

    func testUniformPoolURIsCountMatchesPoolCount() throws {
        let uris = try reader.labellingPoolURIs(frame: .uniformRandom)
        XCTAssertEqual(uris.count, try reader.labellingPoolCount(frame: .uniformRandom))
        XCTAssertEqual(Set(uris).count, uris.count, "no duplicate URIs")
    }

    /// Outlet 1 (r1) carries 222 of the fixture's 224 replies; outlet 2 (r2) carries the
    /// other 2 (did:a x1, did:b x1) — see `AggregateReaderChartsTests
    /// .testRepliesPerWeekSumsToAllRepliesOnOwnedRoots` for the same 222/2 split.
    func testOutletFilterNarrowsToThatOutletsReplies() throws {
        let outletOne = SamplingFrame(kind: .filtered, outletPK: 1,
                                       dateFrom: nil, dateTo: nil,
                                       minThreadReplies: nil, maxThreadReplies: nil)
        XCTAssertEqual(try reader.labellingPoolCount(frame: outletOne), 222)

        let outletTwo = SamplingFrame(kind: .filtered, outletPK: 2,
                                       dateFrom: nil, dateTo: nil,
                                       minThreadReplies: nil, maxThreadReplies: nil)
        XCTAssertEqual(try reader.labellingPoolCount(frame: outletTwo), 2)
    }

    /// Thread size = the root's total reply count. Root r1 (222 replies) and root r2
    /// (2 replies) sit far enough apart that a `minThreadReplies`/`maxThreadReplies`
    /// bound can cleanly select one root's replies without the other.
    func testThreadSizeFilterUsesHavingOnTheRootsReplyCount() throws {
        let bigThreadsOnly = SamplingFrame(kind: .filtered, outletPK: nil,
                                            dateFrom: nil, dateTo: nil,
                                            minThreadReplies: 200, maxThreadReplies: nil)
        XCTAssertEqual(try reader.labellingPoolCount(frame: bigThreadsOnly), 222,
                       "only r1 (222 replies) has a thread size >= 200")

        let smallThreadsOnly = SamplingFrame(kind: .filtered, outletPK: nil,
                                              dateFrom: nil, dateTo: nil,
                                              minThreadReplies: nil, maxThreadReplies: 10)
        XCTAssertEqual(try reader.labellingPoolCount(frame: smallThreadsOnly), 2,
                       "only r2 (2 replies) has a thread size <= 10")
    }

    /// did:c1 is the earliest reply in the fixture, at exactly 2024-01-01T00:00:00Z.
    /// A `dateTo` at that exact instant must include it (inclusive boundary); a
    /// `dateTo` one second earlier must exclude it (nothing is that early).
    func testDateRangeFilterIncludesAndExcludesAcrossABoundary() throws {
        let atBoundary = SamplingFrame(kind: .filtered, outletPK: nil,
                                        dateFrom: nil,
                                        dateTo: StoreFixture.date("2024-01-01T00:00:00Z"),
                                        minThreadReplies: nil, maxThreadReplies: nil)
        XCTAssertEqual(try reader.labellingPoolCount(frame: atBoundary), 1,
                       "only at://c1 sits at or before this instant")

        let beforeBoundary = SamplingFrame(kind: .filtered, outletPK: nil,
                                            dateFrom: nil,
                                            dateTo: StoreFixture.date("2023-12-31T23:59:59Z"),
                                            minThreadReplies: nil, maxThreadReplies: nil)
        XCTAssertEqual(try reader.labellingPoolCount(frame: beforeBoundary), 0,
                       "one second earlier excludes even at://c1")
    }

    /// Thread size describes the whole thread, not whatever slice of it a date range
    /// happens to let into the pool — the two filters describe different things (one
    /// the reply, one the thread it's in) and must not be conflated. Root r1's TRUE
    /// size is 222 (comfortably over the 200 threshold), but only ONE of its replies
    /// (at://c2, 2024-02-01) falls inside this narrow one-instant date window. If the
    /// thread-size subquery wrongly counted only date-windowed replies, that windowed
    /// count would be 1 (< 200), r1 would fail the threshold, and the pool would come
    /// back empty instead of containing at://c2.
    func testThreadSizeUsesTrueThreadSizeNotDateWindowedReplyCount() throws {
        let frame = SamplingFrame(kind: .filtered, outletPK: nil,
                                   dateFrom: StoreFixture.date("2024-02-01T00:00:00Z"),
                                   dateTo: StoreFixture.date("2024-02-01T00:00:00Z"),
                                   minThreadReplies: 200, maxThreadReplies: nil)
        XCTAssertEqual(try reader.labellingPoolURIs(frame: frame), ["at://c2"])
        XCTAssertEqual(try reader.labellingPoolCount(frame: frame), 1)
    }

    /// `labellingPoolCount` and `labellingPoolURIs` share one predicate-building helper
    /// specifically so they cannot drift apart — this test exercises that agreement
    /// across every kind of frame above, not just the uniform case.
    func testPoolCountAndURIsAgreeForEveryFrame() throws {
        let frames: [SamplingFrame] = [
            .uniformRandom,
            SamplingFrame(kind: .filtered, outletPK: 1, dateFrom: nil, dateTo: nil,
                          minThreadReplies: nil, maxThreadReplies: nil),
            SamplingFrame(kind: .filtered, outletPK: nil, dateFrom: nil, dateTo: nil,
                          minThreadReplies: 200, maxThreadReplies: nil),
            SamplingFrame(kind: .filtered, outletPK: nil,
                          dateFrom: nil,
                          dateTo: StoreFixture.date("2024-01-01T00:00:00Z"),
                          minThreadReplies: nil, maxThreadReplies: nil),
        ]
        for frame in frames {
            let count = try reader.labellingPoolCount(frame: frame)
            let uris = try reader.labellingPoolURIs(frame: frame)
            XCTAssertEqual(uris.count, count, "count and URIs disagree for frame \(frame)")
        }
    }

    // MARK: - labellingContext

    /// at://b1 is an ordinary depth-1 reply: its `ZPARENTURI` equals its `ZROOTURI`
    /// (at://r1), so the parent fields must be nil — a labeller must not be shown the
    /// root a second time under the "parent" label.
    func testContextForDepth1ReplyHasNilParentFields() throws {
        let contexts = try reader.labellingContext(uris: ["at://b1"])
        let ctx = try XCTUnwrap(contexts.first)
        XCTAssertEqual(ctx.uri, "at://b1")
        XCTAssertEqual(ctx.authorHandle, "bob.test")
        XCTAssertEqual(ctx.rootURI, "at://r1")
        XCTAssertEqual(ctx.rootHandle, "outlet-one.com")
        XCTAssertNil(ctx.parentURI)
        XCTAssertNil(ctx.parentText)
        XCTAssertNil(ctx.parentHandle)
    }

    /// at://c3 is `StoreFixture.make()`'s sole depth-2 reply: its `ZPARENTURI` is
    /// at://c2 (another reply, not the root). Parent fields must carry that
    /// intermediate reply's own text/handle, not the root's.
    func testContextForDepth2ReplyCarriesIntermediateParent() throws {
        let contexts = try reader.labellingContext(uris: ["at://c3"])
        let ctx = try XCTUnwrap(contexts.first)
        XCTAssertEqual(ctx.uri, "at://c3")
        XCTAssertEqual(ctx.rootURI, "at://r1")
        XCTAssertEqual(ctx.parentURI, "at://c2")
        XCTAssertEqual(ctx.parentText, "text")
        XCTAssertEqual(ctx.parentHandle, "carol.test")
    }

    func testContextBatchFetchReturnsBothRequestedRows() throws {
        let contexts = try reader.labellingContext(uris: ["at://b1", "at://c3"])
        XCTAssertEqual(Set(contexts.map(\.uri)), ["at://b1", "at://c3"])
    }

    /// An unknown URI is simply absent from the result — never a thrown error. The
    /// caller drawing a batch has no reliable way to tell "already labelled and
    /// pruned" from "never existed" and shouldn't have to.
    func testUnknownURIIsAbsentNotAnError() throws {
        XCTAssertNoThrow(try reader.labellingContext(uris: ["at://does-not-exist"]))
        let contexts = try reader.labellingContext(uris: ["at://does-not-exist", "at://b1"])
        XCTAssertEqual(contexts.map(\.uri), ["at://b1"])
    }

    func testEmptyURIListReturnsEmptyWithoutQuerying() throws {
        XCTAssertEqual(try reader.labellingContext(uris: []), [])
    }

    // MARK: - Structural blindness guarantee

    /// The central integrity requirement of this task: `LabellingContext` is the
    /// structural guarantee that the labelling view cannot see any model output.
    /// Crude, but it fails loudly the instant a future edit adds a field like
    /// `modelScore` or `predictedLabel` — see the task brief for why this matters:
    /// human labels are this project's held-out gold set, and a labeller who can see a
    /// model's own guess about the post they're labelling is no longer producing an
    /// independent measurement.
    func testLabellingContextExposesNoModelFields() {
        let sample = AggregateReader.LabellingContext(
            uri: "x", text: "x", createdAt: Date(), authorHandle: "x",
            rootURI: "x", rootText: "x", rootHandle: "x",
            parentURI: nil, parentText: nil, parentHandle: nil
        )
        let forbidden = ["score", "label", "class", "sentiment", "model"]
        for child in Mirror(reflecting: sample).children {
            guard let name = child.label?.lowercased() else { continue }
            for term in forbidden {
                XCTAssertFalse(name.contains(term),
                                "LabellingContext.\(name) contains forbidden term '\(term)' — " +
                                "this struct must stay structurally blind to model output")
            }
        }
    }
}
