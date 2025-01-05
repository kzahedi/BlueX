//
//  Structs.swift
//  Bluesent
//
//  Created by Keyan Ghazi-Zahedi on 25.12.24.
//

import Foundation

struct FeedResponse: Codable {
    var cursor: String?
    var feed: [FeedItem]
   
    enum CodingKeys: String, CodingKey {
        case cursor
        case feed
    }
}

func decodeFeed(from jsonData: Data) throws -> FeedResponse {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let r = try decoder.decode(FeedResponse.self, from: jsonData)
    return r
}

struct FeedItem: Codable {
    let post: ApiPost
    
    enum CodingKeys: String, CodingKey {
        case post
    }
}

struct ThreadResponse: Codable {
    let thread: Thread
    
    enum CodingKeys: String, CodingKey {
        case thread
    }
}


func decodeThread(from jsonData: Data) throws -> ThreadResponse {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let r = try decoder.decode(ThreadResponse.self, from: jsonData)
    return r
}

struct Thread: Codable {
    let post: ApiPost?
    let replies : [Thread]?
    
    enum CodingKeys: String, CodingKey {
        case post
        case replies
    }
}

struct ApiPost: Codable {
    let uri: String?
    let author: Author?
    let record: Record?
    let repostCount: Int?
    let likeCount: Int?
    let indexedAt: String?
    let quoteCount: Int?
    let replyCount: Int?
    let title: String?
    let replies: [ApiPost]?
    
    enum CodingKeys: String, CodingKey {
        case uri = "uri"
        case author = "author"
        case record = "record"
        case repostCount = "repostCount"
        case likeCount = "likeCount"
        case indexedAt = "indexedAt"
        case quoteCount = "quoteCount"
        case replyCount = "replyCount"
        case title = "title"
        case replies = "replies"
    }
}

struct Record: Codable {
    let text: String?
    let createdAt: String?
    let embed: Embed?
    
    enum CodingKeys: String, CodingKey {
        case text = "text"
        case createdAt = "createdAt"
        case embed = "embed"
    }
}

struct Embed: Codable {
    let type: String?
    let external: External?
    
    enum CodingKeys: String, CodingKey {
        case type = "$type"
        case external = "external"
    }
}

struct External: Codable {
    let title: String?
    let description: String?
    let uri: String?
    
    enum CodingKeys: String, CodingKey {
        case title = "title"
        case description = "description"
        case uri = "uri"
    }
}

struct Author: Codable {
    let handle: String?
    let displayName: String?
    let did: String?
    let createdAt: String?
    
    enum CodingKeys: String, CodingKey {
        case handle = "handle"
        case displayName = "displayName"
        case did = "did"
        case createdAt = "createdAt"
    }
}
