//
//  StringExtensions.swift
//  BlueX
//
//  Created by Keyan Ghazi-Zahedi on 20.01.25.
//

import Foundation

extension String {
    func replacingTimeWithEndOfDay() -> String {
        let regex = try! NSRegularExpression(pattern: #"\d{2}:\d{2}:\d{2}"#)
        return regex.stringByReplacingMatches(in: self, range: NSRange(self.startIndex..., in: self), withTemplate: "23:59:59")
    }
}
