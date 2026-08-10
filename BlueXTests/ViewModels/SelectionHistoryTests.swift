// BlueXTests/ViewModels/SelectionHistoryTests.swift
import XCTest
import SwiftData
@testable import BlueX

final class SelectionHistoryTests: XCTestCase {

    /// A group needs a model object, unlike `.queue`/`.settings`, so build it in an
    /// in-memory container per the brief's guidance — only when a third distinct,
    /// non-account/post case is genuinely needed (here, for the three-item stack test).
    private func makeGroupItem() throws -> SidebarItem {
        let container = try ModelContainer(
            for: AccountGroup.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let group = AccountGroup(name: "test-group")
        let context = ModelContext(container)
        context.insert(group)
        return .group(group)
    }

    func testFreshHistoryCannotGoBack() {
        let history = SelectionHistory()
        XCTAssertFalse(history.canGoBack)
        XCTAssertNil(history.goBack())
    }

    func testRecordingOneItemThenGoingBackEmptiesTheStack() {
        let history = SelectionHistory()
        history.record(.queue)
        XCTAssertTrue(history.canGoBack)
        XCTAssertEqual(history.goBack(), .queue)
        XCTAssertFalse(history.canGoBack)
        XCTAssertNil(history.goBack())
    }

    func testGoingBackThriceUnwindsInReverseOrder() throws {
        let history = SelectionHistory()
        let groupItem = try makeGroupItem()
        history.record(.queue)
        history.record(.settings)
        history.record(groupItem)
        XCTAssertEqual(history.goBack(), groupItem)
        XCTAssertEqual(history.goBack(), .settings)
        XCTAssertEqual(history.goBack(), .queue)
        XCTAssertNil(history.goBack())
    }

    func testRecordingNilIsIgnored() {
        let history = SelectionHistory()
        history.record(nil)
        XCTAssertFalse(history.canGoBack)
    }

    func testConsecutiveDuplicatesAreNotRecordedTwice() {
        let history = SelectionHistory()
        history.record(.queue)
        history.record(.queue)
        XCTAssertEqual(history.goBack(), .queue)
        XCTAssertFalse(history.canGoBack)
    }

    func testExceedingMaxDepthDropsOldestEntries() {
        let history = SelectionHistory()
        // Alternate between two items so every record passes the consecutive-duplicate
        // guard, and push well past maxDepth.
        for i in 0..<(SelectionHistory.maxDepth + 10) {
            history.record(i.isMultiple(of: 2) ? .queue : .settings)
        }
        XCTAssertEqual(history.stack.count, SelectionHistory.maxDepth)
        // The oldest entries were dropped; the most recent one recorded survives.
        XCTAssertEqual(history.stack.last, .settings)
    }

    func testClearEmptiesTheStack() {
        let history = SelectionHistory()
        history.record(.queue)
        history.record(.settings)
        history.clear()
        XCTAssertFalse(history.canGoBack)
        XCTAssertNil(history.goBack())
    }
}
