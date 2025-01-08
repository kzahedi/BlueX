//
//  ProcessMenu.swift
//  BlueX
//
//  Created by Keyan Ghazi-Zahedi on 07.01.25.
//

import Foundation
import SwiftUI
import CoreData

struct ProcessesMenu: Commands {
    @EnvironmentObject var taskManager: TaskManager
    private var context : NSManagedObjectContext? = nil
    private var backgroundContext : NSManagedObjectContext? = nil

    init() {
        self.context = PersistenceController.shared.container.viewContext
        self.backgroundContext = {
            let context = PersistenceController.shared.container.newBackgroundContext()
            context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
            return context
        }()
    }
        
    var body: some Commands {
        CommandMenu("Processes") {
            Button("Feed Scraping (All Accounts)") {
                performFeedScraping()
            }
            Button("Reply Tree Scraping (All Accounts)") {
                performReplyTreeScraping()
            }
            Button("Calculate Statistics (All Acconts)") {
                calculateStatistics()
            }
            Button("Sentiment Analysis (All Accounts)") {
                sentimentAnalysis()
            }
        }
    }
    
    // Example placeholder methods for each menu action
    func performFeedScraping() {
        print("Feed Scraping for All Accounts initiated.")
        
        let fetchRequest: NSFetchRequest<Account> = Account.fetchRequest()
        do {
            let accounts = try self.context!.fetch(fetchRequest)
            for account in accounts {
                let did = account.did!
                let name = account.displayName!
                let date = account.startAt!
                let force = account.forceFeedUpdate
                print("Working on \(name)")

                sendNotification(title: "BlueX", subtitle: "Feed Scraper - Start", body: "Starting the feed scraper for \(name)")
                var scraper = BlueskyFeedHandler()
                scraper.context = self.backgroundContext!
                try scraper.runFor(did:did, earliestDate: date, forceUpdate: force) {process in print(process)}
                sendNotification(title: "BlueX", subtitle: "Feed Scraper - Complete", body: "The feed scraper has completed for \(name)")
            }
        } catch {
            print(error)
        }
    }
    
    func performReplyTreeScraping() {
        print("Reply Tree Scraping for All Accounts initiated.")
        let fetchRequest: NSFetchRequest<Account> = Account.fetchRequest()
        do {
            let accounts = try self.context!.fetch(fetchRequest)
            for account in accounts {
                let did = account.did!
                let name = account.displayName!
                let date = account.startAt!
                let force = account.forceFeedUpdate
                print("Working on \(name)")
                
                sendNotification(title: "BlueX", subtitle: "Reply Tree Scraper - Start", body: "Starting the feed scraper for \(name)")
                var scraper = BlueskyRepliesHandler()
                scraper.context = self.backgroundContext!
                try scraper.runFor(did:did, earliestDate: date, forceUpdate: force) {process in print(process)}
                sendNotification(title: "BlueX", subtitle: "Reply Tree Scraper - Complete", body: "The reply tree scraper has completed for \(name)")
            }
        } catch {
            print(error)
        }

    }
    
    func calculateStatistics() {
        print("Calculate statistics for all accounts.")
        let fetchRequest: NSFetchRequest<Account> = Account.fetchRequest()
        do {
            let accounts = try self.context!.fetch(fetchRequest)
            for account in accounts {
                let did = account.did!
                let name = account.displayName!
                print("Working on \(name)")

                sendNotification(title: "BlueX", subtitle: "Calculating Statistics - Start", body: "Starting to calculate statistics for \(name)")
                var calc = CountReplies()
                calc.context = self.backgroundContext!
                try calc.runFor(did:did) {process in let _ = process}
                sendNotification(title: "BlueX", subtitle: "Calculating Statistics - Complete", body: "Statistics calculation has completed for \(name)")
            }
        } catch {
            print(error)
        }

    }
    
    func sentimentAnalysis() {
        print("Sentiment Analysis for all accounts.")
        let fetchRequest: NSFetchRequest<Account> = Account.fetchRequest()
        do {
            let accounts = try self.context!.fetch(fetchRequest)
            for account in accounts {
                let did = account.did!
                let name = account.displayName!
                print("Working on \(name)")

                sendNotification(title: "BlueX", subtitle: "Sentiment Analysis - Start", body: "Starting sentiment analysis for \(name)")
                var calc = CountReplies()
                calc.context = self.backgroundContext!
                try calc.runFor(did:did) {process in let _ = process}
                sendNotification(title: "BlueX", subtitle: "Sentiment Analysis - Complete", body: "The sentityment analysis has completed for \(name)")
            }
        } catch {
            print(error)
        }
    }
}


