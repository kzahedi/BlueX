//
//  HTTPRequests.swift
//  Bluesent
//
//  Created by Keyan Ghazi-Zahedi on 25.12.24.
//
import Foundation
import CoreData

struct BlueskyRepliesHandler {
    var context : NSManagedObjectContext? = nil
    var token : String = ""
    var accountID : UUID = UUID()
    var currentUri : String = ""
    
    private func getThread(url:URL) throws -> ([String], [ApiPost]) {
        var feedRequest = URLRequest(url: url)
        let group = DispatchGroup()
        var uris : [String] = []
        var posts : [ApiPost] = []
        
        feedRequest.httpMethod = "GET"
        feedRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
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
                
                
                let threadResponse = try decodeThread(from: data!)
                let (u, p) = recursiveParseThread(thread: threadResponse.thread)
                uris = u
                posts = p
                
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
        return (uris, posts)
    }
    
    func recursiveParseThread(thread:Thread) -> ([String], [ApiPost]) {
        var uris : [String] = []
        var posts : [ApiPost] = []
        
        // check all leafs again
        if let replies = thread.replies {
            for reply in replies {
                if reply.replies == nil || reply.replies!.isEmpty {
                    if reply.post != nil && reply.post!.uri != nil {
                        uris.append(reply.post!.uri!)
                    }
                }
            }
            
            posts += thread.replies!.map{$0.post!}
            for repply in thread.replies! {
                if let replies = repply.replies {
                    for reply in replies {
                        let (u, p) = recursiveParseThread(thread:reply)
                        uris = uris + u
                        posts = posts + p
                    }
                }
            }
        }
        
        return (uris, posts)
        
    }
    
    
    
    private func createRequestURL(uri:String) -> URL {
        let url = "https://api.bsky.social/xrpc/app.bsky.feed.getPostThread?parentHeight=0&depth=1000&uri=\(uri)"
        return URL(string: url)!
    }
    
    public func recursiveGetThread(uri:String) -> [ApiPost] {
        
        var uris : [String] = []
        var posts : [ApiPost] = []
        let url = createRequestURL(uri:uri)
        do {
            (uris, posts) = try getThread(url:url)
        } catch {
            print(error)
        }
        for uri in uris {
            let p = recursiveGetThread(uri: uri)
            posts = posts + p
        }
        
        return posts
    }
    
    
    
    public mutating func runFor(did:String,
                                earliestDate:Date? = nil,
                                forceUpdate:Bool = false,
                                progress: @escaping (Double) -> Void) throws {
        if self.context == nil {
            print("No context set")
            return
        }
        
        let account = try getAccount(did:did, context:self.context!)
        
        if account == nil {
            print("Cannot find account")
            return
        }
        
        self.accountID = account!.id!
        
        let fetchRequest: NSFetchRequest<Post> = Post.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "accountID == %@ AND createdAt >= %@",
                                             account!.id! as CVarArg, earliestDate! as NSDate)
        
        let results = try self.context!.fetch(fetchRequest)
        self.token = getToken()!
        
        print("Found \(results.count) posts")
        
        var filteredResults = results.filter{$0.createdAt! >= earliestDate! || forceUpdate}
        
        if forceUpdate == false {
            // Step 1: Collect all parentIDs
            let parentURIs = Set(filteredResults.compactMap { $0.parentURI })
            
            // Step 2: Filter posts whose id is not in the set of parentIDs
            // If there is a post, that is the parent of another post, remove it
            filteredResults = filteredResults.filter { !parentURIs.contains($0.uri!) }
        }
        
        let uris = filteredResults.map{$0.uri!}
        
        var n : Double = 0.0
        let count : Double = Double(uris.count)
        
        for uri in uris {
            n = n + 1
            progress(n/count)
            currentUri = uri
            //            print("Running for \(uri)")
            let r = recursiveGetThread(uri: uri)
            for p in r {
                //                print("Creating \(p.uri!)")
                let post = getPost(uri: p.uri!, context: self.context!)
                let date = convertToDate(from:p.record!.createdAt!) ?? nil
                post.accountID = accountID
                post.createdAt = date
                post.fetchedAt = Date()
                post.uri = p.uri
                post.likeCount = Int64(p.likeCount!)
                post.replyCount = Int64(p.replyCount!)
                post.quoteCount = Int64(p.quoteCount!)
                post.repostCount = Int64(p.repostCount!)
                post.parentURI = p.record!.reply!.parent!.uri!
                post.rootURI = p.record!.reply!.root!.uri!
                post.text = p.record!.text!
                post.title = p.record!.embed?.external?.title!
            }
            try self.context!.save()
        }
        account!.timestampReplyTrees = Date()
        try self.context!.save()
    }
}
