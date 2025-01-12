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
    
    private func getReplies(post:Post, token:String) throws -> [ApiPost] {
        let url = createRequestURL(uri:post.uri!)
        var feedRequest = URLRequest(url: url)
        let group = DispatchGroup()
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
                
                if threadResponse.thread.replies != nil {
                    let replies = threadResponse.thread.replies!
                    posts = replies.map{$0.post!}
                }
                
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
        return posts
    }
    
    private func createRequestURL(uri:String) -> URL {
        // only get one level of replies
        let url = "https://api.bsky.social/xrpc/app.bsky.feed.getPostThread?parentHeight=0&depth=1&uri=\(uri)"
        return URL(string: url)!
    }
    
    private func update(dst:inout Post, from:ApiPost) {
        let date = convertToDate(from:from.record!.createdAt!) ?? nil
        dst.createdAt = date
        dst.fetchedAt = Date()
        dst.uri = from.uri
        dst.likeCount = Int64(from.likeCount!)
        dst.replyCount = Int64(from.replyCount!)
        dst.quoteCount = Int64(from.quoteCount!)
        dst.repostCount = Int64(from.repostCount!)
        if let rootUri = from.record?.reply?.root?.uri {
            dst.rootURI = rootUri
        }
        if let parentUri = from.record?.reply?.parent?.uri {
            dst.parentURI = parentUri
        }
        dst.text = from.record!.text!
        dst.title = from.record!.embed?.external?.title!
        dst.replyTreeChecked = true
    }
    
    private func createNewReply(parent:Post, child:ApiPost) {
        var newChild = Post(context: self.context!)
        update(dst: &newChild, from: child)
        newChild.parent = parent
        newChild.rootID = parent.rootID
        parent.addToReplies(newChild)
        try? self.context?.save()
    }
    
    public func recursiveGetThread(post:Post, force:Bool, token:String) {
        let storedReplies = post.replies?.allObjects as? [Post] ?? []
        let uris = storedReplies.map{$0.uri!}
        
        if let replies = try? getReplies(post:post, token:token) {
            for reply in replies {
                if force == false { // only create new replies
                    if uris.contains(reply.uri!) { // already in the list
                        continue
                    }
                    createNewReply(parent:post, child:reply)
                } else {
                    if uris.contains(reply.uri!) { // already in the list
                        var oldPost = storedReplies.first(where:{$0.uri! == reply.uri!})!
                        update(dst: &oldPost, from: reply)
                    } else {
                        createNewReply(parent:post, child:reply)
                    }
                }
                try? self.context!.save()
            }
        }
        
        if let replies = post.replies?.allObjects as? [Post] {
            for reply in replies {
                recursiveGetThread(post:reply, force:force, token:token)
            }
        }
        
        post.replyTreeChecked = true
        try? self.context!.save()
    }
    
    
    
    public func runFor(did:String, progress: @escaping (Double) -> Void) throws {
        if self.context == nil {
            print("No context set")
            return
        }
        
        if let account = try getAccount(did:did, context:self.context!) {
            if let token = getToken() {
                runFor(account:account, token:token, progress:progress)
            }
        }
    }
    
    public func runFor(account:Account, token:String, progress: @escaping (Double) -> Void) {
        
        let force = account.forceReplyTreeUpdate
        let startAt = account.startAt
        
        let postsSet = account.posts as? Set<Post> ?? Set()
        var posts = Array(postsSet)
        
        if startAt != nil && force == false {
            posts = posts.filter{ $0.createdAt! >= startAt! && $0.rootURI == nil && $0.replyTreeChecked != true}
        } else if force == true && startAt != nil {
            posts = posts.filter{ $0.createdAt! >= startAt! && $0.rootURI == nil}
        } else if force == false && startAt == nil {
            posts = posts.filter{ $0.rootURI == nil && $0.replyTreeChecked != true}
        } else {
            posts = posts.filter{ $0.rootURI == nil}
        }
        
        
        print("Reply tree running on \(posts.count) posts")
        var n : Double = 0.0
        let count : Double = Double(posts.count)
        
        for post in posts {
            n = n + 1
            progress(n/count)
            recursiveGetThread(post:post, force:force, token:token)
        }
        account.timestampReplyTrees = Date()
        try? self.context!.save()
    }
}

//                let date = convertToDate(from:p.record!.createdAt!) ?? nil
//                post.createdAt = date
//                post.fetchedAt = Date()
//                post.uri = p.uri
//                post.likeCount = Int64(p.likeCount!)
//                post.replyCount = Int64(p.replyCount!)
//                post.quoteCount = Int64(p.quoteCount!)
//                post.repostCount = Int64(p.repostCount!)
//                if let rootUri = p.record?.reply?.root?.uri {
//                    post.rootURI = rootUri
//                }
//                if let parentUri = p.record?.reply?.parent?.uri {
//                    post.parentURI = parentUri
//                }
//                if root != nil {
//                    post.rootID = root!.id!
//                }
//                post.text = p.record!.text!
//                post.title = p.record!.embed?.external?.title!
//                post.replyTreeChecked = true
//                
//                if root != nil {
//                    post.parent = root!
//                    root!.addToReplies(post)
//                }
// 
