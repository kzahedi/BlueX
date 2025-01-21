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
    
    
    func run() throws {
        let accountHandler : AccountHandler = AccountHandler.shared
        
        let sentimentTask = SentimentAnalysis()
        let statisticsTask = CalculateStatistics()
        
        if let token = getBlueSkyToken() {
            let feedScraper = FeedScraper()
            let threadScraper = ThreadScraper()
            let accountScraper = AccountScaper()
            
            for account in accountHandler.accounts {
                accountScraper.updateAccount(account: account, token: token)
                
                if account.isActive {
                    print("Working on:")
                    print(account)
                    if feed       || all { feedScraper.scrape(account:account, token:token) }
                    if thread     || all { threadScraper.scrape(account:account, token:token) }
                    if Sentiment  || all { sentimentTask.calculateSentimentsFor(account:account, tool: .NLTagger) }
                    if statistics || all { statisticsTask.calculateFor(account:account) }
                }
            }
        } else {
            print("Cannot get BlueSky token. Skipping sentiment and statistics calculations...")
            if Sentiment  || all { sentimentTask.calculateSentimentsForAllActiveAccounts() }
            if statistics || all { statisticsTask.calculateStatisticsForAllActiveAccounts() }
        }
        
    }
}

Scraper.main()



