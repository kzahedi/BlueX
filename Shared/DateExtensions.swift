//
//  DateExtensions.swift
//  BlueX
//
//  Created by Keyan Ghazi-Zahedi on 18.01.25.
//
import Foundation

extension Date {
    
    func toStartOfDay() -> Date {
        let calendar = Calendar.current
        
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: self)
        
        components.minute = 0
        components.second = 0
        components.hour = 0
        
        return calendar.date(from: components)!
    }
    
    func toEndOfDay() -> Date {
        let calendar = Calendar.current
        
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: self)
        
        components.minute = 59
        components.second = 59
        components.hour = 23

        return calendar.date(from: components)!
    }
    
    func toNoon() -> Date {
        let calendar = Calendar.current
        
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: self)
        
        components.minute = 00
        components.second = 00
        components.hour = 12
        
        return calendar.date(from: components)!
    }

    func toCursor() -> String {
        return ISO8601DateFormatter().string(from: self).replacingOccurrences(of: "22:59:59", with: "23:59:59")
    }
    
    func isOlderThanXDays(x:Int) -> Bool {
        let calendar = Calendar.current
        let now = Date()
        let xDaysAgo = calendar.date(byAdding: .day, value: -x, to: now)
        if xDaysAgo == nil { return false }
        return self < xDaysAgo!
    }
    
    func isYoungerThanXDays(x:Int) -> Bool {
        return !isOlderThanXDays(x: x)
    }
    
    func isXHoursAgo(x:Int) -> Bool {
        let calendar = Calendar.current
        let now = Date()
        let xDaysAgo = calendar.date(byAdding: .hour, value: -x, to: now)
        if xDaysAgo == nil { return false }
        return self < xDaysAgo!
    }
    
    func interval(ofComponent comp: Calendar.Component, fromDate date: Date) -> Int {
        
        let currentCalendar = Calendar.current
        
        guard let start = currentCalendar.ordinality(of: comp, in: .era, for: date) else { return 0 }
        guard let end = currentCalendar.ordinality(of: comp, in: .era, for: self) else { return 0 }
        
        return end - start
    }
}
