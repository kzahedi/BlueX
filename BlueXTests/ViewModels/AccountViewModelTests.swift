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

    // MARK: - replyCountBounds / customRangeError (typed min/max fields)

    func testCustomEmptyEmptyIsUnbounded() {
        let vm = AccountViewModel()
        vm.replyCountPreset = .custom
        vm.minRepliesText = ""
        vm.maxRepliesText = ""
        let bounds = vm.replyCountBounds
        XCTAssertNil(bounds.min)
        XCTAssertNil(bounds.max)
        XCTAssertNil(vm.customRangeError)
    }

    func testCustomMinOnlyHasNoUpperBound() {
        let vm = AccountViewModel()
        vm.replyCountPreset = .custom
        vm.minRepliesText = "37"
        vm.maxRepliesText = ""
        let bounds = vm.replyCountBounds
        XCTAssertEqual(bounds.min, 37)
        XCTAssertNil(bounds.max, "an absent maximum must never silently become a cap")
        XCTAssertNil(vm.customRangeError)
    }

    func testCustomMaxOnlyHasNoLowerBound() {
        let vm = AccountViewModel()
        vm.replyCountPreset = .custom
        vm.minRepliesText = ""
        vm.maxRepliesText = "20"
        let bounds = vm.replyCountBounds
        XCTAssertNil(bounds.min)
        XCTAssertEqual(bounds.max, 20)
        XCTAssertNil(vm.customRangeError)
    }

    func testCustomBothMinAndMax() {
        let vm = AccountViewModel()
        vm.replyCountPreset = .custom
        vm.minRepliesText = "5"
        vm.maxRepliesText = "50"
        let bounds = vm.replyCountBounds
        XCTAssertEqual(bounds.min, 5)
        XCTAssertEqual(bounds.max, 50)
        XCTAssertNil(vm.customRangeError)
    }

    func testCustomMinGreaterThanMaxSurfacesInlineError() {
        let vm = AccountViewModel()
        vm.replyCountPreset = .custom
        vm.minRepliesText = "50"
        vm.maxRepliesText = "5"
        // The mapping itself still reflects what was typed — it's `customRangeError`
        // that tells the view not to fire this query, not a silently different bound.
        let bounds = vm.replyCountBounds
        XCTAssertEqual(bounds.min, 50)
        XCTAssertEqual(bounds.max, 5)
        XCTAssertNotNil(vm.customRangeError)
    }

    func testCustomNonNumericJunkParsesToNoBoundAndSurfacesError() {
        let vm = AccountViewModel()
        vm.replyCountPreset = .custom
        vm.minRepliesText = "banana"
        vm.maxRepliesText = ""
        let bounds = vm.replyCountBounds
        XCTAssertNil(bounds.min, "junk input must never crash or be misread as a number")
        XCTAssertNil(bounds.max)
        XCTAssertNotNil(vm.customRangeError)
    }

    func testCustomNegativeMinParsesToNoBoundAndSurfacesError() {
        let vm = AccountViewModel()
        vm.replyCountPreset = .custom
        vm.minRepliesText = "-5"
        vm.maxRepliesText = ""
        let bounds = vm.replyCountBounds
        XCTAssertNil(bounds.min, "a negative reply count must never be silently clamped or accepted")
        XCTAssertNotNil(vm.customRangeError)
    }

    func testCustomWhitespaceOnlyTextIsTreatedAsEmpty() {
        let vm = AccountViewModel()
        vm.replyCountPreset = .custom
        vm.minRepliesText = "   "
        vm.maxRepliesText = "  10  "
        let bounds = vm.replyCountBounds
        XCTAssertNil(bounds.min)
        XCTAssertEqual(bounds.max, 10)
        XCTAssertNil(vm.customRangeError)
    }

    func testCustomRangeErrorIsNilWhenPresetIsNotCustom() {
        let vm = AccountViewModel()
        vm.replyCountPreset = .any
        vm.minRepliesText = "not a number"
        XCTAssertNil(vm.customRangeError, "junk in the fields shouldn't matter unless custom is selected")
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
