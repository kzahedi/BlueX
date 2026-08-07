import XCTest
import SwiftData
@testable import BlueX

final class AuthorBackfillTests: XCTestCase {

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Post.self, Annotation.self, TrackedAccount.self, AccountGroup.self,
            ScrapeLog.self, CoordinatorState.self, AccountSnapshot.self, ModelConfig.self,
            ReplyAuthor.self, AuthorObservation.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    private func addReply(_ ctx: ModelContext, uri: String, did: String, at t: TimeInterval) {
        let p = Post(uri: uri, text: "hi", createdAt: Date(timeIntervalSince1970: t),
                     authorDID: did, authorHandle: "\(did).handle",
                     parentURI: "at://root", rootURI: "at://root",
                     isRootPost: false, depth: 1)
        ctx.insert(p)
    }

    func testCreatesOneAuthorPerDIDWithSeenRange() throws {
        let c = try makeContainer(); let ctx = ModelContext(c)
        addReply(ctx, uri: "at://1", did: "did:plc:a", at: 100)
        addReply(ctx, uri: "at://2", did: "did:plc:a", at: 300)
        addReply(ctx, uri: "at://3", did: "did:plc:b", at: 200)
        try ctx.save()

        let r = try AuthorBackfill(container: c).run(batchSize: 2)
        XCTAssertEqual(r.created, 2)

        let fresh = ModelContext(c)
        let authors = try fresh.fetch(FetchDescriptor<ReplyAuthor>()).sorted { $0.did < $1.did }
        XCTAssertEqual(authors.map(\.did), ["did:plc:a", "did:plc:b"])
        XCTAssertEqual(authors[0].firstSeenAt, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(authors[0].lastSeenAt, Date(timeIntervalSince1970: 300))
    }

    func testIgnoresRootPosts() throws {
        let c = try makeContainer(); let ctx = ModelContext(c)
        let root = Post(uri: "at://root", text: "news", createdAt: Date(),
                        authorDID: "did:plc:outlet", authorHandle: "nytimes.com",
                        parentURI: nil, rootURI: "at://root", isRootPost: true, depth: 0)
        ctx.insert(root)
        try ctx.save()
        let r = try AuthorBackfill(container: c).run()
        XCTAssertEqual(r.created, 0, "tracked outlets are not reply authors")
    }

    func testIsIdempotentAndExtendsRange() throws {
        let c = try makeContainer(); let ctx = ModelContext(c)
        addReply(ctx, uri: "at://1", did: "did:plc:a", at: 100)
        try ctx.save()
        _ = try AuthorBackfill(container: c).run()

        let ctx2 = ModelContext(c)
        addReply(ctx2, uri: "at://2", did: "did:plc:a", at: 400)
        try ctx2.save()
        let second = try AuthorBackfill(container: c).run()

        XCTAssertEqual(second.created, 0, "existing author must not be duplicated")
        XCTAssertEqual(second.updated, 1)
        let fresh = ModelContext(c)
        let authors = try fresh.fetch(FetchDescriptor<ReplyAuthor>())
        XCTAssertEqual(authors.count, 1)
        XCTAssertEqual(authors[0].lastSeenAt, Date(timeIntervalSince1970: 400))
    }
}
