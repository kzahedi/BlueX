import XCTest
@testable import BlueX

final class AccountViewModelTests: XCTestCase {
    // Every test gets its own `UserDefaults` suite so persistence tests never touch —
    // or are polluted by — the real `.standard` domain or another test's leftovers.
    private var defaultsSuiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaultsSuiteName = "AccountViewModelTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        defaults = nil
        super.tearDown()
    }

    private func makeVM() -> AccountViewModel {
        AccountViewModel(defaults: defaults)
    }

    // MARK: - replyCountBounds (filter-state -> reader-parameter mapping)

    func testAnyPresetIsUnbounded() {
        let vm = makeVM()
        vm.replyCountPreset = .any
        let bounds = vm.replyCountBounds
        XCTAssertNil(bounds.min)
        XCTAssertNil(bounds.max)
    }

    func testOneOrMorePresetHasNoUpperBound() {
        let vm = makeVM()
        vm.replyCountPreset = .oneOrMore
        let bounds = vm.replyCountBounds
        XCTAssertEqual(bounds.min, 1)
        XCTAssertNil(bounds.max, "an absent maximum must mean unbounded, never a silent cap")
    }

    func testFiftyToNinetyNineIsTheOneExplicitRange() {
        let vm = makeVM()
        vm.replyCountPreset = .fiftyToNinetyNine
        let bounds = vm.replyCountBounds
        XCTAssertEqual(bounds.min, 50)
        XCTAssertEqual(bounds.max, 99)
    }

    func testTwoHundredOrMorePresetHasNoUpperBound() {
        let vm = makeVM()
        vm.replyCountPreset = .twoHundredOrMore
        let bounds = vm.replyCountBounds
        XCTAssertEqual(bounds.min, 200)
        XCTAssertNil(bounds.max)
    }

    // MARK: - replyCountBounds / customRangeError (typed min/max fields)

    func testCustomEmptyEmptyIsUnbounded() {
        let vm = makeVM()
        vm.replyCountPreset = .custom
        vm.minRepliesText = ""
        vm.maxRepliesText = ""
        let bounds = vm.replyCountBounds
        XCTAssertNil(bounds.min)
        XCTAssertNil(bounds.max)
        XCTAssertNil(vm.customRangeError)
    }

    func testCustomMinOnlyHasNoUpperBound() {
        let vm = makeVM()
        vm.replyCountPreset = .custom
        vm.minRepliesText = "37"
        vm.maxRepliesText = ""
        let bounds = vm.replyCountBounds
        XCTAssertEqual(bounds.min, 37)
        XCTAssertNil(bounds.max, "an absent maximum must never silently become a cap")
        XCTAssertNil(vm.customRangeError)
    }

    func testCustomMaxOnlyHasNoLowerBound() {
        let vm = makeVM()
        vm.replyCountPreset = .custom
        vm.minRepliesText = ""
        vm.maxRepliesText = "20"
        let bounds = vm.replyCountBounds
        XCTAssertNil(bounds.min)
        XCTAssertEqual(bounds.max, 20)
        XCTAssertNil(vm.customRangeError)
    }

    func testCustomBothMinAndMax() {
        let vm = makeVM()
        vm.replyCountPreset = .custom
        vm.minRepliesText = "5"
        vm.maxRepliesText = "50"
        let bounds = vm.replyCountBounds
        XCTAssertEqual(bounds.min, 5)
        XCTAssertEqual(bounds.max, 50)
        XCTAssertNil(vm.customRangeError)
    }

    func testCustomMinGreaterThanMaxSurfacesInlineError() {
        let vm = makeVM()
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
        let vm = makeVM()
        vm.replyCountPreset = .custom
        vm.minRepliesText = "banana"
        vm.maxRepliesText = ""
        let bounds = vm.replyCountBounds
        XCTAssertNil(bounds.min, "junk input must never crash or be misread as a number")
        XCTAssertNil(bounds.max)
        XCTAssertNotNil(vm.customRangeError)
    }

    func testCustomNegativeMinParsesToNoBoundAndSurfacesError() {
        let vm = makeVM()
        vm.replyCountPreset = .custom
        vm.minRepliesText = "-5"
        vm.maxRepliesText = ""
        let bounds = vm.replyCountBounds
        XCTAssertNil(bounds.min, "a negative reply count must never be silently clamped or accepted")
        XCTAssertNotNil(vm.customRangeError)
    }

    func testCustomWhitespaceOnlyTextIsTreatedAsEmpty() {
        let vm = makeVM()
        vm.replyCountPreset = .custom
        vm.minRepliesText = "   "
        vm.maxRepliesText = "  10  "
        let bounds = vm.replyCountBounds
        XCTAssertNil(bounds.min)
        XCTAssertEqual(bounds.max, 10)
        XCTAssertNil(vm.customRangeError)
    }

    func testCustomRangeErrorIsNilWhenPresetIsNotCustom() {
        let vm = makeVM()
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
        let vm = makeVM()
        vm.searchText = "hello"
        let rows = [
            row("at://1", "Hello world", "2024-01-01T00:00:00Z"),
            row("at://2", "Goodbye", "2024-01-02T00:00:00Z"),
        ]
        let result = vm.filteredRootPosts(rows)
        XCTAssertEqual(result.map(\.uri), ["at://1"])
    }

    func testSortNewestFirstOrdersDescendingByCreatedAt() {
        let vm = makeVM()
        vm.sortNewestFirst = true
        let rows = [
            row("at://old", "a", "2024-01-01T00:00:00Z"),
            row("at://new", "b", "2024-06-01T00:00:00Z"),
        ]
        XCTAssertEqual(vm.filteredRootPosts(rows).map(\.uri), ["at://new", "at://old"])
    }

    func testSortOldestFirstOrdersAscendingByCreatedAt() {
        let vm = makeVM()
        vm.sortNewestFirst = false
        let rows = [
            row("at://old", "a", "2024-01-01T00:00:00Z"),
            row("at://new", "b", "2024-06-01T00:00:00Z"),
        ]
        XCTAssertEqual(vm.filteredRootPosts(rows).map(\.uri), ["at://old", "at://new"])
    }

    // MARK: - Persistence
    //
    // Unlike `AuthorStatsViewModel`, nothing here gets a first-run default — this filter
    // means "tree size," not "author volume," and the user hasn't asked for a default.
    // Each test gets a fresh `UserDefaults(suiteName:)` (see `setUp`/`tearDown`).

    func testFirstRunHasNoDefaultPreset() {
        let vm = makeVM()
        XCTAssertEqual(vm.replyCountPreset, .any, "no default is imposed here, unlike the authors dashboard")
        XCTAssertEqual(vm.minRepliesText, "")
        XCTAssertEqual(vm.maxRepliesText, "")
    }

    func testStoredFilterIsRestoredOnNextLaunch() {
        let first = makeVM()
        first.replyCountPreset = .custom
        first.minRepliesText = "12"
        first.maxRepliesText = "34"

        let second = makeVM()
        XCTAssertEqual(second.replyCountPreset, .custom)
        XCTAssertEqual(second.minRepliesText, "12")
        XCTAssertEqual(second.maxRepliesText, "34")
    }

    func testClearedCustomTextStaysClearedAcrossReload() {
        let first = makeVM()
        first.replyCountPreset = .custom
        first.minRepliesText = "12"
        first.minRepliesText = ""

        let second = makeVM()
        XCTAssertEqual(second.minRepliesText, "")
    }

    /// A stored preset raw value that doesn't match any current `ReplyCountPreset` case
    /// must fall back to `.any` rather than trapping.
    func testCorruptPresetRawValueFallsBackToAny() {
        defaults.set("not-a-real-preset", forKey: "account.replyCountPreset")
        let vm = makeVM()
        XCTAssertEqual(vm.replyCountPreset, .any)
    }

    func testChangingReplyCountPresetPersistsImmediately() {
        let vm = makeVM()
        vm.replyCountPreset = .fiftyOrMore
        XCTAssertEqual(defaults.string(forKey: "account.replyCountPreset"), ReplyCountPreset.fiftyOrMore.rawValue)
    }
}
