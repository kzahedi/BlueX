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

    public func runFor(did:String, tool: SentimentAnalysisTool, update:Bool = true, progress: @escaping (Double) -> Void) {
        
        print("Running sentiment analysis")
        do {
            let posts = try fetchPostsWithoutMatchingSentiments(toolValue: tool.stringValue)
            let count = Double(posts.count)
            print("Running on \(Int(count)) posts")
            
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
            let account = try getAccount(did:did, context:context!)
            if account != nil {
                account!.timestampSentiment = Date()
            }
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
                let sentiment = Sentiment(context: self.context!)
                sentiment.postID = post.id!
                sentiment.id = UUID()
                sentiment.score = score!
                sentiment.tool = SentimentAnalysisTool.NLTagger.stringValue
                sentiment.post = post
                try? self.context!.save()
            }
        }
    }
    
    func fetchPostsWithoutMatchingSentiments(toolValue: String) throws -> [Post] {
        // Create a fetch request for the Post entity
        let fetchRequest: NSFetchRequest<Post> = Post.fetchRequest()
        
        // Predicate: Select posts that do not have any sentiment with the specified tool and matching postID
        fetchRequest.predicate = NSPredicate(format: "NOT (SUBQUERY(sentiments, $s, $s.postID == id AND $s.tool == %@).@count > 0)", toolValue)
        
        // Execute the fetch request
        return try self.context!.fetch(fetchRequest)
    }
    
    func fetchPost(by uuid: UUID, context: NSManagedObjectContext) throws -> Post? {
        let fetchRequest: NSFetchRequest<Post> = Post.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", uuid as CVarArg)
        fetchRequest.fetchLimit = 1
        return try context.fetch(fetchRequest).first
    }
    
    func fetchSentiment(by uuid: UUID, context: NSManagedObjectContext) throws -> Sentiment? {
        let fetchRequest: NSFetchRequest<Sentiment> = Sentiment.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", uuid as CVarArg)
        fetchRequest.fetchLimit = 1
        return try context.fetch(fetchRequest).first
    }

}

