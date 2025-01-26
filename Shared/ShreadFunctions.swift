//
//  ShreadFunctions.swift
//  BlueX
//
//  Created by Keyan Ghazi-Zahedi on 19.01.25.
//

import Foundation
import CoreData

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

func getPostFromCoreData(uri:String, context:NSManagedObjectContext) -> Post {
    let fetchRequest: NSFetchRequest<Post> = Post.fetchRequest()
    fetchRequest.predicate = NSPredicate(format: "uri == %@", uri as CVarArg)
    fetchRequest.fetchLimit = 1
    
    do {
        let results = try context.fetch(fetchRequest)
        if results.first != nil {
            return results.first!
        }
    } catch {
        print("Failed to fetch AccountHistory: \(error)")
    }
    
    let post = Post(context: context)
    post.uri = uri
    post.id = UUID()
    post.replyTreeChecked = false
    return post
}

func setDateString(date:Date?, optional:String = "N/A") -> String {
    let dateFormatter = DateFormatter()
    dateFormatter.dateStyle = .short
    
    if date != nil {
        return dateFormatter.string(from:date!)
    }
    return optional
}

func printPredicate(_ predicate: NSPredicate) {
    if let comparisonPredicate = predicate as? NSComparisonPredicate {
        let left = comparisonPredicate.leftExpression.description
        let right = comparisonPredicate.rightExpression.description
        let op = comparisonPredicate.predicateOperatorType
        
        print("Predicate: \(left) \(op) \(right)")
    } else {
        print("Predicate: \(predicate)")
    }
}

func getSentimentScore(post:Post, tool: SentimentAnalysisTool) -> Double {
    if let sentimentsSet = post.sentiments as? Set<Sentiment> {
        let sentiments = Array(sentimentsSet)
        let toolStr = tool.stringValue
        return sentiments.filter{$0.tool == toolStr}.first?.score ?? 0.0
    }
    return 0.0
}

func createDateFrom(day:Int, month:Int, year:Int) -> Date {
    //create an instance of DateComponents to keep your code flexible
    var dateComponents = DateComponents()
    
    //create the date components
    dateComponents.year = year
    dateComponents.month = month
    dateComponents.day = day
    dateComponents.timeZone = TimeZone(abbreviation: "GMT")
    dateComponents.hour = 12
    dateComponents.minute = 00
    
    //create an instance of a Calendar for point of reference ex: myCalendar, and use the dateComponents as the parameter
    return Calendar.current.date(from: dateComponents)!
}

func createDateString(day:Int, month:Int, year:Int) -> String? {
    // Create a DateComponents object
    var dateComponents = DateComponents()
    dateComponents.day = day
    dateComponents.month = month
    dateComponents.year = year
    
    // Create a Calendar instance
    let calendar = Calendar.current
    
    // Get the Date from the DateComponents
    if let date = calendar.date(from: dateComponents) {
        // Create a DateFormatter
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "dd-MM-yyyy" // Set the desired format
        
        // Convert the Date to a string in the desired format
        let dateString = dateFormatter.string(from: date)
        
        // Return the formatted date string
        return dateString
    }
    return nil
}
