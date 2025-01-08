//
//  AccountViewModel.swift
//  BlueX
//
//  Created by Keyan Ghazi-Zahedi on 07.01.25.
//

import Foundation
import SwiftUI
import CoreData

class AccountViewModel: ObservableObject {
    @Published var displayName: String
    @Published var handle: String
    @Published var did: String
    @Published var forceFeedUpdate: Bool
    @Published var forceReplyUpdate: Bool
    @Published var forceSentimentUpdate: Bool
    @Published var forceStatistics: Bool
    @Published var startDate: Date
    @Published var timestampFeed: String
    @Published var timestampReplyTrees: String
    @Published var timestampSentiment: String
    @Published var timestampStatistics: String
    @Published var followersCount : String
    @Published var followsCount : String
    @Published var postsCount : String

    let account: Account
    let context: NSManagedObjectContext
    let outputFormatter = DateFormatter()

    init(account: Account, context: NSManagedObjectContext? = nil) {
        self.account = account
        self.context = context ?? PersistenceController.shared.container.viewContext
        self.outputFormatter.dateFormat = "dd.mm.YYYY"
        
       
        // Initialize ViewModel properties from CoreData model
        self.displayName = account.displayName ?? ""
        self.handle = account.handle ?? ""
        self.did = account.did ?? ""
        self.forceFeedUpdate = account.forceFeedUpdate
        self.forceReplyUpdate = account.forceReplyTreeUpdate
        self.forceSentimentUpdate = account.forceSentimentUpdate
        self.forceStatistics = account.forceStatistics
        self.startDate = account.startAt ?? Date()
        self.timestampFeed = ""
        self.timestampReplyTrees = ""
        self.timestampSentiment = ""
        self.timestampStatistics = ""
        
        self.followersCount = "0"
        self.followsCount = "0"
        self.postsCount = "0"
        
        self.timestampFeed = self.getDate(from:account.timestampFeed)
        self.timestampReplyTrees = self.getDate(from:account.timestampReplyTrees)
        self.timestampSentiment = self.getDate(from:account.timestampSentiment)
        self.timestampStatistics = self.getDate(from:account.timestampStatistics)
        
        updateCountsFromHistory()
    }
    
    func updateAccount() {
        if account.did == nil {
            account.did = resolveDID(handle: handle)
        }
        if let profile = resolveProfile(did: account.did!) {
            
            handle = profile.handle
            displayName = profile.displayName
            followsCount = String(profile.followsCount)
            followersCount = String(profile.followersCount)
            postsCount = String(profile.postsCount)
            
            let cutoffDate = Calendar.current.date(byAdding: .hour, value: -12, to: Date())!
            
            let fetchRequest: NSFetchRequest<AccountHistory> = AccountHistory.fetchRequest()
            fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                NSPredicate(format: "accountID == %@", account.id! as CVarArg),
                NSPredicate(format: "timestamp >= %@", cutoffDate as NSDate)
            ])
            
            do {
                let results = try self.context.fetch(fetchRequest)
                
                if results.isEmpty {
                    // No recent entries found, create a new one
                    let newAccountHistory = AccountHistory(context: self.context)
                    newAccountHistory.accountID = account.id
                    newAccountHistory.followersCount = Int64(profile.followersCount)
                    newAccountHistory.followsCount = Int64(profile.followsCount)
                    newAccountHistory.timestamp = Date()
                    newAccountHistory.postsCount = Int64(profile.postsCount)
                    
                } else {
                    print("Recent entry found, skipping update.")
                }
            } catch {
                print("Failed to fetch or save Core Data: \(error.localizedDescription)")
            }
            save()
        }
    }
    
    func save() {
        account.handle = handle
        account.displayName = displayName
        account.did = did
        account.forceFeedUpdate = forceFeedUpdate
        account.forceReplyTreeUpdate = forceReplyUpdate
        account.forceSentimentUpdate = forceSentimentUpdate
        account.forceStatistics = forceStatistics
        account.startAt = startDate.toStartOfDay()
        account.followsCount = Int64(followsCount) ?? 0
        account.followersCount = Int64(followersCount) ?? 0
        
        do {
            try context.save()
            print("Account updated successfully.")
        } catch {
            print("Failed to save account: \(error)")
        }
    }
    
    func getDate(from timestamp: Date?) -> String {
        if timestamp == nil {
            return "Not yet processed"
        }
        return self.outputFormatter.string(from:timestamp!)
    }
    
    private func updateCountsFromHistory() {
        let fetchRequest: NSFetchRequest<AccountHistory> = AccountHistory.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "accountID == %@", account.id! as CVarArg)
        fetchRequest.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
        fetchRequest.fetchLimit = 1
        
        var followersCount: Int64 = 0
        var followsCount: Int64 = 0
        var postsCount: Int64 = 0
        
        do {
            let results = try context.fetch(fetchRequest)
            if results.first != nil {
                followsCount = results.first!.followsCount
                followersCount = results.first!.followersCount
                postsCount = results.first!.postsCount
            }
        } catch {
            print("Failed to fetch AccountHistory: \(error)")
        }
        self.followersCount = String(followersCount)
        self.followsCount = String(followsCount)
        self.postsCount = String(postsCount)
    }
}
