import Foundation

struct AuthorSummary: Identifiable, Hashable {
    var id: String { did }
    let did: String
    /// nil until the account probe runs — the backfill records identity, not profile.
    let handle: String?
    let replyCount: Int
    let firstSeen: Date
    let lastSeen: Date
    let outletCount: Int

    var spanDays: Int {
        max(0, Calendar(identifier: .iso8601)
            .dateComponents([.day], from: firstSeen, to: lastSeen).day ?? 0)
    }
}

struct WeekCount: Identifiable, Hashable {
    var id: Date { weekStart }
    let weekStart: Date
    let count: Int
}

struct RootPostSummary: Identifiable, Hashable {
    var id: String { uri }
    let uri: String
    let text: String
    let createdAt: Date
    let replyCount: Int
}

struct OutletCount: Identifiable, Hashable {
    var id: Int64 { accountPK }
    let accountPK: Int64
    let handle: String
    let authors: Int
    let replies: Int
}

struct HistogramBin: Identifiable, Hashable {
    var id: String { label }
    let label: String
    let lowerBound: Int
    /// nil means unbounded — the top bin.
    let upperBound: Int?
    let authors: Int
}

struct PopulationStats {
    let totalAuthors: Int
    let totalReplies: Int
    let medianRepliesPerAuthor: Int
    let activeLast30Days: Int
    let bins: [HistogramBin]
    let outlets: [OutletCount]
    /// Reads entirely "unknown" until the probe subsystem ships.
    let statusCounts: [String: Int]

    static let empty = PopulationStats(
        totalAuthors: 0, totalReplies: 0, medianRepliesPerAuthor: 0,
        activeLast30Days: 0, bins: [], outlets: [], statusCounts: [:]
    )
}

enum AuthorSort: String, CaseIterable, Identifiable {
    case replyCount, firstSeen, lastSeen, spanDays, did
    var id: String { rawValue }

    var label: String {
        switch self {
        case .replyCount: return "Replies"
        case .firstSeen:  return "First seen"
        case .lastSeen:   return "Last seen"
        case .spanDays:   return "Span"
        case .did:        return "DID"
        }
    }

    /// The ORDER BY fragment. Kept beside the enum so a new case cannot be added
    /// without deciding how it sorts.
    var orderBy: String {
        switch self {
        case .replyCount: return "reply_count DESC"
        case .firstSeen:  return "first_seen ASC"
        case .lastSeen:   return "last_seen DESC"
        case .spanDays:   return "(last_seen - first_seen) DESC"
        case .did:        return "did ASC"
        }
    }
}
