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
