import Foundation
import SwiftData

@Model
final class AccountSnapshot {
    var timestamp: Date
    var followerCount: Int
    var followingCount: Int
    var postCount: Int
    @Relationship(deleteRule: .nullify) var account: TrackedAccount?

    init(timestamp: Date, followerCount: Int, followingCount: Int, postCount: Int) {
        self.timestamp = timestamp
        self.followerCount = followerCount
        self.followingCount = followingCount
        self.postCount = postCount
    }
}
