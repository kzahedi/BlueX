//
//  main.swift
//  Scraper
//
//  Created by Keyan Ghazi-Zahedi on 18.01.25.
//

import Foundation
import Progress

let accountHandler : AccountHandler = AccountHandler.shared
let feedScraper = FeedScraper()

feedScraper.scrape()

