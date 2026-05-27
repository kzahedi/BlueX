import Foundation

// MARK: - Auth

struct ATProtoSession: Codable {
    let did: String
    let handle: String
    let accessJwt: String
    let refreshJwt: String
}

// MARK: - DID Resolution

struct ATProtoProfile: Codable {
    let did: String
    let handle: String
    let displayName: String?
    let avatar: String?
    let followersCount: Int?
    let followsCount: Int?
    let postsCount: Int?
}

// MARK: - Feed

struct ATProtoFeedResponse: Codable {
    let feed: [ATProtoFeedViewPost]
    let cursor: String?
}

struct ATProtoFeedViewPost: Codable {
    let post: ATProtoPost
}

struct ATProtoPost: Codable {
    let uri: String
    let cid: String
    let author: ATProtoAuthor
    let record: ATProtoRecord
    let likeCount: Int?
    let replyCount: Int?
    let quoteCount: Int?
    let repostCount: Int?
    let indexedAt: String  // ISO 8601
}

struct ATProtoAuthor: Codable {
    let did: String
    let handle: String
    let displayName: String?
    let avatar: String?
}

struct ATProtoRecord: Codable {
    let text: String
    let createdAt: String  // ISO 8601
    let reply: ATProtoReplyRef?
}

struct ATProtoReplyRef: Codable {
    let parent: ATProtoStrongRef
    let root: ATProtoStrongRef
}

struct ATProtoStrongRef: Codable {
    let uri: String
    let cid: String
}

// MARK: - Thread

struct ATProtoThreadResponse: Codable {
    let thread: ATProtoThreadView
}

// Why: 'indirect' allows a recursive enum — ATProtoThreadView contains [ATProtoThreadView]
// as replies. Swift needs 'indirect' to break the value-type cycle (otherwise the size
// would be infinite at compile time).
indirect enum ATProtoThreadView: Codable {
    case post(ATProtoThreadPost)
    case notFound
    case blocked

    // Why: Bluesky uses a "$type" discriminator field to identify the variant.
    // We read it first, then decode the full struct for the matching case.
    private enum CodingKeys: String, CodingKey {
        case type = "$type"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type_ = try container.decode(String.self, forKey: .type)
        switch type_ {
        case "app.bsky.feed.defs#threadViewPost":
            let post = try ATProtoThreadPost(from: decoder)
            self = .post(post)
        case "app.bsky.feed.defs#notFoundPost":
            self = .notFound
        default:
            self = .blocked
        }
    }

    func encode(to encoder: Encoder) throws {
        // Read-only client — encode not needed
    }
}

struct ATProtoThreadPost: Codable {
    let post: ATProtoPost
    let replies: [ATProtoThreadView]?
}
