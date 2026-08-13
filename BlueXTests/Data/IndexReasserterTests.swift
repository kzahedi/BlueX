// BlueXTests/Data/IndexReasserterTests.swift
import XCTest
@testable import BlueX

final class IndexReasserterTests: XCTestCase {
    /// Core requirement 1: a store that lacks the indexes gets them created.
    func testCreatesIndexesOnAStoreThatLacksThem() throws {
        let url = try StoreFixture.make()

        let reader = try AggregateReader(storeURL: url)
        XCTAssertFalse(try reader.indexHealth().isHealthy,
                       "fixture must start without the hand-made indexes")

        let outcome = IndexReasserter.reassert(storeURL: url)
        guard case .reasserted(let created) = outcome else {
            return XCTFail("expected .reasserted, got \(outcome)")
        }
        XCTAssertEqual(Set(created), Set(StoreIndexPlan.names),
                       "every planned index was missing, so every one should be reported created")

        let health = try AggregateReader(storeURL: url).indexHealth()
        XCTAssertTrue(health.isHealthy, "expected all indexes present after reassertion, missing: \(health.missing)")
    }

    /// Core requirement 2: re-asserting on a store that already has them is a
    /// no-op — no error, and nothing reported as newly created.
    func testReassertingOnAStoreThatHasThemIsANoOp() throws {
        let url = try StoreFixture.make()
        IndexReasserter.reassert(storeURL: url)
        let firstHealth = try AggregateReader(storeURL: url).indexHealth()
        XCTAssertTrue(firstHealth.isHealthy)

        let outcome = IndexReasserter.reassert(storeURL: url)
        guard case .reasserted(let created) = outcome else {
            return XCTFail("expected .reasserted, got \(outcome)")
        }
        XCTAssertTrue(created.isEmpty, "nothing was missing, so nothing should be reported created")

        let secondHealth = try AggregateReader(storeURL: url).indexHealth()
        XCTAssertTrue(secondHealth.isHealthy)
    }

    /// Core requirement 4: a failure to acquire the write connection degrades
    /// gracefully rather than throwing/crashing. `reassert` opens READWRITE without
    /// CREATE, so a path that doesn't exist at all fails to open — the same shape of
    /// failure as a read-only volume or a lock held by another process.
    func testUnavailableWriteConnectionDegradesGracefully() {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bluex-index-reasserter-missing-\(UUID().uuidString)")
            .appendingPathComponent("does-not-exist.sqlite")

        let outcome = IndexReasserter.reassert(storeURL: missing)
        guard case .unavailable = outcome else {
            return XCTFail("expected .unavailable, got \(outcome)")
        }
        // The point of the requirement: this call must return, not throw or crash.
    }

    /// Requirement 3 (detector half — creator/checker structural pairing): the
    /// indexes `reassert` reports as created are exactly the names in
    /// `StoreIndexPlan.all`, the same constant the checker reads. This does not
    /// duplicate the list in the test — it asserts against `StoreIndexPlan.names`
    /// directly, so a change to the shared plan changes both sides of this
    /// assertion together.
    func testCreatedIndexNamesComeFromTheSharedPlan() throws {
        let url = try StoreFixture.make()
        guard case .reasserted(let created) = IndexReasserter.reassert(storeURL: url) else {
            return XCTFail("expected .reasserted")
        }
        XCTAssertEqual(Set(created), Set(StoreIndexPlan.names))
    }
}
