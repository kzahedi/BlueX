import Foundation

/// Pure text/formatting + frame-construction helpers for the labelling tab, pulled out
/// of the SwiftUI views so wording (especially the agreement string's "intra-rater"
/// qualifier — see `AgreementReport`'s own doc comment on why that word may never be
/// dropped) is exact and testable rather than retyped inline in views only reachable
/// via inspection.
enum LabellingFormatting {

    // MARK: - Frame

    /// One line describing a `SamplingFrame` for the batch list — "uniform random"
    /// stated plainly when it is, since that is the Stage-0 default and must never be
    /// buried under a description of "no filters set". A filtered frame instead lists
    /// exactly which of its optional fields are actually set.
    static func frameSummary(_ frame: SamplingFrame?) -> String {
        guard let frame else { return "unknown frame (failed to decode)" }
        guard frame.kind == .filtered else { return "uniform random" }

        var parts: [String] = []
        if let outletPK = frame.outletPK { parts.append("outlet #\(outletPK)") }
        if frame.dateFrom != nil || frame.dateTo != nil {
            parts.append(dateRangeDescription(from: frame.dateFrom, to: frame.dateTo))
        }
        if frame.minThreadReplies != nil || frame.maxThreadReplies != nil {
            parts.append(threadSizeDescription(min: frame.minThreadReplies, max: frame.maxThreadReplies))
        }
        guard !parts.isEmpty else { return "filtered (no filters set)" }
        return "filtered: " + parts.joined(separator: ", ")
    }

    private static let dateFormat = Date.FormatStyle(date: .abbreviated, time: .omitted)

    private static func dateRangeDescription(from: Date?, to: Date?) -> String {
        switch (from, to) {
        case let (from?, to?): return "\(from.formatted(dateFormat))–\(to.formatted(dateFormat))"
        case let (from?, nil): return "from \(from.formatted(dateFormat))"
        case let (nil, to?): return "until \(to.formatted(dateFormat))"
        case (nil, nil): return ""
        }
    }

    private static func threadSizeDescription(min: Int?, max: Int?) -> String {
        switch (min, max) {
        case let (min?, max?): return "\(min)–\(max) replies/thread"
        case let (min?, nil): return "≥\(min) replies/thread"
        case let (nil, max?): return "≤\(max) replies/thread"
        case (nil, nil): return ""
        }
    }

    /// Builds the `SamplingFrame` the create-batch button submits, from the pool
    /// builder's draft inputs. `outletPK` is resolved by the caller (an async DID→PK
    /// lookup) before this is called — this function itself does no I/O.
    static func buildFrame(uniformRandom: Bool, outletPK: Int64?, dateFrom: Date?, dateTo: Date?,
                           minThreadReplies: Int?, maxThreadReplies: Int?) -> SamplingFrame {
        guard !uniformRandom else { return .uniformRandom }
        return SamplingFrame(kind: .filtered, outletPK: outletPK, dateFrom: dateFrom, dateTo: dateTo,
                             minThreadReplies: minThreadReplies, maxThreadReplies: maxThreadReplies)
    }

    /// Parses an optional non-negative integer from a text field, treating blank or
    /// unparseable text as "not set" rather than as zero — a min/max thread-size field
    /// left empty must not silently become `>= 0`, which would match everything anyway
    /// but for the wrong (accidental) reason.
    static func parseOptionalInt(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let value = Int(trimmed), value >= 0 else { return nil }
        return value
    }

    /// Batch size defaults to 100 (per the brief) whenever the field is blank, zero, or
    /// unparseable — never zero, which would silently draw an empty batch.
    static func parseBatchSize(_ text: String, default defaultValue: Int = 100) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let value = Int(trimmed), value > 0 else { return defaultValue }
        return value
    }

    // MARK: - Batch list

    /// "N labelled · M skipped · K remaining" — progress within a batch, independent
    /// of pass number. Skipped items are never folded into "labelled": a skip is a
    /// deliberate non-decision, not a completed label, and the three counts always
    /// reconcile to `drawn` so nothing about the batch's state is hidden.
    static func batchProgressSummary(labelled: Int, skipped: Int, drawn: Int) -> String {
        let remaining = max(0, drawn - labelled - skipped)
        return "\(labelled) labelled · \(skipped) skipped · \(remaining) remaining"
    }

    static func passLabel(_ passNumber: Int) -> String {
        "Pass \(passNumber)"
    }

    // MARK: - Agreement

    /// The agreement display string. Must always say "intra-rater" — this is one
    /// annotator's agreement with themselves across two passes over the same posts,
    /// not inter-rater agreement, and dropping the qualifier would overclaim what the
    /// figure actually measures (see `AgreementReport`'s doc comment).
    static func agreementSummary(_ report: AgreementReport) -> String {
        let percent = Int((report.percentAgreement * 100).rounded())
        let kappa = String(format: "%.2f", report.cohensKappa)
        return "n=\(report.n) · \(percent)% agreement · intra-rater κ = \(kappa)"
    }

    // MARK: - Session

    /// "Item k of n" — 1-indexed for display even though `currentIndex` is 0-indexed.
    static func sessionProgressSummary(index: Int, total: Int) -> String {
        "Item \(min(index + 1, max(total, 1))) of \(total)"
    }

    /// mm:ss elapsed, for the session header. Caps display at 99:59 rather than
    /// overflowing into hours — a labelling session should never realistically run that
    /// long, and a garbled string is worse than a capped one.
    static func elapsedSummary(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let minutes = min(99, total / 60)
        let secs = total % 60
        return String(format: "%02d:%02d", minutes, secs)
    }

    /// Whether a class/skip keypress (or its mouse-button equivalent) is allowed to act
    /// right now, given the current `recordError`.
    ///
    /// **Why this exists.** `.saveFailed`/`.batchNotFound` mean the current item's label
    /// was NOT persisted and the item is deliberately left current so the annotator can
    /// retry — that guarantee is worthless if a stray "0" keypress can advance past the
    /// stuck item anyway, silently abandoning the unsaved label (the swallowed-save bug
    /// reborn as a UI path). So while either of those is active: `1`/`2`/`3` (retry) stay
    /// permitted, but `0` (skip) is denied — the only way to move on is an explicit,
    /// labelled "skip anyway" affordance the view offers separately, never a bare
    /// keystroke or the ordinary skip button.
    ///
    /// `.postNotFound` is transient and non-blocking (the session has already advanced
    /// past that item) and `nil` means there is nothing to block on — both permit every
    /// key.
    static func keyIsPermitted(_ key: String, recordError: LabellingViewModel.RecordFailure?) -> Bool {
        switch recordError {
        case .saveFailed, .batchNotFound:
            return key != "0"
        case nil, .postNotFound:
            return true
        }
    }

    // MARK: - Text scale

    /// Reading thousands of short posts is the whole job in a labelling session, so the
    /// post text is scalable (⌘+/⌘−/⌘0) and the choice persists. Clamped: below ~0.8
    /// the text stops being readable, above ~2.5 a single reply no longer fits the card
    /// without scrolling, which slows labelling more than large text speeds it up.
    static let minTextScale = 0.8
    static let maxTextScale = 2.5
    static let textScaleStep = 0.1

    /// Clamps a requested scale into the supported range. A non-finite or non-positive
    /// stored value (a corrupted preference) falls back to 1.0 rather than rendering
    /// invisible or absurd text.
    static func clampedTextScale(_ requested: Double) -> Double {
        guard requested.isFinite, requested > 0 else { return 1.0 }
        return min(max(requested, minTextScale), maxTextScale)
    }

}
