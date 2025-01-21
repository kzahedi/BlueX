//
//  FeedScraper.swift
//  BlueX
//
//  Created by Keyan Ghazi-Zahedi on 18.01.25.
//

import Foundation
import CoreData
import Progress

struct FeedScraper {
    let context = CliPersistenceController.shared.container.viewContext
    
    let accountHandler : AccountHandler = AccountHandler.shared
    let dateFormatter = DateFormatter()
    
    let calendar = Calendar.current

    
    init(){
        dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
    }
    
    private func getScrapingDates(account:Account) -> [Date] {
        var dates : [Date] = []
        let today = Date()
        let startAt = account.startAt ?? today
        let calendar = Calendar.current
        
        var currentDate = Date()
        while currentDate >= startAt {
            currentDate = currentDate.toNoon()
            let intervalStart = calendar.startOfDay(for: currentDate)
            let intervalEnd = calendar.date(byAdding: .day, value: 1, to: intervalStart)!
            let tmpo = currentDate
            if let nextDate = calendar.date(byAdding: .day, value: -1, to: currentDate) {
                currentDate = nextDate
            }
            
            if intervalEnd.isOlderThanXDays(x: 1) == false {
                dates.append(intervalEnd.toEndOfDay())
                continue
            }
            
            let fetchRequest: NSFetchRequest<ScrapingLog> = ScrapingLog.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "timestamp >= %@ AND timestamp < %@ AND account == %@ AND completed == true and type == 'feed'",
                                                 intervalStart as NSDate,
                                                 intervalEnd as NSDate,
                                                 account)
            do {
                let logs = try context.fetch(fetchRequest)
                if logs.count == 0 {
                    dates.append(intervalEnd.toNoon())
                }
            } catch {
                print("Failed to fetch posts: \(error)")
            }
        }
        dates.sort(by: >)
        return dates
    }
    
    public func scrapeAllActiveAccounts(token:String) {
        for account in accountHandler.accounts {
            if account.isActive {
                scrape(account: account, token: token)
            }
        }
    }
    
    public func scrape(account:Account, token:String) {
        print("Scraping data for \(account.displayName!):")
        var dates = getScrapingDates(account:account)
        let count = dates.count
        var bar = ProgressBar(count: count)
        while !dates.isEmpty {
            bar.setValue(min(count, count - dates.count + 1))
            let scrapingDate = dates.removeFirst()
            scrapeDay(account:account, day:scrapingDate, token:token)
        }
        print("Done.\n")
    }
    
    private func scrapeDay(account:Account, day:Date, token:String) {
        let limit = 1 // fetch post by post
        var dayCompleted = true
        let startOfDay = day.toStartOfDay()
        let endOfDay = day.toEndOfDay()
        var cursor = endOfDay.toCursor()
        
        while true {
            let feed = fetchFeed(for:account.did!, token: token, limit: limit, cursor:cursor)
            
            if feed == nil {
                dayCompleted = false // TODO: check
                break
            }
            
            for feedItem in feed!.feed {
                
                let date = convertToDate(from:feedItem.post.record!.createdAt!) ?? nil
                
                if date == nil {
                    dayCompleted = false
                    break
                }
                
                if date! < startOfDay {
                    dayCompleted = true
                    break
                }
                
                let post = getPostFromCoreData(uri: feedItem.post.uri!, context: self.context)
                
                post.createdAt = date!
                post.fetchedAt = Date()
                post.uri = feedItem.post.uri
                post.likeCount = Int64(feedItem.post.likeCount!)
                post.replyCount = Int64(feedItem.post.replyCount!)
                post.quoteCount = Int64(feedItem.post.quoteCount!)
                post.repostCount = Int64(feedItem.post.repostCount!)
                post.text = feedItem.post.record!.text!
                post.title = feedItem.post.record!.embed?.external?.title!
                account.addToPosts(post)
                post.account = account
                try? self.context.save()
            }
            
            if feed!.cursor != nil {
                let cursorDate = convertToDate(from: feed!.cursor!)
                if cursorDate == nil {
                    dayCompleted = true
                    if feed!.feed.isEmpty == false {
                        dayCompleted = false
                    }
                    break
                }
                if cursorDate! < startOfDay {
                    dayCompleted = true
                    break
                }
                cursor = feed!.cursor!
            } else {
                dayCompleted = true
                break
            }
        }
        
        var foundLog : ScrapingLog?
        var log : ScrapingLog
        
        if let logs = account.logs as? Set<ScrapingLog> {
            foundLog = logs.first(where: {$0.timestamp! > startOfDay && $0.timestamp! < endOfDay})
        }
        
        if foundLog == nil {
            log = ScrapingLog(context: self.context)
            account.addToLogs(log)
        } else {
            log = foundLog!
        }
        log.timestamp = day.toNoon()
        log.completed = dayCompleted
        log.type = "feed"
        log.account = account
        
        
        account.timestampFeed = Date()
        try? self.context.save()
    }
    
    
    private func fetchFeed(for did:String, token: String, limit: Int, cursor:String) -> FeedResponse? {
        let feedRequestURL = "https://api.bsky.social/xrpc/app.bsky.feed.getAuthorFeed"
        var url = ""
        if cursor == "" {
            url = feedRequestURL + "?actor=\(did)&limit=\(limit)"
        } else {
            url = feedRequestURL + "?actor=\(did)&limit=\(limit)&cursor=\(cursor)"
        }
        var feedRequest = URLRequest(url: URL(string: url)!)
        let group = DispatchGroup()
        
        feedRequest.httpMethod = "GET"
        feedRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        var returnValue: FeedResponse? = nil
        
        group.enter()
        let feedTask = URLSession.shared.dataTask(with: feedRequest) { data, response, error in
            if error != nil {
                print("Error fetching feed: \(error!.localizedDescription)")
                group.leave()
                
            }
            
            let httpResponse = response as? HTTPURLResponse
            if httpResponse == nil {
                print("Invalid response type")
                group.leave()
            }
            
            if data == nil {
                print("No data received")
                group.leave()
            }
            
            //            prettyPrintJSON(data: data!)
            
            do {
                if httpResponse!.statusCode == 401 {
                    throw BlueskyError.unauthorized("Invalid or expired token")
                }
                
                if !(200...299).contains(httpResponse!.statusCode) {
                    throw BlueskyError.feedFetchFailed(
                        reason: "Server returned error response",
                        statusCode: httpResponse!.statusCode
                    )
                }
                
                var feedResponse = try JSONDecoder().decode(FeedResponse.self, from: data!)
                
                let filteredPosts = feedResponse.feed
                    .filter { postWrapper in
                        postWrapper.post.author!.did! == did  // Keep only posts from the target DID
                    }
                
                feedResponse.feed = filteredPosts
                
                returnValue = feedResponse
                
                group.leave()
            } catch let decodingError as DecodingError {
                prettyPrintJSON(data: data!)
                print("Decoding error: \(decodingError)")
                group.leave()
            } catch let blueskyError as BlueskyError {
                print("Bluesky error: \(blueskyError.localizedDescription)")
                group.leave()
            } catch {
                print("Unexpected error: \(error)")
                group.leave()
            }
        }
        feedTask.resume()
        group.wait()
        return returnValue
    }
}
