import Foundation
import SwiftData

/// Creates one `ReplyAuthor` per distinct reply-author DID, and keeps `firstSeenAt` /
/// `lastSeenAt` current as the corpus grows.
///
/// The fold is done in SQL. The previous implementation paged `Post` through SwiftData
/// with `sortBy: [SortDescriptor(\Post.uri)]`, which re-sorted ~892k unindexed strings
/// on every page: measured 1.9–4.8s per page across ~1,786 pages, and a live run reached
/// 2h44m without writing a row. The equivalent GROUP BY takes 0.50s.
///
/// Writes still go through SwiftData, because that is what the app reads.
struct AuthorBackfill {
    private let container: ModelContainer
    private let reader: AggregateReader

    init(container: ModelContainer, reader: AggregateReader) {
        self.container = container
        self.reader = reader
    }

    /// - Parameter progress: called as `(authorsWritten, authorsTotal)`. A job that can
    ///   run for minutes must report, so it is never mistaken for a hang.
    @discardableResult
    func run(batchSize: Int = 5_000,
             progress: ((Int, Int) -> Void)? = nil) throws -> (created: Int, updated: Int) {
        let ranges = try reader.authorSeenRanges()
        let total = ranges.count

        let write = ModelContext(container)
        let existing = try write.fetch(FetchDescriptor<ReplyAuthor>())
        var byDID = Dictionary(uniqueKeysWithValues: existing.map { ($0.did, $0) })

        var created = 0, updated = 0, done = 0
        for entry in ranges {
            let did = entry.did
            if let a = byDID[did] {
                let newFirst = min(a.firstSeenAt, entry.first)
                let newLast = max(a.lastSeenAt, entry.last)
                if newFirst != a.firstSeenAt || newLast != a.lastSeenAt {
                    a.firstSeenAt = newFirst
                    a.lastSeenAt = newLast
                    updated += 1
                }
            } else {
                let a = ReplyAuthor(did: did, firstSeenAt: entry.first, lastSeenAt: entry.last)
                write.insert(a)
                byDID[did] = a
                created += 1
            }
            done += 1
            // Save in batches so the transaction never grows to hundreds of thousands of
            // pending inserts, and so progress is visible before the whole job finishes.
            if done % batchSize == 0 {
                try write.save()
                progress?(done, total)
            }
        }
        try write.save()
        progress?(done, total)
        return (created, updated)
    }
}
