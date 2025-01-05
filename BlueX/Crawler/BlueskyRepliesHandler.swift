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
    
    private func getThread(url:URL) throws -> [ApiPost] {
        var feedRequest = URLRequest(url: url)
        let group = DispatchGroup()
        var returnValue : [ApiPost] = []
        
        print("hier 0")
        feedRequest.httpMethod = "GET"
        feedRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        print("hier 1")

        group.enter()
        let feedTask = URLSession.shared.dataTask(with: feedRequest) { data, response, error in
            print("hier 2")
            if error != nil {
                print("Error fetching feed: \(error!.localizedDescription)")
                group.leave()
                
            }
            print("hier 3")

            let httpResponse = response as? HTTPURLResponse
            if httpResponse == nil {
                print("Invalid response type")
                group.leave()
            }
            print("hier 4")

            if data == nil {
                print("No data received")
                group.leave()
            }
            print("hier 5")

            do {
                if httpResponse!.statusCode == 401 {
                    throw BlueskyError.unauthorized("Invalid or expired token")
                }
                print("hier 6")

                if !(200...299).contains(httpResponse!.statusCode) {
                    throw BlueskyError.feedFetchFailed(
                        reason: "Server returned error response",
                        statusCode: httpResponse!.statusCode
                    )
                }
                
                print("hier 7")

                let threadResponse = try decodeThread(from: data!)
                print("hier 8")

//                returnValue = try writeNode(thread:reply)
                returnValue = threadResponse.thread.replies!.map{$0.post!}
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
    
    private func writeNode(thread:Thread) throws -> [String] {
        let r : [String] = []
        
        print("1001")
        let p = thread.post!
        if p.uri == currentUri {
            return []
        }
        print("1002")
        let replies = thread.replies
        print("1003")

        let post = getPost(uri: p.uri!, context: self.context!)
        print("1004")
        print(post)
        let date = convertToDate(from:p.record!.createdAt!) ?? nil
        print("1005")

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
        print("1006")
        do {
            try post.validateForInsert()
        } catch {
            print("Validation failed: \(error)")
            throw error
        }
        print("hier 1007")
        
//        try self.context!.save()
        print("1008")
        return r
    }
    
    private func createRequestURL(uri:String) -> URL {
        let url = "https://api.bsky.social/xrpc/app.bsky.feed.getPostThread?parentHeight=0&depth=1000&uri=\(uri)"
        return URL(string: url)!
    }
    
    public func recursiveGetThread(uri:String) -> [ApiPost] {
        
//        var uris : [String] = []
        let url = createRequestURL(uri:uri)
        do {
            return try getThread(url:url)

            // save elements
        } catch {
            print(error)
        }
//        for uri in uris {
//            recursiveGetThread(uri: uri, token: token, accountID: accountID)
//        }
        return []
    }
    
    
    
    public mutating func runFor(did:String,
                       earliestDate:Date? = nil,
                                forceUpdate:Bool = false) throws {
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
        
        var uris = filteredResults.map{$0.uri!}
        
        for uri in uris {
            currentUri = uri
            print("Running for \(uri)")
            let r = recursiveGetThread(uri: uri)
            for p in r {
                print("Creating \(p.uri!)")
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
    }
}
