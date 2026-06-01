import Foundation
import SwiftData

@Model
final class AccountSnapshot {
    var timestamp: Date
    // From app.bsky.actor.getProfile
    var followerCount: Int
    var followingCount: Int
    var postCount: Int
    // Computed from local store at snapshot time
    var totalLikes: Int
    var totalReplies: Int
    var totalReposts: Int
    var totalQuotes: Int
    @Relationship(deleteRule: .nullify) var account: TrackedAccount?

    init(timestamp: Date, followerCount: Int, followingCount: Int, postCount: Int,
         totalLikes: Int = 0, totalReplies: Int = 0,
         totalReposts: Int = 0, totalQuotes: Int = 0) {
        self.timestamp = timestamp
        self.followerCount = followerCount
        self.followingCount = followingCount
        self.postCount = postCount
        self.totalLikes = totalLikes
        self.totalReplies = totalReplies
        self.totalReposts = totalReposts
        self.totalQuotes = totalQuotes
    }
}
