import XCTest
import SwiftData
@testable import BlueX

final class ScrapeLogTests: XCTestCase {
    var container: ModelContainer!
    var context: ModelContext!

    override func setUpWithError() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(
            for: TrackedAccount.self, AccountGroup.self,
            Post.self, Annotation.self, AccountSnapshot.self,
            ScrapeLog.self, ModelConfig.self, CoordinatorState.self,
            configurations: config
        )
        context = ModelContext(container)
    }

    override func tearDownWithError() throws { container = nil; context = nil }

    func testScrapeLogWithResumeCursor() throws {
        let log = ScrapeLog(date: Date(), type: "feed", status: "failed",
                            postCount: 42, resumeCursor: "cursor:abc123")
        context.insert(log)
        try context.save()

        let logs = try context.fetch(FetchDescriptor<ScrapeLog>())
        XCTAssertEqual(logs.count, 1)
        XCTAssertEqual(logs[0].resumeCursor, "cursor:abc123")
        XCTAssertEqual(logs[0].status, "failed")
        XCTAssertEqual(logs[0].postCount, 42)
    }

    func testScrapeLogComplete() throws {
        let log = ScrapeLog(date: Date(), type: "thread", status: "complete", postCount: 100)
        context.insert(log)
        try context.save()

        let logs = try context.fetch(FetchDescriptor<ScrapeLog>())
        XCTAssertNil(logs[0].resumeCursor)
        XCTAssertEqual(logs[0].status, "complete")
    }
}
