// BlueX/Views/ChartAxisFormatting.swift
import Foundation

/// Shared axis tick/label logic for date-based charts.
///
/// A fixed tick stride (e.g. "every 2 weeks") cannot work across BlueX's actual range of
/// chart spans: a brand-new author has a couple of weeks of data, while a long-lived one's
/// corpus runs 2018–2026 — roughly 450 weeks. A fixed stride is either invisible (nothing to
/// show yet) or smears a hundred overlapping labels together. This picks a label granularity
/// from the data's actual span instead, and callers pair it with
/// `AxisMarks(values: .automatic(desiredCount:))` so Swift Charts also chooses tick
/// *positions* appropriate to that span rather than a hardcoded calendar component.
enum ChartAxisFormatting {
    /// Ticks to aim for. `.automatic(desiredCount:)` snaps to the nearest calendar-nice
    /// stride (day/week/month/year) around this count; 6 reads cleanly at the width these
    /// charts render at without crowding.
    static let desiredTickCount = 6

    /// Below this span, individual days are still a meaningful read; at or above it, a
    /// day-level label is noise and the axis should collapse to month+year.
    static let shortSpanThresholdDays = 120

    /// Whole days between the earliest and latest date in `dates`. Returns 0 for an empty
    /// or single-element input — a brand-new author with one data point has no span, not an
    /// undefined one.
    static func spanDays(_ dates: [Date], calendar: Calendar = .current) -> Int {
        guard let first = dates.min(), let last = dates.max() else { return 0 }
        return calendar.dateComponents([.day], from: first, to: last).day ?? 0
    }

    /// Label format appropriate to `spanDays`: day+month for a short span, month+year once
    /// the range is long enough that individual days would just add noise.
    static func dateFormat(spanDays: Int) -> Date.FormatStyle {
        spanDays < shortSpanThresholdDays
            ? .dateTime.month(.abbreviated).day()
            : .dateTime.month(.abbreviated).year(.twoDigits)
    }
}
