// BlueX/ViewModels/AccountViewModel.swift
import Foundation
import Observation

/// Presets for the reply-count range filter on `AccountContentView`'s root-post list.
///
/// The bucket boundaries mirror the measured distribution of tree sizes in the corpus
/// (see task-7 brief): most replies live in the 10–49 and 50–99 bands, so those get their
/// own presets rather than forcing "1+" to stand in for both a quiet thread and a viral one.
///
/// `.custom` is the escape hatch for a user-typed min/max range (see
/// `AccountViewModel.minRepliesText`/`maxRepliesText`) — the view supplies both ends,
/// independently optional. An absent maximum must never become a silent cap: `bounds.max`
/// is `nil` for every preset except the one explicit range (`.fiftyToNinetyNine`).
enum ReplyCountPreset: String, CaseIterable, Identifiable {
    case any
    case oneOrMore
    case tenOrMore
    case fiftyToNinetyNine
    case fiftyOrMore
    case hundredOrMore
    case twoHundredOrMore
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .any:               return "Any size"
        case .oneOrMore:         return "1+ replies"
        case .tenOrMore:         return "10+ replies"
        case .fiftyToNinetyNine: return "50–99 replies"
        case .fiftyOrMore:       return "50+ replies"
        case .hundredOrMore:     return "100+ replies"
        case .twoHundredOrMore: return "200+ replies"
        case .custom:            return "Custom range"
        }
    }

    /// `(min, max)` reply-count bounds. `max == nil` means unbounded.
    var bounds: (min: Int?, max: Int?) {
        switch self {
        case .any:               return (nil, nil)
        case .oneOrMore:         return (1, nil)
        case .tenOrMore:         return (10, nil)
        case .fiftyToNinetyNine: return (50, 99)
        case .fiftyOrMore:       return (50, nil)
        case .hundredOrMore:     return (100, nil)
        case .twoHundredOrMore: return (200, nil)
        case .custom:            return (nil, nil)   // view supplies min/max text
        }
    }
}

@Observable
final class AccountViewModel {
    var searchText: String = ""
    var sortNewestFirst: Bool = true
    var isLoading: Bool = false

    // Reply-count range filter — applied in SQL via `AggregateReader.rootPosts`, never
    // in memory. See `replyCountBounds`.
    var replyCountPreset: ReplyCountPreset = .any

    /// Typed reply-count bounds. The view commits these on `.onSubmit`/focus-loss only —
    /// never per keystroke, since each change re-runs a ~2.8s SQL aggregate against the
    /// live store (see `AccountContentView.reload`). Both independently optional: an
    /// empty string means "no bound" in that direction, not zero.
    var minRepliesText: String = ""
    var maxRepliesText: String = ""

    /// The `(minReplies, maxReplies)` to pass to `AggregateReader.rootPosts`/
    /// `rootPostCount`. Pure and independently testable — this is the one place that
    /// decides what preset + typed text means as a SQL range.
    ///
    /// Non-numeric or negative text parses to `nil` (no bound in that direction) rather
    /// than crashing or defaulting to zero; `customRangeError` is what tells the view
    /// *that* the text didn't parse, or that the range is inverted, so it can withhold
    /// the query instead of firing one that provably returns nothing. This property
    /// itself never withholds — it always reflects what the text parses to.
    var replyCountBounds: (min: Int?, max: Int?) {
        if replyCountPreset == .custom {
            return (Self.parseNonNegativeInt(minRepliesText), Self.parseNonNegativeInt(maxRepliesText))
        }
        return replyCountPreset.bounds
    }

    /// Inline validation message for the typed min/max fields, or `nil` if it's safe to
    /// query. Non-nil for: non-numeric text, negative numbers, or `min > max` (a range
    /// that can only ever match zero rows — the view should show this message instead of
    /// firing that query).
    var customRangeError: String? {
        guard replyCountPreset == .custom else { return nil }
        let minTrimmed = minRepliesText.trimmingCharacters(in: .whitespacesAndNewlines)
        let maxTrimmed = maxRepliesText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !minTrimmed.isEmpty && Self.parseNonNegativeInt(minTrimmed) == nil {
            return "Min must be a whole number ≥ 0"
        }
        if !maxTrimmed.isEmpty && Self.parseNonNegativeInt(maxTrimmed) == nil {
            return "Max must be a whole number ≥ 0"
        }
        let min = Self.parseNonNegativeInt(minTrimmed)
        let max = Self.parseNonNegativeInt(maxTrimmed)
        if let min, let max, min > max {
            return "Min (\(min)) is greater than max (\(max))"
        }
        return nil
    }

    /// Empty/whitespace-only, non-numeric, or negative text all parse to `nil` — "no
    /// bound in this direction" for the query. `customRangeError` is the layer that
    /// distinguishes "empty on purpose" from "typed garbage" for the user.
    private static func parseNonNegativeInt(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let value = Int(trimmed), value >= 0 else { return nil }
        return value
    }

    /// Applies text search to a page of root posts already filtered by reply-count range
    /// in SQL, then sorts. Operates only on the (capped) page passed in — never the full
    /// account. No speech-class filter here: `ZANNOTATION` is empty for root posts right
    /// now, so there is nothing to classify by yet (see `ChartsViewModel.load`).
    func filteredRootPosts(_ rows: [RootPostSummary]) -> [RootPostSummary] {
        var result = rows

        if !searchText.isEmpty {
            result = result.filter { $0.text.localizedCaseInsensitiveContains(searchText) }
        }

        if sortNewestFirst {
            result.sort { $0.createdAt > $1.createdAt }
        } else {
            result.sort { $0.createdAt < $1.createdAt }
        }

        return result
    }
}
