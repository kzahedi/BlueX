//
//  UpdateAllTasks.swift
//  BlueX
//
//  Created by Keyan Ghazi-Zahedi on 11.01.25.
//

import Foundation
import CoreData

struct UpdateAllTasks {
    static let shared = UpdateAllTasks()

    let context = PersistenceController.shared.container.viewContext
    var feedScraper : BlueskyFeedHandler = BlueskyFeedHandler()
    var repliesScraper : BlueskyRepliesHandler = BlueskyRepliesHandler()
    var statistics = CalculateStatistics()
    var sentimentAnalysis = SentimentAnalysis()
 
    let logger : Logger = Logger.shared

    private init() {
        let backgroundContext: NSManagedObjectContext = {
            let context = PersistenceController.shared.container.newBackgroundContext()
            context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
            return context
        }()
        self.feedScraper.context = backgroundContext
        self.repliesScraper.context = backgroundContext
        self.sentimentAnalysis.context = backgroundContext
        self.statistics.context = backgroundContext
    }

    public func execute() {
        if let token = getToken() {
            DispatchQueue.background(delay:0.0, background:{
                print("Token: \(token)")
                let fetchRequest: NSFetchRequest<Account> = Account.fetchRequest()
                if let accounts = try? context.fetch(fetchRequest) {
                    var activeAccounts = accounts.filter{$0.isActive}
                    activeAccounts.shuffle()
                    for account in activeAccounts {
                        scrapeFeed(account:account, token:token)
                        scrapeRaplyTrees(account:account, token:token)
                        calculateSentiments(account:account, tool: .NLTagger)
                        calculateStatistics(account:account, tool: .NLTagger)
                    }
                }
            }, completion:{})
        } else {
            print("Cannot get token")
        }
    }
    
    private func scrapeFeed(account: Account, token:String) {
        print("Scraping feed for \(account.displayName!)")
        notifyTaskCompletion(taskName: "Started scraping feed", accountName: account.displayName!)
        feedScraper.runFor(account: account, token:token) { _ in }
        notifyTaskCompletion(taskName: "Completed scraping feed", accountName: account.displayName!)
    }
    
    private func scrapeRaplyTrees(account: Account, token:String) {
        print("Scraping reply tree for \(account.displayName!)")
        feedScraper.runFor(account: account, token:token) { _ in }
        notifyTaskCompletion(taskName: "Started scraping reply trees", accountName: account.displayName!)
        repliesScraper.runFor(account: account, token:token) { _ in }
        notifyTaskCompletion(taskName: "Completed scraping reply trees", accountName: account.displayName!)
    }
    
    private func calculateSentiments(account: Account, tool: SentimentAnalysisTool) {
        print("Calculate sentiments for \(account.displayName!) with \(tool.stringValue)")
        notifyTaskCompletion(taskName: "Started calculating sentiments", accountName: account.displayName!)
        sentimentAnalysis.runFor(account: account, tool: tool) { _ in }
        notifyTaskCompletion(taskName: "Completed calculating sentiments", accountName: account.displayName!)
    }
    
    private func calculateStatistics(account: Account, tool: SentimentAnalysisTool) {
        print("Calculating statistics for \(account.displayName!) with \(tool.stringValue)")
        notifyTaskCompletion(taskName: "Started calculating statistics", accountName: account.displayName!)
        statistics.runFor(account: account) { _ in }
        notifyTaskCompletion(taskName: "Completed calculating statistics", accountName: account.displayName!)
    }

}
