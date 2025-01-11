//
//  SentimentAnalysis.swift
//  Bluesent
//
//  Created by Keyan Ghazi-Zahedi on 25.12.24.
//

import Foundation
import NaturalLanguage
import CoreData

public enum SentimentAnalysisTool : Decodable, CaseIterable {
    case NLTagger
    
    enum CodingKeys : String, CodingKey {
        case NLTagger = "NLTagger"
    }
    
    // Computed property to get the string value
    var stringValue: String {
        switch self {
            case .NLTagger:
                return CodingKeys.NLTagger.rawValue
        }
    }
}

struct SentimentAnalysis {
    
    var context : NSManagedObjectContext? = nil

    public func runFor(did:String, tool: SentimentAnalysisTool, progress: @escaping (Double) -> Void) {
        if let account = try? getAccount(did:did, context:context!) {
            runFor(account:account, tool:tool, progress:progress)
        }
    }
    
    public func runFor(account:Account, tool: SentimentAnalysisTool, progress: @escaping (Double) -> Void) {
        
        let force = account.forceSentimentUpdate
        
        print("Running sentiment analysis")
        do {
            let fetchRequest: NSFetchRequest<Post> = Post.fetchRequest()
            var posts = try self.context!.fetch(fetchRequest)
            
            posts = posts.filter { post in
                post.sentiments?.contains { (sentiment: Sentiment) in
                    sentiment.tool != tool.stringValue
                } ?? force
            }
            
            print("Running on \(posts.count) posts")
            
            let count = Double(posts.count)
            var taggerFunction : ((Post) -> Void)? = nil
            
            switch tool {
                case .NLTagger: taggerFunction = calculateSentimentNLTagger
            }
            
            var index : Double = 0.0
            for post in posts {
                taggerFunction!(post)
                index = index + 1
                progress(index/count)
            }
            account.timestampSentiment = Date()
            
        } catch {
            print(error)
        }
        try? context!.save()
        print("Done with sentiment analysis")
    }
    
    private func calculateSentimentNLTagger(post: Post) -> Void {
        let tagger = NLTagger(tagSchemes: [.sentimentScore])
        if post.text == nil {
            return
        }
        var text = post.text!
        text = text.replacingOccurrences(of: "\\r?\\n", with: "", options: .regularExpression)
        tagger.string = text
        let sentimentScore = tagger.tag(at: text.startIndex, unit: .paragraph, scheme: .sentimentScore)
        if sentimentScore.0 != nil {
            let score = Double(sentimentScore.0!.rawValue)
            if score != nil {
                if let sentimentsSet = post.sentiments as? Set<Sentiment> {
                    let sentiments = Array(sentimentsSet)
                    if let sentiment = sentiments.filter({$0.tool == SentimentAnalysisTool.NLTagger.stringValue }).first {
                        sentiment.score = score!
                        try? self.context!.save()
                    } else {
                        let sentiment = Sentiment(context: self.context!)
                        sentiment.id = UUID()
                        sentiment.score = score!
                        sentiment.tool = SentimentAnalysisTool.NLTagger.stringValue
                        sentiment.post = post
                        post.addToSentiments(sentiment)
                        try? self.context!.save()
                    }
                }
            }
        }
    }
    
    func fetchPostsWithoutMatchingSentiments(toolName: String, force:Bool) throws -> [Post] {
        // Create a fetch request for the Post entity
        let fetchRequest: NSFetchRequest<Post> = Post.fetchRequest()
        
        // Predicate: Select posts that do not have any sentiment with the specified tool and matching postID
        if force == false {
            fetchRequest.predicate = NSPredicate(format: "NOT (SUBQUERY(sentiments, $s, $s.postID == id AND $s.tool == %@).@count > 0)", toolName)
        }
        
        // Execute the fetch request
        return try self.context!.fetch(fetchRequest)
    }
}

