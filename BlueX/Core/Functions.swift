//
//  Functions.swift
//  Bluesent
//
//  Created by Keyan Ghazi-Zahedi on 26.12.24.
//

import Foundation

func prettyPrintJSON(data: Data) {
    if let jsonObject = try? JSONSerialization.jsonObject(with: data),
       let prettyData = try? JSONSerialization.data(withJSONObject: jsonObject, options: .prettyPrinted),
       let prettyString = String(data: prettyData, encoding: .utf8) {
        print("Raw Response:\n\(prettyString)")
    }
}

func convertToDate(from isoString: String) -> Date? {
    let isoFormatter = ISO8601DateFormatter()
    isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    isoFormatter.timeZone = TimeZone(secondsFromGMT: 0)

    let normalizedString = isoString.trimmingCharacters(in: .whitespacesAndNewlines)

    // Attempt ISO8601 parsing
    if let date = isoFormatter.date(from: normalizedString) {
        return date
    }

    // Fallback to manual DateFormatter
    let fallbackFormatter = DateFormatter()
    fallbackFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
    fallbackFormatter.locale = Locale(identifier: "en_US_POSIX")
    fallbackFormatter.timeZone = TimeZone(secondsFromGMT: 0)

    return fallbackFormatter.date(from: normalizedString)
}

