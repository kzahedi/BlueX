import XCTest
@testable import BlueX

final class AccountViewModelTests: XCTestCase {
    // MARK: - replyCountBounds (filter-state -> reader-parameter mapping)

    func testAnyPresetIsUnbounded() {
        let vm = AccountViewModel()
        vm.replyCountPreset = .any
        let bounds = vm.replyCountBounds
        XCTAssertNil(bounds.min)
        XCTAssertNil(bounds.max)
    }

    func testOneOrMorePresetHasNoUpperBound() {
        let vm = AccountViewModel()
        vm.replyCountPreset = .oneOrMore
        let bounds = vm.replyCountBounds
        XCTAssertEqual(bounds.min, 1)
        XCTAssertNil(bounds.max, "an absent maximum must mean unbounded, never a silent cap")
    }

    func testFiftyToNinetyNineIsTheOneExplicitRange() {
        let vm = AccountViewModel()
        vm.replyCountPreset = .fiftyToNinetyNine
        let bounds = vm.replyCountBounds
        XCTAssertEqual(bounds.min, 50)
        XCTAssertEqual(bounds.max, 99)
    }

    func testTwoHundredOrMorePresetHasNoUpperBound() {
        let vm = AccountViewModel()
        vm.replyCountPreset = .twoHundredOrMore
        let bounds = vm.replyCountBounds
        XCTAssertEqual(bounds.min, 200)
        XCTAssertNil(bounds.max)
    }

    func testCustomPresetUsesTheEnteredMinimumWithNoUpperBound() {
        let vm = AccountViewModel()
        vm.customMinReplies = 37
        vm.replyCountPreset = .custom
        let bounds = vm.replyCountBounds
        XCTAssertEqual(bounds.min, 37)
        XCTAssertNil(bounds.max, "\"more than N\" must never silently become a range with a cap")
    }

    func testCustomPresetClampsNegativeEntryToZero() {
        let vm = AccountViewModel()
        vm.customMinReplies = -5
        vm.replyCountPreset = .custom
        XCTAssertEqual(vm.replyCountBounds.min, 0)
    }

    // MARK: - filteredRootPosts

    private func row(_ uri: String, _ text: String, _ iso: String) -> RootPostSummary {
        RootPostSummary(uri: uri, text: text, createdAt: StoreFixture.date(iso),
                         replyCount: 0, replyTreeStatus: "complete")
    }

    func testSearchTextFiltersByCaseInsensitiveSubstring() {
        let vm = AccountViewModel()
        vm.searchText = "hello"
        let rows = [
            row("at://1", "Hello world", "2024-01-01T00:00:00Z"),
            row("at://2", "Goodbye", "2024-01-02T00:00:00Z"),
        ]
        let result = vm.filteredRootPosts(rows)
        XCTAssertEqual(result.map(\.uri), ["at://1"])
    }

    func testSortNewestFirstOrdersDescendingByCreatedAt() {
        let vm = AccountViewModel()
        vm.sortNewestFirst = true
        let rows = [
            row("at://old", "a", "2024-01-01T00:00:00Z"),
            row("at://new", "b", "2024-06-01T00:00:00Z"),
        ]
        XCTAssertEqual(vm.filteredRootPosts(rows).map(\.uri), ["at://new", "at://old"])
    }

    func testSortOldestFirstOrdersAscendingByCreatedAt() {
        let vm = AccountViewModel()
        vm.sortNewestFirst = false
        let rows = [
            row("at://old", "a", "2024-01-01T00:00:00Z"),
            row("at://new", "b", "2024-06-01T00:00:00Z"),
        ]
        XCTAssertEqual(vm.filteredRootPosts(rows).map(\.uri), ["at://old", "at://new"])
    }
}
