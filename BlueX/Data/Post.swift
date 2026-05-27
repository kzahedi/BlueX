import Foundation
import SwiftData

// Why: An enum stored in SwiftData must be RawRepresentable with a primitive type (String)
// so SwiftData can persist it to SQLite. Codable is needed for transformable storage.
enum ReplyTreeStatus: String, Codable {
    case pending     // thread scrape not yet started
    case inProgress  // scrape started but interrupted mid-way
    case complete    // API returned empty cursor — no more replies
}

@Model
final class Post {
    var uri: String          // AT URI — unique dedup key
    var text: String
    var createdAt: Date
    var authorDID: String    // reply authors are NOT TrackedAccounts — they're the public
    var authorHandle: String

    var likeCount: Int
    var replyCount: Int
    var quoteCount: Int
    var repostCount: Int

    var parentURI: String?   // nil for root posts
    var rootURI: String      // always set; equals uri for root posts
    var isRootPost: Bool
    var depth: Int           // 0=root, 1=direct reply, 2+=nested

    var replyTreeStatus: ReplyTreeStatus
    var replyTreeLastChecked: Date?
    var needsReAnnotation: Bool  // set to true when model or prompt changes

    @Relationship(deleteRule: .cascade) var annotations: [Annotation]
    @Relationship(deleteRule: .nullify) var account: TrackedAccount?

    init(uri: String, text: String, createdAt: Date,
         authorDID: String, authorHandle: String,
         parentURI: String?, rootURI: String,
         isRootPost: Bool, depth: Int) {
        self.uri = uri
        self.text = text
        self.createdAt = createdAt
        self.authorDID = authorDID
        self.authorHandle = authorHandle
        self.parentURI = parentURI
        self.rootURI = rootURI
        self.isRootPost = isRootPost
        self.depth = depth
        self.likeCount = 0
        self.replyCount = 0
        self.quoteCount = 0
        self.repostCount = 0
        self.replyTreeStatus = .pending
        self.replyTreeLastChecked = nil
        self.needsReAnnotation = false
        self.annotations = []
    }
}
