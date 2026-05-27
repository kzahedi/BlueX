import Foundation
import SwiftData

@Model
final class ScrapeLog {
    var date: Date
    var type: String            // "feed" | "thread"
    var status: String          // "complete" | "failed"
    var postCount: Int
    var resumeCursor: String?   // Bluesky pagination cursor — non-nil if interrupted mid-page
    @Relationship(deleteRule: .nullify) var account: TrackedAccount?

    init(date: Date, type: String, status: String, postCount: Int, resumeCursor: String? = nil) {
        self.date = date
        self.type = type
        self.status = status
        self.postCount = postCount
        self.resumeCursor = resumeCursor
    }
}
