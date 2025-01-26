//
//  main.swift
//  Scraper
//
//  Created by Keyan Ghazi-Zahedi on 18.01.25.
//

import Foundation
import Progress
import ArgumentParser


struct Scraper: ParsableCommand {
    static var configuration = CommandConfiguration(abstract: "Process posts.")
    
    @Flag(name: .shortAndLong, help: "Update accounts.")
    var updateAccounts: Bool = false
     
    @Flag(name: .shortAndLong, help: "Run the feed scraper.")
    var feed: Bool = false
    
    @Flag(name: .shortAndLong, help: "Run the thread scraper")
    var thread: Bool = false
    
    @Flag(name: .shortAndLong, help: "Calculate sentiments")
    var Sentiment: Bool = false
    
    @Flag(name: .shortAndLong, help: "Calculate statistics")
    var statistics: Bool = false
    
    @Flag(name: .shortAndLong, help: "Calculate plot data")
    var plotdata: Bool = false
    
    @Flag(name: .shortAndLong, help: "Perform all scraping and analysing tasks")
    var all: Bool = false
    
    @Flag(name: .shortAndLong, help: "Cleanup the data")
    var cleanup: Bool = false
    
    @Flag(name: .shortAndLong, help: "Set to false by default. Cleanup will only be done, if this is true.")
    var doit: Bool = false
    
    @Option(name: .shortAndLong, help: "Batch size.")
    var batchSize: Int = 1000
    
    func run() throws {
        let accountHandler : AccountHandler = AccountHandler.shared
        
        let sentimentTask = SentimentAnalysis()
        let statisticsTask = CalculateStatistics()
        let feedScraper = FeedScraper()
        let threadScraper = ThreadScraper()
        let accountScraper = AccountScaper()
        let cleanupTool = Cleanup()
        let calculatePlotData = CalculatePlotData()

        if cleanup { cleanupTool.run(doit: doit, batchSize: batchSize) }
        
        
        if feed || thread || updateAccounts || all {
            if let token = getBlueSkyToken() {
                for account in accountHandler.accounts {
                    accountScraper.updateAccount(account: account, token: token)
                }
            }
        }
  
        if (feed || thread || all)  {
            for account in accountHandler.accounts {
                if account.isActive {
                    print("Working on:")
                    print(account)
                    if let token = getBlueSkyToken() {
                        if feed       || all { feedScraper.scrape(account:account, token:token) }
                        if thread     || all { threadScraper.scrape(account:account, token:token, batchSize:batchSize) }
                    }
                    if Sentiment  || all { sentimentTask.calculateSentimentsFor(account:account, tool: .NLTagger, batchSize:batchSize) }
                    if statistics || all { statisticsTask.calculateFor(account:account, batchSize:batchSize) }
                    if plotdata   || all { calculatePlotData.calculateFor(account:account) }
                }
            }
        } else {
            if feed || thread || all {
                print("Cannot get BlueSky token. Skipping sentiment and statistics calculations...")
            }
            if Sentiment || statistics || plotdata || all {
                for account in accountHandler.accounts {
                    print("Working on:")
                    print(account)
                    if Sentiment  || all { sentimentTask.calculateSentimentsFor(account:account, tool: .NLTagger) }
                    if statistics || all { statisticsTask.calculateFor(account:account) }
                    if plotdata   || all { calculatePlotData.calculateFor(account:account) }
                }
            }
        }
        
    }
}

Scraper.main()



