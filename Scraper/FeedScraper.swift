//
//  FeedScraper.swift
//  BlueX
//
//  Created by Keyan Ghazi-Zahedi on 18.01.25.
//

import Foundation
import CoreData


struct FeedScraper {
    
    let accountHandler : AccountHandler = AccountHandler.shared
    let context = PersistenceController.shared.container.viewContext
    
    private func getScrapingDates(account:Account) -> [Date] {
        var dates : [Date] = []
        let today = Date()
        let startAt = account.startAt ?? today
        let calendar = Calendar.current

        var currentDate = startAt
        while currentDate <= today {
            let intervalStart = currentDate.toStartOfDay()
            if let nextDate = calendar.date(byAdding: .day, value: 1, to: currentDate) {
                currentDate = nextDate
            }
            
            let intervalEnd = currentDate.toStartOfDay()
            
            let fetchRequest: NSFetchRequest<Post> = Post.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "createdAt >= %@ AND createdAt < %@ AND account == %@",
                                                 intervalStart as NSDate,
                                                 intervalEnd as NSDate,
                                                 account)
            do {
                let posts = try context.fetch(fetchRequest)
                if posts.count == 0 {
                    // use end, bc the cursor in bluesky goes back in time
                    dates.append(intervalEnd)
                }
            } catch {
                print("Failed to fetch posts: \(error)")
            }
        }
        return dates
    }
    
    public func scrape() {
        
        if let account = accountHandler.accounts.first {
            let dates = getScrapingDates(account:account)
            for date in dates {
                print(date)
            }
        }
    }
}
