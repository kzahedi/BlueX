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
    @Published var isActive : Bool

    let account: Account
    let context: NSManagedObjectContext
    let outputFormatter = DateFormatter()

    init(account: Account, context: NSManagedObjectContext? = nil) {
        self.account = account
        self.context = context ?? PersistenceController.shared.container.viewContext
        self.outputFormatter.dateFormat = "dd.MM.YYYY"
        
       
        // Initialize ViewModel properties from CoreData model
        self.displayName = account.displayName ?? ""
        self.handle = account.handle ?? ""
        self.did = account.did ?? ""
        self.isActive = account.isActive
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
            print(account.did ?? "DID not found")
        }
        
        if let history = account.history as? Set<AccountHistory> {
            if let newest = history.sorted(by: { $0.timestamp! > $1.timestamp! }).first {
                if newest.timestamp!.isXHoursAgo(x: 12) == false {
                    return
                }
            }
            
            let token = getToken()!
            
            if let profile = resolveProfile(did: account.did!, token:token) {
                
                handle = profile.handle
                displayName = profile.displayName
                followsCount = String(profile.followsCount)
                followersCount = String(profile.followersCount)
                postsCount = String(profile.postsCount)
                did = account.did!
                
                // No recent entries found, create a new one
                let newAccountHistory = AccountHistory(context: self.context)
                newAccountHistory.account = account
                newAccountHistory.followersCount = Int64(profile.followersCount)
                newAccountHistory.followsCount = Int64(profile.followsCount)
                newAccountHistory.timestamp = Date()
                newAccountHistory.postsCount = Int64(profile.postsCount)
                account.addToHistory(newAccountHistory)
                
                save()
            }
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
        account.isActive = isActive
        
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
        
        var followersCount: Int64 = 0
        var followsCount: Int64 = 0
        var postsCount: Int64 = 0
        
        if let history = account.history as? Set<AccountHistory> {
            
            if let newest = history.sorted(by: { $0.timestamp! > $1.timestamp! }).first {
                followsCount = newest.followsCount
                followersCount = newest.followersCount
                postsCount = newest.postsCount
            }
        }
        self.followersCount = String(followersCount)
        self.followsCount = String(followsCount)
        self.postsCount = String(postsCount)
    }
}
