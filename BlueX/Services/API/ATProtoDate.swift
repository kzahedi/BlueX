import Foundation

// AT Protocol timestamps are ISO8601 and usually carry fractional seconds
// ("2024-06-01T10:00:00.000Z"), but some records omit them ("2024-06-01T10:00:00Z").
// ISO8601DateFormatter only parses one shape per `formatOptions`, so we keep a
// configured instance for each and try the common case first. The instances are
// shared because constructing an ISO8601DateFormatter is expensive and the
// scrapers parse a timestamp for every post.
enum ATProtoDate {
    private static let withFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let withoutFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// Parses an AT Protocol timestamp, tolerating both fractional and whole-second forms.
    static func parse(_ string: String) -> Date? {
        withFractionalSeconds.date(from: string) ?? withoutFractionalSeconds.date(from: string)
    }
}
