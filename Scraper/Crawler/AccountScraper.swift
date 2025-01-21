//
//  AccountScraper.swift
//  BlueX
//
// Scrape Account Information
//
//  Created by Keyan Ghazi-Zahedi on 19.01.25.
//

import Foundation
import CoreData


struct AccountScaper {
    let context = CliPersistenceController.shared.container.viewContext
    
    func updateAccount(account:Account, token:String) {
        
        if let handle = account.handle {
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
                
                if let profile = resolveProfile(did: account.did!, token:token) {
                    
                    let displayName = profile.displayName
                    let followsCount = String(profile.followsCount)
                    let followersCount = String(profile.followersCount)
                    let postsCount = String(profile.postsCount)
                    
                    // No recent entries found, create a new one
                    let newAccountHistory = AccountHistory(context: self.context)
                    newAccountHistory.account = account
                    newAccountHistory.followersCount = Int64(profile.followersCount)
                    newAccountHistory.followsCount = Int64(profile.followsCount)
                    newAccountHistory.timestamp = Date()
                    newAccountHistory.postsCount = Int64(profile.postsCount)
                    account.addToHistory(newAccountHistory)
                    
                    
                    account.handle = handle
                    account.displayName = displayName
                    account.followsCount = Int64(followsCount) ?? 0
                    account.followersCount = Int64(followersCount) ?? 0
                    account.postsCount = Int64(postsCount) ?? 0
                    
                    do {
                        try context.save()
                        print("Account \(account.displayName!) updated successfully.")
                    } catch {
                        print("Failed to save account: \(error)")
                    }
                }
            }
        }
    }
}
