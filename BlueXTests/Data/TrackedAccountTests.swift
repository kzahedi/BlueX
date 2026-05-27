import XCTest
import SwiftData
@testable import BlueX

final class TrackedAccountTests: XCTestCase {
    var container: ModelContainer!
    var context: ModelContext!

    override func setUpWithError() throws {
        // Why: isStoredInMemoryOnly: true creates a throw-away database for each test.
        // Tests are isolated from each other and from production data.
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(
            for: TrackedAccount.self, AccountGroup.self,
            Post.self, Annotation.self, AccountSnapshot.self,
            ScrapeLog.self, ModelConfig.self, CoordinatorState.self,
            configurations: config
        )
        context = ModelContext(container)
    }

    override func tearDownWithError() throws {
        container = nil
        context = nil
    }

    func testCreateAndPersistTrackedAccount() throws {
        let account = TrackedAccount(
            did: "did:plc:test123",
            handle: "spiegel.de",
            displayName: "DER SPIEGEL",
            startAt: Date()
        )
        context.insert(account)
        try context.save()

        let accounts = try context.fetch(FetchDescriptor<TrackedAccount>())
        XCTAssertEqual(accounts.count, 1)
        XCTAssertEqual(accounts[0].did, "did:plc:test123")
        XCTAssertEqual(accounts[0].handle, "spiegel.de")
        XCTAssertTrue(accounts[0].isActive)
        XCTAssertTrue(accounts[0].posts.isEmpty)
    }

    func testAccountGroupMembership() throws {
        let account = TrackedAccount(did: "did:plc:test", handle: "zeit.de", displayName: "ZEIT", startAt: Date())
        let group = AccountGroup(name: "German Media")
        account.groups.append(group)
        context.insert(account)
        context.insert(group)
        try context.save()

        let groups = try context.fetch(FetchDescriptor<AccountGroup>())
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].name, "German Media")
        XCTAssertEqual(groups[0].accounts.count, 1)
    }

    func testDefaultIsActiveTrue() throws {
        let account = TrackedAccount(did: "d", handle: "h", displayName: "D", startAt: Date())
        XCTAssertTrue(account.isActive)
    }
}
