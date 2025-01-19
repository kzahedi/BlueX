//
//  Functions.swift
//  Bluesent
//
//  Created by Keyan Ghazi-Zahedi on 26.12.24.
//

import Foundation
import CoreData





func getSentimentScore(post:Post, tool: SentimentAnalysisTool) -> Double {
    if let sentimentsSet = post.sentiments as? Set<Sentiment> {
        let sentiments = Array(sentimentsSet)
        let toolStr = tool.stringValue
        return sentiments.filter{$0.tool == toolStr}.first?.score ?? 0.0
    }
    return 0.0
}

func notifyTaskCompletion(taskName: String, accountName: String) {
    sendNotification(
        title: "BlueX",
        subtitle: accountName,
        body: "\(taskName) has successfully finished."
    )
}

