//
//  HTTPRequests.swift
//  Bluesent
//
//  Created by Keyan Ghazi-Zahedi on 25.12.24.
//
import Foundation
import CoreData

struct BlueskyFeedHandler {
    var context : NSManagedObjectContext? = nil
    
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
    
    public func runFor(did:String, progress: @escaping (Double) -> Void) async {
        
        if self.context == nil {
            print("No context set")
            return
        }
        let account = try? getAccount(did:did, context: self.context!)!
        let token = getToken()
        runFor(account:account!, token:token!, progress:progress)
    }
    
    public func runFor(account:Account, token:String, progress: @escaping (Double) -> Void) {

        let limit = 100
        let earliestDate = account.startAt ?? Date()
        let forceUpdate = account.forceFeedUpdate
        
        let today = Date()
        let nrOfDays : Double = abs(Double(earliestDate.interval(ofComponent: .day, fromDate: today)))
        
        var cursor = getEarliestDateAsCursor(force:forceUpdate, account:account)
        
        while true {
            let feed = fetchFeed(for:account.did!, token: token, limit: limit, cursor:cursor)
            
            if feed == nil {
                break
            }
            
            for feedItem in feed!.feed {
                
                let date = convertToDate(from:feedItem.post.record!.createdAt!) ?? nil
                
                if date == nil || date! < earliestDate {
                    continue
                }
                
                let remainingDays : Double = abs(Double(earliestDate.interval(ofComponent: .day, fromDate: date!)))
                let v = min(1.0, max(0.0, remainingDays / nrOfDays))
                progress(1.0 - v)
                
                let post = getPostFromCoreData(uri: feedItem.post.uri!, context: self.context!)
                
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
                
                try? self.context!.save()
            }
            
            if feed!.cursor != nil {
                let cursorDate = convertToDate(from: feed!.cursor!)
                if cursorDate == nil {
                    print("Problem with \(feed!.cursor!)")
                    break
                }
                if cursorDate! < earliestDate {
                    break
            }
                cursor = feed!.cursor!
            } else {
                break
            }
            try? self.context!.save()
        }
        account.timestampFeed = Date()
        try? self.context!.save()
    }
    
    func getEarliestDateAsCursor(force:Bool, account:Account) -> String {
        if force == true {
            return Date().toCursor()
        }
        
        let postsSet = account.posts as? Set<Post> ?? Set<Post>()
        let posts = Array(postsSet)
        var date = posts.sorted{ $0.createdAt! < $1.createdAt!}.first?.createdAt ?? Date()
        date = date.toStartOfDay()
        return date.toCursor()
    }
}

