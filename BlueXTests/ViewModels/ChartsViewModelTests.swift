import XCTest
@testable import BlueX

final class ChartsViewModelTests: XCTestCase {
    func testWeeklyRepliesComeFromTheReader() async throws {
        let reader = try AggregateReader(storeURL: try StoreFixture.make())
        let vm = ChartsViewModel()
        await vm.load(accountPKs: [1], reader: reader)

        // Account 1 owns only root r1. Its replies: did:c x3, did:n9 x9, did:n10 x10,
        // did:n99 x99, did:n100 x100, did:b x1 = 222.
        XCTAssertEqual(vm.weekBuckets.map(\.replyTotal).reduce(0, +), 222)
        // Compare weekStarts, not buckets: WeekBucket is Identifiable but not Equatable.
        let starts = vm.weekBuckets.map(\.weekStart)
        XCTAssertEqual(starts, starts.sorted())
    }

    func testEmptyAccountYieldsNoBuckets() async throws {
        let reader = try AggregateReader(storeURL: try StoreFixture.make())
        let vm = ChartsViewModel()
        await vm.load(accountPKs: [999], reader: reader)
        XCTAssertTrue(vm.weekBuckets.isEmpty)
    }

    func testWindowSelectsTheMostRecentBuckets() async throws {
        let reader = try AggregateReader(storeURL: try StoreFixture.make())
        let vm = ChartsViewModel()
        await vm.load(accountPKs: [1], reader: reader)
        vm.windowWeeks = 1
        XCTAssertEqual(vm.visibleBuckets.count, min(1, vm.weekBuckets.count))
        XCTAssertEqual(vm.visibleBuckets.last?.weekStart, vm.weekBuckets.last?.weekStart)
    }

    func testMultipleAccountsUnionTheirRootsAndReplies() async throws {
        let reader = try AggregateReader(storeURL: try StoreFixture.make())
        let vm = ChartsViewModel()
        await vm.load(accountPKs: [1, 2], reader: reader)
        // 222 (account 1's r1) + 2 (account 2's r2: did:a, did:b) = 224.
        XCTAssertEqual(vm.weekBuckets.map(\.replyTotal).reduce(0, +), 224)
    }
}
