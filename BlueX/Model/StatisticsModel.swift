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

class StatisticsModel: ObservableObject {
    @Published var displayName: String
    @Published var handle: String
    @Published var did: String
    @Published var timestampFeed: String
    @Published var postsPerDay: [CountsPerDay<Int>]
    @Published var repliesPerDay: [CountsPerDay<Int>]
    @Published var replyTreeDepthPerDay: [CountsPerDay<Double>]
    @Published var sentimentPosts: [CountsPerDay<Double>]
    @Published var sentimentReplies: [CountsPerDay<Double>]
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
        self.replyTreeDepthPerDay = []
        self.sentimentPosts = []
        self.sentimentReplies = []
        self.xMin = account.startAt ?? Date()
        self.xMax = Date()
        
        self.updateDataPoints()
    }
    
    func updateDataPoints() {
        let fetchRequest: NSFetchRequest<Post> = Post.fetchRequest()
        fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "accountID == %@", account.id! as CVarArg),
            NSPredicate(format: "rootID == nil"),
            NSPredicate(format: "createdAt >= %@", account.startAt! as NSDate)
        ])
        
        do {
            let posts = try context.fetch(fetchRequest)
            
            // Use Calendar to group posts by day (ignoring time of day)
            let postCollection : [Date:[Post]] = Dictionary(grouping: posts) { post in
                guard let timestamp = post.createdAt else {
                    return Date.distantPast // Fallback for invalid timestamps
                }
                return Calendar.current.startOfDay(for: timestamp)
            }
            
            let sentimentCollection: [Date: [Sentiment]] = Dictionary(grouping: posts.compactMap { post -> (Date, Sentiment)? in
                guard
                    let createdAt = post.createdAt,
                    let sentiments = post.sentiments as? Set<Sentiment>,
                    let firstSentiment = sentiments.first(where: { $0.tool == SentimentAnalysisTool.NLTagger.stringValue })
                else {
                    return nil // Skip posts with missing data
                }
                
                let day = Calendar.current.startOfDay(for: createdAt)
                return (day, firstSentiment)
            }) { $0.0 }
                .mapValues { $0.map { $0.1 } } // Strip keys in the array
            
            let sentimentRepliesCollection: [Date: Double] = getAvgSentimentOverAllReplies(postCollection:postCollection)
            
            // Map to PostStatsDataPoint
            self.postsPerDay = postCollection.map { (day, posts) in
                CountsPerDay(day: day, count: posts.count)
            }.sorted { $0.day < $1.day } // Sort by day
            
            self.repliesPerDay = postCollection.map { (day, posts) in
                CountsPerDay(day: day, count: sum(posts:posts, field:\.statistics!.countedAllReplies))
            }.sorted { $0.day < $1.day } // Sort by day
            
            self.replyTreeDepthPerDay = postCollection.map { (day, posts) in
                CountsPerDay(day: day, count: mean(posts:posts, field:\.statistics!.replyTreeDepth))
            }.sorted { $0.day < $1.day } // Sort by day
            
            self.sentimentPosts = sentimentCollection.map { (day, sentiments) in
                CountsPerDay(day: day, count: mean(sentiments:sentiments, field:\.score))
            }.sorted { $0.day < $1.day } // Sort by day
            
            self.sentimentReplies = sentimentRepliesCollection.map { (day, avgSentiment) in
                CountsPerDay(day: day, count: avgSentiment)
            }.sorted { $0.day < $1.day } // Sort by day
           
            let today = Calendar.current.startOfDay(for: Date())
            if self.postsPerDay.last == nil {
                xMax = Date()
            } else {
                xMax = self.postsPerDay.last!.day < today ? today : self.postsPerDay.last!.day
            }
            xMin = self.account.startAt == nil ?  self.postsPerDay.first!.day : self.account.startAt!
            
        } catch {
            print("Error fetching posts: \(error)")
            self.postsPerDay = []
            self.repliesPerDay = []
        }
    }
    
    private func sum(posts: [Post], field: KeyPath<Post, Int64>) -> Int {
        return Int(posts.map { $0[keyPath: field] }.reduce(0, +))
    }
    
    private func mean(posts: [Post], field: KeyPath<Post, Int64>) -> Double {
        guard !posts.isEmpty else { return 0 }
        let total = posts.map { $0[keyPath: field] }.reduce(0, +)
        return Double(total) / Double(posts.count)
    }
    
    private func mean(posts: [Post], field: KeyPath<Post, Double>) -> Double {
        guard !posts.isEmpty else { return 0 }
        let total = posts.map { $0[keyPath: field] }.reduce(0, +)
        return Double(total / Double(posts.count))
    }
    
    private func mean(sentiments: [Sentiment], field: KeyPath<Sentiment, Double>) -> Double {
        guard !sentiments.isEmpty else { return 0 }
        let total = sentiments.map { $0[keyPath: field] }.reduce(0, +)
        return Double(total / Double(sentiments.count))
    }
    
    private func getAvgSentimentOverAllReplies(postCollection:[Date:[Post]]) -> [Date: Double] {
       
        var r : [Date:Double] = [:]
        
        for (date, posts) in postCollection {
            let avgSentiment = posts.map{getAverageSentimentOverAllReplies(rootID:$0.id!)}.reduce(0, +) / Double(posts.count)
            r[date] = avgSentiment
        }
        
        return r
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
}
