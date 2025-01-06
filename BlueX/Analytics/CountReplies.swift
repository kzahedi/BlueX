//
//  Statistics.swift
//  Bluesent
//
//  Created by Keyan Ghazi-Zahedi on 28.12.24.
//

import Foundation
import NaturalLanguage
import CoreData

struct CountReplies {
    
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
            n = n + 1
            progress(n/count)
            
            if post.rootID == nil {
                post.countAllReplies = try countAllReplies(rootID:post.id!)
            }
            post.replyTreeDepth = try countReplyTreeDepth(post:post)
            
            try self.context!.save()
        }
        
        print("Done with counting replies")
    }
    
    
    func getAllNodes(accountID:UUID) throws -> [Post] {
        let fetchRequest: NSFetchRequest<Post> = Post.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "accountID == %@", accountID as CVarArg)
        let results = try self.context!.fetch(fetchRequest)
        return results
    }
    
    func countAllReplies(rootID:UUID) throws -> Int64 {
        let fetchRequest: NSFetchRequest<Post> = Post.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "rootID == %@", rootID as CVarArg)
        let results = try self.context!.fetch(fetchRequest)
        return Int64(results.count)
    }
    
    func countRepliesForNode(uri:String) throws -> Int64 {
        let fetchRequest: NSFetchRequest<Post> = Post.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "parentURI == %@", uri as CVarArg)
        let posts = try self.context!.fetch(fetchRequest)
        return Int64(posts.count)
    }
    
    func countReplyTreeDepth(post:Post) throws -> Int64 {
        let replies = post.replies
        
        guard replies != nil, replies!.count > 0 else {
            return 0
        }
        
        for reply in replies! {
            let p = reply as! Post
            let depth = try countReplyTreeDepth(post:p)
            p.replyTreeDepth = depth
        }
        
        let maxDepth = (replies!.max{ ($0 as! Post).replyTreeDepth < ($1 as! Post).replyTreeDepth }! as! Post).replyTreeDepth
        return maxDepth + 1
    }

    
}

