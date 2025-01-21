//
//  main.swift
//  Scraper
//
//  Created by Keyan Ghazi-Zahedi on 18.01.25.
//

import Foundation
import Progress

let accountHandler : AccountHandler = AccountHandler.shared

//if let token = getBlueSkyToken() {
//    
//    let feedScraper = FeedScraper()
//    let threadScraper = ThreadScraper()
//    let accountScraper = AccountScaper()
//    let sentiment = SentimentAnalysis()
//
//    for account in accountHandler.accounts {
//        accountScraper.updateAccount(account: account, token: token)
//        
//        if account.isActive {
//            feedScraper.scrape(account:account, token:token)
//            threadScraper.scrape(account:account, token:token)
//            sentiment.calculateSentimentsFor(account:account, tool: .NLTagger)
//        }
//    }
//    
//} else {
    print("Cannot get BlueSky token.")
//    let sentiment = SentimentAnalysis()
//    sentiment.calculateSentimentsForAllActiveAccounts()
let statistics = CalculateStatistics()
statistics.calculateStatisticsForAllActiveAccounts()
//}



