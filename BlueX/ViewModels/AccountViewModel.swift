// BlueX/ViewModels/AccountViewModel.swift
import Foundation
import Observation

/// Presets for the reply-count range filter on `AccountContentView`'s root-post list.
///
/// The bucket boundaries mirror the measured distribution of tree sizes in the corpus
/// (see task-7 brief): most replies live in the 10–49 and 50–99 bands, so those get their
/// own presets rather than forcing "1+" to stand in for both a quiet thread and a viral one.
///
/// `.custom` is the escape hatch for "more than N" with no upper bound — the view supplies
/// a user-entered minimum. An absent maximum must never become a silent cap: `bounds.max`
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
        case .custom:            return "More than…"
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
        case .custom:            return (nil, nil)   // view supplies the minimum
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
    var customMinReplies: Int = 50

    /// The `(minReplies, maxReplies)` to pass to `AggregateReader.rootPosts`/
    /// `rootPostCount`. Pure and independently testable — this is the one place that
    /// decides what preset + custom value means as a SQL range.
    var replyCountBounds: (min: Int?, max: Int?) {
        if replyCountPreset == .custom {
            return (max(0, customMinReplies), nil)
        }
        return replyCountPreset.bounds
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
