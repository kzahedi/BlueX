//
//  main.swift
//  Scraper
//
//  Created by Keyan Ghazi-Zahedi on 18.01.25.
//

import Foundation
import Progress

let accountHandler : AccountHandler = AccountHandler.shared

let sentiment = SentimentAnalysis()
let statistics = CalculateStatistics()

if let token = getBlueSkyToken() {
    let feedScraper = FeedScraper()
    let threadScraper = ThreadScraper()
    let accountScraper = AccountScaper()
    
    for account in accountHandler.accounts {
        accountScraper.updateAccount(account: account, token: token)
        
        if account.isActive {
            feedScraper.scrape(account:account, token:token)
            threadScraper.scrape(account:account, token:token)
            sentiment.calculateSentimentsFor(account:account, tool: .NLTagger)
        }
    }
    
} else {
    print("Cannot get BlueSky token. Skipping sentiment and statistics calculations...")
    sentiment.calculateSentimentsForAllActiveAccounts()
    statistics.calculateStatisticsForAllActiveAccounts()
}



