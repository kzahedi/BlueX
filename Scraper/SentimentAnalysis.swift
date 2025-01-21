//
//  SentimentAnalysis.swift
//  Bluesent
//
//  Created by Keyan Ghazi-Zahedi on 25.12.24.
//

import Foundation
import NaturalLanguage
import CoreData
import Progress


struct SentimentAnalysis {
    
    let context = CliPersistenceController.shared.container.viewContext
    let accountHandler : AccountHandler = AccountHandler.shared
    
    public func calculateSentiments(tool:SentimentAnalysisTool = .NLTagger, batchSize:Int = 100) {
        
        print("Running sentiment analysis")
        
        for account in accountHandler.accounts {
            if account.isActive == false { continue }
            
            checkForSentimentRecalculation(account: account, tool:tool, batchSize: batchSize)
        }
    }
    
    private func checkForSentimentRecalculation(account : Account, tool : SentimentAnalysisTool, batchSize:Int) {
        
        var taggerFunction : ((Post) -> Void)? = nil
        switch tool {
            case .NLTagger: taggerFunction = calculateSentimentNLTagger
        }
        
        let fetchRequest: NSFetchRequest<Post> = Post.fetchRequest()
        fetchRequest.predicate = NSPredicate(
            format: "account == %@ AND rootURI == nil AND (sentiments.@count == 0 OR (NOT (ANY sentiments.tool == %@)) )",
            account,
            tool.stringValue as CVarArg
        )
        printPredicate(fetchRequest.predicate!)
        let count = try! context.count(for: fetchRequest)
        print("Found \(count) posts to scrape")
        var bar = ProgressBar(count: count)
        
        while true {
            let batch = getBatch(account:account, tool:tool, batchSize:batchSize)
            for post in batch {
                bar.next()
                recursiveCalculateSentiment(post:post, tagger:taggerFunction!)
            }
        }
        
        account.timestampSentiment = Date()
            
        try? context.save()
        print("Done with sentiment analysis")
    }
    
   
    private func getBatch(account:Account, tool:SentimentAnalysisTool, batchSize:Int) -> [Post] {
        let fetchRequest: NSFetchRequest<Post> = Post.fetchRequest()
        fetchRequest.predicate = NSPredicate(
            format: "account == %@ AND rootURI == nil AND (sentiments.@count == 0 OR (NOT (ANY sentiments.tool == %@)) )",
            account,
            tool.stringValue as CVarArg
        )
        fetchRequest.fetchLimit = batchSize
        
        do {
            return try context.fetch(fetchRequest)
        } catch {
            return []
        }
    }
    
    private func checkForSentiment(post:Post, tool:SentimentAnalysisTool) -> Bool {
        let s = post.sentiments as? Set<Sentiment> ?? Set()
        let sArray = Array(s)
        return sArray.filter{$0.tool == tool.stringValue}.count > 0
    }
    
    
    private func recursiveCalculateSentiment(post:Post, tagger:(Post)->Void) {
        tagger(post)
        if let posts = post.replies?.allObjects as? [Post] {
            for post in posts {
                tagger(post)
                recursiveCalculateSentiment(post: post, tagger: tagger)
            }
        }
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
                        try? self.context.save()
                    } else {
                        let sentiment = Sentiment(context: self.context)
                        sentiment.id = UUID()
                        sentiment.score = score!
                        sentiment.tool = SentimentAnalysisTool.NLTagger.stringValue
                        sentiment.post = post
                        post.addToSentiments(sentiment)
                        try? self.context.save()
                    }
                }
            }
        }
    }
    
 
}

