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
    let predicatFormatALL = "account == %@ AND rootURI == nil"

    func calculateStatisticsForAllActiveAccounts(batchSize:Int = 100) {
        for account in accountHandler.accounts {
            if account.isActive == false { continue }
            print(account)
            calculateFor(account:account, batchSize: batchSize)
        }
    }
    
    func calculateFor(account: Account, batchSize:Int = 100) {
        if let posts = account.posts as? Set<Post> {
            for post in posts {
                if post.statistics != nil {
                    context.delete(post.statistics!)
                }
            }
            try? context.save()
        }
        
        print("Calculating statistics for \(account.displayName!)")
        let fetchRequest: NSFetchRequest<Post> = Post.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: predicatFormatALL, account)
        let count = try! context.count(for: fetchRequest)
        var bar = ProgressBar(count: count)
        bar.setValue(0)
        
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
        print("Done with statistics analysis")
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
        
        if post.statistics != nil {
            context.delete(post.statistics!)
            try? context.save()
        }
        
        var totalNumberOfReplies : Int64 = 0
        var nrOfReplies : Int64 = 0
        
        if let replies = post.replies?.allObjects as? [Post] {
            nrOfReplies = Int64(replies.count)
            totalNumberOfReplies = nrOfReplies
            for reply in replies {
                recursiveCalculateStatistics(post:reply)
                totalNumberOfReplies += reply.statistics!.totalNumberOfReplies
            }
        }
        
        let stats = post.statistics ?? Statistics(context: self.context)
        post.statistics = stats
        stats.post = post
        stats.totalNumberOfReplies = totalNumberOfReplies
        stats.nrOfReplies = nrOfReplies
        stats.replyTreeDepth = collectReplyTreeDepth(post:post)
        let sentiments = collectSentiments(post:post)
        if sentiments.count == 0 {
            stats.avgSentimentReplies = 0.0
        } else {
            stats.avgSentimentReplies = sentiments.reduce(0.0, +) / Double(sentiments.count)
        }
        try? context.save()
        
    }
    
    private func countAllReplies(post:Post) -> Int64 {
        var n : Int64 = 0
        if let repliesSet = post.replies as? Set<Post> {
            n += Int64((Array(repliesSet)).count)
            for reply in repliesSet {
                n += reply.statistics!.totalNumberOfReplies 
            }
            return n
        }
        return Int64(0)
    }
    
    private func collectReplyTreeDepth(post:Post) -> Int64 {
        var depth : Int64 = 0
        if let repliesSet = post.replies as? Set<Post> {
            let replies = Array(repliesSet)
            var maxDepth:Int64 = 0
            for post in replies {
                let d = post.statistics?.replyTreeDepth ?? 0
                if d > maxDepth { maxDepth = d }
            }
            if replies.count > 0 {
                depth = maxDepth + 1
            }
        }
        return depth
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

