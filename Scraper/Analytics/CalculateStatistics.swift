//
//  Statistics.swift
//  Bluesent
//
//  Created by Keyan Ghazi-Zahedi on 28.12.24.
//

import Foundation
import NaturalLanguage
import CoreData
import Progress

struct CalculateStatistics {
    
    let context = CliPersistenceController.shared.container.viewContext
    let accountHandler : AccountHandler = AccountHandler.shared
    let predicatFormat = "account == %@ AND rootURI == nil AND statistics == nil"

    func calculateStatisticsForAllActiveAccounts(batchSize:Int = 100) {
        for account in accountHandler.accounts {
            if account.isActive == false { continue }
            calculateFor(account:account, batchSize: batchSize)
        }
    }
    
    func calculateFor(account: Account, batchSize:Int) {
        print("Running for account \(account.displayName!)")
        let fetchRequest: NSFetchRequest<Post> = Post.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: predicatFormat, account)
        let count = try! context.count(for: fetchRequest)
        print("Found \(count) posts to scrape")
        var bar = ProgressBar(count: count)
        
        
        while true {
            let batch = getBatch(account:account, batchSize:batchSize)
            if batch.count == 0 { break }
            for post in batch {
                bar.next()
                recursiveCalculateStatistics(post: post)
            }
        }
        
        account.timestampStatistics = Date()
        
        try? context.save()
        print("Done with sentiment analysis")
    }
    
    private func getBatch(account:Account, batchSize:Int) -> [Post] {
        let fetchRequest: NSFetchRequest<Post> = Post.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: predicatFormat, account)
        fetchRequest.fetchLimit = batchSize
        
        do {
            return try context.fetch(fetchRequest)
        } catch {
            return []
        }
    }

    private func recursiveCalculateStatistics(post:Post) {
        let stats = post.statistics ?? Statistics(context: self.context)
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
        try? self.context.save()
        
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
        let posts = try self.context.fetch(fetchRequest)
        return Int64(posts.count)
    }
    
    private func countReplyTreeDepth(post:Post) -> Int64 {
        
        if let repliesSet = post.replies as? Set<Post> {
            let replies = Array(repliesSet)
            
            var maxDepth:Int64 = -1
            for post in replies {
                let d = countReplyTreeDepth(post: post)
                if post.statistics == nil {
                    let stats = Statistics(context: self.context)
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

