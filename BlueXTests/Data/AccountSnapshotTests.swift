import XCTest
import SwiftData
@testable import BlueX

final class AccountSnapshotTests: XCTestCase {
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

    override func tearDownWithError() throws {
        container = nil
        context = nil
    }

    func testSnapshotPersistsAllFields() throws {
        let account = TrackedAccount(
            did: "did:plc:test", handle: "nytimes.com",
            displayName: "NYT", startAt: Date()
        )
        context.insert(account)

        let snap = AccountSnapshot(
            timestamp: Date(),
            followerCount: 100_000,
            followingCount: 500,
            postCount: 4_200,
            totalLikes: 99_000,
            totalReplies: 12_000,
            totalReposts: 5_500,
            totalQuotes: 800
        )
        snap.account = account
        context.insert(snap)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<AccountSnapshot>())
        XCTAssertEqual(fetched.count, 1)
        let s = fetched[0]
        XCTAssertEqual(s.followerCount, 100_000)
        XCTAssertEqual(s.followingCount, 500)
        XCTAssertEqual(s.postCount, 4_200)
        XCTAssertEqual(s.totalLikes, 99_000)
        XCTAssertEqual(s.totalReplies, 12_000)
        XCTAssertEqual(s.totalReposts, 5_500)
        XCTAssertEqual(s.totalQuotes, 800)
        XCTAssertEqual(s.account?.handle, "nytimes.com")
    }

    func testDefaultEngagementFieldsAreZero() throws {
        let snap = AccountSnapshot(
            timestamp: Date(), followerCount: 0,
            followingCount: 0, postCount: 0
        )
        XCTAssertEqual(snap.totalLikes, 0)
        XCTAssertEqual(snap.totalReplies, 0)
        XCTAssertEqual(snap.totalReposts, 0)
        XCTAssertEqual(snap.totalQuotes, 0)
    }

    func testDedupCheckDetectsTodaysSnapshot() throws {
        let account = TrackedAccount(
            did: "did:plc:test2", handle: "zeit.de",
            displayName: "ZEIT", startAt: Date()
        )
        context.insert(account)
        let snap = AccountSnapshot(
            timestamp: Date(), followerCount: 50_000,
            followingCount: 200, postCount: 1_000
        )
        snap.account = account
        context.insert(snap)
        try context.save()

        let alreadySnapshotted = account.snapshots.contains {
            Calendar.current.isDateInToday($0.timestamp)
        }
        XCTAssertTrue(alreadySnapshotted)
    }

    func testDedupCheckMissesYesterdaysSnapshot() throws {
        let account = TrackedAccount(
            did: "did:plc:test3", handle: "spiegel.de",
            displayName: "SPIEGEL", startAt: Date()
        )
        context.insert(account)
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        let snap = AccountSnapshot(
            timestamp: yesterday, followerCount: 40_000,
            followingCount: 100, postCount: 900
        )
        snap.account = account
        context.insert(snap)
        try context.save()

        let alreadySnapshotted = account.snapshots.contains {
            Calendar.current.isDateInToday($0.timestamp)
        }
        XCTAssertFalse(alreadySnapshotted)
    }
}
