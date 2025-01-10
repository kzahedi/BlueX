//
//  Statistics.swift
//  Bluesent
//
//  Created by Keyan Ghazi-Zahedi on 28.12.24.
//

import Foundation
import NaturalLanguage
import CoreData

struct CalculateStatistics {
    
    var context : NSManagedObjectContext? = nil
    
    public func runFor(did: String, progress: @escaping (Double) -> Void) throws {
        
        print("Counting replies per post")
        var n : Double = 0.0
        
        let account = try getAccount(did: did, context: self.context!)
        if account == nil {
            return
        }
        let allNodes = try getAllNodes(accountID:account!.id!)
        let count = Double(allNodes.count)
        
        print("Found \(allNodes.count) root nodes")
        
        
        for post in allNodes {
            let stats = Statistics(context: context!)
            
            stats.post = post
            post.statistics = stats
            
            if post.rootID == nil { stats.countedAllReplies = try! countAllReplies(post:post) }
            stats.replyTreeDepth = try! countReplyTreeDepth(post:post)
            n = n + 1
            progress(n/count)
        }
        account!.timestampStatistics = Date()
        
        try self.context!.save()

        print("Done with counting replies")
    }
    
    
    func getAllNodes(accountID:UUID) throws -> [Post] {
        let fetchRequest: NSFetchRequest<Post> = Post.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "accountID == %@", accountID as CVarArg)
        let results = try self.context!.fetch(fetchRequest)
        return results
    }
    
    func countAllReplies(post:Post) throws -> Int64 {
        if let repliesSet = post.replies as? Set<Post> {
            let replies = Array(repliesSet)
            return Int64(replies.count)
        }
        return Int64(0)
    }
    
    func countRepliesForNode(uri:String) throws -> Int64 {
        let fetchRequest: NSFetchRequest<Post> = Post.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "parentURI == %@", uri as CVarArg)
        let posts = try self.context!.fetch(fetchRequest)
        return Int64(posts.count)
    }
    
    func countReplyTreeDepth(post:Post) throws -> Int64 {
        
        if let repliesSet = post.replies as? Set<Post> {
            let replies = Array(repliesSet)
            
            var maxDepth:Int64 = 0
            for post in replies {
                let d = try countReplyTreeDepth(post: post)
                if post.statistics == nil {
                    let stats = Statistics(context: self.context!)
                    post.statistics = stats
                    stats.post = post
                }
                post.statistics!.replyTreeDepth = d
                if d > maxDepth { maxDepth = d }
            }
            return maxDepth + 1
        }
        return 0
    }

    
}

