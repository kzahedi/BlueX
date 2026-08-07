// BlueX/Data/ReplyAuthor.swift
import Foundation
import SwiftData

/// A person who replied to a tracked account. Distinct from `TrackedAccount`, which
/// models the six curated news outlets: these are ~146k members of the public with a
/// completely different lifecycle, so they get their own entity rather than a flag.
///
/// Keyed on DID, never handle. The corpus contains 146,422 distinct DIDs but only
/// 146,336 distinct handles — handles are changed and reused, so a handle-keyed identity
/// would silently merge different people.
///
/// There is deliberately NO relationship from `Post` to here. Adding one would mean
/// SwiftData rewriting all 842,369 reply rows in a migration to gain what a join on
/// `authorDID` already provides.
@Model
final class ReplyAuthor {
    var did: String
    /// Earliest and latest reply by this DID *in our corpus* — not the account's real
    /// lifespan, which comes from the profile's `accountCreatedAt`.
    var firstSeenAt: Date
    var lastSeenAt: Date

    /// Caches of the newest observation, so "which authors are still active?" needs no
    /// join. Derived, never authoritative — `observations` is the record.
    var currentHandle: String?
    var currentStatus: String
    var lastProbedAt: Date?

    @Relationship(deleteRule: .cascade, inverse: \AuthorObservation.author)
    var observations: [AuthorObservation]

    init(did: String, firstSeenAt: Date, lastSeenAt: Date) {
        self.did = did
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
        self.currentHandle = nil
        self.currentStatus = AuthorStatus.unknown.rawValue
        self.lastProbedAt = nil
        self.observations = []
    }
}

/// The states an account can be observed in. Stored as `rawValue` strings because
/// SwiftData persists enums only via RawRepresentable, and strings keep the store
/// readable from `sqlite3` during analysis.
enum AuthorStatus: String {
    case active
    case takedown        // AccountTakedown — a moderator actioned this account
    case deactivated     // AccountDeactivated — the user did; reversible
    case deleted         // DID no longer resolves
    case unknown         // absent from a batch but unclassifiable; NOT evidence of removal
}
