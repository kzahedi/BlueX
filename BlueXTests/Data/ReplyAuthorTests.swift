// BlueXTests/Data/ReplyAuthorTests.swift
import XCTest
import SwiftData
@testable import BlueX

final class ReplyAuthorTests: XCTestCase {

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Post.self, Annotation.self, TrackedAccount.self, AccountGroup.self,
            ScrapeLog.self, CoordinatorState.self, AccountSnapshot.self, ModelConfig.self,
            ReplyAuthor.self, AuthorObservation.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    func testAuthorPersistsWithDefaults() throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let a = ReplyAuthor(did: "did:plc:abc",
                            firstSeenAt: Date(timeIntervalSince1970: 100),
                            lastSeenAt: Date(timeIntervalSince1970: 200))
        ctx.insert(a)
        try ctx.save()

        let fresh = ModelContext(container)
        let loaded = try XCTUnwrap(try fresh.fetch(FetchDescriptor<ReplyAuthor>()).first)
        XCTAssertEqual(loaded.did, "did:plc:abc")
        XCTAssertEqual(loaded.currentStatus, "unknown", "an unprobed author is unknown, not active")
        XCTAssertNil(loaded.lastProbedAt)
        XCTAssertNil(loaded.currentHandle)
        XCTAssertTrue(loaded.observations.isEmpty)
    }

    func testObservationAttachesAndCascades() throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let a = ReplyAuthor(did: "did:plc:abc", firstSeenAt: Date(), lastSeenAt: Date())
        ctx.insert(a)
        let o = AuthorObservation(observedAt: Date(timeIntervalSince1970: 500), status: "takedown")
        o.statusReason = "AccountTakedown"
        o.author = a
        ctx.insert(o)
        try ctx.save()

        let fresh = ModelContext(container)
        let loaded = try XCTUnwrap(try fresh.fetch(FetchDescriptor<ReplyAuthor>()).first)
        XCTAssertEqual(loaded.observations.count, 1)
        XCTAssertEqual(loaded.observations.first?.statusReason, "AccountTakedown")

        // deleting the author must remove its observations (cascade)
        let del = ModelContext(container)
        let target = try XCTUnwrap(try del.fetch(FetchDescriptor<ReplyAuthor>()).first)
        del.delete(target)
        try del.save()
        let after = ModelContext(container)
        XCTAssertEqual(try after.fetch(FetchDescriptor<AuthorObservation>()).count, 0)
    }

    // A gone account has no counts. Storing 0 would be a lie that silently
    // corrupts any average computed over the population.
    func testCountsAreNilNotZeroWhenAbsent() throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let o = AuthorObservation(observedAt: Date(), status: "deleted")
        ctx.insert(o)
        try ctx.save()
        let fresh = ModelContext(container)
        let loaded = try XCTUnwrap(try fresh.fetch(FetchDescriptor<AuthorObservation>()).first)
        XCTAssertNil(loaded.followersCount)
        XCTAssertNil(loaded.postsCount)
        XCTAssertNil(loaded.accountCreatedAt)
    }
}
