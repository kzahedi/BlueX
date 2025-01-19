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

print("Found the following accounts:")

feedScraper.scrape()

var bar = ProgressBar(count: 4)

for _ in 0...3 {
    bar.next()
    sleep(1)
}
