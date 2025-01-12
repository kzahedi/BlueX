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
    
    public func runFor(did: String, progress: @escaping (Double) -> Void) {
        
        print("Counting replies per post")
        
        let account = try? getAccount(did: did, context: self.context!)
        if account == nil {
            return
        }
        
        runFor(account:account!, progress:progress)
    }
    
    func runFor(account: Account, progress: @escaping (Double) -> Void) {
        var n : Double = 0.0
        print("Running for account \(account.displayName!)")
        if let nodes = account.posts?.allObjects as? [Post] {
            let count = Double(nodes.count)
            print("Found \(nodes.count) root nodes")
            for post in nodes {
                recursiveCalculateStatistics(post:post)
                n = n + 1
                progress(n/count)
            }
        }
        account.timestampStatistics = Date()
        try? self.context!.save()
        print("Done with counting replies")
    }
    
    private func recursiveCalculateStatistics(post:Post) {
        let stats = post.statistics ?? Statistics(context: self.context!)
        post.statistics = stats
        stats.post = post
        stats.countedAllReplies = countAllReplies(post:post)
        stats.replyTreeDepth = countReplyTreeDepth(post:post)
        let sentiments = collectSentiments(post:post)
        if sentiments.count == 0 {
            stats.avgSentimentReplies = 0.0
        } else {
            stats.avgSentimentReplies = sentiments.reduce(0.0, +) / Double(sentiments.count)
        }
        print("Sentiment replies: \(stats.avgSentimentReplies)")
        try? self.context!.save()
        
        if let replies = post.replies?.allObjects as? [Post] {
            for reply in replies {
                recursiveCalculateStatistics(post:reply)
            }
        }
    }
    
    private func countAllReplies(post:Post) -> Int64 {
        if let repliesSet = post.replies as? Set<Post> {
            let replies = Array(repliesSet)
            return Int64(replies.count)
        }
        return Int64(0)
    }
    
    private func countRepliesForNode(uri:String) throws -> Int64 {
        let fetchRequest: NSFetchRequest<Post> = Post.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "parentURI == %@", uri as CVarArg)
        let posts = try self.context!.fetch(fetchRequest)
        return Int64(posts.count)
    }
    
    private func countReplyTreeDepth(post:Post) -> Int64 {
        
        if let repliesSet = post.replies as? Set<Post> {
            let replies = Array(repliesSet)
            
            var maxDepth:Int64 = -1
            for post in replies {
                let d = countReplyTreeDepth(post: post)
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
        return -1
    }

    private func collectSentiments(post:Post) -> [Double] {
        var values : [Double] = []
        if let replies = post.replies as? Set<Post> {
            values = replies.map{getSentimentScore(post: $0, tool: .NLTagger)}
            for reply in replies {
                values += collectSentiments(post: reply)
            }
        }
        return values
    }
}

