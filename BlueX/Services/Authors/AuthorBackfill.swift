import Foundation
import SwiftData

/// Creates one `ReplyAuthor` per distinct reply-author DID, and keeps `firstSeenAt` /
/// `lastSeenAt` current as the corpus grows.
///
/// Pages over `Post` with a fresh `ModelContext` per page. The store holds ~842k reply
/// rows; a single long-lived context would register all of them and exhaust memory —
/// the same failure that made the original NLTagger pass unable to finish a backfill.
struct AuthorBackfill {
    private let container: ModelContainer

    init(container: ModelContainer) { self.container = container }

    @discardableResult
    func run(batchSize: Int = 500) throws -> (created: Int, updated: Int) {
        // A throwaway context solely to size the paging loop below — fetchCount avoids
        // materializing any Post objects, unlike a full fetch().
        let countCtx = ModelContext(container)

        // Fold the corpus down to one row per DID before touching the store.
        var seen: [String: (first: Date, last: Date)] = [:]
        let total = try countCtx.fetchCount(FetchDescriptor<Post>())
        var offset = 0
        while offset < total {
            let ctx = ModelContext(container)
            var page = FetchDescriptor<Post>(sortBy: [SortDescriptor(\Post.uri)])
            page.fetchOffset = offset
            page.fetchLimit = batchSize
            let posts = try ctx.fetch(page)
            if posts.isEmpty { break }
            offset += posts.count
            for p in posts where !p.isRootPost {
                let d = p.authorDID
                if let cur = seen[d] {
                    seen[d] = (min(cur.first, p.createdAt), max(cur.last, p.createdAt))
                } else {
                    seen[d] = (p.createdAt, p.createdAt)
                }
            }
        }

        var created = 0, updated = 0
        let write = ModelContext(container)
        let existing = try write.fetch(FetchDescriptor<ReplyAuthor>())
        var byDID = Dictionary(uniqueKeysWithValues: existing.map { ($0.did, $0) })

        for (did, range) in seen {
            if let a = byDID[did] {
                let newFirst = min(a.firstSeenAt, range.first)
                let newLast = max(a.lastSeenAt, range.last)
                if newFirst != a.firstSeenAt || newLast != a.lastSeenAt {
                    a.firstSeenAt = newFirst
                    a.lastSeenAt = newLast
                    updated += 1
                }
            } else {
                let a = ReplyAuthor(did: did, firstSeenAt: range.first, lastSeenAt: range.last)
                write.insert(a)
                byDID[did] = a
                created += 1
            }
        }
        try write.save()
        return (created, updated)
    }
}
