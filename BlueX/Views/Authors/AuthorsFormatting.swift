// BlueX/Views/Authors/AuthorsFormatting.swift
import Foundation

/// Pure text/formatting helpers for the reply-author dashboard, pulled out of the SwiftUI
/// views so the three honesty labels (display cap, outlet overlap, status-not-collected)
/// have exact, testable wording rather than being retyped inline in views that only
/// XCTest-via-inspection can reach.
struct AuthorsFormatting {
    /// "Showing N of M matching authors" — a cap that hides how much it hides
    /// misrepresents coverage, so this is always shown next to the capped list.
    static func matchingSummary(shown: Int, total: Int) -> String {
        "Showing \(shown) of \(total) matching authors"
    }

    /// `PopulationStats.statusCounts` is empty until the profile probe runs against
    /// `ZREPLYAUTHOR`. An empty dictionary must not be rendered as a zeroed bar chart —
    /// that would read as "no takedowns", which is false; it means "not measured".
    static func statusIsCollected(_ counts: [String: Int]) -> Bool {
        !counts.isEmpty
    }

    /// Deliberately spells out "not measured, not zero": a separate label sweep of this
    /// corpus already found 1,777 accounts carrying `!takedown` and 4,946 carrying
    /// `!suspend`, so an empty chart here must never be mistaken for "no takedowns
    /// found" — that would flatly contradict data that already exists elsewhere.
    static let statusNotCollectedMessage =
        "Account status not yet collected — this means \"not measured,\" not \"zero.\" " +
        "The profile probe that would surface takedowns or suspensions has not run yet."

    /// Authors are counted once per outlet they reply to, so per-outlet author counts sum
    /// above the population total. That overlap is the cross-outlet signal, not a bug.
    static func outletOverlapNote(totalAuthors: Int) -> String {
        "Authors are counted once per outlet they reply to, so these sum above \(totalAuthors)."
    }

    /// One outlet dominates the corpus while the backfill is incomplete, so cross-outlet
    /// differences are not yet a finding.
    static let confoundedOutletNote =
        "Outlet comparison is confounded: the corpus is dominated by a single outlet " +
        "until the remaining accounts are fully scraped."

    /// Per-author status is not modelled at all yet (no per-author status field exists),
    /// so the detail pane states the same fact rather than fabricating a per-row value.
    static let perAuthorStatusNotCollectedMessage =
        "Status: not yet collected — requires the profile probe."

    /// Sorted for a stable, deterministic display order.
    static func sortedStatusRows(_ counts: [String: Int]) -> [(status: String, count: Int)] {
        counts.sorted { $0.key < $1.key }.map { (status: $0.key, count: $0.value) }
    }

    /// The handle-missing note shown in place of a blank field — never render an empty
    /// handle silently, since that reads as "no handle exists" rather than "not probed".
    static let handleNotCollectedMessage = "Handle requires the profile probe."

    /// Caption under the most-recent-reply handle in the author detail pane. This handle
    /// comes from `ZPOST.ZAUTHORHANDLE` on the author's newest reply, not from a profile
    /// probe — it is honest about *when* it was observed, never implying it is current.
    static let mostRecentHandleCaption = "Handle at time of most recent reply — not necessarily current."

    /// "N handles seen" — shown only when an author's replies carry more than one
    /// distinct handle. A handle change across the corpus is itself an evasion signal,
    /// not noise, so it is surfaced rather than silently collapsed to the latest handle.
    static func multipleHandlesNote(_ handles: [String]) -> String {
        "\(handles.count) handles seen: \(handles.joined(separator: ", "))"
    }

    /// "Showing N of M replies" — the same honesty pattern as `matchingSummary`, applied
    /// to the per-author reply list's display cap.
    static func repliesShownSummary(shown: Int, total: Int) -> String {
        "Showing \(shown) of \(total) replies"
    }
}
