//
//  UpdateAllTasks.swift
//  BlueX
//
//  Created by Keyan Ghazi-Zahedi on 11.01.25.
//

import Foundation
import CoreData

class UpdateAllTasks {
    static let shared = UpdateAllTasks()

    let context = PersistenceController.shared.container.viewContext
    let backgroundContext : NSManagedObjectContext
    var feedScraper : BlueskyFeedHandler = BlueskyFeedHandler()
    var repliesScraper : BlueskyRepliesHandler = BlueskyRepliesHandler()
    var statistics = CalculateStatistics()
    var sentimentAnalysis = SentimentAnalysis()
    var feedUpdates : Int = 0
 
    let logger : Logger = Logger.shared
    var lastPrintTime: Date = .distantPast
    let interval: TimeInterval
    
    @Published var feedProgress : Double = 0.0

    private init(interval: TimeInterval = 1.0) {
        backgroundContext = {
            let context = PersistenceController.shared.container.newBackgroundContext()
            context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
            return context
        }()
        self.feedScraper.context = backgroundContext
        self.repliesScraper.context = backgroundContext
        self.sentimentAnalysis.context = backgroundContext
        self.statistics.context = backgroundContext
        self.interval = interval
    }

    public func execute() {
        if let token = getToken() {
            DispatchQueue.background(delay:0.0, background:{
                print("Token: \(token)")
                let fetchRequest: NSFetchRequest<Account> = Account.fetchRequest()
                if let accounts = try? self.backgroundContext.fetch(fetchRequest) {
                    var activeAccounts = accounts.filter{$0.isActive}
                    activeAccounts.shuffle()
                    for account in activeAccounts {
                        self.scrapeFeed(account:account, token:token)
                        self.scrapeRaplyTrees(account:account, token:token)
                        self.calculateSentiments(account:account, tool: .NLTagger)
                        self.calculateStatistics(account:account)
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
        feedScraper.runFor(account: account, token:token) {progress in
            DispatchQueue.main.async {
                print("Scraping feed progress for \(account.displayName!) is \(Int(round(progress * 100)))%")
            }
        }
        notifyTaskCompletion(taskName: "Completed scraping feed", accountName: account.displayName!)
    }
    
    private func scrapeRaplyTrees(account: Account, token:String) {
        print("Scraping reply tree for \(account.displayName!)")
        notifyTaskCompletion(taskName: "Started scraping reply trees", accountName: account.displayName!)
        repliesScraper.runFor(account: account, token:token) {progress in
            DispatchQueue.main.async {
                print("Scraping reply tree progress for \(account.displayName!) is \(Int(round(progress * 100)))%")
            }
        }
        notifyTaskCompletion(taskName: "Completed scraping reply trees", accountName: account.displayName!)
    }
    
    private func calculateSentiments(account: Account, tool: SentimentAnalysisTool) {
        print("Calculate sentiments for \(account.displayName!) with \(tool.stringValue)")
        notifyTaskCompletion(taskName: "Started calculating sentiments", accountName: account.displayName!)
        sentimentAnalysis.runFor(account: account, tool: tool) {progress in
            DispatchQueue.main.async {
                print("Calculating sentiments for \(account.displayName!) is \(Int(round(progress * 100)))%")
            }
        }
        notifyTaskCompletion(taskName: "Completed calculating sentiments", accountName: account.displayName!)
    }
    
    private func calculateStatistics(account: Account) {
        print("Calculating statistics for \(account.displayName!)")
        notifyTaskCompletion(taskName: "Started calculating statistics", accountName: account.displayName!)
        statistics.runFor(account: account) { progress in
            DispatchQueue.main.async {
                print("Calculating statistics for \(account.displayName!) is \(Int(round(progress * 100)))%")
            }
        }
        notifyTaskCompletion(taskName: "Completed calculating statistics", accountName: account.displayName!)
    }
    
    private func feedUpdate(value:Double) {
        
    }

}
