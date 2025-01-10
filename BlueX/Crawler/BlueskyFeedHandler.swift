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
    
    public func runFor(did:String,
                       earliestDate:Date? = nil,
                       forceUpdate:Bool = false,
                       progress: @escaping (Double) -> Void) throws {
        
        if self.context == nil {
            print("No context set")
            return
        }
        
        let limit = 100
        let token = getToken()
        
        let today = Date()
        let nrOfDays : Double = abs(Double(earliestDate!.interval(ofComponent: .day, fromDate: today)))
        let account = try getAccount(did:did, context: self.context!)!
        
        var cursor = getEarliestDateAsCursor(force:forceUpdate, id:account.id!)
        
        while true {
            let feed = fetchFeed(for:did, token: token!, limit: limit, cursor:cursor)
            
            if feed == nil {
                break
            }
            
            Logger.shared.log("Current cursor: \(cursor)")
            for feedItem in feed!.feed {
                
                let date = convertToDate(from:feedItem.post.record!.createdAt!) ?? nil
                
                if date == nil || date! < earliestDate! {
                    continue
                }
                
                let remainingDays : Double = abs(Double(earliestDate!.interval(ofComponent: .day, fromDate: date!)))
                let v = min(1.0, max(0.0, remainingDays / nrOfDays))
                progress(1.0 - v)
                
                let post = getPost(uri: feedItem.post.uri!, context: self.context!)
                
                post.accountID = account.id
                post.createdAt = date!
                post.fetchedAt = Date()
                post.uri = feedItem.post.uri
                post.likeCount = Int64(feedItem.post.likeCount!)
                post.replyCount = Int64(feedItem.post.replyCount!)
                post.quoteCount = Int64(feedItem.post.quoteCount!)
                post.repostCount = Int64(feedItem.post.repostCount!)
                post.text = feedItem.post.record!.text!
                post.title = feedItem.post.record!.embed?.external?.title!
                
                
            }
            
            if feed!.cursor != nil {
                let cursorDate = convertToDate(from: feed!.cursor!)
                if cursorDate == nil {
                    print("Problem with \(feed!.cursor!)")
                    break
                }
                if earliestDate != nil {
                    if cursorDate! < earliestDate! {
                        break
                    }
                }
                cursor = feed!.cursor!
            } else {
                break
            }
            try self.context!.save()
        }
        account.timestampFeed = Date()
        try self.context!.save()
    }
    
    func getEarliestDateAsCursor(force:Bool, id:UUID) -> String {
        if force == true {
            return Date().toCursor()
        }
        
        let fetchRequest: NSFetchRequest<Post> = Post.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "accountID == %@", id as CVarArg)
        let sort = NSSortDescriptor(key: #keyPath(Post.createdAt), ascending: true)
        fetchRequest.sortDescriptors = [sort]
        fetchRequest.fetchLimit = 1
        
        do {
            var results = try? context!.fetch(fetchRequest)
            var date = results!.first!.createdAt ?? Date()
            return date.toCursor()
        }
        return Date().toCursor()
    }
}

