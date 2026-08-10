import Foundation

/// Rotation of the scrape queue so a long-running, frequently-interrupted pass
/// doesn't systematically starve whichever account sorts last alphabetically.
enum ScrapeOrder {
    /// Rotates `items` so element `startIndex` comes first, wrapping around.
    /// Returns `items` unchanged when it has fewer than two elements.
    ///
    /// `startIndex` is normalised with modulo, so negative values and values
    /// `>= items.count` are handled without trapping.
    static func rotated<T>(_ items: [T], startingAt startIndex: Int) -> [T] {
        let count = items.count
        guard count > 1 else { return items }

        let normalised = ((startIndex % count) + count) % count
        return Array(items[normalised...] + items[..<normalised])
    }
}
