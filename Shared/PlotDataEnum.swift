//
//  PlotDataEnum.swift
//  BlueX
//
//  Created by Keyan Ghazi-Zahedi on 27.01.25.
//

import Foundation

public enum PlotDataEnum {
    case RepliesPerDay
    case RepliesPerPost
    case PostsPerDay
    case SentimentPerPost
    case SentimentPerDay
    case SentimentPerReply
 
    enum CodingKeys : String, CodingKey {
        case RepliesPerPost = "Replies per post"
        case RepliesPerDay = "Replies per day"
        case PostsPerDay = "Posts per day"
        case SentimentPerPost = "Sentiment per day (posts)"
        case SentimentPerDay = "Sentiment per post replies"
        case SentimentPerReply = "Sentiment per day (replies)"
    }
    
    // Computed property to get the string value
    var stringValue: String {
        switch self {
            case .RepliesPerDay:
                return CodingKeys.RepliesPerDay.rawValue
            case .RepliesPerPost:
                return CodingKeys.RepliesPerPost.rawValue
            case .PostsPerDay:
                return CodingKeys.PostsPerDay.rawValue
            case .SentimentPerPost:
                return CodingKeys.SentimentPerPost.rawValue
            case .SentimentPerDay:
                return CodingKeys.SentimentPerDay.rawValue
            case .SentimentPerReply:
                return CodingKeys.SentimentPerReply.rawValue

        }
    }
   
}
