//
//  main.swift
//  Scraper
//
//  Created by Keyan Ghazi-Zahedi on 18.01.25.
//

import Foundation

let accountHandler : AccountHandler = AccountHandler.shared
let feedScraper = FeedScraper()

print("Found the following accounts:")


accountHandler.printAccountInformation()


feedScraper.scrape()

