//
//  SharedBskyFunctions.swift
//  BlueX
//
//  Created by Keyan Ghazi-Zahedi on 19.01.25.
//

import Foundation

struct ErrorResponse: Codable {
    let error: String
    let message: String?
}

enum BlueskyError: Error {
    case feedFetchFailed(reason: String, statusCode: Int?)
    case decodingError(String, underlyingError: Error)
    case networkError(String, underlyingError: Error)
    case invalidResponse(String)
    case unauthorized(String)
    
    var localizedDescription: String {
        switch self {
            case .feedFetchFailed(let reason, let code):
                if let statusCode = code {
                    return "Feed fetch failed: \(reason) (Status: \(statusCode))"
                }
                return "Feed fetch failed: \(reason)"
            case .decodingError(let context, let error):
                return "Decoding error in \(context): \(error.localizedDescription)"
            case .networkError(let context, let error):
                return "Network error in \(context): \(error.localizedDescription)"
            case .invalidResponse(let details):
                return "Invalid response received: \(details)"
            case .unauthorized(let message):
                return "Authorization failed: \(message)"
        }
    }
}

struct HandleResponse: Codable {
    let did: String
}

struct ProfileResponse: Codable {
    let did: String
    let handle:String
    let displayName: String
    let followersCount:Int
    let followsCount:Int
    let postsCount:Int
}

struct TokenResponse: Codable {
    let accessJwt: String
    
    enum CodingKeys: String, CodingKey {
        case accessJwt = "accessJwt"
    }
}

func resolveDID(handle: String) -> String? {
    let didURL = "https://bsky.social/xrpc/com.atproto.identity.resolveHandle"
    let group = DispatchGroup()
    let url = URL(string: "\(didURL)?handle=\(handle)")
    
    if url == nil {
        print("Not an URL: \(didURL)?handle=\(handle)")
        return nil
    }
    
    var request = URLRequest(url: url!)
    request.httpMethod = "GET"
    
    var returnValue : String? = nil
    
    group.enter()
    let task = URLSession.shared.dataTask(with: request) { data, response, error in
        if error != nil {
            print("Error resolving handle: \(error!)")
            group.leave()
        }
        
        if data == nil {
            print("No data received")
            group.leave()
        }
        
        do {
            // Check for error response
            if let errorResponse = try? JSONDecoder().decode(ErrorResponse.self, from: data!) {
                print("Error: \(errorResponse.error)")
                if let message = errorResponse.message {
                    print("Message: \(message)")
                }
                group.leave()
            }
            
            let handleResponse = try JSONDecoder().decode(HandleResponse.self, from: data!)
            returnValue = handleResponse.did
            group.leave()
        } catch {
            prettyPrintJSON(data: data!)
            print("Error decoding handle response: \(error.localizedDescription)")
            group.leave()
        }
    }
    
    task.resume()
    group.wait()
    return returnValue
}


func resolveProfile(did: String, token: String) -> ProfileResponse? {
    let didURL = "https://bsky.social/xrpc/app.bsky.actor.getProfile"
    let group = DispatchGroup()
    let url = URL(string: "\(didURL)?actor=\(did)")
    
    var request = URLRequest(url: url!)
    request.httpMethod = "GET"
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    
    
    var returnValue : ProfileResponse? = nil
    
    group.enter()
    let task = URLSession.shared.dataTask(with: request) { data, response, error in
        if error != nil {
            print("Error resolving handle: \(error!)")
            group.leave()
        }
        
        if data == nil {
            print("No data received")
            group.leave()
        }
        
        do {
            // Check for error response
            if let errorResponse = try? JSONDecoder().decode(ErrorResponse.self, from: data!) {
                print("Error: \(errorResponse.error)")
                if let message = errorResponse.message {
                    print("Message: \(message)")
                }
                group.leave()
            }
            
            let handleResponse = try JSONDecoder().decode(ProfileResponse.self, from: data!)
            returnValue = handleResponse
            group.leave()
        } catch {
            prettyPrintJSON(data: data!)
            print("Error decoding handle response: \(error.localizedDescription)")
            group.leave()
        }
    }
    
    task.resume()
    group.wait()
    return returnValue
}
