import Foundation

/// Caps how many points a chart draws.
///
/// This is *not* what fixed the app's slowness — that was moving aggregation into SQL
/// (Tasks 7a/7b), which removed a ~2.15 million-object materialisation per account click.
/// Weekly account buckets are 12–450 points and are deliberately left undecimated here.
/// Decimation exists for the series that genuinely get large: per-author timelines
/// spanning 2018→2026, and population distributions in the forthcoming dashboard.
enum Decimator {
    /// Evenly samples `items` down to at most `maxPoints`, always keeping the first and
    /// last elements so the visible range still matches the data's true range.
    ///
    /// Dropping either end would silently move the chart's visible date range, which
    /// misrepresents the data rather than merely simplifying its rendering — so both
    /// endpoints are always preserved for any `maxPoints >= 2`.
    ///
    /// - Empty input, single-element input, and inputs no longer than `maxPoints` are
    ///   returned unchanged.
    /// - `maxPoints < 2` cannot preserve both endpoints, so the input is passed through
    ///   unchanged rather than trapping.
    static func downsample<T>(_ items: [T], to maxPoints: Int) -> [T] {
        guard maxPoints >= 2, items.count > maxPoints else { return items }

        var out: [T] = [items[0]]
        // Distribute the interior samples across the gap between the fixed endpoints.
        let interior = maxPoints - 2
        if interior > 0 {
            let step = Double(items.count - 2) / Double(interior + 1)
            for i in 1...interior {
                let index = Int((Double(i) * step).rounded())
                out.append(items[min(max(index, 1), items.count - 2)])
            }
        }
        out.append(items[items.count - 1])
        return out
    }
}
