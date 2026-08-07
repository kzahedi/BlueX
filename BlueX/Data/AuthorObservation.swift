// BlueX/Data/AuthorObservation.swift
import Foundation
import SwiftData

/// One point-in-time record of an account's public state. Immutable once written.
///
/// Written ONLY when something material changed (see `AuthorProbeRunner`). Snapshotting
/// every author every sweep would be ~146k × 52 ≈ 7.6M rows a year, ~99% identical to
/// the row before. Counts deliberately do not count as "material": follower numbers
/// drift continuously, so including them would write the whole population every week.
@Model
final class AuthorObservation {
    var observedAt: Date
    var status: String
    /// The raw API error code when not active — e.g. "AccountTakedown". Kept raw rather
    /// than normalised so an unfamiliar future code is preserved rather than discarded.
    var statusReason: String?

    var handle: String?
    var displayName: String?
    var profileDescription: String?
    /// When the ACCOUNT was created, from the profile. Enables "account age at time of
    /// reply" — the throwaway-account signature.
    var accountCreatedAt: Date?

    // Optional, not defaulted to 0: a gone account has no counts and 0 would be a lie.
    var followersCount: Int?
    var followsCount: Int?
    var postsCount: Int?

    /// Bluesky's own moderation labels, comma-joined. Empty string means "observed, none";
    /// nil means "not observed". That distinction matters when counting labelled accounts.
    var labels: String?
    var hasAvatar: Bool

    @Relationship(deleteRule: .nullify) var author: ReplyAuthor?

    init(observedAt: Date, status: String) {
        self.observedAt = observedAt
        self.status = status
        self.hasAvatar = false
    }
}
