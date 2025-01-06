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
            
            
            let posts = try fetchPostsWithoutMatchingSentiments(context:context!, toolValue: tool.stringValue)
            let count = Double(posts.count)
            
            var taggerFunction : ((inout Post) -> Void)? = nil
            
            switch tool {
                case .NLTagger: taggerFunction = calculateSentimentNLTagger
            }
            
            var index : Double = 0.0
            for var post in posts {
                DispatchQueue.background(delay: 0.0,
                                         background: {taggerFunction!(&post)},
                                         completion: {
                    index = index + 1
                    progress(index/count)
                })
            }
            try context!.save()
        } catch {
            print(error)
        }
        
        print("Done with sentiment analysis")
    }
    
    private func calculateSentimentNLTagger(post: inout Post) -> Void {
        let tagger = NLTagger(tagSchemes: [.sentimentScore])
        var text = post.text!
        text = text.replacingOccurrences(of: "\\r?\\n", with: "", options: .regularExpression)
        tagger.string = text
        let sentimentScore = tagger.tag(at: text.startIndex, unit: .paragraph, scheme: .sentimentScore)
        if sentimentScore.0 != nil {
            let score = Double(sentimentScore.0!.rawValue)
            if score != nil {
                let sentiment = Sentiment(context: self.context!)
                sentiment.post = post
                sentiment.postID = post.id!
                sentiment.id = UUID()
                sentiment.score = score!
                sentiment.tool = SentimentAnalysisTool.NLTagger.stringValue
                post.addToSentiments(sentiment)
            }
        }
    }
    
    func fetchPostsWithoutMatchingSentiments(context: NSManagedObjectContext, toolValue: String) throws -> [Post] {
        // Create a fetch request for the Post entity
        let fetchRequest: NSFetchRequest<Post> = Post.fetchRequest()
        
        // Predicate: Select posts that do not have any sentiment with the specified tool and matching postID
        fetchRequest.predicate = NSPredicate(format: "NOT (SUBQUERY(sentiments, $s, $s.postID == id AND $s.tool == %@).@count > 0)", toolValue)
        
        // Execute the fetch request
        return try context.fetch(fetchRequest)
    }
}

