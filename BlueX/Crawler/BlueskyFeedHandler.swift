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
                
                var filteredPosts = feedResponse.feed
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
                       forceUpdate:Bool = false) throws {
        
        if self.context == nil {
            print("No context set")
            return
        }
        
        let limit = 100
        let token = getToken()
        
        var cursor = Date().toCursor()
        
        while true {
            let feed = fetchFeed(for:did, token: token!, limit: limit, cursor:cursor)
            
            if feed == nil {
                break
            }
            
            for FeedItem in feed!.feed {
                
                let date = convertToDate(from:FeedItem.post.record!.createdAt!) ?? nil
                
                if date == nil || date! < earliestDate! {
                    continue
                }
                    
                let post = getPost(uri: FeedItem.post.uri!, context: self.context!)
                let account = try getAccount(did:did, context: self.context!)!
                
                post.accountID = account.id
                post.createdAt = date!
                post.fetchedAt = Date()
                post.uri = FeedItem.post.uri
                post.likeCount = Int64(FeedItem.post.likeCount!)
                post.replyCount = Int64(FeedItem.post.replyCount!)
                post.quoteCount = Int64(FeedItem.post.quoteCount!)
                post.repostCount = Int64(FeedItem.post.repostCount!)
                post.text = FeedItem.post.record!.text!
                post.title = FeedItem.post.record!.embed?.external?.title!
                
                try self.context!.save()
 
            }
            
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
        }
    }
}

