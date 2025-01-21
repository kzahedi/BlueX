//
//  main.swift
//  Scraper
//
//  Created by Keyan Ghazi-Zahedi on 18.01.25.
//

import Foundation
import Progress

let accountHandler : AccountHandler = AccountHandler.shared
if let token = getBlueSkyToken() {
    let feedScraper = FeedScraper()
    let threadScraper = ThreadScraper()
    let accountScraper = AccountScaper()
    
    for account in accountHandler.accounts {
        accountScraper.updateAccount(account: account, token: token)
    }
    
    feedScraper.scrape(token:token)
    threadScraper.scrape(token:token)
    
} else {
    print("Cannot get BlueSky token.")
}

