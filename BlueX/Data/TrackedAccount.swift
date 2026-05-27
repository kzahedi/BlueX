import Foundation
import SwiftData

// Why: @Model is SwiftData's replacement for @NSManagedObject (CoreData).
// The macro generates all persistence boilerplate at compile time.
// You write plain Swift classes; SwiftData handles the underlying SQLite.
@Model
final class TrackedAccount {
    var did: String
    var handle: String
    var displayName: String
    var avatarURL: String?
    var startAt: Date
    var isActive: Bool

    // Why: @Relationship(deleteRule: .cascade) means when a TrackedAccount is deleted,
    // all its posts and snapshots are deleted too (like ON DELETE CASCADE in SQL).
    @Relationship(deleteRule: .cascade) var posts: [Post]
    @Relationship(deleteRule: .cascade) var snapshots: [AccountSnapshot]
    // Why: .nullify means when the account is deleted, the groups are NOT deleted —
    // only the reference from account→group is cleared.
    // inverse: wires the bidirectional M:N so appending to groups auto-updates group.accounts.
    @Relationship(deleteRule: .nullify, inverse: \AccountGroup.accounts) var groups: [AccountGroup]

    init(did: String, handle: String, displayName: String,
         startAt: Date, isActive: Bool = true, avatarURL: String? = nil) {
        self.did = did
        self.handle = handle
        self.displayName = displayName
        self.startAt = startAt
        self.isActive = isActive
        self.avatarURL = avatarURL
        self.posts = []
        self.snapshots = []
        self.groups = []
    }
}
