//
//  AccountViewModel.swift
//  BlueX
//
//  Created by Keyan Ghazi-Zahedi on 07.01.25.
//

import Foundation
import SwiftUI
import CoreData

struct CountsPerDay<T: Codable> : Codable, Identifiable {
    var id : UUID = UUID()
    var day: Date
    var count: T
}

struct DataPoint: Identifiable {
    let id = UUID()
    var date: Date
    var plotValue: Int
    var series: String
}

class StatisticsModel: ObservableObject {
    @Published var displayName: String
    @Published var handle: String
    @Published var did: String
    @Published var timestampFeed: String
    @Published var postsPerDay: [CountsPerDay<Int>]
    @Published var repliesPerDay: [CountsPerDay<Int>]
    @Published var avgRepliesPerDay: [CountsPerDay<Double>]
    @Published var maxRepliesPerDay: [CountsPerDay<Int>]
    @Published var replyTreeDepthPerDay: [CountsPerDay<Double>]
    @Published var maxReplyTreeDepthPerDay: [CountsPerDay<Int>]
    @Published var sentimentPosts: [CountsPerDay<Double>]
    @Published var sentimentReplies: [CountsPerDay<Double>]
    @Published var plotsRepliesDataPoints: [DataPoint]
    @Published var xMin: Date
    @Published var xMax: Date
    
    let account: Account
    let context: NSManagedObjectContext
    
    init(account: Account, context: NSManagedObjectContext? = nil) {
        self.account = account
        self.context = context ?? PersistenceController.shared.container.viewContext
        
        
        // Initialize ViewModel properties from CoreData model
        self.displayName = account.displayName ?? ""
        self.handle = account.handle ?? ""
        self.did = account.did ?? ""
        self.timestampFeed = ""
        self.postsPerDay = []
        self.repliesPerDay = []
        self.avgRepliesPerDay = []
        self.maxRepliesPerDay = []
        self.replyTreeDepthPerDay = []
        self.maxReplyTreeDepthPerDay = []
        self.sentimentPosts = []
        self.sentimentReplies = []
        self.xMin = account.startAt ?? Date()
        self.xMax = Date()
        
        self.plotsRepliesDataPoints = []
        
        self.updateDataPoints()
    }
    
    
    private func getRecursivePosts(from:Post) -> [Post] {
        var r : [Post] = []
        if let replies = from.replies?.allObjects as? [Post] {
            r = r + replies
            for reply in replies {
                let rr = getRecursivePosts(from:reply)
                r = r + rr
            }
        }
        return r
    }

    private func getAllPostsFrom(account:Account) -> [Post] {
        var r : [Post] = []
        if let posts = account.posts?.allObjects as? [Post] {
            for post in posts {
                let p = getRecursivePosts(from:post)
                r = r + p
            }
            r = r + posts
        }
        return r
    }
    
    func updateDataPoints() {
        
        let posts = getAllPostsFrom(account:account)
        print("Count posts: \(posts.count)")
        
        // Use Calendar to group posts by day (ignoring time of day)
        let postCollection : [Date:[Post]] = Dictionary(grouping: posts) { post in
            guard let timestamp = post.createdAt else {
                return Date.distantPast // Fallback for invalid timestamps
            }
            return Calendar.current.startOfDay(for: timestamp)
        }
        
        let sentimentCollection: [Date: [Sentiment]] = getSentiments(collection:postCollection, tool: .NLTagger)
        
        // Map to PostStatsDataPoint
        self.postsPerDay = postCollection.map { (day, posts) in
            CountsPerDay(day: day, count: posts.count)
        }.sorted { $0.day < $1.day } // Sort by day
        
        self.repliesPerDay = postCollection.map { (day, posts) in
            CountsPerDay(day: day, count: sum(posts:posts, field:\.statistics?.countedAllReplies))
        }.sorted { $0.day < $1.day } // Sort by day
        
        self.avgRepliesPerDay = postCollection.map { (day, posts) in
            CountsPerDay(day: day, count: mean(posts:posts, field:\.statistics?.countedAllReplies))
        }.sorted { $0.day < $1.day } // Sort by day
        
        self.maxRepliesPerDay = postCollection.map { (day, posts) in
            CountsPerDay(day: day, count: max(posts:posts, field:\.statistics?.countedAllReplies))
        }.sorted { $0.day < $1.day } // Sort by day
        
        self.replyTreeDepthPerDay = postCollection.map { (day, posts) in
            CountsPerDay(day: day, count: mean(posts:posts, field:\.statistics?.replyTreeDepth))
        }.sorted { $0.day < $1.day } // Sort by day
        
        self.maxReplyTreeDepthPerDay = postCollection.map { (day, posts) in
            CountsPerDay(day: day, count: max(posts:posts, field:\.statistics?.replyTreeDepth))
        }.sorted { $0.day < $1.day } // Sort by day
        
        self.sentimentPosts = sentimentCollection.map { (day, sentiments) in
            CountsPerDay(day: day, count: mean(sentiments:sentiments, field:\.score))
        }.sorted { $0.day < $1.day } // Sort by day
        
        self.sentimentReplies = postCollection.map { (day, posts) in
            CountsPerDay(day: day, count: mean(posts:posts, field:\.statistics?.avgSentimentReplies))
        }.sorted { $0.day < $1.day } // Sort by day
        
        self.plotsRepliesDataPoints = []
        for dayCount in postsPerDay {
            let dp = DataPoint(date: dayCount.day, plotValue: dayCount.count, series: "Posts per Day")
            self.plotsRepliesDataPoints.append(dp)
        }
        for dayCount in repliesPerDay {
            let dp = DataPoint(date: dayCount.day, plotValue: dayCount.count, series: "Replies per Day")
            self.plotsRepliesDataPoints.append(dp)
        }
        
        let today = Date()
        if self.postsPerDay.last == nil {
            xMax = Date()
        } else {
            xMax = self.postsPerDay.last!.day < today ? today : self.postsPerDay.last!.day
        }
        xMin = self.account.startAt == nil ?  self.postsPerDay.first!.day : self.account.startAt!
    }
    
    private func sum(posts: [Post], field: KeyPath<Post, Int64?>) -> Int {
        return posts
            .compactMap { $0[keyPath: field] } // Unwrap optional Int64
            .reduce(0, { $0 + Int($1) }) // Convert Int64 to Int and sum
    }
    
    private func max(posts: [Post], field: KeyPath<Post, Int64?>) -> Int {
        return Int(posts
            .compactMap { $0[keyPath: field] } // Unwrap optional Int64
            .max()!)
    }
    
    private func mean(posts: [Post], field: KeyPath<Post, Int64?>) -> Double {
        guard !posts.isEmpty else { return 0 }
        
        let total = posts
            .compactMap { $0[keyPath: field] } // Unwrap optional Int64?
            .reduce(0, { $0 + $1 }) // Sum the values (Int64?)
        
        return total > 0 ? Double(total) / Double(posts.count) : 0
    }
    
    private func mean(posts: [Post], field: KeyPath<Post, Double?>) -> Double {
        guard !posts.isEmpty else { return 0.0 }
        let total = posts
            .compactMap { $0[keyPath: field] } // Unwrap optional Int64?
            .reduce(0, { $0 + $1 }) // Sum the values (Int64?)
        
        
        return Double(total) / Double(posts.count)
    }
    
    private func mean(sentiments: [Sentiment], field: KeyPath<Sentiment, Double>) -> Double {
        guard !sentiments.isEmpty else { return 0 }
        let total = sentiments.map { $0[keyPath: field] }.reduce(0, +)
        return Double(total / Double(sentiments.count))
    }
    
   
    func getAverageSentimentOverAllReplies(rootID: UUID) -> Double {
        print("Working on \(rootID)")
        // Fetch posts with matching rootID
        let postFetchRequest: NSFetchRequest<Post> = Post.fetchRequest()
                postFetchRequest.predicate = NSPredicate(format: "rootID == %@", rootID as CVarArg)
        
        // Execute fetch request
        do {
            let posts = try context.fetch(postFetchRequest)
            
            // Initialize an array to hold the matching sentiments
            var matchingSentiments: [Sentiment] = []
            
            // For each post, fetch sentiments where tool is "NLTagger"
            for post in posts {
                let sentimentFetchRequest: NSFetchRequest<Sentiment> = Sentiment.fetchRequest()
                sentimentFetchRequest.predicate = NSPredicate(format: "postID == %@ AND tool == %@", post.id! as CVarArg, "NLTagger")
                
                // Execute sentiment fetch request
                let sentiments = try context.fetch(sentimentFetchRequest)
                matchingSentiments.append(contentsOf: sentiments)
            }
            
            return mean(sentiments:matchingSentiments, field: \.score)
            
        } catch {
            print("Failed to fetch posts or sentiments: \(error)")
            return 0.0
        }
    }
    
    private func getSentiments(collection:[Date:[Post]], tool:SentimentAnalysisTool) -> [Date:[Sentiment]] {
        var r : [Date:[Sentiment]] = [:]
        
        for (day, posts) in collection {
            if r.keys.contains(day) == false {
                r[day] = []
            }
            
            for post in posts{
                if let sentimentSet = post.sentiments as? Set<Sentiment> {
                    let sentiments = Array(sentimentSet).filter { $0.tool! == tool.stringValue }
                    r[day] = r[day]! + sentiments
                }
            }
        }
        return r
    }
}
