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
    case ReplySentimentsPerPost
    case ReplySentimentsPerDay
 
    enum CodingKeys : String, CodingKey {
        case RepliesPerPost = "Replies per post"
        case RepliesPerDay = "Replies per day"
        case PostsPerDay = "Posts per day"
        case SentimentPerPost = "Sentiment per day (posts)"
        case ReplySentimentsPerPost = "Sentiment per post replies"
        case ReplySentimentsPerDay = "Sentiment per day (replies)"
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
            case .ReplySentimentsPerPost:
                return CodingKeys.ReplySentimentsPerPost.rawValue
            case .ReplySentimentsPerDay:
                return CodingKeys.ReplySentimentsPerDay.rawValue
        }
    }
}
