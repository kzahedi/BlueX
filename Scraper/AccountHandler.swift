//
//  AccountHandler.swift
//  BlueX
//
//  Created by Keyan Ghazi-Zahedi on 18.01.25.
//

import Foundation
import CoreData

class AccountHandler {
    static let shared : AccountHandler = AccountHandler()
    public let accounts : [Account]

    let context = PersistenceController.shared.container.viewContext
    
    let dateFormatter = DateFormatter()
    
    private init(){
        dateFormatter.dateStyle = .short
        let fetchRequest: NSFetchRequest<Account> = Account.fetchRequest()
        do {
            self.accounts = try context.fetch(fetchRequest)
        } catch {
            print("Cannot access accounts")
            exit(-1)
        }
    }
    
    private func setDateString(date:Date?, optional:String = "N/A") -> String {
        if date != nil {
            return dateFormatter.string(from:date!)
        }
        return optional
    }
    
    
    public func printAccountInformation(){
        for account in accounts {
            let dateString = setDateString(date:account.startAt)
            let lastFeedUpdate = setDateString(date:account.timestampFeed)
            let lastReplyTreesUpdate = setDateString(date:account.timestampReplyTrees)
            let lastSentimentUpdate = setDateString(date:account.timestampSentiment)
            let lastStatisticsUpdate = setDateString(date:account.timestampStatistics)
                    
            print("Account name: \(account.displayName ?? "No name")")
            print("  Handle:                    \(account.handle ?? "No handle")")
            print("  DID:                       \(account.did ?? "No DID")")
            print("  Is active:                 \(account.isActive)")
            print("  Scraping starts at         \(dateString)")
            print("  Followers Count:           \(account.followersCount)")
            print("  Follows Count:             \(account.followsCount)")
            print("  Number of posts:           \(account.postsCount)")
            print("  Force feed updates:        \(account.forceFeedUpdate)")
            print("  Last feed update:          \(lastFeedUpdate)")
            print("  Force reply tree updates:  \(account.forceReplyTreeUpdate)")
            print("  Last reply trees update:   \(lastReplyTreesUpdate)")
            print("  Force sentiment updates:   \(account.forceSentimentUpdate)")
            print("  Last sentiment update:     \(lastSentimentUpdate)")
            print("  Force statistics updates:  \(account.forceStatistics)")
            print("  Last statistics update:    \(lastStatisticsUpdate)")

        }
    }
}
