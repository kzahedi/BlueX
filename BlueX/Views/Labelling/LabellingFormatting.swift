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

    /// "N/M labelled" — progress within a batch, independent of pass number.
    static func batchProgressSummary(labelled: Int, drawn: Int) -> String {
        "\(labelled)/\(drawn) labelled"
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
}
